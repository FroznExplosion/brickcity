class_name TerrainStreamer
extends Node3D

## Keeps the detailed terrain tiles around the camera, and nothing else.
## [Docs/Terrain.md](../../Docs/Terrain.md) §19.6.
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
## Tiles held resident WITH A COLLIDER wherever the camera is, but drawn only
## while the streamed square would hold them (Docs/Terrain.md §22.18).
##
## For a city that streams its ground like the heightfield test: what is SEEN
## follows the camera, detail near and coarse beyond, while everything that
## stands on the ground -- an enemy across the map, debris from a collapse
## two streets away -- still has a floor. Hidden tiles are not drawn and the
## coarse tier is not hidden over them (`has_tile` answers for drawn tiles).
## Empty: nothing pinned.
var pinned := Rect2i()
## How long assembly may take in one frame. Three milliseconds of a sixteen
## millisecond frame is a fifth of the budget and invisible in practice.
@export var budget_ms := 1.5
## How many tiles may be baking at once. More than the core count only makes
## the queue longer.
@export var max_in_flight := 8
## Bake slots on top of `max_in_flight` that only an EDIT's rebake may take
## (Docs/MineWorld.md 21): with every slot streaming new ground in, a broken
## brick's tile waited for one to free (~9 ms) before it even started.
const EDIT_SLOTS := 2
## Bakes of one tile in flight at once at most (_wants_newer).
const BAKES_PER_TILE := 2
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
## Tiles dropped per frame at most; the rest wait their turn (`_drop`).
## 0 drops every one at once.
@export var drops_per_frame := 4
## Tiles still waiting to be dropped after the last `_drop`.
var _drops_pending := 0

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
## EDIT GENERATIONS (Docs/MineWorld.md 9, --gate=breaklag). Each refresh of a
## built tile counts one up (`_gen`); a bake carries the generation it started
## at (`_slot_gen`) and lands only if it is newer than the last that landed
## (`_landed_gen`). So a second edit starts a second bake AT ONCE, beside the
## first, instead of marking the first stale and waiting for it: three bricks
## broken a frame apart chained three or four whole-tile bakes (145 ms).
var _gen := {}
var _landed_gen := {}
var _slot_gen: Array[int] = []

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
## Tiles within this ring SHOW their detailed version (bevelled studs).
@export var near_show_radius := 1
var _near_centre := Vector2i(1 << 30, 0)
## The centre pinned tiles were last shown or hidden for.
var _shown_centre := Vector2i(1 << 30, 0)
## REFRESHES IN WAITING (an edit's rebuilt tiles): coord -> {tile, step,
## gen}. The new tile is made hidden and finished -- its collider -- while the old one is still drawn and
## collided with; then the two swap in one frame (_swap_step). Swapping at
## once showed the new tile flat and bare for a few frames (the flicker round
## every edit); swapping whole in one frame cost a 5 ms step.
var _swaps := {}
## A refresh in waiting whose collider is in: it swaps with its BATCH.
const SWAP_READY := 2
## EDITS SWAP TOGETHER (Docs/MineWorld.md 20). Every resident tile one
## refresh() names is one batch (two edits over a tile merge theirs), and a
## batch's tiles swap in the SAME frame, once each is built and collided --
## each tile swapping by itself put a brick across a tile edge in one tile and
## out of the other for a frame or more, its studs with it (the studs that
## flashed when a brick broke). coord -> batch {"tiles": {coord: true},
## "since": msec its first tile was ready}.
var _batch_of := {}
## A batch waits this long at most for a straggler (a tile edited again and
## again -- lava relighting, a sand pour) before swapping what is ready.
const BATCH_WAIT_MS := 300
## HELD TILES (Docs/MineWorld.md 20): coord -> {owner: true}. A held tile is
## built and collided but not swapped: what falls from the ground
## (ground_collapse.gd) holds the tiles that still draw it until its own mesh
## is made, then swaps them and lets it go in one call (swap_ready), so the
## piece and the ground never both draw it, nor neither.
var _holds := {}
## THE EDIT'S CLOCK (--gate=breaklag): with `log_latency`, each refreshed tile
## is stamped (usec) as it is marked, its bake starts, lands and swaps, and the
## finished record goes to `latency_log` ({c, dirty, bake, land, swap}).
var log_latency := false
var latency_log: Array = []
## The generation (`_gen`) each drawn tile was baked at: an edit counted up
## to `g` is on screen once drawn_gen[c] >= g (the breaklag gate's --burst).
var drawn_gen := {}
var _stamps := {}
## Worst single phase seen, split three ways — which one hurts is the whole
## question when a hitch has to be chased.
## HELD (moving fast, Docs/MineWorld.md 14): no new bakes start, no studs,
## scatter or collision are added, nor do tiles switch between their
## near and far stud sets; bakes already in flight still
## land (their surface only) and far tiles still drop, so the instance pool
## fills. What is drawn stays drawn. Off again: everything resumes.
var hold := false:
	set(v):
		if hold and not v:
			_finish_pending = true
		hold = v
var _worst_surface_ms := 0.0
var _worst_inst_ms := 0.0
var _worst_coll_ms := 0.0
var _worst_swap_ms := 0.0


## THE BRICK OVERLAY (Docs/BrickOverlay.md) for this ground: real bevelled
## bricks near the camera over the flat tiles. Made in setup when
## `auto_overlay` and TerrainBricks.overlay_default are on; a scene
## that makes its own (the mine world, which also lays it over its deep
## sections and hides shot bricks) turns `auto_overlay` off first.
var auto_overlay := true
var bricks: TerrainBricks = null


func setup(material: Material) -> void:
	_material = material
	if auto_overlay and TerrainBricks.overlay_default and material is ShaderMaterial:
		bricks = TerrainBricks.new()
		bricks.name = "Bricks"
		add_child(bricks)
		bricks.setup(self, material as ShaderMaterial,
				(material as ShaderMaterial).shader == TerrainTile.sky_light_shader())
	for i in max_in_flight + EDIT_SLOTS:
		_slots.append({})
		_slot_task.append(-1)
		_slot_coord.append(Vector2i.ZERO)
		_slot_gen.append(0)
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
	for c in _swaps.keys():
		_drop_swap(c)
	# The tiles have left already (children go first) and handed their
	# MultiMeshes to TerrainTile's static pool. Empty it now, while the
	# renderer is still up: a static holding meshes past the end of the
	# program frees them after the RenderingServer is gone, and the combat
	# arena's gate crashed on its way out (signal 11 after "~ArrayMesh:
	# RenderingServer is null") once the city streamed and dropped tiles.
	TerrainTile.clear_pool()


## Call every frame with the camera's world position.
func follow(camera_xz: Vector2) -> void:
	var tile_m := float(BrickTerrain.get_tile_studs()) * BrickWorld.get_stud_metres()
	var cx := int(floor(camera_xz.x / tile_m))
	var cz := int(floor(camera_xz.y / tile_m))
	if _centre != Vector2i(cx, cz):
		_finish_pending = true    # collision reach moved with it
	_centre = Vector2i(cx, cz)
	if not hold:
		_collect(cx, cz)
	_drop(cx, cz)
	_assemble()
	if _shown_centre != _centre and pinned.has_area():
		_shown_centre = _centre
		var keep := _keep_rect(cx, cz)
		for c in _tiles:
			(_tiles[c] as Node3D).visible = _shown(c, keep)
	# Held, tiles keep the stud set they have: switching builds the other set
	# (a new MultiMesh) the first time, the instance cost the hold is for.
	if _near_centre != _centre and not hold:
		_near_centre = _centre
		for c in _tiles:
			(_tiles[c] as TerrainTile).set_near(absi(c.x - cx) <= near_show_radius
					and absi(c.y - cz) <= near_show_radius)
	if _shadow_centre != _centre:
		_shadow_centre = _centre
		for c in _tiles:
			(_tiles[c] as TerrainTile).set_casts_shadow(
				absi(c.x - cx) <= shadow_radius and absi(c.y - cz) <= shadow_radius)


## Build everything the camera wants, now, blocking. For captures and
## benchmarks, which must not photograph a half-built world.
func settle(camera_xz: Vector2, rounds := 4000) -> void:
	for i in rounds:
		follow(camera_xz)
		if _tasks.is_empty() and _dirty.is_empty() and _swaps.is_empty() and _drops_pending == 0 				and _wanted_missing(camera_xz) == 0:
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
			return


## Rebuild the tiles over a rectangle WITHOUT taking them away first.
##
## For a brush stroke: `invalidate` leaves a hole until the new tile lands,
## and a stroke refreshes the same ground ten times a second. Here the old
## tile stays on screen, a new one bakes behind it, and it is swapped in
## when ready. A bake already in flight over the rectangle read the field
## BEFORE the edit, so its result is thrown away and it bakes again.
func refresh(rect: Rect2i) -> void:
	var batch := {"tiles": {}, "since": 0}
	for c in _tiles:
		if rect.has_point(c):
			_dirty[c] = true
			_gen[c] = int(_gen.get(c, 0)) + 1
			if log_latency and not _stamps.has(c):
				_stamps[c] = {"c": c, "dirty": Time.get_ticks_usec()}
			batch.tiles[c] = true
			# Merged with the batch it was in: they swap as one.
			var old = _batch_of.get(c)
			if old != null and old != batch:
				for t in old.tiles:
					batch.tiles[t] = true
				# Its wait goes on from when it began: a new edit merged in every
				# few frames restarted it, so under fire a batch never stopped waiting.
				if int(old.since) > 0 and (int(batch.since) == 0 or int(old.since) < int(batch.since)):
					batch.since = old.since
	for t in batch.tiles:
		_batch_of[t] = batch
	for c in _tasks:
		# A built tile's bake is only older (its generation says so); a first
		# bake of a tile not yet built is stale and baked again.
		if rect.has_point(c) and not _tiles.has(c):
			_stale[c] = true


## No tile over `rect` is waiting to be rebuilt (refresh): each one drawn is
## the field as it is now. What falls from the ground (ground_collapse.gd) is
## let go once its old tile no longer draws it.
func fresh(rect: Rect2i) -> bool:
	for c in _dirty:
		if rect.has_point(c):
			return false
	for c in _swaps:
		if rect.has_point(c):
			return false
	for c in _stale:
		if rect.has_point(c):
			return false
	return true


## Hold the resident tiles over `rect` for `owner` (any key): built and
## collided, they wait to be swapped until released (unhold, swap_ready).
func hold_tiles(rect: Rect2i, who) -> void:
	for c in _tiles:
		if rect.has_point(c):
			if not _holds.has(c):
				_holds[c] = {}
			# The generation its own clear is drawn at (_tile_ready).
			_holds[c][who] = int(_gen.get(c, 0))


func unhold(rect: Rect2i, who) -> void:
	for c in _holds.keys():
		if rect.has_point(c):
			(_holds[c] as Dictionary).erase(who)
			if (_holds[c] as Dictionary).is_empty():
				_holds.erase(c)


## Could every refresh over `rect` -- and the rest of each one's batch -- swap
## NOW, holds by anyone but `who` aside? (Nothing waiting: true.)
func tiles_ready(rect: Rect2i, who = null) -> bool:
	for c in _batch_tiles(rect):
		if not _tile_ready(c, who):
			return false
	return true


## Swap every batch over `rect` that is ready, now, whatever the frame's
## budget. Then `fresh(rect)` holds when tiles_ready(rect) did.
func swap_ready(rect: Rect2i) -> void:
	var done := {}
	for c in _batch_tiles(rect):
		var b = _batch_of.get(c)
		if b != null and done.has(b):
			continue
		if b != null:
			done[b] = true
		_swap_batch(c, true)


func _held(c: Vector2i, who = null) -> bool:
	var h = _holds.get(c)
	if h == null:
		return false
	for o in h:
		if o != who:
			return true
	return false


## Ready to swap: not held by others, and its waiting refresh built and
## collided -- a newer edit's bake still coming does NOT stop it (it swaps
## after): under sustained fire a tile was never "ready" and the first
## shot's hole waited till the shooting stopped (--gate=breaklag --burst
## --burst-every=1: 534 ms, Docs/MineWorld.md 21). Nothing waiting: ready
## unless its bake is still coming. For `who`'s own hold: its clear's
## generation drawn, or in the waiting swap.
func _tile_ready(c: Vector2i, who = null) -> bool:
	if not _tiles.has(c):
		return true
	if _held(c, who):
		return false
	if who != null and _holds.has(c) and (_holds[c] as Dictionary).has(who):
		var need := int(_holds[c][who])
		if int(drawn_gen.get(c, -1)) >= need:
			return true
		return _swaps.has(c) and int(_swaps[c].step) == SWAP_READY and int(_swaps[c].get("gen", -1)) >= need
	if _swaps.has(c):
		return int(_swaps[c].step) == SWAP_READY
	return not _dirty.has(c) and not _stale.has(c)


## The resident tiles over `rect`, with every tile of their batches.
func _batch_tiles(rect: Rect2i) -> Array:
	var out := {}
	for c in _tiles:
		if rect.has_point(c):
			out[c] = true
			var b = _batch_of.get(c)
			if b != null:
				for t in b.tiles:
					out[t] = true
	return out.keys()


## Swap c's batch -- every tile of it whose refresh is ready -- if all of it
## is ready (or it has waited BATCH_WAIT_MS; `force` skips the wait but not
## the holds). One frame, so nothing is drawn half old and half new.
func _swap_batch(c: Vector2i, force := false) -> void:
	var b = _batch_of.get(c)
	var keys: Array = b.tiles.keys() if b != null else [c]
	var all := true
	for t in keys:
		if _held(t):
			return
		if not _tile_ready(t):
			all = false
	# `force` (a falling piece let go, its own ground ready): what is ready
	# swaps now, the rest when it is.
	if not all and not force:
		if b == null:
			return
		var now := Time.get_ticks_msec()
		if int(b.since) == 0:
			b.since = now
		if now - int(b.since) < BATCH_WAIT_MS:
			return
	for t in keys:
		if _swaps.has(t) and int(_swaps[t].step) == SWAP_READY:
			_swap_now(t)
			if b != null and _batch_of.get(t) == b:
				_batch_of.erase(t)
	# Whole: the batch is done. Waited too long: the tiles still coming stay
	# in it and swap alone when they are ready (its wait is over).
	if all and b != null:
		for t in keys:
			if _batch_of.get(t) == b:
				_batch_of.erase(t)


## The swap itself: the old tile's instance nodes to the pool, the new one
## fills them, is shown and the old one goes -- one frame.
func _swap_now(c: Vector2i) -> void:
	var job: Dictionary = _swaps[c]
	var tile: TerrainTile = job.tile
	var old: TerrainTile = _tiles.get(c)
	_swaps.erase(c)
	if old == null or not is_instance_valid(tile):
		return
	tile.set_near(absi(c.x - _centre.x) <= near_show_radius
			and absi(c.y - _centre.y) <= near_show_radius)
	old.recycle()
	tile.add_instances()
	tile.visible = old.visible
	old.queue_free()
	_tiles[c] = tile
	drawn_gen[c] = int(job.get("gen", 0))
	_built += 1
	if log_latency and _stamps.has(c):
		var st: Dictionary = _stamps[c]
		st["swap"] = Time.get_ticks_usec()
		latency_log.append(st)
		_stamps.erase(c)


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
		_drop_swap(c)
		_dirty.erase(c)
		_batch_of.erase(c)
		_holds.erase(c)
		tile.recycle()
		tile.queue_free()


## Forget what the startup cost; a walk's numbers are the interesting ones.
func reset_stats() -> void:
	_built = 0
	_dropped = 0
	_worst_tile_ms = 0.0
	_worst_surface_ms = 0.0
	_worst_inst_ms = 0.0
	_worst_coll_ms = 0.0
	_worst_swap_ms = 0.0


## The bake's result of a tile drawn now ({} when none): its "light_lo" /
## "light_hi" say which plates its light can come from (MineWorld.md 18).
func tile_data(c: Vector2i) -> Dictionary:
	var t = _tiles.get(c)
	return (t as TerrainTile)._data if t != null else {}


## Is this tile BUILT? Not "wanted" — built. The coarse tier asks before it
## hides itself, and the difference matters: the wanted region fills at a few
## tiles a frame, so hiding against the region opened a black pit the size of
## the detail square every time the camera jumped.
## Is a tile DRAWN here -- what the coarse tier hides itself against. A
## pinned tile held only for its collider is not.
func has_tile(c: Vector2i) -> bool:
	return _tiles.has(c) and (_tiles[c] as Node3D).visible


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


## Tiles near the camera drawn but not whole (TerrainTile.is_whole): what
## the eye sees flicker when an edit rebuilds the ground (--gate counts it).
func bare_near_tiles() -> int:
	var n := 0
	for c in _tiles:
		if absi(c.x - _centre.x) > near_show_radius or absi(c.y - _centre.y) > near_show_radius:
			continue
		var t: TerrainTile = _tiles[c]
		if t.visible and not t.is_whole():
			n += 1
	return n


func report() -> String:
	return "%d resident  %d built  %d dropped  worst %.1f ms (surface %.1f, inst %.1f, coll %.1f, swap %.1f)" % [
		_tiles.size(), _built, _dropped, _worst_tile_ms,
		_worst_surface_ms, _worst_inst_ms, _worst_coll_ms, _worst_swap_ms]


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
	var n := 0
	for r in _wanted_rects(int(floor(camera_xz.x / tile_m)), int(floor(camera_xz.y / tile_m))):
		for dz in r.size.y:
			for dx in r.size.x:
				var c := Vector2i(r.position.x + dx, r.position.y + dz)
				if absi(c.x) > world_half or absi(c.y) > world_half:
					continue
				if not _tiles.has(c):
					n += 1
	return n


## The rectangles of tiles to hold: the streamed region, and the pinned one.
## (A tile in both is counted once by the callers' own checks.)
func _wanted_rects(cx: int, cz: int) -> Array[Rect2i]:
	var out: Array[Rect2i] = [region(cx, cz)]
	if pinned.has_area():
		out.append(pinned)
	return out


## The square resident tiles are kept in: the region grown by the
## hysteresis, in whole blocks.
func _keep_rect(cx: int, cz: int) -> Rect2i:
	# Grown by whole BLOCKS, so the resident set stays a union of aligned
	# blocks. Growing by two loose tiles left a fringe that no coarse block
	# could be hidden against, and those tiles drew on top of coarse ground:
	# 129 tiles drawn twice, which is what the coverage check reported.
	return region(cx, cz).grow(align * maxi(1, int(ceil(
			float(keep_radius - near_radius) / float(align)))))


## A pinned tile outside the streamed square is held for its collider and
## not drawn: the coarse tier shows the ground there, as it would anywhere.
func _shown(c: Vector2i, keep: Rect2i) -> bool:
	return keep.has_point(c) or not pinned.has_point(c)


## Start bakes for the nearest tiles that are missing, up to the in-flight cap.
func _collect(cx: int, cz: int) -> void:
	if _free_slots.is_empty():
		return
	var want: Array[Vector2i] = []
	var seen := {}
	for r in _wanted_rects(cx, cz):
		for dz in r.size.y:
			for dx in r.size.x:
				var c := Vector2i(r.position.x + dx, r.position.y + dz)
				if absi(c.x) > world_half or absi(c.y) > world_half:
					continue   # the world ends here
				if (_tiles.has(c) and not _dirty.has(c)) or (_tasks.has(c) and not _wants_newer(c)):
					continue
				if seen.has(c):
					continue   # in both the region and the pinned rect
				seen[c] = true
				want.append(c)
	# A resident tile an edit made stale is rebuilt even in the hysteresis
	# ring past the region: otherwise it is drawn from the old field until
	# the camera walks away and back (a dev menu rebuild left 28 such tiles).
	for c in _dirty:
		if not seen.has(c) and _tiles.has(c) and (not _tasks.has(c) or _wants_newer(c)):
			seen[c] = true
			want.append(c)
	if want.is_empty():
		return
	# Edits first (a drawn tile rebuilt: the player is looking at the hole),
	# then nearest first: the tile you are about to walk onto matters more
	# than the corner of the square.
	want.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		var ea := _tiles.has(a)
		if ea != _tiles.has(b):
			return ea
		return (a - Vector2i(cx, cz)).length_squared() \
				< (b - Vector2i(cx, cz)).length_squared())
	# New ground streaming in takes at most max_in_flight slots; the
	# EDIT_SLOTS past it are kept for edits.
	var streaming := 0
	for t in _tasks:
		if not _tiles.has(t):
			streaming += 1
	for c in want:
		if _free_slots.is_empty():
			return
		if not _tiles.has(c):
			if streaming >= max_in_flight:
				continue
			streaming += 1
		var slot: int = _free_slots.pop_back()
		_slot_coord[slot] = c
		_slots[slot] = {}
		_slot_gen[slot] = int(_gen.get(c, 0))
		# The slot is this task's alone, so the worker writes without a lock.
		_slot_task[slot] = WorkerThreadPool.add_task(
			func() -> void: _slots[slot] = TerrainTile.bake(c.x, c.y),
			true, "terrain tile")
		_tasks[c] = slot
		if log_latency and _stamps.has(c) and not _stamps[c].has("bake"):
			_stamps[c]["bake"] = Time.get_ticks_usec()


## Turn finished bakes into nodes, for as long as the budget allows.
func _assemble() -> void:
	var t0 := Time.get_ticks_usec()
	_assemble_ms = 0.0
	# Edits' bakes land first: the frame's budget goes to the hole the
	# player made before new ground at the edge of the square.
	var order: Array[int] = []
	var later: Array[int] = []
	for slot in _slot_task.size():
		if _slot_task[slot] < 0:
			continue
		if _tiles.has(_slot_coord[slot]):
			order.append(slot)
		else:
			later.append(slot)
	# Then their swaps, on a budget of their own: the hole a shot made is not
	# held back by new ground landing at the edge of the square (it waited up
	# to 48 ms for it, Docs/MineWorld.md 21). New ground lands after.
	var in_budget := _land_slots(order, t0)
	_swap_step(Time.get_ticks_usec())
	if in_budget and _land_slots(later, t0) and not hold:
		_finish(t0)


## Land the finished bakes of `slots` under the frame's budget (from `t0`);
## false when it ran out.
func _land_slots(slots: Array[int], t0: int) -> bool:
	for slot in slots:
		if _slot_task[slot] < 0:
			continue
		if not WorkerThreadPool.is_task_completed(_slot_task[slot]):
			continue
		WorkerThreadPool.wait_for_task_completion(_slot_task[slot])
		var c: Vector2i = _slot_coord[slot]
		var data: Dictionary = _slots[slot]
		var gen := _slot_gen[slot]
		_slot_task[slot] = -1
		_slots[slot] = {}
		_free_slots.append(slot)
		if _tasks.get(c, -1) == slot:
			_tasks.erase(c)
		if _tiles.has(c) and gen <= int(_landed_gen.get(c, -1)):
			continue   # a newer bake of this tile landed first
		if _stale.has(c):
			# Baked from the field as it was before an edit: bake it again.
			_stale.erase(c)
			if _tiles.has(c):
				_dirty[c] = true
			continue
		var old: TerrainTile = _tiles.get(c)
		_landed_gen[c] = gen
		# Still dirty if an edit came after this bake started (its own bake
		# is running, or starts next frame).
		if gen >= int(_gen.get(c, 0)):
			_dirty.erase(c)

		var t1 := Time.get_ticks_usec()
		var tile := TerrainTile.new()
		tile.name = "Tile_%d_%d" % [c.x, c.y]
		tile.phases = true          # surface now, the rest on later frames
		add_child(tile)
		tile.build(c.x, c.y, _material, data)
		var near := absi(c.x - _centre.x) <= near_show_radius and absi(c.y - _centre.y) <= near_show_radius
		if old != null:
			# A REFRESH (an edit): made hidden and finished over the next
			# frames, the old tile drawn and collided with till the swap.
			tile.visible = false
			if _swaps.has(c):
				# Edited again before the last one swapped: that one is stale.
				var stale: TerrainTile = _swaps[c].tile
				stale.recycle()
				stale.queue_free()
			# The next frame takes the collider and swaps.
			_swaps[c] = {"tile": tile, "step": 1, "gen": gen}
			if log_latency and _stamps.has(c):
				_stamps[c]["land"] = Time.get_ticks_usec()
			var sms0 := float(Time.get_ticks_usec() - t1) / 1000.0
			_worst_surface_ms = maxf(_worst_surface_ms, sms0)
			_worst_tile_ms = maxf(_worst_tile_ms, sms0)
			_assemble_ms = float(Time.get_ticks_usec() - t0) / 1000.0
			if _assemble_ms >= budget_ms:
				return false
			continue
		tile.set_near(near)
		if pinned.has_area():
			tile.visible = _shown(c, _keep_rect(_centre.x, _centre.y))
		_tiles[c] = tile
		drawn_gen[c] = gen
		_built += 1
		_finish_pending = true
		# The budget can only stop the NEXT piece of work, so ONE piece is
		# the floor on a hitch. Assembling a whole tile at once put that
		# floor at 54 ms, which is why a tile is three phases now.
		var sms := float(Time.get_ticks_usec() - t1) / 1000.0
		_worst_surface_ms = maxf(_worst_surface_ms, sms)
		_worst_tile_ms = maxf(_worst_tile_ms, sms)

		_assemble_ms = float(Time.get_ticks_usec() - t0) / 1000.0
		if _assemble_ms >= budget_ms:
			return false   # the rest can wait a frame

	return true


## Each refresh in waiting one step on, under the frame's budget: its
## collider (a few boxes a frame, joining the physics
## space when complete -- with the old one still there, so the ground the old
## tile draws stays solid), then the swap: the old tile's instance nodes go to
## the pool and the new one fills them (drawn before: a copy), it is shown and
## the old one goes, all in one frame -- nothing is drawn half-built.
func _swap_step(t0: int) -> void:
	for c in _swaps.keys():
		if float(Time.get_ticks_usec() - t0) / 1000.0 >= budget_ms:
			return
		if not _swaps.has(c):
			continue   # swapped already, with its batch
		var job: Dictionary = _swaps[c]
		var tile: TerrainTile = job.tile
		var old: TerrainTile = _tiles.get(c)
		if old == null or not is_instance_valid(tile):
			_swaps.erase(c)
			continue
		var t1 := Time.get_ticks_usec()
		match int(job.step):
			0, 1:
				tile.set_casts_shadow(old.casts_shadow())
				if not tile.add_collision(shapes_per_frame):
					continue
				# The collider is in: swap with its batch, in the same
				# frame if the rest of it is ready too.
				job.step = SWAP_READY
				_swap_batch(c)
			_:
				_swap_batch(c)
		var ms := float(Time.get_ticks_usec() - t1) / 1000.0
		_worst_tile_ms = maxf(_worst_tile_ms, ms)
		_worst_swap_ms = maxf(_worst_swap_ms, ms)


## A built tile edited since its newest running bake started.
## ...and may start another bake beside the ones running: at most
## BAKES_PER_TILE at once. One more bake an edit was a whole-tile bake a
## frame under fire, every older one wasted, and the backlog grew: at a shot a
## frame the 30th brick showed 540 ms late (--gate=breaklag --burst
## --burst-every=1, Docs/MineWorld.md 21). An older bake still lands and is
## swapped in (it has the earlier shots' holes); the newest starts as one ends.
func _wants_newer(c: Vector2i) -> bool:
	if not (_tiles.has(c) and _tasks.has(c) and _slot_gen[_tasks[c]] < int(_gen.get(c, 0))):
		return false
	var n := 0
	for slot in _slot_task.size():
		if _slot_task[slot] >= 0 and _slot_coord[slot] == c:
			n += 1
	return n < BAKES_PER_TILE


func _drop_swap(c: Vector2i) -> void:
	if _swaps.has(c):
		var t: TerrainTile = _swaps[c].tile
		if is_instance_valid(t):
			t.recycle()
			t.queue_free()
		_swaps.erase(c)


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
		# A hidden (pinned) tile's studs and scatter wait until it is shown:
		# the centre moving sets _finish_pending again.
		if tile.visible:
			tile.add_instances()
		var ms := float(Time.get_ticks_usec() - t1) / 1000.0
		if ms > 0.05:
			_worst_inst_ms = maxf(_worst_inst_ms, ms)
			_worst_tile_ms = maxf(_worst_tile_ms, ms)
		# Collision only where you could stand. It is the most expensive phase
		# and the only one nobody can see. Pinned tiles always: that is what
		# they are held for.
		if collide_radius < 0 or pinned.has_point(c) or (absi(c.x - _centre.x) <= collide_radius
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
	var keep := _keep_rect(cx, cz)
	var gone: Array[Vector2i] = []
	for c in _tiles:
		if not keep.has_point(c) and not pinned.has_point(c):
			gone.append(c)
	# A FEW A FRAME, furthest first. Crossing a block boundary drops a whole
	# block row -- 48 tiles -- and freeing them in one frame was a 50-67 ms
	# hitch two frames later, the renderer releasing their meshes (the
	# heightfield bench's walk, frame 267; Terrain.md 22.19). A tile waiting
	# its turn stays whole and drawn, so nothing is uncovered meanwhile.
	if drops_per_frame > 0 and gone.size() > drops_per_frame:
		gone.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
			return (a - Vector2i(cx, cz)).length_squared() 					> (b - Vector2i(cx, cz)).length_squared())
		_drops_pending = gone.size() - drops_per_frame
		gone.resize(drops_per_frame)
	else:
		_drops_pending = 0
	for c in gone:
		var tile: TerrainTile = _tiles[c]
		_tiles.erase(c)
		_drop_swap(c)
		_dirty.erase(c)
		_batch_of.erase(c)
		_holds.erase(c)
		tile.recycle()
		tile.queue_free()
		_dropped += 1
