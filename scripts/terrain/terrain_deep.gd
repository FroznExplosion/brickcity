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
	for k in _want:
		if _tasks.size() >= max_in_flight:
			return
		if _tasks.has(k) or (_secs.has(k) and not _dirty.has(k)):
			continue
		var holder := [{}]
		var key := k
		var task := WorkerThreadPool.add_task(
			func() -> void: holder[0] = BrickTerrain.build_section(key.x, key.y, key.z),
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
		var old = _secs.get(k)
		if old != null:
			(old as TerrainTile).recycle()
			(old as TerrainTile).queue_free()
		if not data.has("own_lo") or (data.mesh as Array).is_empty() and (data.boxes as PackedFloat32Array).is_empty():
			_secs[k] = null
			continue
		var tile := TerrainTile.new()
		tile.name = "Deep_%d_%d_%d" % [k.x, k.y, k.z]
		tile.phases = true
		add_child(tile)
		tile.build(k.x, k.z, _material, data)
		tile.set_casts_shadow(false)
		_secs[k] = tile
		built += 1
		if _near(k):
			# Ground just rebuilt under the player must not go a frame
			# without collision (as TerrainStreamer does for refreshes).
			if old != null:
				tile.add_collision()
			else:
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
	var tile := BrickTerrain.get_tile_studs()
	var sec := BrickTerrain.get_deep_section_plates()
	# One cell out: a face on a section's edge is decided by its neighbour.
	var a := Vector3i(floori(float(lo.x - 1) / tile), floori(float(lo.y - 1) / sec), floori(float(lo.z - 1) / tile))
	var b := Vector3i(floori(float(hi.x + 1) / tile), floori(float(hi.y + 1) / sec), floori(float(hi.z + 1) / tile))
	for z in range(a.z, b.z + 1):
		for y in range(a.y, b.y + 1):
			for x in range(a.x, b.x + 1):
				var k := Vector3i(x, y, z)
				if _tasks.has(k):
					_stale[k] = true
				elif _secs.has(k):
					_dirty[k] = true


func clear() -> void:
	for k in _tasks:
		WorkerThreadPool.wait_for_task_completion(_tasks[k][0])
	_tasks.clear()
	for k in _secs:
		if _secs[k] != null:
			(_secs[k] as TerrainTile).queue_free()
	_secs.clear()
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
