extends SceneTree

## The match's parts, offline (Docs/ModularParts.md section 7, stage 10's half without the
## netcode), headless.
##
##     godot --headless --path . --script res://tools/lobby_probe.gd
##
##   list       the host lists each part with its rev, hash and shape, no bricks; a part here
##              has the same hash every time it is asked
##   missing    a client without them lacks them all; with them, none; with another version,
##              that one; shipped parts are never missing
##   transfer   chunks in any order, twice over, arrive as the package; the part imported is
##              the one the lobby named; progress and what is still wanted; refused: a chunk
##              changed on the way, an offer not of the lobby's hash, too big, a chunk of the
##              wrong size or out of range
##   stand-in   a missing part's placeholder fits where it would, marked; a mech still goes
##              together with one
##   steam      without GodotSteam, everything comes from the host

const DIR := "user://_probe_lobby/"

var _pass := 0
var _fail := 0


func _init() -> void:
	print("lobby probe")
	_run.call_deferred()


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _part(base: String, d: Dictionary, sockets: Dictionary = {}, detail := 16) -> PartRecord:
	var socks := []
	for k in sockets:
		socks.append({"name": k, "accepts": [sockets[k][0]]})
	d["sockets"] = socks
	if not d.has("source"):
		d["source"] = "custom"
		d["creator"] = {"name": "Lu"}
	var r := PartRecord.from_dict(d)
	r.dir = base + r.id + "/"
	DirAccess.make_dir_recursive_absolute(r.dir)
	var node := Node3D.new()
	node.name = r.slot
	var mi := MeshInstance3D.new()
	mi.name = "Model"
	var sm := SphereMesh.new()
	sm.radial_segments = detail * 4
	sm.rings = detail * 2
	mi.mesh = sm
	node.add_child(mi)
	mi.owner = node
	if d.has("mount"):
		var m := Node3D.new()
		m.name = "mount"
		node.add_child(m)
		m.owner = node
	for k in sockets:
		var s := Node3D.new()
		s.name = "socket_" + k
		s.position = sockets[k][1]
		node.add_child(s)
		s.owner = node
	var ps := PackedScene.new()
	ps.pack(node)
	node.free()
	ResourceSaver.save(ps, r.dir + "part.scn")
	r.save_file(r.dir + "part.json")
	return r


func _run() -> void:
	_wipe(DIR)
	var host_dir := DIR + "host/"
	var ch := _part(host_dir, {"id": "lu.chassis", "family": "mech", "slot": "chassis", "class": "light"},
			{"leg_L": ["mech.hip", Vector3(-1, 0, 0)], "leg_R": ["mech.hip", Vector3(1, 0, 0)],
			"neck": ["mech.neck", Vector3.UP], "arm_L": ["mech.shoulder", Vector3.LEFT],
			"arm_R": ["mech.shoulder", Vector3.RIGHT]})
	var leg := _part(host_dir, {"id": "lu.leg", "family": "mech", "slot": "leg", "side": "any",
			"mount": {"interface": "mech.hip", "params": {"length": 2}}, "bricks": {"blocks": [1, 2, 3]}})
	var host := PartCatalog.new()
	host.load_dir(host_dir, "custom")

	print("list")
	var entries := PartLobby.list(["lu.chassis", "lu.leg", "nobody"], host)
	_ok("the host lists the two it has", entries.size() == 2, str(entries.size()))
	var le: Dictionary = entries[1]
	_ok("each with rev, hash and shape, no bricks", le.rev == 1 and String(le.hash).length() == 64
			and le.record.slot == "leg" and not le.record.has("bricks"))
	_ok("the same hash every time", PartLobby.list(["lu.leg"], host)[0].hash == le.hash)

	print("missing")
	var client_dir := DIR + "client/"
	var client := PartCatalog.new()
	_ok("a client without them lacks both", PartLobby.missing(entries, client).size() == 2)
	_ok("each from the host (no Steam here)", PartLobby.source_for(le) == "host")

	print("transfer")
	var none := PartCatalog.new()
	for e in entries:
		var made := PartTransfer.make_offer(host.get_part(String(e.id)).dir)
		var rx := PartTransfer.new(made.offer, String(e.hash))
		var order := range((made.chunks as Array).size())
		order.reverse()
		for i in order:
			rx.take(i, made.chunks[i])
			rx.take(i, made.chunks[i])
		var r := rx.finish(client_dir, none)
		_ok("%s: %d chunks in any order, twice over, in" % [e.id, (made.chunks as Array).size()], r.ok, String(r.get("why", "")))
	var big := PartTransfer.make_offer(ch.dir)
	_ok("a big part is more than one chunk", (big.chunks as Array).size() > 1, str((big.chunks as Array).size()))
	client.load_dir(client_dir, "custom")
	_ok("with them, the client lacks none", PartLobby.missing(entries, client).is_empty())
	_ok("the creator came with it", client.get_part("lu.leg").creator.get("name") == "Lu")

	var half := PartTransfer.new(big.offer, String(big.offer.hash))
	half.take(0, big.chunks[0])
	_ok("progress, and what is still wanted", is_equal_approx(half.progress(), 1.0 / (big.chunks as Array).size())
			and half.wanted().size() == (big.chunks as Array).size() - 1 and not half.finish(DIR + "x/").ok)
	var bent := PartTransfer.new(big.offer, String(big.offer.hash))
	for i in (big.chunks as Array).size():
		var c: PackedByteArray = (big.chunks[i] as PackedByteArray).duplicate()
		if i == 1:
			c[100] = c[100] ^ 0xFF
		bent.take(i, c)
	var rb := bent.finish(DIR + "bent/", none)
	_ok("a chunk changed on the way: refused", not rb.ok, String(rb.get("why", "")))
	_ok("an offer not of the lobby's hash: refused", PartTransfer.new(big.offer, "0".repeat(64)).why.contains("lobby"))
	var huge: Dictionary = (big.offer as Dictionary).duplicate()
	huge.size = PartPackage.MAX_PACKAGE + 1
	huge.count = ceili(float(huge.size) / PartTransfer.CHUNK)
	_ok("too big: refused", PartTransfer.new(huge).why.contains("at most"))
	var rx2 := PartTransfer.new(big.offer)
	_ok("a chunk of the wrong size or out of range: refused", not rx2.take(0, PackedByteArray([1, 2, 3]))
			and not rx2.take(999, big.chunks[0]) and not rx2.take(-1, big.chunks[0]))

	# Another version on the host: the client has the old one.
	leg.rev = 2
	leg.display_name = "Lu's leg, longer"
	leg.save_file(leg.dir + "part.json")
	host = PartCatalog.new()
	host.load_dir(host_dir, "custom")
	var entries2 := PartLobby.list(["lu.chassis", "lu.leg"], host)
	var lack := PartLobby.missing(entries2, client)
	_ok("another version on the host: that one missing", lack.size() == 1 and lack[0].id == "lu.leg")
	var shipped := [{"id": "korr_x", "rev": 1, "hash": "abc", "source": "official", "record": {}}]
	var with_ship := PartCatalog.new()
	with_ship.add(PartRecord.from_dict({"id": "korr_x", "family": "mech", "slot": "head", "source": "official"}))
	_ok("a shipped part is never missing", PartLobby.missing(shipped, with_ship).is_empty())

	print("stand-in")
	var stand := PartLobby.placeholder(le)
	_ok("a missing leg's stand-in: its slot, its fit, marked", stand != null and stand.slot == "leg"
			and stand.interface() == "mech.hip" and "placeholder" in stand.tags
			and FileAccess.file_exists(stand.dir + "part.scn"))
	_ok("it fits where the leg would", PartFit.fits(stand, ch, "leg_L", "mech"))
	var b := {"root": ch, "at": {"leg_L": stand, "leg_R": leg}}
	var model := MechAssembler.assemble(b)
	_ok("a mech goes together with it", model != null and (model.get_meta(&"joints") as Dictionary).has("leg_L"))
	if model != null:
		model.free()
	_ok("no record, no stand-in", PartLobby.placeholder({"id": "x"}) == null)

	print("steam")
	_ok("without GodotSteam: no Steam", not SteamParts.available() and not SteamParts.subscribe(1)
			and SteamParts.installed_folder(1) == "")
	SteamParts.keep_item(leg.dir, 4242)
	_ok("an item kept beside its part goes in the lobby list", int(PartLobby.list(["lu.leg"], host)[0].get("steam_item", 0)) == 4242)
	_ok("but still comes from the host while there is no Steam", PartLobby.source_for(PartLobby.list(["lu.leg"], host)[0]) == "host")
	_wipe(DIR)
	DirAccess.remove_absolute(PartLobby.PLACEHOLDER_DIR + "leg/part.scn")
	print("lobby probe: %d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _wipe(dir: String) -> void:
	if not DirAccess.dir_exists_absolute(dir):
		return
	for d in DirAccess.get_directories_at(dir):
		_wipe(dir.path_join(d))
	for file in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(file))
	DirAccess.remove_absolute(dir)
