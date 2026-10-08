class_name TerrainStreamer
extends Node3D

## Keeps the detailed terrain tiles around the camera, and nothing else.
## [Docs/Terrain.md](../Docs/Terrain.md) §19.6.
##
## The world is a fixed authored size, not an infinite field — so this is not
## a chunk streamer in the Minecraft sense and does not pretend to be. The
## coarse tier (§19.4) covers the WHOLE world and is built once; what streams
## is the near tier, which is the expensive half: packed pieces, studs,
## scatter and a collider, ~9 ms of C++ and main-thread assembly a tile.
##
## Three rules, and the middle one is the whole point:
##
##   1. Bake on worker threads. `build_tile` only reads the field.
##   2. Assemble on the main thread under a TIME BUDGET. Node creation and
##      mesh upload cannot leave the main thread, so the only lever is how
##      much of it happens in one frame. A budget turns a 9-second freeze
##      into a few milliseconds a frame for a few seconds.
##   3. Drop tiles behind you, with hysteresis, so walking a boundary does
##      not rebuild the same tile every step.

## The detailed region is snapped OUTWARD to this many tiles.
##
## It has to match the coarse tier's smallest block, because that is what
## makes "is this block covered by detail" a yes or a no. Unaligned, a coarse
## block is partly covered — and a partly covered block cannot be hidden
## without leaving a hole, or kept without poking through the detail, since
## its height is the MAX over its cells.
@export var align := 4

## Tiles of full detail either side of the camera. 3 is a 7x7 square, 78 m.
@export var near_radius := 3
## ...and how far out a built tile is kept before it is dropped. The gap
## between this and `near_radius` is the hysteresis.
@export var keep_radius := 5
## The authored world, in tiles either side of the origin. Nothing is built
## outside it — this world has edges and knows where they are.
@export var world_half := 50
## Hold the WHOLE world resident, wherever the camera is.
##
## For an authored place small enough to afford it — a city is 96 m across —
## and it buys two things streaming cannot: the ground a collapse lands on is
## never half-built, and the hole in the coarse tier never moves, so the far
## tier can be baked once and never thought about again.
##
## It also fixes a failure that is easy to miss. The region is centred on the
## CAMERA, so a camera standing outside the world looking in — which is where
## every scripted pass puts it — asks for the near half and no more: the big
## city got 144 of its 625 tiles and the far half of it stood on coarse
## ground.
@export var whole_world := false
## How long assembly may take in one frame. Three milliseconds of a sixteen
## millisecond frame is a fifth of the budget and invisible in practice.
@export var budget_ms := 1.5
## How many tiles may be baking at once. More than the core count only makes
## the queue longer.
@export var max_in_flight := 8
## Tiles within this many of the camera get a COLLIDER. Collision is the most
## expensive phase and the only one nobody can see; you cannot stand on a
## tile four away from you.
##
## NEGATIVE means every resident tile, for a small world held whole: debris
## from a collapse two streets away still has to land on something.
@export var collide_radius := 2
## Tiles within this many of the camera cast into the sun's shadow map.
##
## ZERO by default: the ground bakes its own sun shadow at build time
## (BrickTerrain.set_sun_direction), so it has no reason to be in the shadow
## map at all. Raise it to compare the two.
@export var shadow_radius := 0
## Collision boxes added per frame per tile; 0 is the whole collider at once.
## The cap was 32 because a whole collider measured an 18.9 ms spike -- but
## that was Jolt rebuilding its compound on every box added to a body already
## in the space. Added before the body joins (TerrainTile.add_collision) a
## whole 670-box tile is 0.77 ms, so it goes in one call.
@export var shapes_per_frame := 0

var _material: Material = null
var _tiles := {}          ## Vector2i -> TerrainTile
var _tasks := {}          ## Vector2i -> slot index
## Resident tiles an edit made stale: shown until their replacement lands.
var _dirty := {}
## Bakes in flight that started before an edit over them: thrown away.
var _stale := {}
var _slot_task: Array[int] = []
var _slot_coord: Array[Vector2i] = []
var _slots: Array[Dictionary] = []
var _free_slots: Array[int] = []

var _built := 0
var _dropped := 0
var _assemble_ms := 0.0
var _worst_tile_ms := 0.0
var _centre := Vector2i.ZERO
## The centre the shadow flags were last set for: they only change when it
## moves (a new tile gets its flag in _finish).
var _shadow_centre := Vector2i(1 << 30, 0)
## Some tile still has a phase to add (instances, collision in reach). When
## nothing does, _finish is not run: it sorted and walked every resident tile
## each frame to find nothing to do, ~1 ms of an idle frame.
var _finish_pending := true
## Tiles within this many of the camera get the chamfered near mesh
## (TerrainTile.add_bevel). It is shown within near_show_radius (about
## one tile), so two is enough with a margin, and nothing further pays for it.
@export var bevel_radius := 2
## Tiles within this ring SHOW their detailed version (chamfer, bevelled
## studs); `bevel_radius` bakes one ring further ahead so it is ready.
@export var near_show_radius := 1
var _near_centre := Vector2i(1 << 30, 0)
## Chamfered bakes in flight: tile coord -> [task id, result holder, tile].
var _bevel_tasks := {}
const BEVEL_IN_FLIGHT := 2
## Worst single phase seen, split three ways — which one hurts is the whole
## question when a hitch has to be chased.
var _worst_surface_ms := 0.0
var _worst_inst_ms := 0.0
var _worst_coll_ms := 0.0


func setup(material: Material) -> void:
	_material = material
	for i in max_in_flight:
		_slots.append({})
		_slot_task.append(-1)
		_slot_coord.append(Vector2i.ZERO)
		_free_slots.append(i)


## Leaving the tree with bakes in flight: wait for them, and keep nothing.
##
## A worker still inside BrickTerrain when the scene goes away -- a gate that
## quits the moment it has its answer -- crashed the engine on the way out
## (the combat arena's gate, twice in two runs, once the chamfered bakes ran
## under the city too: Docs/Terrain.md §22.15). A bake is a few milliseconds.
func _exit_tree() -> void:
	for slot in _slot_task.size():
		if _slot_task[slot] < 0:
			continue
		WorkerThreadPool.wait_for_task_completion(_slot_task[slot])
		_slot_task[slot] = -1
		_slots[slot] = {}
		_free_slots.append(slot)
	_tasks.clear()
	_stale.clear()
	for c in _bevel_tasks:
		WorkerThreadPool.wait_for_task_completion(_bevel_tasks[c][0])
	_bevel_tasks.clear()


## Call every frame with the camera's world position.
func follow(camera_xz: Vector2) -> void:
	var tile_m := float(BrickTerrain.get_tile_studs()) * BrickWorld.get_stud_metres()
	var cx := int(floor(camera_xz.x / tile_m))
	var cz := int(floor(camera_xz.y / tile_m))
	if _centre != Vector2i(cx, cz):
		_finish_pending = true    # collision reach moved with it
	_centre = Vector2i(cx, cz)
	_collect(cx, cz)
	_drop(cx, cz)
	_assemble()
	_bevel_step()
	if _near_centre != _centre:
		_near_centre = _centre
		for c in _tiles:
			(_tiles[c] as TerrainTile).set_near(absi(c.x - cx) <= near_show_radius
					and absi(c.y - cz) <= near_show_radius)
	if _shadow_centre != _centre:
		_shadow_centre = _centre
		for c in _tiles:
			(_tiles[c] as TerrainTile).set_casts_shadow(
				absi(c.x - cx) <= shadow_radius and absi(c.y - cz) <= shadow_radius)


## Start chamfered bakes for near tiles that lack one, and hand finished
## ones to their tiles -- if the tile is still the one the bake was for (a
## refreshed tile is a new node, and gets a new bake).
func _bevel_step() -> void:
	if not TerrainTile.bevel_enabled:
		return
	for c in _bevel_tasks.keys():
		var job: Array = _bevel_tasks[c]
		if not WorkerThreadPool.is_task_completed(job[0]):
			continue
		WorkerThreadPool.wait_for_task_completion(job[0])
		_bevel_tasks.erase(c)
		var tile = job[2]
		if is_instance_valid(tile) and _tiles.get(c) == tile and tile.needs_bevel():
			tile.add_bevel(job[1][0])
	if _bevel_tasks.size() >= BEVEL_IN_FLIGHT:
		return
	for dz in range(-bevel_radius, bevel_radius + 1):
		for dx in range(-bevel_radius, bevel_radius + 1):
			var c := _centre + Vector2i(dx, dz)
			if _bevel_tasks.has(c) or not _tiles.has(c):
				continue
			var tile: TerrainTile = _tiles[c]
			if not tile.needs_bevel():
				continue
			var holder := [{}]
			var task := WorkerThreadPool.add_task(
				func() -> void: holder[0] = BrickTerrain.build_tile_chamfered(c.x, c.y, TerrainTile.BEVEL),
				true, "terrain chamfer")
			_bevel_tasks[c] = [task, holder, tile]
			if _bevel_tasks.size() >= BEVEL_IN_FLIGHT:
				return


## Build everything the camera wants, now, blocking. For captures and
## benchmarks, which must not photograph a half-built world.
func settle(camera_xz: Vector2, rounds := 4000) -> void:
	for i in rounds:
		follow(camera_xz)
		if _tasks.is_empty() and _wanted_missing(camera_xz) == 0:
			# One more pass with no budget, so a settled world is whole and
			# not three frames from being whole.
			var saved := budget_ms
			var saved_shapes := shapes_per_frame
			budget_ms = 1e9
			shapes_per_frame = 0        # no cap: finish them
			for pass_i in 3:
				_finish(Time.get_ticks_usec())
			budget_ms = saved
			shapes_per_frame = saved_shapes
			# And the chamfered near meshes, so a capture sees them.
			for b in 4000:
				_bevel_step()
				if _bevel_tasks.is_empty():
					break
				OS.delay_msec(1)
			return


## Rebuild the tiles over a rectangle WITHOUT taking them away first.
##
## For a brush stroke: `invalidate` leaves a hole until the new tile lands,
## and a stroke refreshes the same ground ten times a second. Here the old
## tile stays on screen, a new one bakes behind it, and it is swapped in
## when ready. A bake already in flight over the rectangle read the field
## BEFORE the edit, so its result is thrown away and it bakes again.
func refresh(rect: Rect2i) -> void:
	for c in _tiles:
		if rect.has_point(c):
			_dirty[c] = true
	for c in _tasks:
		if rect.has_point(c):
			_stale[c] = true


## Throw away the tiles over a rectangle so they are built again.
##
## For the level EDITOR: an edit changes the field, so every tile over it is
## stale — and only those. A pad is tens of studs across and the world is
## thousands, so rebuilding the rectangle rather than the world is the
## difference between an editor that answers a keypress and one that stops.
func invalidate(rect: Rect2i) -> void:
	var gone: Array[Vector2i] = []
	for c in _tiles:
		if rect.has_point(c):
			gone.append(c)
	for c in _tasks:
		if rect.has_point(c):
			_stale[c] = true
	for c in gone:
		var tile: TerrainTile = _tiles[c]
		_tiles.erase(c)
		tile.queue_free()


## Forget what the startup cost; a walk's numbers are the interesting ones.
func reset_stats() -> void:
	_built = 0
	_dropped = 0
	_worst_tile_ms = 0.0
	_worst_surface_ms = 0.0
	_worst_inst_ms = 0.0
	_worst_coll_ms = 0.0


## Is this tile BUILT? Not "wanted" — built. The coarse tier asks before it
## hides itself, and the difference matters: the wanted region fills at a few
## tiles a frame, so hiding against the region opened a black pit the size of
## the detail square every time the camera jumped.
func has_tile(c: Vector2i) -> bool:
	return _tiles.has(c)


## The coordinates of every resident tile. For the gate, which has to ask
## what IS built rather than what was asked for.
func tiles_at() -> Array:
	return _tiles.keys()


func built_count() -> int:
	return _built


func worst_phase_ms() -> float:
	return _worst_tile_ms


func tile_count() -> int:
	return _tiles.size()


func report() -> String:
	return "%d resident  %d built  %d dropped  worst %.1f ms (surface %.1f, inst %.1f, coll %.1f)" % [
		_tiles.size(), _built, _dropped, _worst_tile_ms,
		_worst_surface_ms, _worst_inst_ms, _worst_coll_ms]


func tiles() -> Array:
	return _tiles.values()


# ---------------------------------------------------------------------------

## The detailed region for a camera tile, snapped out to the alignment.
func region(cx: int, cz: int) -> Rect2i:
	# The camera's own block, extended by whole blocks.
	#
	# Snapping the RADIUS out instead turned a 9-tile square into a 20-tile
	# one — four times the tiles — because both edges rounded away from the
	# centre independently.
	if whole_world:
		return Rect2i(-world_half, -world_half,
				world_half * 2 + 1, world_half * 2 + 1)
	var pad: int = int(ceil(float(near_radius) / float(align))) * align
	var lo := Vector2i(_snap_down(cx) - pad, _snap_down(cz) - pad)
	var size := Vector2i.ONE * (align + pad * 2)
	return Rect2i(lo, size)


func current_region() -> Rect2i:
	return region(_centre.x, _centre.y)


func _snap_down(v: int) -> int:
	return int(floor(float(v) / float(align))) * align


func _snap_up(v: int) -> int:
	return int(ceil(float(v + 1) / float(align))) * align - 1


func _wanted_missing(camera_xz: Vector2) -> int:
	var tile_m := float(BrickTerrain.get_tile_studs()) * BrickWorld.get_stud_metres()
	var r := region(int(floor(camera_xz.x / tile_m)), int(floor(camera_xz.y / tile_m)))
	var n := 0
	for dz in r.size.y:
		for dx in r.size.x:
			var c := Vector2i(r.position.x + dx, r.position.y + dz)
			if absi(c.x) > world_half or absi(c.y) > world_half:
				continue
			if not _tiles.has(c):
				n += 1
	return n


## Start bakes for the nearest tiles that are missing, up to the in-flight cap.
func _collect(cx: int, cz: int) -> void:
	if _free_slots.is_empty():
		return
	var want: Array[Vector2i] = []
	var r := region(cx, cz)
	for dz in r.size.y:
		for dx in r.size.x:
			var c := Vector2i(r.position.x + dx, r.position.y + dz)
			if absi(c.x) > world_half or absi(c.y) > world_half:
				continue   # the world ends here
			if (_tiles.has(c) and not _dirty.has(c)) or _tasks.has(c):
				continue
			want.append(c)
	if want.is_empty():
		return
	# Nearest first: the tile you are about to walk onto matters more than
	# the corner of the square.
	want.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return (a - Vector2i(cx, cz)).length_squared() \
				< (b - Vector2i(cx, cz)).length_squared())
	for c in want:
		if _free_slots.is_empty():
			return
		var slot: int = _free_slots.pop_back()
		_slot_coord[slot] = c
		_slots[slot] = {}
		# The slot is this task's alone, so the worker writes without a lock.
		_slot_task[slot] = WorkerThreadPool.add_task(
			func() -> void: _slots[slot] = TerrainTile.bake(c.x, c.y),
			true, "terrain tile")
		_tasks[c] = slot


## Turn finished bakes into nodes, for as long as the budget allows.
func _assemble() -> void:
	var t0 := Time.get_ticks_usec()
	_assemble_ms = 0.0
	for slot in _slot_task.size():
		if _slot_task[slot] < 0:
			continue
		if not WorkerThreadPool.is_task_completed(_slot_task[slot]):
			continue
		WorkerThreadPool.wait_for_task_completion(_slot_task[slot])
		var c: Vector2i = _slot_coord[slot]
		var data: Dictionary = _slots[slot]
		_slot_task[slot] = -1
		_slots[slot] = {}
		_free_slots.append(slot)
		_tasks.erase(c)
		if _stale.has(c):
			# Baked from the field as it was before an edit: bake it again.
			_stale.erase(c)
			if _tiles.has(c):
				_dirty[c] = true
			continue
		var replacing := _tiles.has(c)
		if replacing:
			# A refresh: the new tile replaces the old one only now it exists.
			(_tiles[c] as TerrainTile).queue_free()
			_tiles.erase(c)
		_dirty.erase(c)

		var t1 := Time.get_ticks_usec()
		var tile := TerrainTile.new()
		tile.name = "Tile_%d_%d" % [c.x, c.y]
		tile.phases = true          # surface now, the rest on later frames
		add_child(tile)
		tile.build(c.x, c.y, _material, data)
		if replacing:
			# The ground under something that is standing on it -- a
			# building, the brush's own aim, debris -- must not go a frame
			# without collision. The studs can wait; the collider cannot.
			tile.add_collision()
		_tiles[c] = tile
		_built += 1
		_finish_pending = true
		tile.set_near(absi(c.x - _centre.x) <= near_show_radius
				and absi(c.y - _centre.y) <= near_show_radius)
		# The budget can only stop the NEXT piece of work, so ONE piece is
		# the floor on a hitch. Assembling a whole tile at once put that
		# floor at 54 ms, which is why a tile is three phases now.
		var sms := float(Time.get_ticks_usec() - t1) / 1000.0
		_worst_surface_ms = maxf(_worst_surface_ms, sms)
		_worst_tile_ms = maxf(_worst_tile_ms, sms)

		_assemble_ms = float(Time.get_ticks_usec() - t0) / 1000.0
		if _assemble_ms >= budget_ms:
			return   # the rest can wait a frame

	_finish(t0)


## The later phases, nearest first, still under the frame's budget.
func _finish(t0: int) -> void:
	if not _finish_pending:
		return
	var coords := _tiles.keys()
	coords.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return (a - _centre).length_squared() < (b - _centre).length_squared())
	# Whether a phase is still owed when this pass ends; a budget stop
	# leaves `_finish_pending` set, so the next frame carries on.
	var left := false
	for c in coords:
		if float(Time.get_ticks_usec() - t0) / 1000.0 >= budget_ms:
			return
		var tile: TerrainTile = _tiles[c]
		tile.set_casts_shadow(absi(c.x - _centre.x) <= shadow_radius
				and absi(c.y - _centre.y) <= shadow_radius)
		var t1 := Time.get_ticks_usec()
		tile.add_instances()
		var ms := float(Time.get_ticks_usec() - t1) / 1000.0
		if ms > 0.05:
			_worst_inst_ms = maxf(_worst_inst_ms, ms)
			_worst_tile_ms = maxf(_worst_tile_ms, ms)
		# Collision only where you could stand. It is the most expensive phase
		# and the only one nobody can see.
		if collide_radius < 0 or (absi(c.x - _centre.x) <= collide_radius
				and absi(c.y - _centre.y) <= collide_radius):
			var t2 := Time.get_ticks_usec()
			if not tile.add_collision(shapes_per_frame):
				left = true
			var cms := float(Time.get_ticks_usec() - t2) / 1000.0
			if cms > 0.05:
				_worst_coll_ms = maxf(_worst_coll_ms, cms)
				_worst_tile_ms = maxf(_worst_tile_ms, cms)
	_finish_pending = left


## Everything past `keep_radius` goes. The gap to `near_radius` is what stops
## a tile being rebuilt every time the camera crosses a boundary.
func _drop(cx: int, cz: int) -> void:
	# Grown by whole BLOCKS, so the resident set stays a union of aligned
	# blocks. Growing by two loose tiles left a fringe that no coarse block
	# could be hidden against, and those tiles drew on top of coarse ground:
	# 129 tiles drawn twice, which is what the coverage check reported.
	var keep := region(cx, cz).grow(align * maxi(1, int(ceil(
			float(keep_radius - near_radius) / float(align)))))
	var gone: Array[Vector2i] = []
	for c in _tiles:
		if not keep.has_point(c):
			gone.append(c)
	for c in gone:
		var tile: TerrainTile = _tiles[c]
		_tiles.erase(c)
		tile.queue_free()
		_dropped += 1
