extends Node

## THE RUBBLE FIELD (Docs/DestructionLod.md 3.5): wreckage at rest, far off,
## drawn tile by tile as merged meshes instead of a body or a mesh each --
## built on workers, coarsened with distance, ranked by what is seen.
##
## A part of the island manager, made by it (IslandManager.rubble), and moved
## out of island_manager.gd so this is in one place. It reads the manager
## through `host` -- typed against its script, so a name the manager no longer
## has is a parse error here.

const Host := preload("res://scripts/island_manager.gd")

var host: Host

## What sleeping wreckage leaves drawn -- its stand-ins (_leave_stand_in) -- is
## drawn a TILE at a time: every stand-in in one FIELD_TILE_M square merged into
## one mesh, a surface per material, the stand-ins' own nodes kept (hidden) for
## the piece to take back when it wakes. And only so many tiles are drawn: the
## FIELD_MAX_DRAWN that look biggest from where everybody is (apparent_size), so
## a tall wreck far off -- one seen from round the planet -- is drawn before a
## low heap nearer (user, 2026-10-25). Ranked every FIELD_RANK_TICKS; merged on
## workers (FIELD_JOBS at a time) once a tile has been quiet FIELD_QUIET_TICKS.
##
## Measured before (--rubble --big): 165 pieces asleep after a big collapse,
## each its own node and draw call; settled pieces cost the physics step
## nothing, and drawing them was 62 of 970 draw calls.
const FIELD_TILE_M := 32.0 * BrickPalette.STUD_M

const FIELD_MAX_DRAWN := 48

const FIELD_RANK_TICKS := 30

## A tile is merged once it has been left alone this long: a collapse puts its
## pieces to sleep one a tick, and merging on every one was 378 merges for 77
## tiles. Until then, and while its worker runs, its stand-ins draw themselves.
const FIELD_QUIET_TICKS := 30

## Off (--no-field), every stand-in draws itself and none is culled: the A/B.
var field_enabled := true

const FIELD_JOBS := 2

## A stand-in left as its BRICKS -- the cap puts pieces to sleep near as well as
## far, and 95 of 132 after a big collapse were -- has no arrays to merge from.
## Past the coarse ladder's range (ISLAND_MESH_RANGE + ISLAND_MESH_HYSTERESIS,
## where an awake piece would be coarse too) it is made coarse: its record made a
## chunk again, the coarse mesh built on a worker, the chunk given back, as
## build_due_stand_ins does for a save's. FIELD_COARSEN_JOBS at a time. Nearer,
## it keeps its bricks and draws itself.
const FIELD_COARSEN_JOBS := 2

var field_coarsened := 0

var _field_root: Node3D = null

var _field_ranked := -1000

var field_merges := 0          ## tiles merged, all told

var field_worst_ms := 0.0      ## the slowest worker merge

var field_main_worst_ms := 0.0 ## the slowest a merge cost the main thread

var field_drawn := 0           ## tiles drawn at the last ranking

var field_culled := 0          ## tiles the cap left undrawn at the last ranking


func _init(h: Node3D) -> void:
	host = h
	name = "RubbleField"


func _field_key_of(p: Vector3) -> Vector2i:
	return Vector2i(floori(p.x / FIELD_TILE_M), floori(p.z / FIELD_TILE_M))


func field_add(d: Host.Dormant) -> void:
	if not field_enabled or d.in_field or d.stand_in == null or not is_instance_valid(d.stand_in):
		return
	if _field_root == null:
		_field_root = Node3D.new()
		_field_root.name = "RubbleField"
		host.add_child(_field_root)
	var key := _field_key_of(d.stand_in.global_position)
	var tile: Host.FieldTile = host._field.get(key)
	if tile == null:
		tile = Host.FieldTile.new()
		host._field[key] = tile
	tile.members.append(d)
	d.field_key = key
	d.in_field = true
	_field_touch(tile)


## A piece waking takes its stand-in back, out of its tile: the tile draws its
## stand-ins one by one until it is merged again, so nothing is drawn twice.
func field_remove(d: Host.Dormant) -> void:
	if not d.in_field:
		return
	d.in_field = false
	if d.stand_in != null and is_instance_valid(d.stand_in):
		d.stand_in.visible = true
	var tile: Host.FieldTile = host._field.get(d.field_key)
	if tile == null:
		return
	tile.members.erase(d)
	_field_touch(tile)


## Changed: drawn piece by piece from now until merged again.
func _field_touch(tile: Host.FieldTile) -> void:
	tile.dirty = true
	tile.changed_tick = Engine.get_physics_frames()
	if tile.job >= 0:
		tile.restart = true
	_field_show(tile)


## What draws a tile: its merged mesh when that is up to date, else each of
## its stand-ins -- and neither when the cap has culled it.
func _field_show(tile: Host.FieldTile) -> void:
	var merged := not tile.dirty and tile.node != null and is_instance_valid(tile.node)
	if tile.node != null and is_instance_valid(tile.node):
		tile.node.visible = tile.shown and merged
	for d in tile.members:
		var dd: Host.Dormant = d
		if dd.stand_in != null and is_instance_valid(dd.stand_in):
			dd.stand_in.visible = tile.shown and (not merged or dd.stand_in_arrays.is_empty())


func tend_field() -> void:
	if host._field.is_empty():
		return
	var now := Engine.get_physics_frames()
	for key in host._field.keys():
		var tile: Host.FieldTile = host._field[key]
		if tile.job >= 0:
			if WorkerThreadPool.is_task_completed(tile.job):
				_field_finish(tile)
			continue
		if tile.dirty and host._field_jobs < FIELD_JOBS and now - tile.changed_tick >= FIELD_QUIET_TICKS:
			_field_start(key, tile)
	if not host._coarsening.is_empty():
		_field_coarsen_finish()
	if now - _field_ranked >= FIELD_RANK_TICKS:
		_field_ranked = now
		_field_rank()
		_field_coarsen_start()


## Hand a tile's stand-ins to a worker to merge. Members whose piece has woken
## or gone are dropped here; an empty tile is freed.
func _field_start(key: Vector2i, tile: Host.FieldTile) -> void:
	var t0 := Time.get_ticks_usec()
	var into := _field_root.global_transform.affine_inverse()
	var items: Array = []
	for i in range(tile.members.size() - 1, -1, -1):
		var d: Host.Dormant = tile.members[i]
		if not host.dormant.has(d) or d.stand_in == null or not is_instance_valid(d.stand_in) \
				or d.stand_in.mesh == null:
			d.in_field = false
			tile.members.remove_at(i)
			continue
		if d.stand_in_arrays.is_empty():
			continue   # drawn by itself (_field_show)
		var node := d.stand_in
		items.append([d.stand_in_arrays, into * node.global_transform,
				node.material_override if node.material_override != null else host.brick_material])
	if tile.members.is_empty():
		if tile.node != null and is_instance_valid(tile.node):
			tile.node.queue_free()
		host._field.erase(key)
		return
	tile.dirty = false
	if items.is_empty():
		_field_show(tile)   # every one of them draws itself
		return
	tile.restart = false
	var holder := [null, AABB()]
	tile.holder = holder
	tile.job = WorkerThreadPool.add_task(func() -> void:
		var t := Time.get_ticks_usec()
		var built := IslandManager._field_build(items)
		UploadLedger.note("rubble field", -1)
		holder[0] = built[0]
		holder[1] = built[1]
		holder.append(float(Time.get_ticks_usec() - t) / 1000.0), true, "rubble field")
	host._field_jobs += 1
	field_main_worst_ms = maxf(field_main_worst_ms, float(Time.get_ticks_usec() - t0) / 1000.0)


func _field_finish(tile: Host.FieldTile) -> void:
	var t0 := Time.get_ticks_usec()
	WorkerThreadPool.wait_for_task_completion(tile.job)
	tile.job = -1
	host._field_jobs -= 1
	var mesh: ArrayMesh = tile.holder[0]
	if tile.holder.size() > 2:
		field_worst_ms = maxf(field_worst_ms, float(tile.holder[2]))
	if tile.restart or mesh == null:
		# Changed while it was merged: what it made is already out of date.
		tile.dirty = true
		_field_show(tile)
		return
	if tile.node == null or not is_instance_valid(tile.node):
		tile.node = MeshInstance3D.new()
		tile.node.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		_field_root.add_child(tile.node)
	tile.node.mesh = mesh
	tile.box = _field_root.global_transform * (tile.holder[1] as AABB)
	field_merges += 1
	_field_show(tile)
	field_main_worst_ms = maxf(field_main_worst_ms, float(Time.get_ticks_usec() - t0) / 1000.0)


## Start making far stand-ins of bricks coarse (FIELD_COARSEN_JOBS).
func _field_coarsen_start() -> void:
	# Read once, not per pass of the loop below: the scene never swaps these.
	var h_world := host.world
	if host._coarsening.size() >= FIELD_COARSEN_JOBS:
		return
	var points := host.interest_points()
	if points.is_empty():
		return
	var busy := {}
	for c in host._coarsening:
		busy[c[0]] = true
	for d in host.dormant:
		if host._coarsening.size() >= FIELD_COARSEN_JOBS:
			return
		if busy.has(d) or not d.stand_in_arrays.is_empty() or d.stand_in == null \
				or not is_instance_valid(d.stand_in) or d.record.block_count() <= 1:
			continue
		if host._distance_to_interest(d.record.box, points) < Host.ISLAND_MESH_RANGE + Host.ISLAND_MESH_HYSTERESIS:
			continue
		var chunk := d.record.restore(h_world)
		if chunk < 0:
			continue
		h_world.coarse_chunk_async(chunk)
		host._coarsening.append([d, chunk])


func _field_coarsen_finish() -> void:
	# Read once, not per pass of the loop below: the scene never swaps these.
	var h_world := host.world
	for i in range(host._coarsening.size() - 1, -1, -1):
		var d: Host.Dormant = host._coarsening[i][0]
		var chunk: int = host._coarsening[i][1]
		if not h_world.coarse_ready(chunk):
			if not h_world.coarse_pending(chunk):
				h_world.coarse_chunk_async(chunk)
			continue
		host._coarsening.remove_at(i)
		var arrays: Array = h_world.take_coarse_mesh(chunk)
		h_world.release_chunk(chunk)
		# Woken meanwhile: it has its own mesh now.
		if not host.dormant.has(d) or d.stand_in == null or not is_instance_valid(d.stand_in):
			continue
		if arrays.is_empty() or not Host.mesh_arrays_ok(arrays, "coarse stand-in of piece %d" % d.piece_id):
			continue
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		d.stand_in.mesh = mesh
		d.stand_in.material_override = host.brick_material
		d.stand_in.transform = d.record.xform
		d.stand_in_arrays = arrays
		field_coarsened += 1
		var tile: Host.FieldTile = host._field.get(d.field_key)
		if d.in_field and tile != null:
			_field_touch(tile)


## The cap: the FIELD_MAX_DRAWN tiles that look biggest are drawn, the rest
## are not (still asleep, still there, only unseen). Every tile within the
## coarse ladder's range is drawn whatever the count -- the cap is for FAR
## wreckage -- and fills the cap first. A tile not merged yet is ranked by its
## stand-ins' own boxes.
func _field_rank() -> void:
	var points := host.interest_points()
	if points.is_empty():
		return
	var tiles: Array = []
	var seen := {}
	for key in host._field:
		var tile: Host.FieldTile = host._field[key]
		var box := tile.box
		if box.size == Vector3.ZERO:
			for d in tile.members:
				var dd: Host.Dormant = d
				box = dd.record.box if box.size == Vector3.ZERO else box.merge(dd.record.box)
		var dist := host._distance_to_interest(box, points)
		# Near wreckage is never culled: it would blink out at somebody's feet.
		# It is drawn, and counts against the cap.
		seen[tile] = INF if dist < Host.ISLAND_MESH_RANGE + Host.ISLAND_MESH_HYSTERESIS 				else Host.apparent_size(box, dist)
		tiles.append(tile)
	tiles.sort_custom(func(a, c) -> bool: return float(seen[a]) > float(seen[c]))
	field_drawn = 0
	field_culled = 0
	for i in tiles.size():
		var tile: Host.FieldTile = tiles[i]
		tile.shown = i < FIELD_MAX_DRAWN or is_inf(float(seen[tile]))
		_field_show(tile)
		if tile.shown:
			field_drawn += 1
		else:
			field_culled += 1
