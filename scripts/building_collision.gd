class_name BuildingCollision
extends RefCounted

## A standing building's collision: one static body per band of the building --
## the bands its mesh is already cut into (BrickWorld.set_chunk_section_plates,
## CityScene._section_plates: at most 16, at least 24 plates tall).
##
## It was one body for the whole building, and every change to that body -- a
## blast's bricks switched off, a piece cut out of it, the first hit turning
## merged boxes back into one a brick -- rebuilt the physics shape of the WHOLE
## building. On a mega tower that was 7-13 ms, twice in the worst tick of a
## collapse ("disable" and "collision update"). A band is a sixteenth of the
## tallest tower, and a change rebuilds only the bands it touched.
##
## Furniture is left out of every band (it collides through a body of its own).
##
## A standing building's bands are merged (CityScene builds them so), and a
## band that loses bricks is NOT turned back into a box a brick: it is marked
## stale and merged again, without them, once at the end of the tick (flush),
## however many pieces came out of it. Nothing is simulated in between -- the
## physics steps after the tick, by when the band is right. Un-merging was the
## first hit's whole cost, and switching boxes off one at a time rebuilds the
## band's shape just the same: a mega collapse cutting a 4,000-brick chunk
## across four bands paid 7 ms in one tick either way. Merging one band again
## is 0.1-0.7 ms.
##
## A band of a box a brick (merge false: kept for a probe or an experiment)
## still switches its boxes off at once, and merge_next merges it.
##
## flush() takes a budget. Merging a band again is ~0.45 ms on a mega tower's
## footprint, and one 4,000-brick chunk cut out of it can leave fifteen bands
## stale in one tick. A stale band over the budget is PARKED -- taken out of the
## physics space -- until its turn, a tick or two later: its stale boxes would
## overlap the piece just cut out of it, and the solver answers an overlap by
## throwing the piece. For those ticks that band is not solid, in a building
## that is coming apart.

var world: BrickWorld
var chunk := -1
var bodies: Array[RID] = []
## Per band: block id -> the shape indices it owns. Empty for a merged band --
## a merged box spans blocks, so there is nothing to switch off one at a time.
var maps: Array[Dictionary] = []
var merged: Array[bool] = []
## Merged bands that have lost bricks since they were built: merged again,
## without them, by flush().
var stale: Array[bool] = []
## Stale bands flush() had no budget for, out of the space until it does.
var parked: Array[bool] = []
## The space the bodies belong in.
var space: RID

## This building's shape rebuilds, and every building's, for the report.
var reshapes := 0
static var merges := 0
static var merge_ms := 0.0
static var merge_worst := 0.0
static var unmerges := 0
static var unmerge_ms := 0.0
static var unmerge_worst := 0.0


## Every band's body, built and put in `space` at `xform`. `merge` builds them
## merged (a walk-up) rather than a box a brick (a hit).
func _init(w: BrickWorld, c: int, in_space: RID, xform: Transform3D, merge: bool) -> void:
	world = w
	chunk = c
	space = in_space
	var n: int = maxi(world.get_chunk_sections(chunk), 1)
	for si in n:
		var body := PhysicsServer3D.body_create()
		PhysicsServer3D.body_set_mode(body, PhysicsServer3D.BODY_MODE_STATIC)
		PhysicsServer3D.body_set_collision_layer(body, Layers.STRUCTURE)
		PhysicsServer3D.body_set_collision_mask(body, Layers.STRUCTURE_MASK)
		# See IslandManager.spawn: the shapes are built inside the extension,
		# dead blocks disabled as they go.
		var built: Dictionary = world.add_chunk_shapes(body, chunk, Vector3.ZERO, merge, merge,
				si if n > 1 else -1, true)
		PhysicsServer3D.body_set_state(body, PhysicsServer3D.BODY_STATE_TRANSFORM, xform)
		PhysicsServer3D.body_set_space(body, space)
		bodies.append(body)
		maps.append(built.get("map", {}))
		merged.append(merge)
		stale.append(false)
		parked.append(false)


func free_bodies() -> void:
	for body in bodies:
		PhysicsServer3D.free_rid(body)
	bodies.clear()
	maps.clear()
	merged.clear()
	stale.clear()
	parked.clear()


func owns(body: RID) -> bool:
	return bodies.has(body)


func shape_count() -> int:
	var n := 0
	for body in bodies:
		n += PhysicsServer3D.body_get_shape_count(body)
	return n


func all_merged() -> bool:
	return not merged.has(false)


func any_merged() -> bool:
	return merged.has(true)


## Rebuild one band's shapes, merged or a box a brick. Returns what it cost, ms.
## `force` rebuilds it even when it is already that form (a stale band).
func reshape(si: int, merge: bool, force := false) -> float:
	if si < 0 or si >= bodies.size() or (merged[si] == merge and not force):
		return 0.0
	var t := Time.get_ticks_usec()
	var body := bodies[si]
	# Out of the space first: a shape call on a body IN a space costs time
	# proportional to its shape count.
	if PhysicsServer3D.body_get_space(body).is_valid():
		PhysicsServer3D.body_set_space(body, RID())
	PhysicsServer3D.body_clear_shapes(body)
	# skip_dead now, where promotion cannot: by this point the holes are known,
	# so a dead brick costs no box at all rather than a disabled one.
	var built: Dictionary = world.add_chunk_shapes(body, chunk, Vector3.ZERO, true, merge,
			si if bodies.size() > 1 else -1, true)
	maps[si] = built.get("map", {})
	merged[si] = merge
	stale[si] = false
	parked[si] = false
	PhysicsServer3D.body_set_space(body, space)
	var cost := float(Time.get_ticks_usec() - t) / 1000.0
	reshapes += 1
	if merge:
		merges += 1
		merge_ms += cost
		merge_worst = maxf(merge_worst, cost)
	else:
		unmerges += 1
		unmerge_ms += cost
		unmerge_worst = maxf(unmerge_worst, cost)
	return cost


## Every band, merged or not. Returns what it cost, ms.
func reshape_all(merge: bool) -> float:
	var cost := 0.0
	for si in bodies.size():
		cost += reshape(si, merge)
	return cost


## Merge the lowest band that is still a box a brick. False when there is none.
func merge_next() -> bool:
	var si := merged.find(false)
	if si < 0:
		return false
	reshape(si, true)
	return true


## The bands these blocks are in, each once. Furniture is in none: it is not
## in the building's collision at all (it has a body of its own, CityScene's
## _room_body), so shutting a room does not rebuild the band it is in -- which
## it did, every few ticks while rooms streamed around somebody, and a band
## taken out of the space and put back is a floor that is not there for a tick.
func bands_of(ids: PackedInt32Array) -> PackedInt32Array:
	var out := PackedInt32Array()
	for si in world.get_block_sections(chunk, ids, true):
		if si >= 0 and si < bodies.size() and not out.has(si):
			out.append(si)
	return out


## Switch off the shapes these blocks own: now, in a band that is a box a
## brick; at flush(), for a merged band, which is merged again without them.
func disable(ids: PackedInt32Array) -> void:
	if ids.is_empty():
		return
	for si in bands_of(ids):
		if merged[si]:
			stale[si] = true
			continue
		var map: Dictionary = maps[si]
		var any := false
		for bid in ids:
			if map.has(bid):
				any = true
				break
		if not any:
			continue
		var body := bodies[si]
		var was_space := PhysicsServer3D.body_get_space(body)
		# Lifting the body out of the space first: each shape call costs time
		# proportional to the body's shape count, so in a loop it is quadratic.
		if was_space.is_valid():
			PhysicsServer3D.body_set_space(body, RID())
		for bid in ids:
			if map.has(bid):
				for shape_index in map[bid]:
					PhysicsServer3D.body_set_shape_disabled(body, shape_index, true)
		if was_space.is_valid():
			PhysicsServer3D.body_set_space(body, was_space)


## Merge again up to `budget` of the bands that have lost bricks since they
## were built, and park the rest (see `parked`). Once a tick, after everything
## that can take bricks out of them, before the physics steps: by then what came
## out is dead or belongs to a piece, and is left out. All of them in one call
## (BrickWorld.add_band_shapes), which walks the building's blocks once rather
## than twice a band. Returns how many it merged; the cost is in last_flush_ms.
func flush(budget: int = 1 << 30) -> int:
	var sis := PackedInt32Array()
	var bs: Array = []
	for si in stale.size():
		if not stale[si]:
			continue
		if sis.size() < budget:
			sis.append(si)
			bs.append(bodies[si])
		elif not parked[si]:
			PhysicsServer3D.body_set_space(bodies[si], RID())
			parked[si] = true
	last_flush_ms = 0.0
	if sis.is_empty():
		return 0
	var t := Time.get_ticks_usec()
	for body: RID in bs:
		# Out of the space first, as in reshape.
		if PhysicsServer3D.body_get_space(body).is_valid():
			PhysicsServer3D.body_set_space(body, RID())
		PhysicsServer3D.body_clear_shapes(body)
	world.add_band_shapes(bs, chunk, Vector3.ZERO, sis, true)
	for si in sis:
		maps[si] = {}
		merged[si] = true
		stale[si] = false
		parked[si] = false
		PhysicsServer3D.body_set_space(bodies[si], space)
	var cost := float(Time.get_ticks_usec() - t) / 1000.0
	last_flush_ms = cost
	reshapes += sis.size()
	merges += sis.size()
	merge_ms += cost
	merge_worst = maxf(merge_worst, cost)
	return sis.size()


var last_flush_ms := 0.0


func any_stale() -> bool:
	return stale.has(true)

