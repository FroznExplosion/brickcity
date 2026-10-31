class_name RoomShell
extends RefCounted

## The set-by-shell generator (Docs/RoomModules.md section 4, stage 6): a
## tower's outside fixed first -- a box `width` x `depth` studs, `storeys`
## high -- and its inside split into rooms and filled with modules from the
## library (RoomModules).
##
##   var lib := RoomModules.library()
##   var made := RoomShell.generate(lib, {"seed": 3, "width": 44, "depth": 28, "storeys": 6})
##   made.recipe   # the tower as one build
##
## Every storey the same plan, seen from above (west at the left):
##
##   +--------+------+--------+-----+
##   |        |module| filler |     |   north side: rooms on the corridor
##   |  stair +--  --+---  ---+-----+
##   |  hall    corridor             |
##   |  ====  +--  --+--  ----+-----+
##   |        |module| module |     |   south side
##   +--------+------+--------+-----+
##
## The stair hall at the west end: a straight flight a storey, two studs wide,
## two plates a step, the flights turning back storey to storey in two lanes,
## the slab over each flight cut; the top one comes up through the roof (the
## finish). The way in is a doorway in the hall's south wall on the ground.
## Along the corridor, each side filled west to east with modules whose door
## faces the corridor, their own walls standing in the shell's; what no module
## fits is a filler room (split where it is long) with a doorway off the
## corridor. A module's other doors are walled up. Windows every few studs in
## the shell's own outer wall, one window style a tower.
##
## Same seed and library, same tower. Laid by RoomGrow.lay, as a grown
## building is.

## The shell's defaults. `pitch`: plates a storey, floor to floor (0: the
## height most room modules have); `corridor`: studs wide (4: two flights side
## by side in the hall); `room_max`: studs a filler room runs before a wall
## splits it; `window_every`: studs from one window to the next; `fill`: the
## chance a gap along the corridor gets a module rather than filler.
const PARAMS := {"seed": 1, "width": 44, "depth": 28, "storeys": 4, "pitch": 0, "corridor": 4,
		"room_max": 12, "window_every": 5, "fill": 0.85}
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

var lib: Array
var p: Dictionary
var rng := RandomNumberGenerator.new()
var w := 0
var d := 0
var storeys := 0
var pitch := 0
var corr := 0
var zc := 0             ## the corridor's south row
var hall := 0           ## the stair hall's inside length, x 1..hall
var xh := 0             ## the hall's east wall line
var placed := []        ## [{m, t, off}], as RoomGrow plans have them
var mod_cols := []      ## per storey: Vector2i -> true, the columns of its modules
var spans := []         ## per storey: [[x0, x1, side]], each module's run along the corridor
var holes := {}         ## Vector3i -> true: doorways, windows, the way in, kept open
var pits := []          ## per storey: Vector2i -> true, the slab cells cut over the flight below
var adds := []          ## [[part, cell, colour, material]]
var rooms := []         ## [{kind, seed, cols, floor_y, ceil_y}] the shell's own spaces
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


func _generate(library: Array, params: Dictionary) -> Dictionary:
	lib = library
	p = PARAMS.duplicate()
	p.merge(params, true)
	rng.seed = hash("shell %d" % int(p.seed))
	w = int(p.width)
	d = int(p.depth)
	storeys = maxi(int(p.storeys), 1)
	corr = maxi(int(p.corridor), 4)
	pitch = int(p.pitch) if int(p.pitch) > 0 else pitch_of(lib)
	var steps := ceili(float(pitch) / STEP)
	hall = steps + 2
	xh = hall + 1
	@warning_ignore("integer_division")
	zc = (d - corr) / 2
	if w < xh + 8 or zc < 5 or pitch < DOORWAY.y + 3:
		return {"ok": false, "why": "the shell is too small: at least %d x %d studs, %d plates a storey" % [
				xh + 8, corr + 10, DOORWAY.y + 3]}
	style = RoomGrow.WINDOW_STYLES[rng.randi_range(0, RoomGrow.WINDOW_STYLES.size() - 1)]
	for s in storeys + 1:
		mod_cols.append({})
		spans.append([])
		pits.append({})
	for s in storeys:
		for side in [0, 1]:
			_fill_side(s, side)
	if not placed.is_empty():
		colour = int(lib[placed[0].m].turns[placed[0].t].colour)
	_caps_and_glass()
	for s in storeys:
		_flight(s)
	# The way in: a doorway in the hall's south wall on the ground.
	@warning_ignore("integer_division")
	var door_x := maxi(1, hall / 2)
	for x in DOORWAY.x:
		for y in DOORWAY.y:
			holes[Vector3i(door_x + x, 1 + y, 0)] = true
	for s in storeys:
		_rooms_of(s)
		_windows(s)
		_walls(s)
	for s in storeys + 1:
		_slab(s)
	_parapet()
	var g_stats := {"modules": placed.size(), "storeys": storeys, "pitch": pitch, "caps": caps,
			"rooms": rooms.size(), "width": w, "depth": d}
	var plan := {"ok": true, "why": "", "seed": int(p.seed), "ground_y": 0, "placed": placed,
			"joins": [], "path": [], "entrance": {}, "exit": {}, "caps": [], "cuts": [], "adds": adds,
			"window_style": style, "stats": g_stats, "at": Vector3i(1, 0, 1)}
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
# Modules along the corridor.

## The corridor wall line of a side (0 south, 1 north) and the facing a
## module's door has to have to open on the corridor.
func _wall_line(side: int) -> int:
	return zc - 1 if side == 0 else zc + corr


## One side of one storey, west to east: a module where one fits (and the
## `fill` chance says so), else a stud on to try again.
func _fill_side(s: int, side: int) -> void:
	var x := xh + 1
	while x < w - 2:
		var cands := _fits_at(s, side, x) if rng.randf() < float(p.fill) else []
		if cands.is_empty():
			x += 1
			continue
		var pick: Array = _weighted(cands)
		var m: int = pick[0]
		var t: int = pick[1]
		var off: Vector3i = pick[2]
		var td: Dictionary = lib[m].turns[t]
		var idx := placed.size()
		placed.append({"m": m, "t": t, "off": off, "door": pick[3], "storey": s})
		var x1 := x
		for c: Vector2i in td.cols:
			mod_cols[s][Vector2i(c.x + off.x, c.y + off.z)] = true
			x1 = maxi(x1, c.x + off.x)
		(spans[s] as Array).append([x, x1, side, idx])
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
			var hi := Vector2i(-(1 << 30), -(1 << 30))
			var top := 0
			for c: Vector2i in td.cols:
				lo = Vector2i(mini(lo.x, c.x), mini(lo.y, c.y))
				hi = Vector2i(maxi(hi.x, c.x), maxi(hi.y, c.y))
				top = maxi(top, (td.cols[c] as Vector2i).y)
			if top - int(td.min_y) > pitch:
				continue
			for ci in (td.conns as Array).size():
				var c: Dictionary = td.conns[ci]
				if String(c.kind) != "door" or int(c.facing) != want or String(c.link) == "off":
					continue
				var at: Vector3i = c.at
				var off := Vector3i(x - lo.x, yb - int(td.min_y), 0)
				# The door's outer face on the corridor's first row: its wall the line.
				off.z = (zc if side == 0 else line - 1) - at.z
				if at.y + off.y != yb + 1:
					continue
				var z0 := lo.y + off.z
				var z1 := hi.y + off.z
				var x1 := hi.x + off.x
				if x1 > w - 1:
					continue
				if side == 0 and (z0 < 0 or z1 > line):
					continue
				if side == 1 and (z0 < line or z1 > d - 1):
					continue
				var dx := at.x + off.x
				if dx < xh + 1 or dx + (c.size as Vector2i).x - 1 > w - 2:
					continue
				if not _clear(td, off, s):
					continue
				out.append([m, t, off, ci, float(rules.weight)])
	return out


## Nothing of the module in another module's columns this storey.
func _clear(td: Dictionary, off: Vector3i, s: int) -> bool:
	for c: Vector2i in td.cols:
		if (mod_cols[s] as Dictionary).has(Vector2i(c.x + off.x, c.y + off.z)):
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
# The stair hall.

## Storey s's flight: two studs wide, rising STEP plates a stud, east on even
## storeys in the corridor's south lane, west on odd ones in its north lane;
## the slab over it (the next storey's floor, or the roof) cut.
func _flight(s: int) -> void:
	var yb := s * pitch
	var n := ceili(float(pitch) / STEP)
	var lane := zc if s % 2 == 0 else zc + corr - 2
	for i in n:
		var x := 1 + i if s % 2 == 0 else n - i
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


# ---------------------------------------------------------------------------
# The shell's own rooms, walls, floors.

## Storey s's corridor with its hall, and its filler rooms: what of each side
## no module has, split where it runs past `room_max`, a doorway each off the
## corridor where there is room for one.
func _rooms_of(s: int) -> void:
	var yb := s * pitch
	var cols := []
	for z in range(1, d - 1):
		for x in range(1, hall + 1):
			cols.append(Vector2i(x, z))
	for z in range(zc, zc + corr):
		for x in range(xh, w - 1):
			cols.append(Vector2i(x, z))
	var corridor := {"kind": "corridor", "seed": Vector3i(w - 2, yb + 1, zc), "cols": cols,
			"floor_y": yb, "ceil_y": yb + pitch, "storey": s, "split": []}
	rooms.append(corridor)
	for side in [0, 1]:
		var line := _wall_line(side)
		var z_lo := 1 if side == 0 else line + 1
		var z_hi := line - 1 if side == 0 else d - 2
		var free := {}
		for z in range(z_lo, z_hi + 1):
			for x in range(xh + 1, w - 1):
				if not (mod_cols[s] as Dictionary).has(Vector2i(x, z)):
					free[Vector2i(x, z)] = true
		for comp in _components(free):
			var x0 := 1 << 30
			var x1 := -(1 << 30)
			for c: Vector2i in comp:
				x0 = mini(x0, c.x)
				x1 = maxi(x1, c.x)
			# Long runs split: a wall across every room_max studs.
			var splits := []
			var cut := x0 + int(p.room_max)
			while cut < x1 - 2:
				splits.append(cut)
				cut += int(p.room_max) + 1
			var left := {}
			for c: Vector2i in comp:
				if splits.has(c.x):
					(corridor.split as Array).append(Vector3i(c.x, side, c.y))
				else:
					left[c] = true
			for piece in _components(left):
				_filler(s, side, piece)


## A filler room: its doorway off the corridor (the middle two cells it has on
## the corridor wall), or none -- a closed pocket behind a module.
func _filler(s: int, side: int, piece: Array) -> void:
	var yb := s * pitch
	var line := _wall_line(side)
	var row := line - 1 if side == 0 else line + 1
	var on := []
	for c: Vector2i in piece:
		if c.y == row:
			on.append(c.x)
	on.sort()
	var pairs := []
	for x in on:
		if on.has(x + 1):
			pairs.append(x)
	if pairs.is_empty() or piece.size() < 6:
		return
	@warning_ignore("integer_division")
	var x0: int = pairs[pairs.size() / 2]
	var h := mini(DOORWAY.y, pitch - 3)
	for x in DOORWAY.x:
		for y in h:
			holes[Vector3i(x0 + x, yb + 1 + y, line)] = true
	rooms.append({"kind": "office", "seed": Vector3i(piece[0].x, yb + 1, piece[0].y), "cols": piece,
			"floor_y": yb, "ceil_y": yb + pitch, "storey": s})


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
			for dv in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var n: Vector2i = c + dv
				if cells.has(n) and not seen.has(n):
					seen[n] = true
					todo.append(n)
		comp.sort()
		out.append(comp)
	return out


## Windows in the shell's own outer wall: every `window_every` studs along each
## face, not at a corner, not where a module's wall stands in it.
func _windows(s: int) -> void:
	var yb := s * pitch
	var y0 := yb + 1 + SILL
	var h := mini(WINDOW.y, pitch - 2 - SILL)
	if h < 2:
		return
	var glass := RoomGrow._glass()
	var every := maxi(int(p.window_every), WINDOW.x + 1)
	var faces := [[Vector3i(0, 0, 0), Vector3i(1, 0, 0), w], [Vector3i(0, 0, d - 1), Vector3i(1, 0, 0), w],
			[Vector3i(0, 0, 0), Vector3i(0, 0, 1), d], [Vector3i(w - 1, 0, 0), Vector3i(0, 0, 1), d]]
	for f in faces:
		var origin: Vector3i = f[0]
		var along: Vector3i = f[1]
		var length: int = f[2]
		var a := 3
		while a + WINDOW.x <= length - 3:
			var cells := []
			var ok := true
			for x in WINDOW.x:
				for y in h:
					var c: Vector3i = origin + along * (a + x) + Vector3i(0, y0 + y, 0)
					ok = ok and not (mod_cols[s] as Dictionary).has(Vector2i(c.x, c.z)) and not holes.has(c)
					cells.append(c)
			if ok:
				for c: Vector3i in cells:
					holes[c] = true
					if style == "glass" and glass >= 0:
						adds.append(["plate_1x1", c, 0, glass])
			a += every


## Storey s's walls: the outer ring, the hall's east wall, the corridor walls
## where no module stands, the filler rooms' splits -- each a course at a time.
func _walls(s: int) -> void:
	var lines := []
	var xs := func(x0: int, x1: int, z: int) -> Array:
		var out := []
		for x in range(x0, x1 + 1):
			out.append(Vector2i(x, z))
		return out
	var zs := func(z0: int, z1: int, x: int) -> Array:
		var out := []
		for z in range(z0, z1 + 1):
			out.append(Vector2i(x, z))
		return out
	lines.append([xs.call(0, w - 1, 0), "x"])
	lines.append([xs.call(0, w - 1, d - 1), "x"])
	lines.append([zs.call(1, d - 2, 0), "z"])
	lines.append([zs.call(1, d - 2, w - 1), "z"])
	lines.append([zs.call(1, zc - 1, xh), "z"])
	lines.append([zs.call(zc + corr, d - 2, xh), "z"])
	for side in [0, 1]:
		var line := _wall_line(side)
		var run := []
		for x in range(xh + 1, w - 1):
			var mine := false
			for sp: Array in spans[s]:
				if int(sp[2]) == side and x >= int(sp[0]) and x <= int(sp[1]):
					mine = true
			if mine:
				if not run.is_empty():
					lines.append([run, "x"])
				run = []
			else:
				run.append(Vector2i(x, line))
		if not run.is_empty():
			lines.append([run, "x"])
	var by_x := {}
	for room: Dictionary in rooms:
		if int(room.get("storey", -1)) == s and room.has("split"):
			for c: Vector3i in room.split:
				var key := Vector2i(c.x, c.y)
				if not by_x.has(key):
					by_x[key] = []
				(by_x[key] as Array).append(Vector2i(c.x, c.z))
	for key in by_x:
		lines.append([by_x[key], "z"])
	for ln in lines:
		_course_line(s, ln[0], String(ln[1]))


## One line of wall up a storey: courses of bricks in a running bond over the
## cells that are free all three plates, plates where they are not.
func _course_line(s: int, cells: Array, axis: String) -> void:
	var yb := s * pitch
	var mine: Dictionary = mod_cols[s]
	var free := func(c: Vector2i, y: int) -> bool:
		return not mine.has(c) and not holes.has(Vector3i(c.x, y, c.y))
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
			# The run of whole cells from here.
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


## Storey s's floor (s == storeys: the roof): the whole footprint but its
## modules' columns (they have floors of their own) and the cut over the flight
## below, in the biggest square plates that fit.
func _slab(s: int) -> void:
	var y := s * pitch
	var cells := {}
	for z in d:
		for x in w:
			var c := Vector2i(x, z)
			if not (mod_cols[s] as Dictionary).has(c) and not (pits[s] as Dictionary).has(c):
				cells[c] = true
	for n in [4, 2, 1]:
		for z in d:
			for x in w:
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


## A rail round the roof a brick high, in the outer wall's line.
func _parapet() -> void:
	var y := storeys * pitch + 1
	var ring := []
	for x in w:
		ring.append([Vector2i(x, 0), "x"])
		ring.append([Vector2i(x, d - 1), "x"])
	for z in range(1, d - 1):
		ring.append([Vector2i(0, z), "z"])
		ring.append([Vector2i(w - 1, z), "z"])
	for r in ring:
		var c: Vector2i = r[0]
		adds.append(["brick_1x1", Vector3i(c.x, y, c.y), colour, 0])
