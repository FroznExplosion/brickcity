class_name RoomStation
extends RoomGrow

## The station grower (Docs/RoomModules.md 7.2): the grow's rules with a
## station's roles -- grown from its core along a spine of nodes and tubes to a
## dock, branches of pods, nodes, tubes and trusses off the open ports, more
## docks at the far ends, and tubes bridging ports that face across a gap (the
## many passageways); a solar wing out from each `panel` spot, a radiator from
## each `radiator` spot. One "down" for the whole station (its deck's gravity):
## vertical ports are stair links, as a building's.
##
##   var made := RoomStation.generate(RoomModules.library(), {"seed": 4, "modules": 20})
##   made.recipe   # the station as one build, its lowest row at 1, in sections
##
## Same seed and library, same station.

## `modules`: modules in all; `spine`: modules between the core and the first
## dock; `docks`: docks in all; `bridges`: tubes put across gaps at most;
## `wings`: the chance a panel spot gets a wing (and a radiator spot its
## radiator); `section_bricks`: BuildSections' budget.
const STATION_PARAMS := {"seed": 1, "modules": 16, "spine": 4, "docks": 2, "bridges": 4, "wings": 1.0,
		"tries": 6000, "balcony": 0.0, "hang": 0.0, "doors": 1.0, "section_bricks": BuildSections.BUDGET}
## A solar wing: studs across, studs out past its boom; the boom's length.
const WING := Vector2i(8, 16)
const BOOM := 3
## A radiator: studs across, studs out.
const RADIATOR := Vector2i(4, 8)
## The longest gap a bridging tube spans, studs.
const GAP := 24
## The furthest aside a bridged port may be of the other, studs.
const SHIFT := 8

var wings := 0
var radiators := 0
var bridges := 0
var docks := 0
var _wing_colour := -1
var _radiator_colour := -1
var _boom_colour := -1
var _tubes := []        ## the bridging tubes' bricks, added to the plan's


## {ok, why, recipe, plan, stats}: as RoomShell.generate.
static func generate(library: Array, params := {}) -> Dictionary:
	var g := RoomStation.new()
	return g._station(library, params)


func _station(library: Array, params: Dictionary) -> Dictionary:
	path_roles = ["tube", "node"]
	branch_roles = ["pod", "node", "tube", "truss"]
	start_role = "core"
	finish_role = "dock"
	var pp := STATION_PARAMS.duplicate()
	pp.merge(params, true)
	pp.rooms = int(pp.modules)
	pp.path = int(pp.spine)
	_wing_colour = _colour_named(["dark blue", "blue"])
	_radiator_colour = _colour_named(["white"])
	_boom_colour = _colour_named(["light bluish gray", "light grey", "light gray", "grey", "gray"])
	if library.filter(func(m) -> bool: return String(m.rules.role) == "core").is_empty():
		return {"ok": false, "why": "no core module: a station grows from a module whose role is core"}
	var plan := _grow(library, pp)
	if not bool(plan.ok):
		return {"ok": false, "why": String(plan.why)}
	docks = (1 if exit >= 0 else 0) + keep.size()
	(plan.adds as Array).append_array(_tubes)
	plan.stats.merge({"docks": docks, "bridges": bridges, "wings": wings, "radiators": radiators}, true)
	plan.generator = "station"
	plan.at = _at(plan)
	var r := RoomGrow.lay(lib, plan, true)
	r.name = "station %d" % int(pp.seed)
	r.meta["generated"] = {"generator": "station", "seed": int(pp.seed), "stats": plan.stats,
			"modules": plan.placed.map(func(pl) -> String: return String(lib[pl.m].name))}
	return {"ok": true, "why": "", "recipe": r, "plan": plan, "stats": plan.stats}


## After the branches: docks at the far ends, then tubes across the gaps.
func _more() -> void:
	_docks()
	_bridges()


## More docks till there are `docks`, on the open ports furthest from the core.
func _docks() -> void:
	var want := int(p.docks) - (1 if exit >= 0 else 0)
	var ports := _all_open().filter(func(i) -> bool: return String(open[i].kind) == "door")
	ports.sort_custom(func(a, b) -> bool:
			return Vector3(open[a].at).length_squared() > Vector3(open[b].at).length_squared())
	for oi: int in ports:
		if keep.size() >= want or budget <= 0:
			return
		if bool(open[oi].used):
			continue
		for cand in _shuffled(_candidates(oi, ["finish"])):
			var idx := _attach(oi, cand)
			if idx >= 0:
				var k := _reserved_of(idx, "finish")
				if k >= 0:
					keep.append(k)
				break


## A tube cut to fit between two open ports that face each other across a
## clear gap (up to GAP studs along, SHIFT aside): rooms reached two ways, as
## the ISS's are. Wide enough for both doorways, a stud of wall, floor and
## ceiling round it, in the first port's wall brick; the two ports joined
## through it.
func _bridges() -> void:
	var tube_adds := []
	for i in open.size():
		if bridges >= int(p.bridges):
			break
		var a: Dictionary = open[i]
		if bool(a.used) or String(a.kind) != "door" or String(a.link) != "auto":
			continue
		var fd: Vector2i = StructureSpaces.FACINGS[int(a.facing)]
		var d := Vector3i(fd.x, 0, fd.y)
		for k in open.size():
			var b: Dictionary = open[k]
			if k == i or bool(b.used) or String(b.kind) != "door" or String(b.link) != "auto":
				continue
			if int(b.p) == int(a.p) or int(b.facing) != (int(a.facing) + 2) % 4 or b.size != a.size:
				continue
			var g := _gap(a.at, b.at, d)
			if g.x < 1 or g.x > GAP or absi(g.y) > SHIFT:
				continue
			var span := Vector2i(mini(0, g.y), maxi(0, g.y) + (a.size as Vector2i).x)
			var cells := _tube_cells(a, d, g.x, span)
			if not _free(cells):
				continue
			for c: Vector3i in cells:
				var w := Vector2i(c.x, c.z)
				if not occ.has(w):
					occ[w] = []
				(occ[w] as Array).append([c.y, c.y + 1, -1, false])
			var wall: Array = a.get("wall", [])
			var colour := int(wall[0]) if not wall.is_empty() else int(lib[placed[int(a.p)].m].turns[0].colour)
			var material := int(wall[1]) if not wall.is_empty() else 0
			for c: Vector3i in cells:
				if _shell_of(a, d, span, c):
					tube_adds.append(["plate_1x1", c, colour, material])
			a.used = true
			b.used = true
			joins.append({"a": i, "b": k, "loop": true})
			bridges += 1
			break
	_tubes = tube_adds


## (free cells from a's outer face to b's along d, b's doorway aside of a's
## across): b.at = a.at + d (gap - 1) + across shift. x < 0 when they do not face.
func _gap(a_at: Vector3i, b_at: Vector3i, d: Vector3i) -> Vector2i:
	var across := Vector3i(absi(d.z), 0, absi(d.x))
	var v := b_at - a_at
	var along := v.x * d.x + v.z * d.z
	var aside := v.x * across.x + v.z * across.z
	if v.y != 0 or v != d * along + across * aside:
		return Vector2i(-1, 0)
	return Vector2i(along + 1, aside)


## The tube's cells: `span` across (from a's doorway's low side) by the
## doorway's height, a stud of wall round it, `gap` long.
func _tube_cells(a: Dictionary, d: Vector3i, gap: int, span: Vector2i) -> Array:
	var across := Vector3i(absi(d.z), 0, absi(d.x))
	var h := (a.size as Vector2i).y
	var out := []
	for k in gap:
		for x in range(span.x - 1, span.y + 1):
			for y in range(-1, h + 1):
				out.append((a.at as Vector3i) + d * k + across * x + Vector3i(0, y, 0))
	return out


func _shell_of(a: Dictionary, d: Vector3i, span: Vector2i, c: Vector3i) -> bool:
	var across := Vector3i(absi(d.z), 0, absi(d.x))
	var v: Vector3i = c - (a.at as Vector3i)
	var x := v.x * across.x + v.z * across.z
	return x < span.x or x >= span.y or v.y < 0 or v.y >= (a.size as Vector2i).y


func _free(cells: Array) -> bool:
	for c: Vector3i in cells:
		for s in occ.get(Vector2i(c.x, c.z), []):
			if c.y < int(s[1]) and int(s[0]) <= c.y:
				return false
	return true


## A wing or a radiator out from its spot, if nothing is where it goes.
func _dress(_cuts: Dictionary, adds: Array, mk: Dictionary, off: Vector3i, _td: Dictionary) -> bool:
	var kind := String(mk.kind)
	if kind != "panel" and kind != "radiator":
		return false
	if rng.randf() >= float(p.wings):
		return false
	var size := WING if kind == "panel" else RADIATOR
	var fd: Vector2i = StructureSpaces.FACINGS[int(mk.facing)]
	var d := Vector3i(fd.x, 0, fd.y)
	var across := Vector3i(absi(fd.y), 0, absi(fd.x))
	var at: Vector3i = (mk.at as Vector3i) + off
	var face := at + d * int(mk.depth)
	var boom := []
	for o in BOOM:
		boom.append(face + d * o)
	# The panel in 2x2 tiles, flat, past the boom: each tile's low corner.
	var tiles := []
	@warning_ignore("integer_division")
	for x in range(-size.x / 2, size.x / 2, 2):
		for o in range(BOOM, BOOM + size.y, 2):
			tiles.append((face + d * o).min(face + d * (o + 1)) + across * x)
	var cells := boom.duplicate()
	for t: Vector3i in tiles:
		for dz in 2:
			for dx in 2:
				cells.append(t + Vector3i(dx, 0, dz))
	for c: Vector3i in cells:
		for s in occ.get(Vector2i(c.x, c.z), []):
			if c.y < int(s[1]) and int(s[0]) <= c.y:
				return false
	for c: Vector3i in cells:
		var w := Vector2i(c.x, c.z)
		if not occ.has(w):
			occ[w] = []
		(occ[w] as Array).append([c.y, c.y + 1, -1, false])
	for c: Vector3i in boom:
		adds.append(["plate_1x1", c, _boom_colour, 0])
	for t: Vector3i in tiles:
		adds.append(["plate_2x2", t, _wing_colour if kind == "panel" else _radiator_colour, 0])
	if kind == "panel":
		wings += 1
	else:
		radiators += 1
	return true


## Where the station stands in the workshop: its lowest row at 1, its corner at (1, 1).
func _at(plan: Dictionary) -> Vector3i:
	var lo := Vector3i(1 << 30, 1 << 30, 1 << 30)
	for pl: Dictionary in plan.placed:
		var td: Dictionary = lib[pl.m].turns[pl.t]
		var off: Vector3i = pl.off
		for c: Vector2i in td.cols:
			lo = Vector3i(mini(lo.x, c.x + off.x), mini(lo.y, (td.cols[c] as Vector2i).x + off.y), mini(lo.z, c.y + off.z))
	for a in plan.adds:
		var c: Vector3i = a[1]
		lo = lo.min(c)
	return Vector3i(1 - lo.x, 1 - lo.y, 1 - lo.z)


static func _colour_named(names: Array) -> int:
	for want: String in names:
		for i in BrickWorld.get_material_colour_count(0):
			if BrickWorld.get_material_colour_name(0, i).to_lower() == want:
				return i
	for want: String in names:
		for i in BrickWorld.get_material_colour_count(0):
			if BrickWorld.get_material_colour_name(0, i).to_lower().contains(want):
				return i
	return 0
