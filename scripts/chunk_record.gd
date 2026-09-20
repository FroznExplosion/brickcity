class_name ChunkRecord
extends RefCounted

## A chunk as bytes: what a piece of the world is when nothing is simulating it.
##
## Plan.md §4.2's ladder, for the one thing that never had it. A building is a
## recipe until something hits it, a fixture is built with its host, a player
## creation is a recipe and a shell -- and **wreckage is wreckage forever**. An
## island that has come to rest keeps a chunk, an occupancy grid, a face bake, a
## mesh and a body, for as long as the scene lasts, however far away it is and
## however long nobody has looked at it. Docs/Status.md's worst case is 1.2 GB
## and most of it is exactly this.
##
## The reason it never had the ladder is that it has no recipe. A tower can be
## regenerated from three numbers; a lump of rubble is the arbitrary leftovers
## of a collapse and the only description of it is the blocks themselves. So
## this is that description, and nothing else: a cell, an archetype and a colour
## per block, plus where it stands.
##
##   a settled island   chunk + occupancy grid + bake + mesh + body
##   its record         17 bytes a block -- three ints of cell, an int of
##                      archetype, a byte of colour
##
## What it deliberately does NOT keep is the damage record. A building's dead
## list has to survive because the building will be rebuilt from a recipe that
## does not know about it; a record is captured from the world AFTER the damage,
## so what is gone is simply not in it. Rubble has no history, only a shape.
##
## [Interiors §5](../Docs/Interiors.md) wants the same thing for room contents,
## which is why this is a type of its own rather than three fields on
## `BrickIsland`.

var dims := Vector3i.ONE
var xform := Transform3D()
## 3 ints per block: the cell its origin sits in.
var cells := PackedInt32Array()
var archetypes := PackedInt32Array()
var colours := PackedByteArray()
## The grid's own orientation, which is authoring data and not the transform.
var rotation := 0
var origin_ticks := Vector3i.ZERO
## World AABB when it went to sleep. A dormant piece still has to answer "is
## this blast anywhere near you" without being rebuilt to do it.
var box := AABB()


func block_count() -> int:
	return archetypes.size()


## Bytes this record holds. What the tier is FOR, so it is measurable.
func bytes() -> int:
	return cells.size() * 4 + archetypes.size() * 4 + colours.size()


## Photograph a chunk. Dead and removed blocks are left out: what comes back is
## what is standing, which is all a lump of rubble is.
static func capture(world: BrickWorld, chunk: int) -> ChunkRecord:
	var r := ChunkRecord.new()
	if chunk < 0 or not world.is_chunk_alive(chunk):
		return r
	r.dims = world.get_chunk_dims(chunk)
	r.xform = world.get_chunk_transform(chunk)
	r.rotation = world.get_chunk_rotation(chunk)
	r.origin_ticks = world.get_chunk_origin_ticks(chunk)

	var dead := {}
	for id in world.get_dead_blocks(chunk):
		dead[id] = true
	var t := BrickWorld.ticks_per_stud()
	var pt := BrickWorld.ticks_per_plate()
	var lo := Vector3(INF, INF, INF)
	var hi := Vector3(-INF, -INF, -INF)
	var cell := BrickWorld.get_cell_size()
	for id in world.get_block_count(chunk):
		if dead.has(id):
			continue
		# An empty box is a REMOVED block -- a tombstone that kept its id so
		# that nothing keyed on ids has to move. It is not part of the shape.
		var ticks: Array = world.get_block_ticks(chunk, id)
		if ticks.is_empty():
			continue
		var at: Vector3i = ticks[0]
		var size: Vector3i = ticks[1]
		@warning_ignore("integer_division")
		var c := Vector3i(at.x / t, at.y / pt, at.z / t)
		r.cells.push_back(c.x)
		r.cells.push_back(c.y)
		r.cells.push_back(c.z)
		r.archetypes.push_back(world.get_block_archetype(chunk, id))
		r.colours.push_back(world.get_block_colour(chunk, id))
		var a := Vector3(at) * (cell.x / float(t))
		var b := Vector3(at + size) * (cell.x / float(t))
		lo = Vector3(minf(lo.x, a.x), minf(lo.y, a.y), minf(lo.z, a.z))
		hi = Vector3(maxf(hi.x, b.x), maxf(hi.y, b.y), maxf(hi.z, b.z))
	if r.block_count() > 0:
		# In WORLD space: the eight corners of the local box under the chunk's
		# own transform, because a piece at rest is usually lying at an angle.
		var first := true
		for i in 8:
			var corner: Vector3 = r.xform * Vector3(
					hi.x if (i & 1) else lo.x,
					hi.y if (i & 2) else lo.y,
					hi.z if (i & 4) else lo.z)
			if first:
				r.box = AABB(corner, Vector3.ZERO)
				first = false
			else:
				r.box = r.box.expand(corner)
	return r


## Build it again. Returns the new chunk, or -1.
##
## The blocks go back in capture order, so a record round-trips to the same
## chunk -- same block ids, same bake, same mesh. That is what makes this a LOD
## tier rather than a destructive optimisation.
func restore(world: BrickWorld) -> int:
	if block_count() == 0:
		return -1
	var chunk := world.create_chunk(Vector3i.ZERO, dims)
	if chunk < 0:
		return -1
	if rotation != 0 or origin_ticks != Vector3i.ZERO:
		world.set_chunk_frame(chunk, rotation, origin_ticks)
	for i in block_count():
		world.place_block(chunk, Vector3i(cells[i * 3], cells[i * 3 + 1], cells[i * 3 + 2]),
				archetypes[i], colours[i])
	world.set_chunk_transform(chunk, xform)
	return chunk
