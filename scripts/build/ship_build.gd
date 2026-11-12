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
## A window in the hull's side: studs along it, plates high, its sill plates over
## the room's floor (the pawn's eyes are about 11 up), one every WINDOW_EVERY
## studs of a room's run along the side.
const WINDOW := Vector2i(2, 8)
const WINDOW_SILL := 4
const WINDOW_EVERY := 6
## How far in from a room's wall the hull may stand (its wall, a gap, the hull).
const WINDOW_REACH := 4
## The bridge's consoles (Docs/RoomModules.md 7.11): a panel along its fore wall
## CONSOLE_BACK courses high, a desk in front of it CONSOLE_DESK high topped with
## dark screens, and side stations along its side walls fore of the seat; studs
## either side of a doorway kept clear.
const CONSOLE_BACK := 2
const CONSOLE_DESK := 1
const CONSOLE_COLOUR := "dark bluish gray"
const SCREEN_COLOUR := "black"
## The bridge's inside, studs: the first that the packer fits fore (a narrow bow
## takes only the last).
const BRIDGES := [Vector2i(10, 8), Vector2i(6, 6)]


## {ok, why, recipe, plan, stats, seat: Vector3i, decks}.
static func make(seed: int, passes := 1) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("ship %d" % seed)
	var length := 56 + 8 * rng.randi_range(0, 5)
	var beam := 26 + 2 * rng.randi_range(0, 2)
	var decks := rng.randi_range(1, 3)
	var h := hull(length, beam, decks)
	var section := 24 + 4 * rng.randi_range(0, 2)
	var made := {}
	var lib0 := []
	for b: Vector2i in BRIDGES:
		lib0 = library(b)
		made = RoomPack.generate(lib0, {"seed": seed, "hull": h, "passes": passes, "fore": "+x",
				"section_studs": section, "pitch": PITCH, "airlock": true, "doorway": DOOR.y})
		if not bool(made.ok) or (made.plan.placed as Array).any(func(pl) -> bool:
				return String(lib0[pl.m].name) == "bridge"):
			break
	if not bool(made.ok):
		return made
	made.lib = lib0
	made.recipe.meta["engines"] = h.meta.get("engines", [])
	made.decks = int(made.stats.decks)
	made.seat = Vector3i(-1, -1, -1)
	var bridge := {}
	var bridge_floor := 0
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
			bridge_floor = int(sp.floor_y) + off.y
			for c: Vector2i in sp.cols:
				bridge[Vector2i(c.x + off.x, c.y + off.z)] = true
			break
	made.stats["windows"] = _windows(made.recipe, h)
	made.stats["consoles"] = _consoles(made.recipe, bridge, bridge_floor, made.seat)
	# Its gravity generator aft, in the engine room (Docs/RoomModules.md 7.12).
	made.stats["generator"] = GravityGenerator.lay(made.recipe, ["engine room", "reactor"])
	made.stats["furniture"] = KitFurnish.furnish(made.recipe, seed)
	return made


## Windows in the hull's sides (Docs/RoomModules.md 7.9): for each room against
## a side, WINDOW panes along its run there, one every WINDOW_EVERY studs; the
## hull's cells glazed (glass plates), a room's own wall and any gap between cut
## open, what a cut brick leaves kept as plates. Each new brick is in the section
## of the brick it was cut from. How many it made.
static func _windows(r: BuildRecipe, h: BuildRecipe) -> int:
	var glass := RoomGrow._glass()
	var hull := {}
	for i in h.size():
		var c := h.cell_of(i)
		var s := BuildRecipe.part_size(h.part_of(i))
		for y in s.y:
			for z in s.z:
				for x in s.x:
					hull[c + Vector3i(x, y, z)] = true
	var cells := {}
	for i in r.size():
		var c := r.cell_of(i)
		var s := BuildRecipe.part_size(r.part_of(i))
		for y in s.y:
			for z in s.z:
				for x in s.x:
					cells[c + Vector3i(x, y, z)] = i
	var in_door := {}
	for d: Dictionary in BuildDoors.of(r):
		var lo: Vector3i = d.lo
		var ds: Vector3i = d.size
		for z in range(lo.z - 1, lo.z + ds.z + 1):
			for x in range(lo.x - 1, lo.x + ds.x + 1):
				in_door[Vector2i(x, z)] = true
	var cut := {}
	var glazed := {}
	var made := 0
	for sp: Dictionary in (r.meta.get("structure", {}) as Dictionary).get("spaces", []):
		if String(sp.kind) == "storage" or (sp.get("columns", []) as Array).is_empty():
			continue
		var y0 := int(sp.floor_y) + 1 + WINDOW_SILL
		var cols := {}
		for c in sp.columns:
			cols[Vector2i(int(c[0]), int(c[1]))] = true
		for dz in [-1, 1]:
			# Each column on that side: how far out the hull is (0: not against it).
			var reach := {}
			for v: Vector2i in cols:
				if cols.has(v + Vector2i(0, dz)) or in_door.has(v + Vector2i(0, dz)):
					continue
				for k in range(1, WINDOW_REACH + 1):
					var w := Vector3i(v.x, y0, v.y + dz * k)
					if hull.has(w):
						if not cells.has(w + Vector3i(0, 0, dz)):
							reach[v.x] = [k, v.y]
						break
			var xs := reach.keys()
			xs.sort()
			var k0 := 0
			while k0 < xs.size():
				# A run: neighbouring columns with the hull as far out.
				var k1 := k0
				while k1 + 1 < xs.size() and int(xs[k1 + 1]) == int(xs[k1]) + 1 \
						and reach[xs[k1 + 1]] == reach[xs[k0]]:
					k1 += 1
				var run := k1 - k0 + 1
				var depth := int(reach[xs[k0]][0])
				var z0 := int(reach[xs[k0]][1])
				@warning_ignore("integer_division")
				var n := run / WINDOW_EVERY if run >= WINDOW_EVERY else (1 if run >= WINDOW.x + 2 else 0)
				for wi in n:
					var x0 := int(xs[k0]) + int(float(run) * (wi + 0.5) / n) - WINDOW.x / 2
					for x in range(x0, x0 + WINDOW.x):
						for y in range(y0, y0 + WINDOW.y):
							for j in range(1, depth + 1):
								var w := Vector3i(x, y, z0 + dz * j)
								cut[w] = true
								if j == depth:
									glazed[w] = true
					made += 1
				k0 = k1 + 1
	if made == 0:
		return 0
	var of := BuildSections.of_build(r)
	var gone := {}
	for w: Vector3i in cut:
		if cells.has(w):
			gone[int(cells[w])] = true
	var ids := PackedInt32Array(gone.keys())
	ids.sort()
	var adds := []
	for i in ids:
		var c := r.cell_of(i)
		var s := BuildRecipe.part_size(r.part_of(i))
		var sec := of[i] if not of.is_empty() else 0
		for y in s.y:
			for z in s.z:
				for x in s.x:
					var v := c + Vector3i(x, y, z)
					if not cut.has(v):
						adds.append(["plate_1x1", v, r.colour_of(i), r.material_of(i), sec])
					elif glazed.has(v) and glass >= 0:
						adds.append(["plate_1x1", v, r.colour_of(i), glass, sec])
	var kept := PackedInt32Array()
	if not of.is_empty():
		var k := 0
		for i in of.size():
			if k < ids.size() and ids[k] == i:
				k += 1
				continue
			kept.append(of[i])
	r.remove_many(ids)
	for a: Array in adds:
		r.add(String(a[0]), a[1], int(a[2]), 0, BuildRecipe.Role.STRUCTURE, int(a[3]))
		if not of.is_empty():
			kept.append(int(a[4]))
	if not of.is_empty() and r.meta.has("sections"):
		BuildSections.rerecord(r, kept)
	return made


## The bridge's consoles (Docs/RoomModules.md 7.11), facing the seat from fore
## (+X): along the room's fore edge a panel and a desk before it, and along its
## two side edges, fore of the seat, side desks; never in a doorway
## or beside one, nor on the seat's column. Each brick in its floor's section;
## `meta.consoles` {from, bricks}. A bridge with furniture of its own (a
## player's: interior bricks) gets none. How many columns it laid.
static func _consoles(r: BuildRecipe, cols: Dictionary, floor_y: int, seat: Vector3i) -> int:
	if cols.is_empty():
		return 0
	var cells := {}
	for i in r.size():
		var c := r.cell_of(i)
		var s := BuildRecipe.part_size(r.part_of(i))
		for y in s.y:
			for z in s.z:
				for x in s.x:
					var v := c + Vector3i(x, y, z)
					cells[v] = i
					if r.is_interior(i) and cols.has(Vector2i(v.x, v.z)) and v.y > floor_y:
						return 0
	var near_door := {}
	for d: Dictionary in BuildDoors.of(r):
		var lo: Vector3i = d.lo
		var ds: Vector3i = d.size
		for z in range(lo.z - 2, lo.z + ds.z + 2):
			for x in range(lo.x - 2, lo.x + ds.x + 2):
				near_door[Vector2i(x, z)] = true
	# Each column's place: 2 the fore edge (the panel), 1 a desk.
	var place := {}
	for v: Vector2i in cols:
		if near_door.has(v) or v == Vector2i(seat.x, seat.z):
			continue
		if not cols.has(v + Vector2i(1, 0)):
			place[v] = 2
			if cols.has(v - Vector2i(1, 0)) and not near_door.has(v - Vector2i(1, 0)):
				place[v - Vector2i(1, 0)] = maxi(int(place.get(v - Vector2i(1, 0), 0)), 1)
		elif v.x > seat.x + 1 and (not cols.has(v + Vector2i(0, 1)) or not cols.has(v - Vector2i(0, 1))):
			place[v] = maxi(int(place.get(v, 0)), 1)
	var of := BuildSections.of_build(r)
	var body := StationKit._colour(CONSOLE_COLOUR)
	var screen := StationKit._colour(SCREEN_COLOUR)
	var first := r.size()
	var laid := 0
	for v: Vector2i in place:
		var under: Vector3i = Vector3i(v.x, floor_y, v.y)
		if not cells.has(under):
			continue
		var high := (CONSOLE_BACK if int(place[v]) == 2 else CONSOLE_DESK) * 3
		var free := true
		for y in high + 1:
			free = free and not cells.has(Vector3i(v.x, floor_y + 1 + y, v.y))
		if not free:
			continue
		for k in range(0, high, 3):
			r.add("brick_1x1", Vector3i(v.x, floor_y + 1 + k, v.y), body, 0, BuildRecipe.Role.STRUCTURE)
		r.add("tile_1x1", Vector3i(v.x, floor_y + 1 + high, v.y), screen, 0, BuildRecipe.Role.STRUCTURE)
		if not of.is_empty():
			for k in range(0, high + 1, 3):
				of.append(of[int(cells[under])])
		laid += 1
	if of.size() == r.size() and r.meta.has("sections"):
		BuildSections.rerecord(r, of)
	r.meta["consoles"] = {"from": first, "bricks": r.size() - first}
	return laid


## The ship rooms: the player's modules with a zone when one is a bridge, else these.
static func library(bridge: Vector2i = BRIDGES[0]) -> Array:
	var mine := RoomModules.library().filter(func(m) -> bool:
			return String(m.rules.get("zone", "any")) != "any" or String(m.name) == "bridge")
	if mine.any(func(m) -> bool: return String(m.name) == "bridge"):
		return RoomModules.library()
	return RoomModules.from_recipes(modules(bridge))


static func modules(bridge: Vector2i = BRIDGES[0]) -> Array:
	var two := [[1, 3, "auto"], [3, 3, "auto"]]
	return [
		room("bridge", bridge.x, bridge.y, {"zone": "fore", "min": 1, "max": 1}, two, "white"),
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
