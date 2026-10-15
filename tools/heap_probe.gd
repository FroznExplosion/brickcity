extends SceneTree

## Bricks that stay where they fall (Docs/CollapseNext.md 0, item 17; BrickHeap).
##
##     godot --headless --path . --script tools/heap_probe.gd
##
## A crumb that comes to rest is laid in the heap: flat on a face, on the floor
## it stopped on, for good -- not shrunk away a second and a half after it came
## loose. What lay on something that goes falls again; what a piece comes to
## rest on goes; a square of the city holds so many of each size, the oldest
## overwritten; past the setting all told, the oldest heaps are swept first;
## at 0 on the setting nothing is laid, as before.

var _pass := 0
var _fail := 0
var _started := false
var _w: BrickWorld
var _palette: Dictionary
var _m: IslandManager
var _camera: Camera3D


func _init() -> void:
	print("bricks that stay where they fall")
	seed(20261015)
	_w = BrickWorld.new()
	_palette = TowerRecipe.bake_palette(_w)
	var ground := StaticBody3D.new()
	ground.collision_layer = Layers.WORLD
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(600.0, 1.0, 600.0)
	shape.shape = box
	shape.position = Vector3(0.0, -0.5, 0.0)
	ground.add_child(shape)
	root.add_child(ground)
	_camera = Camera3D.new()
	root.add_child(_camera)
	_m = IslandManager.new()
	root.add_child(_m)
	_m.setup(_w, null, _camera)
	_m.interest = func() -> PackedVector3Array: return PackedVector3Array([Vector3(0, 1, 0)])
	physics_frame.connect(_run)


func _ok(what: String, cond: bool, detail := "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _ticks(n: int) -> void:
	for k in n:
		await physics_frame
		_m.tick()


func _until_still() -> void:
	var most := int((IslandManager.CRUMB_FALL_MAX_MS + 300) * Engine.physics_ticks_per_second / 1000.0)
	for t in most:
		if _m.crumb_count == 0:
			return
		await _ticks(1)


## Every brick lying: [size, transform].
func _lying() -> Array:
	var out := []
	for k in _m.heap._heaps:
		var h = _m.heap._heaps[k]
		for slot in h.filled:
			if h.used[slot]:
				out.append([h.size, h.xf[slot]])
	return out


static func _half_h(size: Vector3, b: Basis) -> float:
	return (absf(b.x.y) * size.x + absf(b.y.y) * size.y + absf(b.z.y) * size.z) * 0.5


## Of the bricks lying (see _lying), how many rest on the street (y = 0) or on
## the top of another brick lying under them -- none in the street, none in
## another brick, none in the air.
func _resting(lying: Array) -> int:
	var n := 0
	for i in lying.size():
		var size: Vector3 = lying[i][0]
		var xf: Transform3D = lying[i][1]
		var foot := xf.origin.y - _half_h(size, xf.basis)
		if absf(foot) < 0.01:
			n += 1
			continue
		var mine := BrickHeap._footprint(size, xf.basis, xf.origin)
		for j in lying.size():
			if j == i:
				continue
			var os: Vector3 = lying[j][0]
			var ox: Transform3D = lying[j][1]
			if absf(ox.origin.y + _half_h(os, ox.basis) - foot) > 0.01:
				continue
			var under := false
			for c in BrickHeap._footprint(os, ox.basis, ox.origin):
				if mine.has(c):
					under = true
					break
			if under:
				n += 1
				break
	return n


func _look(from: Vector3, at: Vector3) -> void:
	_camera.global_position = from
	_camera.look_at(at, Vector3.UP)


## A brick of 2x4's size laid straight at `at` (its middle), flat.
func _lay_at(at: Vector3) -> void:
	var size := Vector3(4, 3, 2) * BrickWorld.get_cell_size()
	_m.heap.lay(size.snapped(Vector3.ONE * 0.001), Transform3D(Basis(), at), Color.RED)


func _run() -> void:
	if _started:
		return
	_started = true
	var cs: Vector3 = BrickWorld.get_cell_size()

	# --- a blast's ring comes down and stays ---------------------------------------
	print("\na blast on a wall, low down")
	var tower := _w.create_chunk(Vector3i.ZERO, TowerRecipe.chunk_dims(16, 16, 12))
	TowerRecipe.build(_w, tower, _palette, 16, 16, 12)
	var at := Vector3(2.8, 2.0, 0.2)
	_look(Vector3(2.8, 3.0, -14.0), at)
	var killed: PackedInt32Array = _w.apply_hit(tower, at, 1.4)
	_m.throw_killed(tower, killed, at, 1.4)
	var thrown := _m.crumb_count
	await _until_still()
	_ok("what it threw has come down and lies there, none still falling",
			thrown > 0 and _m.crumb_count == 0 and _m.heap.count == thrown,
			"%d thrown, %d lying" % [thrown, _m.heap.count])
	var flat := 0
	var piled := 0
	for e in _lying():
		var xf: Transform3D = e[1]
		for k in 3:
			if is_equal_approx(absf(xf.basis[k].y), 1.0):
				flat += 1
				break
		if xf.origin.y - _half_h(e[0], xf.basis) > 0.01:
			piled += 1
	_ok("each lies flat on one of its faces", flat == _m.heap.count, "%d of %d" % [flat, _m.heap.count])
	var resting := _resting(_lying())
	_ok("on the street, or on a brick lying under it -- none in another, none in the air",
			resting == _m.heap.count, "%d of %d; %d on another brick" % [resting, _m.heap.count, piled])
	var lying0 := _m.heap.count
	await _ticks(int(8.0 * Engine.physics_ticks_per_second))
	_ok("eight seconds on, every one is still there", _m.heap.count == lying0,
			"%d, then %d" % [lying0, _m.heap.count])

	# --- what they lay on goes ----------------------------------------------------------
	print("\nwhat they lay on goes")
	for k in 5:
		_lay_at(Vector3(40.0 + k * 0.5, 3.0, 0.0))
	var before := _m.heap.count
	_m._heap_support_gone(AABB(Vector3(39.0, 2.5, -1.0), Vector3(4.0, 0.3, 2.0)))
	_ok("they are handed back to fall", _m.heap.count == before - 5 and _m.crumb_count == 5
			and _m.heap.handed_back >= 5, "%d lying, %d falling" % [_m.heap.count, _m.crumb_count])
	await _until_still()
	var again := []
	for e in _lying():
		var xf: Transform3D = e[1]
		if xf.origin.x > 39.0 and xf.origin.x < 43.0 and xf.origin.y < 2.0:
			again.append(e)
	_ok("and lie again where they came down: on the street, or on each other",
			again.size() == 5 and _resting(again) == 5, "%d of 5 down, %d resting" % [
				again.size(), _resting(again)])

	# --- a piece comes to rest on them -----------------------------------------------------
	print("\na piece comes to rest on them")
	for k in 6:
		_lay_at(Vector3(79.8 + k * 0.4, 0.21, 0.0))
	var cleared0 := _m.heap.cleared
	var c := _w.create_chunk(Vector3i.ZERO, TowerRecipe.chunk_dims(8, 8, 2))
	TowerRecipe.build(_w, c, _palette, 8, 8, 2)
	_w.set_chunk_transform(c, Transform3D(Basis(), Vector3(79.0, 2.0, -1.4)))
	var ids := PackedInt32Array()
	for id in _w.get_block_count(c):
		ids.append(id)
	var slab := _m.spawn(c, ids, Vector3.ZERO, Vector3.ZERO, -1, -1)
	for t in 150:
		await _ticks(1)
		if slab.settled:
			break
	_m.settle_now(slab)
	var under := 0
	for e in _lying():
		var xf: Transform3D = e[1]
		if xf.origin.x > 79.5 and xf.origin.x < 81.9 and absf(xf.origin.z) < 0.5:
			under += 1
	_ok("the bricks under it are gone", _m.heap.cleared - cleared0 >= 6 and under == 0,
			"%d cleared, %d left under it" % [_m.heap.cleared - cleared0, under])

	# --- how many ---------------------------------------------------------------------------
	print("\nhow many")
	var over0 := _m.heap.overwritten
	for k in BrickHeap.CELL_CAP + 10:
		# All in one square of the city (130-140 m: square 4, 128-160 m).
		_lay_at(Vector3(130.0 + (k % 20) * 0.5, 0.21, 130.0 + float(k / 20) * 0.3))
	_ok("a square of the city holds so many of a size, the oldest overwritten",
			_m.heap.overwritten - over0 == 10, "%d overwritten" % (_m.heap.overwritten - over0))
	var keep := BrickHeap.max_bricks
	BrickHeap.max_bricks = _m.heap.count + 20
	var old_area := 0
	for k in 40:
		_lay_at(Vector3(300.0 + (k % 10) * 0.6, 0.21, 300.0 + float(k / 10) * 0.6))
	for e in _lying():
		var xf: Transform3D = e[1]
		if xf.origin.x < 100.0 and xf.origin.z < 50.0:
			old_area += 1
	_ok("past the setting, the heaps laid longest ago are swept first",
			_m.heap.count <= BrickHeap.max_bricks and old_area == 0,
			"%d lying of %d, %d left in the first heaps" % [_m.heap.count, BrickHeap.max_bricks, old_area])
	BrickHeap.max_bricks = keep
	var far_ok := true
	for k in _m.heap._heaps:
		far_ok = far_ok and is_equal_approx(_m.heap._heaps[k].mmi.visibility_range_end, BrickHeap.DRAW_RANGE)
	_ok("and a heap is not drawn past DRAW_RANGE", far_ok)

	# --- the setting at 0 ------------------------------------------------------------------------
	print("\nwith the setting at 0")
	BrickHeap.max_bricks = 0
	var laid0 := _m.heap.laid
	var t2 := _w.create_chunk(Vector3i.ZERO, TowerRecipe.chunk_dims(16, 16, 12))
	TowerRecipe.build(_w, t2, _palette, 16, 16, 12)
	_w.set_chunk_transform(t2, Transform3D(Basis(), Vector3(-80.0, 0.0, 0.0)))
	var at2 := Vector3(-77.2, 2.0, 0.2)
	_look(Vector3(-77.2, 3.0, -14.0), at2)
	killed = _w.apply_hit(t2, at2, 1.4)
	_m.throw_killed(t2, killed, at2, 1.4)
	var thrown2 := _m.crumb_count
	await _ticks(int((IslandManager.CRUMB_LIFE_MS + 200) * Engine.physics_ticks_per_second / 1000.0))
	_ok("nothing is laid: they shrink away a second and a half on, as before",
			thrown2 > 0 and _m.crumb_count == 0 and _m.heap.laid == laid0,
			"%d thrown, %d falling, %d laid" % [thrown2, _m.crumb_count, _m.heap.laid - laid0])
	BrickHeap.max_bricks = keep

	print("  --   %s" % _m.heap.census_line())
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
