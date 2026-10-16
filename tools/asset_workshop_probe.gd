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
