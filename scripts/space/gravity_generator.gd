class_name GravityGenerator
extends RefCounted

## A station's or ship's gravity generator (Docs/RoomModules.md 7.12): a column
## of bricks in a corner of its core (a station) or its engine room (a ship),
## away from the doors. While every one of its bricks stands it can pull (G turns
## it on and off); shot out -- any of them dead, or gone with a piece -- nothing
## pulls there, and G cannot bring it back. Its bricks are the build's own, so a
## save keeps their damage as it keeps the rest (SpaceStation.gone).
##
##   meta.generator   {"from": its first brick, "bricks": how many}

## Its footprint, studs; its height, courses (three plates each).
const SIZE := 2
const COURSES := 2
const BODY_COLOUR := "dark bluish gray"
const CORE_COLOUR := "trans light blue"
## Studs kept from a doorway.
const DOOR_KEEP := 2


## Lays it into `r` in the space of kind `kinds[0]` (or the next that has one,
## else the first space), each brick in its floor's section. How many bricks
## (0: no room for it).
static func lay(r: BuildRecipe, kinds: Array) -> int:
	var spaces: Array = (r.meta.get("structure", {}) as Dictionary).get("spaces", [])
	if spaces.is_empty():
		return 0
	var sp: Dictionary = {}
	for k in kinds:
		for s: Dictionary in spaces:
			if String(s.kind) == String(k):
				sp = s
				break
		if not sp.is_empty():
			break
	if sp.is_empty():
		sp = spaces[0]
	var cols := {}
	for c in sp.get("columns", []):
		cols[Vector2i(int(c[0]), int(c[1]))] = true
	var floor_y := int(sp.floor_y)
	var cells := {}
	for i in r.size():
		var c := r.cell_of(i)
		var s := BuildRecipe.part_size(r.part_of(i))
		for y in s.y:
			for z in s.z:
				for x in s.x:
					cells[c + Vector3i(x, y, z)] = i
	var near_door := {}
	for d: Dictionary in BuildDoors.of(r):
		var lo: Vector3i = d.lo
		var ds: Vector3i = d.size
		for z in range(lo.z - DOOR_KEEP, lo.z + ds.z + DOOR_KEEP):
			for x in range(lo.x - DOOR_KEEP, lo.x + ds.x + DOOR_KEEP):
				near_door[Vector2i(x, z)] = true
	# The best corner: its footprint in the space, on its floor, clear up to its
	# top and of the doors; against the most walls (a corner over a wall).
	var high := COURSES * 3 + 1
	var best := Vector2i(1 << 30, 0)
	var best_walls := -1
	var keys := cols.keys()
	keys.sort()
	for v: Vector2i in keys:
		var fits := true
		var walls := 0
		for dz in SIZE:
			for dx in SIZE:
				var w := v + Vector2i(dx, dz)
				if not cols.has(w) or near_door.has(w) or not cells.has(Vector3i(w.x, floor_y, w.y)):
					fits = false
					continue
				for y in high:
					fits = fits and not cells.has(Vector3i(w.x, floor_y + 1 + y, w.y))
		if not fits:
			continue
		for n: Vector2i in [Vector2i(-1, 0), Vector2i(SIZE, 0), Vector2i(0, -1), Vector2i(0, SIZE)]:
			if not cols.has(v + n):
				walls += 1
		if walls > best_walls:
			best_walls = walls
			best = v
	if best_walls < 0:
		return 0
	var of := BuildSections.of_build(r)
	var under: int = cells[Vector3i(best.x, floor_y, best.y)]
	var body := StationKit._colour(BODY_COLOUR)
	var core := StationKit._colour(CORE_COLOUR)
	var first := r.size()
	for k in COURSES:
		r.add("brick_2x2", Vector3i(best.x, floor_y + 1 + k * 3, best.y), core if k == COURSES - 1 else body, 0,
				BuildRecipe.Role.STRUCTURE)
	r.add("tile_2x2", Vector3i(best.x, floor_y + 1 + COURSES * 3, best.y), body, 0, BuildRecipe.Role.STRUCTURE)
	if not of.is_empty():
		for i in range(first, r.size()):
			of.append(of[under])
		if of.size() == r.size() and r.meta.has("sections"):
			BuildSections.rerecord(r, of)
	r.meta["generator"] = {"from": first, "bricks": r.size() - first}
	return r.size() - first


## Its bricks' ids in `r` (block ids, as laid from its template); empty for none.
static func blocks(r: BuildRecipe) -> PackedInt32Array:
	var out := PackedInt32Array()
	var g: Dictionary = r.meta.get("generator", {}) if r != null else {}
	for i in int(g.get("bricks", 0)):
		out.append(int(g.from) + i)
	return out
