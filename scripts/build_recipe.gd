class_name BuildRecipe
extends RefCounted

## What a player built, as a recipe rather than as bricks.
##
## Docs/BuildMode.md section 8. Same pattern as everything else in this project:
## the thing that is saved, placed, replicated and (later) exported is a compact
## deterministic generator, and the bricks are derived from it on demand.
##
## **Placement order IS block id order.** That is not a style choice -- it is the
## determinism guarantee M3 rides on. `BuildingRegistry` keys its damage record
## on block id, so id N has to mean the same brick every time this recipe is
## built, forever. Anything that reorders `_cells` breaks saved damage in every
## existing save, which is what `VERSION` exists to catch.
##
## Parts are stored by **name**, not by archetype id. Ids are assigned by bake
## order inside one BrickWorld and mean nothing across a save; names are the
## stable identity (Docs/Status.md, the part palette).

const VERSION := 4
## Every older version means the same thing in a newer one, because each bump
## has only ADDED a column: v2 added welds, v3 added fixtures, v4 added the
## structure/interior role per block. So an old recipe loads rather than being
## refused, and it comes back with exactly what it was saved with -- a v1
## sideways build with nothing holding its frames on, a v2 build with no
## staircase in it, a v3 build that is structure all the way through, which is
## what every recipe authored before the workshop had two layers actually is.
const OLDEST_VERSION := 1

var name := "untitled"

## Distinct archetype names used, in first-use order. Blocks index into this, so
## a 500-brick house carries ~8 strings rather than 500.
var parts := PackedStringArray()

## Frames, as (rotation, origin in ticks). Frame 0 is always the identity and is
## never stored -- a single-frame recipe carries none of this at all, which is
## the overwhelmingly common case.
##
## Ticks, not metres: two frames can only be guaranteed to meet if the offset
## between them is on the tick lattice (a stud is 5, a plate is 2), and a float
## offset in a save file would leave that to rounding.
var _frame_rot := PackedInt32Array()    ## one per frame beyond 0
var _frame_ticks := PackedInt32Array()  ## 3 ints per frame beyond 0

# Parallel arrays, one entry per block, in placement order.
var _cells := PackedInt32Array()   ## 3 ints per block: x, y, z
var _parts := PackedInt32Array()   ## index into `parts`
var _colours := PackedByteArray()
var _frames := PackedInt32Array()  ## which frame each block is in
## 1 if this block is INTERIOR -- fixed to the structure rather than being it.
##
## Authored, not derived. Nothing about a chair's shape or position says it is
## not load-bearing; a player who builds a table out of the same bricks as a
## wall has built a table, and only they know that. BuildMode §9.2 left this as
## an authored flag on a frame and said so; it is a flag on a BLOCK, which is
## the unit the city's own interiors turned out to need (Block::decorative).
var _decor := PackedByteArray()

## Welds, as 2 ints per weld: the two BLOCK IDS joined.
##
## Block ids, not chunk ids and not frames: a chunk id means nothing across a
## save, and the frames are already known from the blocks, so storing them as
## well would be a second copy of the same fact that could disagree with the
## first. Docs/BuildMode.md section 2.8 -- a weld's aliveness is derived from
## its two blocks, and this is the authoring-time record of which two.
##
## Without this a saved sideways build loads with its frames and nothing
## holding them on, and every rotated frame falls off on the first solve
## (section 3.3).
var _welds := PackedInt32Array()

## Fixtures: staircases, railings, the things fixed TO a build rather than
## built out of it (Docs/BuildMode.md section 9).
##
## One record per fixture, not one per brick, so this is a handful of entries
## where everything above is a column -- and it is a plain Array of plain
## Dictionaries for the same reason those are plain arrays: what is in memory
## and what is in the file have to be the same thing, or JSON quietly turns one
## into the other's string form.
##
##   {"kind": "staircase", "cell": [x, y, z], "role": 1, "params": {...}}
##
## The cell is in FRAME 0's grid, the same coordinates the bricks are in, so a
## fixture rebases with the build and needs no coordinate of its own.
var _fixtures := []


func size() -> int:
	return _parts.size()


func is_empty() -> bool:
	return _parts.is_empty()


## Append a block. Returns the block id it will have when built, which is also
## its index here -- the two are the same number by construction.
func add(archetype_name: String, cell: Vector3i, colour: int, frame: int = 0,
		interior: bool = false) -> int:
	var pi := parts.find(archetype_name)
	if pi < 0:
		pi = parts.size()
		parts.push_back(archetype_name)
	var id := _parts.size()
	_cells.push_back(cell.x)
	_cells.push_back(cell.y)
	_cells.push_back(cell.z)
	_parts.push_back(pi)
	_colours.push_back(clampi(colour, 0, 255))
	_frames.push_back(maxi(frame, 0))
	_decor.push_back(1 if interior else 0)
	return id


## Is this block interior rather than structure?
func is_interior(id: int) -> bool:
	return id >= 0 and id < _decor.size() and _decor[id] != 0


## How many blocks of this recipe are interior.
func interior_count() -> int:
	var n := 0
	for v in _decor:
		if v != 0:
			n += 1
	return n


## Join two blocks with a weld. Order is parent-then-child, which matters for
## grounding order and not for the join itself.
func add_weld(block_a: int, block_b: int) -> int:
	if block_a < 0 or block_b < 0 or block_a >= size() or block_b >= size():
		return -1
	_welds.push_back(block_a)
	_welds.push_back(block_b)
	@warning_ignore("integer_division")
	var n: int = _welds.size() / 2
	return n - 1


func weld_count() -> int:
	@warning_ignore("integer_division")
	var n: int = _welds.size() / 2
	return n


## The two block ids a weld joins.
func weld_blocks(i: int) -> Vector2i:
	return Vector2i(_welds[i * 2], _welds[i * 2 + 1])


## Declare a frame and return its index. Frame 0 exists implicitly.
func add_frame(rotation: int, origin_ticks: Vector3i) -> int:
	_frame_rot.push_back(rotation)
	_frame_ticks.push_back(origin_ticks.x)
	_frame_ticks.push_back(origin_ticks.y)
	_frame_ticks.push_back(origin_ticks.z)
	return _frame_rot.size()  # 0 is implicit, so the first added frame is 1


func frame_count() -> int:
	return _frame_rot.size() + 1


func is_single_frame() -> bool:
	return _frame_rot.is_empty()


func frame_of(id: int) -> int:
	return _frames[id] if id < _frames.size() else 0


func frame_rotation(frame: int) -> int:
	return 0 if frame <= 0 else _frame_rot[frame - 1]


func frame_ticks(frame: int) -> Vector3i:
	if frame <= 0:
		return Vector3i.ZERO
	var i := (frame - 1) * 3
	return Vector3i(_frame_ticks[i], _frame_ticks[i + 1], _frame_ticks[i + 2])


## Attach a fixture, in frame 0's coordinates. Returns its index.
func add_fixture(kind: String, cell: Vector3i, params: Dictionary,
		role: int = Fixture.Role.DECORATIVE) -> int:
	_fixtures.append({
		"kind": kind,
		"cell": [cell.x, cell.y, cell.z],
		"role": int(role),
		"params": params.duplicate(true),
	})
	return _fixtures.size() - 1


func fixture_count() -> int:
	return _fixtures.size()


## One fixture, with its cell as a Vector3i rather than as three numbers.
func fixture_at(i: int) -> Dictionary:
	if i < 0 or i >= _fixtures.size():
		return {}
	var f: Dictionary = _fixtures[i]
	var c: Array = f.get("cell", [0, 0, 0])
	return {
		"kind": str(f.get("kind", "staircase")),
		"cell": Vector3i(int(c[0]), int(c[1]), int(c[2])),
		"role": int(f.get("role", Fixture.Role.DECORATIVE)),
		"params": (f.get("params", {}) as Dictionary),
	}


## Drop the most recently attached fixture. Undo.
func pop_fixture() -> bool:
	return remove_fixture(_fixtures.size() - 1)


## Drop one fixture, from anywhere. Fixtures are not blocks: they have no ids
## anything else keys on, so taking one out of the middle is safe.
func remove_fixture(i: int) -> bool:
	if i < 0 or i >= _fixtures.size():
		return false
	_fixtures.remove_at(i)
	return true


## Drop the most recently added block. Undo.
func pop() -> bool:
	if _parts.is_empty():
		return false
	return remove_at(_parts.size() - 1)


## Take one block out, from anywhere. Every block after it moves down one id.
##
## Authoring-time only. A recipe that has been built into the city has damage
## records keyed on its block ids, and renumbering under those would silently
## point them at the wrong bricks -- so nothing on the city side calls this. In
## the workshop nothing is keyed on the ids yet, and the renumbering IS the
## point: recipe index == block id has to stay true for the next build.
func remove_at(id: int) -> bool:
	if id < 0 or id >= _parts.size():
		return false
	_cells.remove_at(id * 3 + 2)
	_cells.remove_at(id * 3 + 1)
	_cells.remove_at(id * 3)
	_parts.remove_at(id)
	_colours.remove_at(id)
	_frames.remove_at(id)
	_decor.remove_at(id)
	# A weld to a block that no longer exists is not a weld, and every weld to
	# a block after it follows that block down.
	var kept := PackedInt32Array()
	for i in weld_count():
		var w := weld_blocks(i)
		if w.x == id or w.y == id:
			continue
		kept.push_back(w.x - 1 if w.x > id else w.x)
		kept.push_back(w.y - 1 if w.y > id else w.y)
	_welds = kept
	return true


func cell_of(id: int) -> Vector3i:
	return Vector3i(_cells[id * 3], _cells[id * 3 + 1], _cells[id * 3 + 2])


func part_of(id: int) -> String:
	return parts[_parts[id]]


func colour_of(id: int) -> int:
	return _colours[id]


## Grid AABB of everything placed, as (min corner, size in cells). Size is zero
## for an empty recipe.
func bounds() -> Array:
	if is_empty():
		return [Vector3i.ZERO, Vector3i.ZERO]
	var lo := Vector3i(1 << 30, 1 << 30, 1 << 30)
	var hi := Vector3i(-(1 << 30), -(1 << 30), -(1 << 30))
	for i in size():
		# Frame 0 only: another frame has its own grid at its own rotation, so
		# its cells are not in these coordinates and averaging them in would
		# produce a box that describes nothing.
		if frame_of(i) != 0:
			continue
		var c := cell_of(i)
		var s := BrickPalette.size_of(part_of(i))
		lo = Vector3i(mini(lo.x, c.x), mini(lo.y, c.y), mini(lo.z, c.z))
		hi = Vector3i(maxi(hi.x, c.x + s.x), maxi(hi.y, c.y + s.y), maxi(hi.z, c.z + s.z))
	return [lo, hi - lo]


## Chunk dimensions this recipe needs, with its min corner at the chunk origin.
##
## Fixtures count. They are built into this chunk with the bricks (Fixture), so
## a staircase taller than the walls around it still has to fit -- otherwise the
## flight is silently cut off at the roof line.
func chunk_dims() -> Vector3i:
	var b := bounds()
	var lo: Vector3i = b[0]
	var d: Vector3i = b[1]
	for i in fixture_count():
		var f := fixture_at(i)
		var fb: Array = _fixture_bounds(f)
		var flo: Vector3i = (fb[0] as Vector3i) - lo
		var fhi: Vector3i = flo + (fb[1] as Vector3i)
		d = Vector3i(maxi(d.x, fhi.x), maxi(d.y, fhi.y), maxi(d.z, fhi.z))
	return Vector3i(maxi(d.x, 1), maxi(d.y, 1), maxi(d.z, 1))


## Cells a fixture occupies, as (min corner, size). Kept here rather than asked
## of `Fixture` so that a recipe can be measured without building one.
func _fixture_bounds(f: Dictionary) -> Array:
	match str(f.get("kind", "")):
		"staircase":
			var steps := int((f.params as Dictionary).get("steps", 8))
			return [f.cell, StaircaseRecipe.chunk_dims(steps)]
		_:
			return [f.cell, Vector3i.ONE]


## Where the recipe's own origin sits relative to the chunk. Blocks are stored
## in the author's coordinates, which may start anywhere; the chunk starts at
## its own zero, so building subtracts this.
func origin() -> Vector3i:
	return bounds()[0]


## Build the bricks into a chunk, in order. Returns how many were placed.
##
## A block that does not fit is SKIPPED rather than aborting the build, and the
## count coming back short is the caller's signal that the recipe and the
## palette disagree. Skipping still advances the id, because the ids are the
## contract -- bailing out or shifting them would be worse than a hole.
##
## `rebase` moves the recipe's min corner to the chunk origin, which is what a
## city placement wants: a tight chunk around exactly these bricks. A WORKSHOP
## wants the opposite -- its chunk is a fixed baseplate and the recipe is already
## in its coordinates, so rebasing drops the whole build a course and every
## brick collides with the baseplate. That was a real bug and it looked like a
## load failure rather than an offset.
func build(world: BrickWorld, chunk_id: int, palette: Dictionary,
		rebase: bool = true) -> int:
	if not is_single_frame():
		push_warning("BuildRecipe '%s' has %d frames; build() places frame 0 only. Use build_into()."
				% [name, frame_count()])
	var lo := origin() if rebase else Vector3i.ZERO
	var placed := 0
	var built := {}
	for i in size():
		if frame_of(i) != 0:
			continue
		var pn := part_of(i)
		if not palette.has(pn):
			push_error("BuildRecipe '%s': no part named '%s' in the palette" % [name, pn])
			continue
		var got := world.place_block(chunk_id, cell_of(i) - lo, palette[pn], colour_of(i))
		if got >= 0:
			placed += 1
			built[i] = got
	apply_roles(world, built, func(_f: int) -> int: return chunk_id)
	return placed


## Tell the world which of the blocks just built are interior.
##
## `built` maps recipe block id -> the id it got in its chunk, which is what
## build_into already keeps: the two are not the same number, because a chunk
## holds one frame's blocks and a part the palette could not place leaves a
## hole. Grouped per chunk so this is one call per frame rather than one per
## brick.
func apply_roles(world: BrickWorld, built: Dictionary, chunk_of_frame: Callable) -> int:
	var by_chunk := {}
	for i in built:
		if not is_interior(int(i)):
			continue
		var chunk: int = chunk_of_frame.call(frame_of(int(i)))
		if chunk < 0:
			continue
		# Read out, append, put back. A Packed*Array is a VALUE, so indexing
		# the dictionary hands over a COPY -- pushing onto it in place
		# compiles, runs, and marks nothing at all.
		var ids: PackedInt32Array = by_chunk.get(chunk, PackedInt32Array())
		ids.push_back(int(built[i]))
		by_chunk[chunk] = ids
	var marked := 0
	for chunk in by_chunk:
		marked += world.set_blocks_decorative(chunk, by_chunk[chunk], true)
	return marked


## Cells this frame needs, measured in ITS OWN grid with its origin at zero.
##
## Frame 0 of a city placement is rebased to its own min corner, but a frame
## beyond 0 cannot be: its offset from the root is stored in ticks, and moving
## its grid origin moves every brick in it away from the welds that hold it.
## So a rotated frame gets a chunk that starts at zero and is as big as its
## furthest brick, which is exactly what `add_frame` wants.
func frame_dims(frame: int) -> Vector3i:
	var hi := Vector3i.ZERO
	for i in size():
		if frame_of(i) != frame:
			continue
		var c := cell_of(i)
		var sz := BrickPalette.size_of(part_of(i))
		hi = Vector3i(maxi(hi.x, c.x + sz.x), maxi(hi.y, c.y + sz.y), maxi(hi.z, c.z + sz.z))
	return Vector3i(maxi(hi.x, 1), maxi(hi.y, 1), maxi(hi.z, 1))


## Build every frame into an Assembly, which is what a multi-frame recipe needs.
##
## Returns how many bricks were placed. Frames are created in recipe order, so
## a frame index in the recipe is the same index in the assembly.
##
## `dims` of zero means "one chunk per frame, sized to that frame" -- what a
## city placement wants. A caller with grids already standing over a fixed
## volume, which is what the workshop has, passes that volume instead.
func build_into(asm: Assembly, palette: Dictionary, dims: Vector3i = Vector3i.ZERO) -> int:
	var fixed := dims != Vector3i.ZERO
	if asm.frames.is_empty():
		asm.add_frame(dims if fixed else frame_dims(0), 0, Vector3i.ZERO)
	for f in range(1, frame_count()):
		asm.add_frame(dims if fixed else frame_dims(f), frame_rotation(f), frame_ticks(f))
	var placed := 0
	# Recipe block id -> the block id it got in its frame's chunk. They are NOT
	# the same number: a chunk only holds the blocks of one frame, and a block
	# the palette could not place leaves a hole. The welds are expressed in
	# recipe ids, so this is what turns them into chunk ids.
	var built := {}
	for i in size():
		var pn := part_of(i)
		if not palette.has(pn):
			push_error("BuildRecipe '%s': no part named '%s'" % [name, pn])
			continue
		var f: int = frame_of(i)
		if f >= asm.frames.size():
			continue
		# Straight to place_block, not Assembly.place: the recipe already knows
		# these bricks did not collide when they were authored, and re-running
		# the cross-frame test per brick would make loading quadratic.
		var got: int = asm.world.place_block(asm.frames[f], cell_of(i), palette[pn], colour_of(i))
		if got >= 0:
			placed += 1
			built[i] = got
	for i in weld_count():
		var w := weld_blocks(i)
		if not (built.has(w.x) and built.has(w.y)):
			# One end did not make it into the world, so there is nothing to
			# weld. Silent: the failed placement above has already said so.
			continue
		asm.weld(asm.frames[frame_of(w.x)], built[w.x], asm.frames[frame_of(w.y)], built[w.y])
	apply_roles(asm.world, built, func(f: int) -> int:
			return asm.frames[f] if f < asm.frames.size() else -1)
	return placed


# ---------------------------------------------------------------------------
# Serialisation. One format, and it is the save file, the thing a city places,
# and what the exporter will walk (mvs-c: one serializer, three consumers).
# ---------------------------------------------------------------------------

## ONE format, and it is JSON-safe by construction: plain Arrays of plain
## numbers, never a Packed*Array.
##
## That is not tidiness. `JSON.stringify` serialises a `PackedByteArray` as the
## STRING "[4, 7]" rather than as an array, so a recipe saved with packed types
## in it wrote fine, parsed fine, and loaded as zero bricks. Emitting plain
## arrays here means the in-memory dictionary and the file are the same thing,
## so whatever round-trips through one round-trips through the other.
func to_dict() -> Dictionary:
	return {
		"version": VERSION,
		"name": name,
		"parts": _plain(parts),
		"cells": _plain(_cells),
		"part_index": _plain(_parts),
		"colours": _plain(_colours),
		"block_frames": _plain(_frames),
		"interior": _plain(_decor),
		"frame_rot": _plain(_frame_rot),
		"frame_ticks": _plain(_frame_ticks),
		"welds": _plain(_welds),
		"fixtures": _fixtures.duplicate(true),
	}


static func from_dict(d: Dictionary) -> BuildRecipe:
	var r := BuildRecipe.new()
	var v := int(d.get("version", -1))
	if v < OLDEST_VERSION or v > VERSION:
		push_warning("BuildRecipe: version %s against %d; refusing it rather than misreading it"
				% [d.get("version", "?"), VERSION])
		return r
	r.name = str(d.get("name", "untitled"))
	r.parts = _strings(d.get("parts", []))
	r._cells = _ints(d.get("cells", []))
	r._parts = _ints(d.get("part_index", []))
	r._colours = _bytes(d.get("colours", []))
	r._frames = _ints(d.get("block_frames", []))
	# A file written before the workshop had two layers has no role column, and
	# it means what it always meant: all of it is structure.
	r._decor = _bytes(d.get("interior", []))
	r._frame_rot = _ints(d.get("frame_rot", []))
	r._frame_ticks = _ints(d.get("frame_ticks", []))
	# A v1 file has no weld column at all. Missing is not the same as empty
	# here, but it loads the same way: nothing held the frames on then either.
	r._welds = _ints(d.get("welds", []))
	# JSON has no integer type, so every number in a fixture record comes back
	# as a float. Rebuilt entry by entry, like every other array here.
	for raw in (d.get("fixtures", []) as Array):
		if typeof(raw) != TYPE_DICTIONARY:
			continue
		var f: Dictionary = raw
		var c: Array = f.get("cell", [0, 0, 0])
		if c.size() != 3:
			continue
		var params := {}
		for k in (f.get("params", {}) as Dictionary):
			var raw_value = f["params"][k]
			params[str(k)] = int(raw_value) if typeof(raw_value) == TYPE_FLOAT else raw_value
		r._fixtures.append({
			"kind": str(f.get("kind", "staircase")),
			"cell": [int(c[0]), int(c[1]), int(c[2])],
			"role": int(f.get("role", Fixture.Role.DECORATIVE)),
			"params": params,
		})
	# A recipe written before frames existed has no per-block frame column; every
	# brick was in frame 0, so fill it in rather than rejecting the file.
	if r._frames.is_empty() and not r._parts.is_empty():
		r._frames.resize(r._parts.size())
		r._frames.fill(0)
	if r._decor.size() != r._parts.size():
		r._decor.resize(r._parts.size())
	if r._cells.size() != r._parts.size() * 3 or r._colours.size() != r._parts.size() \
			or r._frames.size() != r._parts.size() \
			or r._frame_ticks.size() != r._frame_rot.size() * 3:
		push_error("BuildRecipe '%s': arrays disagree; discarding" % r.name)
		return BuildRecipe.new()
	return r


# JSON has no integer type and no typed arrays, so every number comes back as a
# float in an untyped Array -- and Packed*Array constructors will not take that
# (the byte one does not exist at all). Every array is therefore rebuilt element
# by element, in both directions.
static func _plain(a) -> Array:
	var out := []
	for v in a:
		out.append(v)
	return out


static func _bytes(a) -> PackedByteArray:
	var out := PackedByteArray()
	for v in a:
		out.push_back(clampi(int(v), 0, 255))
	return out


static func _ints(a) -> PackedInt32Array:
	var out := PackedInt32Array()
	for v in a:
		out.push_back(int(v))
	return out


static func _strings(a) -> PackedStringArray:
	var out := PackedStringArray()
	for v in a:
		out.push_back(str(v))
	return out


func save_to(path: String) -> Error:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_string(JSON.stringify(to_dict(), "\t"))
	return OK


static func load_from(path: String) -> BuildRecipe:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("BuildRecipe: cannot open %s" % path)
		return BuildRecipe.new()
	var parsed = JSON.parse_string(f.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("BuildRecipe: %s is not a recipe" % path)
		return BuildRecipe.new()
	# from_dict already rebuilds every array element by element, so the parsed
	# dictionary needs no repair on the way in.
	return from_dict(parsed)
