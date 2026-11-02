class_name ShipBuild
extends RefCounted

## A ship to fly, generated (Docs/RoomModules.md 7.5): a hull grown from a seed
## -- long along +X, its bow (+X) narrowing, decks `PITCH` apart -- and its
## inside packed with ship rooms by RoomPack (bridge fore, engine room aft,
## reactor at the core, quarters, galley, med bay, cargo, cabins; the player's
## own modules with a zone instead when they have a bridge). Bulkheads cut it
## into sections; SpaceShip flies it, the bridge's seat its pilot's.
##
##   var made := ShipBuild.make(7)
##   made.recipe   # hull and rooms, one build
##   made.seat     # the pilot's cell: on the bridge's floor, its middle

## A room's inside height; a module is a floor plate, the room, two ceiling layers.
## The pawn is 12 plates (BODY_HEIGHT): rooms 16, doors 14, as a tower's 15.
const H := 16
const PITCH := H + 3
const DOOR := Vector2i(2, 14)
const HULL_COLOUR := "light bluish gray"
const ENGINE_COLOUR := "dark bluish gray"
## An engine housing on the roof aft: studs across, courses high, studs it
## hangs out past the stern.
const NACELLE := Vector3i(4, 3, 2)
## How far a wing's root reaches in over the roof, studs.
const WING_ROOT := 4


## {ok, why, recipe, plan, stats, seat: Vector3i, decks}.
static func make(seed: int, passes := 1) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("ship %d" % seed)
	var length := 56 + 8 * rng.randi_range(0, 5)
	var beam := 26 + 2 * rng.randi_range(0, 2)
	var decks := rng.randi_range(1, 3)
	var h := hull(length, beam, decks)
	var lib0 := library()
	var made := RoomPack.generate(lib0, {"seed": seed, "hull": h, "passes": passes, "fore": "+x",
			"section_studs": 24 + 4 * rng.randi_range(0, 2), "pitch": PITCH, "airlock": true, "doorway": DOOR.y})
	if not bool(made.ok):
		return made
	made.lib = lib0
	made.recipe.meta["engines"] = h.meta.get("engines", [])
	made.decks = int(made.stats.decks)
	made.seat = Vector3i(-1, -1, -1)
	var lib: Array = made.lib
	for pl: Dictionary in made.plan.placed:
		if String(lib[pl.m].name) != "bridge":
			continue
		var td: Dictionary = lib[pl.m].turns[pl.t]
		for sp: Dictionary in td.spaces.values():
			var lo := Vector2i(1 << 30, 1 << 30)
			var hi := -lo
			for c: Vector2i in sp.cols:
				lo = Vector2i(mini(lo.x, c.x), mini(lo.y, c.y))
				hi = Vector2i(maxi(hi.x, c.x), maxi(hi.y, c.y))
			@warning_ignore("integer_division")
			var mid := Vector2i((lo.x + hi.x) / 2, (lo.y + hi.y) / 2)
			var off: Vector3i = pl.off
			made.seat = Vector3i(mid.x + off.x, int(sp.floor_y) + off.y + 1, mid.y + off.z)
			break
	return made


## The ship rooms: the player's modules with a zone when one is a bridge, else these.
static func library() -> Array:
	var mine := RoomModules.library().filter(func(m) -> bool:
			return String(m.rules.get("zone", "any")) != "any" or String(m.name) == "bridge")
	if mine.any(func(m) -> bool: return String(m.name) == "bridge"):
		return RoomModules.library()
	return RoomModules.from_recipes(modules())


static func modules() -> Array:
	var two := [[1, 3, "auto"], [3, 3, "auto"]]
	return [
		room("bridge", 6, 6, {"zone": "fore", "min": 1, "max": 1}, two, "white"),
		room("engine room", 12, 8, {"zone": "aft", "min": 1, "max": 1}, two, "dark bluish gray"),
		room("reactor", 6, 6, {"zone": "core", "min": 1, "max": 1}, two, "yellow"),
		room("quarters", 6, 8, {"weight": 3.0}, two, "white"),
		room("galley", 8, 8, {"weight": 1.0, "max": 1}, two, "white"),
		room("med bay", 6, 8, {"weight": 1.0, "max": 1}, two, "white"),
		room("cargo", 12, 8, {"zone": "hull", "weight": 1.5}, two, "light bluish gray"),
		room("cabin", 6, 9, {"weight": 3.0}, two, "white"),
	]


## A ship room W x D inside, H high, walls a stud: a floor of plates, brick wall
## columns, a ceiling of two plate layers (each seam bridged); doors [[side,
## along, link]] (side 0 +X, 1 +Z, 2 -X, 3 -Z), the door's bottom on the row over
## the floor (as RoomShell's corridors want it).
static func room(name: String, w: int, d: int, rules: Dictionary, doors: Array, colour_name: String) -> BuildRecipe:
	var r := BuildRecipe.new()
	r.name = name
	var colour := StationKit._colour(colour_name)
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
			for y in range(1, DOOR.y + 1):
				hole[wall_cell.call(dr[0], int(dr[1]) + a, y)] = true
		link_at[wall_cell.call(dr[0], int(dr[1]), 1)] = String(dr[2])
	StationKit._tiles(r, Vector3i.ZERO, Vector2i(w + 2, d + 2), colour)
	StationKit.slab(r, Vector3i(0, H + 1, 0), Vector2i(w + 2, d + 2), colour)
	for x in w + 2:
		for z in d + 2:
			if x == 0 or z == 0 or x == w + 1 or z == d + 1:
				StationKit._column(r, Vector3i(x, 1, z), H, hole, colour)
	var rec := StructureSpaces.empty()
	@warning_ignore("integer_division")
	rec.spaces = [{"id": 0, "kind": name, "frame": 0, "seed": [w / 2, 1, d / 2]}]
	r.meta["structure"] = rec
	r.meta["module"] = rules.merged({"on": true, "role": "room"})
	rec = RoomModules.refresh(r)
	for o in rec.openings:
		for c in o.cells:
			var v := Vector3i(int(c[0]), int(c[1]), int(c[2]))
			if link_at.has(v):
				o.link = link_at[v]
	r.meta["structure"] = rec
	return r


## A hull `length` along +X, `beam` across, `decks` high: its half-beam falling
## over the fore quarter to a third of it at the bow; a floor of plates (row 1:
## row 0 is the ground's when a build is laid), brick side walls, a roof of two
## plate layers over the top deck; on the roof aft two engine housings and a
## fin (`meta.engines`: each housing's back, its middle, for its glow), and
## swept wings on its sides.
static func hull(length: int, beam: int, decks: int) -> BuildRecipe:
	var r := BuildRecipe.new()
	r.name = "hull"
	var colour := StationKit._colour(HULL_COLOUR)
	@warning_ignore("integer_division")
	var half := beam / 2
	var top := 1 + decks * PITCH
	var inside := {}
	for x in length:
		var hw := half
		var fore := length * 3 / 4
		if x > fore:
			hw = half - int(round((half - half / 3.0) * float(x - fore) / float(length - fore)))
		for z in range(half - hw, half + hw + 1):
			inside[Vector2i(x, z)] = true
	# The floor and the roof's two layers over the whole outline.
	_layer(r, inside, 1, Vector2i.ZERO, colour)
	_layer(r, inside, top, Vector2i.ZERO, colour)
	_layer(r, inside, top + 1, Vector2i.ONE, colour)
	# Walls: the outline's edge, brick columns from the floor to the roof.
	for c: Vector2i in inside:
		var edge := false
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			if not inside.has(c + d):
				edge = true
		if edge:
			StationKit._column(r, Vector3i(c.x, 2, c.y), top - 2, {}, colour)
	_engines(r, length, half, top + 2)
	_wings(r, length, half, top + 2)
	return r


## Swept wings on the roof's sides over its middle and aft: two plate layers a
## stud apart (each seam of one bridged by the other), their roots WING_ROOT studs
## in over the roof so they hold by its studs, `span` out at the trailing edge,
## a third of that at the leading.
static func _wings(r: BuildRecipe, length: int, half: int, y0: int) -> void:
	var dark := StationKit._colour(ENGINE_COLOUR)
	# On the 2-stud grid, so the lower layer is 2x2s throughout and every 1x1 at
	# the upper layer's edge sits on one (two 1x1s on each other hold nothing).
	@warning_ignore("integer_division")
	var x0 := length / 5 / 2 * 2
	@warning_ignore("integer_division")
	var x1 := length * 11 / 20 / 2 * 2
	@warning_ignore("integer_division")
	var span := clampi(half / 2, 6, 10) / 2 * 2
	var cells := {}
	for x in range(x0, x1):
		var xp := x - (x - x0) % 2
		var out := span - int(round((span - span / 3.0) * float(xp - x0) / float(maxi(x1 - x0 - 2, 1))))
		out = maxi(out / 2 * 2, 2)
		for z in range(-out, WING_ROOT):
			cells[Vector2i(x, z)] = true
			cells[Vector2i(x, 2 * half - 1 - z)] = true
	_layer(r, cells, y0, Vector2i.ZERO, dark)
	_layer(r, cells, y0 + 1, Vector2i.ONE, dark)


## Two engine housings on the roof aft, a quarter of its length, hanging out past
## the stern: 2x2 bricks in a running bond (each course a stud on, so every brick
## holds two below it), 1x1s where a course's ends fall short; a fin between them
## on the middle line, stepping down forward.
static func _engines(r: BuildRecipe, length: int, half: int, y0: int) -> void:
	var dark := StationKit._colour(ENGINE_COLOUR)
	var colour := StationKit._colour(HULL_COLOUR)
	var x_lo := -NACELLE.z
	@warning_ignore("integer_division")
	var x_hi := maxi(length / 4, 8) / 2 * 2 - 1
	@warning_ignore("integer_division")
	var off := maxi(4, half / 2) / 2 * 2
	var engines := []
	for side in [-1, 1]:
		var z0: int = half + side * off - NACELLE.x / 2
		for course in NACELLE.y:
			var y := y0 + course * 3
			var x := x_lo + course % 2
			if x > x_lo:
				for z in NACELLE.x:
					r.add("brick_1x1", Vector3i(x_lo, y, z0 + z), dark)
			while x + 1 <= x_hi:
				for z in range(0, NACELLE.x, 2):
					r.add("brick_2x2", Vector3i(x, y, z0 + z), dark)
				x += 2
			if x == x_hi:
				for z in NACELLE.x:
					r.add("brick_1x1", Vector3i(x_hi, y, z0 + z), dark)
		engines.append([x_lo, y0 + NACELLE.y * 3 / 2.0, z0 + NACELLE.x / 2.0])
	r.meta["engines"] = engines
	# The fin: 1x1 columns, a course more than the housings at the stern.
	@warning_ignore("integer_division")
	var fin := maxi(length / 5, 6)
	for x in fin:
		var h := 1 + (NACELLE.y + 1) * (fin - x) / fin
		for course in h:
			r.add("brick_1x1", Vector3i(x, y0 + course * 3, half), colour)


## One plate layer over `cells` at row y: 2x2 plates on the grid from `shift`
## where all four cells are in, 1x1s for the rest.
static func _layer(r: BuildRecipe, cells: Dictionary, y: int, shift: Vector2i, colour: int) -> void:
	var done := {}
	var keys := cells.keys()
	keys.sort()
	for c: Vector2i in keys:
		if done.has(c):
			continue
		var on_grid := posmod(c.x - shift.x, 2) == 0 and posmod(c.y - shift.y, 2) == 0
		var quad := [c, c + Vector2i(1, 0), c + Vector2i(0, 1), c + Vector2i(1, 1)]
		if on_grid and quad.all(func(q) -> bool: return cells.has(q) and not done.has(q)):
			r.add("plate_2x2", Vector3i(c.x, y, c.y), colour)
			for q in quad:
				done[q] = true
			continue
		r.add("plate_1x1", Vector3i(c.x, y, c.y), colour)
		done[c] = true
