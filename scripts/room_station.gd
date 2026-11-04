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
## Built to hold in space, where nothing stands on the ground: every seam
## between two modules tied under their walls by a plate, tubes and wings in
## two plate layers, and a keel of plates under the core the lowest thing of
## all -- the station's one anchor (its foundation row), so a part a hit cuts
## off from the core comes away whole (Docs/RoomModules.md 7.3).
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
## The furthest above or below a bridged port may be of the other, plates: a
## tube between two levels holds a stair (a stud of tread a step, two studs of
## landing at its top), each step's rise the first of STEPS its gap has the
## length for (two plates, the workshop's stair; a brick, the pawn's step).
const RISE := 24
const STEPS := [2, 3]
const NONE := 1 << 30

var wings := 0
var radiators := 0
var bridges := 0
var stairs := 0          ## bridging tubes between two levels, a stair in each
var sills := 0           ## door seams tied by a tile on their sills (over a module below)
var docks := 0
var _wing_colour := -1
var _radiator_colour := -1
var _boom_colour := -1
var _tubes := []        ## the bridging tubes' and the ties' bricks, added to the plan's
var keel_row := 0       ## the keel's lowest row, before the plan is moved (`_at`)


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
	_ties()
	(plan.adds as Array).append_array(_tubes)
	_keel(plan)
	plan.stats.merge({"docks": docks, "bridges": bridges, "stairs": stairs, "sills": sills, "wings": wings,
			"radiators": radiators}, true)
	plan.keel = keel_row
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
## clear gap (up to GAP studs along, SHIFT aside, RISE plates up or down): rooms
## reached two ways, as the ISS's are. Wide enough for both doorways; a floor
## and a ceiling of two plate layers (each seam bridged), walls of bricks on the
## floor's edge, tied to both modules under their walls; the two ports joined
## through it. Between two levels it is as tall as both doorways' rows, a stair
## of bricks on its floor up to the higher doorway and a lintel over the lower.
func _bridges() -> void:
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
			var rise := (b.at as Vector3i).y - (a.at as Vector3i).y
			if g.x < 1 or g.x > GAP or absi(g.y) > SHIFT or absi(rise) > RISE \
					or rise != 0 and _step_for(g.x, absi(rise)) == 0:
				continue
			var span := Vector2i(mini(0, g.y), maxi(0, g.y) + (a.size as Vector2i).x)
			var cells := _tube_cells(a, d, g.x, span, rise)
			if not _free(cells):
				continue
			for c: Vector3i in cells:
				_occupy(c)
			_tube(a, b, d, g.x, span)
			a.used = true
			b.used = true
			joins.append({"a": i, "b": k, "loop": true})
			bridges += 1
			stairs += 1 if rise != 0 else 0
			break


## A stair's rise a step up `rise` plates in a tube `gap` studs long: the first
## of STEPS whose flight and landing it has the length for; 0, none.
func _step_for(gap: int, rise: int) -> int:
	for s: int in STEPS:
		if ceili(float(rise) / s) + 2 <= gap:
			return s
	return 0


## (free cells from a's outer face to b's along d, b's doorway aside of a's
## across): b.at = a.at + d (gap - 1) + across shift (+ up or down). x < 0 when
## they do not face.
func _gap(a_at: Vector3i, b_at: Vector3i, d: Vector3i) -> Vector2i:
	var across := Vector3i(absi(d.z), 0, absi(d.x))
	var v := b_at - a_at
	v.y = 0
	var along := v.x * d.x + v.z * d.z
	var aside := v.x * across.x + v.z * across.z
	if v != d * along + across * aside:
		return Vector2i(-1, 0)
	return Vector2i(along + 1, aside)


## The tube's cells: `span` across (from a's doorway's low side) and a stud of
## wall each side, from two plates under the lower doorway (its floor) to two
## over the higher (its ceiling), `gap` long.
func _tube_cells(a: Dictionary, d: Vector3i, gap: int, span: Vector2i, rise := 0) -> Array:
	var across := Vector3i(absi(d.z), 0, absi(d.x))
	var h := (a.size as Vector2i).y + absi(rise)
	var at: Vector3i = (a.at as Vector3i) + Vector3i(0, mini(rise, 0), 0)
	var out := []
	for k in gap:
		for x in range(span.x - 1, span.y + 1):
			for y in range(-2, h + 2):
				out.append(at + d * k + across * x + Vector3i(0, y, 0))
	return out


## The tube's bricks: its floor, walls and ceiling, and a tie at each end;
## between two levels, its stair and the lintel over the lower doorway.
func _tube(a: Dictionary, b: Dictionary, d: Vector3i, gap: int, span: Vector2i) -> void:
	var across := Vector3i(absi(d.z), 0, absi(d.x))
	var rise := (b.at as Vector3i).y - (a.at as Vector3i).y
	var door_h := (a.size as Vector2i).y
	var h := door_h + absi(rise)
	# Its frame's row 0 the lower doorway's bottom row.
	var at: Vector3i = (a.at as Vector3i) + Vector3i(0, mini(rise, 0), 0)
	var wall: Array = a.get("wall", [])
	var colour := int(wall[0]) if not wall.is_empty() else int(lib[placed[int(a.p)].m].turns[0].colour)
	var material := int(wall[1]) if not wall.is_empty() else 0
	# The tube in its own frame: o along d (0 .. gap - 1), x across (span.x - 1 .. span.y).
	var cell := func(o: int, x: int, y: int) -> Vector3i:
		return at + d * o + across * x + Vector3i(0, y, 0)
	var w := span.y - span.x + 2
	for layer in 2:
		var y := -2 + layer
		_slab_adds(_tubes, func(o: int, x: int) -> Vector3i: return cell.call(o, span.x - 1 + x, y),
				gap, w, layer, colour, material)
		_slab_adds(_tubes, func(o: int, x: int) -> Vector3i: return cell.call(o, span.x - 1 + x, h + layer),
				gap, w, layer, colour, material)
	for o in gap:
		for x in [span.x - 1, span.y]:
			_wall_column(_tubes, cell.call(o, x, 0), h, colour, material)
	# Ties: under a's wall and the tube's first stud, under b's and its last.
	# (Only where the module has its wall under the tube's end: a doorway aside
	# of the other is tied under its own part of the end.) At the higher end of a
	# stair the tie is right under that module's wall, in the stair's top step,
	# which stands on it and under it (`held`: the step's row it takes).
	var held := {}
	for x in range(span.x, span.y, 2):
		for end in [[int(a.p), -1, 0, rise < 0], [int(b.p), gap, gap - 1, rise > 0]]:
			var mc: Vector3i = cell.call(end[1], x, 0)
			var tc: Vector3i = cell.call(end[2], x, 0)
			var lo := mini(_low_of(end[0], mc), _low_of(end[0], mc + across))
			if lo == NONE:
				continue
			if bool(end[3]) and lo - 1 >= at.y:
				_tie(mc, lo, tc, lo, Vector3i.ZERO, d, colour, material)
				held[Vector2i(end[2], x)] = lo - 1 - at.y
				held[Vector2i(end[2], x + 1)] = lo - 1 - at.y
			else:
				_tie(mc, lo, tc, at.y - 2, Vector3i.ZERO, d, colour, material)
	if rise == 0:
		return
	# The stair: k studs from the higher doorway, a column of bricks on the floor
	# up to its step; two studs of landing at the top.
	var top := absi(rise)
	var each := _step_for(gap, top)
	for o in gap:
		var k := gap - 1 - o if rise > 0 else o
		var step := clampi(top - each * (k - 1), 0, top)
		for x in range(span.x, span.y):
			var tie_row := int(held.get(Vector2i(o, x), step))
			_wall_column(_tubes, cell.call(o, x, 0), mini(step, tie_row), colour, material)
			if tie_row < step:
				_wall_column(_tubes, cell.call(o, x, tie_row + 1), step - tie_row - 1, colour, material)
	# Over the lower doorway, where the module's wall may not reach: a lintel
	# hung from the ceiling.
	var low := 0 if rise > 0 else gap - 1
	for x in range(span.x, span.y):
		_wall_column(_tubes, cell.call(low, x, door_h), top, colour, material)


## One layer of a two-layer slab `n_o` x `n_x` studs, `cell(o, x)` placing a
## stud of it: layer 0 in 2x2 plates from its corner; layer 1 a stud in, 1x1s
## round its rim -- every seam of one bridged by the other (StationKit.slab).
func _slab_adds(out: Array, cell: Callable, n_o: int, n_x: int, layer: int, colour: int, material: int) -> void:
	# The upper layer is a stud in both ways -- only across when it is too short
	# along to be (a two-stud tube), where its plates still bridge every seam.
	var so := layer if n_o > 2 else 0
	var sx := layer
	var o_end := n_o - so
	var x_end := n_x - sx
	for o in range(so, o_end, 2):
		for x in range(sx, x_end, 2):
			if o + 1 < o_end and x + 1 < x_end:
				var lo: Vector3i = (cell.call(o, x) as Vector3i).min(cell.call(o + 1, x + 1))
				out.append(["plate_2x2", lo, colour, material])
				continue
			for do in mini(2, o_end - o):
				for dx in mini(2, x_end - x):
					out.append(["plate_1x1", cell.call(o + do, x + dx), colour, material])
	if layer == 1:
		for o in n_o:
			for x in n_x:
				if (so > 0 and (o == 0 or o == n_o - 1)) or x == 0 or x == n_x - 1:
					out.append(["plate_1x1", cell.call(o, x), colour, material])


## A wall column `h` plates up from `at`: bricks, a plate where three no longer fit.
func _wall_column(out: Array, at: Vector3i, h: int, colour: int, material: int) -> void:
	var y := 0
	while y < h:
		var brick := y + 3 <= h
		out.append(["brick_1x1" if brick else "plate_1x1", at + Vector3i(0, y, 0), colour, material])
		y += 3 if brick else 1


## A 2x2 plate under the seam between column `a` (its lowest brick at row
## `lo_a`) and column `b` (at `lo_b`), across +`side` and one more: one plate
## under the lower of the two, plates stacked under the other down to it.
func _tie(a: Vector3i, lo_a: int, b: Vector3i, lo_b: int, side: Vector3i, d: Vector3i, colour: int,
		material: int) -> void:
	var u := mini(lo_a, lo_b) - 1
	var across := Vector3i(absi(d.z), 0, absi(d.x))
	for pair in [[a, lo_a], [b, lo_b]]:
		var col: Vector3i = pair[0]
		for y in range(u + 1, int(pair[1])):
			for x in 2:
				_tubes.append(["plate_1x1", Vector3i(col.x, y, col.z) + side + across * x, colour, material])
	var lo := (a + side).min(b + side)
	_tubes.append(["plate_2x2", Vector3i(lo.x, u, lo.z), colour, material])


## The lowest row of placement `pi` in world column `col` (NONE: not its column).
func _low_of(pi: int, col: Vector3i) -> int:
	var pl: Dictionary = placed[pi]
	var td: Dictionary = lib[pl.m].turns[pl.t]
	var off: Vector3i = pl.off
	var span = td.cols.get(Vector2i(col.x - off.x, col.z - off.z))
	if span == null:
		return NONE
	return (span as Vector2i).x + off.y


func _occupy(c: Vector3i) -> void:
	var w := Vector2i(c.x, c.z)
	if not occ.has(w):
		occ[w] = []
	(occ[w] as Array).append([c.y, c.y + 1, -1, false])


func _free(cells: Array) -> bool:
	for c: Vector3i in cells:
		for s in occ.get(Vector2i(c.x, c.z), []):
			if c.y < int(s[1]) and int(s[0]) <= c.y:
				return false
	return true


## Every door join's seam tied under its two walls (a station holds by its
## studs: nothing in space stands on the ground).
func _ties() -> void:
	for j: Dictionary in joins:
		var a: Dictionary = open[j.a]
		var b: Dictionary = open[j.b]
		if String(a.kind) != "door":
			continue
		var fd: Vector2i = StructureSpaces.FACINGS[int(a.facing)]
		var d := Vector3i(fd.x, 0, fd.y)
		if b.at != (a.at as Vector3i) - d:
			continue    # a bridging tube: tied by _tube
		var wall: Array = a.get("wall", [])
		var colour := int(wall[0]) if not wall.is_empty() else 0
		var across := Vector3i(absi(d.z), 0, absi(d.x))
		var at: Vector3i = a.at
		for x in range(0, maxi((a.size as Vector2i).x - 1, 1), 2):
			var la := _low_of(int(a.p), at - d + across * x)
			var lb := _low_of(int(b.p), at + across * x)
			if la == NONE or lb == NONE:
				continue
			# Over a module below (a level up), the tie's place is that module's
			# ceiling: a tile across the doorway's sills holds the two instead.
			var u := mini(la, lb) - 1
			var under := []
			for c: Vector3i in [at - d, at]:
				for k in 2:
					for y in range(u, maxi(la, lb)):
						under.append(Vector3i(c.x, y, c.z) + across * (x + k))
			if _free(under):
				_tie(at - d, la, at, lb, across * x, d, colour, 0)
			else:
				_tubes.append(["tile_2x2", (at - d).min(at) + across * x, colour, 0])
				sills += 1


## Under the core, the lowest thing of all: a keel of plates, the only bricks
## at the station's lowest row -- in space its one anchor (the foundation), so
## what a hit leaves joined to nothing that reaches the core comes away.
func _keel(plan: Dictionary) -> void:
	var core: Dictionary = placed[int(path[0])]
	var td: Dictionary = lib[core.m].turns[core.t]
	var off: Vector3i = core.off
	var lo := Vector2i(1 << 30, 1 << 30)
	var hi := -lo
	for c: Vector2i in td.cols:
		lo = Vector2i(mini(lo.x, c.x), mini(lo.y, c.y))
		hi = Vector2i(maxi(hi.x, c.x), maxi(hi.y, c.y))
	@warning_ignore("integer_division")
	var mid := Vector2i((lo.x + hi.x) / 2, (lo.y + hi.y) / 2)
	var core_low := int(td.min_y) + off.y
	var g := core_low
	for pl: Dictionary in placed:
		g = mini(g, int(lib[pl.m].turns[pl.t].min_y) + (pl.off as Vector3i).y)
	for a in plan.adds:
		g = mini(g, (a[1] as Vector3i).y)
	var colour := int(td.colour)
	for y in range(g - 2, core_low):
		plan.adds.append(["plate_2x2", Vector3i(mid.x + off.x, y, mid.y + off.z), colour, 0])
	keel_row = g - 2


## A wing or a radiator on its spot: flat on the module's roof at the wall and
## out past it -- a boom two studs wide BOOM long, then the panel -- in two
## plate layers, the upper a stud along so each seam is bridged and the whole
## holds to the wall's top by its studs. If nothing is where it goes.
func _dress(_cuts: Dictionary, adds: Array, mk: Dictionary, off: Vector3i, td: Dictionary) -> bool:
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
	var top = td.cols.get(Vector2i((mk.at as Vector3i).x, (mk.at as Vector3i).z))
	if top == null:
		return false
	var row: int = (top as Vector2i).y + off.y
	# o along d from the wall's outer stud (-1), x across.
	var face := at + d * int(mk.depth)
	face.y = 0
	var cell := func(o: int, x: int, y: int) -> Vector3i:
		return face + d * o + across * x + Vector3i(0, y, 0)
	var parts := []
	var colour := _wing_colour if kind == "panel" else _radiator_colour
	@warning_ignore("integer_division")
	var x0 := -size.x / 2
	# The boom: plates two studs wide along it, the upper layer a stud on from the
	# lower, its last one over the panel's first row.
	for o in range(-1, BOOM, 2):
		parts.append(["plate_2x2", (cell.call(o, 0, row) as Vector3i).min(cell.call(o + 1, 1, row)), _boom_colour, 0])
	for o in range(0, BOOM + 1, 2):
		parts.append(["plate_2x2", (cell.call(o, 0, row + 1) as Vector3i).min(cell.call(o + 1, 1, row + 1)),
				_boom_colour, 0])
	for layer in 2:
		_slab_adds(parts, func(o: int, x: int) -> Vector3i: return cell.call(BOOM + o, x0 + x, row + layer),
				size.y, size.x, layer, colour, 0)
	var cells := []
	for a in parts:
		var sz := BuildRecipe.part_size(String(a[0]))
		for z in sz.z:
			for x in sz.x:
				cells.append((a[1] as Vector3i) + Vector3i(x, 0, z))
	if not _free(cells):
		return false
	for c: Vector3i in cells:
		_occupy(c)
	adds.append_array(parts)
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
