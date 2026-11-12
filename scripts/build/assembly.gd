class_name Assembly
extends RefCounted

## A creation: a tree of FRAMES joined by WELDS. Docs/BuildMode.md sections 1-2.
##
## A frame is one chunk at one of the 24 axis-aligned rotations, offset by an
## exact integer number of ticks. Frame 0 is upright and is where almost
## everything lives; a rotated frame is how sideways building happens, because
## rotating a BLOCK 90 degrees about X or Z swaps a stud axis with the plate
## axis and lands on 1.2 studs, which the grid cannot express (section 2.1).
##
## Nothing here is a new runtime object. A frame is a chunk, which already has
## its own grid, its own transform and its own body; a weld is an edge between
## two blocks in two of them. What this class adds is the bookkeeping: which
## frames exist, which welds hold them on, and which frames are still attached
## to the root after something has been shot.

## A weld is rigid, so a sideways frame is grounded THROUGH its welds rather
## than by a foundation of its own. Without that every rotated frame reads as
## ungrounded and falls off on the first solve.
var world: BrickWorld
var palette := {}

## chunk ids, in creation order. frames[0] is the root and is never welded on.
var frames: PackedInt32Array = PackedInt32Array()
## weld ids in `world`, for the welds this assembly owns.
var welds: PackedInt32Array = PackedInt32Array()
## Frames that are fixed TO structure rather than being structure: a staircase,
## a railing, a cornice. chunk id -> true.
##
## Docs/BuildMode.md section 9.2. A decorative frame is **absent from the solve
## entirely** -- it carries no load, contributes no capacity, is grounded by
## assertion rather than through the weld tree, and is released rather than
## re-solved when what holds it dies. Three costs go at once: it adds nothing
## to `solve_stress`, it needs no seed-set grounding, and having no load path
## it imposes no ordering on anyone else.
##
## Authored, not player-facing (section 9.2): "decorative" is a promise that
## nothing load-bearing rests on it, and a player handed the flag would build a
## floor out of decorative parts and get a bridge that holds for free.
var decorative := {}


func _init(brick_world: BrickWorld, part_palette: Dictionary) -> void:
	world = brick_world
	palette = part_palette


func frame_count() -> int:
	return frames.size()


func root() -> int:
	return frames[0] if frames.size() > 0 else -1


## Add a frame. `rotation` indexes the 24 axis-aligned rotations; `origin_ticks`
## is where its grid origin sits, in ticks (a stud is 5, a plate is 2).
##
## Exact integers are the whole point: two frames can only be guaranteed to
## touch if the offset between them is on the tick lattice, and float would put
## that guarantee at the mercy of rounding.
func add_frame(dims: Vector3i, rotation: int = 0,
		origin_ticks: Vector3i = Vector3i.ZERO) -> int:
	var c := world.create_chunk(Vector3i.ZERO, dims)
	if c < 0:
		return -1
	world.set_chunk_frame(c, rotation, origin_ticks)
	frames.push_back(c)
	return c


## Mark a frame as fixed to structure rather than as structure.
func set_decorative(frame_chunk: int, on: bool = true) -> void:
	if on:
		decorative[frame_chunk] = true
	else:
		decorative.erase(frame_chunk)


func is_decorative(frame_chunk: int) -> bool:
	return decorative.has(frame_chunk)


## Frames that are in the solve. The root always is.
func structural_frames() -> PackedInt32Array:
	var out := PackedInt32Array()
	for f in frames:
		if not is_decorative(f):
			out.push_back(f)
	return out


## Weld two blocks in two different frames.
##
## `a` is the parent side. The weld is rigid and carries the child's whole
## weight, so which end is which matters for grounding order, not for the join.
func weld(chunk_a: int, block_a: int, chunk_b: int, block_b: int) -> int:
	var w := world.add_weld(chunk_a, block_a, chunk_b, block_b)
	if w >= 0:
		welds.push_back(w)
	return w


## Can this part go here without hitting anything in ANOTHER frame?
##
## Occupancy is per chunk, so nothing in the extension can see across a frame
## boundary on its own -- `place_block` would happily drop a sideways brick
## inside an upright one. This is the check that stops it, and it is
## authoring-time only: it never runs on the damage path (Plan B2).
func can_place(chunk_id: int, cell: Vector3i, archetype_id: int) -> bool:
	if not world.can_place(chunk_id, cell, archetype_id):
		return false
	for other in frames:
		if other == chunk_id:
			continue
		if world.overlaps_frame(chunk_id, cell, archetype_id, other):
			return false
	return true


## Place a part, refusing a cross-frame collision as well as an in-frame one.
func place(chunk_id: int, cell: Vector3i, archetype_id: int, colour: int) -> int:
	if not can_place(chunk_id, cell, archetype_id):
		return -1
	return world.place_block(chunk_id, cell, archetype_id, colour)


# ---------------------------------------------------------------------------
# What is still attached
# ---------------------------------------------------------------------------

## Solve grounding across the whole assembly, root first, through the welds.
##
## Returns frame chunk id -> PackedByteArray of per-block grounded flags.
##
## The root frame is grounded by its foundation, as any building is. Every other
## frame is grounded by the welds that reach it: a live weld whose parent-side
## block came out grounded contributes its child-side block as a SEED, and that
## frame floods from there. Solve order is the weld tree, so a frame is always
## solved after whatever holds it (Docs/BuildMode.md section 3.3).
func solve_grounded() -> Dictionary:
	var out := {}
	if frames.is_empty():
		return out
	out[frames[0]] = world.solve_grounded(frames[0])

	# Frames come in creation order and a weld always attaches a new frame to an
	# existing one, so one pass in that order visits parents before children.
	# Repeat while anything changed, so a weld pointing "backwards" still works.
	var changed := true
	var passes := 0
	while changed and passes < frames.size() + 2:
		changed = false
		passes += 1
		for f in frames:
			if f == frames[0]:
				continue
			if is_decorative(f):
				continue  # held by assertion; it is in no solve at all
			var seeds := _seeds_for(f, out)
			if seeds.is_empty():
				if not out.has(f):
					out[f] = world.solve_grounded_from(f, PackedInt32Array())
					changed = true
				continue
			var before: int = _count(out.get(f, PackedByteArray()))
			out[f] = world.solve_grounded_from(f, seeds)
			if _count(out[f]) != before:
				changed = true
	return out


## Blocks of `frame` that a live weld reaches from an already-grounded block.
func _seeds_for(frame: int, grounded: Dictionary) -> PackedInt32Array:
	var seeds := PackedInt32Array()
	for wid in welds:
		if not world.is_weld_alive(wid):
			continue
		var w: Dictionary = world.get_weld(wid)
		# A structural frame may not be grounded THROUGH a decorative one
		# (section 9.2): "decorative" promises nothing load-bearing rests on it,
		# and a path to ground that runs through a staircase is exactly that.
		if is_decorative(w.chunk_a) or is_decorative(w.chunk_b):
			continue
		# A weld is undirected for grounding: whichever end is already grounded
		# seeds the other.
		if w.chunk_b == frame and _is_grounded(grounded, w.chunk_a, w.block_a):
			seeds.push_back(w.block_b)
		elif w.chunk_a == frame and _is_grounded(grounded, w.chunk_b, w.block_b):
			seeds.push_back(w.block_a)
	return seeds


func _is_grounded(grounded: Dictionary, chunk: int, block: int) -> bool:
	if not grounded.has(chunk):
		return false
	var flags: PackedByteArray = grounded[chunk]
	return block >= 0 and block < flags.size() and flags[block] != 0


func _count(flags: PackedByteArray) -> int:
	var n := 0
	for v in flags:
		if v != 0:
			n += 1
	return n


## Which frames are still held on, and which have come loose.
##
## Returns {"attached": [chunk ids], "detached": [chunk ids]}. A frame is
## attached when a live weld reaches it from a grounded block; detachment is a
## question about the WELD GRAPH's components, not about one chunk, because a
## released weld may take several frames with it and a frame may be held by a
## second weld.
func detached_frames() -> Dictionary:
	var grounded := solve_grounded()
	var attached := [frames[0]] if frames.size() > 0 else []
	var loose := []
	var released := []
	for f in frames:
		if f == frames[0]:
			continue
		if is_decorative(f):
			# It was never in the solve, so "is it grounded" is not the
			# question. The question is whether anything is still holding it,
			# and when nothing is it is RELEASED rather than detached -- the
			# distinction matters because a released fixture is not re-solved,
			# it crumbles on its own (section 9.2).
			if _welds_holding(f) > 0:
				attached.append(f)
			else:
				released.append(f)
			continue
		var flags: PackedByteArray = grounded.get(f, PackedByteArray())
		if _count(flags) > 0:
			attached.append(f)
		else:
			loose.append(f)
	return {"attached": attached, "detached": loose, "released": released}


## Live welds with an end in this frame.
func _welds_holding(frame: int) -> int:
	var n := 0
	for wid in welds:
		if not world.is_weld_alive(wid):
			continue
		var w: Dictionary = world.get_weld(wid)
		if w.chunk_a == frame or w.chunk_b == frame:
			n += 1
	return n


## Total live welds this assembly still holds. A weld dies when either of its
## blocks does -- derived, never invalidated, so nothing can go stale.
func live_weld_count() -> int:
	var n := 0
	for wid in welds:
		if world.is_weld_alive(wid):
			n += 1
	return n
