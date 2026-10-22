extends RefCounted

## Translation-only floating origin, prototype (Docs/Planets.md 10b, the
## feasibility tests 1 and 2).
##
## `shift(city, offset)` moves everything the city scene holds by `offset` in
## one frame: nodes, the bodies that live only on the physics server, the
## BrickWorld chunks, the registry's buildings, the AI's proxies, WorldFrame.
## Nothing turns, so nothing inside a building, a piece or a tile changes -- a
## shift in whole 32-stud terrain tiles keeps even the stud lattice where it
## was.
##
## What it does NOT move is the list the test reports (Planets.md 10b, test 2):
## whatever holds an absolute position this prototype cannot reach.

## Metres in one terrain tile: shifts go in whole tiles.
static func tile_metres() -> float:
	return float(BrickTerrain.get_tile_studs()) * BrickWorld.get_stud_metres()


## `offset` rounded to whole tiles in X and Z and whole tiles in Y too (a tile
## is 32 studs, 160 ticks; in Y it is 80 plates -- whole plates and ticks).
static func whole_tiles(offset: Vector3) -> Vector3:
	var t := tile_metres()
	return Vector3(roundf(offset.x / t) * t, roundf(offset.y / t) * t, roundf(offset.z / t) * t)


## Every body and area in `space`, as {rid: object-or-null}: one shape query
## the size of everything. Server-only bodies (no node) come back with a null
## collider. The query is the prototype's way to find them; a real shift keeps
## a list.
static func bodies_in(space: RID, centre: Vector3, half: float) -> Dictionary:
	var box := BoxShape3D.new()
	box.size = Vector3.ONE * half * 2.0
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = box
	q.transform = Transform3D(Basis(), centre)
	q.collide_with_areas = false
	q.collide_with_bodies = true
	q.collision_mask = 0xFFFFFFFF
	var hits := PhysicsServer3D.space_get_direct_state(space).intersect_shape(q, 1 << 20)
	var out := {}
	for h in hits:
		out[h.rid] = h.collider
	return out


## Move the whole city scene by `offset`. Returns the time each part took, in
## microseconds, and counts.
static func shift(city: Node3D, offset: Vector3, find_half := 30000.0) -> Dictionary:
	var r := {}
	var t_all := Time.get_ticks_usec()
	var tr := Transform3D(Basis(), offset)

	# 1. Bodies the physics server holds with no node: shells, rooms, frames,
	# a promoted building's bands, terrain tiles, the sea. Found before
	# anything moves. Parked band bodies are out of the space and found
	# through their owner instead.
	var t := Time.get_ticks_usec()
	var found := bodies_in(city.get_world_3d().space, city.camera.global_position, find_half)
	r.find_us = Time.get_ticks_usec() - t
	t = Time.get_ticks_usec()
	var server_only := {}
	for rid in found:
		if found[rid] == null:
			server_only[rid] = true
	for bc in city._brick_cols.values():
		for body in bc.bodies:
			server_only[body] = true
	for rid in server_only:
		var xf: Transform3D = PhysicsServer3D.body_get_state(rid, PhysicsServer3D.BODY_STATE_TRANSFORM)
		PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_TRANSFORM, tr * xf)
	r.server_bodies = server_only.size()
	r.server_us = Time.get_ticks_usec() - t

	# 2. Nodes: every Node3D with no Node3D above it (or top_level), in the
	# city and in the autoloads. Children follow their parents.
	t = Time.get_ticks_usec()
	var moved: Array[Node3D] = []
	_collect(city.get_tree().root, moved, false)
	for n in moved:
		n.global_position += offset
	for n in moved:
		n.reset_physics_interpolation()
	r.nodes = moved.size()
	r.nodes_us = Time.get_ticks_usec() - t

	# 3. The brick world's chunks: buildings, pieces, records. A piece's chunk
	# follows its body anyway; a sleeping or standing one only follows this.
	t = Time.get_ticks_usec()
	var w: BrickWorld = city.world
	var chunks := 0
	for c in w.get_chunk_count():
		if w.is_chunk_alive(c):
			w.set_chunk_transform(c, tr * w.get_chunk_transform(c))
			chunks += 1
	r.chunks = chunks
	r.chunks_us = Time.get_ticks_usec() - t

	# 4. The registry's buildings (their xform is the world's; boxes are local).
	t = Time.get_ticks_usec()
	for b in city.registry.buildings:
		b.xform = tr * b.xform
	r.buildings = city.registry.buildings.size()
	r.registry_us = Time.get_ticks_usec() - t

	# 5. The AI: its proxies, cover, smoke and danger move (AIWorld.shift_origin);
	# the walking maps are keyed by world stud column, so they are dropped and
	# read again where the bricks now are (cold once).
	t = Time.get_ticks_usec()
	city.ai_world.shift_origin(offset)
	city.ai_world.sync()
	r.ai_world_us = Time.get_ticks_usec() - t
	t = Time.get_ticks_usec()
	city.ai_nav.clear_cache()
	if city.mech_nav != null:
		city.mech_nav.clear_cache()
	r.ai_nav_us = Time.get_ticks_usec() - t

	# 6. WorldFrame: the scene origin's place in the body's frame moves the
	# other way, so a saved position means the same point.
	WorldFrame.origin -= offset
	r.total_us = Time.get_ticks_usec() - t_all
	return r


static func _collect(n: Node, out: Array[Node3D], under3d: bool) -> void:
	for c in n.get_children():
		var is3d := c is Node3D
		if is3d and (not under3d or (c as Node3D).top_level):
			out.append(c)
		_collect(c, out, under3d or is3d)
