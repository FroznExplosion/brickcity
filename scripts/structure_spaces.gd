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

const _DIRS := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
enum { _INSIDE, _WALL, _OUTSIDE }


## The room whose floor is under `seed` -- an air cell just above the floor
## clicked. `cell_kind(cell: Vector3i) -> int` answers Cell for any cell; `lo`
## and `hi` bound the grid (hi exclusive). Returns
##   {ok, why, floor_y, ceil_y, columns: Array[Vector2i], openings: Array}
## with each opening {kind, cells: Array[Vector3i]}. Docs/Structures.md 3.2.
static func find_space(start: Vector3i, cell_kind: Callable, lo: Vector3i, hi: Vector3i) -> Dictionary:
	var out := {"ok": false, "why": "", "floor_y": 0, "ceil_y": 0, "columns": [], "openings": []}
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
	if ceil_y >= hi.y or ceil_y - start.y > MAX_REACH:
		out.why = "no ceiling over it"
		return out
	out.floor_y = floor_y
	out.ceil_y = ceil_y

	# 2. The footprint: inside columns, four ways from the seed's.
	var what := {}   # Vector2i -> _INSIDE / _WALL / _OUTSIDE, as asked
	var col := func(c: Vector2i) -> int:
		if what.has(c):
			return int(what[c])
		var k := _column(c, floor_y, ceil_y, cell_kind, lo, hi)
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
	out.columns = columns

	# 3. The openings: in each wall column beside the room, the cells between
	# floor and ceiling that are a hole through it, glass or a door; an
	# outside column is open from floor to ceiling.
	var kind_of := {}   # Vector3i -> opening kind
	for n: Vector2i in edge:
		var k := int(what[n])
		for y in range(floor_y + 1, ceil_y):
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
## between. Outside: air between, and no floor or no ceiling.
static func _column(c: Vector2i, floor_y: int, ceil_y: int, cell_kind: Callable,
		lo: Vector3i, hi: Vector3i) -> int:
	if c.x < lo.x or c.y < lo.z or c.x >= hi.x or c.y >= hi.z:
		return _OUTSIDE
	for y in range(floor_y + 1, ceil_y):
		if int(cell_kind.call(Vector3i(c.x, y, c.y))) != Cell.AIR:
			return _WALL
	if int(cell_kind.call(Vector3i(c.x, floor_y, c.y))) == Cell.AIR \
			or int(cell_kind.call(Vector3i(c.x, ceil_y, c.y))) == Cell.AIR:
		return _OUTSIDE
	return _INSIDE


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


# ---------------------------------------------------------------------------
# The generator's: a generated building's record, from its bricks.

## The record of a generated building whose bricks are in `chunk`: every room
## RoomManifest.rooms_for gives it found by the same finder the workshop's tool
## uses, from the free cell nearest the room's middle, as a space of the
## room's own kind. One description of a room for a build and for the city
## (Docs/Structures.md 3.1). About a millisecond a room: asked for one building
## when it is wanted, not for a city at load.
static func for_tower(world: BrickWorld, chunk: int, footprint_x: int, footprint_z: int,
		courses: int, building_seed: int, program: Dictionary = {}) -> Dictionary:
	var rec := empty()
	if chunk < 0 or not world.is_chunk_alive(chunk):
		return rec
	var origin := world.get_chunk_origin(chunk)
	var lo := origin
	var hi := origin + world.get_chunk_dims(chunk)
	var kind := func(c: Vector3i) -> int:
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

static func empty() -> Dictionary:
	return {"spaces": [], "openings": [], "points": []}


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
