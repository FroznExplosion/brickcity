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
