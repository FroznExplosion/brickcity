class_name RoomShell
extends RefCounted

## The set-by-shell generator (Docs/RoomModules.md section 4): a tower's
## outside fixed first -- a footprint (a box `width` x `depth`, or any shape:
## an outline drawn in the workshop, `footprint`), `storeys` high, stepping in
## by `setback` studs every `setback_every` storeys -- and its inside split
## into rooms and filled with modules from the library (RoomModules).
##
##   var lib := RoomModules.library()
##   var made := RoomShell.generate(lib, {"seed": 3, "width": 44, "depth": 28, "storeys": 6})
##   made.recipe   # the tower as one build
##
## A storey, seen from above (a box; any footprint has the same parts):
##
##   +---------------+--------+-----+
##   | lift |        |module| filler|   north: rooms on the corridor
##   +--  --+--------+--  ----+-----+
##   | stair hall ===  corridor      |
##   +--------------++--  --+--  ---+
##   |   filler     |module | module|   south
##   +--------------+-------+-------+
##
## The stair hall where the top storey has room for it, at the west end of the
## corridor, the same place every storey: a straight flight a storey, two
## studs wide, two plates a step, the flights turning back storey to storey in
## two lanes, the slab over each cut; the top one comes up through the roof
## (the finish). A lift shaft beside it where it fits (BuildLifts), a door to
## it each storey. The corridor runs east from the hall as far as the storey
## goes; along it, each side filled west to east with modules whose door faces
## the corridor, their own walls standing in the shell's. The rest of the
## storey is filler rooms -- split where they run past `room_max` either way --
## each with a doorway to the corridor, the hall, or a filler room already
## reached, so every room is reached. A module's other doors are walled up.
## Windows in the outer wall, one window style a tower; a rail round the roof
## and round every terrace a setback leaves. Doors in every doorway
## (BuildDoors). The way in: a doorway in the outer wall off the corridor or
## the hall on the ground, the east end first.
##
## Same seed, footprint and library, same tower. Laid by RoomGrow.lay, as a
## grown building is.

## The shell's defaults. `pitch`: plates a storey, floor to floor (0: the
## height most room modules have); `corridor`: studs wide (4: two flights side
## by side in the hall); `room_max`: studs a filler room runs before a wall
## splits it; `window_every`: studs from one window to the next; `fill`: the
## chance a gap along the corridor gets a module rather than filler;
## `footprint`: [Vector2i] columns the tower stands on (empty: the box);
## `setback`, `setback_every`: studs in, every so many storeys (0: straight up);
## `lift`: a lift shaft by the hall where there is room.
const PARAMS := {"seed": 1, "width": 44, "depth": 28, "storeys": 4, "pitch": 0, "corridor": 4,
		"room_max": 12, "window_every": 5, "fill": 0.85, "footprint": [], "setback": 0,
		"setback_every": 0, "lift": true}
## The module roles a shell sets along its corridors.
const ROLES := ["room", "corridor"]
## A filler room's doorway and the way in: studs across, plates up.
const DOORWAY := Vector2i(2, 9)
## A window in the shell's outer wall, and how far over its floor it starts.
const WINDOW := Vector2i(2, 6)
const SILL := 3
## A flight's rise a step, in plates (StaircaseRecipe.STEP_PLATES).
const STEP := 2
## Bricks a wall course is laid in, longest first, in a running bond.
const WALL_RUNS := [4, 2, 1]
## The pitch when no module says: a floor plate, twelve plates of room, a ceiling.
const PITCH := 14
## A lift shaft's inside, studs.
const SHAFT := 4
const DIRS := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]

var lib: Array
var p: Dictionary
var rng := RandomNumberGenerator.new()
var storeys := 0
var pitch := 0
var corr := 0
var zc := 0             ## the corridor's south row
var hall := 0           ## the stair hall's inside length along x
var hx0 := 0            ## the hall's west column
var hx1 := 0            ## and its east one
var foot := []          ## per storey (and one over the top, empty): Vector2i -> true
var ring := []          ## per storey: its outer wall's columns
var inner := []         ## per storey: inside the outer wall
var hall_cells := {}    ## the hall's inside
var hall_ring := {}     ## its walls
var shaft := {}         ## the lift's inside ({} for none)
var shaft_ring := {}
var shaft_door := []    ## the two columns of the wall between hall and shaft a door is in
var corridor := []      ## per storey: Vector2i -> true
var walls := []         ## per storey: Vector2i -> true, the shell's inner walls
var cx_end := []        ## per storey: the corridor's last column
var placed := []        ## [{m, t, off, door, storey}], as RoomGrow plans have them
var mod_cols := []      ## per storey: Vector2i -> true, the columns of its modules
var holes := {}         ## Vector3i -> true: doorways, windows, the way in, kept open
var pits := []          ## per storey: Vector2i -> true, the slab cells cut over the flight below
var adds := []          ## [[part, cell, colour, material]]
var rooms := []         ## [{kind, seed, cols, floor_y, ceil_y}] the shell's own spaces
var doors := []         ## [[lo, size]]: every hole a door hangs in (BuildDoors)
var colour := 0         ## the shell's colour: the first module's
var style := "open"
var caps := 0


static func generate(library: Array, params := {}) -> Dictionary:
	var g := RoomShell.new()
	return g._generate(library, params)


## The storey height most room modules have (their lowest row to their
## highest), PITCH when there is none.
static func pitch_of(library: Array) -> int:
	var votes := {}
	for m: Dictionary in library:
		if not ROLES.has(String(m.rules.role)):
			continue
		var td: Dictionary = m.turns[0]
		var top := 0
		for c: Vector2i in td.cols:
			top = maxi(top, (td.cols[c] as Vector2i).y)
		var h := top - int(td.min_y)
		votes[h] = int(votes.get(h, 0)) + 1
	var best := PITCH
	var n := 0
	for h in votes:
		if int(votes[h]) > n:
			n = int(votes[h])
			best = int(h)
	return best


## A drawn outline's footprint, for `footprint`: every column a build's bricks
## stand in or close round (RoomModules.footprint).
static func footprint_of(r: BuildRecipe) -> Array:
	return RoomModules.footprint(r).keys()


func _generate(library: Array, params: Dictionary) -> Dictionary:
	lib = library
	p = PARAMS.duplicate()
	p.merge(params, true)
	rng.seed = hash("shell %d" % int(p.seed))
	storeys = maxi(int(p.storeys), 1)
	corr = maxi(int(p.corridor), 4)
	pitch = int(p.pitch) if int(p.pitch) > 0 else pitch_of(lib)
	hall = ceili(float(pitch) / STEP) + 2
	if pitch < DOORWAY.y + 3:
		return {"ok": false, "why": "a storey needs %d plates at least" % (DOORWAY.y + 3)}
	_footprints()
	if not _place_hall():
		return {"ok": false, "why": "the shell is too small: its top storey has no room for a stair hall %d x %d and a corridor" % [
				hall + 2, corr + 4]}
	style = RoomGrow.WINDOW_STYLES[rng.randi_range(0, RoomGrow.WINDOW_STYLES.size() - 1)]
	for s in storeys + 1:
		mod_cols.append({})
		pits.append({})
	for s in storeys:
		_corridor(s)
	for s in storeys:
		for side in [0, 1]:
			_fill_side(s, side)
	if not placed.is_empty():
		colour = int(lib[placed[0].m].turns[placed[0].t].colour)
	_caps_and_glass()
	for s in storeys:
		_flight(s)
	_way_in()
	for s in storeys:
		_rooms_of(s)
		_windows(s)
		_walls(s)
	for s in storeys + 1:
		_slab(s)
	_rails()
	for pl: Dictionary in placed:
		var c: Dictionary = lib[pl.m].turns[pl.t].conns[int(pl.door)]
		doors.append(BuildDoors.hole((c.at as Vector3i) + (pl.off as Vector3i), int(c.facing),
				(c.size as Vector2i).x, (c.size as Vector2i).y, int(c.depth)))
	var lifts := []
	if not shaft.is_empty():
		var lo := Vector2i(1 << 30, 1 << 30)
		for c: Vector2i in shaft:
			lo = Vector2i(mini(lo.x, c.x), mini(lo.y, c.y))
		var stops := []
		for s in storeys:
			stops.append(s * pitch)
		lifts.append({"lo": Vector3i(lo.x, 0, lo.y), "size": Vector2i(SHAFT, SHAFT), "stops": stops})
	var bb := _box(foot[0])
	var g_stats := {"modules": placed.size(), "storeys": storeys, "pitch": pitch, "caps": caps,
			"doors": doors.size(), "rooms": rooms.size(), "width": bb[1].x, "depth": bb[1].y,
			"lifts": lifts.size()}
	var plan := {"ok": true, "why": "", "seed": int(p.seed), "ground_y": 0, "placed": placed,
			"joins": [], "path": [], "entrance": {}, "exit": {}, "caps": [], "cuts": [], "adds": adds,
			"window_style": style, "stats": g_stats, "at": Vector3i(1, 0, 1), "doors": doors, "lifts": lifts}
	var r := RoomGrow.lay(lib, plan, true)
	r.name = "shell %d" % int(p.seed)
	var rec: Dictionary = r.meta["structure"]
	for room: Dictionary in rooms:
		var sd: Vector3i = (room.seed as Vector3i) + Vector3i(1, 0, 1)
		(rec.spaces as Array).append({"id": (rec.spaces as Array).size(), "kind": String(room.kind),
				"frame": 0, "seed": [sd.x, sd.y, sd.z], "floor_y": int(room.floor_y),
				"ceil_y": int(room.ceil_y),
				"columns": (room.cols as Array).map(func(c) -> Array: return [c.x + 1, c.y + 1])})
	r.meta["generated"] = {"generator": "shell", "seed": int(p.seed), "stats": g_stats,
			"modules": placed.map(func(pl) -> String: return String(lib[pl.m].name)), "window_style": style}
	return {"ok": true, "why": "", "recipe": r, "plan": plan, "stats": g_stats, "window_style": style}


# ---------------------------------------------------------------------------
# The outside.

## Each storey's footprint: the drawn one or the box, moved to start at 0,
## stepped in by `setback` every `setback_every` storeys; its outer wall (the
## columns with outside next to them, corners too) and what is inside it.
func _footprints() -> void:
	var base := {}
	var given: Array = p.footprint
	if given.is_empty():
		for z in int(p.depth):
			for x in int(p.width):
				base[Vector2i(x, z)] = true
	else:
		var lo := Vector2i(1 << 30, 1 << 30)
		for c in given:
			lo = Vector2i(mini(lo.x, c.x), mini(lo.y, c.y))
		for c in given:
			base[Vector2i(c.x, c.y) - lo] = true
	for s in storeys + 1:
		var f := {}
		if s < storeys:
			var k := 0
			if int(p.setback_every) > 0:
				@warning_ignore("integer_division")
				k = int(p.setback) * (s / int(p.setback_every))
			f = _eroded(base, k)
		foot.append(f)
		var rg := {}
		var inn := {}
		for c: Vector2i in f:
			var edge := false
			for dz in [-1, 0, 1]:
				for dx in [-1, 0, 1]:
					if not f.has(c + Vector2i(dx, dz)):
						edge = true
			if edge:
				rg[c] = true
			else:
				inn[c] = true
		ring.append(rg)
		inner.append(inn)


func _eroded(f: Dictionary, k: int) -> Dictionary:
	var out := f
	for i in k:
		var next := {}
		for c: Vector2i in out:
			var keep := true
			for dz in [-1, 0, 1]:
				for dx in [-1, 0, 1]:
					if not out.has(c + Vector2i(dx, dz)):
						keep = false
			if keep:
				next[c] = true
		out = next
	return out


static func _box(f: Dictionary) -> Array:
	var lo := Vector2i(1 << 30, 1 << 30)
	var hi := Vector2i(-(1 << 30), -(1 << 30))
	for c: Vector2i in f:
		lo = Vector2i(mini(lo.x, c.x), mini(lo.y, c.y))
		hi = Vector2i(maxi(hi.x, c.x), maxi(hi.y, c.y))
	return [lo, hi - lo + Vector2i.ONE]


## The stair hall where the top storey has room for it and a corridor east of
## it (at least 6 studs), its band nearest the middle, then furthest west; the
## lift beside it, north or south, where it fits.
func _place_hall() -> bool:
	var top: Dictionary = inner[storeys - 1]
	if top.is_empty():
		return false
	var bb := _box(top)
	var lo: Vector2i = bb[0]
	var size: Vector2i = bb[1]
	@warning_ignore("integer_division")
	var mid := lo.y + (size.y - corr) / 2
	var tries := []
	for k in size.y:
		var half := (k + 1) >> 1
		tries.append(mid - half if k % 2 == 0 else mid + half)
	for z in tries:
		for x in range(lo.x, lo.x + size.x):
			if _hall_fits(top, x, z):
				hx0 = x
				hx1 = x + hall - 1
				zc = z
				for hz in range(zc - 1, zc + corr + 1):
					for hx in range(hx0, hx1 + 1):
						hall_cells[Vector2i(hx, hz)] = true
				for hz in range(zc - 2, zc + corr + 2):
					for hx in range(hx0 - 1, hx1 + 2):
						var c := Vector2i(hx, hz)
						if not hall_cells.has(c) and not (hx == hx1 + 1 and hz >= zc and hz < zc + corr):
							hall_ring[c] = true
				if bool(p.lift):
					_place_shaft(top)
				return true
	return false


func _hall_fits(top: Dictionary, x: int, z: int) -> bool:
	for hz in range(z - 1, z + corr + 1):
		for hx in range(x, x + hall + 7):
			if not top.has(Vector2i(hx, hz)):
				return false
	for hz in range(z - 2, z + corr + 2):
		for hx in range(x - 1, x + hall + 1):
			if not (foot[storeys - 1] as Dictionary).has(Vector2i(hx, hz)):
				return false
	return true


func _place_shaft(top: Dictionary) -> void:
	for side in [1, -1]:
		# North: the shaft past the hall's north wall; south: past its south one.
		var z0 := zc + corr + 2 if side == 1 else zc - 2 - SHAFT
		var x0 := hx0
		var ok := true
		for z in range(z0 - 1, z0 + SHAFT + 1):
			for x in range(x0 - 1, x0 + SHAFT + 1):
				var c := Vector2i(x, z)
				var inside := z >= z0 and z < z0 + SHAFT and x >= x0 and x < x0 + SHAFT
				if inside and not top.has(c):
					ok = false
				if not inside and not (foot[storeys - 1] as Dictionary).has(c):
					ok = false
		if not ok:
			continue
		for z in range(z0 - 1, z0 + SHAFT + 1):
			for x in range(x0 - 1, x0 + SHAFT + 1):
				var c := Vector2i(x, z)
				if z >= z0 and z < z0 + SHAFT and x >= x0 and x < x0 + SHAFT:
					shaft[c] = true
				elif not hall_ring.has(c):
					shaft_ring[c] = true
		var wz := zc + corr + 1 if side == 1 else zc - 2
		@warning_ignore("integer_division")
		var dx := x0 + SHAFT / 2 - 1
		shaft_door = [Vector2i(dx, wz), Vector2i(dx + 1, wz)]
		return


## Storey s's corridor: east from the hall while the storey has its whole band,
## a wall across its end.
func _corridor(s: int) -> void:
	var c := {}
	var inn: Dictionary = inner[s]
	var x := hx1 + 1
	while true:
		var all := true
		for z in range(zc, zc + corr):
			all = all and inn.has(Vector2i(x, z))
		if not all:
			break
		for z in range(zc, zc + corr):
			c[Vector2i(x, z)] = true
		x += 1
	corridor.append(c)
	cx_end.append(x - 1)
	var wl := {}
	for wx in range(hx1 + 2, x):
		for z in [zc - 1, zc + corr]:
			wl[Vector2i(wx, z)] = true
	for z in range(zc - 1, zc + corr + 1):
		wl[Vector2i(x, z)] = true
	for k in hall_ring:
		wl[k] = true
	for k in shaft_ring:
		wl[k] = true
	for k in wl.keys():
		if not inn.has(k):
			wl.erase(k)
	walls.append(wl)


# ---------------------------------------------------------------------------
# Modules along the corridor.

## The corridor wall line of a side (0 south, 1 north).
func _wall_line(side: int) -> int:
	return zc - 1 if side == 0 else zc + corr


## One side of one storey, west to east: a module where one fits (and the
## `fill` chance says so), else a stud on to try again.
func _fill_side(s: int, side: int) -> void:
	var x := hx1 + 2
	while x < int(cx_end[s]):
		var cands := _fits_at(s, side, x) if rng.randf() < float(p.fill) else []
		if cands.is_empty():
			x += 1
			continue
		var pick: Array = _weighted(cands)
		var m: int = pick[0]
		var t: int = pick[1]
		var off: Vector3i = pick[2]
		var td: Dictionary = lib[m].turns[t]
		placed.append({"m": m, "t": t, "off": off, "door": pick[3], "storey": s})
		var x1 := x
		for c: Vector2i in td.cols:
			var w := Vector2i(c.x + off.x, c.y + off.z)
			mod_cols[s][w] = true
			(walls[s] as Dictionary).erase(w)
			x1 = maxi(x1, w.x)
		x = x1 + 1


## Every module and turn that fits with its west edge on `x`: [[m, t, off,
## door index, weight]].
func _fits_at(s: int, side: int, x: int) -> Array:
	var out := []
	var yb := s * pitch
	var line := _wall_line(side)
	var want := 1 if side == 0 else 3
	for m in lib.size():
		var rules: Dictionary = lib[m].rules
		if not ROLES.has(String(rules.role)) or float(rules.weight) <= 0.0:
			continue
		var max_n := int(rules.max)
		if max_n >= 0 and placed.filter(func(pl) -> bool: return int(pl.m) == m).size() >= max_n:
			continue
		match String(rules.storeys):
			"ground":
				if s != 0:
					continue
			"upper":
				if s == 0:
					continue
			"top":
				if s != storeys - 1:
					continue
		for t in 4:
			var td: Dictionary = lib[m].turns[t]
			var lo := Vector2i(1 << 30, 1 << 30)
			var top := 0
			for c: Vector2i in td.cols:
				lo = Vector2i(mini(lo.x, c.x), mini(lo.y, c.y))
				top = maxi(top, (td.cols[c] as Vector2i).y)
			if top - int(td.min_y) > pitch:
				continue
			for ci in (td.conns as Array).size():
				var c: Dictionary = td.conns[ci]
				if String(c.kind) != "door" or int(c.facing) != want or String(c.link) == "off":
					continue
				var at: Vector3i = c.at
				# The door's outer face on the corridor's first row: its wall the line.
				var off := Vector3i(x - lo.x, yb - int(td.min_y), (zc if side == 0 else line - 1) - at.z)
				if at.y + off.y != yb + 1:
					continue
				var dx := at.x + off.x
				if dx < hx1 + 2 or dx + (c.size as Vector2i).x - 1 > int(cx_end[s]):
					continue
				if not _clear(td, off, s, side, line):
					continue
				out.append([m, t, off, ci, float(rules.weight)])
	return out


## The module inside this storey's footprint, on its side of the corridor,
## clear of the hall, the lift, the corridor and every module this storey.
func _clear(td: Dictionary, off: Vector3i, s: int, side: int, line: int) -> bool:
	var f: Dictionary = foot[s]
	for c: Vector2i in td.cols:
		var w := Vector2i(c.x + off.x, c.y + off.z)
		if not f.has(w) or (mod_cols[s] as Dictionary).has(w) or (corridor[s] as Dictionary).has(w):
			return false
		if hall_cells.has(w) or hall_ring.has(w) or shaft.has(w) or shaft_ring.has(w):
			return false
		if (side == 0 and w.y > line) or (side == 1 and w.y < line):
			return false
	return true


func _weighted(cands: Array) -> Array:
	var total := 0.0
	for c in cands:
		total += float(c[4])
	var r := rng.randf() * total
	for c in cands:
		r -= float(c[4])
		if r <= 0.0:
			return c
	return cands[-1]


## A module's doors that are not its corridor door, walled up (RoomGrow's caps);
## its windows glazed in the glass style.
func _caps_and_glass() -> void:
	var g := RoomGrow.new()
	g.lib = lib
	g.placed = placed
	var glass := RoomGrow._glass()
	for idx in placed.size():
		var pl: Dictionary = placed[idx]
		var td: Dictionary = lib[pl.m].turns[pl.t]
		var off: Vector3i = pl.off
		for ci in (td.conns as Array).size():
			var c: Dictionary = td.conns[ci]
			if String(c.kind) != "door" or ci == int(pl.door):
				continue
			var wc := c.duplicate()
			wc.p = idx
			wc.at = (c.at as Vector3i) + off
			adds.append_array(g._cap(wc))
			caps += 1
		if style == "glass" and glass >= 0:
			for wn: Dictionary in td.windows:
				if String(wn.kind) == "window":
					for c: Vector3i in wn.cells:
						adds.append(["plate_1x1", c + off, 0, glass])


# ---------------------------------------------------------------------------
# The stair hall and the way in.

## Storey s's flight: two studs wide, rising STEP plates a stud, east on even
## storeys in the corridor's south lane, west on odd ones in its north lane;
## the slab over it (the next storey's floor, or the roof) cut.
func _flight(s: int) -> void:
	var yb := s * pitch
	var n := ceili(float(pitch) / STEP)
	var lane := zc if s % 2 == 0 else zc + corr - 2
	for i in n:
		var x := hx0 + i if s % 2 == 0 else hx0 + n - 1 - i
		var rise := mini(STEP * (i + 1), pitch)
		for k in 2:
			var y := 0
			while y + 3 <= rise:
				adds.append(["brick_1x1", Vector3i(x, yb + 1 + y, lane + k), colour, 0])
				y += 3
			while y < rise:
				adds.append(["plate_1x1", Vector3i(x, yb + 1 + y, lane + k), colour, 0])
				y += 1
			if rise + 1 + RoomGrow.HEADROOM > pitch:
				pits[s + 1][Vector2i(x, lane + k)] = true


## The way in: two columns of the ground storey's outer wall with the corridor
## or the hall inside them, the corridor's east end first; the lift's door on
## every storey.
func _way_in() -> void:
	var rg: Dictionary = ring[0]
	var reach := {}
	for c in corridor[0]:
		reach[c] = true
	for c in hall_cells:
		reach[c] = true
	var best := []
	var best_x := -(1 << 30)
	for c: Vector2i in rg:
		for dv: Vector2i in DIRS:
			var along := Vector2i(absi(dv.y), absi(dv.x))
			var e := c + along
			if rg.has(e) and reach.has(c - dv) and reach.has(e - dv) and not rg.has(c - dv) \
					and not rg.has(c + dv) and not rg.has(e + dv) and c.x > best_x:
				best = [c, e]
				best_x = c.x
	if best.is_empty():
		return
	var h := mini(DOORWAY.y, pitch - 3)
	for c: Vector2i in best:
		for y in h:
			holes[Vector3i(c.x, 1 + y, c.y)] = true
	doors.append(_door_box(best[0], best[1], 0, h))
	if not shaft_door.is_empty():
		for s in storeys:
			for c: Vector2i in shaft_door:
				for y in h:
					holes[Vector3i(c.x, s * pitch + 1 + y, c.y)] = true
			doors.append(_door_box(shaft_door[0], shaft_door[1], s * pitch, h))


func _door_box(a: Vector2i, b: Vector2i, yb: int, h: int) -> Array:
	return [Vector3i(mini(a.x, b.x), yb + 1, mini(a.y, b.y)),
			Vector3i(absi(a.x - b.x) + 1, h, absi(a.y - b.y) + 1)]


# ---------------------------------------------------------------------------
# The shell's own rooms, walls, floors.

## Storey s's corridor with its hall, and its filler rooms: what of the storey no
## module, hall, lift or corridor has, split where it runs past `room_max`
## either way, each with a doorway to what is already reached.
func _rooms_of(s: int) -> void:
	var yb := s * pitch
	var wl: Dictionary = walls[s]
	var cols := []
	for c in hall_cells:
		cols.append(c)
	for c in corridor[s]:
		cols.append(c)
	rooms.append({"kind": "corridor", "seed": Vector3i(hx1, yb + 1, zc + 1), "cols": cols,
			"floor_y": yb, "ceil_y": yb + pitch})
	var free := {}
	for c: Vector2i in inner[s]:
		if wl.has(c) or hall_cells.has(c) or shaft.has(c) or (corridor[s] as Dictionary).has(c) \
				or (mod_cols[s] as Dictionary).has(c):
			continue
		free[c] = true
	# Long runs split: a wall across every room_max studs, either way.
	var step := int(p.room_max)
	var pieces := []
	for comp in _components(free):
		var bb := _box(_cell_set(comp))
		var lo: Vector2i = bb[0]
		var size: Vector2i = bb[1]
		var left := {}
		for c: Vector2i in comp:
			var cut_x := size.x > step + 2 and (c.x - lo.x) % (step + 1) == step and c.x < lo.x + size.x - 2
			var cut_z := size.y > step + 2 and (c.y - lo.y) % (step + 1) == step and c.y < lo.y + size.y - 2
			if cut_x or cut_z:
				wl[c] = true
			else:
				left[c] = true
		pieces.append_array(_components(left))
	# Doorways out from what is reached, a round at a time, until none is left.
	var reached := {}
	for c in cols:
		reached[c] = true
	var h := mini(DOORWAY.y, pitch - 3)
	var todo := pieces.filter(func(pc) -> bool: return (pc as Array).size() >= 4)
	var progress := true
	while progress and not todo.is_empty():
		progress = false
		for pc: Array in todo.duplicate():
			var door := _doorway(_cell_set(pc), reached, wl, s)
			if door.is_empty():
				continue
			for c: Vector2i in door:
				for y in h:
					holes[Vector3i(c.x, yb + 1 + y, c.y)] = true
			doors.append(_door_box(door[0], door[1], yb, h))
			for c in pc:
				reached[c] = true
			rooms.append({"kind": "office", "seed": Vector3i(pc[0].x, yb + 1, pc[0].y), "cols": pc,
					"floor_y": yb, "ceil_y": yb + pitch})
			todo.erase(pc)
			progress = true


func _cell_set(cells: Array) -> Dictionary:
	var out := {}
	for c in cells:
		out[c] = true
	return out


## Two wall columns side by side, each with the piece on one side and what is
## reached on the other, in the shell's own inner walls (not the outer wall, a
## module, the lift's): the middle pair. [] for none.
func _doorway(piece: Dictionary, reached: Dictionary, wl: Dictionary, s: int) -> Array:
	var pairs := []
	for c: Vector2i in wl:
		if (ring[s] as Dictionary).has(c) or shaft_ring.has(c):
			continue
		for dv: Vector2i in [Vector2i(1, 0), Vector2i(0, 1)]:
			var along := Vector2i(dv.y, dv.x)
			var e := c + along
			if not wl.has(e) or (ring[s] as Dictionary).has(e) or shaft_ring.has(e):
				continue
			for sg in [1, -1]:
				var a: Vector2i = dv * sg
				if piece.has(c + a) and piece.has(e + a) and reached.has(c - a) and reached.has(e - a):
					pairs.append([c, e])
	if pairs.is_empty():
		return []
	pairs.sort_custom(func(x, y) -> bool: return x[0].x < y[0].x or (x[0].x == y[0].x and x[0].y < y[0].y))
	@warning_ignore("integer_division")
	return pairs[pairs.size() / 2]


func _components(cells: Dictionary) -> Array:
	var seen := {}
	var out := []
	var keys := cells.keys()
	keys.sort()
	for start: Vector2i in keys:
		if seen.has(start):
			continue
		var comp := []
		var todo: Array[Vector2i] = [start]
		seen[start] = true
		while not todo.is_empty():
			var c: Vector2i = todo.pop_back()
			comp.append(c)
			for dv: Vector2i in DIRS:
				var n: Vector2i = c + dv
				if cells.has(n) and not seen.has(n):
					seen[n] = true
					todo.append(n)
		comp.sort()
		out.append(comp)
	return out


## The straight runs of a set of wall columns: along x first (two or more),
## the rest along z. [[cells in order, axis]].
static func _runs(cells: Dictionary) -> Array:
	var out := []
	var used := {}
	var keys := cells.keys()
	keys.sort_custom(func(a, b) -> bool: return a.y < b.y or (a.y == b.y and a.x < b.x))
	for c: Vector2i in keys:
		if used.has(c) or cells.has(c - Vector2i(1, 0)) and not used.has(c - Vector2i(1, 0)):
			continue
		var run := [c]
		var n := c + Vector2i(1, 0)
		while cells.has(n) and not used.has(n):
			run.append(n)
			n += Vector2i(1, 0)
		if run.size() >= 2:
			for r in run:
				used[r] = true
			out.append([run, "x"])
	keys.sort_custom(func(a, b) -> bool: return a.x < b.x or (a.x == b.x and a.y < b.y))
	for c: Vector2i in keys:
		if used.has(c):
			continue
		var run := [c]
		used[c] = true
		var n := c + Vector2i(0, 1)
		while cells.has(n) and not used.has(n):
			run.append(n)
			used[n] = true
			n += Vector2i(0, 1)
		out.append([run, "z"])
	return out


## Windows in the outer wall: along each straight face every `window_every`
## studs, not at its ends, not where a module stands.
func _windows(s: int) -> void:
	var yb := s * pitch
	var y0 := yb + 1 + SILL
	var h := mini(WINDOW.y, pitch - 2 - SILL)
	if h < 2:
		return
	var glass := RoomGrow._glass()
	var every := maxi(int(p.window_every), WINDOW.x + 1)
	var f: Dictionary = foot[s]
	var rg: Dictionary = ring[s]
	# A face: ring columns with the outside straight out from them one way.
	for out_dir: Vector2i in DIRS:
		var face := {}
		for c: Vector2i in rg:
			if not f.has(c + out_dir) and f.has(c - out_dir) and not rg.has(c - out_dir):
				face[c] = true
		for run in _runs(face):
			var cells: Array = run[0]
			var a := 2
			while a + WINDOW.x <= cells.size() - 2:
				var hole := []
				var ok := true
				for x in WINDOW.x:
					var c: Vector2i = cells[a + x]
					ok = ok and not (mod_cols[s] as Dictionary).has(c)
					for y in h:
						var v := Vector3i(c.x, y0 + y, c.y)
						ok = ok and not holes.has(v)
						hole.append(v)
				if ok:
					for v: Vector3i in hole:
						holes[v] = true
						if style == "glass" and glass >= 0:
							adds.append(["plate_1x1", v, 0, glass])
				a += every


## Storey s's walls: the outer ring and the inner walls (hall, lift, corridor,
## splits), never in a module's columns -- each run a course at a time.
func _walls(s: int) -> void:
	var all := {}
	for c in ring[s]:
		all[c] = true
	for c in walls[s]:
		all[c] = true
	for c in mod_cols[s]:
		all.erase(c)
	for run in _runs(all):
		_course_line(s, run[0], String(run[1]))


## One line of wall up a storey: courses of bricks in a running bond over the
## cells that are free all three plates, plates where they are not.
func _course_line(s: int, cells: Array, axis: String) -> void:
	var yb := s * pitch
	var free := func(c: Vector2i, y: int) -> bool:
		return not holes.has(Vector3i(c.x, y, c.y))
	var y := yb + 1
	var course := 0
	while y < yb + pitch:
		var brick := y + 3 <= yb + pitch
		var i := 0
		while i < cells.size():
			var c: Vector2i = cells[i]
			var whole: bool = brick and free.call(c, y) and free.call(c, y + 1) and free.call(c, y + 2)
			if not whole:
				for k in (3 if brick else 1):
					if free.call(c, y + k):
						adds.append(["plate_1x1", Vector3i(c.x, y + k, c.y), colour, 0])
				i += 1
				continue
			var n := 1
			while i + n < cells.size():
				var e: Vector2i = cells[i + n]
				if not (free.call(e, y) and free.call(e, y + 1) and free.call(e, y + 2)):
					break
				n += 1
			var piece := 1
			for r: int in WALL_RUNS:
				if r <= n and not (course % 2 == 1 and i == 0 and r > 1):
					piece = r
					break
			var part := "brick_1x1" if piece == 1 else "brick_1x%d_%s" % [piece, axis]
			adds.append([part, Vector3i(c.x, y, c.y), colour, 0])
			i += piece
		y += 3 if brick else 1
		course += 1


## Storey s's floor (s == storeys: the roof): its footprint and the one under
## it (a setback's terrace is the storey below's roof), but not its modules'
## columns (they have floors of their own), the cut over the flight below, or
## the lift shaft between the ground and the top -- in the biggest square
## plates that fit.
func _slab(s: int) -> void:
	var y := s * pitch
	var cells := {}
	for c in foot[s]:
		cells[c] = true
	if s > 0:
		for c in foot[s - 1]:
			cells[c] = true
	for c in mod_cols[s]:
		cells.erase(c)
	for c in pits[s]:
		cells.erase(c)
	if s > 0 and s < storeys:
		for c in shaft:
			cells.erase(c)
	var bb := _box(cells) if not cells.is_empty() else [Vector2i.ZERO, Vector2i.ZERO]
	var lo: Vector2i = bb[0]
	var size: Vector2i = bb[1]
	for n in [4, 2, 1]:
		for z in range(lo.y, lo.y + size.y):
			for x in range(lo.x, lo.x + size.x):
				var all := true
				for dz in n:
					for dx in n:
						all = all and cells.has(Vector2i(x + dx, z + dz))
				if not all:
					continue
				for dz in n:
					for dx in n:
						cells.erase(Vector2i(x + dx, z + dz))
				adds.append(["plate_%dx%d" % [n, n], Vector3i(x, y, z), colour, 0])


## A rail a brick high round the roof and round each terrace a setback leaves:
## the outer wall of the storey below where the storey above does not stand.
func _rails() -> void:
	for s in range(1, storeys + 1):
		var y := s * pitch + 1
		var over: Dictionary = foot[s]
		for c: Vector2i in ring[s - 1]:
			if not over.has(c):
				adds.append(["brick_1x1", Vector3i(c.x, y, c.y), colour, 0])
