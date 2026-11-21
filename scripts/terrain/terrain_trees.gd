class_name TerrainTrees
extends Node3D

## The trees of a heightfield scene (the terrain test and the terrain editor),
## for looking at: the same trees in the same places as the city grows
## (Trees.scatter from the same seed), drawn the same way (ImpostorLod: real
## bricks near, octahedral cards far), but not registered as buildings -- this
## scene has no brick world to shoot them in. Docs/Impostors.md 8.
##
## Re-placed when the ground changes under them, a moment after the last
## edit rather than on every stroke of the brush -- and only where it changed.
##
## The ImpostorLod sets are KEPT across a rebuild: a new set has no baked
## card, and until it bakes every one of its trees is drawn at full detail.
## Re-making them on every edit was 9 million triangles for a couple of
## seconds after each tool switch or brush stroke.

const MAX_TREES := 6000
## Frames between tier passes: several thousand trees is several milliseconds
## of distance checks, and nobody crosses 45 m in a sixth of a second.
const UPDATE_EVERY := 10
const REBUILD_AFTER := 0.5
## The ImpostorLod square for trees. 6,000 cards over a kilometre and a half
## in 128 m squares were ~1,470 draw calls from the editor's height (two
## MultiMeshes a square a kind, and their shadow passes).
static var chunk_metres := 512.0

var camera: Camera3D
var material: Material
var rect := Rect2i()
var world_seed := 0
var count := 0

var _sets := {}
## One row per tree placed: {key, handle, x, z}.
var _placed: Array[Dictionary] = []
var _frame := 0
var _rebuild_in := -1.0
## Where the ground changed since the last rebuild; empty with `_rebuild_all`
## for a change that could be anywhere (a site moved, a pad cut).
var _pending := Rect2i()
var _rebuild_all := false
## Where each set was last sorted into tiers from, by key. A set is sorted
## again only once the camera has moved a metre from there, and the sets take
## turns, one a frame: a pass over all 6000 trees was 3.8 ms every tenth frame.
var _sorted_at := {}
var _turn := 0
const RESORT_METRES := 1.0

## STREAMED (Docs/MineWorld.md 4), for a world with no edge: trees are placed
## per square cell of STREAM_CELL studs, the cells within `keep_m` of the
## camera, nearest first, a few a frame; a cell past `drop_m` is taken away.
## What grows where is the caller's (`stream`'s callables), so the same
## scatter serves the biome world and nothing is copied.
const STREAM_CELL := 128
const STREAM_BUDGET_US := 2500
## A set's squares refilled at most this a frame; the rest the frames after.
const SETS_BUDGET_US := 2000
var streaming := false
var keep_m := 420.0
var drop_m := 500.0
var _chance_at := Callable()
var _variant_at := Callable()
## Vector2i cell -> the rows placed in it.
var _cells := {}
var _queue: Array[Vector2i] = []
var _plan_at := Vector3.INF

## SOLID TRUNKS, streaming mode (Docs/MineWorld.md 4): the trunks of every
## cell whose middle is within `solid_m` of the camera are boxes the player
## and rounds meet (FIXTURE | TREE, PlanetTrees' layers), taken away past 1.5
## times that. 0 = none (the editor and heightfield test only look at trees).
## Nodeless: one PhysicsServer body a cell, one shared box shape a kind.
var solid_m := 0.0
## Vector2i cell -> the body RID of its trunks.
var _solid := {}
var _trunk_shapes := {}
var _solid_at := Vector3.INF


func setup(p_camera: Camera3D, p_material: Material) -> void:
	camera = p_camera
	material = p_material


func build(p_rect: Rect2i, p_seed: int) -> void:
	rect = p_rect
	world_seed = p_seed
	var t0 := Time.get_ticks_usec()
	_clear_placed(Rect2i())
	_place(Trees.scatter(rect, world_seed, MAX_TREES))
	count = _placed.size()
	print("[trees] %d scattered in %.0f ms" % [count, float(Time.get_ticks_usec() - t0) / 1000.0])
	_update()


## The ground changed: place again once the edits stop. `studs` is where;
## empty means anywhere.
func rebuild_soon(studs := Rect2i()) -> void:
	_rebuild_in = REBUILD_AFTER
	if not studs.has_area():
		_rebuild_all = true
	else:
		_pending = studs if not _pending.has_area() else _pending.merge(studs)


func _rebuild() -> void:
	if _rebuild_all:
		_rebuild_all = false
		_pending = Rect2i()
		build(rect, world_seed)
		return
	if not _pending.has_area():
		return
	var t0 := Time.get_ticks_usec()
	# Out to the scatter's lattice, so every tree whose cell is in the area
	# is taken away and Trees.scatter puts back exactly those cells.
	var sp: int = Trees.SPACING
	var lo := Vector2i(floori(float(_pending.position.x) / sp) * sp,
			floori(float(_pending.position.y) / sp) * sp)
	var hi := Vector2i(ceili(float(_pending.end.x) / sp) * sp,
			ceili(float(_pending.end.y) / sp) * sp)
	var area := Rect2i(lo, hi - lo).intersection(rect)
	_pending = Rect2i()
	if not area.has_area():
		return
	var gone := _clear_placed(area)
	var spots: Array = Trees.scatter(area, world_seed, MAX_TREES)
	_place(spots)
	count = _placed.size()
	print("[trees] %d re-placed (%d before) in %.0f ms" % [spots.size(), gone,
			float(Time.get_ticks_usec() - t0) / 1000.0])
	_update()


## Take away the trees standing in `area` (every tree when it is empty).
## Returns how many.
func _clear_placed(area: Rect2i) -> int:
	var kept: Array[Dictionary] = []
	var gone := 0
	for row in _placed:
		if area.has_area() and not area.has_point(Vector2i(row.x, row.z)):
			kept.append(row)
			continue
		(_sets[row.key] as ImpostorLod).remove(int(row.handle))
		gone += 1
	_placed = kept
	return gone


## Stream trees round the camera from now on (see STREAM_CELL). Clears
## whatever was placed before.
func stream(p_seed: int, chance_at: Callable, variant_at: Callable, keep := 420.0) -> void:
	clear_all()
	streaming = true
	world_seed = p_seed
	_chance_at = chance_at
	_variant_at = variant_at
	keep_m = keep
	drop_m = keep + 80.0


## Every tree gone (a new world is about to be generated).
func clear_all() -> void:
	for c in _solid.keys():
		_unsolid(c)
	_solid_at = Vector3.INF
	for c in _cells:
		for row in _cells[c]:
			(_sets[row.key] as ImpostorLod).remove(int(row.handle))
	_cells.clear()
	_queue.clear()
	_plan_at = Vector3.INF
	_clear_placed(Rect2i())
	count = 0


func _stream_step() -> void:
	var here := to_local(camera.global_position)
	var cell_m := float(STREAM_CELL) * BrickWorld.get_stud_metres()
	if _plan_at.distance_to(here) > cell_m * 0.25:
		_plan_at = here
		var r := int(ceil(keep_m / cell_m))
		var cc := Vector2i(floori(here.x / cell_m), floori(here.z / cell_m))
		var want: Array[Vector2i] = []
		for dz in range(-r, r + 1):
			for dx in range(-r, r + 1):
				var c := cc + Vector2i(dx, dz)
				var mid := (Vector2(c) + Vector2(0.5, 0.5)) * cell_m
				if mid.distance_to(Vector2(here.x, here.z)) <= keep_m and not _cells.has(c):
					want.append(c)
		want.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
			return (a - cc).length_squared() < (b - cc).length_squared())
		_queue = want
		var gone: Array[Vector2i] = []
		for c in _cells:
			var mid := (Vector2(c) + Vector2(0.5, 0.5)) * cell_m
			if mid.distance_to(Vector2(here.x, here.z)) > drop_m:
				gone.append(c)
		for c in gone:
			_unsolid(c)
			for row in _cells[c]:
				(_sets[row.key] as ImpostorLod).remove(int(row.handle))
				count -= 1
				_sorted_at.erase(row.key)
			_cells.erase(c)
	var t0 := Time.get_ticks_usec()
	while not _queue.is_empty() and Time.get_ticks_usec() - t0 < STREAM_BUDGET_US:
		var c: Vector2i = _queue.pop_front()
		if _cells.has(c):
			continue
		var cell_rect := Rect2i(c * STREAM_CELL, Vector2i(STREAM_CELL, STREAM_CELL))
		var rows := _place(Trees.scatter(cell_rect, world_seed, 4000, _chance_at, _variant_at))
		_cells[c] = rows
		count += rows.size()
		for row in rows:
			_sorted_at.erase(row.key)
		_solid_at = Vector3.INF
	if solid_m > 0.0:
		_solid_step(here, cell_m)


## Near cells' trunks solid, far ones not; looked at again once the camera
## has moved a couple of metres (or a cell came in).
func _solid_step(here: Vector3, cell_m: float) -> void:
	if _solid_at.distance_to(here) < 2.0:
		return
	_solid_at = here
	var at := Vector2(here.x, here.z)
	for c in _cells:
		var d := ((Vector2(c) + Vector2(0.5, 0.5)) * cell_m).distance_to(at)
		if d < solid_m and not _solid.has(c):
			_make_solid(c)
		elif d > solid_m * 1.5 and _solid.has(c):
			_unsolid(c)


func _make_solid(c: Vector2i) -> void:
	var rows: Array = _cells[c]
	if rows.is_empty() or not is_inside_tree():
		_solid[c] = RID()
		return
	var body := PhysicsServer3D.body_create()
	PhysicsServer3D.body_set_mode(body, PhysicsServer3D.BODY_MODE_STATIC)
	PhysicsServer3D.body_set_collision_layer(body, Layers.FIXTURE | Layers.TREE)
	PhysicsServer3D.body_set_collision_mask(body, 0)
	for row in rows:
		var v: int = row.variant
		var size := Trees.trunk_size(v)
		var foot: Vector3 = (row.xf as Transform3D) * Trees.trunk_foot(v)
		PhysicsServer3D.body_add_shape(body, _trunk_shape(v),
				Transform3D(Basis(), foot + Vector3(0, size.y * 0.5, 0)))
	PhysicsServer3D.body_set_state(body, PhysicsServer3D.BODY_STATE_TRANSFORM, global_transform)
	PhysicsServer3D.body_set_space(body, get_world_3d().space)
	_solid[c] = body
	set_notify_transform(true)


## Trunk bodies have no node: when this node moves (the mine world's origin
## shift) they move with it.
func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSFORM_CHANGED:
		for c in _solid:
			var body: RID = _solid[c]
			if body.is_valid():
				PhysicsServer3D.body_set_state(body, PhysicsServer3D.BODY_STATE_TRANSFORM, global_transform)


func _unsolid(c: Vector2i) -> void:
	var body: RID = _solid.get(c, RID())
	if body.is_valid():
		PhysicsServer3D.free_rid(body)
	_solid.erase(c)


func _trunk_shape(variant: int) -> RID:
	if not _trunk_shapes.has(variant):
		var s := PhysicsServer3D.box_shape_create()
		PhysicsServer3D.shape_set_data(s, Trees.trunk_size(variant) * 0.5)
		_trunk_shapes[variant] = s
	return _trunk_shapes[variant]


## How many cells have solid trunks, and how many trunks (probes, readout).
func solid_counts() -> Vector2i:
	var n := 0
	for c in _solid:
		if (_solid[c] as RID).is_valid():
			n += (_cells.get(c, []) as Array).size()
	return Vector2i(_solid.size(), n)


func _exit_tree() -> void:
	for c in _solid.keys():
		_unsolid(c)
	for v in _trunk_shapes:
		PhysicsServer3D.free_rid(_trunk_shapes[v])
	_trunk_shapes.clear()


func _place(spots: Array) -> Array:
	var rows := []
	for spot in spots:
		var variant: int = spot.variant
		var key := "tree_%d" % variant
		if not _sets.has(key):
			var s := ImpostorLod.new()
			s.name = "Trees_%d" % variant
			add_child(s)
			var tree_mesh := RecipeMesh.build(Trees.recipe(variant), key)
			# Its crowns move in the wind (weather.gdshaderinc).
			if tree_mesh != null:
				s.sway = WeatherFx.sway_tree(tree_mesh.get_aabb().end.y)
			s.snowcap = 1.0   # snow on the crowns
			s.set_chunk(chunk_metres)
			s.setup(tree_mesh, material, 45.0)
			_sets[key] = s
		var cell: Vector3i = spot.cell
		var xf := Trees.placement(cell, variant)
		var h := (_sets[key] as ImpostorLod).add(xf)
		var row := {"key": key, "handle": h, "x": cell.x, "z": cell.z, "variant": variant, "xf": xf}
		rows.append(row)
		if not streaming:
			_placed.append(row)
	return rows


## The last frame's _process, microseconds (the mine world's flight gate).
var last_us := 0


func _process(delta: float) -> void:
	var t_in := Time.get_ticks_usec()
	_process_body(delta)
	last_us = Time.get_ticks_usec() - t_in


func _process_body(delta: float) -> void:
	if _rebuild_in >= 0.0:
		_rebuild_in -= delta
		if _rebuild_in < 0.0:
			_rebuild()
	_frame += 1
	if streaming and camera != null:
		_stream_step()
	if camera == null or _sets.is_empty():
		return
	# Squares a budget left waiting (ImpostorLod.update's): refilled a little each
	# frame. One set's whole refill was a 44-140 ms frame flying low over a forest
	# on the planet (Docs/PlanetCost.md 7); these sets are as big.
	var t_d := Time.get_ticks_usec()
	for lod in _sets.values():
		if Time.get_ticks_usec() - t_d > SETS_BUDGET_US:
			break
		if (lod as ImpostorLod).has_pending():
			(lod as ImpostorLod).drain(SETS_BUDGET_US - (Time.get_ticks_usec() - t_d))
	if _frame % UPDATE_EVERY >= _sets.size():
		return
	# One set on each of the first frames of every UPDATE_EVERY.
	var keys := _sets.keys()
	var key: String = keys[_turn % keys.size()]
	_turn += 1
	var here := to_local(camera.global_position)
	var was: Vector3 = _sorted_at.get(key, Vector3.INF)
	if was.distance_to(here) < RESORT_METRES:
		return
	_sorted_at[key] = here
	(_sets[key] as ImpostorLod).update(here, SETS_BUDGET_US)


## Every set, now: after trees were added or taken away.
func _update() -> void:
	if camera == null:
		return
	var here := to_local(camera.global_position)
	for key in _sets:
		(_sets[key] as ImpostorLod).update(here)
		_sorted_at[key] = here
