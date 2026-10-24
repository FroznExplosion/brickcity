extends SceneTree

## Every part saved on its own, and guns made only of parts that fit
## (Docs/ModularParts.md stage 2).
##
##     godot --headless --path . --script res://tools/part_save_probe.gd
##
##   fit rule    parts from before interfaces join each other by slot, as always; a part
##               that says its interface joins only a socket that takes it, and never a
##               part that says nothing
##   generator   a body that takes a narrow magazine never rolls a wide one; a muzzle goes
##               on the barrel's socket
##   save        Save writes each part in its own folder, part.json and part.scn, and no
##               gun file; each record says what it is, who made it, what it mounts with
##               and what it takes, and holds its own bricks
##   again       saved again unchanged, nothing is written; one part changed, only that
##               part is written, its rev up by one
##   game        the parts are a design the game makes a gun of, put together by the
##               assembler; a part that stops fitting makes no gun, and the assembler
##               leaves it off
##   new parts   Save As another name makes new parts and leaves the old; a new build
##               starts with no part ids

const DIR := "user://_probe_parts/"

var _pass := 0
var _fail := 0
var _ws
var _frames := 0


func _init() -> void:
	_ws = load("res://scenes/asset_workshop.tscn").instantiate()
	root.add_child(_ws)
	process_frame.connect(_tick)


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _tick() -> void:
	_frames += 1
	if _frames != 2:
		return
	_ws.set_process(false)
	# Nothing a probe does may land in the player's own files.
	_ws._hotbar.save_path = "user://_probe_asset_hotbar.json"
	_ws.toolbars_save = "user://_probe_asset_toolbars.json"
	_wipe(DIR)
	print("part save probe")
	_fit_rule()
	_generator()
	_save()
	_wipe(DIR)
	print("part save probe: %d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _def(id: String, slot: GunPartDef.Slot, mount: String = "", accepts: Dictionary = {}) -> GunPartDef:
	var d := GunReceiverDef.new() if slot == GunPartDef.Slot.BODY else GunPartDef.new()
	d.id = StringName(id)
	d.slot = slot
	d.scene = PackedScene.new()
	d.mount_interface = StringName(mount)
	d.socket_accepts = accepts
	return d


func _fit_rule() -> void:
	print("fit rule")
	var S := GunPartDef.Slot
	var old_body := _def("old_body", S.BODY)
	var old_mag := _def("old_mag", S.MAGAZINE)
	var body := _def("body", S.BODY, "", {"magazine": PackedStringArray(["mag.narrow"])})
	var narrow := _def("narrow", S.MAGAZINE, "mag.narrow")
	var wide := _def("wide", S.MAGAZINE, "mag.wide")
	_ok("old parts join by slot", old_body.takes(old_mag, "magazine"))
	_ok("a narrow magazine in a narrow well", body.takes(narrow, "magazine"))
	_ok("not a wide one", not body.takes(wide, "magazine"))
	_ok("not an old one on a new body", not body.takes(old_mag, "magazine"))
	_ok("not a new one on an old body", not old_body.takes(narrow, "magazine"))
	_ok("not in a socket the body has not", not body.takes(_def("b", S.BARREL, "barrel.collar"), "barrel"))
	var barrel := _def("barrel", S.BARREL, "barrel.collar", {"muzzle": PackedStringArray(["muzzle.pin"])})
	var recipe := {S.BODY: _def("b2", S.BODY, "", {"barrel": PackedStringArray(["barrel.collar"])}), S.BARREL: barrel}
	_ok("a muzzle on the barrel's socket", GunPartDef.fits_recipe(_def("m", S.MUZZLE, "muzzle.pin"), recipe))
	_ok("a muzzle of another pin on nothing", not GunPartDef.fits_recipe(_def("m2", S.MUZZLE, "muzzle.wide"), recipe))


func _generator() -> void:
	print("generator")
	var S := GunPartDef.Slot
	var lib := GunPartLibrary.new()
	var accepts := {"barrel": PackedStringArray(["barrel.collar"]), "grip": PackedStringArray(["grip.pin"]),
			"magazine": PackedStringArray(["mag.narrow"])}
	lib.parts = [_def("body", S.BODY, "", accepts), _def("barrel", S.BARREL, "barrel.collar"),
			_def("grip", S.GRIP, "grip.pin"), _def("narrow", S.MAGAZINE, "mag.narrow"),
			_def("wide", S.MAGAZINE, "mag.wide"), _def("wide2", S.MAGAZINE, "mag.wide")] as Array[GunPartDef]
	var mags := {}
	for i in 60:
		var res := GunGenerator.generate(lib, 500 + i, WeaponClass.builtin(&"smg"), 1, 1)
		var m: GunPartDef = res.recipe.get(S.MAGAZINE)
		mags[String(m.id) if m != null else "none"] = true
	_ok("a narrow-well body only ever rolls the narrow magazine", mags.keys() == ["narrow"], str(mags.keys()))


## A four-part gun on the side plane, as the workshop probe's round 8 builds one.
func _build_gun() -> void:
	_ws._new_build()
	_ws.work_plane = "side"
	for spec in [["body", 3, [Vector2(20, 30), Vector2(40, 30), Vector2(40, 42), Vector2(20, 42)]],
			["grip", 3, [Vector2(34, 14), Vector2(38, 14), Vector2(39, 30), Vector2(35, 30)]],
			["barrel", 1, [Vector2(8, 35), Vector2(20, 35), Vector2(20, 38), Vector2(8, 38)]],
			["magazine", 1, [Vector2(26, 20), Vector2(30, 20), Vector2(30, 30), Vector2(26, 30)]]]:
		_ws.select_part(_ws.part_names.find(spec[0]))
		_ws.part_width[spec[0]] = spec[1]
		_ws.sketch_region(spec[2])


func _point(part: String, kind: String, slot: String, iface: String, at: Array) -> void:
	_ws.select_part(_ws.part_names.find(part))
	_ws.toggle_point(at, kind, slot, iface)


func _save() -> void:
	print("save")
	_build_gun()
	_point("barrel", "mount", "barrel", "barrel.collar", [20, 36, 1])
	_point("body", "socket", "barrel", "barrel.collar", [20, 36, 2])
	_point("grip", "mount", "grip", "grip.pin", [36, 30, 1])
	_point("body", "socket", "grip", "grip.pin", [36, 30, 2])
	_point("magazine", "mount", "magazine", "mag.narrow", [28, 30, 1])
	_point("body", "socket", "magazine", "mag.narrow", [28, 30, 2])
	_ws.select_part(0)
	_ws._builds_dir = DIR
	var path: String = _ws._save_as("Probe Parts")
	var parts_dir: String = _ws.parts_dir()
	_ok("the build saved, its parts beside it in a test's folder", path != "" and parts_dir == DIR + "parts/", parts_dir)
	var folders := Array(DirAccess.get_directories_at(parts_dir))
	_ok("four parts, four folders", folders.size() == 4, str(folders))
	var every := true
	for f in folders:
		every = every and FileAccess.file_exists(parts_dir + f + "/part.json") \
				and FileAccess.file_exists(parts_dir + f + "/part.scn")
	_ok("each a part.json and a part.scn", every)
	_ok("no gun file among them", not _any_file(parts_dir, "gun.json"))
	_ok("no staging left", not DirAccess.dir_exists_absolute(parts_dir + ".staging"))

	var cat := PartCatalog.new()
	var n := cat.load_dir(parts_dir, "custom")
	_ok("the catalogue reads all four", n == 4, str(n))
	var body := _find(cat, "body")
	var mag := _find(cat, "magazine")
	_ok("a body: a gun's, held, custom, by its maker, from its build", body != null and body.family == "gun"
			and body.scale == "held" and body.source == "custom" and body.creator.get("name") == "player"
			and body.extra.get("from") == "Probe Parts" and body.weapon_class == _ws.gun_class)
	_ok("an id that is its maker's and its own", body != null and body.id.begins_with("player.probe_parts_body."), body.id if body else "")
	_ok("the body's sockets take what its points say", body != null
			and body.socket("magazine").get("accepts") == ["mag.narrow"]
			and body.socket("barrel").get("accepts") == ["barrel.collar"])
	_ok("the magazine mounts on mag.narrow, and detaches", mag != null and mag.interface() == "mag.narrow"
			and "detaches" in mag.tags)
	var bricks := BuildRecipe.from_dict(mag.extra.get("bricks", {})) if mag != null else BuildRecipe.new()
	var mag_bricks := 0
	for i in _ws.recipe.size():
		if _ws.part_names[_ws.part_of[i]] == "magazine":
			mag_bricks += 1
	_ok("it holds its own bricks and no others", bricks.size() == mag_bricks and mag_bricks > 0,
			"%d of %d" % [bricks.size(), mag_bricks])
	_ok("rev 1", body != null and body.rev == 1 and mag.rev == 1)

	var again: Dictionary = _ws.save_parts()
	_ok("saved again unchanged: nothing written", (again.written as Array).is_empty()
			and (again.kept as Array).size() == 4, str(again))
	_ws.select_part(_ws.part_names.find("barrel"))
	_ws.sketch_region([Vector2(4, 35), Vector2(8, 35), Vector2(8, 38), Vector2(4, 38)])
	again = _ws.save_parts()
	cat = PartCatalog.new()
	cat.load_dir(parts_dir, "custom")
	_ok("a longer barrel: only the barrel written", (again.written as Array).size() == 1
			and String(again.written[0]).contains("barrel"), str(again.written))
	_ok("its rev 2, the rest still 1", _find(cat, "barrel").rev == 2 and _find(cat, "body").rev == 1)

	# Into the game: a design of these parts, made into a gun.
	var designs := AssetGuns.designs(cat)
	_ok("the parts are one design, by the build's name", designs.has(&"probe_parts")
			and (designs.probe_parts.parts as Dictionary).size() == 4, str(designs.keys()))
	var lib := GunPartLibrary.new()
	AssetGuns.add_to(lib, cat)
	_ok("its parts fit: it makes a gun", AssetGuns.why_not(lib, &"probe_parts") == "",
			AssetGuns.why_not(lib, &"probe_parts"))
	var res := AssetGuns.generate(lib, &"probe_parts", 7, 1, 3, cat)
	_ok("a gun named for its build", res != null and res.gun_name.ends_with("Probe Parts"), res.gun_name if res else "null")
	if res != null:
		var gun := GunAssembler.assemble(res.recipe)
		root.add_child(gun)
		var placed := 0
		for c in gun.find_children("*", "Node3D", true, false):
			if c.is_in_group(GunAssembler.PART_GROUP):
				placed += 1
		_ok("the assembler puts all three on the body", placed == 3, str(placed))
		gun.queue_free()

	# The magazine changed to a wide one: it no longer fits.
	_ws.points = _ws.points.filter(func(q: Dictionary) -> bool: return not (q.part == "magazine" and q.kind == "mount"))
	_point("magazine", "mount", "magazine", "mag.wide", [28, 30, 1])
	_ws.save_parts()
	cat = PartCatalog.new()
	cat.load_dir(parts_dir, "custom")
	lib = GunPartLibrary.new()
	AssetGuns.add_to(lib, cat)
	var why := AssetGuns.why_not(lib, &"probe_parts")
	_ok("a wide magazine on a narrow well: no gun", why.contains("magazine") and why.contains("does not fit"), why)
	_ok("and generate gives none", AssetGuns.generate(lib, &"probe_parts", 7, 1, 3, cat) == null)
	var recipe := AssetGuns._recipe(lib, &"probe_parts")
	var gun := GunAssembler.assemble(recipe)
	root.add_child(gun)
	var mags := 0
	for c in gun.find_children("*", "Node3D", true, false):
		if c.is_in_group(GunAssembler.PART_GROUP) and c.get_meta(&"part_slot") == GunPartDef.Slot.MAGAZINE:
			mags += 1
	_ok("put together anyway, the assembler leaves the magazine off", mags == 0,
			"%d: body takes %s, magazine mounts %s" % [mags, recipe[GunPartDef.Slot.BODY].socket_accepts,
			recipe[GunPartDef.Slot.MAGAZINE].mount_interface])
	gun.queue_free()

	# Save As another name: new parts; the old stay.
	var old_ids: Dictionary = _ws.part_ids.duplicate()
	_ws._save_as("Probe Parts Two")
	_ok("Save As another name: new ids", _ws.part_ids.size() == 4 and _ws.part_ids.body != old_ids.body
			and String(_ws.part_ids.body).contains("probe_parts_two"), str(_ws.part_ids.body))
	_ok("eight parts now, the old ones kept", DirAccess.get_directories_at(parts_dir).size() == 8)
	_ws._new_build()
	_ok("a new build has no part ids", _ws.part_ids.is_empty())
	_ws._builds_dir = BuildRecipe.player_dir()


func _find(cat: PartCatalog, slot: String) -> PartRecord:
	var list := cat.filter({"slot": [slot]})
	return list[0] if not list.is_empty() else null


func _any_file(dir: String, file: String) -> bool:
	if FileAccess.file_exists(dir.path_join(file)):
		return true
	for d in DirAccess.get_directories_at(dir):
		if _any_file(dir.path_join(d), file):
			return true
	return false


func _wipe(dir: String) -> void:
	if not DirAccess.dir_exists_absolute(dir):
		return
	for d in DirAccess.get_directories_at(dir):
		_wipe(dir.path_join(d))
	for file in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(file))
	DirAccess.remove_absolute(dir)
