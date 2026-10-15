extends SceneTree
## Acceptance probe for the asset workshop, phase 1 (Docs/AssetWorkshop.md).
##
##     godot --headless --path . --script tools/asset_workshop_probe.gd
##
## Drives the scene with exact numbers, as place_probe does: the scene's own
## `_process` is off, so nothing the real mouse does moves anything between checks.
##
##   units      a stud here is 4 mm printed and 16 mm real; a plate 1.6 and 6.4
##   photo      two clicks and a length scale a photo so those two points are that far
##              apart, about the first one, which stays put; a ray finds the photo
##   measure    a distance read out in studs, print mm and real mm
##   mirror     a brick placed with the mirror on is placed again across the plane, a
##              part with a front turned to look the other way
##   views      a flat view is orthographic and perspective comes back
##   saved      photos and the mirror ride in the recipe's meta and load back
##
## Phase 2:
##
##   parts      a brick is tagged with the part whose toolbar it came from; a delete takes
##              its own tag and an undo the last; each part keeps its own toolbar
##   run        holding LMB lays the brick again wherever the ghost moves
##   points     a mount placed, the same spot again takes it away, and they load back
##
## Phase 3:
##
##   packer     a box of cells is covered exactly; clean takes fewer bricks than random
##   shapes     a cylinder and a sphere are rounder than their box, a wedge falls along x
##   select     a box selects what is under it; re-pack, copy to the ghost, delete
##   guide      a model loads, sized so its longest side is the real length asked
##   section    a flat view cuts at the plane; perspective does not
##   outlines   drawn when asked
##
## Phase 4:
##
##   undo       a fill and a mirrored pair each undo at once; redo lays them back, each
##              brick in its own part
##   wand       a click on a photo fills the patch of its colour, and nothing outside it
##   export     the sheet has each part: as laid, or smooth as a loft; joints at the points

var _pass := 0
var _fail := 0
var _ws
var _frames := 0
const STUD := 0.35


func _init() -> void:
	_ws = load("res://scenes/asset_workshop.tscn").instantiate()
	root.add_child(_ws)
	process_frame.connect(_tick)


func _tick() -> void:
	_frames += 1
	if _frames != 2:
		return
	_ws.set_process(false)
	# Nothing a probe does may land in the player's own files.
	_ws._hotbar.save_path = "user://_probe_asset_hotbar.json"
	_ws.toolbars_save = "user://_probe_asset_toolbars.json"
	print("asset workshop probe (phases 1 and 2)")
	_units()
	_photo()
	_measure()
	_mirror()
	_views()
	_saved()
	_parts()
	_run()
	_points()
	_packer()
	_shapes()
	_select()
	_guide()
	_section()
	_undo_redo()
	_wand()
	_export()
	_ws.show_help(true)
	_ok("the instructions open", _ws._help.visible)
	_ws.show_help(false)
	_ok("and close", not _ws._help.visible)
	print("asset workshop probe: %d ok, %d FAIL" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s" % what)
	else:
		_fail += 1
		print("  FAIL %s  %s" % [what, detail])


func _units() -> void:
	var t: String = _ws.studs_text(53)
	_ok("53 studs are 212 mm printed, 848 mm real", t.contains("212.0 mm print") and t.contains("848 mm real"), t)
	t = _ws.plates_text(5)
	_ok("5 plates are 8 mm printed, 32 mm real", t.contains("8.0 mm print") and t.contains("32 mm real"), t)


func _photo() -> void:
	var img := Image.create(200, 100, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.8, 0.6, 0.3))
	var i: int = _ws.add_photo_image(img, "(probe)", "side")
	var a: Vector3 = _ws.photo_point(i, Vector2(50, 50))
	var b: Vector3 = _ws.photo_point(i, Vector2(150, 50))
	_ws.calibrate(i, a, b, 160.0)
	var a2: Vector3 = _ws.photo_point(i, Vector2(50, 50))
	var b2: Vector3 = _ws.photo_point(i, Vector2(150, 50))
	_ok("calibrated: 160 mm real between the points is 10 studs", absf(a2.distance_to(b2) - 10.0 * STUD) < 1e-4,
			"%.4f m" % a2.distance_to(b2))
	_ok("calibrated about the first point, which stays put", a2.distance_to(a) < 1e-4, "%v vs %v" % [a2, a])
	var on = _ws.ray_on_photo(i, a2 + Vector3(0, 0, 5), Vector3(0, 0, -1))
	_ok("a ray straight at the photo lands on it", on != null and (on as Vector3).distance_to(a2) < 1e-4, str(on))
	_ws.set_photo_plane(i, "top")
	var n: Vector3 = (_ws.photos[i].node as Node3D).transform.basis.z
	_ok("a photo on the top plane faces up", n.distance_to(Vector3.UP) < 1e-4, "%v" % n)
	_ws.set_photo_plane(i, "side")


func _measure() -> void:
	var t: String = _ws.measure_text(Vector3.ZERO, Vector3(STUD * 10.0, 0, 0))
	_ok("10 studs measure 40 mm printed, 160 mm real",
			t.contains("10 studs along") and t.contains("40.0 mm print") and t.contains("160 mm real"), t)
	var p = _ws.measure_point(Vector3(2.0, 5.0, 2.0), Vector3(0, -1, 0))
	# Within a millimetre of the workshop (0.01 mm printed): the face, not inside the brick.
	_ok("measuring onto the bare baseplate lands on its top", p != null and absf((p as Vector3).y - 0.14) < 1e-3, str(p))


func _part_index(name: String) -> int:
	return (_ws._parts() as Array).find(name)


func _mirror() -> void:
	_ws.mirror_z = 24.5
	_ok("a 2-wide part at 20 mirrors to 27 across a plane at 24.5", _ws.mirrored_z(20, 2) == 27)
	_ok("a 3-wide part centred on the plane is its own mirror", _ws.mirrored_z(23, 3) == 23)
	_ws.set_mirror(true)
	var before: int = _ws.recipe.size()
	_ws._part_index = _part_index("plate_1x2")
	_ws._yaw = 0
	_ws._flip = false
	_ws._cell = Vector3i(10, 1, 20)
	_ws._update_ghost()
	_ws._place()
	var got: int = _ws.recipe.size() - before
	_ok("a 1x2 placed with the mirror on lays two", got == 2, "laid %d" % got)
	if got == 2:
		var c: Vector3i = _ws.recipe.cell_of(before + 1)
		_ok("the mirrored one is across the plane", c == Vector3i(10, 1, 27), "%v" % c)

	var slope := ""
	for name in _ws._parts():
		if String(name).begins_with("slope_1x2"):
			slope = name
			break
	_ws._part_index = _part_index(slope)
	var facing_z := -1
	for y in 4:
		if BrickPalette.front_of(BrickPalette.variant_name(slope, y, false)) == Vector3i(0, 0, 1):
			facing_z = y
	_ws._yaw = facing_z
	_ws._cell = Vector3i(16, 1, 18)
	_ws._update_ghost()
	before = _ws.recipe.size()
	_ws._place()
	got = _ws.recipe.size() - before
	_ok("a slope placed with the mirror on lays two", got == 2, "laid %d (%s, yaw %d)" % [got, slope, facing_z])
	if got == 2:
		var f: Vector3i = BrickPalette.front_of(_ws.recipe.part_of(before + 1))
		_ok("the mirrored slope looks the other way", f == Vector3i(0, 0, -1), "%v" % f)
	_ws.set_mirror(false)


func _views() -> void:
	_ws.set_view(1)
	_ok("the side view is flat", (_ws._camera as Camera3D).projection == Camera3D.PROJECTION_ORTHOGONAL)
	_ws.set_view(0)
	_ok("perspective comes back", (_ws._camera as Camera3D).projection == Camera3D.PROJECTION_PERSPECTIVE)


func _saved() -> void:
	_ws.set_mirror(true)
	var bricks: int = _ws.recipe.size()
	var mpp: float = _ws.photos[0].mpp
	var d = JSON.parse_string(JSON.stringify(_ws.recipe.to_dict()))
	var r: BuildRecipe = BuildRecipe.from_dict(d)
	_ws._load_recipe(r)
	_ok("the bricks load back", _ws.recipe.size() == bricks, "%d of %d" % [_ws.recipe.size(), bricks])
	_ok("the photo loads back at its scale", _ws.photos.size() == 1 and absf(float(_ws.photos[0].mpp) - mpp) < 1e-9,
			"%d photos" % _ws.photos.size())
	_ok("the mirror loads back on", _ws.mirror_on)


func _lay(part_name: String, cell: Vector3i) -> bool:
	var before: int = _ws.recipe.size()
	_ws._part_index = _part_index(part_name)
	_ws._yaw = 0
	_ws._flip = false
	_ws._cell = cell
	_ws._update_ghost()
	_ws._place()
	return _ws.recipe.size() == before + 1


func _parts() -> void:
	_ws.set_mirror(false)
	_ws._new_build()
	_ok("a new build has a gun's parts", _ws.part_names.size() == 8 and _ws.part_names[2] == "stock")
	_ws.select_part(2)
	_lay("plate_1x2", Vector3i(30, 1, 30))
	_ws.select_part(0)
	_lay("plate_1x2", Vector3i(34, 1, 30))
	_lay("plate_1x2", Vector3i(38, 1, 30))
	_ok("each brick is tagged with its toolbar's part", Array(_ws.part_of) == [2, 0, 0], str(_ws.part_of))
	# Delete the stock's brick, the first one: from straight above it.
	var top := Vector3((30 + 0.5) * STUD, 3.0, (30 + 0.5) * STUD)
	_ws._delete_ray(top, Vector3.DOWN)
	_ok("a delete takes its own brick's tag", Array(_ws.part_of) == [0, 0], str(_ws.part_of))
	_ws._undo()
	_ok("an undo takes the last tag", Array(_ws.part_of) == [0], str(_ws.part_of))
	_ws._hotbar.select(0)
	_ws._hotbar.set_slot("brick_2x4", 3)
	_ws.select_part(1)
	_ws._hotbar.select(0)
	_ws._hotbar.set_slot("round_1x1", 5)
	_ws.select_part(0)
	_ok("a part's toolbar comes back with it", String(_ws._hotbar.slots[0][0]) == "brick_2x4",
			str(_ws._hotbar.slots[0]))
	_ws.select_part(1)
	_ok("and the other part's with it", String(_ws._hotbar.slots[0][0]) == "round_1x1", str(_ws._hotbar.slots[0]))


func _run() -> void:
	_ws._new_build()
	_ws._part_index = _part_index("plate_1x1")
	_ws._yaw = 0
	_ws._cell = Vector3i(20, 1, 20)
	_ws._update_ghost()
	_ws._place()
	_ws._run_on = true
	_ws._run_last = _ws._cell
	for x in [21, 22, 23]:
		_ws._cell = Vector3i(x, 1, 20)
		_ws._update_ghost()
		_ws.run_step()
	_ws._run_on = false
	_ok("a held run lays a brick at each cell the ghost passes", _ws.recipe.size() == 4, "%d bricks" % _ws.recipe.size())


func _points() -> void:
	_ws.select_part(2)
	var at := [30, 1, 20.5]
	_ok("a mount is placed", _ws.toggle_point(at, "mount", "stock", "stock.tang") and _ws.points.size() == 1)
	_ok("the same spot again takes it away", not _ws.toggle_point(at, "", "", "") and _ws.points.is_empty())
	_ws.toggle_point(at, "mount", "stock", "stock.tang")
	var tags := Array(_ws.part_of)
	var r: BuildRecipe = BuildRecipe.from_dict(JSON.parse_string(JSON.stringify(_ws.recipe.to_dict())))
	_ws._load_recipe(r)
	_ok("points and part tags load back", _ws.points.size() == 1 and String(_ws.points[0].part) == "stock"
			and Array(_ws.part_of) == tags, "%d points, tags %s" % [_ws.points.size(), _ws.part_of])


func _cells_box(lo: Vector3i, hi: Vector3i) -> Dictionary:
	var out := {}
	for x in range(lo.x, hi.x + 1):
		for y in range(lo.y, hi.y + 1):
			for z in range(lo.z, hi.z + 1):
				out[Vector3i(x, y, z)] = true
	return out


func _covered(packed: Array) -> int:
	var n := 0
	for pc in packed:
		var size := BrickPalette.size_of(pc[0])
		n += size.x * size.y * size.z
	return n


func _packer() -> void:
	var cells := _cells_box(Vector3i(10, 1, 10), Vector3i(17, 6, 11))
	var clean: Array = _ws.pack_cells(cells, false)
	var mixed: Array = _ws.pack_cells(cells, true)
	_ok("clean covers the box exactly", _covered(clean) == cells.size(), "%d of %d" % [_covered(clean), cells.size()])
	_ok("random covers the box exactly", _covered(mixed) == cells.size(), "%d of %d" % [_covered(mixed), cells.size()])
	_ok("clean takes fewer bricks than random", clean.size() < mixed.size(), "%d vs %d" % [clean.size(), mixed.size()])


func _shapes() -> void:
	var a := Vector3i(40, 1, 40)
	var b := Vector3i(47, 1, 47)
	var box: Dictionary = _ws.shape_cells("box", a, b, 3)
	var cyl: Dictionary = _ws.shape_cells("cylinder", a, b, 3)
	var sph: Dictionary = _ws.shape_cells("sphere", a, b, 3)
	_ok("a box is every cell", box.size() == 8 * 8 * 3)
	_ok("a cylinder is rounder than its box", cyl.size() < box.size() and cyl.size() > box.size() / 2, str(cyl.size()))
	_ok("a sphere is as tall as it is wide", sph.has(Vector3i(43, 1 + 9, 43)) and not sph.has(Vector3i(40, 1, 40)), str(sph.size()))
	var wedge: Dictionary = _ws.shape_cells("wedge", a, b, 6)
	_ok("a wedge falls along the gun", wedge.has(Vector3i(40, 6, 40)) and not wedge.has(Vector3i(47, 2, 40))
			and wedge.has(Vector3i(47, 1, 40)))
	_ws._new_build()
	var laid: int = _ws.fill_cells(_ws.shape_cells("box", Vector3i(30, 1, 30), Vector3i(35, 1, 31), 3))
	_ok("a box shape is laid as bricks", laid > 0 and _ws.recipe.size() == laid, "%d laid" % laid)


func _select() -> void:
	var n: int = _ws.recipe.size()
	_ws.select_box(Vector3i(29, 1, 29), Vector3i(36, 1, 32))
	_ok("a box over the shape selects all of it", _ws.selection.size() == n, "%d of %d" % [_ws.selection.size(), n])
	var got: Array = _ws.repack_selection(true)
	_ok("re-packed random, the same cells are still covered", _ws.recipe.size() == got[1] and got[1] > 0, str(got))
	_ws.select_box(Vector3i(29, 1, 29), Vector3i(36, 1, 32))
	_ws._cell = Vector3i(50, 1, 50)
	var copied: int = _ws.copy_selection_to_ghost(false)
	_ok("copied to the ghost", copied == got[1], "%d of %d" % [copied, got[1]])
	_ws.select_box(Vector3i(29, 1, 29), Vector3i(36, 1, 32))
	var gone: int = _ws.delete_selection()
	_ok("the selection deletes", gone == got[1] and _ws.recipe.size() == copied, "%d gone, %d left" % [gone, _ws.recipe.size()])


func _guide() -> void:
	var scene := Node3D.new()
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(2.0, 1.0, 0.5)
	mi.mesh = bm
	scene.add_child(mi)
	mi.owner = scene
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	doc.append_from_scene(scene, state)
	var path := ProjectSettings.globalize_path("user://_probe_guide.glb")
	doc.write_to_filesystem(state, path)
	scene.free()
	var i: int = _ws.load_guide(path, 160.0)
	_ok("a guide model loads", i >= 0)
	if i >= 0:
		var size: Vector3 = _ws.guide_size(i)
		var longest := maxf(size.x, maxf(size.y, size.z))
		_ok("its longest side is the real length asked: 160 mm is 10 studs", absf(longest - 10.0 * STUD) < 1e-3,
				"%.4f m" % longest)


func _section() -> void:
	_ws.set_view(1)
	_ws.set_section(true)
	_ok("a flat view with the section on cuts at the mirror plane", (_ws._camera as Camera3D).near > 1.0,
			"near %.2f" % (_ws._camera as Camera3D).near)
	_ws.set_view(0)
	_ok("perspective does not cut", absf((_ws._camera as Camera3D).near - 0.05) < 1e-6)
	_ws.set_section(false)
	_ws.set_outlines(1)
	_ws._draw_outlines()
	_ok("outlines are drawn", (_ws._outline_lines.mesh as ImmediateMesh).get_surface_count() > 0)
	_ws.set_outlines(0)


func _undo_redo() -> void:
	_ws._new_build()
	_ws.select_part(0)
	var laid: int = _ws.fill_cells(_cells_box(Vector3i(20, 1, 20), Vector3i(25, 3, 21)))
	_ws._undo()
	_ok("a fill undoes at once", _ws.recipe.size() == 0, "%d of %d left" % [_ws.recipe.size(), laid])
	var back: int = _ws.redo()
	_ok("redo lays the fill back", back == laid and _ws.recipe.size() == laid, "%d of %d" % [back, laid])
	_ws._undo()
	_ws.set_mirror(true)
	_ws.mirror_z = 30.5
	_lay("plate_1x2", Vector3i(20, 1, 26))
	_ok("a mirrored brick lays two", _ws.recipe.size() == 2, str(_ws.recipe.size()))
	_ws._undo()
	_ok("and they undo together", _ws.recipe.size() == 0, str(_ws.recipe.size()))
	_ws.set_mirror(false)


func _wand() -> void:
	_ws._new_build()
	var img := Image.create(100, 50, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.05, 0.05, 0.05))
	img.fill_rect(Rect2i(20, 10, 40, 30), Color(0.85, 0.7, 0.45))
	var i: int = _ws.add_photo_image(img, "(probe wand)", "side")
	# 100 px to 25 studs: 400 mm real.
	_ws.calibrate(i, _ws.photo_point(i, Vector2(0, 25)), _ws.photo_point(i, Vector2(100, 25)), 400.0)
	var hit: Vector3 = _ws.photo_point(i, Vector2(40, 25))
	var laid: int = _ws.wand_fill(i, hit, 2)
	var lo: Vector3 = _ws.photo_point(i, Vector2(20, 40))
	var hi: Vector3 = _ws.photo_point(i, Vector2(60, 10))
	var inside := true
	for k in _ws.recipe.size():
		var c: Vector3i = _ws.recipe.cell_of(k)
		var size := BrickPalette.size_of(_ws.recipe.part_of(k))
		if c.x * STUD < lo.x - STUD or (c.x + size.x) * STUD > hi.x + STUD:
			inside = false
	_ok("the wand fills the patch under the click", laid > 0, "%d laid" % laid)
	_ok("and nothing outside it", inside)
	_ws.remove_photo(i)


func _export() -> void:
	_ws._new_build()
	_ws.select_part(0)
	_ws.fill_cells(_cells_box(Vector3i(20, 1, 39), Vector3i(29, 6, 41)))
	_ws.select_part(2)
	_ws.fill_cells(_cells_box(Vector3i(30, 1, 39), Vector3i(37, 3, 41)))
	_ws.toggle_smooth()
	_ws.toggle_point([30, 2, 40.5], "mount", "stock", "stock.tang")
	var sheet: Dictionary = _ws.export_sheet()
	# Kept for running the part kit on by hand: the chain past this probe.
	var f := FileAccess.open("user://_probe_export.json", FileAccess.WRITE)
	f.store_string(JSON.stringify(sheet, " "))
	f.close()
	var by := {}
	for p in sheet.parts:
		by[p.name] = p
	_ok("the export has the body and the stock", by.has("body") and by.has("stock"), str(by.keys()))
	if by.has("body") and by.has("stock"):
		_ok("the body goes as laid", by.body.kind == "placed" and (by.body.bricks as Array).size() > 0)
		_ok("the smooth stock goes as a loft along the gun", by.stock.kind == "loft" and by.stock.axis == "x"
				and (by.stock.stations as Array).size() >= 8, "%s, %d stations" % [by.stock.kind, (by.stock.get("stations", []) as Array).size()])
		_ok("its mount is where the point is, in mm from the muzzle", by.stock.has("mount")
				and absf(float(by.stock.mount.at[0]) - 40.0) < 1e-6, str(by.stock.get("mount", {})))
