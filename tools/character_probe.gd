extends SceneTree

## Characters: the builder and what a figure does (Docs/ModularParts.md section 10), headless.
##
##     godot --headless --path . --script res://tools/character_probe.gd
##
##   builder    a whole figure rolled from the catalogue; each slot offers only the parts that
##              fit there (a mech's arm never, a head with no hat socket not while a hat is on);
##              Left / Right steps through them; saved as a design of fixed slots, read back
##              the same; put in the world, the same figure
##   brain      idle stands; follow walks after its target, facing it, and stops short;
##              patrol goes round its route; wander walks its circle

const DIR := "user://_probe_character/"

var _pass := 0
var _fail := 0


func _init() -> void:
	print("character probe")
	_run.call_deferred()


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _part(d: Dictionary, sockets: Dictionary = {}) -> PartRecord:
	var socks := []
	for k in sockets:
		socks.append({"name": k, "accepts": [sockets[k][0]]})
	d["sockets"] = socks
	d["source"] = "custom"
	d["creator"] = {"name": "Lu"}
	if not d.has("family"):
		d["family"] = "figure"
	var r := PartRecord.from_dict(d)
	r.dir = DIR + r.id + "/"
	DirAccess.make_dir_recursive_absolute(r.dir)
	var n := Node3D.new()
	n.name = r.slot
	var box := MeshInstance3D.new()
	box.mesh = BoxMesh.new()
	n.add_child(box)
	box.owner = n
	if d.has("mount"):
		var m := Node3D.new()
		m.name = "mount"
		n.add_child(m)
		m.owner = n
	for k in sockets:
		var s := Node3D.new()
		s.name = "socket_" + k
		s.position = sockets[k][1]
		n.add_child(s)
		s.owner = n
	var ps := PackedScene.new()
	ps.pack(n)
	n.free()
	ResourceSaver.save(ps, r.dir + "part.scn")
	return r


func _catalog() -> PartCatalog:
	var cat := PartCatalog.new()
	var torso_sockets := {"neck": ["fig.neck", Vector3(0, 0.5, 0)], "arm_L": ["fig.shoulder", Vector3(-0.2, 0.4, 0)],
			"arm_R": ["fig.shoulder", Vector3(0.2, 0.4, 0)], "leg_L": ["fig.hip", Vector3(-0.1, 0, 0)],
			"leg_R": ["fig.hip", Vector3(0.1, 0, 0)]}
	for r in [
		_part({"id": "torso_a", "slot": "torso", "name": "Torso A"}, torso_sockets),
		_part({"id": "torso_b", "slot": "torso", "name": "Torso B"}, torso_sockets),
		_part({"id": "head_hatted", "slot": "head", "name": "Head with studs", "mount": {"interface": "fig.neck"}},
				{"hat": ["fig.hat", Vector3(0, 0.3, 0)]}),
		_part({"id": "head_bald", "slot": "head", "name": "Bald head", "mount": {"interface": "fig.neck"}}),
		_part({"id": "arm_1", "slot": "arm", "side": "any", "name": "Arm 1", "mount": {"interface": "fig.shoulder"}},
				{"hand": ["fig.wrist", Vector3(0, -0.4, 0)]}),
		_part({"id": "arm_2", "slot": "arm", "side": "any", "name": "Arm 2", "mount": {"interface": "fig.shoulder"}},
				{"hand": ["fig.wrist", Vector3(0, -0.45, 0)]}),
		_part({"id": "arm_3", "slot": "arm", "side": "any", "name": "Arm 3", "mount": {"interface": "fig.shoulder"}},
				{"hand": ["fig.wrist", Vector3(0, -0.5, 0)]}),
		_part({"id": "hand", "slot": "hand", "side": "any", "name": "Hand", "mount": {"interface": "fig.wrist"}}),
		_part({"id": "leg", "slot": "leg", "side": "any", "name": "Leg", "mount": {"interface": "fig.hip"}}),
		_part({"id": "hat_cap", "slot": "hat", "name": "Cap", "tags": ["hat"], "mount": {"interface": "fig.hat"}}),
		_part({"id": "mech_arm", "family": "mech", "slot": "arm", "side": "any", "name": "Mech arm",
				"mount": {"interface": "mech.shoulder"}}),
	]:
		cat.add(r)
	return cat


func _run() -> void:
	_wipe(DIR)
	var cat := _catalog()
	print("builder")
	var cb := CharacterBuilder.new()
	root.add_child(cb)
	cb.open(cat)
	_ok("a whole figure rolled", cb.figure != null and PartFit.problems({"root": cb.figure.build.root,
			"at": cb.figure.build.at}, "figure").is_empty())
	_ok("its slots: the torso, then each socket", cb.slots()[0] == "root" and "neck/hat" in cb.slots()
			and cb.slots().size() == 9, str(cb.slots()))
	var arm_ids := cb.options("arm_L").map(func(r: PartRecord) -> String: return r.id)
	_ok("the arm slot offers the figure arms, never a mech's", arm_ids == ["arm_1", "arm_2", "arm_3"], str(arm_ids))
	# Make sure a hat is on, then the bald head is not offered.
	if not cb.figure.build.at.has("neck/hat"):
		cb.figure.swap("neck", cat.get_part("head_hatted"))
		cb.figure.swap("neck/hat", cat.get_part("hat_cap"))
	if (cb.figure.build.at.neck as PartRecord).id != "head_hatted":
		cb.figure.swap("neck/hat", cat.get_part("hat_cap"))
	var heads := cb.options("neck").map(func(r: PartRecord) -> String: return r.id)
	_ok("with a hat on, a head with nowhere for it is not offered", cb.figure.build.at.has("neck/hat")
			and heads == ["head_hatted"], "%s %s" % [heads, cb.figure.build.at.keys()])
	cb.slot = cb.slots().find("arm_L")
	var was: String = cb.figure.build.at.arm_L.id
	_ok("Right: the next arm that fits", cb.cycle(1) and cb.figure.build.at.arm_L.id != was)
	cb.cycle(-1)
	_ok("Left: back to the one it was", cb.figure.build.at.arm_L.id == was)
	_ok("its hand stays on through it", cb.figure.build.at.has("arm_L/hand"))
	cb.design_name = "Probe Kid"
	var path := cb.save(DIR + "designs/")
	var designs := PartDesign.load_all([DIR + "designs/"])
	var d: PartDesign = designs.get("probe_kid")
	_ok("saved as a design, every slot fixed", path != "" and d != null and d.plan == "figure"
			and d.slots.root.fixed == cb.figure.build.root.id and d.slots.size() == cb.figure.build.at.size() + 1)
	var again := Figure.make(PartBuilder.generate("figure", d, 99, cat))
	var same := again != null
	if same:
		for p in cb.figure.build.at:
			same = same and again.build.at[p].id == cb.figure.build.at[p].id
	_ok("read back, the same figure", same)
	var got := []
	cb.spawned.connect(func(f: Figure) -> void: got.append(f))
	var f := cb.spawn()
	_ok("put in the world: the same figure, its own", f != null and got == [f] and f != cb.figure
			and f.build.at.arm_L.id == cb.figure.build.at.arm_L.id)
	_ok("the builder's text lists it", cb.text().contains("Probe Kid") and cb.text().contains("arm_L"))

	print("brain")
	root.add_child(f)
	f.mode = "idle"
	f.think(0.1)
	_ok("idle: stands", f.speed == 0.0)
	var t := Node3D.new()
	root.add_child(t)
	t.position = Vector3(0, 0, -10)
	f.position = Vector3.ZERO
	f.mode = "follow"
	f.target = t
	for i in 400:
		f.think(1.0 / 30.0)
	var d_now := Vector2(f.position.x - t.position.x, f.position.z - t.position.z).length()
	_ok("follow: walks after its target and stops short", absf(d_now - Figure.FOLLOW_GAP) < 0.05 and f.speed == 0.0,
			str(d_now))
	var facing := -f.global_transform.basis.z
	_ok("facing it", facing.dot((t.position - f.position).normalized()) > 0.95)
	f.mode = "patrol"
	f.route = [Vector3(5, 0, 0), Vector3(5, 0, 5)]
	var seen := {}
	for i in 900:
		f.think(1.0 / 30.0)
		if f.position.distance_to(Vector3(5, 0, 0)) < 0.35:
			seen["a"] = true
		if f.position.distance_to(Vector3(5, 0, 5)) < 0.35:
			seen["b"] = true
	_ok("patrol: round its route", seen.size() == 2, str(seen.keys()))
	f.mode = "wander"
	f.think(0.5)
	_ok("wander: its circle", f.speed == Figure.WANDER_SPEED and f.wander)
	_wipe(DIR)
	print("character probe: %d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _wipe(dir: String) -> void:
	if not DirAccess.dir_exists_absolute(dir):
		return
	for d in DirAccess.get_directories_at(dir):
		_wipe(dir.path_join(d))
	for file in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(file))
	DirAccess.remove_absolute(dir)
