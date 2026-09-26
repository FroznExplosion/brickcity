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
## Each band is merged or one box a brick on its own (CityScene._last_hit
## says why both forms exist): the first hit un-merges the band it landed in,
## not the building, and a quiet building is merged back a band at a time.

var world: BrickWorld
var chunk := -1
var bodies: Array[RID] = []
## Per band: block id -> the shape indices it owns. Empty for a merged band --
## a merged box spans blocks, so there is nothing to switch off one at a time.
var maps: Array[Dictionary] = []
var merged: Array[bool] = []

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
func _init(w: BrickWorld, c: int, space: RID, xform: Transform3D, merge: bool) -> void:
	world = w
	chunk = c
	var n: int = maxi(world.get_chunk_sections(chunk), 1)
	for si in n:
		var body := PhysicsServer3D.body_create()
		PhysicsServer3D.body_set_mode(body, PhysicsServer3D.BODY_MODE_STATIC)
		PhysicsServer3D.body_set_collision_layer(body, Layers.STRUCTURE)
		PhysicsServer3D.body_set_collision_mask(body, Layers.STRUCTURE_MASK)
		# See IslandManager.spawn: the shapes are built inside the extension,
		# dead blocks disabled as they go.
		var built: Dictionary = world.add_chunk_shapes(body, chunk, Vector3.ZERO, merge, merge,
				si if n > 1 else -1)
		PhysicsServer3D.body_set_state(body, PhysicsServer3D.BODY_STATE_TRANSFORM, xform)
		PhysicsServer3D.body_set_space(body, space)
		bodies.append(body)
		maps.append(built.get("map", {}))
		merged.append(merge)


func free_bodies() -> void:
	for body in bodies:
		PhysicsServer3D.free_rid(body)
	bodies.clear()
	maps.clear()
	merged.clear()


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
func reshape(si: int, merge: bool) -> float:
	if si < 0 or si >= bodies.size() or merged[si] == merge:
		return 0.0
	var t := Time.get_ticks_usec()
	var body := bodies[si]
	var space := PhysicsServer3D.body_get_space(body)
	# Out of the space first: a shape call on a body IN a space costs time
	# proportional to its shape count.
	if space.is_valid():
		PhysicsServer3D.body_set_space(body, RID())
	PhysicsServer3D.body_clear_shapes(body)
	# skip_dead now, where promotion cannot: by this point the holes are known,
	# so a dead brick costs no box at all rather than a disabled one.
	var built: Dictionary = world.add_chunk_shapes(body, chunk, Vector3.ZERO, true, merge,
			si if bodies.size() > 1 else -1)
	maps[si] = built.get("map", {})
	merged[si] = merge
	if space.is_valid():
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


## The bands these blocks are in, each once.
func bands_of(ids: PackedInt32Array) -> PackedInt32Array:
	var out := PackedInt32Array()
	if bodies.size() == 1:
		out.append(0)
		return out
	for si in world.get_block_sections(chunk, ids):
		if si >= 0 and si < bodies.size() and not out.has(si):
			out.append(si)
	return out


## Switch off the shapes these blocks own. A merged band they are in is made a
## box a brick first -- only that band.
func disable(ids: PackedInt32Array) -> void:
	if ids.is_empty():
		return
	for si in bands_of(ids):
		if merged[si]:
			# Rebuilt without the dead: blocks already dead get no box at all.
			reshape(si, false)
		var map: Dictionary = maps[si]
		var any := false
		for bid in ids:
			if map.has(bid):
				any = true
				break
		if not any:
			continue
		var body := bodies[si]
		var space := PhysicsServer3D.body_get_space(body)
		# Lifting the body out of the space first: each shape call costs time
		# proportional to the body's shape count, so in a loop it is quadratic.
		if space.is_valid():
			PhysicsServer3D.body_set_space(body, RID())
		for bid in ids:
			if map.has(bid):
				for shape_index in map[bid]:
					PhysicsServer3D.body_set_shape_disabled(body, shape_index, true)
		if space.is_valid():
			PhysicsServer3D.body_set_space(body, space)
