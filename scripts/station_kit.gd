class_name StationKit
extends RefCounted

## The station modules the game ships (Docs/RoomModules.md 7.2-7.3): rooms with
## a station's roles, built the way a station in space has to be -- every brick
## held by studs to the next, since nothing stands on the ground there. A floor
## and a ceiling are two layers of plates, the upper laid a stud over the lower
## so every seam of one is bridged by the other; walls are columns of bricks on
## the floor's edge under the ceiling's. A player's own station modules (the
## rooms tool, a station role) are used instead when the library has a core.
##
## Inside a box module: floor rows 0 and 1, room rows 2 to 17 (a door 2 x 14
## from row 2), ceiling rows 18 and 19 -- the pawn is 12 plates, it stands and
## walks through.

const H := 16
const DOOR := Vector2i(2, 14)
const FLOOR := 2
## White hull, a grey for nodes, a colour band on pods.
const COLOURS := {"core": "white", "node": "light bluish gray", "tube": "white", "pod": "white",
		"truss": "dark bluish gray", "dock": "light bluish gray"}


## The station library: the player's station modules when they have a core,
## else these.
static func library() -> Array:
	var mine := RoomModules.library().filter(func(m) -> bool:
			return ["core", "node", "pod", "tube", "truss", "dock"].has(String(m.rules.role)))
	if mine.any(func(m) -> bool: return String(m.rules.role) == "core"):
		return mine
	return RoomModules.from_recipes(modules())


static func modules() -> Array:
	var all4 := func(along: int) -> Array:
		return [[0, along, "auto"], [1, along, "auto"], [2, along, "auto"], [3, along, "auto"]]
	return [
		box("core", 10, 10, {"role": "core", "min": 1, "max": 1}, all4.call(4)),
		box("node", 6, 6, {"role": "node", "weight": 2.0}, all4.call(2)),
		box("tube", 12, 4, {"role": "tube", "weight": 2.0}, [[0, 1, "auto"], [2, 1, "auto"]]),
		box("short tube", 4, 4, {"role": "tube"}, [[0, 1, "auto"], [2, 1, "auto"]]),
		box("pod", 14, 6, {"role": "pod", "weight": 2.0}, [[2, 2, "auto"]], [[3, 6, 5, 2, 4]],
				[["radiator", [7, 6, 7], 1]]),
		box("truss", 10, 2, {"role": "truss"}, [[2, 1, "auto"]], [], [["panel", [11, 6, 1], 0]]),
		box("dock", 6, 6, {"role": "dock"}, [[2, 2, "auto"], [0, 2, "finish"]]),
	]


## A box room W x D inside, its walls a stud: doors [[side, along, link]] (side 0
## +X, 1 +Z, 2 -X, 3 -Z; along from 1), windows [[side, along, y0, w, h]], marks
## [[kind, [x, y, z], facing]] -- as tools/room_module_kit.gd's, built to hold.
static func box(name: String, w: int, d: int, rules: Dictionary, doors: Array, windows := [],
		marks := []) -> BuildRecipe:
	var r := BuildRecipe.new()
	r.name = name
	var colour := _colour(String(COLOURS.get(String(rules.get("role", "room")), "white")))
	var hole := {}
	var link_at := {}
	var wall_cell := func(side: int, along: int, y: int) -> Vector3i:
		match side:
			0: return Vector3i(w + 1, y, along)
			1: return Vector3i(along, y, d + 1)
			2: return Vector3i(0, y, along)
		return Vector3i(along, y, 0)
	for dr in doors:
		for a in DOOR.x:
			for y in range(FLOOR, FLOOR + DOOR.y):
				hole[wall_cell.call(dr[0], int(dr[1]) + a, y)] = true
		link_at[wall_cell.call(dr[0], int(dr[1]), FLOOR)] = String(dr[2])
	for wn in windows:
		for a in int(wn[3]):
			for y in range(int(wn[2]), int(wn[2]) + int(wn[4])):
				hole[wall_cell.call(wn[0], int(wn[1]) + a, y)] = true
	slab(r, Vector3i(0, 0, 0), Vector2i(w + 2, d + 2), colour)
	slab(r, Vector3i(0, FLOOR + H, 0), Vector2i(w + 2, d + 2), colour)
	for x in w + 2:
		for z in d + 2:
			if x == 0 or z == 0 or x == w + 1 or z == d + 1:
				_column(r, Vector3i(x, FLOOR, z), H, hole, colour)
	var rec := StructureSpaces.empty()
	@warning_ignore("integer_division")
	rec.spaces = [{"id": 0, "kind": "office", "frame": 0, "seed": [w / 2, FLOOR, d / 2]}]
	r.meta["structure"] = rec
	r.meta["module"] = rules.merged({"on": true})
	rec = RoomModules.refresh(r)
	for o in rec.openings:
		for c in o.cells:
			var v := Vector3i(int(c[0]), int(c[1]), int(c[2]))
			if link_at.has(v):
				o.link = link_at[v]
	for mk in marks:
		rec.marks.append({"kind": mk[0], "space": 0, "at": mk[1], "facing": mk[2]})
	r.meta["structure"] = rec
	return r


## A floor or a ceiling `size` studs at `lo`: plate_2x2s from the corner, then a
## second layer over them a stud in (its rim plate_1x1s), every seam bridged.
static func slab(r: BuildRecipe, lo: Vector3i, size: Vector2i, colour: int, material := 0) -> void:
	_tiles(r, lo, size, colour, material)
	_tiles(r, lo + Vector3i(1, 1, 1), size - Vector2i(2, 2), colour, material)
	for x in size.x:
		for z in size.y:
			if x == 0 or z == 0 or x == size.x - 1 or z == size.y - 1:
				r.add("plate_1x1", lo + Vector3i(x, 1, z), colour, 0, BuildRecipe.Role.STRUCTURE, material)


## A rectangle in one layer: 2x2 plates, 1x1s where one no longer fits.
static func _tiles(r: BuildRecipe, lo: Vector3i, size: Vector2i, colour: int, material := 0) -> void:
	for z in range(0, size.y, 2):
		for x in range(0, size.x, 2):
			if x + 1 < size.x and z + 1 < size.y:
				r.add("plate_2x2", lo + Vector3i(x, 0, z), colour, 0, BuildRecipe.Role.STRUCTURE, material)
				continue
			for dz in mini(2, size.y - z):
				for dx in mini(2, size.x - x):
					r.add("plate_1x1", lo + Vector3i(x + dx, 0, z + dz), colour, 0, BuildRecipe.Role.STRUCTURE, material)


## A wall column `h` plates up from `at`: bricks where all three plates are
## wall, plates where a hole's edge cuts one.
static func _column(r: BuildRecipe, at: Vector3i, h: int, hole: Dictionary, colour: int) -> void:
	var y := 0
	while y < h:
		var c := at + Vector3i(0, y, 0)
		if hole.has(c):
			y += 1
			continue
		var brick := y + 3 <= h and not hole.has(c + Vector3i(0, 1, 0)) and not hole.has(c + Vector3i(0, 2, 0))
		r.add("brick_1x1" if brick else "plate_1x1", c, colour)
		y += 3 if brick else 1


static func _colour(want: String) -> int:
	for i in BrickWorld.get_material_colour_count(0):
		if BrickWorld.get_material_colour_name(0, i).to_lower() == want:
			return i
	for i in BrickWorld.get_material_colour_count(0):
		if BrickWorld.get_material_colour_name(0, i).to_lower().contains(want.split(" ")[-1]):
			return i
	return 0
