extends SceneTree

## Part packages, .bcpart (Docs/ModularParts.md section 7, stage 9), headless.
##
##     godot --headless --path . --script res://tools/package_probe.gd
##
##   export     a saved build's parts, one package each, its creator and bricks in it
##   import     into another folder: the record, a part.scn built here from the arrays and
##              the manifest; the part looks as it did (its nodes, meshes and materials the
##              same); the catalogue reads them and the game makes a gun of them; the same
##              package again changes nothing
##   refused    a file changed after packing; a file a package may not hold (a scene, a
##              script); a node of another type; an index out of range; a record that breaks
##              the schema; a path in its id; a shipped part's id; an older rev; too big
##   kept       a package cannot make itself official; a newer rev replaces the old

const DIR := "user://_probe_pkg/"

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
	_ws._hotbar.save_path = "user://_probe_pkg_hotbar.json"
	_ws.toolbars_save = "user://_probe_pkg_toolbars.json"
	_wipe(DIR)
	print("package probe")
	var made := _export()
	_import(made)
	_refused(made)
	_ws._builds_dir = BuildRecipe.player_dir()
	_wipe(DIR)
	print("package probe: %d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _export() -> Array:
	print("export")
	_ws._new_build()
	_ws.work_plane = "side"
	for spec in [["body", 3, [Vector2(20, 30), Vector2(40, 30), Vector2(40, 42), Vector2(20, 42)]],
			["grip", 3, [Vector2(34, 14), Vector2(38, 14), Vector2(39, 30), Vector2(35, 30)]],
			["barrel", 1, [Vector2(8, 35), Vector2(20, 35), Vector2(20, 38), Vector2(8, 38)]],
			["magazine", 1, [Vector2(26, 20), Vector2(30, 20), Vector2(30, 30), Vector2(26, 30)]]]:
		_ws.select_part(_ws.part_names.find(spec[0]))
		_ws.part_width[spec[0]] = spec[1]
		_ws.sketch_region(spec[2])
	for q in [["barrel", "mount", "barrel", "barrel.collar", [20, 36, 1]], ["body", "socket", "barrel", "barrel.collar", [20, 36, 2]],
			["grip", "mount", "grip", "grip.pin", [36, 30, 1]], ["body", "socket", "grip", "grip.pin", [36, 30, 2]],
			["magazine", "mount", "magazine", "mag.narrow", [28, 30, 1]], ["body", "socket", "magazine", "mag.narrow", [28, 30, 2]]]:
		_ws.select_part(_ws.part_names.find(q[0]))
		_ws.toggle_point(q[4], q[1], q[2], q[3])
	_ws._builds_dir = DIR
	_ws._save_as("Probe Pkg")
	var made: Array = _ws.export_packages(DIR + "out/")
	_ok("four packages", made.size() == 4 and made.all(func(r: Dictionary) -> bool: return r.ok), str(made))
	var got := PartPackage.read(made[0].path)
	_ok("one reads back whole", got.ok, String(got.get("why", "")))
	if got.ok:
		_ok("its creator and its bricks in it", (got.record as PartRecord).creator.get("name") == "player"
				and not ((got.record as PartRecord).extra.get("bricks", {}) as Dictionary).is_empty())
		_ok("its hash the one export gave", got.hash == made[0].hash)
	var zip := ZIPReader.new()
	zip.open(made[0].path)
	var names := Array(zip.get_files())
	zip.close()
	_ok("data only: no scene, no script in it", not names.any(func(n: String) -> bool:
			return n.ends_with(".scn") or n.ends_with(".tscn") or n.ends_with(".gd") or n.ends_with(".res")), str(names))
	return made


func _import(made: Array) -> void:
	print("import")
	var into := DIR + "in/"
	var none := PartCatalog.new()
	var all_ok := true
	for m in made:
		var r := PartPackage.import_file(m.path, into, none)
		all_ok = all_ok and r.ok
		if not r.ok:
			print("    ", r.why)
	_ok("all four imported", all_ok)
	var body_id: String = _ws.part_ids.body
	var dir := into + body_id + "/"
	var files := Array(DirAccess.get_files_at(dir))
	files.sort()
	_ok("its folder: the record, the scene built here, the manifest", files == ["package.json", "part.json", "part.scn"],
			str(files))
	var src := (load(_ws.parts_dir() + body_id + "/part.scn") as PackedScene).instantiate() as Node3D
	var back := (ResourceLoader.load(dir + "part.scn", "", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene).instantiate() as Node3D
	var da := PartPackage.describe(src)
	var db := PartPackage.describe(back)
	var why := _same(da, db, "")
	_ok("it looks as it did: the same nodes, meshes and materials", why == "" and (da.meshes as Array).size() > 0, why)
	_ok("the sockets where they were", back.get_node_or_null(^"socket_magazine") != null
			and (back.get_node(^"socket_magazine") as Node3D).position.is_equal_approx(
			(src.get_node(^"socket_magazine") as Node3D).position))
	var studs_src := PartDressing.studs(src).studs as Array
	var studs_back := PartDressing.studs(back).studs as Array
	_ok("its studs came too (dressing finds them)", studs_src.size() > 0 and studs_back.size() == studs_src.size(),
			"%d vs %d" % [studs_src.size(), studs_back.size()])
	src.free()
	back.free()
	var cat := PartCatalog.new()
	_ok("the catalogue reads them", cat.load_dir(into, "custom") == 4)
	var lib := GunPartLibrary.new()
	var res := AssetGuns.generate(lib, &"probe_pkg", 5, 1, 3, cat)
	_ok("the game makes the gun of them", res != null and res.gun_name.ends_with("Probe Pkg"), res.gun_name if res else "null")
	var again := PartPackage.import_file(made[0].path, into, none)
	_ok("the same package again: nothing changes", again.ok and again.get("same", false))


## A package of `files` (name -> bytes or Dictionary), its manifest made right -- as
## anyone can make one, so only the checks stand in the way.
func _pack(path: String, files: Dictionary) -> String:
	var bytes := {}
	for f in files:
		bytes[f] = files[f] if files[f] is PackedByteArray else JSON.stringify(files[f], "", true).to_utf8_buffer()
	var d = JSON.parse_string((bytes["part.json"] as PackedByteArray).get_string_from_utf8())
	var manifest := {"format": PartPackage.FORMAT, "id": d.get("id", ""), "rev": d.get("rev", 1), "files": {}}
	for f in bytes:
		manifest.files[f] = PartPackage._sha(bytes[f])
	manifest["hash"] = PartPackage.content_hash(manifest.files)
	bytes["manifest.json"] = JSON.stringify(manifest, "", true).to_utf8_buffer()
	var zip := ZIPPacker.new()
	zip.open(path)
	for f in bytes:
		zip.start_file(f)
		zip.write_file(bytes[f])
		zip.close_file()
	zip.close()
	return path


func _contents(path: String) -> Dictionary:
	var zip := ZIPReader.new()
	zip.open(path)
	var out := {}
	for f in zip.get_files():
		out[f] = zip.read_file(f)
	zip.close()
	return out


func _json(b: PackedByteArray) -> Dictionary:
	return JSON.parse_string(b.get_string_from_utf8())


func _refused(made: Array) -> void:
	print("refused")
	var into := DIR + "in2/"
	var none := PartCatalog.new()
	var c := _contents(made[0].path)
	# Changed after packing, its manifest left as it was.
	var rec := _json(c["part.json"])
	rec.name = "Something else"
	var bent := c.duplicate()
	bent["part.json"] = JSON.stringify(rec, "", true).to_utf8_buffer()
	var zip := ZIPPacker.new()
	zip.open(DIR + "bent.bcpart")
	for f in bent:
		zip.start_file(f)
		zip.write_file(bent[f])
		zip.close_file()
	zip.close()
	_ok("a file changed after packing", PartPackage.import_file(DIR + "bent.bcpart", into, none).why.contains("does not match its hash"))
	var base := {"part.json": _json(c["part.json"]), "mesh.json": _json(c["mesh.json"]),
			"interfaces.json": _json(c["interfaces.json"])}
	for bad in ["part.scn", "evil.gd", "x.tscn"]:
		var f := base.duplicate(true)
		f[bad] = "extends Node\nfunc _ready(): OS.shell_open('x')".to_utf8_buffer()
		var r := PartPackage.import_file(_pack(DIR + "extra.bcpart", f), into, none)
		_ok("a package holding %s" % bad, not r.ok and r.why.contains("may not"), r.get("why", ""))
	var odd := base.duplicate(true)
	odd["mesh.json"].nodes[0].type = "Node"
	_ok("a node of another type", PartPackage.import_file(_pack(DIR + "odd.bcpart", odd), into, none).why.contains("is a Node"))
	var idx := base.duplicate(true)
	for m in idx["mesh.json"].meshes:
		for s in m.surfaces:
			if s.arrays.has(str(Mesh.ARRAY_INDEX)):
				var ints: PackedInt32Array = PartPackage._dec(s.arrays[str(Mesh.ARRAY_INDEX)])
				ints[0] = 999999999
				s.arrays[str(Mesh.ARRAY_INDEX)] = PartPackage._enc(ints)
	var r_idx := PartPackage.import_file(_pack(DIR + "idx.bcpart", idx), into, none)
	_ok("an index out of range", not r_idx.ok and r_idx.why.contains("out of range"), r_idx.get("why", ""))
	var schema := base.duplicate(true)
	schema["part.json"].mount = {"interface": "mag.made_up"}
	_ok("a record that breaks the schema", PartPackage.import_file(_pack(DIR + "schema.bcpart", schema), into, none)
			.why.contains("no interface"))
	var path_id := base.duplicate(true)
	path_id["part.json"].id = "../../escape"
	_ok("a path in its id", not PartPackage.import_file(_pack(DIR + "path.bcpart", path_id), into, none).ok)
	var shipped := PartCatalog.new()
	var taken := PartRecord.from_dict(_json(c["part.json"]))
	taken.source = "official"
	taken.creator = {}
	shipped.add(taken)
	_ok("a shipped part's id", PartPackage.import_file(made[0].path, into, shipped).why.contains("shipped"))
	var big := FileAccess.open(DIR + "big.bcpart", FileAccess.WRITE)
	big.store_buffer(_bytes(PartPackage.MAX_PACKAGE + 10))
	big.close()
	_ok("too big", PartPackage.import_file(DIR + "big.bcpart", into, none).why.contains("too big"))

	print("kept")
	var sneaky := base.duplicate(true)
	sneaky["part.json"].source = "official"
	var rs := PartPackage.import_file(_pack(DIR + "sneaky.bcpart", sneaky), into, none)
	var cat := PartCatalog.new()
	cat.load_dir(into, "custom")
	_ok("it cannot make itself official", rs.ok and cat.get_part(rs.id).source == "custom")
	var newer := base.duplicate(true)
	newer["part.json"].rev = 5
	newer["part.json"].name = "Newer"
	var rn := PartPackage.import_file(_pack(DIR + "newer.bcpart", newer), into, none)
	_ok("a newer rev replaces it", rn.ok and PartRecord.load_file(rn.dir + "part.json").display_name == "Newer")
	var older := base.duplicate(true)
	older["part.json"].rev = 2
	older["part.json"].name = "Older"
	var ro := PartPackage.import_file(_pack(DIR + "older.bcpart", older), into, none)
	_ok("an older rev is refused", not ro.ok and ro.why.contains("rev 5 is here"), ro.get("why", ""))
	_ok("and changed nothing", PartRecord.load_file(rn.dir + "part.json").display_name == "Newer")


## Where two descriptions differ ("" nowhere). Normals and tangents only near: the engine
## packs them small, so one taken out and put back moves in the last bits.
func _same(a: Variant, b: Variant, at: String) -> String:
	if a is Dictionary and b is Dictionary:
		if a.keys().size() != b.keys().size():
			return "%s: keys %s vs %s" % [at, a.keys(), b.keys()]
		for k in a:
			if not b.has(k):
				return "%s: no %s" % [at, k]
			if at.ends_with("arrays") and str(k) in [str(Mesh.ARRAY_NORMAL), str(Mesh.ARRAY_TANGENT)]:
				var fa: PackedFloat32Array = Marshalls.base64_to_raw(a[k].b).to_float32_array()
				var fb: PackedFloat32Array = Marshalls.base64_to_raw(b[k].b).to_float32_array()
				if fa.size() != fb.size():
					return "%s/%s: lengths" % [at, k]
				for i in fa.size():
					if absf(fa[i] - fb[i]) > 0.01:
						return "%s/%s: %f vs %f" % [at, k, fa[i], fb[i]]
				continue
			var w := _same(a[k], b[k], "%s/%s" % [at, k])
			if w != "":
				return w
		return ""
	if a is Array and b is Array:
		if a.size() != b.size():
			return "%s: %d vs %d" % [at, a.size(), b.size()]
		for i in a.size():
			var w := _same(a[i], b[i], "%s[%d]" % [at, i])
			if w != "":
				return w
		return ""
	if (a is float or a is int) and (b is float or b is int):
		return "" if is_equal_approx(float(a), float(b)) else "%s: %s vs %s" % [at, a, b]
	return "" if a == b else "%s: %s vs %s" % [at, str(a).left(60), str(b).left(60)]


func _bytes(n: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(n)
	return b


func _wipe(dir: String) -> void:
	if not DirAccess.dir_exists_absolute(dir):
		return
	for d in DirAccess.get_directories_at(dir):
		_wipe(dir.path_join(d))
	for file in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(file))
	DirAccess.remove_absolute(dir)
