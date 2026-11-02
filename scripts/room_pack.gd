class_name RoomPack
extends RoomShell

## Ship interiors (Docs/RoomModules.md 7.4): the shell turned inside out. The
## hull is the outside, given -- a ship build's bricks -- and as much of its
## inside as fits is rooms: decks `pitch` apart up from its keel, each deck's
## footprint what the hull closes round at every row of it; one spine corridor
## fore to aft down every deck through a stair well amidships; modules along
## both sides of it, the biggest that fits first, where their `zone` rule says
## (fore, mid, aft, core, hull, any), the ones with a `min` first; bulkheads
## across the hull every `section_studs` with a door at the spine, no module
## across one, each stretch between them a section (BuildSections); the rest
## filler rooms off the spine, and what is too small or never reached a closed
## storage nook. A few passes, the best kept by `stats.fill`: room cells over
## the hull's inside cells.
##
##   var made := RoomPack.generate(lib, {"seed": 2, "hull": hull_recipe})
##   made.recipe   # the hull and its rooms as one build
##
## The hull is turned so its long side runs along X first (`stats.turned`: the
## quarter turns, the made build in that frame).

const PACK_PARAMS := {"seed": 1, "hull": null, "pitch": 0, "corridor": 4, "room_max": 10,
		"section_studs": 32, "passes": 4, "fore": "auto", "fill": 1.0, "lift": false, "balcony": 0.0,
		"window_every": 1000}
## `airlock`: a doorway with a door through the hull's aft wall at the spine.
## A deck needs at least this many columns.
const MIN_DECK := 60
## The share of the length at each end compared to say which end is fore.
const ENDS := 0.15
const ZONES := ["any", "fore", "mid", "aft", "core", "hull"]

var hull: BuildRecipe
var hull_cells := {}
var turned := 0
var segments := []      ## the bulkheads' columns along x, west to east
var fore := 1           ## +1: fore is +X; -1: -X
var x_lo := 0
var x_hi := 0
var cx_start := []      ## per deck: the spine's west end
var mins_short := 0
var in_hull := 0        ## module wall columns standing in the hull's wall
var airlock := Vector3i(-1, -1, -1)  ## the airlock doorway's low cell, if one was cut
var solid := []         ## per deck: Vector2i -> true, module columns solid all the way up


## {ok, why, recipe, plan, stats}: as RoomShell.generate, with stats.fill.
static func generate(library: Array, params := {}) -> Dictionary:
	var pp := PACK_PARAMS.duplicate()
	pp.merge(params, true)
	if not pp.hull is BuildRecipe or (pp.hull as BuildRecipe).is_empty():
		return {"ok": false, "why": "no hull: build one (or open it) to fill"}
	var best := {}
	var passes := maxi(int(pp.passes), 1)
	for k in passes:
		var g := RoomPack.new()
		var made := g._pack(library, pp, k)
		if not bool(made.ok):
			return made
		if best.is_empty() or float(made.stats.fill) > float(best.stats.fill):
			best = made
	best.stats.passes = passes
	return best


func _pack(library: Array, pp: Dictionary, k: int) -> Dictionary:
	hull = pp.hull
	var b := hull.bounds()
	if (b[1] as Vector3i).z > (b[1] as Vector3i).x:
		hull = hull.turned(1)
		turned = 1
	for i in hull.size():
		var c := hull.cell_of(i)
		var s := BuildRecipe.part_size(hull.part_of(i))
		for y in s.y:
			for z in s.z:
				for x in s.x:
					hull_cells[c + Vector3i(x, y, z)] = true
	nooks = "storage"
	var q := pp.duplicate()
	q.erase("hull")
	q.seed = int(pp.seed) * 7919 + k
	var made := _generate(library, q)
	if not bool(made.ok):
		return made
	made.plan.seed = int(pp.seed)
	made.stats.merge(_fill_stats(), true)
	made.stats.turned = turned
	made.stats.fore = "+x" if fore > 0 else "-x"
	made.stats.bulkheads = segments.size()
	made.stats.short = mins_short
	made.stats.in_hull = in_hull
	made.stats.airlock = airlock
	made.recipe.meta.generated.stats = made.stats
	made.recipe.meta.generated.seed = int(pp.seed)
	made.recipe.name = "ship interior %d" % int(pp.seed)
	return made


func _kind() -> String:
	return "pack"


func _plan_at() -> Vector3i:
	return Vector3i.ZERO


func _plan_more(plan: Dictionary) -> void:
	plan.segments = segments.duplicate()
	plan.fore = fore
	# The root section: the one with the required fore module (the bridge), else the bow's.
	plan.root_x = x_hi if fore > 0 else x_lo
	for pl: Dictionary in placed:
		var rules: Dictionary = lib[pl.m].rules
		if String(rules.get("zone", "any")) == "fore" and int(rules.min) > 0:
			var lo := 1 << 30
			var hi := -(1 << 30)
			for c: Vector2i in lib[pl.m].turns[pl.t].cols:
				lo = mini(lo, c.x + (pl.off as Vector3i).x)
				hi = maxi(hi, c.x + (pl.off as Vector3i).x)
			@warning_ignore("integer_division")
			plan.root_x = (lo + hi) / 2
			break
	# Each stretch between bulkheads a section of its own.
	plan.section_bricks = 1


## The hull's bricks first, so nothing of the rooms is laid in them.
## The hull's bricks first, so nothing of the rooms is laid in them -- but not in
## the airlock (`airlock`): a doorway through the hull's aft wall where the spine
## meets it on the lowest deck, a door in it.
func _prelay() -> void:
	var hole := {}
	if bool(p.get("airlock", false)) and storeys > 0:
		var x := int(cx_start[0]) - 1 if fore > 0 else int(cx_end[0]) + 1
		var h := mini(door_h, pitch - 3)
		for z in range(zc + 1, zc + 3):
			for y in h:
				hole[Vector3i(x, base + 1 + y, z)] = true
		if hull_cells.has(Vector3i(x, base + 1, zc + 1)):
			doors.append(_door_box(Vector2i(x, zc + 1), Vector2i(x, zc + 2), base, h))
			airlock = Vector3i(x, base + 1, zc + 1)
	var hb := []
	for i in hull.size():
		var c := hull.cell_of(i)
		var sz := BuildRecipe.part_size(hull.part_of(i))
		var cut := false
		for y in sz.y:
			for z in sz.z:
				for x in sz.x:
					cut = cut or hole.has(c + Vector3i(x, y, z))
		if not cut:
			hb.append([hull.part_of(i), c, hull.colour_of(i), hull.material_of(i)])
			continue
		# What of it the doorway leaves, in plates: a brick over the hole's top
		# row would leave a gap under the next one, the door's lintel.
		for y in sz.y:
			for z in sz.z:
				for x in sz.x:
					var v := c + Vector3i(x, y, z)
					if not hole.has(v):
						hb.append(["plate_1x1", v, hull.colour_of(i), hull.material_of(i)])
	adds = hb + adds


# ---------------------------------------------------------------------------
# The decks.

## Each deck's footprint: the columns the hull closes round at every row from
## its floor to its ceiling (the floor and ceiling rows inside or the hull's
## own), from the hull's lowest row up, while a deck has MIN_DECK columns.
func _footprints() -> void:
	var b := hull.bounds()
	var lo: Vector3i = b[0]
	var size: Vector3i = b[1]
	base = lo.y
	x_lo = lo.x
	x_hi = lo.x + size.x - 1
	var rows := {}
	var s := 0
	while true:
		var yb := base + s * pitch
		if yb + pitch > lo.y + size.y - 1:
			break
		for y in range(yb, yb + pitch + 1):
			if not rows.has(y):
				rows[y] = _inside(y, lo, size)
		# Inside at every row of the deck; its floor and ceiling rows inside or the hull's.
		var f := {}
		for c: Vector2i in rows[yb + 1]:
			var ok := true
			for y in range(yb + 2, yb + pitch):
				ok = ok and (rows[y] as Dictionary).has(c)
			for y in [yb, yb + pitch]:
				ok = ok and ((rows[y] as Dictionary).has(c) or hull_cells.has(Vector3i(c.x, y, c.y)))
			if ok:
				f[c] = true
		if f.size() < MIN_DECK:
			break
		foot.append(f)
		ring.append({})
		inner.append(f)
		s += 1
	storeys = foot.size()
	foot.append({})
	ring.append({})
	inner.append({})
	if storeys > 0:
		# Fore: the narrower end of the lowest deck.
		var len := x_hi - x_lo + 1
		var aft_n := 0
		var fore_n := 0
		for c: Vector2i in foot[0]:
			if c.x < x_lo + len * ENDS:
				aft_n += 1
			elif c.x > x_hi - len * ENDS:
				fore_n += 1
		match String(p.fore):
			"+x":
				fore = 1
			"-x":
				fore = -1
			_:
				fore = 1 if fore_n <= aft_n else -1


## The cells of row y the hull closes round: not the hull's, not reached from
## outside its bounds.
func _inside(y: int, lo: Vector3i, size: Vector3i) -> Dictionary:
	var out := {}
	var seen := {}
	var todo: Array[Vector2i] = []
	for x in range(lo.x - 1, lo.x + size.x + 1):
		for z in [lo.z - 1, lo.z + size.z]:
			todo.append(Vector2i(x, z))
	for z in range(lo.z - 1, lo.z + size.z + 1):
		for x in [lo.x - 1, lo.x + size.x]:
			todo.append(Vector2i(x, z))
	for c in todo:
		seen[c] = true
	while not todo.is_empty():
		var c: Vector2i = todo.pop_back()
		for d: Vector2i in DIRS:
			var n := c + d
			if seen.has(n) or n.x < lo.x - 1 or n.y < lo.z - 1 or n.x > lo.x + size.x or n.y > lo.z + size.z:
				continue
			if hull_cells.has(Vector3i(n.x, y, n.y)):
				continue
			seen[n] = true
			todo.append(n)
	for z in range(lo.z, lo.z + size.z):
		for x in range(lo.x, lo.x + size.x):
			var c := Vector2i(x, z)
			if not seen.has(c) and not hull_cells.has(Vector3i(x, y, z)):
				out[c] = true
	return out


## The stair well amidships: where every deck has the hall, its walls and the
## spine's band, nearest the middle of the lowest deck.
func _place_hall() -> bool:
	if storeys == 0:
		return false
	var bb := _box(foot[0])
	var lo: Vector2i = bb[0]
	var size: Vector2i = bb[1]
	@warning_ignore("integer_division")
	var mz := lo.y + (size.y - corr) / 2
	@warning_ignore("integer_division")
	var mx := lo.x + (size.x - hall) / 2
	var zs := []
	for k in size.y:
		var half := (k + 1) >> 1
		zs.append(mz - half if k % 2 == 0 else mz + half)
	var xs := []
	for k in size.x:
		var half := (k + 1) >> 1
		xs.append(mx - half if k % 2 == 0 else mx + half)
	for z in zs:
		for x in xs:
			if _well_fits(x, z):
				hx0 = x
				hx1 = x + hall - 1
				zc = z
				for hz in range(zc - 1, zc + corr + 1):
					for hx in range(hx0, hx1 + 1):
						hall_cells[Vector2i(hx, hz)] = true
				for hz in range(zc - 2, zc + corr + 2):
					for hx in range(hx0 - 1, hx1 + 2):
						var c := Vector2i(hx, hz)
						var opening := (hx == hx0 - 1 or hx == hx1 + 1) and hz >= zc and hz < zc + corr
						if not hall_cells.has(c) and not opening:
							hall_ring[c] = true
				_bulkheads()
				return true
	return false


func _well_fits(x: int, z: int) -> bool:
	for s in storeys:
		var f: Dictionary = foot[s]
		for hz in range(z - 2, z + corr + 2):
			for hx in range(x - 2, x + hall + 2):
				if not f.has(Vector2i(hx, hz)):
					return false
	return true


## Bulkheads every section_studs from the fore and aft ends inward... from x_lo
## east, moved clear of the well.
func _bulkheads() -> void:
	var step := maxi(int(p.section_studs), hall + 6)
	var x := x_lo + step
	while x < x_hi - 4:
		var bx := x
		if bx >= hx0 - 2 and bx <= hx1 + 2:
			bx = hx1 + 3
		if segments.is_empty() or bx > int(segments[-1]) + 4:
			segments.append(bx)
		x += step


## Deck s's spine: both ways from the well while the deck has its whole band,
## a wall across each end; its bulkheads with a doorway (and a door) at the spine.
func _corridor(s: int) -> void:
	var c := {}
	var inn: Dictionary = inner[s]
	var band := func(x: int) -> bool:
		for z in range(zc - 1, zc + corr + 1):
			if not inn.has(Vector2i(x, z)):
				return false
		return true
	var east := hx1 + 1
	while band.call(east):
		for z in range(zc, zc + corr):
			c[Vector2i(east, z)] = true
		east += 1
	var west := hx0 - 1
	while band.call(west):
		for z in range(zc, zc + corr):
			c[Vector2i(west, z)] = true
		west -= 1
	corridor.append(c)
	cx_end.append(east - 1)
	cx_start.append(west + 1)
	var wl := {}
	for wx in range(west + 1, east):
		if wx >= hx0 - 1 and wx <= hx1 + 1:
			continue
		for z in [zc - 1, zc + corr]:
			wl[Vector2i(wx, z)] = true
	for z in range(zc - 1, zc + corr + 1):
		wl[Vector2i(east, z)] = true
		wl[Vector2i(west, z)] = true
	for k in hall_ring:
		wl[k] = true
	var yb := _yb(s)
	var h := mini(door_h, pitch - 3)
	for bx: int in segments:
		var across := []
		for col: Vector2i in inn:
			if col.x == bx:
				wl[col] = true
				if c.has(col):
					across.append(col)
					for y in h:
						holes[Vector3i(col.x, yb + 1 + y, col.y)] = true
		if not across.is_empty():
			across.sort()
			doors.append(_door_box(across[0], across[-1], yb, h))
	for k in wl.keys():
		if not inn.has(k):
			wl.erase(k)
	walls.append(wl)


## The top deck has no flight up: the hull's roof is over it.
func _flight(s: int) -> void:
	if s < storeys - 1:
		super._flight(s)


# ---------------------------------------------------------------------------
# Packing.

func _door_x_ok(s: int, x0: int, x1: int) -> bool:
	if not (x1 < hx0 - 1 or x0 > hx1 + 1):
		return false
	var cor: Dictionary = corridor[s]
	for x in range(x0, x1 + 1):
		if not cor.has(Vector2i(x, zc)) or segments.has(x):
			return false
	return true


## Two modules side by side share a wall: a column solid from the floor to the
## top in both (no doorway, no window in it) may be both of theirs.
func _shares(td: Dictionary, c: Vector2i, s: int, w: Vector2i) -> bool:
	return _solid_of(td).has(c) and (solid[s] as Dictionary).has(w)


## A module's solid wall may stand in the hull's wall: the hull's bricks there
## all its rows (the module's are cut there, the hull kept).
func _outside_ok(td: Dictionary, c: Vector2i, off: Vector3i, w: Vector2i) -> bool:
	if not _solid_of(td).has(c):
		return false
	var span: Vector2i = td.cols[c]
	for y in range(span.x + off.y, span.y + off.y):
		if not hull_cells.has(Vector3i(w.x, y, w.y)):
			return false
	return true


func _put(s: int, side: int, pick: Array) -> int:
	var x1 := super._put(s, side, pick)
	var off: Vector3i = pick[2]
	var td: Dictionary = lib[pick[0]].turns[pick[1]]
	# Its walls in the hull's: the hull's bricks stay.
	for c: Vector2i in td.cols:
		var w := Vector2i(c.x + off.x, c.y + off.z)
		if not (foot[s] as Dictionary).has(w):
			in_hull += 1
			var span: Vector2i = td.cols[c]
			for y in range(span.x + off.y, span.y + off.y):
				cuts[Vector3i(w.x, y, w.y)] = true
	while solid.size() <= s:
		solid.append({})
	for c: Vector2i in _solid_of(td):
		solid[s][Vector2i(c.x + off.x, c.y + off.z)] = true
	return x1


## A turned module's columns solid from its lowest row to its top (cached).
func _solid_of(td: Dictionary) -> Dictionary:
	if td.has("solid_cols"):
		return td.solid_cols
	var count := {}
	var r: BuildRecipe = td.recipe
	for i in r.size():
		var c := r.cell_of(i)
		var sz := BuildRecipe.part_size(r.part_of(i))
		for z in sz.z:
			for x in sz.x:
				var k := Vector2i(c.x + x, c.z + z)
				count[k] = int(count.get(k, 0)) + sz.y
	var out := {}
	for c: Vector2i in td.cols:
		var span: Vector2i = td.cols[c]
		if int(count.get(c, 0)) >= span.y - span.x:
			out[c] = true
	td["solid_cols"] = out
	return out


func _sealed(c: Vector2i) -> bool:
	return segments.has(c.x)


func _clear(td: Dictionary, off: Vector3i, s: int, side: int, line: int) -> bool:
	if not super._clear(td, off, s, side, line):
		return false
	for c: Vector2i in td.cols:
		if segments.has(c.x + off.x):
			return false
	return true


## Every fit at x whose zone rule its place keeps.
func _fits_at(s: int, side: int, x: int) -> Array:
	return super._fits_at(s, side, x).filter(func(c) -> bool:
			return _zone_ok(int(c[0]), lib[c[0]].turns[c[1]], c[2], s))


func _zone_ok(m: int, td: Dictionary, off: Vector3i, s: int) -> bool:
	var zone := String(lib[m].rules.get("zone", "any"))
	if zone == "any":
		return true
	var lo := 1 << 30
	var hi := -(1 << 30)
	var touches := false
	var f: Dictionary = foot[s]
	for c: Vector2i in td.cols:
		var w := Vector2i(c.x + off.x, c.y + off.z)
		lo = mini(lo, w.x)
		hi = maxi(hi, w.x)
		for d: Vector2i in DIRS:
			if not f.has(w + d):
				touches = true
	var t := (float(lo + hi) * 0.5 - x_lo) / maxf(float(x_hi - x_lo), 1.0)
	if fore < 0:
		t = 1.0 - t
	match zone:
		"fore":
			return t >= 2.0 / 3.0
		"aft":
			return t < 1.0 / 3.0
		"mid":
			return t >= 1.0 / 3.0 and t < 2.0 / 3.0
		"core":
			return t >= 1.0 / 3.0 and t < 2.0 / 3.0 and not touches
		"hull":
			return touches
	return true


## The modules with a `min` first, each where its zone has room, biggest first.
func _before_fill() -> void:
	var need := []
	for m in lib.size():
		if int(lib[m].rules.min) > 0:
			need.append(m)
	need.sort_custom(func(a, b) -> bool:
			return (lib[a].turns[0].cols as Dictionary).size() > (lib[b].turns[0].cols as Dictionary).size())
	for m: int in need:
		for k in int(lib[m].rules.min):
			if not _put_one(m):
				mins_short += 1


func _put_one(m: int) -> bool:
	for s in storeys:
		for side in [0, 1]:
			for x in range(int(cx_start[s]), int(cx_end[s]) + 1):
				var fits := _fits_at(s, side, x).filter(func(c) -> bool: return int(c[0]) == m)
				if not fits.is_empty():
					_put(s, side, fits[0])
					return true
	return false


## One side of one deck, west to east along the spine: at each stud the
## biggest module that fits (a quarter of the time, after the first pass, one
## by weight), else a stud on.
func _fill_side(s: int, side: int) -> void:
	var x := int(cx_start[s])
	while x <= int(cx_end[s]):
		var cands := _fits_at(s, side, x)
		if cands.is_empty():
			x += 1
			continue
		var pick: Array
		if int(p.seed) % 7919 > 0 and rng.randf() < 0.25:
			pick = _weighted(cands)
		else:
			var best := -1
			for c in cands:
				var n := (lib[c[0]].turns[c[1]].cols as Dictionary).size()
				if n > best or (n == best and rng.randf() < 0.5):
					best = n
					pick = c
		# The next one may share this one's east wall.
		x = _put(s, side, pick)


## How much of the inside is rooms: each deck's columns in a module's room, the
## spine and well, a filler room or a nook, over its footprint's columns.
func _fill_stats() -> Dictionary:
	var inside := 0
	var used := 0
	for s in storeys:
		inside += (foot[s] as Dictionary).size()
		var u := {}
		for pl: Dictionary in placed:
			if int(pl.storey) != s:
				continue
			var off: Vector3i = pl.off
			for sp: Dictionary in lib[pl.m].turns[pl.t].spaces.values():
				for c: Vector2i in sp.cols:
					u[Vector2i(c.x + off.x, c.y + off.z)] = true
		var yb := _yb(s)
		for room: Dictionary in rooms:
			if int(room.floor_y) == yb:
				for c in room.cols:
					u[c] = true
		used += u.size()
	var n_nooks := rooms.filter(func(r) -> bool: return String(r.kind) == "storage").size()
	return {"fill": float(used) / maxf(float(inside), 1.0), "inside": inside, "used": used,
			"decks": storeys, "nooks": n_nooks}
