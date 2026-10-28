extends SceneTree

## The building tools (Docs/BuildTools.md): shapes on the grid, courses staggered and
## aligned, kept shapes, cuts, undo, saving -- and the run and the rail the building
## workshop now shares with the asset workshop.
##
##     godot --headless --path . --script tools/build_tools_probe.gd

var _pass := 0
var _fail := 0
var _ws


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s" % what)
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _initialize() -> void:
	_shape_checks()
	_course_checks()
	_ws = load("res://scenes/workshop.tscn").instantiate()
	root.add_child(_ws)
	await process_frame
	await process_frame
	_ws._builds_dir = "user://_probe_builds/"
	_ws._save_path = "user://_probe_quick.json"
	_rail_checks()
	_run_checks()
	_kept_checks()
	_wall_checks()
	_sketch_checks()
	_opening_checks()
	_repeat_checks()
	_button_checks()
	_redo_checks()
	_mirror_checks()
	_house_checks()
	_pull_checks()
	_floor_plan_checks()
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


# ---------------------------------------------------------------------------

func _shape_checks() -> void:
	print("[probe] shapes on the grid")
	var a := Vector2i(0, 0)
	_ok("a 4 x 3 rectangle is 12 cells", BrickShapes.cells_2d("rect", a, Vector2i(3, 2)).size() == 12)
	_ok("a 6 x 5 hollow rectangle, rim 1, is its edge: 18 cells",
			BrickShapes.cells_2d("hollow", a, Vector2i(5, 4), 1).size() == 18)
	_ok("rim 2: 6 x 5 less 2 x 1", BrickShapes.cells_2d("hollow", a, Vector2i(5, 4), 2).size() == 28)
	var circle := BrickShapes.cells_2d("circle", a, Vector2i(8, 8))
	_ok("a circle 9 across: its middle, not its corners, about pi r squared",
			circle.has(Vector2i(4, 4)) and not circle.has(Vector2i(0, 0)) and absi(circle.size() - 64) <= 8,
			"%d cells" % circle.size())
	var ring := BrickShapes.cells_2d("ring", a, Vector2i(12, 12), 1)
	_ok("a ring is hollow", not ring.has(Vector2i(6, 6)) and ring.has(Vector2i(6, 0)))
	_ok("and joined edge to edge all round (one piece, four ways)", _pieces(ring) == 1, "%d pieces" % _pieces(ring))
	var tri := BrickShapes.cells_2d("triangle", a, Vector2i(8, 6))
	_ok("a triangle: wide where the drag began, a point at the far end",
			_row(tri, 0) == 9 and _row(tri, 6) <= 2 and _row(tri, 3) < 9, "rows %d %d %d" % [_row(tri, 0), _row(tri, 3), _row(tri, 6)])
	var tri2 := BrickShapes.cells_2d("triangle", Vector2i(0, 6), Vector2i(8, 0))
	_ok("dragged the other way, it points the other way", _row(tri2, 6) == 9 and _row(tri2, 0) <= 2)
	var line := BrickShapes.cells_2d("line", a, Vector2i(9, 0), 1)
	_ok("a line along a row is that row", line.size() == 10)
	var arch := BrickShapes.cells_2d("arch", a, Vector2i(3, 19), 1, BrickShapes.aspect("wall_x"))
	_ok("an arch in a wall: straight sides, a round top", _row(arch, 0) == 4 and _row(arch, 19) < 4,
			"bottom %d top %d" % [_row(arch, 0), _row(arch, 19)])
	var out := BrickShapes.outline_cells([[0, 0], [4, 0], [4, 3], [0, 3]])
	_ok("an outline 4 x 3 fills 12 cells", out.size() == 12)
	var wall := BrickShapes.solid_cells({"kind": "rect", "lie": "wall_x", "a": [2, 1], "b": [5, 9], "at": 7, "depth": 2})
	_ok("a wall stands in x and y, `depth` deep in z",
			wall.size() == 4 * 9 * 2 and wall.has(Vector3i(2, 1, 7)) and wall.has(Vector3i(5, 9, 8)))
	var wz := BrickShapes.solid_cells({"kind": "rect", "lie": "wall_z", "a": [2, 1], "b": [5, 9], "at": 7, "depth": 1})
	_ok("a wall the other way stands in z and y", wz.has(Vector3i(7, 1, 2)) and wz.has(Vector3i(7, 9, 5)))


func _pieces(cells: Dictionary) -> int:
	var seen := {}
	var n := 0
	for c in cells:
		if seen.has(c):
			continue
		n += 1
		var todo: Array = [c]
		seen[c] = true
		while not todo.is_empty():
			var p: Vector2i = todo.pop_back()
			for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				if cells.has(p + d) and not seen.has(p + d):
					seen[p + d] = true
					todo.append(p + d)
	return n


func _row(cells: Dictionary, v: int) -> int:
	var n := 0
	for c in cells:
		if c.y == v:
			n += 1
	return n


# ---------------------------------------------------------------------------

func _course_checks() -> void:
	print("[probe] courses of the held brick")
	var w := BrickWorld.new()
	var pal := TowerRecipe.bake_palette(w)
	var parts := BrickShapes.parts_for("brick_1x4_x", pal)
	var names := {}
	for p in parts:
		names[BrickPalette.part_of(String(p[0]))] = true
	_ok("a 1x4 lays 1x4s, 1x2s, 1x1s and plates of them", names.has("brick_1x4") and names.has("brick_1x2")
			and names.has("brick_1x1") and names.has("plate_1x4"), str(names.keys()))
	_ok("and nothing bigger than itself", not names.has("brick_2x4") and not names.has("brick_1x6"))
	_ok("the held brick first", BrickPalette.part_of(String(parts[0][0])) == "brick_1x4")
	# A straight wall 12 long, 3 courses.
	var cells := {}
	for x in 12:
		for y in 9:
			cells[Vector3i(x, y, 0)] = true
	var st := BrickShapes.pack_courses(cells, parts, true)
	_ok("staggered: every cell covered once", _covers(st, cells))
	var seams := _seams(st)
	_ok("staggered: no seam lines up with the one below (running bond)",
			_shared(seams[0], seams[1]) == 0 and _shared(seams[1], seams[2]) == 0, str(seams))
	_ok("staggered: mostly the held brick", _count(st, "brick_1x4") >= 6)
	var al := BrickShapes.pack_courses(cells, parts, false)
	var aseams := _seams(al)
	_ok("aligned: every cell covered once", _covers(al, cells))
	_ok("aligned: the seams run straight up (stack bond)", aseams[0] == aseams[1] and aseams[1] == aseams[2], str(aseams))
	# Four walls round a room: the corners take turns.
	var room := {}
	for c2 in BrickShapes.cells_2d("hollow", Vector2i(0, 0), Vector2i(7, 5), 1):
		for y in 6:
			room[Vector3i(c2.x, y, c2.y)] = true
	var rp := BrickShapes.pack_courses(room, parts, true)
	_ok("a hollow rectangle's walls: every cell covered", _covers(rp, room))
	var c0 := _along_at(rp, Vector3i(0, 0, 0))
	var c1 := _along_at(rp, Vector3i(0, 3, 0))
	_ok("staggered: the corner's brick runs one way, the next course's the other (interlocked)",
			c0 != "" and c1 != "" and c0 != c1, "%s then %s" % [c0, c1])
	# Height left over: plates.
	var odd := {}
	for x in 8:
		for y in 4:
			odd[Vector3i(x, y, 0)] = true
	var op := BrickShapes.pack_courses(odd, parts, true)
	_ok("4 plates tall: a course of bricks and one of plates", _covers(op, odd) and _count(op, "plate_") > 0)


## True if the bricks fill exactly `cells`, none overlapping.
func _covers(packed: Array, cells: Dictionary) -> bool:
	var got := {}
	for pc in packed:
		var size := BrickPalette.size_of(String(pc[0]))
		for dx in size.x:
			for dy in size.y:
				for dz in size.z:
					var c: Vector3i = pc[1] + Vector3i(dx, dy, dz)
					if got.has(c) or not cells.has(c):
						return false
					got[c] = true
	return got.size() == cells.size()


## Each course's seams along x (where a brick starts, past the wall's own start).
func _seams(packed: Array) -> Array:
	var out := [[], [], []]
	for pc in packed:
		var c: Vector3i = pc[1]
		@warning_ignore("integer_division")
		var k: int = c.y / 3
		if k < 3 and c.x > 0 and not (out[k] as Array).has(c.x):
			(out[k] as Array).append(c.x)
	for s in out:
		(s as Array).sort()
	return out


func _shared(a: Array, b: Array) -> int:
	var n := 0
	for x in a:
		if b.has(x):
			n += 1
	return n


func _count(packed: Array, prefix: String) -> int:
	var n := 0
	for pc in packed:
		if String(pc[0]).begins_with(prefix):
			n += 1
	return n


## "x" or "z": the way the brick covering `cell` runs, "" if none or square.
func _along_at(packed: Array, cell: Vector3i) -> String:
	for pc in packed:
		var size := BrickPalette.size_of(String(pc[0]))
		var at: Vector3i = pc[1]
		var d := cell - at
		if d.x >= 0 and d.y >= 0 and d.z >= 0 and d.x < size.x and d.y < size.y and d.z < size.z:
			return "" if size.x == size.z else ("x" if size.x > size.z else "z")
	return ""


# ---------------------------------------------------------------------------

func _hold(part: String) -> void:
	_ws._part_index = (_ws._parts() as Array).find(part)
	_ws._yaw = 0
	_ws._flip = false


func _rail_checks() -> void:
	print("[probe] the rail")
	var t: WorkshopTools = _ws._tools
	_ok("the building workshop has the rail", t != null and t.rail is ToolRail)
	_ok("with its tools, each with a pop-up and an icon", t.rail.buttons.size() == WorkshopTools.TOOLS.size()
			and (t.rail.buttons.values() as Array).all(func(b: Button) -> bool:
				return b.tooltip_text.length() > 20 and b.icon != null))
	t.pick("shape")
	_ok("a tool picked is the one lit", t.active() == "shape")
	t.pick("paint")
	_ok("Paint is the workshop's own brush", _ws._painting and t.active() == "paint")
	t.pick("place")
	_ok("Place puts the brush down", not _ws._painting and t.active() == "place")
	await process_frame
	_ok("the readout sits right of the rail", _ws._hud.position.x >= t.rail.position.x + t.rail.size.x)


func _run_checks() -> void:
	print("[probe] the run (moved down from the asset workshop)")
	_ws._new_build()
	_hold("plate_1x1")
	_ws._cell = Vector3i(20, 1, 20)
	_ws._update_ghost()
	_ws._place()
	_ws._begin_run()
	_ws._cell = Vector3i(21, 1, 20)
	_ws._update_ghost()
	_ws.run_step()
	_ok("a click held still lays one brick", _ws.recipe.size() == 1, "%d bricks" % _ws.recipe.size())
	_ws._run_moved = 40.0
	_ws._run_press_ms = Time.get_ticks_msec() - 1000
	_ws._run_last = Vector3i(20, 1, 20)
	for x in [21, 22, 23]:
		_ws._cell = Vector3i(x, 1, 20)
		_ws._update_ghost()
		_ws.run_step()
	_ws._run_on = false
	_ok("a held run lays a brick at each cell the ghost passes", _ws.recipe.size() == 4, "%d bricks" % _ws.recipe.size())


func _bricks(sh: Dictionary) -> Dictionary:
	var out := {}
	for b in sh.bricks:
		out["%s@%s" % [b[0], str(BuildRecipe.cell_from(b[1]))]] = true
	return out


func _kept_checks() -> void:
	print("[probe] kept shapes, cuts, undo, saving")
	_ws._new_build()
	var t: WorkshopTools = _ws._tools
	_hold("brick_1x4")
	t.tall = 9
	t.rim = 1
	t.staggered = true
	var f0: int = _ws.asm.frames[0]
	# A room: four walls, 12 x 8 studs, 3 bricks high, on the baseplate.
	var id := t.add_shape("hollow", "flat", Vector2i(4, 4), Vector2i(15, 11), 1)
	var sh := t.shape_of(id)
	var cells := BrickShapes.shape_cells(sh)
	var filled := 0
	for c in cells:
		if _ws.world.is_solid(f0, c):
			filled += 1
	_ok("a hollow rectangle 9 plates tall lays every cell of its walls", filled == cells.size() and cells.size() == 36 * 9,
			"%d of %d" % [filled, cells.size()])
	_ok("the shape keeps its bricks", (sh.bricks as Array).size() == _ws.recipe.size() and _ws.recipe.size() > 0)
	var fam := true
	for i in _ws.recipe.size():
		var p := BrickPalette.part_of(_ws.recipe.part_of(i))
		fam = fam and p in ["brick_1x4", "brick_1x2", "brick_1x1", "plate_1x4", "plate_1x2", "plate_1x1"]
	_ok("of the held brick and smaller ones of its kind", fam)
	_ok("one undo edit for the whole shape", _ws._edits == ["shape"], str(_ws._edits))
	# A hand-laid brick inside the doorway-to-be, and one elsewhere.
	_hold("plate_1x1")
	_ws._cell = Vector3i(9, 10, 2)
	_ws._update_ghost()
	_ws._place()
	var before := _bricks(t.shape_of(id))
	# A door, one click on the front wall (z = 4), from outside.
	var face := t.face_under(Vector3(9.5 * 0.35, 4 * 0.14, -3.0), Vector3(0, 0, 1))
	_ok("the face under a ray: the front wall, one stud deep", face.get("lie") == "wall_x" and int(face.get("at", -1)) == 4
			and int(face.get("depth", 0)) == 1, str(face))
	t.cut_kind = "door"
	var cut := t.preset_cut("door", face)
	_ok("a door stands on the wall's lowest course", int(cut.a[1]) == 1, str(cut))
	t.apply_cut(cut)
	var hole := BrickShapes.solid_cells(cut)
	var open := true
	for c in hole:
		open = open and not _ws.world.is_solid(f0, c)
	_ok("Cut: the doorway is open", open)
	var back_ok := true
	for x in range(4, 16):
		for y in range(1, 10):
			back_ok = back_ok and _ws.world.is_solid(f0, Vector3i(x, y, 11))
	_ok("and goes no further than the wall it was cut in (the back wall is whole)", back_ok)
	var after := _bricks(t.shape_of(id))
	var near: AABB = t._near_box(hole, t.shape_of(id), "wall_x")
	var far_kept := true
	var far_n := 0
	for k in before:
		var parts: PackedStringArray = String(k).split("@")
		var cs := String(parts[1]).trim_prefix("(").trim_suffix(")").split(",")
		var c := Vector3i(int(cs[0]), int(cs[1]), int(cs[2]))
		var size := BrickPalette.size_of(parts[0])
		if not AABB(Vector3(c), Vector3(size)).intersects(near):
			far_n += 1
			far_kept = far_kept and after.has(k)
	_ok("the rest of the wall keeps its bricks (%d far from the door)" % far_n, far_kept and far_n > 15)
	var rest := 0
	for c in BrickShapes.shape_cells(t.shape_of(id)):
		if _ws.world.is_solid(f0, c):
			rest += 1
	_ok("and every cell of the wall round the door is still filled",
			rest == BrickShapes.shape_cells(t.shape_of(id)).size())
	_ok("the shape remembers its cut", (t.shape_of(id).cuts as Array).size() == 1)
	_ok("the hand-laid brick in the doorway was taken up", _ws.find_brick("plate_1x1", Vector3i(9, 10, 2)) < 0
			or not hole.has(Vector3i(9, 10, 2)))
	# Saved and opened again.
	var back := BuildRecipe.from_dict(JSON.parse_string(JSON.stringify(_ws.recipe.to_dict())))
	var kept: Array = back.meta.get("shapes", [])
	_ok("saved: the shape and its cut go with the build", kept.size() == 1 and (kept[0].cuts as Array).size() == 1
			and (kept[0].bricks as Array).size() == (t.shape_of(id).bricks as Array).size())
	# Undo the cut: the wall is as it was.
	_ws._undo()
	_ok("undo the cut: the wall's bricks are as before", _bricks(t.shape_of(id)) == before)
	_ok("and its cut is gone", (t.shape_of(id).cuts as Array).is_empty())
	# Change it: a different bond, laid again whole, cuts kept.
	t.change_shape(id, {"bond": "align"})
	_ok("Select: aligned, laid again", String(t.shape_of(id).bond) == "align")
	_ws._undo()
	_ok("and undone", String(t.shape_of(id).bond) == "stagger" and _bricks(t.shape_of(id)) == before)
	# RMB on a shape's brick: no hand brick's undo is lost.
	var bricks_edits := (_ws._edits as Array).count("brick")
	var b0: Array = t.shape_of(id).bricks[0]
	var c0 := BuildRecipe.cell_from(b0[1])
	var size0 := BrickPalette.size_of(String(b0[0]))
	var mid := Vector3((c0.x + size0.x * 0.5) * 0.35, (c0.y + size0.y + 3) * 0.14, (c0.z + size0.z * 0.5) * 0.35)
	_ws._delete_ray(mid, Vector3.DOWN)
	_ok("RMB on a shape's brick takes it out of the shape, not a hand brick's undo",
			(_ws._edits as Array).count("brick") == bricks_edits and _bricks(t.shape_of(id)).size() == before.size() - 1,
			"%d brick edits, %d of %d" % [(_ws._edits as Array).count("brick"), _bricks(t.shape_of(id)).size(), before.size()])
	# Let go: the bricks stay, the shape is forgotten.
	var n: int = _ws.recipe.size()
	t.let_go(id)
	_ok("let go: the bricks stay, the shape is gone", _ws.recipe.size() == n and t.shape_of(id).is_empty())
	_ws._undo()
	_ok("and undone, it is a shape again", not t.shape_of(id).is_empty() and _ws.recipe.size() == n)
	t.delete_shape(id)
	_ok("delete: shape and bricks gone, the hand brick stays", t.shape_of(id).is_empty() and _ws.recipe.size() <= 1)
	_ws._undo()
	_ok("and undone", not t.shape_of(id).is_empty() and _ws.recipe.size() == n)
	# Undo all the way: nothing left.
	while _ws._undo():
		pass
	_ok("undo all the way back: an empty build", _ws.recipe.size() == 0 and t.shapes().is_empty(),
			"%d bricks, %d shapes" % [_ws.recipe.size(), t.shapes().size()])


func _wall_checks() -> void:
	print("[probe] standing shapes")
	_ws._new_build()
	var t: WorkshopTools = _ws._tools
	_hold("brick_1x2")
	t.thick = 1
	var f0: int = _ws.asm.frames[0]
	# A gable: a triangle standing on the baseplate, 15 studs wide.
	var id := t.add_shape("triangle", "wall_x", Vector2i(10, 1), Vector2i(24, 18), 20)
	var cells := BrickShapes.shape_cells(t.shape_of(id))
	var filled := 0
	for c in cells:
		if _ws.world.is_solid(f0, c):
			filled += 1
	_ok("a triangle wall lays its cells (%d of %d)" % [filled, cells.size()], filled >= cells.size() * 0.95 and filled > 50)
	# A round window cut right through it.
	t.apply_cut({"kind": "circle", "lie": "wall_x", "a": [15, 3], "b": [19, 13], "at": 20, "depth": 1})
	_ok("a round window cut out of it", not _ws.world.is_solid(f0, Vector3i(17, 8, 20)) and (t.shape_of(id).cuts as Array).size() == 1)
	_ok("the wall round it stands", _ws.world.is_solid(f0, Vector3i(12, 2, 20)))
	# A ring lying flat, 3 plates: a round platform's rim.
	_hold("brick_1x1")
	t.tall = 3
	var rid := t.add_shape("ring", "flat", Vector2i(2, 30), Vector2i(14, 42), 1)
	var rc := BrickShapes.shape_cells(t.shape_of(rid))
	var rf := 0
	for c in rc:
		if _ws.world.is_solid(f0, c):
			rf += 1
	_ok("a ring lying flat is laid", rf == rc.size() and rc.size() > 30, "%d of %d" % [rf, rc.size()])


func _sketch_checks() -> void:
	print("[probe] sketch: the asset workshop's pen, making kept shapes")
	var sq := SketchPen.region_cells([[4, 4], [12, 4], [12, 10], [4, 10]])
	_ok("the pen fills an outline 8 x 6 with 48 cells", sq.size() == 48)
	_ok("and a brush stroke round its path", SketchPen.region_cells(SketchPen.brush_entry([Vector2(5.5, 5.5)], 1, true, "top")).size() == 9)
	_ok("BrickShapes fills an outline with the same code", BrickShapes.outline_cells([[4, 4], [12, 4], [12, 10], [4, 10]]) == sq)
	_ws._new_build()
	var t: WorkshopTools = _ws._tools
	var f0: int = _ws.asm.frames[0]
	_hold("brick_1x2")
	t.pick("sketch")
	_ok("Sketch is on the rail", t.active() == "sketch" and t.rail.buttons.has("sketch"))
	t.tall = 3
	t.pen.draw = "polygon"
	t._sk = {"lie": "flat", "at": 1}
	for q in [Vector2(4, 4), Vector2(12, 4), Vector2(12, 10)]:
		t.pen.polygon_click(q, false, false)
	_ok("a polygon closes on its first corner", t.pen.polygon_click(Vector2(4.2, 4.1), false, false))
	t.pen.points.clear()
	t.pen.out = false
	for q in [Vector2(4, 4), Vector2(12, 4), Vector2(12, 10), Vector2(4, 10)]:
		t.pen.polygon_click(q, false, false)
	t._sketch_commit()
	_ok("a stroke on a level goes into the plan, nothing laid yet", t.shapes().is_empty() and not t._draft.is_empty())
	t.raise_plan()
	t.commit_pending()
	_ok("raised and placed: a kept shape", t.shapes().size() == 1 and String(t.shapes()[0].kind) == "plan")
	var cells := BrickShapes.shape_cells(t.shapes()[0])
	var filled := 0
	for c in cells:
		if _ws.world.is_solid(f0, c):
			filled += 1
	_ok("of the held brick, every cell laid (%d)" % cells.size(), cells.size() == 48 * 3 and filled == cells.size())
	# RMB with the brush: a cut through it.
	t.pen.draw = "brush"
	t.brush_size = 1
	t.brush_square = true
	t._sk = {"lie": "flat", "at": 1}
	t.pen.press(Vector2(8.5, 7.5), true)
	t._sketch_commit()
	t.commit_pending()
	_ok("a stroke drawn with RMB cuts the shape", (t.shapes()[0].cuts as Array).size() == 1
			and not _ws.world.is_solid(f0, Vector3i(8, 2, 7)) and _ws.world.is_solid(f0, Vector3i(4, 2, 4)))
	# Saved, and laid again from the save: the outline is kept.
	var back := BuildRecipe.from_dict(JSON.parse_string(JSON.stringify(_ws.recipe.to_dict())))
	var kept: Dictionary = back.meta.shapes[0]
	_ok("saved, a sketched shape's outline fills the same", BrickShapes.shape_cells(kept).size()
			== BrickShapes.shape_cells(t.shapes()[0]).size())
	t.pick("place")


## A room 16 x 10, 24 plates tall, of 1x4s, on the baseplate; returns its shape id.
func _room() -> int:
	_ws._new_build()
	var t: WorkshopTools = _ws._tools
	_hold("brick_1x4")
	_ws._colour = 2
	t.tall = 24
	t.rim = 1
	t.staggered = true
	return t.add_shape("hollow", "flat", Vector2i(4, 4), Vector2i(19, 13), 1)


func _solid(c: Vector3i) -> bool:
	return _ws.world.is_solid(_ws.asm.frames[0], c)


func _opening_checks() -> void:
	print("[probe] doors and windows, with frames and glass")
	var wall := _room()
	var t: WorkshopTools = _ws._tools
	var f0: int = _ws.asm.frames[0]
	var before := _bricks(t.shape_of(wall))
	var n0: int = _ws.recipe.size()
	# A window, clicked on the front wall at plate 6, framed in white 1x2s.
	_hold("brick_1x2")
	_ws._colour = 1
	t.frame_on = true
	t.glass_on = true
	var face := t.face_under(Vector3(11.5 * 0.35, 6.5 * 0.14, -3.0), Vector3(0, 0, 1))
	var op := t.apply_opening("window", face)
	_ok("one undo for the window, its frame and its glass", (_ws._edits as Array).back() == "shape"
			and t.shapes().size() == 3, "%d shapes" % t.shapes().size())
	var glass := WorkshopTools.glass_paint()
	_ok("there is a see-through material for glass", BrickWorld.is_material_translucent(glass.x))
	var a := BrickShapes._v2(op.a)
	var b := BrickShapes._v2(op.b)
	var mid := Vector3i((a.x + b.x) >> 1, (a.y + b.y) >> 1, 4)
	var bid: int = _ws.world.block_at(f0, mid)
	_ok("the window is glass", bid >= 0 and _ws.world.get_block_material(f0, bid) == glass.x)
	var fr := Vector3i(a.x - 1, (a.y + b.y) >> 1, 4)
	var fid: int = _ws.world.block_at(f0, fr)
	_ok("framed beside it in the held colour", fid >= 0 and _ws.world.get_block_colour(f0, fid) == 1)
	var sill := Vector3i((a.x + b.x) >> 1, a.y - 1, 4)
	var sid: int = _ws.world.block_at(f0, sill)
	_ok("with a sill under it", sid >= 0 and _ws.world.get_block_colour(f0, sid) == 1)
	var wall_ok := _solid(Vector3i(a.x - 2, a.y, 4)) and _solid(Vector3i(a.x, b.y + 4, 4))
	var wid: int = _ws.world.block_at(f0, Vector3i(a.x - 2, a.y, 4))
	_ok("and the wall round the frame is the wall's", wall_ok and _ws.world.get_block_colour(f0, wid) == 2)
	_ok("the back wall untouched", _solid(Vector3i((a.x + b.x) >> 1, a.y + 2, 13)))
	_ws._undo()
	_ok("undo: the wall exactly as it was, no frame or glass", t.shapes().size() == 1
			and _bricks(t.shape_of(wall)) == before and _ws.recipe.size() == n0,
			"%d shapes, %d of %d bricks" % [t.shapes().size(), _ws.recipe.size(), n0])
	# A door: no sill, the floor stays open.
	var dface := t.face_under(Vector3(8.5 * 0.35, 4.5 * 0.14, -3.0), Vector3(0, 0, 1))
	var dop := t.apply_opening("door", dface)
	var da := BrickShapes._v2(dop.a)
	var db := BrickShapes._v2(dop.b)
	_ok("a door stands on the floor and is open to it", int(da.y) == 1
			and not _solid(Vector3i((da.x + db.x) >> 1, 1, 4)) and not _solid(Vector3i(da.x, db.y, 4)))
	_ok("with jambs both sides and a head", _solid(Vector3i(da.x - 1, 2, 4)) and _solid(Vector3i(db.x + 1, 2, 4))
			and _solid(Vector3i(da.x, db.y + 1, 4)))
	_ok("and no glass", t.shapes().size() == 2)


func _repeat_checks() -> void:
	print("[probe] repeat: storeys and rows")
	var wall := _room()
	var t: WorkshopTools = _ws._tools
	_hold("brick_1x2")
	var face := t.face_under(Vector3(8.5 * 0.35, 4.5 * 0.14, -3.0), Vector3(0, 0, 1))
	t.apply_opening("door", face)
	# A plain brick on the floor inside, in the storey.
	_hold("plate_1x1")
	_ws._cell = Vector3i(10, 1, 8)
	_ws._update_ghost()
	_ws._place()
	var shapes0 := t.shapes().size()
	var n0: int = _ws.recipe.size()
	t.rep_what = "storey"
	t.rep_lo = 1
	t.rep_hi = 24
	var made := t.repeat("up", 2, 0)
	_ok("a storey repeated twice up: its shapes, door and all, and its loose brick", made > 0
			and t.shapes().size() == shapes0 * 3, "%d shapes, %d made" % [t.shapes().size(), made])
	_ok("the walls go on up", _solid(Vector3i(4, 25, 4)) and _solid(Vector3i(19, 72, 13)) and not _solid(Vector3i(4, 73, 4)))
	_ok("each storey has its door, open, framed", not _solid(Vector3i(9, 26, 4)) and not _solid(Vector3i(9, 50, 4))
			and _solid(Vector3i(5, 26, 4)) and _solid(Vector3i(5, 50, 4)))
	_ok("and its loose brick", _solid(Vector3i(10, 25, 8)) and _solid(Vector3i(10, 49, 8)))
	_ws._undo()
	_ok("one undo takes every copy back", t.shapes().size() == shapes0 and _ws.recipe.size() == n0,
			"%d shapes, %d bricks" % [t.shapes().size(), _ws.recipe.size()])
	# A window repeated along X: three windows, each cut in the wall.
	_hold("brick_1x2")
	var wface := t.face_under(Vector3(11.5 * 0.35, 6.5 * 0.14, -3.0), Vector3(0, 0, 1))
	t.window_size = Vector2i(2, 6)
	var op := t.apply_opening("window", wface)
	var frame_id := -1
	for sh in t.shapes():
		if sh.has("opening") and String(sh.kind) == "hollow":
			frame_id = int(sh.id)
	t.selected = frame_id
	t.rep_what = "shape"
	t.repeat("x", 2, 1)
	var a := BrickShapes._v2(op.a)
	var g := WorkshopTools.glass_paint()
	var f0: int = _ws.asm.frames[0]
	var ok := true
	for k in [0, 1, 2]:
		var c := Vector3i(a.x + k * 5, a.y + 1, 4)
		var bid: int = _ws.world.block_at(f0, c)
		ok = ok and bid >= 0 and _ws.world.get_block_material(f0, bid) == g.x
	_ok("a window repeated twice along X, a stud between frames: three windows of glass", ok)
	_ok("its copies cut the wall they land on", (t.shape_of(wall).cuts as Array).size() >= 4)
	# A sketched brush stroke laid with LMB is a shape too.
	t.pick("sketch")
	t.pen.draw = "brush"
	t.brush_size = 1
	t._sk = {"lie": "flat", "at": 1}
	t.pen.press(Vector2(30.5, 30.5), false)
	t.pen.move(Vector2(34.5, 30.5), 1)
	var before := t.shapes().size()
	t._sketch_commit()
	t.raise_plan()
	t.commit_pending()
	_ok("a brush stroke drawn with LMB is a kept shape", t.shapes().size() == before + 1 and _solid(Vector3i(32, 1, 30)))
	t.pick("place")


func _button_checks() -> void:
	print("[probe] every key a button (section 7)")
	var t: WorkshopTools = _ws._tools
	var all := true
	for sec in WorkshopTools.ACTIONS:
		for row in sec[1]:
			var b: Button = t.rail.action_buttons.get(row[0])
			all = all and b != null and b.tooltip_text.length() > 15
	_ok("every action has a button with a pop-up", all and t.rail.action_buttons.size() >= 18)
	var tools_ok := true
	for row in WorkshopTools.TOOLS:
		var b: Button = t.rail.buttons.get(row[0])
		tools_ok = tools_ok and b != null and b.icon != null
	_ok("every tool a button with an icon", tools_ok and t.rail.buttons.size() == 14)
	var yaw: int = _ws._yaw
	t.act("rotate")
	_ok("Rotate turns the brick in hand", _ws._yaw == (yaw + 1) % 4)
	t.act("lock")
	_ok("Lock height stays on", _ws.plane_locked)
	t.act("lock")
	var grid: bool = _ws._grid_on
	t.act("grid")
	_ok("Grid toggles", _ws._grid_on != grid and _ws._grid.visible == _ws._grid_on)
	t.act("grid")
	var role: int = _ws._role
	t.act("layer")
	_ok("Layer moves the hand to the next layer", _ws._role != role)
	while _ws._role != role:
		t.act("layer")


func _redo_checks() -> void:
	print("[probe] redo, and a run as one undo")
	_ws._new_build()
	var t: WorkshopTools = _ws._tools
	_hold("plate_1x1")
	_ws._cell = Vector3i(20, 1, 20)
	_ws._update_ghost()
	var before: int = _ws.recipe.size()
	_ws._place()
	_ws._begin_run(before)
	_ws._run_moved = 40.0
	_ws._run_press_ms = Time.get_ticks_msec() - 1000
	for x in [21, 22, 23]:
		_ws._cell = Vector3i(x, 1, 20)
		_ws._update_ghost()
		_ws.run_step()
	_ws._end_run()
	_ok("a run of four", _ws.recipe.size() == 4)
	_ws._undo()
	_ok("one Z takes the whole run back", _ws.recipe.size() == 0, "%d left" % _ws.recipe.size())
	_ws.redo_last()
	_ok("Redo lays it all back", _ws.recipe.size() == 4 and _solid(Vector3i(23, 1, 20)))
	_ws._undo()
	_ok("and it undoes as one again", _ws.recipe.size() == 0)
	_hold("brick_1x4")
	t.tall = 3
	var id := t.add_shape("rect", "flat", Vector2i(4, 4), Vector2i(11, 7), 1)
	var laid := _bricks(t.shape_of(id))
	_ws._undo()
	_ok("a shape undone", t.shapes().is_empty() and _ws.recipe.size() == 0)
	_ws.redo_last()
	_ok("and redone, the same bricks", t.shapes().size() == 1 and _bricks(t.shapes()[0]) == laid)
	_ws._undo()
	_ok("and undone again", t.shapes().is_empty())
	_ws._place()
	_ok("a new edit clears what redo had", _ws._redo_list.is_empty())


func _mirror_checks() -> void:
	print("[probe] the mirror (moved down from the asset workshop)")
	_ws._new_build()
	var t: WorkshopTools = _ws._tools
	_ws.mirror_axis = 2
	_ws.mirror_z = 24.0
	_ws.set_mirror(true)
	_hold("plate_1x1")
	_ws._cell = Vector3i(20, 1, 10)
	_ws._update_ghost()
	var before: int = _ws.recipe.size()
	_ws._place()
	_ws._begin_run(before)
	_ws._end_run()
	_ok("a brick placed is placed again across the plane", _solid(Vector3i(20, 1, 10)) and _solid(Vector3i(20, 1, 37)))
	_ws._undo()
	_ok("the pair undoes as one", _ws.recipe.size() == 0)
	_hold("brick_1x2")
	t.tall = 3
	t.add_shape("rect", "flat", Vector2i(4, 4), Vector2i(9, 7), 1)
	_ok("a shape and its mirror image", t.shapes().size() == 2 and _solid(Vector3i(4, 1, 43)) and _solid(Vector3i(9, 1, 40)))
	_ws.set_mirror(false)


## A room 12 x 8, 12 plates of 1x2s; returns its id.
func _small_room() -> int:
	_ws._new_build()
	var t: WorkshopTools = _ws._tools
	_hold("brick_1x2")
	t.tall = 12
	t.rim = 1
	return t.add_shape("hollow", "flat", Vector2i(4, 4), Vector2i(15, 11), 1)


func _house_checks() -> void:
	print("[probe] walls, floor, stairs, roof")
	_ws._new_build()
	var t: WorkshopTools = _ws._tools
	_hold("brick_1x2")
	t.tall = 6
	t.thick = 1
	t._wall_at = 1
	for c in [Vector2i(4, 4), Vector2i(15, 4), Vector2i(15, 11), Vector2i(4, 11)]:
		t._wall_pts.append(c)
	var wid := t.finish_walls(true)
	var w := t.shape_of(wid)
	_ok("Walls: four corners, closed, are a hollow rectangle's cells",
			BrickShapes.shape_cells(w) == BrickShapes.shape_cells({"kind": "hollow", "lie": "flat", "a": [4, 4],
					"b": [15, 11], "at": 1, "depth": 6, "rim": 1}))
	var fill := 0
	for c in BrickShapes.shape_cells(w):
		if _solid(c):
			fill += 1
	_ok("and laid", fill == BrickShapes.shape_cells(w).size())
	var room := _small_room()
	t.floor_tall = 1
	var fid := t.floor_at(Vector3i(8, 1, 7), false)
	_ok("Floor: the room's inside, a plate", fid >= 0 and BrickShapes.shape_cells(t.shape_of(fid)).size() == 10 * 6
			and _solid(Vector3i(5, 1, 5)) and _solid(Vector3i(14, 1, 10)))
	var cid := t.floor_at(Vector3i(8, 2, 7), true)
	var cs := t.shape_of(cid)
	_ok("on top of the walls: over them, out to their faces", cid >= 0 and int(cs.at) == 13
			and _solid(Vector3i(4, 13, 4)) and _solid(Vector3i(15, 13, 11)) and _solid(Vector3i(9, 13, 8)))
	_ok("open ground is refused", t.floor_at(Vector3i(30, 1, 30), false) == -1)
	# Stairs from the floor to the floor on top.
	_hold("brick_1x2")
	t.stair_wide = 2
	var sid := t.stairs_between(Vector3i(5, 2, 24), Vector3i(14, 14, 24))
	var st := t.shape_of(sid)
	var sc := BrickShapes.shape_cells(st)
	var sf := 0
	for c in sc:
		if _solid(c):
			sf += 1
	_ok("Stairs: a step a brick high, laid", sid >= 0 and sf == sc.size() and _solid(Vector3i(5, 2, 24))
			and _solid(Vector3i(14, 13, 24)) and not _solid(Vector3i(14, 2, 24)), "%d of %d" % [sf, sc.size()])
	# A roof on the room.
	room = _small_room()
	_hold("brick_1x2")
	t.roof_style = "gable"
	t.roof_overhang = 1
	var rid := t.roof_on(room)
	var slopes := 0
	for i in _ws.recipe.size():
		if _ws.recipe.part_of(i).begins_with("slope_1x2"):
			slopes += 1
	var rc := BrickShapes.shape_cells(t.shape_of(rid))
	var rf := 0
	for c in rc:
		if _solid(c):
			rf += 1
	_ok("Roof: gable, slopes along its edges", rid >= 0 and slopes >= 20, "%d slopes" % slopes)
	_ok("every cell of it laid (%d)" % rc.size(), rf == rc.size())
	_ok("it sits on the walls, a stud past them", _solid(Vector3i(3, 13, 3)) or _solid(Vector3i(3, 13, 7)))
	var front := Vector3i.ZERO
	for i in _ws.recipe.size():
		if _ws.recipe.part_of(i).begins_with("slope_1x2") and _ws.recipe.cell_of(i).z == 3:
			front = BrickPalette.front_of(_ws.recipe.part_of(i))
	_ok("the low side's slopes face out", front == Vector3i(0, 0, -1), str(front))
	_ws._undo()
	_ok("one undo", t.shape_of(rid).is_empty())
	t.roof_style = "hip"
	var hid := t.roof_on(room)
	_ok("hip roof too", hid >= 0 and (t.shape_of(hid).bricks as Array).size() > 10)


func _pull_checks() -> void:
	print("[probe] base, then height (section 8)")
	_ws._new_build()
	var t: WorkshopTools = _ws._tools
	_hold("plate_1x4")
	_ok("a plate in hand: the height goes a plate at a time", t.height_step("flat") == 1)
	_hold("brick_2x4")
	_ok("a brick: a course (3 plates) at a time", t.height_step("flat") == 3)
	_ok("and a wall of it is two studs thick", t.held_width() == 2)
	_hold("brick_1x2")
	# Walls: drag a line, let go, pull it up 9 plates, click.
	t.pick("walls")
	t._drag = {"phase": "base", "tool": "walls", "button": MOUSE_BUTTON_LEFT, "lie": "flat", "at": 1,
			"a": Vector2i(4, 4), "b": Vector2i(15, 4), "kind": "polyline", "cut": false}
	var plan := t._plan_for(t._making())
	_ok("the bricks it will lay are worked out while it is drawn", plan.size() > 0)
	t._to_height()
	_ok("let go: the height comes next, a course to start", t._drag.phase == "height" and int(t._drag.rec.depth) == 3)
	t._drag.rec.depth = 9
	var shown := t._plan_for(t._drag.rec)
	var w1 := t.commit_pending()
	var laid := {}
	for b in t.shape_of(w1).bricks:
		laid["%s@%s" % [b[0], str(BuildRecipe.cell_from(b[1]))]] = true
	var same := shown.size() == laid.size()
	for pc in shown:
		same = same and laid.has("%s@%s" % [pc[0], str(pc[1])])
	_ok("clicked: a wall 9 plates tall, exactly the bricks shown", w1 >= 0 and int(t.shape_of(w1).depth) == 9 and same)
	_ok("of the held brick", BrickPalette.part_of(String(t.shape_of(w1).bricks[0][0])).begins_with("brick_1x"))
	# The next wall from its end joins it; the last one back to the start closes it.
	for seg in [[Vector2i(15, 4), Vector2i(15, 11)], [Vector2i(15, 11), Vector2i(4, 11)], [Vector2i(4, 11), Vector2i(4, 4)]]:
		t._drag = {"phase": "base", "tool": "walls", "button": MOUSE_BUTTON_LEFT, "lie": "flat", "at": 1,
				"a": seg[0], "b": seg[1], "kind": "polyline", "cut": false}
		t._to_height()
		t._drag.rec.depth = 9
		t.commit_pending()
	var w := t.shape_of(w1)
	_ok("walls drawn end to end are one wall line, closed", t.shapes().size() == 1 and (w.points.pts as Array).size() == 4
			and bool(w.points.closed))
	_ok("its cells a hollow rectangle's: the corners joined", BrickShapes.shape_cells(w) == BrickShapes.shape_cells(
			{"kind": "hollow", "lie": "flat", "a": [4, 4], "b": [15, 11], "at": 1, "depth": 9, "rim": 1}))
	# Floor: a click (no drag) inside fills it; pulled to 2 plates, of the held plate.
	_hold("plate_2x2")
	t.pick("floor")
	t._drag = {"phase": "base", "tool": "floor", "button": MOUSE_BUTTON_LEFT, "lie": "flat", "at": 1,
			"a": Vector2i(8, 7), "b": Vector2i(8, 7), "kind": "rect", "cut": false}
	t._to_height()
	_ok("a floor clicked inside the walls fills them, a plate to start", t._drag.rec.kind == "cells"
			and int(t._drag.rec.depth) == 1)
	t._drag.rec.depth = 2
	var f := t.commit_pending()
	_ok("placed, 2 plates of 2x2 plates", f >= 0 and _solid(Vector3i(5, 2, 5)) and not _solid(Vector3i(5, 3, 5))
			and BrickPalette.part_of(String(t.shape_of(f).bricks[0][0])).begins_with("plate_"))
	# Shapes: a ring footprint, then its height.
	_hold("brick_1x2")
	t.pick("shape")
	t.kind = "ring"
	t._drag = {"phase": "base", "tool": "shape", "button": MOUSE_BUTTON_LEFT, "lie": "flat", "at": 1,
			"a": Vector2i(24, 24), "b": Vector2i(34, 34), "kind": "ring", "cut": false}
	t._to_height()
	t._drag.rec.depth = 6
	var r := t.commit_pending()
	_ok("Shapes: a ring 6 plates tall", r >= 0 and int(t.shape_of(r).depth) == 6 and _solid(Vector3i(29, 6, 24)))
	t.kind = "rect"
	t.pick("place")
	# Roofs: a hip has corner slopes; a held curve makes a curved roof.
	var room := _small_room()
	t.roof_style = "hip"
	var hid := t.roof_on(room)
	var corners := 0
	for b in t.shape_of(hid).bricks:
		if String(b[0]).begins_with("slopecorner_2x2"):
			corners += 1
	var hc := BrickShapes.shape_cells(t.shape_of(hid))
	var hf := 0
	for c in hc:
		if _solid(c):
			hf += 1
	_ok("a hip roof's corners are corner slopes (%d)" % corners, corners >= 4 and corners % 4 == 0)
	_ok("and every cell of it is laid", hf == hc.size(), "%d of %d" % [hf, hc.size()])
	_ws._undo()
	_hold("curve_1x2")
	t.roof_style = "gable"
	var cid := t.roof_on(room)
	var curves := 0
	for b in t.shape_of(cid).bricks:
		if String(b[0]).begins_with("curve_1x2"):
			curves += 1
	_ok("a curve in hand: a roof of curves", curves >= 10, "%d" % curves)


func _floor_plan_checks() -> void:
	print("[probe] floor plans: sketch, raise, storeys (section 9)")
	var pts := {"adds": [[[0, 0], [10, 0], [10, 8], [0, 8]]], "subs": [[[3, 3], [5, 3], [5, 5], [3, 5]]]}
	_ok("a plan is its strokes in, less its strokes out", BrickShapes.plan_region(pts).size() == 80 - 4)
	_ok("walls along its outline: a ring the brick's width", BrickShapes.ring(BrickShapes.plan_region(
			{"adds": [[[0, 0], [10, 0], [10, 8], [0, 8]]]}), 1).size() == 32)
	_ws._new_build()
	var t: WorkshopTools = _ws._tools
	var f0: int = _ws.asm.frames[0]
	_hold("brick_1x2")
	t.pick("sketch")
	t.lie = "flat"
	t.sketch_level = 1
	# The plan: a rectangle and a wing on its side, two strokes.
	for poly in [[Vector2(4, 4), Vector2(20, 4), Vector2(20, 16), Vector2(4, 16)],
			[Vector2(20, 8), Vector2(26, 8), Vector2(26, 12), Vector2(20, 12)]]:
		t.pen.draw = "polygon"
		t.pen.points.clear()
		t._sk = {"lie": "flat", "at": 1}
		for q in poly:
			t.pen.polygon_click(q, false, false)
		t._sketch_commit()
	_ok("two strokes, one plan", (t._draft.adds as Array).size() == 2 and t.shapes().is_empty())
	t.sketch_makes = "building"
	t.storey_courses = 3
	t.flat_roof = true
	t.raise_plan()
	_ok("raised as a building: a storey (and the roof) to start", t._drag.phase == "height"
			and int(t._drag.rec.depth) == 11 and int(t._drag.rec.step) == 10)
	t._drag.rec.depth = 21
	var b := t.commit_pending()
	var sh := t.shape_of(b)
	_ok("placed: two storeys and a flat roof", b >= 0 and String(sh.kind) == "plan" and int(sh.depth) == 21
			and t._draft.is_empty())
	_ok("a floor at the bottom, the whole plan", _solid(Vector3i(10, 1, 10)) and _solid(Vector3i(24, 1, 10)))
	_ok("walls along the outline above it, the inside open", _solid(Vector3i(4, 5, 10)) and _solid(Vector3i(25, 5, 9))
			and not _solid(Vector3i(10, 5, 10)) and not _solid(Vector3i(20, 5, 10)))
	_ok("the next storey's floor, and the flat roof", _solid(Vector3i(10, 11, 10)) and _solid(Vector3i(10, 21, 10))
			and not _solid(Vector3i(10, 22, 10)) and not _solid(Vector3i(10, 15, 10)))
	var cells := BrickShapes.shape_cells(sh)
	var filled := 0
	for c in cells:
		if _solid(c):
			filled += 1
	_ok("every cell of it laid (%d)" % cells.size(), filled == cells.size())
	var starts_ok := true
	var floors_plates := true
	for i in _ws.recipe.size():
		var size := BrickPalette.size_of(_ws.recipe.part_of(i))
		var y: int = _ws.recipe.cell_of(i).y
		if size.y == 3:
			starts_ok = starts_ok and y in [2, 5, 8, 12, 15, 18]
		if y in [1, 11, 21]:
			floors_plates = floors_plates and size.y == 1
	_ok("each storey's walls are whole courses up from its floor", starts_ok)
	_ok("the floors are plates", floors_plates)
	# A window on every floor, and a door that stands on its storey's floor.
	_hold("brick_1x2")
	t.window_size = Vector2i(2, 3)
	t.every_floor = true
	var face := t.face_under(Vector3(12.5 * 0.35, 5.5 * 0.14, -3.0), Vector3(0, 0, 1))
	t.apply_opening("window", face)
	var g := WorkshopTools.glass_paint()
	var gl0: int = _ws.world.block_at(f0, Vector3i(12, 6, 4))
	var gl1: int = _ws.world.block_at(f0, Vector3i(12, 16, 4))
	_ok("a window on every floor: glass on both storeys", gl0 >= 0 and gl1 >= 0
			and _ws.world.get_block_material(f0, gl0) == g.x and _ws.world.get_block_material(f0, gl1) == g.x)
	_ws._undo()
	_ok("one undo takes them all", _ws.world.get_block_material(f0, _ws.world.block_at(f0, Vector3i(12, 16, 4))) != g.x)
	t.door_size = Vector2i(3, 6)
	var dface := t.face_under(Vector3(8.5 * 0.35, 15.5 * 0.14, -3.0), Vector3(0, 0, 1))
	var dop := t.opening_spec("door", dface)
	_ok("a door on the upper storey stands on its floor", int(dop.a[1]) == 12, str(dop.a))
	# On top: the next plan starts at the roof, from the same outline.
	t.plan_on_top(true)
	_ok("on top of the last building, starting from its plan", int(t._draft.at) == 22
			and (t._draft.adds as Array).size() == 2)
	(t._draft.subs as Array).append([[20, 4], [27, 4], [27, 17], [20, 17]])
	t.sketch_makes = "walls"
	t.raise_plan()
	t._drag.rec.depth = 6
	var top := t.commit_pending()
	_ok("a setback storey on top: walls along the new outline", top >= 0 and int(t.shape_of(top).at) == 22
			and _solid(Vector3i(4, 23, 10)) and not _solid(Vector3i(24, 23, 10)))
	# A plan moves and mirrors with its strokes.
	var moved := BrickShapes.shifted(sh, Vector3i(3, 0, 2))
	var want := {}
	for c in BrickShapes.solid_cells(sh):
		want[c + Vector3i(3, 0, 2)] = true
	_ok("a plan moved is its cells moved", BrickShapes.solid_cells(moved) == want)
	t.lie = "flat"
	t.sketch_level = -1
	t.sketch_makes = "solid"
	t.pick("place")
