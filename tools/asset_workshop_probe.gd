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
##
## Round 2 (after the first use):
##
##   floor      there is none: an empty build has no bricks at all, and the starting brick
##              is laid mid-air when the build is empty
##   free       the ghost goes where the cursor meets the working plane
##   lengths    a calibration length in mm or in studs
##   sketch     an outline fills exactly the cells inside it, as thick as the part; a top
##              edge climbing two plates a stud is laid as slopes facing the right way,
##              a bottom edge as flipped ones, a rounding end as a curve; the front and
##              top planes sketch too
##   zoom       zooming a flat view keeps the point under the cursor where it was
##   photo      "behind the build" puts a side photo just past the build's far side
##
## Round 3:
##
##   delete     an RMB delete undoes and redoes
##   one click  a held click lays nothing more until the mouse has really moved
##   sketch     kept: area drawn out takes bricks away; an outline round twice fills whole;
##              a change undoes at once, sketch and bricks; eager slopes on a one-plate step

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
	_round2()
	_round3()
	_round4()
	_round5()
	_round6()
	_round7()
	_round8()
	_round9()
	_round10()
	_form()
	_resize()
	_curves()
	_sideways()
	_shells()
	_sculpt()
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
	_ok("an undo lays the deleted brick back, in its own part", Array(_ws.part_of) == [0, 0, 2], str(_ws.part_of))
	_ws._undo()
	_ws._undo()
	_ok("and further undos take the last tags", Array(_ws.part_of) == [0], str(_ws.part_of))
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
	# Held still, a click lays nothing more however the ghost settles.
	_ws._run_moved = 0.0
	_ws._run_press_ms = Time.get_ticks_msec()
	_ws._cell = Vector3i(21, 1, 20)
	_ws._update_ghost()
	_ws.run_step()
	_ok("a click held still lays one brick", _ws.recipe.size() == 1, "%d bricks" % _ws.recipe.size())
	# Dragged, it lays a run.
	_ws._run_moved = 40.0
	_ws._run_press_ms = Time.get_ticks_msec() - 1000
	_ws._run_last = Vector3i(20, 1, 20)
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
	# Filled again over itself and a brick beside it: nothing is laid where bricks are, and
	# the rest of the box is filled whole round them.
	_ws._new_build()
	_lay("brick_1x1", Vector3i(32, 1, 30))
	_ws.fill_cells(_ws.shape_cells("box", Vector3i(30, 1, 30), Vector3i(35, 1, 31), 3))
	_ok("a fill packs round a brick already there, leaving no hole", _volume() == 6 * 2 * 3, "%d cells" % _volume())


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
	_ws.fill_cells(_cells_box(Vector3i(30, 1, 39), Vector3i(37, 8, 41)))
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
		_ok("the smooth stock has studs on both sides", (by.stock.get("studs", []) as Array).size() == 2)
		_ok("its mount is where the point is, in mm from the muzzle", by.stock.has("mount")
				and absf(float(by.stock.mount.at[0]) - 40.0) < 1e-6, str(by.stock.get("mount", {})))


func _volume() -> int:
	var n := 0
	for k in _ws.recipe.size():
		var size := BrickPalette.size_of(_ws.recipe.part_of(k))
		n += size.x * size.y * size.z
	return n


func _round2() -> void:
	_ws._new_build()
	_ok("no floor: an empty build has nothing to hit", _ws.recipe.size() == 0
			and (_ws._first_hit(Vector3(14.0, 5.0, 14.0), Vector3.DOWN) as Dictionary).is_empty())
	_ws.auto_start_brick = true
	_ws._ensure_start_brick()
	_ws.auto_start_brick = false
	_ok("the starting brick is laid mid-air", _ws.recipe.size() == 1
			and _ws.recipe.cell_of(0).y == _ws.work_height, "%d bricks" % _ws.recipe.size())

	_ws.work_plane = "side"
	_ws.work_depth = 40.5
	var hit = _ws.work_plane_hit(Vector3(3.0, 4.0, 30.0), Vector3(0, 0, -1))
	_ok("a ray meets the side working plane at its depth", hit != null
			and absf((hit as Vector3).z - 40.5 * STUD) < 1e-5, str(hit))
	var c: Vector3i = _ws.free_cell(Vector3(10.2 * STUD, 30.5 * 0.14, 40.5 * STUD), Vector3i(2, 1, 1))
	_ok("a 2-long part centres on the cursor, on the plane's depth", c == Vector3i(9, 30, 40), "%v" % c)

	_ok("lengths: 852 is mm", _ws.length_mm("852") == 852.0)
	_ok("lengths: 53s is 53 studs, 848 mm", _ws.length_mm("53s") == 848.0, str(_ws.length_mm("53s")))
	_ok("lengths: 12 studs is 192 mm", _ws.length_mm("12 studs") == 192.0)

	_ws._new_build()
	_ws.select_part(0)
	_ws.part_width["body"] = 3
	var laid: int = _ws.sketch_fill([Vector2(10, 30), Vector2(16, 30), Vector2(16, 36), Vector2(10, 36)])
	_ok("a sketched square fills its cells, 3 studs thick", laid > 0 and _volume() == 6 * 6 * 3,
			"%d laid, %d cells" % [laid, _volume()])
	_ws._undo()
	_ok("and undoes at once", _ws.recipe.size() == 0, "%d left" % _ws.recipe.size())

	# A ramp climbing 2 plates a stud along +x: its top edge is a slope's pitch.
	_ws._new_build()
	_ws.part_width["body"] = 2
	_ws.sketch_fill([Vector2(10, 30), Vector2(20, 30), Vector2(20, 50)])
	var slopes := 0
	var facing_ok := true
	for k in _ws.recipe.size():
		var name: String = _ws.recipe.part_of(k)
		if name.begins_with("slope_"):
			slopes += 1
			if BrickPalette.front_of(name) != Vector3i(-1, 0, 0):
				facing_ok = false
	_ok("a ramp's top edge is laid as slopes", slopes >= 3, "%d slopes of %d bricks" % [slopes, _ws.recipe.size()])
	_ok("each slope's low front faces down the ramp", facing_ok)
	_ok("a flat outline has no edge pieces", _ws.edge_pieces({Vector2i(0, 0): true, Vector2i(1, 0): true}).is_empty())
	# A bottom edge falling two plates a stud along +x: flipped slopes under it.
	_ws._new_build()
	_ws.part_width["body"] = 2
	_ws.sketch_fill([Vector2(10, 50), Vector2(20, 50), Vector2(20, 30)])
	var under := 0
	for k in _ws.recipe.size():
		var name: String = _ws.recipe.part_of(k)
		if name.begins_with("slope_") and name.ends_with("_i"):
			under += 1
	_ok("a falling bottom edge is laid as flipped slopes", under >= 3, "%d of %d bricks" % [under, _ws.recipe.size()])
	# An end that rounds over: two plates up from nothing, then one more.
	var grid := {}
	for v in 2:
		grid[Vector2i(0, v)] = true
	for u in [1, 2]:
		for v in 3:
			grid[Vector2i(u, v)] = true
	var found: Array = _ws.edge_pieces(grid)
	_ok("an end rounding over three plates in two studs is a curve", found.size() >= 1 and found[0].kind == "curve"
			and found[0].u == 0 and found[0].base == 0 and found[0].rises == 1, str(found))

	# A drum on the front plane: a circle, two studs thick along the gun.
	_ws._new_build()
	_ws.work_plane = "front"
	_ws.work_x = 40
	var circle := []
	for a in 24:
		var t := a * TAU / 24.0
		circle.append(Vector2(40.5 + 5.0 * cos(t), 60.0 + 12.5 * sin(t)))
	var drum: int = _ws.sketch_fill(circle)
	var along_ok := true
	for k in _ws.recipe.size():
		var at: Vector3i = _ws.recipe.cell_of(k)
		var size := BrickPalette.size_of(_ws.recipe.part_of(k))
		if at.x < 39 or at.x + size.x > 41:
			along_ok = false
	_ok("a circle on the front plane fills, two studs along the gun", drum > 0 and along_ok, "%d laid" % drum)
	# A square on the top plane: two studs thick is five plates up.
	_ws._new_build()
	_ws.work_plane = "top"
	_ws.work_height = 20
	_ws.sketch_fill([Vector2(10, 30), Vector2(14, 30), Vector2(14, 34), Vector2(10, 34)])
	_ok("a square on the top plane fills 4 x 4 studs, 5 plates up", _volume() == 4 * 4 * 5, "%d cells" % _volume())
	_ws.work_plane = "side"
	_ws.work_height = 30
	_ws.part_width["body"] = 3

	_ws._new_build()
	_ws.sketch_fill([Vector2(10, 30), Vector2(16, 30), Vector2(16, 36), Vector2(10, 36)])
	var img := Image.create(40, 20, false, Image.FORMAT_RGBA8)
	var i: int = _ws.add_photo_image(img, "(probe depth)", "side")
	_ws.set_photo_depth(i, "behind")
	var lo: Vector3i = _ws.recipe.bounds()[0]
	_ok("behind the build: just past its far side", absf((_ws.photos[i].centre as Vector3).z
			- (lo.z - 0.5) * STUD) < 1e-5, str(_ws.photos[i].centre))
	_ws.remove_photo(i)

	_ws.set_view(1)
	var cam := _ws._camera as Camera3D
	var point := cam.global_position + Vector3(2.0, 1.0, -cam.global_position.z + 14.0)
	var before := cam.unproject_position(point)
	_ws.zoom_at(point, 0.7)
	var after := cam.unproject_position(point)
	_ok("zooming keeps the point under the cursor", before.distance_to(after) < 0.5, "%v -> %v" % [before, after])
	_ws.set_view(0)


func _round3() -> void:
	_ws.work_plane = "side"
	_ws.work_depth = 40.5
	_ws._new_build()
	_lay("brick_1x2", Vector3i(20, 1, 20))
	var top := Vector3(20.5 * STUD, 1.5 * 0.14, 20.5 * STUD)
	_ws._delete_ray(top, Vector3.DOWN)
	_ok("RMB deletes", _ws.recipe.size() == 0)
	_ws._undo()
	_ok("Z lays a deleted brick back", _ws.recipe.size() == 1 and _ws.recipe.cell_of(0) == Vector3i(20, 1, 20),
			"%d bricks" % _ws.recipe.size())
	_ws.redo()
	_ok("shift Z deletes it again", _ws.recipe.size() == 0, "%d bricks" % _ws.recipe.size())

	# A square drawn round twice: even-odd would leave a hole where it crosses itself.
	_ws._new_build()
	_ws.select_part(0)
	_ws.part_width["body"] = 2
	var square := [Vector2(10, 30), Vector2(16, 30), Vector2(16, 36), Vector2(10, 36)]
	var twice := []
	for _i in 2:
		for q in square:
			twice.append(q + Vector2(randf() * 0.01, 0))
	_ws.sketch_region(twice)
	_ok("an outline drawn round twice fills whole", _volume() == 6 * 6 * 2, "%d cells" % _volume())
	# Its right half drawn out: the bricks are worked out again.
	_ws.sketch_region([Vector2(13, 29), Vector2(17, 29), Vector2(17, 37), Vector2(13, 37)], true)
	var right := 0
	for k in _ws.recipe.size():
		var at: Vector3i = _ws.recipe.cell_of(k)
		var size := BrickPalette.size_of(_ws.recipe.part_of(k))
		if at.x + size.x > 13:
			right += 1
	_ok("RMB area drawn out takes those bricks away", _volume() == 3 * 6 * 2 and right == 0, "%d cells" % _volume())
	_ws._undo()
	_ok("and one Z puts them back, sketch and all", _volume() == 6 * 6 * 2
			and (_ws.sketches[_ws._sketch_key()].subs as Array).is_empty(), "%d cells" % _volume())
	_ws.redo()
	_ok("shift Z takes them out again", _volume() == 3 * 6 * 2, "%d cells" % _volume())

	# A one-plate step: a slope only when eager.
	# Not at an end (an end rounding over is a curve's): flat, flat, one plate up.
	var step := {}
	for u in [-1, 0, 1]:
		for v in (4 if u == 1 else 3):
			step[Vector2i(u, v)] = true
	_ok("a one-plate step gets no slope at the slope's own pitch", _ws.edge_pieces(step, false).is_empty())
	_ok("and one when slopes are eager", _ws.edge_pieces(step, true).size() == 1, str(_ws.edge_pieces(step, true)))

	# A small change to a big part works out only the bricks near it (each stroke laying
	# the whole part again was a hitch), and still fills exactly what is drawn.
	_ws._new_build()
	_ws.select_part(0)
	_ws.sketch_region([Vector2(10, 30), Vector2(40, 30), Vector2(40, 60), Vector2(10, 60)])
	var had := {}
	for k in _ws.recipe.size():
		had["%s|%s" % [_ws.recipe.part_of(k), _ws.recipe.cell_of(k)]] = true
	var t0 := Time.get_ticks_msec()
	_ws.sketch_region([Vector2(36, 56), Vector2(41, 56), Vector2(41, 61), Vector2(36, 61)], true)
	var ms := Time.get_ticks_msec() - t0
	var same := 0
	for k in _ws.recipe.size():
		if had.has("%s|%s" % [_ws.recipe.part_of(k), _ws.recipe.cell_of(k)]):
			same += 1
	_ok("a small cut keeps the bricks clear of it", same * 10 >= _ws.recipe.size() * 8,
			"%d of %d kept, %d ms" % [same, _ws.recipe.size(), ms])
	_ok("and fills exactly what is left", _volume() == (30 * 30 - 4 * 4) * 2, "%d cells" % _volume())
	_ws._undo()
	_ok("one Z puts the corner back", _volume() == 30 * 30 * 2, "%d cells" % _volume())
	_ws.part_width["body"] = 3


func _round4() -> void:
	# Stage 1: the rail and the brushes.
	_ws.rail_pick("sketch")
	_ok("the rail opens sketch", _ws.tool == "sketch" and _ws.rail_active() == "sketch")
	_ws.rail_pick("paint")
	_ok("and paint, putting sketch down", _ws._painting and _ws.tool == "" and _ws.rail_active() == "paint")
	_ws.rail_pick("place")
	_ok("place puts everything down", not _ws._painting and _ws.tool == "" and _ws.rail_active() == "place")
	var rect: Array = _ws.drag_shape("rect", Vector2(14, 36), Vector2(10, 30))
	_ok("a rectangle dragged either way has its four corners", rect.size() == 4 and rect[0] == Vector2(10, 30)
			and rect[2] == Vector2(14, 36), str(rect))
	var round_cells: Dictionary = _ws.brush_cells(_ws.brush_entry([Vector2(20.5, 40.5)], 2, false, "side"))
	var square_cells: Dictionary = _ws.brush_cells(_ws.brush_entry([Vector2(20.5, 40.5)], 2, true, "side"))
	_ok("a square brush of 2 studs on the side plane covers 5 studs by 11 plates", square_cells.size() == 55,
			str(square_cells.size()))
	_ok("a round one less, its middle in", round_cells.size() < 55 and round_cells.has(Vector2i(20, 40)),
			str(round_cells.size()))
	_ws._new_build()
	_ws.select_part(0)
	_ws.part_width["body"] = 2
	_ws.sketch_region_entry(_ws.brush_entry([Vector2(10.5, 30.5), Vector2(20.5, 30.5)], 1, true, "side"))
	_ok("a brush stroke sketches what it swept: 13 studs by 5 plates, 2 deep", _volume() == 130, "%d cells" % _volume())
	_ws._new_build()
	_lay("brick_1x2", Vector3i(20, 1, 20))
	_ws._repaint(0, 3, 1)
	_ws.paint_what = "colour"
	_ws._colour = 5
	_ws._mat = 0
	_ws._stroke = []
	_ws._paint_one(0)
	_ok("paint, colour only, leaves the material", _ws.recipe.colour_of(0) == 5 and _ws.recipe.material_of(0) == 1,
			"colour %d material %d" % [_ws.recipe.colour_of(0), _ws.recipe.material_of(0)])
	_ws._end_stroke()
	_ws.paint_what = "both"

	# Stage 2: a part in three views. A receiver: a side rectangle 10 studs by 15 plates,
	# 4 thick (z 39..42 round the plane at 40.5).
	_ws._new_build()
	_ws.select_part(0)
	_ws.part_width["body"] = 4
	_ws.work_plane = "side"
	_ws.sketch_region([Vector2(10, 30), Vector2(20, 30), Vector2(20, 45), Vector2(10, 45)])
	_ok("a side view: a slab its thickness deep", _volume() == 10 * 15 * 4, "%d cells" % _volume())
	# From the front (studs across, plates up): area drawn in keeps only what is inside it.
	_ws.work_plane = "front"
	_ws.work_x = 25
	_ws.sketch_region([Vector2(39, 20), Vector2(41, 20), Vector2(41, 50), Vector2(39, 50)])
	_ok("a front view keeps only what is inside it", _volume() == 10 * 15 * 2, "%d cells" % _volume())
	_ws._undo()
	_ok("and undoes", _volume() == 10 * 15 * 4, "%d cells" % _volume())
	# Area drawn out from the front cuts right through, along the whole part.
	_ws.sketch_region([Vector2(38, 42), Vector2(44, 42), Vector2(44, 50), Vector2(38, 50)], true)
	_ok("area drawn out from the front cuts through", _volume() == 10 * 12 * 4, "%d cells" % _volume())
	_ws._undo()
	# A port: a depth cut from the side, one stud in from the face toward the camera.
	_ws.work_plane = "side"
	_ws.cut_deep = 1
	_ws.sketch_region([Vector2(12, 36), Vector2(16, 36), Vector2(16, 40), Vector2(12, 40)], true)
	_ws.cut_deep = 0
	_ok("a depth cut makes a pocket, not a hole", _volume() == 10 * 15 * 4 - 4 * 4, "%d cells" % _volume())
	_ws._undo()
	_ok("one Z fills it", _volume() == 10 * 15 * 4, "%d cells" % _volume())
	# A chamfer seen from the front, at a slope's pitch: slopes along the part.
	_ws.slope_eager = true
	_ws.work_plane = "front"
	_ws.sketch_region([Vector2(39, 30), Vector2(43, 30), Vector2(43, 45), Vector2(41, 45), Vector2(39, 41)])
	var slopes := 0
	for k in _ws.recipe.size():
		if String(_ws.recipe.part_of(k)).begins_with("slope"):
			slopes += 1
	_ok("a chamfer from the front gets slopes (%d)" % slopes, slopes > 0, "%d slopes, %d cells" % [slopes, _volume()])
	_ws.slope_eager = false
	_ws.clear_part_sketch("body")
	_ok("clearing the part takes every view's bricks", _ws.recipe.size() == 0 and _ws.sketches.is_empty(),
			"%d bricks" % _ws.recipe.size())
	_ws.work_plane = "side"
	_ws.part_width["body"] = 3

	# Stage 3: studs anywhere. A brick's side, from +z.
	_ws._new_build()
	_ws.select_part(0)
	_lay("brick_2x4", Vector3i(20, 1, 20))
	var size := BrickPalette.size_of(_ws.recipe.part_of(0))
	var hit: Dictionary = _ws.stud_hit(Vector3((20 + size.x * 0.5 + 0.1) * STUD, 2.4 * 0.14, 30 * STUD), Vector3.BACK * -1)
	_ok("a stud on a brick's side faces out of it", not hit.is_empty() and Array(hit.dir) == [0.0, 0.0, 1.0]
			and is_equal_approx(float(hit.at[2]), 20 + size.z), str(hit))
	_ok("on the side's half-stud lattice", not hit.is_empty() and is_equal_approx(fmod(float(hit.at[0]) * 2.0, 1.0), 0.0)
			and is_equal_approx(fmod(float(hit.at[1]) * 2.0, 1.0), 0.0), str(hit.get("at")))
	_ws.stud_edit(true, hit)
	_ok("put on", _ws.extra_studs.size() == 1)
	_ws._undo()
	_ok("Z takes it off", _ws.extra_studs.is_empty())
	_ws.redo()
	_ok("shift Z puts it back", _ws.extra_studs.size() == 1)
	var sheet: Dictionary = _ws.export_sheet()
	var extra := []
	for sp in sheet.parts:
		extra.append_array(sp.get("studs_extra", []))
	_ok("it leaves with the part, facing across the gun", extra.size() == 1
			and is_equal_approx(absf(float(extra[0].normal[1])), 1.0), str(extra))
	# A connection point on it, facing the way it does.
	_ws.point_on_stud(hit)
	_ok("a stud as a connection point asks which", _ws._point_panel.visible and Array(_ws._point_panel.get_meta("dir")) == Array(hit.dir))
	_ws._point_panel.visible = false
	_ws.toggle_point(hit.at, "mount", "body", "stock.tang", hit.dir)
	sheet = _ws.export_sheet()
	var mount := {}
	for sp in sheet.parts:
		if sp.has("mount"):
			mount = sp.mount
	_ok("and leaves facing that way", mount.has("normal") and is_equal_approx(absf(float(mount.normal[1])), 1.0), str(mount))
	_ws.toggle_point(hit.at, "", "", "")
	# A slope's leaning face: the stud leans with it.
	_ws._new_build()
	var slope: String = _ws.edge_variant("slope", 1, 1, false, "side")
	_ws.place_named(slope, Vector3i(30, 1, 20))
	var ss := BrickPalette.size_of(slope)
	var lean := {}
	for x in [30.2, 30.5, 30.8, 31.2, 31.5, 31.8]:
		var h: Dictionary = _ws.stud_hit(Vector3(x * STUD, 3.0, (20 + ss.z * 0.5) * STUD), Vector3.DOWN)
		if not h.is_empty() and absf(float(h.dir[1])) < 0.94 and float(h.dir[1]) > 0.0:
			lean = h
	_ok("a stud on a slope leans with its face", not lean.is_empty(), str(lean))
	_ws.extra_studs.clear()
	_ws._draw_studs()

	# Stage 4: exploded, and parts moved whole. A body, and a barrel forward of it (-x).
	_ws._new_build()
	_ws.select_part(0)
	_lay("brick_2x4", Vector3i(30, 1, 20))
	_ws.select_part(_ws.part_names.find("barrel"))
	_lay("brick_2x4", Vector3i(26, 1, 20))
	var bsize := BrickPalette.size_of(_ws.recipe.part_of(1))
	_ws.select_part(0)
	_ws.set_exploded(true)
	_ws._rebuild_display()
	_ok("exploded, each part is drawn on its own", _ws._display.has("body") and _ws._display.has("barrel"))
	var off: Vector3 = _ws._offsets.get("barrel", Vector3.ZERO)
	_ok("the barrel goes forward of the body, the body stays", off.x < -3.0 and _ws._offsets.get("body") == Vector3.ZERO, str(off))
	# A ray down onto the barrel where it is drawn is taken into the barrel where it is.
	var above := Vector3((26 + bsize.x * 0.5) * STUD + off.x, 5.0, (20 + bsize.z * 0.5) * STUD)
	var into: Array = _ws.ray_into_parts([above, Vector3.DOWN])
	var met: Dictionary = _ws._first_hit(into[0], into[1])
	_ok("a ray onto a drawn-apart part meets it where it really is", _ws._ray_part == "barrel" and not met.is_empty()
			and _ws._recipe_id_at(0, met.block) == 1, "%s %s" % [_ws._ray_part, str(met)])
	# Moved whole, as one undo, studs with it; refused onto another part.
	var st: Dictionary = _ws.stud_hit(Vector3((26 + bsize.x * 0.5 + 0.1) * STUD, 2.4 * 0.14, 30 * STUD), Vector3.FORWARD)
	_ws.stud_edit(true, st)
	_ok("a part will not move into another", not _ws.move_part("barrel", Vector3i(4, 0, 0)))
	_ok("moved whole", _ws.move_part("barrel", Vector3i(-3, 2, 0)) and _ws.recipe.cell_of(_ws.recipe.size() - 1) == Vector3i(23, 3, 20),
			str(_ws.recipe.cell_of(_ws.recipe.size() - 1)))
	_ok("its studs go with it", is_equal_approx(float(_ws.extra_studs[0].at[0]), float(st.at[0]) - 3.0), str(_ws.extra_studs))
	_ws._undo()
	var back := false
	for k in _ws.recipe.size():
		back = back or _ws.recipe.cell_of(k) == Vector3i(26, 1, 20)
	_ok("one Z puts it back, studs and all", back and is_equal_approx(float(_ws.extra_studs[0].at[0]), float(st.at[0])),
			str(_ws.extra_studs))
	_ws.set_exploded(false)
	_ok("closed, the parts are one build again", _ws._display.is_empty() and _ws.part_offset("barrel") == Vector3.ZERO)
	_ws.extra_studs.clear()
	_ws._draw_studs()

	# Stage 5: the hands, and the gun worked. A body, a grip leaning back under it, a
	# magazine in front of the grip, a barrel.
	_ws._new_build()
	_ws.work_plane = "side"
	for spec in [["body", 3, [Vector2(20, 30), Vector2(50, 30), Vector2(50, 44), Vector2(20, 44)]],
			["grip", 3, [Vector2(40, 12), Vector2(45, 12), Vector2(48, 30), Vector2(43, 30)]],
			["magazine", 3, [Vector2(28, 10), Vector2(33, 10), Vector2(33, 30), Vector2(28, 30)]],
			["barrel", 1, [Vector2(4, 36), Vector2(20, 36), Vector2(20, 40), Vector2(4, 40)]]]:
		_ws.select_part(_ws.part_names.find(spec[0]))
		_ws.part_width[spec[0]] = spec[1]
		_ws.sketch_region(spec[2])
	_ws.select_part(0)
	_ws.set_hands(true)
	var t: Dictionary = _ws.hand_targets()
	var right: Node3D = _ws._hand_nodes[0]
	var k: float = 1.0 / float(_ws.GAME_PER_WORKSHOP)
	var hole := right.transform * Vector3(0, ViewArms.HOLE_Y, 0)
	_ok("the right hand's C is round the grip", t.has("right") and hole.distance_to(t.right[0]) < 0.01
			and absf(right.transform.basis.x.normalized().y) > 0.8, "%s %s" % [hole, str(t.get("right"))])
	_ok("at the gun's scale: its hole is a grip's thickness (7-9.5 mm print)",
			absf(0.019 * 2.0 * k / BrickPalette.STUD_M * 4.0 - 8.3) < 1.3, "%.1f mm" % (0.019 * 2.0 * k / BrickPalette.STUD_M * 4.0))
	_ok("the left hand on the barrel, its hole along the gun", t.get("fore") == "barrel"
			and absf((_ws._hand_nodes[1] as Node3D).transform.basis.x.normalized().x) > 0.9, str(t.get("fore")))
	_ws._play = {"t": 0.0, "last": 0}
	_ws._rebuild_display()
	_ws.play_pose(0.06)
	var body_d: Dictionary = _ws._display.body
	_ok("a shot kicks the gun back", ((body_d.mesh as Node3D).transform.origin - (body_d.xform as Transform3D).origin).x > 0.05,
			str((body_d.mesh as Node3D).transform.origin - (body_d.xform as Transform3D).origin))
	_ws.play_pose(3.0)
	var mag_d: Dictionary = _ws._display.magazine
	_ok("reloading, the magazine comes out under the gun, the left hand pinching it",
			((mag_d.mesh as Node3D).transform.origin - (mag_d.xform as Transform3D).origin).y < -2.0
			and ((_ws._hand_nodes[1] as Node3D).get_node("PINCH") as Node3D).visible,
			str((mag_d.mesh as Node3D).transform.origin - (mag_d.xform as Transform3D).origin))
	_ws._play = {}
	_ws._clear_display()
	_ws.set_hands(false)


func _round5() -> void:
	# RMB in sketch takes up any brick under the stroke, not only the sketch's own.
	_ws._new_build()
	_ws.work_plane = "side"
	_ws.select_part(_ws.part_names.find("barrel"))
	_lay("brick_2x4", Vector3i(30, 1, 20))
	_ws.select_part(0)
	var cut := [Vector2(29, 0), Vector2(33, 0), Vector2(33, 5), Vector2(29, 5)]
	_ws.sketch_region(cut, true)
	_ok("RMB in sketch takes up a hand-laid brick of another part", _ws.recipe.size() == 0, "%d bricks" % _ws.recipe.size())
	_ws._undo()
	_ok("and Z lays it back", _ws.recipe.size() == 1)
	# Over a sketch of this part: its bricks and the other brick, one undo.
	_ws.part_width["body"] = 3
	_ws.sketch_region([Vector2(20, 6), Vector2(40, 6), Vector2(40, 12), Vector2(20, 12)])
	var with_sketch: int = _ws.recipe.size()
	_ws.sketch_region([Vector2(28, 0), Vector2(34, 0), Vector2(34, 13), Vector2(28, 13)], true)
	var hand_gone := true
	for k in _ws.recipe.size():
		hand_gone = hand_gone and _ws.recipe.cell_of(k) != Vector3i(30, 1, 20)
	_ok("a cut over a sketch takes its bricks and the other brick", hand_gone and _ws._volume_in(28, 34) == 0,
			"%d bricks" % _ws.recipe.size())
	_ws._undo()
	_ok("one Z puts both back", _ws.recipe.size() == with_sketch, "%d of %d" % [_ws.recipe.size(), with_sketch])
	# A depth cut takes only the nearest brick in.
	_ws._new_build()
	_ws.select_part(_ws.part_names.find("barrel"))
	_lay("brick_2x4", Vector3i(30, 1, 20))
	_lay("brick_2x4", Vector3i(30, 1, 30))
	var near_ids: Array = _ws.bricks_under(_ws.region_cells([[29, 0], [33, 0], [33, 5], [29, 5]]), "side", 1, 1)
	_ok("a depth cut reaches only the brick nearest the camera", near_ids.size() == 1
			and _ws.recipe.cell_of(near_ids[0]) == Vector3i(30, 1, 30), str(near_ids))
	_ws.erase_any = false
	_ws.select_part(0)
	_ws.sketch_region(cut, true)
	_ok("switched off, RMB leaves other bricks alone", _ws.recipe.size() == 2)
	_ws.erase_any = true


func _round6() -> void:
	# The shape brush: Ctrl + LMB lays a shape, Ctrl + RMB carves one, in any tool.
	var cube: Dictionary = _ws.brush_shape_cells("cube", Vector3i(30, 20, 30), 4)
	var box: Array = _ws.brush_shape_box("cube", Vector3i(30, 20, 30), 4)
	_ok("a 4-stud cube: 4 studs by 10 plates by 4", cube.size() == 160 and box[1] - box[0] == Vector3i(4, 10, 4),
			"%d cells %s" % [cube.size(), str(box)])
	_ok("a 1-stud ball is one stud, 3 plates", _ws.brush_shape_cells("ball", Vector3i(30, 20, 30), 1).size() == 3)
	var disc: Dictionary = _ws.brush_shape_cells("circle", Vector3i(30, 20, 30), 4, 1, 1)
	var flat := true
	for c in disc:
		flat = flat and c.y == 20
	_ok("a flat circle lies on its plane, one cell thick, corners off", flat and disc.size() == 12, "%d cells" % disc.size())
	var upright: Dictionary = _ws.brush_shape_cells("square", Vector3i(30, 20, 30), 4, 2, 2)
	var zs := {}
	for c in upright:
		zs[c.z] = true
	_ok("on the side plane it stands up, its thickness across", zs.size() == 2 and upright.size() == 4 * 10 * 2,
			"%d cells, %d deep" % [upright.size(), zs.size()])
	_ws._new_build()
	_ws.select_part(0)
	_ws.shape_place(cube)
	_ok("laid: the cube's cells, filled", _volume() == 160, "%d cells" % _volume())
	var ball: Dictionary = _ws.brush_shape_cells("ball", Vector3i(32, 24, 32), 4)
	var both := 0
	for c in ball:
		if cube.has(c):
			both += 1
	_ws._group(_ws.shape_carve(ball))
	_ok("carved: what the ball covered is gone, the rest laid again", _volume() == 160 - both and both > 0,
			"%d cells, %d carved" % [_volume(), both])
	var parts_ok := true
	for k in _ws.recipe.size():
		parts_ok = parts_ok and _ws.part_of[k] == 0
	_ok("in its own part", parts_ok)
	_ws._undo()
	_ok("one Z fills the hole", _volume() == 160, "%d cells" % _volume())


func _round7() -> void:
	# Saved as a gun, in the guns' library, and opened back with everything.
	_ok("what is made here is a gun", _ws.recipe.kind == "gun", _ws.recipe.kind)
	_ok("guns have a library of their own", BuildRecipe.player_dir("gun") == "user://guns/")
	var m: WorkshopMenu = _ws._menu
	var shown := []
	for i in m._open_filter.item_count:
		shown.append(m._open_filter.get_item_metadata(i))
	_ok("Open lists only assets", shown == ["gun", "mech"], str(shown))
	_ok("no building menus: Insert, Type, Layer, Generated hidden", not m._insert.visible and not m._type.visible
			and not m._layer.visible and not m._gen.visible)
	_ok("and no Test in city", m._file.get_popup().get_item_index(WorkshopMenu.F_CITY) < 0)
	_ws._new_build()
	_ws.select_part(_ws.part_names.find("grip"))
	_lay("brick_2x4", Vector3i(30, 1, 20))
	_ws.extra_studs.append({"part": "grip", "at": [31.0, 3.0, 21.0], "dir": [0.0, 1.0, 0.0], "colour": 0, "mat": 0})
	_ws._store_asset_meta()
	_ws._builds_dir = "user://_probe_guns/"
	var path: String = _ws._save_as("Probe Gun")
	_ok("Save As writes the gun", path.ends_with("probe_gun.json") and FileAccess.file_exists(path), path)
	_ws._new_build()
	_ok("opened back: its bricks, its parts, its studs", _ws._open_path(path) and _ws.recipe.size() == 1
			and _ws.part_of[0] == _ws.part_names.find("grip") and _ws.extra_studs.size() == 1
			and _ws.recipe.kind == "gun", "%d bricks, studs %d" % [_ws.recipe.size(), _ws.extra_studs.size()])
	DirAccess.remove_absolute(path)
	_ws._builds_dir = BuildRecipe.player_dir()
	_ws.extra_studs.clear()
	_ws._draw_studs()


func _round8() -> void:
	# Out to the game: each part a scene, put back together by the game's own assembler.
	_ws._new_build()
	_ws.work_plane = "side"
	for spec in [["body", 3, [Vector2(20, 30), Vector2(40, 30), Vector2(40, 42), Vector2(20, 42)]],
			["grip", 3, [Vector2(34, 14), Vector2(38, 14), Vector2(39, 30), Vector2(35, 30)]],
			["barrel", 1, [Vector2(8, 35), Vector2(20, 35), Vector2(20, 38), Vector2(8, 38)]],
			["muzzle", 1, [Vector2(5, 34), Vector2(8, 34), Vector2(8, 39), Vector2(5, 39)]]]:
		_ws.select_part(_ws.part_names.find(spec[0]))
		_ws.part_width[spec[0]] = spec[1]
		_ws.sketch_region(spec[2])
	_ws.select_part(0)
	var dir := "user://_probe_gun_game/"
	var out: Dictionary = _ws.export_game(dir)
	_ok("export to game writes a scene a part", out.get("ok", false) and (out.parts as Dictionary).size() == 4,
			str(out))
	var recipe := {}
	for name in out.parts:
		var def := GunPartDef.new()
		def.id = StringName("probe_" + name)
		def.slot = GunPartDef.SLOT_BY_SUFFIX[name]
		def.scene = load(out.parts[name])
		recipe[def.slot] = def
	var gun := GunAssembler.assemble(recipe)
	root.add_child(gun)
	var placed := {}
	for n in gun.find_children("*", "Node3D", true, false):
		if n.is_in_group(GunAssembler.PART_GROUP):
			placed[String(GunPartDef.Slot.keys()[n.get_meta(&"part_slot")]).to_lower()] = n
	placed["body"] = gun
	_ok("the game's assembler puts every part on", placed.size() == 4, str(placed.keys()))
	# Each part where it was built: its bricks' middle, in the game's frame from the body's.
	var b: Basis = _ws.game_basis()
	var ids := {}
	for i in _ws.recipe.size():
		(ids.get_or_add(_ws.part_names[_ws.part_of[i]], []) as Array).append(i)
	var body_c: Vector3 = _ws._cells_centre(ids.body)
	var worst := 0.0
	for name in ["grip", "barrel", "muzzle"]:
		var want: Vector3 = b * (_ws._cells_centre(ids[name]) - body_c)
		worst = maxf(worst, ((placed[name] as Node3D).global_position - gun.global_position).distance_to(want))
	_ok("each part sits where it was built (within a millimetre)", worst < 0.001, "%.4f m off" % worst)
	var grip_mesh: MeshInstance3D = (placed.grip as Node3D).find_child("Bricks", true, false)
	var gb := grip_mesh.global_transform * grip_mesh.get_aabb()
	_ok("real size: a 16-plate grip is 6.4 cm tall... (16 plates x 1.6 mm x 4)", absf(gb.size.y - 0.1024) < 0.005,
			"%.3f m" % gb.size.y)
	# The muzzle socket the game fires from: the deepest, at the front, the muzzle along -Z.
	var best: Node3D = null
	var depth := -1
	for n in gun.find_children("socket_muzzle*", "Node3D", true, false):
		var d := 0
		var cur: Node = n
		while cur != gun:
			d += 1
			cur = cur.get_parent()
		if d > depth:
			depth = d
			best = n
	var front := INF
	for n in placed.values():
		var mi: MeshInstance3D = (n as Node3D).find_child("Bricks", true, false)
		front = minf(front, (mi.global_transform * mi.get_aabb()).position.z)
	_ok("it fires from the muzzle's tip, the gun pointing -Z", best != null and best.get_parent() == placed.muzzle
			and absf(best.global_position.z - front) < 0.01, "%s at %.3f, front %.3f" % [best, best.global_position.z if best else 0.0, front])
	_ok("its length in the game", absf(float(out.length_m) - 35 * 4.0 * 4.0 / 1000.0) < 0.01, "%.3f m" % float(out.length_m))
	gun.queue_free()
	# Built the other way round (muzzle toward +x): it still comes out pointing -Z.
	_ws._new_build()
	_ws.muzzle_end = "-x"
	for spec in [["body", 3, [Vector2(20, 30), Vector2(40, 30), Vector2(40, 42), Vector2(20, 42)]],
			["barrel", 1, [Vector2(40, 35), Vector2(52, 35), Vector2(52, 38), Vector2(40, 38)]],
			["stock", 3, [Vector2(8, 30), Vector2(20, 30), Vector2(20, 40), Vector2(8, 40)]]]:
		_ws.select_part(_ws.part_names.find(spec[0]))
		_ws.part_width[spec[0]] = spec[1]
		_ws.sketch_region(spec[2])
	_ws.select_part(0)
	out = _ws.export_game(dir)
	recipe = {}
	for name in out.parts:
		var def := GunPartDef.new()
		def.id = StringName("probe2_" + name)
		def.slot = GunPartDef.SLOT_BY_SUFFIX[name]
		def.scene = ResourceLoader.load(out.parts[name], "", ResourceLoader.CACHE_MODE_IGNORE)
		recipe[def.slot] = def
	gun = GunAssembler.assemble(recipe)
	root.add_child(gun)
	var zs := {}
	for n in [gun] + gun.find_children("*", "Node3D", true, false):
		if n == gun or n.is_in_group(GunAssembler.PART_GROUP):
			var mi: MeshInstance3D = (n as Node3D).find_child("Bricks", true, false)
			zs[String(n.name)] = (mi.global_transform * mi.get_aabb()).get_center().z
	_ok("built muzzle toward +x, it is read off the build and still points -Z", _ws.muzzle_end == "+x"
			and float(zs.get("probe2_barrel", 0.0)) < float(zs.get("body", 0.0)) - 0.05
			and float(zs.get("probe2_stock", 0.0)) > float(zs.get("body", 0.0)) + 0.05, str(zs))
	# The readout's triangle count is what the exported gun draws (Docs/AssetWorkshop.md,
	# "Triangles"): its bricks' meshes plus every stud instance.
	var drawn := 0
	for n in gun.find_children("*", "", true, false):
		if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
			drawn += _ws._mesh_triangles((n as MeshInstance3D).mesh)
		elif n is MultiMeshInstance3D and (n as MultiMeshInstance3D).multimesh != null:
			var mm: MultiMesh = (n as MultiMeshInstance3D).multimesh
			drawn += _ws._mesh_triangles(mm.mesh) * mm.instance_count
	var stats: Dictionary = _ws.triangle_stats()
	_ok("the triangle readout is what the exported gun draws", drawn > 0 and int(stats.total) == drawn,
			"readout %d, exported %d" % [stats.total, drawn])
	_ws._tris = stats
	_ok("the readout shows it", _ws.ruler_text().contains("triangles: "), _ws.ruler_text())
	gun.queue_free()
	var pdir: String = _ws.export_print(false)
	_ok("print files go beside the other print files, outside the repository",
			pdir.ends_with("/brickcity-print/guns/" + _ws.slug(_ws.recipe.name if _ws.recipe.name != "untitled" else "gun"))
			and not pdir.begins_with(ProjectSettings.globalize_path("res://")), pdir)
	_ws.muzzle_end = "-x"
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir + f)


func _round9() -> void:
	# Nothing to remember: every key's action is in a menu, its key beside it (the tools
	# are on the rail).
	var texts := []
	var items := {}
	var row: Node = _ws._menu._spacer.get_parent()
	for c in row.get_children():
		if c is MenuButton:
			var pm := (c as MenuButton).get_popup()
			for i in pm.item_count:
				texts.append(pm.get_item_text(i))
				items[pm.get_item_text(i)] = pm.get_item_id(i)
	var missing := []
	for key in ["Alt 0", "Alt 1", "Alt 2", "Alt 3", "Alt M", "Alt S", "Alt Shift S", "Alt F", "Alt E", "Alt H",
			"Alt P", "Alt X", "Alt B", "PgUp", "PgDn", "Y", "Shift Y", "J", "O", "P", "N", "F2", "F3", "F4",
			"F10", "F12", "Home", "End", "Shift Z", "R", "F", "T", "B", "G", ".", ","]:
		var found := false
		for t in texts:
			found = found or String(t).ends_with("      " + key)
		if not found:
			missing.append(key)
	var rail_keys := []
	for t in _ws.RAIL_TOOLS:
		rail_keys.append(t[2])
	_ok("every key's action is in a menu", missing.is_empty(), str(missing))
	_ok("and every tool's on the rail", rail_keys.has("Alt D") and rail_keys.has("Alt V") and rail_keys.has("Alt U") and rail_keys.has("Alt G")
			and rail_keys.has("K") and rail_keys.has("L"), str(rail_keys))
	var pick := func(label: String) -> void:
		for t in items:
			if String(t).begins_with(label):
				_ws._on_asset_menu(items[t])
				return
	pick.call("Side view")
	_ok("a menu item does what its key does: Side view", _ws.view == 1)
	pick.call("3D view")
	pick.call("Next part")
	_ok("Next part", _ws.part_sel == 1, str(_ws.part_sel))
	_ws._part_pick.select(0)
	_ws._part_pick.item_selected.emit(0)
	_ok("the rail's part picker picks the part", _ws.part_sel == 0)


func _round10() -> void:
	# The shape brush is the Shapes tool's brush: a plain click lays, a plain right click carves.
	_ws._new_build()
	_ws.select_part(0)
	_ws.rail_pick("shape")
	_ws.shape_mode = "brush"
	_ws.brush3d = "cube"
	_ws.shape_size = 2
	_ws._cell = Vector3i(30, 20, 30)
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	_ok("Shapes as a brush takes a plain click", _ws._shape_brush_input(click))
	click = click.duplicate()
	click.pressed = false
	_ws._shape_brush_input(click)
	_ok("and lays the shape: 2 studs by 5 plates by 2", _volume() == 2 * 5 * 2, "%d cells" % _volume())
	_ws.shape_mode = "drag"
	click = click.duplicate()
	click.pressed = true
	_ok("set to drag a box, a plain click is the drag's", not _ws._shape_brush_input(click))
	_ws.rail_pick("place")


func _brush(button: MouseButton, cells: Array) -> void:
	# A shape-brush stroke: pressed on the first cell, dragged over the rest, let go.
	_ws._cell = cells[0]
	var e := InputEventMouseButton.new()
	e.button_index = button
	e.pressed = true
	_ws._shape_brush_input(e)
	for c in cells.slice(1):
		_ws._cell = c
		_ws._shape_brush_input(InputEventMouseMotion.new())
	e = e.duplicate()
	e.pressed = false
	_ws._shape_brush_input(e)


func _form() -> void:
	# The shape brush lays into the part's form (Docs/AssetWorkshop.md, "The form"): a
	# stroke is kept with the part, its bricks are the part's sketch bricks, so the part can
	# be laid again from what was drawn -- what the size and curve sliders will do.
	_ws._new_build()
	_ws.select_part(_ws.part_names.find("body"))
	_ws.rail_pick("shape")
	_ws.shape_mode = "brush"
	_ws.brush3d = "cube"
	_ws.shape_size = 2
	_brush(MOUSE_BUTTON_LEFT, [Vector3i(30, 20, 30), Vector3i(33, 20, 30)])
	var solids := []
	for k in _ws.sketches:
		if _ws.sketches[k].has("solid"):
			solids.append(_ws.sketches[k])
	_ok("a brush stroke is kept in the part's form, one entry, a stamp a centre",
			solids.size() == 1 and (solids[0].solid.at as Array).size() == 2 and solids[0].part == "body", str(solids))
	_ok("and filled: two cubes of 2 x 5 plates x 2", _volume() == 40, "%d cells" % _volume())
	_ok("its bricks are the form's", (_ws.part_bricks.get("body", []) as Array).size() == _ws.recipe.size()
			and _ws.recipe.size() > 0, "%d listed, %d laid" % [(_ws.part_bricks.get("body", []) as Array).size(), _ws.recipe.size()])
	_ws._undo()
	var left := 0
	for k in _ws.sketches:
		left += 1
	_ok("one Z takes the stroke and its bricks", _volume() == 0 and left == 0, "%d cells, %d sketches" % [_volume(), left])
	_ws.redo()
	_ok("shift Z puts them back", _volume() == 40 and _ws.sketches.size() == 1, "%d cells" % _volume())
	# A sketch and a shape in one part, and a carve through both.
	_ws.rail_pick("sketch")
	_ws.work_plane = "side"
	_ws.work_depth = 31.0
	_ws.part_width["body"] = 2
	_ws.sketch_region([Vector2(20, 20), Vector2(30, 20), Vector2(30, 25), Vector2(20, 25)])
	var both := _volume()
	var want := {}
	for c in _ws.brush_shape_cells("cube", Vector3i(30, 20, 30), 2).keys() + _ws.brush_shape_cells("cube", Vector3i(33, 20, 30), 2).keys():
		want[c] = true
	for x in range(20, 30):
		for y in range(20, 25):
			for z in [30, 31]:
				want[Vector3i(x, y, z)] = true
	var got := 0
	for c in want:
		if _ws.world.is_solid(_ws.chunk, c):
			got += 1
	var form: int = _ws.part_volume(_ws.part_sketches("body")).size()
	_ok("a sketch beside it adds to the same part", form == want.size() and got == want.size(),
			"form %d, filled %d, wanted %d" % [form, got, want.size()])
	_ws.rail_pick("shape")
	_ws.shape_mode = "brush"
	_ws.brush3d = "cube"
	_ws.shape_size = 2
	_brush(MOUSE_BUTTON_RIGHT, [Vector3i(25, 22, 31)])
	var carved := 0
	for c in _ws.brush_shape_cells("cube", Vector3i(25, 22, 31), 2):
		if c.x >= 20 and c.x < 30 and c.y >= 20 and c.y < 25 and c.z >= 30 and c.z < 32:
			carved += 1
	_ok("carving cuts the part's form, the sketch and the stamp kept", _volume() == both - carved and carved > 0
			and _ws.sketches.size() == 3, "%d cells, %d carved, %d entries" % [_volume(), carved, _ws.sketches.size()])
	var vol: Dictionary = _ws.part_volume(_ws.part_sketches("body"))
	var filled := 0
	for c in vol:
		if _ws.world.is_solid(_ws.chunk, c):
			filled += 1
	var stray := 0
	for k in _ws.recipe.size():
		var arch := String(_ws.recipe.part_of(k))
		if not (arch.begins_with("brick_") or arch.begins_with("plate_")):
			continue
		var size := BrickPalette.size_of(arch)
		for dx in size.x:
			for dy in size.y:
				for dz in size.z:
					if not vol.has(_ws.recipe.cell_of(k) + Vector3i(dx, dy, dz)):
						stray += 1
	_ok("the bricks laid are the form: all of it filled, no plain brick outside it", filled == vol.size() and stray == 0,
			"form %d, filled %d, stray %d" % [vol.size(), filled, stray])
	_ws._undo()
	_ok("one Z fills the carve", _volume() == both, "%d cells" % _volume())
	# Kept with the gun: saved and opened back, the form lays the same bricks.
	_ws._store_asset_meta()
	_ws._builds_dir = "user://_probe_guns/"
	var path: String = _ws._save_as("Probe Form")
	_ws._new_build()
	var opened: bool = _ws._open_path(path)
	var back: int = _ws.part_volume(_ws.part_sketches("body")).size()
	_ok("opened back: the stroke is in the form", opened and _ws.sketches.size() == 2 and back == want.size(),
			"opened %s, %d entries, form %d of %d" % [opened, _ws.sketches.size(), back, want.size()])
	DirAccess.remove_absolute(path)
	_ws._builds_dir = BuildRecipe.player_dir()
	_ws.rail_pick("place")


func _form_filled(part: String) -> Array:
	# [the part's form cells, how many of them have a brick, plain-brick cells outside it]
	var vol: Dictionary = _ws.part_volume(_ws.part_sketches(part))
	var filled := 0
	for c in vol:
		if _ws.world.is_solid(_ws.chunk, c):
			filled += 1
	var stray := 0
	var tag: int = _ws.part_names.find(part)
	for k in _ws.recipe.size():
		var arch := String(_ws.recipe.part_of(k))
		if _ws.part_of[k] != tag or not (arch.begins_with("brick_") or arch.begins_with("plate_")):
			continue
		var size := BrickPalette.size_of(arch)
		for dx in size.x:
			for dy in size.y:
				for dz in size.z:
					if not vol.has(_ws.recipe.cell_of(k) + Vector3i(dx, dy, dz)):
						stray += 1
	return [vol.size(), filled, stray]


func _resize() -> void:
	# The size slider: the block-out scaled and every part laid again from its form, as one
	# undo (Docs/AssetWorkshop.md, "The form, stage 2").
	_ws._new_build()
	_ws.select_part(_ws.part_names.find("body"))
	_ws.rail_pick("sketch")
	_ws.work_plane = "side"
	_ws.work_depth = 31.0
	_ws.part_width["body"] = 2
	_ws.sketch_region([Vector2(20, 20), Vector2(30, 20), Vector2(30, 25), Vector2(20, 25)])
	_ws.select_part(_ws.part_names.find("grip"))
	_ws.rail_pick("shape")
	_ws.shape_mode = "brush"
	_ws.brush3d = "cube"
	_ws.shape_size = 2
	_brush(MOUSE_BUTTON_LEFT, [Vector3i(26, 28, 31)])
	var keys_before: Array = _ws.sketches.keys()
	keys_before.sort()
	var body0: Array = _form_filled("body")
	var grip0: Array = _form_filled("grip")
	var box0: Array = _ws._box.duplicate()
	_ok("resized x2: done", _ws.scale_form(2.0))
	var body2: Array = _form_filled("body")
	var grip2: Array = _form_filled("grip")
	_ok("the sketched part is eight times the cells, and all of it laid", body2[0] == body0[0] * 8
			and body2[1] == body2[0] and body2[2] == 0, "%s -> %s" % [str(body0), str(body2)])
	_ok("the shape too: twice the size", grip2[0] == grip0[0] * 8 and grip2[1] == grip2[0] and grip2[2] == 0,
			"%s -> %s" % [str(grip0), str(grip2)])
	_ok("the parts keep their sketches, one each", _ws.sketches.size() == keys_before.size(), str(_ws.sketches.keys()))
	_ws._undo()
	var keys_after: Array = _ws.sketches.keys()
	keys_after.sort()
	_ok("one Z: the old size, sketches and bricks", keys_after == keys_before and _form_filled("body") == body0
			and _form_filled("grip") == grip0, "%s %s" % [str(keys_after), str(_form_filled("body"))])
	_ws.redo()
	_ok("shift Z: big again", _form_filled("body") == body2, str(_form_filled("body")))
	var n: int = _ws.recipe.size()
	_ok("too big for the build area: refused, nothing changed", not _ws.scale_form(200.0) and _ws.recipe.size() == n
			and _form_filled("body") == body2)
	_ws.scale_form(0.5)
	_ok("and halved: back to the first size", _form_filled("body") == body0 and _form_filled("grip") == grip0,
			"%s %s" % [str(_form_filled("body")), str(_form_filled("grip"))])
	_ws.rail_pick("place")


func _pieces_of(kind: String) -> int:
	var n := 0
	for k in _ws.recipe.size():
		if String(_ws.recipe.part_of(k)).begins_with(kind):
			n += 1
	return n


func _curves() -> void:
	# The curve slider: every part laid again from its form with more or fewer slopes and
	# curves, as one undo, the level with it (Docs/AssetWorkshop.md, "The form, stage 3").
	_ws._new_build()
	_ws.select_part(_ws.part_names.find("body"))
	_ws.rail_pick("sketch")
	_ws.work_plane = "side"
	_ws.work_depth = 31.0
	_ws.part_width["body"] = 2
	_ws.curve_level = 2
	# An end that rounds over (its last column a plate lower), and a ramp climbing two plates
	# a stud: a curve's and a slope's profiles.
	_ws.sketch_region([Vector2(20, 20), Vector2(30, 20), Vector2(30, 23), Vector2(29, 23), Vector2(29, 24),
			Vector2(20, 24)])
	_ws.sketch_region([Vector2(40, 20), Vector2(48, 20), Vector2(48, 28), Vector2(44, 28)])
	var full: int = _form_filled("body")[0]
	var slopes2 := _pieces_of("slope")
	var curves2 := _pieces_of("curve")
	_ok("slopes and curves (2): both", slopes2 > 0 and curves2 > 0, "%d slopes, %d curves" % [slopes2, curves2])
	_ws.set_curves(0)
	_ok("steps only (0): none, and the form still filled", _pieces_of("slope") == 0 and _pieces_of("curve") == 0
			and _form_filled("body")[1] == full, "%d slopes, %d curves, %s" % [_pieces_of("slope"), _pieces_of("curve"), str(_form_filled("body"))])
	_ws.set_curves(1)
	_ok("slopes (1): slopes, no curves", _pieces_of("slope") > 0 and _pieces_of("curve") == 0,
			"%d slopes, %d curves" % [_pieces_of("slope"), _pieces_of("curve")])
	_ws._undo()
	_ok("one Z: steps again, the level with them", _pieces_of("slope") == 0 and _ws.curve_level == 0,
			"%d slopes, level %d" % [_pieces_of("slope"), _ws.curve_level])
	_ws.redo()
	_ok("shift Z: slopes again", _pieces_of("slope") > 0 and _ws.curve_level == 1)
	# A ball from the shape brush has no sketch view to be fitted from: at 3 it is fitted
	# from the side and the front.
	_ws._new_build()
	_ws.set_curves(2)
	_ws.select_part(_ws.part_names.find("body"))
	_ws.rail_pick("shape")
	_ws.shape_mode = "brush"
	_ws.brush3d = "ball"
	_ws.shape_size = 8
	_brush(MOUSE_BUTTON_LEFT, [Vector3i(30, 30, 30)])
	var ball2 := _pieces_of("slope") + _pieces_of("curve")
	_ws.set_curves(3)
	var ball3 := _pieces_of("slope") + _pieces_of("curve")
	_ok("a brushed ball gets slopes and curves from the side and front (3)", ball2 == 0 and ball3 > 0,
			"%d -> %d" % [ball2, ball3])
	_ok("and is still all filled", _form_filled("body")[1] == _form_filled("body")[0], str(_form_filled("body")))
	_ws.set_curves(2)
	_ws.rail_pick("place")


func _sideways() -> void:
	# Bricks built sideways (in a turned grid) go out with the rest: Export to game meshes
	# them where they are, the triangle count counts them, the print sheet turns them
	# (Docs/AssetWorkshop.md, "Sideways bricks go out too").
	_ws._new_build()
	_ws.select_part(_ws.part_names.find("body"))
	_ok("a 2x4 laid upright", _ws.place_named(BrickPalette.variant_name("brick_2x4", 0, false), Vector3i(500, 30, 500)))
	var flat: Dictionary = _ws.triangle_stats()
	# A 1x1 plate on the brick's -z side, laid in the grid whose up is -z.
	var af := -1
	for k in _ws.asm.frames.size():
		if _ws.FRAME_UPS[k] == Vector3(0, 0, -1):
			af = k
	var f0: Transform3D = _ws.world.get_chunk_transform(_ws.asm.frames[0])
	var at: Vector3 = f0 * Vector3(501.5 * BrickPalette.STUD_M, 31.5 * BrickPalette.PLATE_M, 500.0 * BrickPalette.STUD_M - 0.002)
	var cell: Vector3i = _ws._cell_in(_ws.asm.frames[af], at)
	_ok("a plate laid in the sideways grid", af > 0 and _ws.place_named("plate_1x1", cell, -1, -1, af)
			and _ws._brick_frame(_ws.recipe.size() - 1) == af, "frame %d cell %v" % [af, cell])
	var side: int = _ws.recipe.size() - 1
	var box: AABB = _ws._brick_box(side)
	_ok("it sits on the brick's side, a plate out", absf(box.end.z - 500.0 * BrickPalette.STUD_M) < 1e-3
			and absf(box.size.z - BrickPalette.PLATE_M) < 1e-3, str(box))
	var stats: Dictionary = _ws.triangle_stats()
	_ok("the triangle count has it", int(stats.total) > int(flat.total), "%d -> %d" % [flat.total, stats.total])
	var dir := "user://_probe_gun_side/"
	var out: Dictionary = _ws.export_game(dir)
	var scene: PackedScene = ResourceLoader.load(out.parts.body, "", ResourceLoader.CACHE_MODE_IGNORE)
	var body: Node3D = scene.instantiate()
	var drawn := 0
	var sideways: MeshInstance3D = null
	for n in body.find_children("*", "", true, false):
		if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
			drawn += _ws._mesh_triangles((n as MeshInstance3D).mesh)
			if String(n.name).begins_with("Bricks") and n.name != "Bricks":
				sideways = n
		elif n is MultiMeshInstance3D and (n as MultiMeshInstance3D).multimesh != null:
			var mm: MultiMesh = (n as MultiMeshInstance3D).multimesh
			drawn += _ws._mesh_triangles(mm.mesh) * mm.instance_count
	_ok("exported: a mesh of its own, and the count is what it draws", sideways != null and drawn == int(stats.total),
			"drawn %d, counted %d" % [drawn, stats.total])
	if sideways != null:
		var mid: Vector3 = sideways.transform * sideways.get_aabb().get_center()
		_ok("where it was built", mid.distance_to(box.get_center()) < 0.01, "%v vs %v" % [mid, box.get_center()])
	body.free()
	for fname in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir + fname)
	var sheet: Dictionary = _ws.export_sheet()
	var spec: Dictionary = {}
	for ps in sheet.parts:
		if ps.name == "body":
			spec = ps
	var turned := (spec.get("bricks", []) as Array).filter(func(b: Dictionary) -> bool: return b.has("turn"))
	_ok("the print sheet turns it, its stud with it", turned.size() == 1 and (spec.get("studs_extra", []) as Array).size() == 1
			and absf(float(turned[0].turn[1][1]) + 1.0) < 1e-3, str(turned))


func _shells() -> void:
	# A shell: the part's form sampled finer than the grid and wrapped in one smooth closed
	# surface, its bricks the form shrunk by the thickness (Docs/AssetWorkshop.md, "Shells").
	_ws._new_build()
	_ws.select_part(_ws.part_names.find("body"))
	_ws.rail_pick("sketch")
	_ws.work_plane = "side"
	_ws.work_depth = 31.0
	_ws.part_width["body"] = 4
	_ws.sketch_region([Vector2(20, 20), Vector2(32, 20), Vector2(32, 30), Vector2(26, 34), Vector2(20, 30)])
	var bare: Array = _form_filled("body")
	var bricks_bare: int = _ws.recipe.size()
	_ws.set_shell("body", {"thick": 0.5, "res": 2})
	var mi: MeshInstance3D = _ws._shell_nodes.get("body")
	_ok("a shell on the part: one mesh", mi != null and int(_ws._shell_tris.get("body", 0)) > 0,
			str(_ws._shell_tris))
	if mi != null:
		var arr: Array = mi.mesh.surface_get_arrays(0)
		var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
		# Corners at one place are one vertex (a hard edge gives each its own normal).
		var first := {}
		var welded := PackedInt32Array()
		for i in idx:
			var key: Vector3 = ((arr[Mesh.ARRAY_VERTEX] as PackedVector3Array)[i] * 1e6).round()
			if not first.has(key):
				first[key] = first.size()
			welded.append(int(first[key]))
		idx = welded
		var edges := {}
		var twice := true
		for t in range(0, idx.size(), 3):
			for k in 3:
				var e := Vector2i(idx[t + k], idx[t + (k + 1) % 3])
				twice = twice and not edges.has(e)
				edges[e] = true
		for e: Vector2i in edges:
			twice = twice and edges.has(Vector2i(e.y, e.x))
		_ok("closed: every edge twice, once each way", twice)
		var box: AABB = mi.transform * mi.get_aabb()
		var want := AABB(Vector3(20, 20, 29) * _ws.CELL_M, Vector3(12, 14, 4) * _ws.CELL_M)
		_ok("the size of the form (within a sample)", box.position.distance_to(want.position) < BrickPalette.STUD_M * 0.6
				and box.size.distance_to(want.size) < BrickPalette.STUD_M * 1.2, "%s vs %s" % [box, want])
	var core_cells: Dictionary = _ws._part_vol.get("body", {})
	var core_filled := 0
	for c in core_cells:
		if _ws.world.is_solid(_ws.chunk, c):
			core_filled += 1
	var inside := true
	var full: Dictionary = _ws.part_volume(_ws.part_sketches("body"))
	for k in _ws.recipe.size():
		inside = inside and full.has(_ws.recipe.cell_of(k))
	_ok("its bricks: fewer, all inside the form", _ws.recipe.size() > 0 and _ws.recipe.size() < bricks_bare
			and core_filled == core_cells.size() and core_cells.size() > 0 and inside,
			"%d -> %d bricks, core %d of %d filled" % [bricks_bare, _ws.recipe.size(), core_filled, core_cells.size()])
	var stats: Dictionary = _ws.triangle_stats()
	_ok("counted: the shell, not the bricks it covers", int(stats.parts.body.shell) == int(_ws._shell_tris.body)
			and int(stats.parts.body.studs) == 0, str(stats.parts.body))
	var dir := "user://_probe_gun_shell/"
	var out: Dictionary = _ws.export_game(dir)
	var body: Node3D = (ResourceLoader.load(out.parts.body, "", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene).instantiate()
	var drawn := 0
	for n in body.find_children("*", "", true, false):
		if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
			drawn += _ws._mesh_triangles((n as MeshInstance3D).mesh)
		elif n is MultiMeshInstance3D and (n as MultiMeshInstance3D).multimesh != null:
			var mm: MultiMesh = (n as MultiMeshInstance3D).multimesh
			drawn += _ws._mesh_triangles(mm.mesh) * mm.instance_count
	_ok("exported: the shell, and the count is what it draws", body.find_child("Shell", true, false) != null
			and drawn == int(stats.total), "drawn %d, counted %d" % [drawn, stats.total])
	body.free()
	for fname in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir + fname)
	var sheet: Dictionary = _ws.export_sheet()
	var has_shell := false
	for ps in sheet.parts:
		if ps.name == "body":
			has_shell = ps.has("shell") and (ps.shell.verts as Array).size() > 0 and (ps.bricks as Array).is_empty()
	_ok("the print sheet has the shell, not the bricks inside it", has_shell)
	var thin: int = _ws.recipe.size()
	_ws.set_shell("body", {"thick": 1.5, "res": 2})
	_ok("thicker: fewer bricks inside", _ws.recipe.size() < thin, "%d -> %d" % [thin, _ws.recipe.size()])
	_ws._undo()
	_ok("one Z: the thin shell back", _ws.recipe.size() == thin and float(_ws.shells.body.thick) == 0.5,
			"%d bricks, %s" % [_ws.recipe.size(), str(_ws.shells.get("body"))])
	_ws._undo()
	_ok("and again: no shell, every brick of the form back", not _ws.shells.has("body")
			and not _ws._shell_nodes.has("body") and _form_filled("body") == bare, str(_form_filled("body")))
	# Against another part: real bricks embedded where they meet, kept in the game and the
	# print -- the join, with its studs.
	_ws.select_part(_ws.part_names.find("barrel"))
	_ok("a barrel brick against the body's end", _ws.place_named(BrickPalette.variant_name("brick_1x2", 0, false),
			Vector3i(32, 21, 30)))
	_ws.select_part(_ws.part_names.find("body"))
	_ws.set_shell("body", {"thick": 0.5, "res": 2})
	var joins: Dictionary = _ws._shell_joins.get("body", {})
	var at_end := not joins.is_empty()
	for c in joins:
		at_end = at_end and c.x == 31
	var kept := 0
	for ps in _ws.export_sheet().parts:
		if ps.name == "body":
			kept = (ps.bricks as Array).size()
	_ok("the cells against it are embedded bricks, on the sheet with the shell", at_end and kept > 0,
			"%d join cells %s, %d bricks on the sheet" % [joins.size(), str(joins.keys().slice(0, 4)), kept])
	_ws.set_shell("body", null)
	_ws.rail_pick("place")


## The SDF block-out (Docs/AssetWorkshop.md, "The SDF block-out"): a stroke is in the
## field, not in bricks; one undo each; saved with the gun.
func _sculpt() -> void:
	_ws.rail_pick("sketch")
	_ok("the Sketch tool draws in 2D", _ws.sketch_draw != "sculpt" and _ws.rail_active() == "sketch"
			and not _ws._sculpt_box.visible and _ws._sketch2d_box.visible)
	_ws.rail_pick("sculpt")
	_ok("the Sculpt tool sculpts in 3D, its own panel", _ws.sketch_draw == "sculpt" and _ws.rail_active() == "sculpt"
			and _ws._sculpt_box.visible and not _ws._sketch2d_box.visible)
	_ws.sculpt_clear()
	var bricks: int = _ws.recipe.size()
	var at: Vector3 = _ws.sculpt.to_sample(Vector3(10, 4, 8) * STUD)
	_ws._sculpt_op = SdfForm.ADD
	_ws.sculpt.form.begin_edit()
	_ws._sculpt_dab(at, at + Vector3(30, 0, 0))
	_ws._sculpt_record(_ws.sculpt.form.end_edit())
	_ok("a stroke makes surface, and no bricks", _ws.sculpt.triangles() > 0 and _ws.recipe.size() == bricks,
			"%d tris, %d -> %d bricks" % [_ws.sculpt.triangles(), bricks, _ws.recipe.size()])
	var cells: PackedInt32Array = _ws.sculpt.form.cells()
	_ok("labelled with the part", cells.size() > 0 and cells[3] == _ws.part_sel + 1, str(cells.slice(0, 5)))
	_ws._sculpt_op = SdfForm.REMOVE
	_ws.sculpt.form.begin_edit()
	_ws._sculpt_dab(at, at)
	_ws._sculpt_record(_ws.sculpt.form.end_edit())
	var carved: PackedInt32Array = _ws.sculpt.form.cells()
	_ok("a carve takes some away", carved.size() < cells.size())
	_ws._undo()
	_ok("one Z puts the carve back", _ws.sculpt.form.cells() == cells)
	_ws.redo()
	_ok("Shift Z carves again", _ws.sculpt.form.cells() == carved)
	var meta: Dictionary = _ws.recipe.meta.asset.sdf
	var f := SdfForm.new()
	var raw := Marshalls.base64_to_raw(String(meta.data)).decompress(int(meta.size), FileAccess.COMPRESSION_ZSTD)
	_ok("saved with the gun", f.from_bytes(raw) and f.cells() == carved)
	_ws.sculpt_scale(2.0)
	_ok("the size slider scales it", _ws.sculpt.form.cells().size() > carved.size() * 5,
			"%d -> %d" % [carved.size() / 5, _ws.sculpt.form.cells().size() / 5])
	_ws._undo()
	_ok("one undo", _ws.sculpt.form.cells() == carved)
	# A guide model made solid.
	_ws.sculpt_clear()
	var holder := Node3D.new()
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(4, 2, 2) * STUD
	mi.mesh = bm
	mi.position = Vector3(20, 3, 20) * STUD
	holder.add_child(mi)
	_ws.add_child(holder)
	_ws.guides.append({"path": "", "real_mm": 1.0, "offset": Vector3.ZERO, "turn": 0, "opacity": 0.35,
			"node": holder})
	_ok("a model goes into the part as SDF", _ws.sculpt_model_into(_ws.guides.size() - 1, SdfForm.ADD) == 1)
	var n: int = _ws.sculpt.form.cells().size() / 5
	_ok("a 4 x 2 x 2-stud box is about 4 x 5 x 2 cells", n >= 30 and n <= 50, str(n))
	_ws.sculpt_model_into(_ws.guides.size() - 1, SdfForm.REMOVE)
	_ok("and carves it out again", _ws.sculpt.form.cells().is_empty())
	_ws._undo()
	_ok("one undo puts it back", _ws.sculpt.form.cells().size() / 5 == n)
	_ws.guides.pop_back()
	holder.queue_free()
	_ws.sculpt_clear()
	_convert()
	_convert_plain()
	_stamp_box()
	_lathe()
	_flatten()
	_placed_model()
	_size_and_view()
	_ws.rail_pick("place")


## Convert and back: zones to bricks, the rest to each part's custom piece over hidden
## bricks; brick edits back into the field 1:1.
func _convert() -> void:
	_ws._reset_space()
	_ws.rail_pick("sculpt")
	var body: int = _ws.part_names.find("body")
	var barrel: int = _ws.part_names.find("barrel")
	var at: Vector3 = _ws.sculpt.to_sample(Vector3(30, 10, 30) * STUD)
	_ws.sculpt.form.begin_edit()
	_ws._sculpt_op = SdfForm.ADD
	_ws.select_part(body)
	_ws.sculpt_radius = 1.5
	_ws._sculpt_dab(at, at + Vector3(40, 0, 0))
	_ws.select_part(barrel)
	_ws.sculpt_radius = 0.8
	_ws._sculpt_dab(at + Vector3(40, 0, 0), at + Vector3(80, 0, 0))
	_ws._sculpt_op = SdfForm.MARK
	_ws.sculpt_radius = 12.0
	_ws._sculpt_dab(at, at + Vector3(80, 0, 0))   # all smooth...
	_ws._sculpt_op = SdfForm.UNMARK
	_ws.sculpt_radius = 3.0
	_ws._sculpt_dab(at + Vector3(70, 0, 0), at + Vector3(90, 0, 0))   # ...but the barrel's end: bricks
	_ws._sculpt_record(_ws.sculpt.form.end_edit())
	var cells: PackedInt32Array = _ws.sculpt.form.cells()
	var n_cells := cells.size() / 5
	var before: int = _ws.recipe.size()
	_ws.set_exploded(true)
	_ok("Explode is refused while sculpting", not _ws.exploded)
	_ws.sculpt_convert()
	_ok("converted: the block-out is hidden", _ws.sculpt_state == "bricks" and not _ws.sculpt.visible)
	var covered: int = _asset_cells().size()
	var hidden: int = _ws._sdf_shell.size() / 5
	_ok("every solid cell is a brick or inside a custom piece", covered == n_cells and hidden > 0,
			"%d cells, %d covered, %d by pieces alone (%d bricks before)" % [n_cells, covered, hidden, before])
	_ok("both parts have a custom piece", _ws.shells.has("body") and _ws.shells.has("barrel")
			and int(_ws._shell_tris.get("body", 0)) > 0 and int(_ws._shell_tris.get("barrel", 0)) > 0,
			str(_ws._shell_tris))
	_ws.set_exploded(true)
	_ok("and works once converted", _ws.exploded)
	_ws.set_exploded(false)
	var zone_bricks := 0
	var shown := 0
	for ps in _ws.export_sheet().parts:
		if ps.name == "barrel":
			shown = (ps.bricks as Array).size()
	for i in range(0, cells.size(), 5):
		zone_bricks += 1 - cells[i + 4]   # not marked smooth
	_ok("the brick zone stays bricks on the sheet, the rest under the shell", shown > 0 and zone_bricks > 0,
			"%d barrel bricks on the sheet, %d zone cells" % [shown, zone_bricks])
	# Edit the bricks, then back to the SDF: exactly those edits show.
	var i0: int = _ws.recipe.size() - 1
	var gone_cell: Vector3i = _ws.recipe.cell_of(i0)
	_ws.take_brick(i0)
	_ws.select_part(body)
	var top := Vector3i(gone_cell.x, gone_cell.y + 20, gone_cell.z)
	_ok("a brick laid by hand", _ws.place_named(BrickPalette.variant_name("brick_1x1", 0, false), top))
	var want := _asset_cells()
	_ws.sculpt_to_sdf()
	var got: Dictionary = {}
	var sc: PackedInt32Array = _ws.sculpt.form.cells()
	for i in range(0, sc.size(), 5):
		got[Vector3i(sc[i], sc[i + 1], sc[i + 2])] = sc[i + 3]
	_ok("Edit as SDF: the field is the bricks, edits and all", got == want and _ws.sculpt.visible,
			"%d vs %d" % [got.size(), want.size()])
	_ok("and the bricks are put aside", _ws._brick_cell_list().is_empty() and not _ws._sdf_stash.is_empty())
	# New bricks take their part's colour, not the hotbar's.
	var used_colours := {}
	for s in _ws._sdf_stash:
		used_colours[int(s[4])] = true
	var keep_colour: int = _ws._colour
	var odd := 0
	while used_colours.has(odd):
		odd += 1
	_ws._colour = odd
	_ws.sculpt_convert()
	_ws._colour = keep_colour
	var hotbar_coloured := 0
	for i in _ws.recipe.size():
		hotbar_coloured += int(_ws.recipe.colour_of(i) == odd)
	_ok("Convert colours new bricks by their part, not the hotbar", hotbar_coloured == 0,
			"%d bricks in the hotbar's colour" % hotbar_coloured)
	var again := _asset_cells()
	var bl: PackedInt32Array = _ws._brick_cell_list()
	_ok("converted again: the same cells", again == want, "%d vs %d" % [again.size(), want.size()])
	_ws._undo()
	_ok("one Z: back to sculpting", _ws.sculpt_state == "sdf" and _ws._brick_cell_list().is_empty())
	_ws.redo()
	_ok("Shift Z: converted again", _ws.sculpt_state == "bricks" and _ws._brick_cell_list().size() == bl.size())
	# A piece's look: fewer triangles, one undo.
	var fine := int(_ws._shell_tris.get("body", 0))
	_ws.sculpt_piece_detail("body", 300)
	var coarse := int(_ws._shell_tris.get("body", 0))
	_ws._undo()
	_ok("a piece's detail slider, and undo", coarse < fine and int(_ws._shell_tris.get("body", 0)) == fine,
			"%d -> %d -> %d" % [fine, coarse, int(_ws._shell_tris.get("body", 0))])


## Nothing marked smooth: Convert makes it all bricks, no custom pieces.
func _convert_plain() -> void:
	_ws._reset_space()
	_ws.rail_pick("sculpt")
	var at: Vector3 = _ws.sculpt.to_sample(Vector3(30, 10, 30) * STUD)
	_ws.sculpt.form.begin_edit()
	_ws._sculpt_op = SdfForm.ADD
	_ws.select_part(_ws.part_names.find("body"))
	_ws.sculpt_radius = 1.5
	_ws._sculpt_dab(at, at + Vector3(30, 0, 0))
	_ws._sculpt_record(_ws.sculpt.form.end_edit())
	var n: int = _ws.sculpt.form.cells().size() / 5
	_ws.sculpt_convert()
	var sdf_pieces := 0
	for part in _ws.shells:
		sdf_pieces += int(_ws.shells[part].get("sdf", false))
	_ok("unmarked: Convert lays only bricks", sdf_pieces == 0 and _ws._sdf_shell.is_empty()
			and _ws._brick_cell_list().size() / 5 == n, "%d pieces, %d of %d cells bricks" % [sdf_pieces,
			_ws._brick_cell_list().size() / 5, n])
	var shaped := 0
	for i in _ws.recipe.size():
		shaped += int(BrickPalette.is_shaped(BrickPalette.part_of(_ws.recipe.part_of(i))))
	_ok("its rounded edges get slopes and curves", shaped > 0, "%d shaped of %d" % [shaped, _ws.recipe.size()])
	var first := _asset_cells()
	_ws.sculpt_to_sdf()
	_ws.sculpt_convert()
	_ok("and back and converted again: the same cells", _asset_cells() == first,
			"%d vs %d" % [_asset_cells().size(), first.size()])


## A lathe (Docs/AssetWorkshop.md, "SDF tools, round 3"): an axis, an outline clicked
## point by point, laid with a click on the last point; one undo; Escape drops one.
func _lathe() -> void:
	_ws._reset_space()
	_ws.rail_pick("sculpt")
	_ws.sculpt_mode = "stamp"
	_ws.sculpt_shape = "lathe"
	var z := 5.0 * 30
	_ws._sculpt_plane = Plane(Vector3.BACK, z)
	_ws._lathe_axis = [Vector3(50, 40, z), Vector3(100, 40, z)]
	_ws._lathe_op = SdfForm.ADD
	for p in [Vector3(50, 46, z), Vector3(80, 50, z), Vector3(100, 44, z)]:
		_ws.lathe_click(p)
	_ok("a lathe's outline is drawn point by point", _ws._lathe_pts.size() == 3 and _ws.sculpt.form.cells().is_empty())
	_ws.lathe_click(Vector3(100, 44.2, z))
	var cells: int = _ws.sculpt.form.cells().size() / 5
	_ok("a click on the last point lays it: round, fat in the middle", cells > 50 and _ws._lathe_axis.is_empty()
			and _ws.sculpt.form.sample(Vector3(80, 40 + 9, z)) < 0.0 and _ws.sculpt.form.sample(Vector3(80, 40, z + 9)) < 0.0
			and _ws.sculpt.form.sample(Vector3(52, 40 + 9, z)) > 0.0, str(cells))
	_ws._undo()
	_ok("one undo takes it off", _ws.sculpt.form.cells().is_empty())
	_ws._lathe_axis = [Vector3(50, 40, z), Vector3(100, 40, z)]
	_ws.lathe_click(Vector3(60, 45, z))
	var esc := InputEventKey.new()
	esc.keycode = KEY_ESCAPE
	esc.pressed = true
	_ok("Escape drops a lathe being drawn", _ws._lathe_key(esc) and _ws._lathe_axis.is_empty()
			and _ws.sculpt.form.cells().is_empty())
	_ws.sculpt_shape = "box"
	_ws.sculpt_mode = "shape"


## A model read as one mesh where it is drawn (Docs/AssetWorkshop.md, "SDF tools, round 4"):
## a skinned mesh posed by its skeleton -- an armature at 1/100 with its bone a hundred
## times over draws real size, and so must the mesh -- and a plain one by its nodes.
func _flatten() -> void:
	var root := Node3D.new()
	var sk := Skeleton3D.new()
	sk.scale = Vector3.ONE * 0.01
	root.add_child(sk)
	sk.add_bone("b")
	sk.set_bone_rest(0, Transform3D(Basis.from_scale(Vector3.ONE * 100.0), Vector3.ZERO))
	sk.reset_bone_poses()
	var arr := BoxMesh.new().get_mesh_arrays()
	var nv: int = (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	var bones := PackedInt32Array()
	var weights := PackedFloat32Array()
	for i in nv:
		bones.append_array([0, 0, 0, 0])
		weights.append_array([1.0, 0.0, 0.0, 0.0])
	arr[Mesh.ARRAY_BONES] = bones
	arr[Mesh.ARRAY_WEIGHTS] = weights
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	var mi := MeshInstance3D.new()
	mi.mesh = am
	var skin := Skin.new()
	skin.add_named_bind("b", Transform3D())
	mi.skin = skin
	sk.add_child(mi)
	mi.skeleton = NodePath("..")
	var plain := MeshInstance3D.new()
	plain.mesh = BoxMesh.new()
	plain.scale = Vector3(2, 1, 1)
	plain.position = Vector3(5, 0, 0)
	root.add_child(plain)
	var flat := ModelMesh.flatten(root)
	var bb := flat.get_aabb() if flat != null else AABB()
	# The skinned box: 1 m at the origin; the plain one: 2 m long at x = 5.
	_ok("a skinned mesh is read posed by its skeleton, a plain one by its nodes",
			bb.position.is_equal_approx(Vector3(-0.5, -0.5, -0.5)) and bb.end.is_equal_approx(Vector3(6, 0.5, 0.5)), str(bb))
	root.free()


## A placed model: on the grid at the class's length, moved by the gizmo and stamped again,
## one undo when laid, Escape leaves the field as it was.
func _placed_model() -> void:
	_ws._reset_space()
	_ws.rail_pick("sculpt")
	_ws.sculpt_clear()
	_ws.set_gun_class("smg")
	# A model longer across (z) than along: turned to lie along x.
	var bm := BoxMesh.new()
	bm.size = Vector3(0.2, 0.4, 2.0)
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, bm.get_mesh_arrays())
	var groups: int = _ws._edit_groups.size()
	_ok("a model is placed", _ws.place_mesh(am, "box.glb"))
	var s: Vector3 = _ws.placed_size()
	_ok("along x, as long as an SMG (53 studs)", absf(s.x - 53.25) < 0.01 and s.z < 6.0, str(s))
	var bb: AABB = _ws.size_box()
	_ok("standing on the plate, on the mirror plane", absf(bb.position.y - BrickPalette.PLATE_M) < 0.01
			and absf(bb.get_center().z - _ws.mirror_z * STUD) < 0.01, str(bb))
	var field := _field_box()
	_ok("and in the field where it stands", field.size != Vector3.ZERO and absf(field.size.x - bb.size.x) < STUD
			and absf(field.get_center().x - bb.get_center().x) < STUD, "%s vs %s" % [field, bb])
	# The gizmo's drags, snapped.
	_ws._gizmo_xf0 = _ws._placed.xf
	var turned: Transform3D = _ws.dragged_xf({"turn": [Vector3.UP, 0.2]}, false)
	var by := (turned.basis.orthonormalized() * (_ws._gizmo_xf0 as Transform3D).basis.orthonormalized().inverse()).get_euler().y
	_ok("a turn snaps to 15 degrees", is_equal_approx(by, deg_to_rad(15.0)), str(rad_to_deg(by)))
	var sized: Transform3D = _ws.dragged_xf({"size": 1.234}, false)
	_ok("a resize snaps to 1%", is_equal_approx(sized.basis.get_scale().x / (_ws._placed.xf as Transform3D).basis.get_scale().x, 1.23))
	_ws._placed.xf = _ws.dragged_xf({"move": Vector3(2.1 * STUD, 0, 0)}, false)
	_ws._stamp_placed()
	var moved := _field_box()
	_ok("a move snaps to a quarter stud, and the field follows", absf(moved.position.x - field.position.x - 2.0 * STUD) < 0.05,
			"%.3f studs" % ((moved.position.x - field.position.x) / STUD))
	_ok("nothing to undo while it is placed", _ws._edit_groups.size() == groups)
	var esc := InputEventKey.new()
	esc.keycode = KEY_ESCAPE
	esc.pressed = true
	_ok("Escape takes it back out", _ws._placed_key(esc) and _ws.placed_model().is_empty()
			and _ws.sculpt.form.cells().is_empty())
	_ws.place_mesh(am, "box.glb")
	_ws._gizmo_xf0 = _ws._placed.xf
	_ws._placed.xf = _ws.dragged_xf({"move": Vector3(0, 0, 3.0 * STUD)}, false)
	_ws._stamp_placed()
	_ws.model_op(SdfForm.ADD)
	var cells: PackedInt32Array = _ws.sculpt.form.cells()
	_ws.lay_model()
	_ok("laid: one undo, the field kept", _ws._edit_groups.size() == groups + 1 and _ws.sculpt.form.cells() == cells
			and not _ws._gizmo.visible)
	_ws._undo()
	_ok("one Z takes the model out", _ws.sculpt.form.cells().is_empty())
	_ws.redo()
	_ok("Shift Z puts it back", _ws.sculpt.form.cells() == cells)
	# The gizmo's handles under the mouse's ray.
	_ws.place_mesh(am, "box.glb")
	var g: ModelGizmo = _ws._gizmo
	g.scale = Vector3.ONE * 2.0
	var at: Vector3 = g.global_position
	_ok("the gizmo's arrow, ring and cube are picked by a ray", g.pick(at + Vector3(1.2, 0, 10), Vector3.FORWARD) == "move0"
			and g.pick(at + Vector3(1.018, 10, 1.018), Vector3.DOWN) == "turn1" and g.pick(at + Vector3(0, 0, 10), Vector3.FORWARD) == "size"
			and g.pick(at + Vector3(5, 5, 10), Vector3.FORWARD) == "",
			"%s %s %s" % [g.pick(at + Vector3(1.2, 0, 10), Vector3.FORWARD), g.pick(at + Vector3(1.018, 10, 1.018), Vector3.DOWN),
			g.pick(at + Vector3(0, 0, 10), Vector3.FORWARD)])
	_ws.drop_model()
	_ws.sculpt_clear()


## The field's box in workshop space.
func _field_box() -> AABB:
	var bb: AABB = _ws.sculpt.form.bounds()
	if bb.size == Vector3.ZERO:
		return AABB()
	return _ws.global_transform.affine_inverse() * _ws.sculpt.global_transform * bb


## The size marks and the game's view: the SMG's ruler 53 studs from the butt, the grip
## box, and the camera framing the gun as PlayerView does.
func _size_and_view() -> void:
	_ws._reset_space()
	_ws.rail_pick("sculpt")
	_ok("an SMG is 53.25 studs, a rifle 62.5, a pistol 13.5", is_equal_approx(_ws.class_studs("smg"), 53.25)
			and is_equal_approx(_ws.class_studs("rifle"), 62.5) and is_equal_approx(_ws.class_studs("pistol"), 13.5))
	var bm := BoxMesh.new()
	bm.size = Vector3(2.0, 0.4, 0.2)
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, bm.get_mesh_arrays())
	_ws.place_mesh(am, "box.glb")
	_ws.muzzle_end = "+x"
	_ws.draw_size_marks()
	var bb: AABB = _ws.size_box()
	var r: Vector2 = _ws.size_ruler()
	var labels: Array = _ws._size_labels.get_children().map(func(l: Node) -> String: return (l as Label3D).text)
	_ok("the ruler starts at the butt and marks the SMG's length", is_equal_approx(r.x, bb.position.x) and r.y > 0.0
			and labels.has("50") and labels.any(func(t: String) -> bool: return t.begins_with("SMG: 53.3 studs = 852 mm real, 213 mm print"))
			and labels.any(func(t: String) -> bool: return t.begins_with("grip:")), str(labels))
	_ws.flip_butt()
	_ok("turned, from the other end", is_equal_approx(_ws.size_ruler().x, bb.end.x) and _ws.size_ruler().y < 0.0)
	_ws.flip_butt()
	var was: Transform3D = _ws._camera.global_transform
	_ws.set_game_view(true)
	var k: float = bb.size.x / float(PlayerView.VIEW_LENGTH[&"smg"])
	var back_top := Vector3(bb.position.x, bb.end.y, bb.get_center().z)
	var seen: Vector3 = _ws._camera.global_transform.affine_inverse() * (_ws.global_transform * back_top)
	_ok("the game's view: the gun's back top at the hip pose, muzzle ahead", _ws.game_view_on
			and seen.is_equal_approx(PlayerView.HIP * k) and (-_ws._camera.global_transform.basis.z).is_equal_approx(Vector3.RIGHT),
			"%s vs %s" % [seen, PlayerView.HIP * k])
	var rmb := InputEventMouseButton.new()
	rmb.button_index = MOUSE_BUTTON_RIGHT
	rmb.pressed = true
	_ws._game_view_input(rmb)
	seen = _ws._camera.global_transform.affine_inverse() * (_ws.global_transform * back_top)
	_ok("RMB aims down the sights", _ws.game_view_ads and seen.is_equal_approx(PlayerView.ADS * k))
	_ws.set_game_view(false)
	_ok("and back to the camera as it was", not _ws.game_view_on and _ws._camera.global_transform.is_equal_approx(was))
	_ws.drop_model()
	_ws.sculpt_clear()


## A box stamp snapped to the grid: one undo, and Convert makes exactly its cells bricks.
func _stamp_box() -> void:
	_ws._reset_space()
	_ws.rail_pick("sculpt")
	_ws.sculpt_mode = "stamp"
	_ws.sculpt_shape = "box"
	_ws.sculpt_snap = true
	_ws.sculpt_radius = 1.0
	_ws.select_part(_ws.part_names.find("body"))
	var z := 5.0 * 30
	_ws._sculpt_plane = Plane(Vector3.BACK, z)
	# Off the grid a little each way: the snap puts the corners on cell corners.
	_ws._stamp_from = _ws._stamp_snap(Vector3(50.6, 40.3, z))
	_ws._stamp_to = _ws._stamp_snap(Vector3(69.7, 51.8, z))
	_ws.sculpt.form.begin_edit()
	_ws._lay_stamp(_ws._stamp_desc(), SdfForm.ADD)
	_ws._sculpt_record(_ws.sculpt.form.end_edit())
	var want := {}
	for x in range(10, 14):
		for y in range(20, 26):
			for zz in range(29, 31):
				want[Vector3i(x, y, zz)] = _ws.part_names.find("body") + 1
	var got := {}
	var sc: PackedInt32Array = _ws.sculpt.form.cells()
	for i in range(0, sc.size(), 5):
		got[Vector3i(sc[i], sc[i + 1], sc[i + 2])] = sc[i + 3]
	_ok("a box stamp snaps to the grid: its cells exactly", got == want, "%d vs %d cells" % [got.size(), want.size()])
	_ws._undo()
	_ok("one Z takes the stamp off", _ws.sculpt.form.cells().is_empty())
	_ws.redo()
	_ws.sculpt_convert()
	var shaped := 0
	for i in _ws.recipe.size():
		shaped += int(BrickPalette.is_shaped(BrickPalette.part_of(_ws.recipe.part_of(i))))
	_ok("converted: the box's bricks, no slopes", _asset_cells() == want and shaped == 0,
			"%d cells, %d shaped" % [_asset_cells().size(), shaped])
	_ws.sculpt_mode = "shape"


## The asset's cells after a Convert: its bricks', and those its custom pieces fill alone.
func _asset_cells() -> Dictionary:
	var out := {}
	for l in [_ws._brick_cell_list(), _ws._sdf_shell]:
		for i in range(0, l.size(), 5):
			out[Vector3i(l[i], l[i + 1], l[i + 2])] = l[i + 3]
	return out
