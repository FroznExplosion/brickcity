class_name StructureSpaces
extends RefCounted

## What a structure says about itself beyond its bricks: its SPACES (rooms,
## halls, corridors, stairwells, each of a kind), their OPENINGS (doorways,
## doors, windows, glass, arches, open sides) and optional POINTS (spawn,
## loot, cover). Docs/Structures.md section 3.
##
## One record for a build and for a generated building -- `recipe.meta
## ["structure"]` in a build, TowerRecipe.structure for the generator -- and
## one finder: click the floor of a room and find_space walks the air from
## there to the walls, and says where the walls have holes in them.

## A space's kind: what the procedural fill reads (Structures.md 4.3).
## The city's room kinds (Room.KINDS) are all here, by the same names.
const KINDS := ["office", "corridor", "hall", "stairwell", "storeroom", "kitchen",
		"bathroom", "bedroom", "living", "shop", "lab", "armory", "barracks", "workshop",
		"empty", "other"]
## An opening's kind. A doorway and a window are holes; a door and glass are
## bricks in the hole; an arch is a hole the user says is one (never found);
## open is a side of the room with no wall at all.
const OPENING_KINDS := ["doorway", "door", "window", "glass", "arch", "open"]
const POINT_KINDS := ["spawn", "loot", "cover"]

## What find_space asks of a cell.
enum Cell { AIR, SOLID, GLASS, DOOR }

## How far up and down a floor and a ceiling are looked for, in plates.
const MAX_REACH := 160
## How many columns a room may have before the fill stops: a click outside,
## or a room with a whole wall missing. 240 x 160 studs.
const MAX_COLUMNS := 38400
## How thick a wall may be for a hole to count as going through it, in studs.
## A hole that ends inside the wall is a niche, not an opening.
const MAX_WALL := 4
## The widest a doorway's lintel runs, in studs. A longer run of wall that is
## air from the floor up and solid over it, with room beyond it, is a beam under
## the ceiling, and the room goes on under it (_beams).
const MAX_DOORWAY := 6

const _DIRS := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
enum { _INSIDE, _WALL, _OUTSIDE }


## The room whose floor is under `seed` -- an air cell just above the floor
## clicked. `cell_kind(cell: Vector3i) -> int` answers Cell for any cell; `lo`
## and `hi` bound the grid (hi exclusive). Returns
##   {ok, why, floor_y, ceil_y, open_top, columns: Array[Vector2i], openings: Array}
## with each opening {kind, cells: Array[Vector3i]}. Docs/Structures.md 3.2.
##
## With no ceiling over the click -- a courtyard, a wall walk, a tower open at
## the top -- the room is `open_top`: bounded by its walls alone, each wall's
## openings asked up to its own top, and `ceil_y` one over the highest of them.
## One open at a side as well is no room: a click on a yard or a roof.
static func find_space(start: Vector3i, cell_kind: Callable, lo: Vector3i, hi: Vector3i) -> Dictionary:
	var out := {"ok": false, "why": "", "floor_y": 0, "ceil_y": 0, "open_top": false,
			"columns": [], "openings": []}
	if not _in(start, lo, hi) or int(cell_kind.call(start)) != Cell.AIR:
		out.why = "not in the air of a room"
		return out
	# 1. The floor under the click and the ceiling over it.
	var floor_y := start.y - 1
	while floor_y >= lo.y and start.y - floor_y <= MAX_REACH \
			and int(cell_kind.call(Vector3i(start.x, floor_y, start.z))) == Cell.AIR:
		floor_y -= 1
	var ceil_y := start.y + 1
	while ceil_y < hi.y and ceil_y - start.y <= MAX_REACH \
			and int(cell_kind.call(Vector3i(start.x, ceil_y, start.z))) == Cell.AIR:
		ceil_y += 1
	if floor_y < lo.y or start.y - floor_y > MAX_REACH:
		out.why = "no floor under it"
		return out
	var open_top := ceil_y >= hi.y or ceil_y - start.y > MAX_REACH
	if open_top:
		ceil_y = mini(hi.y, start.y + MAX_REACH + 1)
	out.floor_y = floor_y
	out.ceil_y = ceil_y
	out.open_top = open_top

	# 2. The footprint: inside columns, four ways from the seed's.
	var what := {}   # Vector2i -> _INSIDE / _WALL / _OUTSIDE, as asked
	var col := func(c: Vector2i) -> int:
		if what.has(c):
			return int(what[c])
		var k := _column(c, floor_y, ceil_y, cell_kind, lo, hi, open_top)
		what[c] = k
		return k
	var first := Vector2i(start.x, start.z)
	if int(col.call(first)) != _INSIDE:
		out.why = "not in the air of a room"
		return out
	var columns: Array[Vector2i] = [first]
	var seen := {first: true}
	var edge := {}   # boundary column -> [the room columns beside it, as directions]
	var head := 0
	while true:
		while head < columns.size():
			var c: Vector2i = columns[head]
			head += 1
			for d: Vector2i in _DIRS:
				var n: Vector2i = c + d
				if seen.has(n):
					if int(what.get(n, _INSIDE)) != _INSIDE:
						(edge[n] as Array).append(d)
					continue
				seen[n] = true
				if int(col.call(n)) == _INSIDE:
					columns.append(n)
					if columns.size() > MAX_COLUMNS:
						out.why = "too big: no walls round it (clicked outside, or a wall is missing)"
						return out
				else:
					edge[n] = [d]
		# Under a beam the room goes on: what was taken for wall is let in, and
		# the fill carries on from it.
		var beams: Array[Vector2i] = []
		if not open_top:
			beams = _beams(edge, what, col, floor_y, ceil_y, cell_kind)
		if beams.is_empty():
			break
		for c in beams:
			what[c] = _INSIDE
			edge.erase(c)
			seen[c] = true
			columns.append(c)
	out.columns = columns
	if open_top:
		var top := floor_y + 1
		for n: Vector2i in edge:
			if int(what[n]) == _OUTSIDE:
				out.why = "no ceiling over it, and open at the side"
				return out
			top = maxi(top, _top_of(n, floor_y, ceil_y, cell_kind) + 1)
		out.ceil_y = top

	# 3. The openings: in each wall column beside the room, the cells between
	# floor and ceiling that are a hole through it, glass or a door; an
	# outside column is open from floor to ceiling.
	var kind_of := {}   # Vector3i -> opening kind
	for n: Vector2i in edge:
		var k := int(what[n])
		# Open at the top, a wall's openings are in it, not in the sky over it.
		var to := _top_of(n, floor_y, ceil_y, cell_kind) + 1 if open_top else ceil_y
		for y in range(floor_y + 1, to):
			var cell := Vector3i(n.x, y, n.y)
			if k == _OUTSIDE:
				kind_of[cell] = "open"
				continue
			match int(cell_kind.call(cell)):
				Cell.GLASS:
					kind_of[cell] = "glass"
				Cell.DOOR:
					kind_of[cell] = "door"
				Cell.AIR:
					for d: Vector2i in edge[n]:
						if _through(cell, d, cell_kind, lo, hi):
							kind_of[cell] = "hole"
							break
	out.openings = _group(kind_of, floor_y)
	out.ok = true
	return out


## Inside: floor under it, ceiling over it, air between. Wall: anything solid
## between. Outside: air between, and no floor or no ceiling. `open_top`: no
## ceiling is asked for (find_space).
static func _column(c: Vector2i, floor_y: int, ceil_y: int, cell_kind: Callable,
		lo: Vector3i, hi: Vector3i, open_top := false) -> int:
	if c.x < lo.x or c.y < lo.z or c.x >= hi.x or c.y >= hi.z:
		return _OUTSIDE
	for y in range(floor_y + 1, ceil_y):
		if int(cell_kind.call(Vector3i(c.x, y, c.y))) != Cell.AIR:
			return _WALL
	if int(cell_kind.call(Vector3i(c.x, floor_y, c.y))) == Cell.AIR \
			or (not open_top and int(cell_kind.call(Vector3i(c.x, ceil_y, c.y))) == Cell.AIR):
		return _OUTSIDE
	return _INSIDE


## The highest cell of column `c` between floor and ceiling that is not air:
## the top of a wall round a room open at the top.
static func _top_of(c: Vector2i, floor_y: int, ceil_y: int, cell_kind: Callable) -> int:
	for y in range(ceil_y - 1, floor_y, -1):
		if int(cell_kind.call(Vector3i(c.x, y, c.y))) != Cell.AIR:
			return y
	return floor_y


## A header: a column with its floor, air from the floor up for half the room's
## height or more, and solid from there to the ceiling -- under a beam, or under
## a doorway's lintel. Which of the two, _beams says.
static func _header(c: Vector2i, floor_y: int, ceil_y: int, cell_kind: Callable) -> bool:
	if int(cell_kind.call(Vector3i(c.x, floor_y, c.y))) == Cell.AIR:
		return false
	var y := floor_y + 1
	while y < ceil_y and int(cell_kind.call(Vector3i(c.x, y, c.y))) == Cell.AIR:
		y += 1
	@warning_ignore("integer_division")
	var half := (ceil_y - floor_y - 1) / 2
	if y >= ceil_y or y - floor_y - 1 < half:
		return false
	while y < ceil_y:
		if int(cell_kind.call(Vector3i(c.x, y, c.y))) == Cell.AIR:
			return false
		y += 1
	return true


## The headers beside the room that are beams: each run of them joined side by
## side, longer than MAX_DOORWAY across, and with no outside beyond it. A
## shorter run is a lintel over a doorway; one with outside beyond it is an
## opening in a facade, a shop front. A run longer than a doorway between two
## rooms -- a wide arch -- makes them one, as an open plan is.
static func _beams(edge: Dictionary, what: Dictionary, col: Callable, floor_y: int, ceil_y: int,
		cell_kind: Callable) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var done := {}
	for e: Vector2i in edge:
		if done.has(e) or int(what[e]) != _WALL or not _header(e, floor_y, ceil_y, cell_kind):
			continue
		var run: Array[Vector2i] = [e]
		done[e] = true
		var outside := false
		var lo := e
		var hi := e
		var i := 0
		while i < run.size():
			var c: Vector2i = run[i]
			i += 1
			lo = Vector2i(mini(lo.x, c.x), mini(lo.y, c.y))
			hi = Vector2i(maxi(hi.x, c.x), maxi(hi.y, c.y))
			for d: Vector2i in _DIRS:
				var n: Vector2i = c + d
				if done.has(n):
					continue
				var k := int(col.call(n))
				if k == _OUTSIDE:
					outside = true
				elif k == _WALL and _header(n, floor_y, ceil_y, cell_kind):
					done[n] = true
					run.append(n)
		if not outside and maxi(hi.x - lo.x, hi.y - lo.y) + 1 > MAX_DOORWAY:
			out.append_array(run)
	return out


## Does the air at `cell` -- in a wall, beside the room -- go on through it,
## going on the way `d` points (away from the room), within MAX_WALL studs?
static func _through(cell: Vector3i, d: Vector2i, cell_kind: Callable,
		lo: Vector3i, hi: Vector3i) -> bool:
	var at := cell
	for i in MAX_WALL:
		at += Vector3i(d.x, 0, d.y)
		if not _in(at, lo, hi):
			return true
		if int(cell_kind.call(at)) != Cell.AIR:
			return false
		# Past the wall: no solid above-and-below pinching it, so out.
		if int(cell_kind.call(at + Vector3i(d.x, 0, d.y))) == Cell.AIR:
			return true
	return false


## Neighbouring cells of one kind are one opening. A hole that starts at the
## floor is a doorway, one with wall under it a window.
static func _group(kind_of: Dictionary, floor_y: int) -> Array:
	var out := []
	var done := {}
	for start: Vector3i in kind_of:
		if done.has(start):
			continue
		var k: String = kind_of[start]
		var cells: Array[Vector3i] = [start]
		done[start] = true
		var i := 0
		while i < cells.size():
			var c: Vector3i = cells[i]
			i += 1
			for d: Vector3i in [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 1, 0),
					Vector3i(0, -1, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]:
				var n: Vector3i = c + d
				if not done.has(n) and kind_of.get(n, "") == k:
					done[n] = true
					cells.append(n)
		var low := floor_y + 1000000
		for c in cells:
			low = mini(low, c.y)
		if k == "hole":
			k = "doorway" if low == floor_y + 1 else "window"
		out.append({"kind": k, "cells": cells})
	return out


static func _in(c: Vector3i, lo: Vector3i, hi: Vector3i) -> bool:
	return c.x >= lo.x and c.y >= lo.y and c.z >= lo.z and c.x < hi.x and c.y < hi.y and c.z < hi.z


## Where a cell of the upright frame (`frames[0]`) is asked of every frame's
## bricks: a wall built in a sideways frame stands in upright cells too
## (Docs/Structures.md 3.2, "a wall built sideways is not seen"). Returns
## `func(c: Vector3i) -> Vector2i`: (frame index, block id), or (-1, -1) where no
## frame has a brick. A turned frame's cells are not the upright grid's -- a
## wall one plate thick, turned, is thinner than a stud -- so an upright cell is
## asked at its middle and a third of the way to each of its faces.
static func frames_reader(world: BrickWorld, frames: Array) -> Callable:
	var f0: int = frames[0]
	var cs := BrickWorld.get_cell_size()
	var xf0 := world.get_chunk_transform(f0)
	var inv0 := xf0.affine_inverse()
	var o0 := world.get_chunk_origin(f0)
	# Each other frame: [chunk, world -> its space, its origin, its box in upright cells].
	var others := []
	for k in range(1, frames.size()):
		var fk: int = frames[k]
		var xf := world.get_chunk_transform(fk)
		var ok := world.get_chunk_origin(fk)
		var dims := world.get_chunk_dims(fk)
		var box := AABB()
		for i in 8:
			var corner := Vector3(dims.x if i & 1 else 0, dims.y if i & 2 else 0, dims.z if i & 4 else 0)
			var at: Vector3 = (inv0 * (xf * (corner * cs))) / cs + Vector3(o0)
			box = AABB(at, Vector3.ZERO) if i == 0 else box.expand(at)
		others.append([fk, xf.affine_inverse(), ok, box.grow(1.0)])
	var points: Array[Vector3] = [Vector3(0.5, 0.5, 0.5)]
	for axis in 3:
		for t in [1.0 / 6.0, 5.0 / 6.0]:
			var q := Vector3(0.5, 0.5, 0.5)
			q[axis] = t
			points.append(q)
	return func(c: Vector3i) -> Vector2i:
		if world.is_solid(f0, c):
			return Vector2i(0, world.block_at(f0, c))
		for k in others.size():
			var o: Array = others[k]
			if not (o[3] as AABB).has_point(Vector3(c) + Vector3(0.5, 0.5, 0.5)):
				continue
			for q in points:
				var at: Vector3 = (o[1] as Transform3D) * (xf0 * ((Vector3(c - o0) + q) * cs))
				var cell := Vector3i((at / cs).floor()) + (o[2] as Vector3i)
				if world.is_solid(int(o[0]), cell):
					return Vector2i(k + 1, world.block_at(int(o[0]), cell))
		return Vector2i(-1, -1)


# ---------------------------------------------------------------------------
# The generator's: a generated building's record, from its bricks.

## The record of a generated building whose bricks are in `chunk`: every room
## RoomManifest.rooms_for gives it found by the same finder the workshop's tool
## uses, from the free cell nearest the room's middle, as a space of the
## room's own kind. One description of a room for a build and for the city
## (Docs/Structures.md 3.1). About a millisecond a room: asked for one building
## when it is wanted, not for a city at load.
##
## The stairwell (`stair`, in the building's own studs; TowerRecipe.stair_rect)
## is solid to the finder, every storey of it: a room beside it is sealed by it
## as by a wall. It is a shaft through every slab, and the hole read as "no
## floor" -- an open side -- to each room it cut through (user, 2026-10-18).
static func for_tower(world: BrickWorld, chunk: int, footprint_x: int, footprint_z: int,
		courses: int, building_seed: int, program: Dictionary = {},
		stair: Rect2i = TowerRecipe.stair_rect(footprint_x, footprint_z)) -> Dictionary:
	var rec := empty()
	if chunk < 0 or not world.is_chunk_alive(chunk):
		return rec
	var origin := world.get_chunk_origin(chunk)
	var lo := origin
	var hi := origin + world.get_chunk_dims(chunk)
	var shaft := Rect2i(stair.position + Vector2i(origin.x, origin.z), stair.size)
	var kind := func(c: Vector3i) -> int:
		if shaft.has_point(Vector2i(c.x, c.z)):
			return Cell.SOLID
		if not world.is_solid(chunk, c):
			return Cell.AIR
		var id := world.block_at(chunk, c)
		if world.is_block_decorative(chunk, id):
			return Cell.AIR
		if BrickWorld.is_material_translucent(world.get_block_material(chunk, id)):
			return Cell.GLASS
		if world.get_archetype_name(world.get_block_archetype(chunk, id)).contains("door"):
			return Cell.DOOR
		return Cell.SOLID
	for room: Room in RoomManifest.rooms_for(footprint_x, footprint_z, courses, building_seed, program):
		var start := _free_cell(room, origin, kind)
		if start.x == -1000000000:
			continue
		var found := find_space(start, kind, lo, hi)
		if not found.ok:
			continue
		var space_kind: String = room.kind if KINDS.has(room.kind) else "other"
		var made := record_space(room.id, space_kind, 0, start, found)
		rec.spaces.append(made[0])
		rec.openings.append_array(made[1])
	# The frame, from the recipe (Docs/DestructionLod.md 4): its floors, its
	# columns and its stair core, made with the building, never searched for.
	var f := TowerRecipe.frame(footprint_x, footprint_z, courses,
			[] if stair.size == Vector2i.ZERO else [stair], true, world, chunk)
	rec["floors"] = f.floors
	rec["columns"] = f.columns
	rec["core"] = f.core
	return rec


## The air cell on a room's floor nearest its middle: the middle itself can be
## a column (Room.posts).
static func _free_cell(room: Room, origin: Vector3i, kind: Callable) -> Vector3i:
	var mid := Vector2(room.lo.x + room.size.x * 0.5, room.lo.z + room.size.z * 0.5)
	var best := Vector3i(-1000000000, 0, 0)
	var best_d := INF
	for x in range(room.lo.x, room.lo.x + room.size.x):
		for z in range(room.lo.z, room.lo.z + room.size.z):
			var d := Vector2(x + 0.5, z + 0.5).distance_squared_to(mid)
			if d >= best_d:
				continue
			var c := origin + Vector3i(x, room.lo.y, z)
			if int(kind.call(c)) == Cell.AIR:
				best = c
				best_d = d
	return best


# ---------------------------------------------------------------------------
# The record (Docs/Structures.md 3.1): plain arrays, so it saves as JSON.

## "floors", "columns" and "core" are the frame (TowerRecipe.frame): a
## generated building's record has them from the generator; a build's are
## empty until they are found in its bricks (Structures.md 2.4).
static func empty() -> Dictionary:
	return {"spaces": [], "openings": [], "points": [], "floors": [], "columns": [], "core": []}


# ---------------------------------------------------------------------------
# Floors found in the bricks (Docs/Structures.md 2.4).

## How far round a cell has to be structure, in studs, for the cell to be
## floor: a slab is structure all round; a wall two studs thick or a column is
## not, however long it is, nor where two walls meet.
const FLOOR_REACH := 2
## Floor cells a layer needs to be a floor: a slab of 7 x 7 studs or more.
const FLOOR_CORE := 9


## The floors of a structure, found in its bricks: wide layers of structure,
## [[y, plates], ...] bottom up -- what TowerRecipe.frame says of a generated
## building, found for a build (BuildingRegistry.floor_lines). `layer.call(y)`
## is plate layer y as size.x * size.z bytes, x fastest, 1 where there is
## structure. A layer is floor where FLOOR_CORE of its cells have structure
## FLOOR_REACH all round them; a run of such layers is one floor, at any
## height -- a mezzanine half a storey up is a floor like any other. A solid
## mass is one floor as thick as it is: its foot is still where it parts.
static func find_floors(layer: Callable, size: Vector3i) -> Array:
	var out := []
	var run_y := -1
	for y in size.y + 1:
		var is_floor := y < size.y and _floor_layer(layer.call(y), size.x, size.z)
		if is_floor and run_y < 0:
			run_y = y
		elif not is_floor and run_y >= 0:
			out.append([run_y, y - run_y])
			run_y = -1
	return out


## A build's floors (find_floors) from its recipe alone, in its own grid: its
## structure, not its interior or detail, and its upright frame only, as the
## space finder sees it.
static func floors_of_build(recipe: BuildRecipe) -> Array:
	var bounds: Array = recipe.bounds()
	var lo: Vector3i = bounds[0]
	var size: Vector3i = bounds[1]
	if size.x <= 0 or size.y <= 0 or size.z <= 0:
		return []
	var area := size.x * size.z
	var cells := PackedByteArray()   # layer by layer, x fastest
	cells.resize(area * size.y)
	for id in recipe.size():
		if recipe.role_of(id) != BuildRecipe.Role.STRUCTURE or recipe.frame_of(id) != 0:
			continue
		var c := recipe.cell_of(id) - lo
		var s := BuildRecipe.part_size(recipe.part_of(id))
		for y in range(maxi(c.y, 0), mini(c.y + s.y, size.y)):
			for z in range(maxi(c.z, 0), mini(c.z + s.z, size.z)):
				for x in range(maxi(c.x, 0), mini(c.x + s.x, size.x)):
					cells[y * area + z * size.x + x] = 1
	var found := find_floors(func(y: int) -> PackedByteArray:
			return cells.slice(y * area, (y + 1) * area), size)
	for f in found:
		f[0] = int(f[0]) + lo.y
	return found


## Has this layer FLOOR_CORE cells with structure FLOOR_REACH all round them?
## Along x first -- is the run of cells centred on each one all structure --
## then along z over those.
static func _floor_layer(mask: PackedByteArray, w: int, d: int) -> bool:
	var side := 2 * FLOOR_REACH + 1
	if w < side or d < side or mask.count(1) < FLOOR_CORE:
		return false
	var across := PackedByteArray()
	across.resize(w * d)
	for z in d:
		var row := z * w
		var n := 0
		for x in w:
			n += mask[row + x]
			if x >= side:
				n -= mask[row + x - side]
			if n == side:
				across[row + x - FLOOR_REACH] = 1
	var core := 0
	for x in range(FLOOR_REACH, w - FLOOR_REACH):
		var n := 0
		for z in d:
			n += across[z * w + x]
			if z >= side:
				n -= across[(z - side) * w + x]
			if n == side:
				core += 1
				if core >= FLOOR_CORE:
					return true
	return false


## A space found from `seed`, as the record keeps it, with its openings --
## the kinds set by hand on `old` openings kept where the same cells are
## still an opening.
static func record_space(id: int, kind: String, frame: int, start: Vector3i, found: Dictionary,
		old_openings: Array = []) -> Array:
	var space := {"id": id, "kind": kind, "frame": frame, "seed": [start.x, start.y, start.z],
			"floor_y": int(found.floor_y), "ceil_y": int(found.ceil_y), "columns": []}
	for c: Vector2i in found.columns:
		(space.columns as Array).append([c.x, c.y])
	var set_by_hand := {}
	for o: Dictionary in old_openings:
		if bool(o.get("set", false)):
			for c in o.cells:
				set_by_hand[Vector3i(int(c[0]), int(c[1]), int(c[2]))] = String(o.kind)
	var openings := []
	for o: Dictionary in found.openings:
		var rec := {"kind": o.kind, "space": id, "cells": [], "set": false}
		for c: Vector3i in o.cells:
			(rec.cells as Array).append([c.x, c.y, c.z])
			if set_by_hand.has(c) and not rec.set:
				rec.kind = set_by_hand[c]
				rec.set = true
		openings.append(rec)
	return [space, openings]


## The next kind of an opening, cycling, and marked as set by hand.
static func cycle_opening(o: Dictionary, step := 1) -> void:
	var i := OPENING_KINDS.find(String(o.kind))
	o.kind = OPENING_KINDS[posmod(i + step, OPENING_KINDS.size())]
	o.set = true


static func cycle_kind(space: Dictionary, step := 1) -> void:
	var i := KINDS.find(String(space.kind))
	space.kind = KINDS[posmod(i + step, KINDS.size())]


## Which recorded opening holds `cell`, by index, or -1.
static func opening_at(rec: Dictionary, cell: Vector3i) -> int:
	var openings: Array = rec.openings
	for i in openings.size():
		for c in (openings[i] as Dictionary).cells:
			if int(c[0]) == cell.x and int(c[1]) == cell.y and int(c[2]) == cell.z:
				return i
	return -1


## Which recorded space has `cell` in its air, by index, or -1.
static func space_at(rec: Dictionary, cell: Vector3i) -> int:
	var spaces: Array = rec.spaces
	for i in spaces.size():
		var s: Dictionary = spaces[i]
		if cell.y <= int(s.floor_y) or cell.y >= int(s.ceil_y):
			continue
		for c in s.columns:
			if int(c[0]) == cell.x and int(c[1]) == cell.z:
				return i
	return -1
