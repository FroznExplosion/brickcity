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
## Which blocks, by their index in this record, are furniture
## (BrickWorld.set_blocks_decorative). Without it a piece that slept woke with its
## furniture turned into structure: bearing load, holding things up, and named in
## a DETACH as if every machine had it. A list, not a byte per block, because most
## pieces carry none and a record is meant to cost 17 bytes a block.
var decorative := PackedInt32Array()
## Where the chunk's grid starts, in the building's grid. A piece cut out of a
## building keeps the absolute cells its bricks had, and those cells are how the
## log names them (DamageLog, piece commands) -- so a piece has to wake up at the
## same origin, not at zero, or every command after its sleep lands somewhere else.
var origin := Vector3i.ZERO
## Severed joints, sparse: [index, BrickWorld joint bits] pairs. A joint a landing
## had cut used to be whole again when the piece woke.
var joints := PackedInt32Array()
## Bricks a gun has worn down, sparse: [index, hp] pairs (BrickWorld.chip_hit). A
## piece that slept used to wake with every brick back at full strength.
var worn := PackedInt32Array()
## The grid's own orientation, which is authoring data and not the transform.
var rotation := 0
var origin_ticks := Vector3i.ZERO
## World AABB when it went to sleep. A dormant piece still has to answer "is
## this blast anywhere near you" without being rebuilt to do it.
var box := AABB()

## A capture in progress (begin_capture / capture_some / finish_capture). Not
## part of the record -- nothing here is saved.
var next := 0
## The blocks that are NOT standing: dead, or cut out into another piece. A
## removed block has no box and is skipped on its own. Asked of the world as two
## short lists, where asking every block's box and keeping a set of the standing
## ones was 70 ms of a big wreck's capture before a single block was recorded.
var _gone := {}
## Block id -> its index in this record, for the worn bricks at the end.
var _index_of := {}
var _lo := Vector3(INF, INF, INF)
var _hi := Vector3(-INF, -INF, -INF)


func block_count() -> int:
	return archetypes.size()


## Bytes this record holds. What the tier is FOR, so it is measurable.
func bytes() -> int:
	return cells.size() * 4 + archetypes.size() * 4 + colours.size() + decorative.size() * 4 \
			+ joints.size() * 4 + worn.size() * 4


## For a save file (AreaSnapshot). Archetypes are written by NAME: fixture parts
## are baked on first demand, so a stair step's archetype number depends on what
## this session happened to build first, and the next session may number it
## differently.
func to_data(world: BrickWorld) -> Dictionary:
	var names := PackedStringArray()
	var index := {}
	var refs := PackedInt32Array()
	for a in archetypes:
		if not index.has(a):
			index[a] = names.size()
			names.append(world.get_archetype_name(a))
		refs.append(int(index[a]))
	return {"dims": dims, "xform": xform, "cells": cells, "names": names, "refs": refs,
			"colours": colours, "decorative": decorative, "joints": joints, "worn": worn,
			"origin": origin, "rotation": rotation,
			"origin_ticks": origin_ticks, "box": box}


## Back from to_data, against this session's archetypes. Returns null if a part
## it needs has not been baked here -- the caller builds the buildings (and so
## their parts) first.
static func from_data(world: BrickWorld, d: Dictionary) -> ChunkRecord:
	var by_name := {}
	for a in world.get_archetype_count():
		by_name[world.get_archetype_name(a)] = a
	var r := ChunkRecord.new()
	r.dims = d.dims
	r.xform = d.xform
	r.cells = d.cells
	r.colours = d.colours
	r.decorative = d.get("decorative", PackedInt32Array())
	r.joints = d.get("joints", PackedInt32Array())
	r.worn = d.get("worn", PackedInt32Array())
	r.origin = d.get("origin", Vector3i.ZERO)
	r.rotation = int(d.rotation)
	r.origin_ticks = d.origin_ticks
	r.box = d.box
	var names: PackedStringArray = d.names
	for i in (d.refs as PackedInt32Array):
		var n: String = names[i]
		if not by_name.has(n):
			push_warning("[record] no archetype called %s in this session" % n)
			return null
		r.archetypes.append(int(by_name[n]))
	return r


## Photograph a chunk. Only what is standing goes in: what comes back is what is
## standing, which is all a lump of rubble is.
##
## "Standing" is ALIVE, not "not in get_dead_blocks". That list deliberately
## leaves out DETACHED blocks -- the ones that left as a piece of their own --
## because a building rebuilt from its recipe must not show them as holes. For a
## record it is the wrong question: a piece that had shed bricks came back from
## sleep with those bricks resurrected, standing in it again while the piece
## they left on went on existing. Found chasing a piece that held 1,140 bricks
## more than its replay in the city's log-replay check (Docs/AIPlan.md P0 step
## 4); tools/dormant_probe.gd shows it directly -- 50 shed, 80 standing, and the
## old rule kept 130.
static func capture(world: BrickWorld, chunk: int) -> ChunkRecord:
	var r := begin_capture(world, chunk)
	if chunk < 0 or not world.is_chunk_alive(chunk):
		return r
	r.capture_some(world, chunk, 1 << 30)
	r.finish_capture(world, chunk)
	return r


## The same capture, a slice at a time, for a piece too big to capture in one
## tick (IslandManager.CAPTURE_BLOCKS_PER_TICK). begin, then capture_some until
## it says done, then finish -- and the record is exactly what capture() makes,
## because capture() is those three calls. The chunk must not change in
## between; the caller checks.
static func begin_capture(world: BrickWorld, chunk: int) -> ChunkRecord:
	var r := ChunkRecord.new()
	if chunk < 0 or not world.is_chunk_alive(chunk):
		return r
	r.dims = world.get_chunk_dims(chunk)
	r.origin = world.get_chunk_origin(chunk)
	r.xform = world.get_chunk_transform(chunk)
	r.rotation = world.get_chunk_rotation(chunk)
	r.origin_ticks = world.get_chunk_origin_ticks(chunk)
	for id in world.get_dead_blocks(chunk):
		r._gone[id] = true
	for id in world.get_detached_blocks(chunk):
		r._gone[id] = true
	return r


## Capture up to `count` more block ids. True when every block has been seen.
func capture_some(world: BrickWorld, chunk: int, count: int) -> bool:
	var r := self
	var gone := _gone
	var index_of := _index_of
	var t := BrickWorld.ticks_per_stud()
	var pt := BrickWorld.ticks_per_plate()
	var lo := _lo
	var hi := _hi
	var cell := BrickWorld.get_cell_size()
	var n := world.get_block_count(chunk)
	var end := mini(next + count, n)
	for id in range(next, end):
		if gone.has(id):
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
		if world.is_block_decorative(chunk, id):
			r.decorative.push_back(r.archetypes.size())
		var cut := world.get_block_joints(chunk, id)
		if cut != 0:
			r.joints.push_back(r.archetypes.size())
			r.joints.push_back(cut)
		index_of[id] = r.archetypes.size()
		r.archetypes.push_back(world.get_block_archetype(chunk, id))
		r.colours.push_back(world.get_block_colour(chunk, id))
		var a := Vector3(at) * (cell.x / float(t))
		var b := Vector3(at + size) * (cell.x / float(t))
		lo = Vector3(minf(lo.x, a.x), minf(lo.y, a.y), minf(lo.z, a.z))
		hi = Vector3(maxf(hi.x, b.x), maxf(hi.y, b.y), maxf(hi.z, b.z))
	_lo = lo
	_hi = hi
	next = end
	return next >= n


## The worn bricks and the world box, once every block has been seen; and the
## working state let go.
func finish_capture(world: BrickWorld, chunk: int) -> void:
	var r := self
	var lo := _lo
	var hi := _hi
	var w := world.get_worn_blocks(chunk)
	for k in range(0, w.size() - 1, 2):
		if _index_of.has(w[k]):
			r.worn.push_back(int(_index_of[w[k]]))
			r.worn.push_back(w[k + 1])
	_gone = {}
	_index_of = {}
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


## Build it again. Returns the new chunk, or -1.
##
## The blocks go back in capture order, so a record round-trips to the same
## chunk -- same block ids, same bake, same mesh. That is what makes this a LOD
## tier rather than a destructive optimisation.
func restore(world: BrickWorld) -> int:
	if block_count() == 0:
		return -1
	var chunk := world.create_chunk(origin, dims)
	if chunk < 0:
		return -1
	if rotation != 0 or origin_ticks != Vector3i.ZERO:
		world.set_chunk_frame(chunk, rotation, origin_ticks)
	var placed := PackedInt32Array()
	for i in block_count():
		placed.append(world.place_block(chunk, origin + Vector3i(cells[i * 3], cells[i * 3 + 1], cells[i * 3 + 2]),
				archetypes[i], colours[i]))
	var furniture := PackedInt32Array()
	for i in decorative:
		if i < placed.size() and placed[i] >= 0:
			furniture.append(placed[i])
	if not furniture.is_empty():
		world.set_blocks_decorative(chunk, furniture, true)
	for k in range(0, joints.size() - 1, 2):
		var i := joints[k]
		if i < placed.size() and placed[i] >= 0:
			world.set_block_joints(chunk, placed[i], joints[k + 1])
	var hp := PackedInt32Array()
	for k in range(0, worn.size() - 1, 2):
		var i := worn[k]
		if i < placed.size() and placed[i] >= 0:
			hp.push_back(placed[i])
			hp.push_back(worn[k + 1])
	if not hp.is_empty():
		world.set_worn_blocks(chunk, hp)
	world.set_chunk_transform(chunk, xform)
	return chunk
