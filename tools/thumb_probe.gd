extends SceneTree

## Not headless (it draws): part pictures for the catalogue (Docs/ModularParts.md section 7).
## Run headless, it checks only that there is no picture and nothing breaks.
##
##     godot --path . --script res://tools/thumb_probe.gd
##
##   drawn      a part's picture, 256 across: the part in the middle, clear round it, its
##              colour; written beside the part as thumb.png
##   shown      the catalogue list shows it as the part's icon
##   carried    a package of the part carries the picture, and an import keeps it
##   headless   no window: no picture, and nothing breaks

const DIR := "user://_probe_thumb/"

var _pass := 0
var _fail := 0


func _init() -> void:
	print("thumb probe")
	_run.call_deferred()


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _part() -> PartRecord:
	var r := PartRecord.from_dict({"id": "lu.red_box", "name": "Red box", "family": "mech", "slot": "head",
			"source": "custom", "creator": {"name": "Lu"}, "mount": {"interface": "mech.neck"}})
	r.dir = DIR + r.id + "/"
	DirAccess.make_dir_recursive_absolute(r.dir)
	var n := Node3D.new()
	n.name = "head"
	var mi := MeshInstance3D.new()
	mi.name = "Model"
	var bm := BoxMesh.new()
	bm.size = Vector3(1.0, 0.6, 0.8)
	mi.mesh = bm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.9, 0.15, 0.1)
	mi.material_override = mat
	n.add_child(mi)
	mi.owner = n
	var m := Node3D.new()
	m.name = "mount"
	n.add_child(m)
	m.owner = n
	var ps := PackedScene.new()
	ps.pack(n)
	n.free()
	ResourceSaver.save(ps, r.dir + "part.scn")
	r.save_file(r.dir + "part.json")
	return r


func _run() -> void:
	_wipe(DIR)
	var r := _part()
	var host := Node3D.new()
	root.add_child(host)
	if not PartThumbnail.can_render():
		print("headless")
		var made: bool = await PartThumbnail.make_for(r.dir, host)
		_ok("no window: no picture, and nothing breaks", not made and not FileAccess.file_exists(r.dir + "thumb.png"))
		_ok("no picture: no icon", PartThumbnail.texture_for(r.dir) == null)
		_finish()
		return
	print("drawn")
	var made: bool = await PartThumbnail.make_for(r.dir, host)
	_ok("a picture made beside the part", made and FileAccess.file_exists(r.dir + "thumb.png"))
	var img := Image.load_from_file(ProjectSettings.globalize_path(r.dir + "thumb.png"))
	_ok("256 across", img != null and img.get_width() == 256 and img.get_height() == 256)
	if img != null:
		var mid := img.get_pixel(128, 128)
		var corner := img.get_pixel(3, 3)
		_ok("the part in the middle, in its colour", mid.a > 0.9 and mid.r > mid.g + 0.2 and mid.r > mid.b + 0.2, str(mid))
		_ok("clear round it", corner.a < 0.1, str(corner))
		var lit := 0
		for y in range(0, 256, 8):
			for x in range(0, 256, 8):
				if img.get_pixel(x, y).a > 0.5:
					lit += 1
		_ok("framed: it fills a good part of the picture, not all", lit > 150 and lit < 1000, "%d of 1024" % lit)
	print("shown")
	var cat := PartCatalog.new()
	cat.load_dir(DIR, "custom")
	var panel := PartCatalogPanel.new()
	root.add_child(panel)
	panel.set_catalog(cat)
	var item: TreeItem = panel._tree.get_root().get_child(0).get_child(0)
	_ok("the catalogue shows it as the part's icon", item.get_icon(0) != null and item.get_icon(0).get_width() == 256)
	print("carried")
	var pk := PartPackage.export_part(r.dir, DIR + "box.bcpart")
	var into := DIR + "in/"
	var im := PartPackage.import_file(DIR + "box.bcpart", into, PartCatalog.new())
	_ok("a package carries it and an import keeps it", pk.ok and im.ok and FileAccess.file_exists(into + r.id + "/thumb.png"))
	_finish()


func _finish() -> void:
	_wipe(DIR)
	print("thumb probe: %d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _wipe(dir: String) -> void:
	if not DirAccess.dir_exists_absolute(dir):
		return
	for d in DirAccess.get_directories_at(dir):
		_wipe(dir.path_join(d))
	for file in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(file))
	DirAccess.remove_absolute(dir)
