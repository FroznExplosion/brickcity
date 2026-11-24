class_name TerrainDeep
extends Node3D

## THE DEEP TIER (Docs/MineWorld.md 16): the underground under the surface
## tiles' floors, in SECTIONS -- a tile column's plates [sy, sy + 1) *
## DEEP_SECTION_PLATES, clipped to the bedrock below and the tile's floor
## (BrickTerrain.deep_top) above -- baked by BrickTerrain.build_section and
## drawn by TerrainTile, the surface tiles' own node (a section's result has
## the same keys: a mesh, colliders, no studs).
##
## Streamed round the EYE in 3D, and only while the eye is underground
## (`UNDER_PLATES` under the surface of its column): a player on the surface
## loads none. Never waits on a worker; a few node builds and a capped number
## of collider shapes a frame. `hold` (moving fast, MineWorld.md 14) starts no
## new bakes. A child of the mine world, so the origin shift moves it whole
## (MineWorld.md 15) and its colliders follow their nodes.

## Tiles round the eye's tile, and sections above and below the eye's.
@export var radius := 2
@export var up := 1
@export var down := 1
## Sections within this many tiles (and one section up or down) collide.
@export var collide_radius := 1
@export var max_in_flight := 4
@export var budget_ms := 1.5
## Collider shapes added a frame per section (TerrainTile.add_collision).
@export var shapes_per_frame := 48
## How far under its column's surface the eye must be for the tier to load.
const UNDER_PLATES := 30

var hold := false
var active := false
var built := 0
var dropped := 0
var worst_ms := 0.0

var _material: Material = null
## Vector3i(tx, sy, tz) -> TerrainTile, or null for a section that owns no
## plates (above the floor, under the bedrock).
var _secs := {}
## Vector3i -> [task id, holder]
var _tasks := {}
var _dirty := {}
## In flight when an edit landed: baked again when it lands.
var _stale := {}
var _centre := Vector3i(1 << 30, 0, 0)
var _want: Array[Vector3i] = []
var _collide_pending := {}
## Out of range since (msec), by section: a section goes only after LINGER_MS
## out of range, so an eye that jumps for a frame (a landing, a teleport)
## does not take the floor away.
var _out_since := {}
const LINGER_MS := 600
## REFRESHES SWAP TOGETHER, as the surface tiles' do (TerrainStreamer,
## Docs/MineWorld.md 20): a refreshed section is built hidden and collided
## (`_swaps`, key -> the new TerrainTile or null for none), and the sections
## one edit named (a batch) swap in one frame once all are built; a held
## section (hold_box, ground_collapse.gd) waits for its holder.
var _swaps := {}
var _batch_of := {}
var _holds := {}
const BATCH_WAIT_MS := 300


func setup(material: Material) -> void:
	_material = material


func _exit_tree() -> void:
	# A worker still inside BrickTerrain when the scene goes crashed the
	# engine on the way out (TerrainStreamer._exit_tree): land every bake.
	for k in _tasks:
		WorkerThreadPool.wait_for_task_completion(_tasks[k][0])
	_tasks.clear()


static func section_of(p: Vector3) -> Vector3i:
	var tile_m := float(BrickTerrain.get_tile_studs()) * BrickWorld.get_stud_metres()
	var yp := floori(p.y / BrickWorld.get_plate_metres())
	return Vector3i(floori(p.x / tile_m), floori(float(yp) / BrickTerrain.get_deep_section_plates()),
			floori(p.z / tile_m))


## Each frame, with the eye in the terrain frame.
func follow(eye: Vector3) -> void:
	var t0 := Time.get_ticks_usec()
	var stud := BrickWorld.get_stud_metres()
	var eye_p := floori(eye.y / BrickWorld.get_plate_metres())
	# Under the column's GENERATED surface: in a shaft the player dug, the
	# current surface is the shaft's bottom and the tier never came on.
	active = eye_p < BrickTerrain.generated_plate(floori(eye.x / stud), floori(eye.z / stud)) - UNDER_PLATES
	var c := section_of(eye)
	if c != _centre:
		_centre = c
		_plan()
	_land(t0)
	# A batch waiting on a straggler swaps once its wait is over.
	for k in _swaps.keys():
		if _swaps.has(k):
			_swap_batch(k)
	if active and not hold:
		_start()
	_drop()
	_collide(t0)
	worst_ms = maxf(worst_ms, float(Time.get_ticks_usec() - t0) / 1000.0)


func _plan() -> void:
	_want.clear()
	for dz in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			for dy in range(-down, up + 1):
				_want.append(_centre + Vector3i(dx, dy, dz))
	_want.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
		return (a - _centre).length_squared() < (b - _centre).length_squared())
	_collide_pending.clear()
	for k in _secs:
		if _secs[k] != null and _near(k):
			_collide_pending[k] = true


func _near(k: Vector3i) -> bool:
	return absi(k.x - _centre.x) <= collide_radius and absi(k.z - _centre.z) <= collide_radius \
			and absi(k.y - _centre.y) <= 1


func _start() -> void:
	# Edits first, with EDIT_SLOTS more in flight than new sections may take
	# (TerrainStreamer's rule, Docs/MineWorld.md 21): a hole in a cave wall
	# does not wait behind the caves loading round it.
	var edits: Array[Vector3i] = []
	for k in _want:
		if _dirty.has(k) and _secs.has(k) and not _tasks.has(k):
			edits.append(k)
	for k in edits:
		if _tasks.size() >= max_in_flight + TerrainStreamer.EDIT_SLOTS:
			return
		_start_one(k)
	var fresh := 0
	for k in _tasks:
		if not _secs.has(k):
			fresh += 1
	for k in _want:
		if fresh >= max_in_flight:
			return
		if _tasks.has(k) or (_secs.has(k) and not _dirty.has(k)):
			continue
		_start_one(k)
		fresh += 1


func _start_one(k: Vector3i) -> void:
	var holder := [{}]
	var task := WorkerThreadPool.add_task(
		func() -> void: holder[0] = BrickTerrain.build_section(k.x, k.y, k.z),
		true, "deep section")
	_tasks[k] = [task, holder]
	_dirty.erase(k)


func _land(t0: int) -> void:
	for k in _tasks.keys():
		if float(Time.get_ticks_usec() - t0) / 1000.0 >= budget_ms:
			return
		var job: Array = _tasks[k]
		if not WorkerThreadPool.is_task_completed(job[0]):
			continue
		WorkerThreadPool.wait_for_task_completion(job[0])
		_tasks.erase(k)
		if _stale.has(k):
			_stale.erase(k)
			_dirty[k] = true
			continue
		var data: Dictionary = job[1][0]
		var refresh := _secs.has(k)
		var tile: TerrainTile = null
		if data.has("own_lo") and not ((data.mesh as Array).is_empty() and (data.boxes as PackedFloat32Array).is_empty()):
			tile = TerrainTile.new()
			tile.name = "Deep_%d_%d_%d" % [k.x, k.y, k.z]
			tile.phases = true
			add_child(tile)
			tile.build(k.x, k.z, _material, data)
			tile.set_casts_shadow(false)
			# Studs on its cave floors (Docs/MineWorld.md 20).
			tile.set_near(true)
			built += 1
		if refresh:
			# A refresh: hidden and collided now (ground just rebuilt under
			# the player must not go a frame without collision), swapped with
			# its batch.
			if _swaps.has(k) and _swaps[k] != null:
				(_swaps[k] as TerrainTile).recycle()
				(_swaps[k] as TerrainTile).queue_free()
			if tile != null:
				tile.visible = false
				if _near(k):
					tile.add_collision()
			_swaps[k] = tile
			_swap_batch(k)
			continue
		_secs[k] = tile
		if tile != null:
			tile.add_instances()
			if _near(k):
				_collide_pending[k] = true


func _collide(t0: int) -> void:
	for k in _collide_pending.keys():
		if float(Time.get_ticks_usec() - t0) / 1000.0 >= budget_ms:
			return
		var tile = _secs.get(k)
		if tile == null or not _near(k):
			_collide_pending.erase(k)
			continue
		if (tile as TerrainTile).add_collision(shapes_per_frame):
			_collide_pending.erase(k)


func _drop() -> void:
	var n := 0
	var now := Time.get_ticks_msec()
	for k in _secs.keys():
		if absi(k.x - _centre.x) <= radius + 1 and absi(k.z - _centre.z) <= radius + 1 \
				and k.y >= _centre.y - down - 1 and k.y <= _centre.y + up + 1:
			_out_since.erase(k)
			continue
		if not _out_since.has(k):
			_out_since[k] = now
		if now - int(_out_since[k]) < LINGER_MS:
			continue
		_out_since.erase(k)
		var tile = _secs[k]
		_secs.erase(k)
		_dirty.erase(k)
		_drop_swap(k)
		_batch_of.erase(k)
		_holds.erase(k)
		if tile != null:
			(tile as TerrainTile).recycle()
			(tile as TerrainTile).queue_free()
			dropped += 1
			n += 1
			if n >= 4:
				return


## An edit's plate box (fill_box, clear_runs, carve: box_lo / box_hi, cells):
## the sections it touches are baked again, behind the drawn ones.
func refresh_box(lo: Vector3i, hi: Vector3i) -> void:
	var batch := {"keys": {}, "since": 0}
	for k in _box_keys(lo, hi):
		if _tasks.has(k):
			_stale[k] = true
		elif _secs.has(k):
			_dirty[k] = true
		else:
			continue
		if not _secs.has(k):
			continue   # a first bake: nothing to swap
		batch.keys[k] = true
		var old = _batch_of.get(k)
		if old != null and old != batch:
			for t in old.keys:
				batch.keys[t] = true
	for t in batch.keys:
		_batch_of[t] = batch


## The sections an edit's plate box touches, one cell out: a face on a
## section's edge is decided by its neighbour.
func _box_keys(lo: Vector3i, hi: Vector3i) -> Array[Vector3i]:
	var tile := BrickTerrain.get_tile_studs()
	var sec := BrickTerrain.get_deep_section_plates()
	var a := Vector3i(floori(float(lo.x - 1) / tile), floori(float(lo.y - 1) / sec), floori(float(lo.z - 1) / tile))
	var b := Vector3i(floori(float(hi.x + 1) / tile), floori(float(hi.y + 1) / sec), floori(float(hi.z + 1) / tile))
	var out: Array[Vector3i] = []
	for z in range(a.z, b.z + 1):
		for y in range(a.y, b.y + 1):
			for x in range(a.x, b.x + 1):
				out.append(Vector3i(x, y, z))
	return out


## Hold the sections over an edit's box for `owner` (TerrainStreamer.hold_tiles).
func hold_box(lo: Vector3i, hi: Vector3i, owner) -> void:
	for k in _box_keys(lo, hi):
		if _secs.has(k):
			if not _holds.has(k):
				_holds[k] = {}
			_holds[k][owner] = true


func unhold(owner) -> void:
	for k in _holds.keys():
		(_holds[k] as Dictionary).erase(owner)
		if (_holds[k] as Dictionary).is_empty():
			_holds.erase(k)


## Could every refresh over the box, and the rest of each one's batch, swap
## now (holds by anyone but `owner` aside)? Nothing waiting: true. An
## inactive tier bakes nothing: what it holds stays as drawn (true).
func ready_box(lo: Vector3i, hi: Vector3i, owner = null) -> bool:
	if not active:
		return true
	for k in _batch_keys(lo, hi):
		if not _sec_ready(k, owner):
			return false
	return true


## Swap every batch over the box that is ready, now.
func swap_ready_box(lo: Vector3i, hi: Vector3i) -> void:
	for k in _batch_keys(lo, hi):
		if _swaps.has(k):
			_swap_batch(k, true)


func _batch_keys(lo: Vector3i, hi: Vector3i) -> Array:
	var out := {}
	for k in _box_keys(lo, hi):
		if not _secs.has(k):
			continue
		out[k] = true
		var b = _batch_of.get(k)
		if b != null:
			for t in b.keys:
				out[t] = true
	return out.keys()


func _held(k: Vector3i, owner = null) -> bool:
	var h = _holds.get(k)
	if h == null:
		return false
	for o in h:
		if o != owner:
			return true
	return false


func _sec_ready(k: Vector3i, owner = null) -> bool:
	if not _secs.has(k):
		return true
	return not _tasks.has(k) and not _dirty.has(k) and not _stale.has(k) and not _held(k, owner)


func _swap_batch(k: Vector3i, force := false) -> void:
	var b = _batch_of.get(k)
	var keys: Array = b.keys.keys() if b != null else [k]
	var all := true
	for t in keys:
		if _held(t):
			return
		if not _sec_ready(t):
			all = false
	if not all:
		if b == null or force:
			return
		var now := Time.get_ticks_msec()
		if int(b.since) == 0:
			b.since = now
		if now - int(b.since) < BATCH_WAIT_MS:
			return
	for t in keys:
		if _swaps.has(t) and _sec_ready(t):
			_swap_now(t)
			if b != null and _batch_of.get(t) == b:
				_batch_of.erase(t)
	if all and b != null:
		for t in keys:
			if _batch_of.get(t) == b:
				_batch_of.erase(t)


func _swap_now(k: Vector3i) -> void:
	var tile = _swaps[k]
	_swaps.erase(k)
	var old = _secs.get(k)
	if old != null:
		(old as TerrainTile).recycle()
		(old as TerrainTile).queue_free()
	_secs[k] = tile
	if tile != null:
		(tile as TerrainTile).add_instances()
		(tile as TerrainTile).visible = true


func _drop_swap(k: Vector3i) -> void:
	if _swaps.has(k):
		var t = _swaps[k]
		if t != null and is_instance_valid(t):
			(t as TerrainTile).recycle()
			(t as TerrainTile).queue_free()
		_swaps.erase(k)


func clear() -> void:
	for k in _tasks:
		WorkerThreadPool.wait_for_task_completion(_tasks[k][0])
	_tasks.clear()
	for k in _secs:
		if _secs[k] != null:
			(_secs[k] as TerrainTile).queue_free()
	for k in _swaps.keys():
		_drop_swap(k)
	_secs.clear()
	_batch_of.clear()
	_holds.clear()
	_dirty.clear()
	_stale.clear()
	_collide_pending.clear()
	_centre = Vector3i(1 << 30, 0, 0)


func section_count() -> int:
	var n := 0
	for k in _secs:
		if _secs[k] != null:
			n += 1
	return n


func report() -> String:
	return "%s, %d sections drawn (%d known), %d baking, %d built, %d dropped, worst %.1f ms" % [
			"underground" if active else "off (on the surface)", section_count(), _secs.size(),
			_tasks.size(), built, dropped, worst_ms]
