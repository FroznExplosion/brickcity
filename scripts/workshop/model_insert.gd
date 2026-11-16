class_name ModelInsert
extends Node

## A 3D model into bricks in the building workshop (Docs/BuildTools.md section 21, stage 7d):
## the model read (`ModelMesh`), sized by its longest side in studs, turned into brick cells
## with no clay (`SdfForm.mesh_cells`, only the skin as walls of `wall_studs`), the budget said
## first, then packed and laid a course a time over frames (`BrickBench.pack_cells`), with a
## bar and Cancel. One undo for the whole; Cancel takes back what was laid.
##
## In the held colour and material; the model's own colours are stage 8.

signal changed

## Where it is laid from: the middle of the build area, on the floor.
var bench: BrickBench
var path := ""
var size_studs := 100
## The wall's thickness, studs (0: solid).
var wall_studs := 1
## The model in its own metres: triangles.
var _verts := PackedVector3Array()
var _index := PackedInt32Array()
var _box := AABB()
## The cells it would lay (x, y, z a cell), from `recount`.
var cells := PackedInt32Array()
## What `recount` found: {cells, bricks (about), fits, size (studs, plates, studs)}.
var budget := {}
## "" idle, "laying".
var state := ""
var progress := 0.0
## While laying: the courses left ([base, Dictionary of cells]), the recipe as it stood.
var _courses := []
var _total := 0
var _before := {}
var laid := 0
var refused := 0
## A frame's laying budget, ms (the rest of the frame is the workshop's).
const FRAME_MS := 12.0


## The model file, or false if it cannot be read.
func open(p: String) -> bool:
	var mesh := ModelMesh.read(p)
	if mesh == null:
		return false
	path = p
	set_mesh(mesh)
	return true


## A mesh (the model's frame) as the model.
func set_mesh(mesh: ArrayMesh) -> void:
	_verts = PackedVector3Array()
	_index = PackedInt32Array()
	for s in mesh.get_surface_count():
		if mesh.surface_get_primitive_type(s) != Mesh.PRIMITIVE_TRIANGLES:
			continue
		var arr := mesh.surface_get_arrays(s)
		var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var off := _verts.size()
		_verts.append_array(v)
		var idx = arr[Mesh.ARRAY_INDEX]
		if idx == null or (idx as PackedInt32Array).is_empty():
			for i in v.size():
				_index.append(off + i)
		else:
			for i in idx:
				_index.append(off + int(i))
	_box = AABB()
	if not _verts.is_empty():
		_box = AABB(_verts[0], Vector3.ZERO)
		for v in _verts:
			_box = _box.expand(v)
	recount()


func has_model() -> bool:
	return not _verts.is_empty()


## The cells at this size and wall, and the budget: said before anything is laid.
func recount() -> void:
	cells = PackedInt32Array()
	budget = {}
	if _verts.is_empty() or bench == null:
		changed.emit()
		return
	var longest := maxf(_box.size.x, maxf(_box.size.y, _box.size.z))
	var k := size_studs * BrickPalette.STUD_M / maxf(longest, 0.0001)
	var to_cell := Vector3(k / BrickPalette.STUD_M, k / BrickPalette.PLATE_M, k / BrickPalette.STUD_M)
	var span := _box.size * to_cell
	var area := float(bench.plate_studs)
	var origin := Vector3(floorf((area - span.x) * 0.5), 1.0, floorf((area - span.z) * 0.5))
	var v := PackedVector3Array()
	v.resize(_verts.size())
	for i in _verts.size():
		v[i] = (_verts[i] - _box.position) * to_cell + origin
	var wall := Vector3i.ZERO
	if wall_studs > 0:
		wall = Vector3i(wall_studs, maxi(1, roundi(wall_studs * BrickPalette.STUD_M / BrickPalette.PLATE_M)), wall_studs)
	cells = SdfForm.mesh_cells(v, _index, wall)
	var n := cells.size() / 3
	var fits := span.x <= area and span.z <= area and span.y + 1.0 <= bench.height_plates
	budget = {"cells": n, "bricks": _estimate(), "fits": fits,
			"size": Vector3i(ceili(span.x), ceili(span.y), ceili(span.z))}
	changed.emit()


## About how many bricks: courses spread up the model packed (about 20,000 cells' worth), the
## rest at the bricks a cell of the nearest packed one.
func _estimate() -> int:
	var n := cells.size() / 3
	if n == 0:
		return 0
	var base := cells[1]
	var by := {}
	for i in range(0, cells.size(), 3):
		var y := cells[i + 1]
		(by.get_or_add(y - posmod(y - base, 3), []) as Array).append(Vector3i(cells[i], y, cells[i + 2]))
	var keys := by.keys()
	keys.sort()
	# The first and last courses (a floor, a roof: big plates) and every `every`th between;
	# each course counted at the bricks a cell of the sampled course nearest it.
	var every := maxi(1, ceili(float(n) / 20000.0))
	var ratio := {}
	for j in range(keys.size()):
		if j % every != 0 and j != keys.size() - 1:
			continue
		var some := {}
		for c in by[keys[j]]:
			some[c] = true
		ratio[j] = float(bench.pack_cells(some, false, {}, base).size()) / some.size()
	var sampled := ratio.keys()
	var total := 0.0
	for j in range(keys.size()):
		var near: int = sampled[0]
		for q in sampled:
			if absi(int(q) - j) < absi(near - j):
				near = q
		total += float(ratio[near]) * (by[keys[j]] as Array).size()
	return int(round(total))


## Start laying it, a course a frame or more.
func lay() -> bool:
	if state != "" or cells.is_empty() or not bool(budget.get("fits", false)):
		return false
	var base := cells[1]
	var by := {}
	for i in range(0, cells.size(), 3):
		var y := cells[i + 1]
		var c0 := y - posmod(y - base, 3)
		(by.get_or_add(c0, {}) as Dictionary)[Vector3i(cells[i], y, cells[i + 2])] = true
	var keys := by.keys()
	keys.sort()
	_courses = []
	for c0 in keys:
		_courses.append([base, by[c0]])
	_total = _courses.size()
	_before = {"first": bench.recipe.size(), "fixtures": bench.recipe.fixture_count(),
			"towers": bench.recipe.towers.size(), "placements": bench.recipe.placements.size()}
	laid = 0
	refused = 0
	progress = 0.0
	state = "laying"
	changed.emit()
	return true


func _process(_delta: float) -> void:
	if state == "laying":
		step(FRAME_MS)


## Lay courses for about `ms`; the last one finishes it.
func step(ms: float) -> void:
	var t0 := Time.get_ticks_usec()
	bench._batch = true
	# At least one course a step, then as many as fit in `ms`.
	var first := true
	while not _courses.is_empty() and (first or (Time.get_ticks_usec() - t0) / 1000.0 < ms):
		first = false
		var c: Array = _courses.pop_front()
		for b in bench.pack_cells(c[1], false, {}, int(c[0])):
			if bench.lay_part(String(b[0]), b[1], bench._colour, bench._mat):
				laid += 1
			else:
				refused += 1
	bench._batch = false
	progress = 1.0 - float(_courses.size()) / maxf(_total, 1)
	if _courses.is_empty():
		_finish()
	else:
		bench._after_edit()
	changed.emit()


func _finish() -> void:
	state = ""
	var first := int(_before.first)
	bench.recipe.groups.append({"source": path, "name": path.get_file().get_basename() if path != "" else "a model",
			"first": first, "count": bench.recipe.size() - first, "turn": 0, "offset": [0, 0, 0]})
	bench.undo_stack.push(WkCommand.make(&"stamp", _before.duplicate(), bench._undo_stamp))
	bench._after_edit()
	print("[workshop] model '%s': %d bricks laid, %d refused" % [path.get_file(), laid, refused])


## Stop laying and take back what was laid.
func cancel() -> void:
	if state != "laying":
		return
	state = ""
	_courses = []
	bench._undo_stamp(WkCommand.make(&"stamp", _before.duplicate(), bench._undo_stamp))
	laid = 0
	progress = 0.0
	changed.emit()


## What the panel says.
func say() -> String:
	if _verts.is_empty():
		return "No model yet: open one (glTF, OBJ, FBX, STL)."
	if state == "laying":
		return "Laying: %d%%, %d bricks" % [int(progress * 100.0), laid]
	var s: Vector3i = budget.get("size", Vector3i.ZERO)
	var t := "%s: %d x %d x %d studs, %d cells, about %d bricks" % [path.get_file() if path != "" else "model",
			s.x, ceili(s.y * BrickPalette.PLATE_M / BrickPalette.STUD_M), s.z, int(budget.get("cells", 0)), int(budget.get("bricks", 0))]
	if not bool(budget.get("fits", false)):
		t += ". Too big for the build area: make it smaller."
	return t
