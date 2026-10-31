class_name RoomGrow
extends RefCounted

## The grow-by-connectors generator (Docs/RoomModules.md sections 3 and 5):
## modules from the library (RoomModules) put together door to door into one
## building with a start and a finish and a path between them, then laid as
## bricks (lay).
##
##   var plan := RoomGrow.grow(RoomModules.library(), {"seed": 7, "rooms": 10, "path": 4})
##   var recipe := RoomGrow.lay(lib, plan)
##
## Everything comes from (seed, library): the same seed grows the same building.
##
## A placement is {m: module index, t: quarter turns, off: Vector3i}: the turned
## module's cells moved by `off`. Two door connectors join where the second's
## outer face is the first's last wall cell (b.at == a.at - a's facing), facing
## each other, the same size: walls back to back, the doorway through both. A
## stair link up joins a stair link down over it, the upper module's lowest
## brick in that column on the lower one's highest.

## The grow's defaults. `path`: modules between the start and the finish;
## `rooms`: modules in all; `tries`: how many fits it may try before it gives up;
## `balcony`: the chance a balcony spot gets one; `hang`: the chance a branch
## grows off a hang spot rather than a door; `doors`: the chance a joined doorway
## (and the way in and out) gets a door (BuildDoors).
const PARAMS := {"seed": 1, "rooms": 10, "path": 3, "tries": 4000, "balcony": 0.5, "hang": 0.3,
		"doors": 1.0}
## Window styles, one per building: what the window holes of every module are.
const WINDOW_STYLES := ["open", "glass"]
## A cut facade window: studs across, plates up.
const FACADE_WINDOW := Vector2i(2, 6)
## A balcony: studs along the wall, studs out; its rail a brick high.
const BALCONY := Vector2i(4, 3)
## Headroom over a stair's step before the ceiling over it is cut, in plates.
const HEADROOM := 15
## A stair's rise a step, in plates, the ones it tries in order: two plates
## (StaircaseRecipe.STEP_PLATES, the workshop's own stairs), a brick where the
## room has no floor for the longer flight.
const STEP_RISES := [2, 3]
## The bricks a cap is laid in, longest first: a course of them along the
## doorway, every other course started with a short one (a running bond).
const CAP_RUNS := [6, 4, 2, 1]

var lib: Array
var p: Dictionary
var rng := RandomNumberGenerator.new()
var placed := []        ## [{m, t, off}]
var occ := {}           ## Vector2i -> [[y0, y1, placement, top]]
var counts := {}        ## module index -> how many placed
var open := []          ## every connector of every placement, world cells: see _conn
var joins := []         ## [{a: open index, b: open index, loop}]
var budget := 0
var ground_y := 0
var path := []          ## placement indices, start to finish
var entrance := -1      ## open index of the start's way in
var exit := -1          ## open index of the finish's way out
var _starts := []       ## modules that can start a building (role or link)
var _finishes := []     ## and finish one
var _hangers := false   ## the library has modules made to hang off a wall (role hang)


## A plan: {ok, why, placed, joins: [{a: [placement, kind, at...]}], path,
## entrance, exit, caps, cuts: [Vector3i], adds: [[part, cell, colour, material]],
## window_style, balconies, stats}. Never fails silently: `ok` false says why.
static func grow(library: Array, params := {}) -> Dictionary:
	var g := RoomGrow.new()
	return g._grow(library, params)


func _grow(library: Array, params: Dictionary) -> Dictionary:
	lib = library
	p = PARAMS.duplicate()
	p.merge(params, true)
	rng.seed = hash(int(p.seed))
	budget = int(p.tries)
	if lib.is_empty():
		return {"ok": false, "why": "no modules: turn Module on for a build with its rooms found, and save it"}
	_starts = _with_role("start")
	_finishes = _with_role("finish")
	_hangers = not _with_role("hang").is_empty()
	var starts := _starts.duplicate()
	if starts.is_empty():
		starts = range(lib.size())
	# The path first, as long as asked, shorter if it must be.
	var made := false
	for want in range(int(p.path), -1, -1):
		_reset()
		var s: int = starts[rng.randi_range(0, starts.size() - 1)]
		_place(s, rng.randi_range(0, 3), Vector3i.ZERO)
		ground_y = int(lib[s].turns[placed[0].t].min_y)
		entrance = _reserved_of(0, "start")
		if _extend(0, want):
			made = true
			break
		if budget <= 0:
			break
	if not made:
		return {"ok": false, "why": "no path from a start to a finish fits (tries ran out)"}
	path = range(placed.size())
	_mins()
	_branches()
	var loops := _loops()
	return _finish(loops)


func _reset() -> void:
	placed.clear()
	occ.clear()
	counts.clear()
	open.clear()
	joins.clear()
	entrance = -1
	exit = -1


func _with_role(role: String) -> Array:
	var out := []
	for i in lib.size():
		var m: Dictionary = lib[i]
		if String(m.rules.role) == role:
			out.append(i)
			continue
		for c in m.turns[0].conns:
			if String(c.link) == role:
				out.append(i)
				break
	return out


# ---------------------------------------------------------------------------
# Placing.

## A module's turn at `off`, its connectors open. Returns its index.
func _place(m: int, t: int, off: Vector3i) -> int:
	var td: Dictionary = lib[m].turns[t]
	var idx := placed.size()
	placed.append({"m": m, "t": t, "off": off})
	counts[m] = int(counts.get(m, 0)) + 1
	var top := String(lib[m].rules.storeys) == "top"
	for c: Vector2i in td.cols:
		var w := Vector2i(c.x + off.x, c.y + off.z)
		var s: Vector2i = td.cols[c]
		if not occ.has(w):
			occ[w] = []
		(occ[w] as Array).append([s.x + off.y, s.y + off.y, idx, top])
	for ci in (td.conns as Array).size():
		open.append(_conn(idx, td.conns[ci], off))
	for mk: Dictionary in td.marks:
		if String(mk.kind) == "hang":
			open.append(_hang(idx, mk, off))
	return idx


## A connector of a placement, in world cells, as the open list keeps it.
func _conn(idx: int, c: Dictionary, off: Vector3i) -> Dictionary:
	return {"p": idx, "kind": String(c.kind), "at": (c.at as Vector3i) + off, "facing": int(c.facing),
			"size": c.size, "link": String(c.link), "depth": int(c.depth), "space": int(c.space),
			"base": int(c.get("base", 0)) + off.y, "top": int(c.get("top", 0)) + off.y,
			"wall": c.get("wall", []), "used": false, "dead": false}


## A hang spot as an open connector: its outer face at the room's floor row, any
## size; a module joined there gets a doorway cut through the wall.
func _hang(idx: int, mk: Dictionary, off: Vector3i) -> Dictionary:
	var fd: Vector2i = StructureSpaces.FACINGS[int(mk.facing)]
	var at: Vector3i = (mk.at as Vector3i) + Vector3i(fd.x, 0, fd.y) * int(mk.depth)
	at.y = int(mk.floor_y) + 1
	return {"p": idx, "kind": "hang", "at": at + off, "facing": int(mk.facing), "size": Vector2i.ZERO,
			"link": "auto", "depth": int(mk.depth), "space": int(mk.space),
			"room_h": int(mk.ceil_y) - int(mk.floor_y) - 1, "base": 0, "top": 0, "used": false, "dead": false}


## Take back the last placement (the path's backtracking).
func _unplace() -> void:
	var idx := placed.size() - 1
	var m: int = placed[idx].m
	counts[m] = int(counts[m]) - 1
	var td: Dictionary = lib[m].turns[placed[idx].t]
	var off: Vector3i = placed[idx].off
	for c: Vector2i in td.cols:
		var w := Vector2i(c.x + off.x, c.y + off.z)
		occ[w] = (occ[w] as Array).filter(func(s) -> bool: return int(s[2]) != idx)
	while not open.is_empty() and int(open[-1].p) == idx:
		open.pop_back()
	while not joins.is_empty() and int(joins[-1].b) >= open.size():
		open[joins[-1].a].used = false
		joins.pop_back()
	placed.pop_back()


## Does module m turned t fit at `off`: nothing of it in anything placed, its
## storey rule kept, nothing over a top module or a top module under anything?
func _fits(m: int, t: int, off: Vector3i) -> bool:
	var rules: Dictionary = lib[m].rules
	var td: Dictionary = lib[m].turns[t]
	var max_n := int(rules.max)
	if max_n >= 0 and int(counts.get(m, 0)) >= max_n:
		return false
	var low := int(td.min_y) + off.y
	match String(rules.storeys):
		"ground":
			if low != ground_y:
				return false
		"upper", "top":
			if low <= ground_y:
				return false
	var top := String(rules.storeys) == "top"
	for c: Vector2i in td.cols:
		var w := Vector2i(c.x + off.x, c.y + off.z)
		if not occ.has(w):
			continue
		var s: Vector2i = td.cols[c]
		var y0 := s.x + off.y
		var y1 := s.y + off.y
		for o in occ[w]:
			if y0 < int(o[1]) and int(o[0]) < y1:
				return false
			if bool(o[3]) and y0 >= int(o[1]):
				return false
			if top and int(o[0]) >= y1:
				return false
	return true


## Every way a module can join open connector `oi`: [[m, t, ci, weight]], with
## `roles` the module roles allowed (and a finish's finish link only on a finish).
func _candidates(oi: int, roles: Array, only := -1) -> Array:
	var c: Dictionary = open[oi]
	var out := []
	for m in lib.size():
		if only >= 0 and m != only:
			continue
		var role := String(lib[m].rules.role)
		var is_finish := _finishes.has(m)
		var is_start := _starts.has(m)
		if roles.has("finish"):
			if not is_finish:
				continue
		elif is_finish or is_start or not roles.has(role):
			continue
		var weight := float(lib[m].rules.weight)
		if weight <= 0.0:
			continue
		for t in 4:
			var conns: Array = lib[m].turns[t].conns
			for ci in conns.size():
				var d: Dictionary = conns[ci]
				if String(d.link) != "auto":
					continue
				if _matches(c, d):
					out.append([m, t, ci, weight])
	return out


func _matches(a: Dictionary, b: Dictionary) -> bool:
	match String(a.kind):
		"door":
			return String(b.kind) == "door" and int(b.facing) == (int(a.facing) + 2) % 4 and b.size == a.size
		"hang":
			return String(b.kind) == "door" and int(b.facing) == (int(a.facing) + 2) % 4 \
					and (b.size as Vector2i).y <= int(a.room_h)
		"stair_up":
			return String(b.kind) == "stair_down"
		"stair_down":
			return String(b.kind) == "stair_up"
	return false


## Where module m turned t sits to join open connector `oi` with its connector ci.
func _offset(oi: int, m: int, t: int, ci: int) -> Vector3i:
	var a: Dictionary = open[oi]
	var b: Dictionary = lib[m].turns[t].conns[ci]
	match String(a.kind):
		"stair_up":
			return Vector3i(a.at.x - b.at.x, int(a.top) - int(b.base), a.at.z - b.at.z)
		"stair_down":
			return Vector3i(a.at.x - b.at.x, int(a.base) - int(b.top), a.at.z - b.at.z)
	var fd: Vector2i = StructureSpaces.FACINGS[int(a.facing)]
	return (a.at as Vector3i) - Vector3i(fd.x, 0, fd.y) - (b.at as Vector3i)


## Join a module to open connector `oi`: placed, both ends used. -1 when it
## does not fit.
func _attach(oi: int, cand: Array) -> int:
	budget -= 1
	var m: int = cand[0]
	var t: int = cand[1]
	var off := _offset(oi, m, t, cand[2])
	if not _fits(m, t, off):
		return -1
	var first := open.size()
	var idx := _place(m, t, off)
	var bi := first + int(cand[2])
	open[oi].used = true
	open[bi].used = true
	joins.append({"a": oi, "b": bi, "loop": false})
	return idx


## Candidates in weighted random order.
func _shuffled(cands: Array) -> Array:
	var left := cands.duplicate()
	var out := []
	while not left.is_empty():
		var total := 0.0
		for c in left:
			total += float(c[3])
		var r := rng.randf() * total
		var pick := left.size() - 1
		for i in left.size():
			r -= float(left[i][3])
			if r <= 0.0:
				pick = i
				break
		out.append(left[pick])
		left.remove_at(pick)
	return out


func _open_of(idx: int, kinds: Array) -> Array:
	var out := []
	for i in open.size():
		var c: Dictionary = open[i]
		if int(c.p) == idx and not bool(c.used) and String(c.link) == "auto" and kinds.has(String(c.kind)):
			out.append(i)
	for i in range(out.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var x = out[i]
		out[i] = out[j]
		out[j] = x
	return out


# ---------------------------------------------------------------------------
# The path, then the rest.

## Grow the path from the last placement: `want` modules more, then a finish.
func _extend(depth: int, want: int) -> bool:
	if budget <= 0:
		return false
	var last := placed.size() - 1
	var exits := _open_of(last, ["door", "stair_up", "stair_down"])
	if depth == want:
		if _finishes.is_empty():
			return true    # no finish module: the path ends at the last room
		for oi in exits:
			for cand in _shuffled(_candidates(oi, ["finish"])):
				var idx := _attach(oi, cand)
				if idx >= 0:
					exit = _reserved_of(idx, "finish")
					return true
				if budget <= 0:
					return false
		return false
	for oi in exits:
		for cand in _shuffled(_candidates(oi, ["room", "corridor", "stair"])):
			var idx := _attach(oi, cand)
			if idx < 0:
				if budget <= 0:
					return false
				continue
			if _extend(depth + 1, want):
				return true
			_unplace()
			if budget <= 0:
				return false
	return false


## The placement's connector linked `link` (the start's way in, the finish's
## way out), by open index, or -1.
func _reserved_of(idx: int, link: String) -> int:
	for i in open.size():
		if int(open[i].p) == idx and String(open[i].link) == link:
			open[i].used = true
			return i
	return -1


## Every module with a `min` not met, put on wherever it fits.
func _mins() -> void:
	for m in lib.size():
		var want := int(lib[m].rules.min)
		while int(counts.get(m, 0)) < want and budget > 0:
			var done := false
			for oi in _all_open():
				for cand in _shuffled(_candidates(oi, [String(lib[m].rules.role)], m)):
					if _attach(oi, cand) >= 0:
						done = true
						break
				if done:
					break
			if not done:
				break


func _all_open() -> Array:
	var out := []
	for i in open.size():
		var c: Dictionary = open[i]
		if not bool(c.used) and not bool(c.dead) and String(c.link) == "auto":
			out.append(i)
	return out


## Rooms on the open connectors until the building has `rooms` modules: a
## connector nothing fits is dead (and capped). A hang spot is picked with the
## chance `hang` against a door's.
func _branches() -> void:
	while placed.size() < int(p.rooms) and budget > 0:
		var all := _all_open()
		if all.is_empty():
			return
		var hangs := all.filter(func(i) -> bool: return String(open[i].kind) == "hang")
		var rest := all.filter(func(i) -> bool: return String(open[i].kind) != "hang")
		var pool: Array = hangs if not hangs.is_empty() and (rest.is_empty() or rng.randf() < float(p.hang)) else rest
		var oi: int = pool[rng.randi_range(0, pool.size() - 1)]
		var ok := false
		var roles := ["room", "corridor", "stair"]
		if String(open[oi].kind) == "hang":
			roles = ["hang"] if _hangers else ["room"]
		for cand in _shuffled(_candidates(oi, roles)):
			if _attach(oi, cand) >= 0:
				ok = true
				break
			if budget <= 0:
				return
		if not ok:
			open[oi].dead = true


## Open doors that meet now -- the same cells, facing each other, the same size
## -- joined: rooms meeting at more than one place. Returns how many.
func _loops() -> int:
	var n := 0
	var doors := []
	for i in open.size():
		var c: Dictionary = open[i]
		if String(c.kind) == "door" and not bool(c.used) and String(c.link) == "auto":
			doors.append(i)
	for x in doors.size():
		var a: Dictionary = open[doors[x]]
		if bool(a.used):
			continue
		var fd: Vector2i = StructureSpaces.FACINGS[int(a.facing)]
		var want: Vector3i = (a.at as Vector3i) - Vector3i(fd.x, 0, fd.y)
		for y in range(x + 1, doors.size()):
			var b: Dictionary = open[doors[y]]
			if not bool(b.used) and int(b.p) != int(a.p) and b.at == want \
					and int(b.facing) == (int(a.facing) + 2) % 4 and b.size == a.size:
				a.used = true
				b.used = true
				joins.append({"a": doors[x], "b": doors[y], "loop": true})
				n += 1
				break
	return n


# ---------------------------------------------------------------------------
# What is cut and added: caps, stairs, hang doorways, the facade (Docs/RoomModules.md 5).

func _finish(loops: int) -> Dictionary:
	var cuts := {}
	var adds := []
	var caps := []
	# Caps: every door left open, the start's way in and the finish's way out
	# apart -- a start or finish link on any other module is capped too.
	for i in open.size():
		var c: Dictionary = open[i]
		if String(c.kind) != "door" or i == entrance or i == exit:
			continue
		if bool(c.used) and _joined(i):
			continue
		caps.append(i)
		adds.append_array(_cap(c))
	# Joins: a hang spot's doorway cut, a stair's hole and steps.
	for j: Dictionary in joins:
		var a: Dictionary = open[j.a]
		var b: Dictionary = open[j.b]
		if String(a.kind) == "hang":
			_cut_wall(cuts, a, (b.size as Vector2i).x, (b.size as Vector2i).y, int(a.at.y))
		elif String(a.kind) == "stair_up" or String(a.kind) == "stair_down":
			var lower := a if String(a.kind) == "stair_up" else b
			var upper := b if lower == a else a
			_stair(cuts, adds, lower, upper)
	# The facade: one window style; balconies by chance where they fit.
	var style: String = WINDOW_STYLES[rng.randi_range(0, WINDOW_STYLES.size() - 1)]
	var glass := _glass()
	var balconies := 0
	for idx in placed.size():
		var pl: Dictionary = placed[idx]
		var td: Dictionary = lib[pl.m].turns[pl.t]
		var off: Vector3i = pl.off
		if style == "glass" and glass >= 0:
			for w: Dictionary in td.windows:
				if String(w.kind) == "window":
					for c: Vector3i in w.cells:
						adds.append(["plate_1x1", c + off, 0, glass])
		for mk: Dictionary in td.marks:
			var at: Vector3i = (mk.at as Vector3i) + off
			var wall := {"at": at, "facing": int(mk.facing), "depth": int(mk.depth)}
			match String(mk.kind):
				"window":
					_cut_through(cuts, wall, FACADE_WINDOW.x, FACADE_WINDOW.y, at.y)
					if style == "glass" and glass >= 0:
						var fd: Vector2i = StructureSpaces.FACINGS[int(mk.facing)]
						var across := Vector3i(absi(fd.y), 0, absi(fd.x))
						for x in FACADE_WINDOW.x:
							for y in FACADE_WINDOW.y:
								adds.append(["plate_1x1", at + across * x + Vector3i(0, y, 0), 0, glass])
				"balcony":
					if rng.randf() < float(p.balcony) and _balcony(cuts, adds, mk, off, int(td.colour)):
						balconies += 1
	# Doors: in the first wall of each joined doorway, a hung room's, the way in and out.
	var doors := []
	for j: Dictionary in joins:
		var a: Dictionary = open[j.a]
		var b: Dictionary = open[j.b]
		if rng.randf() >= float(p.doors):
			continue
		if String(a.kind) == "door":
			doors.append(BuildDoors.hole(a.at, int(a.facing), (a.size as Vector2i).x, (a.size as Vector2i).y, int(a.depth)))
		elif String(a.kind) == "hang":
			doors.append(BuildDoors.hole(a.at, int(a.facing), (b.size as Vector2i).x, (b.size as Vector2i).y, int(a.depth)))
	for i in [entrance, exit]:
		if i >= 0 and String(open[i].kind) == "door" and rng.randf() < float(p.doors):
			var c: Dictionary = open[i]
			doors.append(BuildDoors.hole(c.at, int(c.facing), (c.size as Vector2i).x, (c.size as Vector2i).y, int(c.depth)))
	var cut_cells := []
	for c in cuts:
		cut_cells.append(c)
	var plan_joins := []
	for j: Dictionary in joins:
		plan_joins.append({"a": _plain(open[j.a]), "b": _plain(open[j.b]), "loop": bool(j.loop)})
	return {"ok": true, "why": "", "seed": int(p.seed), "ground_y": ground_y, "placed": placed.duplicate(true),
			"joins": plan_joins, "path": path.duplicate(),
			"entrance": _plain(open[entrance]) if entrance >= 0 else {},
			"exit": _plain(open[exit]) if exit >= 0 else {},
			"caps": caps.map(func(i) -> Dictionary: return _plain(open[i])),
			"cuts": cut_cells, "adds": adds, "window_style": style, "doors": doors,
			"stats": {"modules": placed.size(), "path": path.size(), "joins": joins.size(),
				"loops": loops, "caps": caps.size(), "balconies": balconies, "doors": doors.size(),
				"tries": int(p.tries) - budget}}


func _joined(i: int) -> bool:
	for j: Dictionary in joins:
		if int(j.a) == i or int(j.b) == i:
			return true
	return false


func _plain(c: Dictionary) -> Dictionary:
	return {"p": int(c.p), "kind": String(c.kind), "at": c.at, "facing": int(c.facing),
			"size": c.size, "link": String(c.link)}


## A doorway left open, walled up: its cells through the wall (an open side:
## a wall one stud thick on its outer face), in the wall's own brick -- the
## colour and material beside the doorway -- courses of bricks along it in a
## running bond, plates where a brick's three no longer fit under the lintel.
func _cap(c: Dictionary) -> Array:
	var out := []
	var fd: Vector2i = StructureSpaces.FACINGS[int(c.facing)]
	var d := Vector3i(fd.x, 0, fd.y)
	var across := Vector3i(absi(fd.y), 0, absi(fd.x))
	var axis := "x" if across.x == 1 else "z"
	var wall: Array = c.get("wall", [])
	if wall.is_empty():
		wall = [int(lib[placed[int(c.p)].m].turns[placed[int(c.p)].t].colour), 0]
	var depth := int(c.depth)
	var size: Vector2i = c.size
	for k in (range(1, depth + 1) if depth > 0 else [0]):
		var base: Vector3i = (c.at as Vector3i) - d * int(k)
		var y := 0
		var course := 0
		while y < size.y:
			var kind := "brick" if y + 3 <= size.y else "plate"
			var x := 0
			while x < size.x:
				var n := 1
				for run: int in CAP_RUNS:
					# Every other course starts with a short one: the joints stagger.
					if run <= size.x - x and not (course % 2 == 1 and x == 0 and run > 1):
						n = run
						break
				var part := "%s_1x1" % kind if n == 1 else "%s_1x%d_%s" % [kind, n, axis]
				out.append([part, base + across * x + Vector3i(0, y, 0), int(wall[0]), int(wall[1])])
				x += n
			y += 3 if kind == "brick" else 1
			course += 1
	return out


## Cut a doorway `w` x `h` through the wall behind an outer face (a hang spot).
func _cut_wall(cuts: Dictionary, c: Dictionary, w: int, h: int, y0: int) -> void:
	var fd: Vector2i = StructureSpaces.FACINGS[int(c.facing)]
	var d := Vector3i(fd.x, 0, fd.y)
	var across := Vector3i(absi(fd.y), 0, absi(fd.x))
	for k in range(1, int(c.depth) + 1):
		for x in w:
			for y in h:
				var at := (c.at as Vector3i) - d * k + across * x
				cuts[Vector3i(at.x, y0 + y, at.z)] = true


## Cut a hole `w` x `h` through a wall from its inside cell outwards.
func _cut_through(cuts: Dictionary, wall: Dictionary, w: int, h: int, y0: int) -> void:
	var fd: Vector2i = StructureSpaces.FACINGS[int(wall.facing)]
	var d := Vector3i(fd.x, 0, fd.y)
	var across := Vector3i(absi(fd.y), 0, absi(fd.x))
	for k in int(wall.depth):
		for x in w:
			for y in h:
				var at := (wall.at as Vector3i) + d * k + across * x
				cuts[Vector3i(at.x, y0 + y, at.z)] = true


## A straight stair from the lower room's floor up to the upper's, two studs
## wide, ending at the stair link, a stud of tread a step; the slab cells over
## it cut where a step would have under HEADROOM. Each step's rise the first of
## STEP_RISES whose flight the lower room has the floor for, the way it has it.
func _stair(cuts: Dictionary, adds: Array, lower: Dictionary, upper: Dictionary) -> void:
	var lp: Dictionary = placed[int(lower.p)]
	var up: Dictionary = placed[int(upper.p)]
	var ls: Dictionary = lib[lp.m].turns[lp.t].spaces.get(int(lower.space), {})
	var us: Dictionary = lib[up.m].turns[up.t].spaces.get(int(upper.space), {})
	if ls.is_empty() or us.is_empty():
		return
	var loff: Vector3i = lp.off
	var floor_lo := int(ls.floor_y) + loff.y
	var ceil_lo := int(ls.ceil_y) + loff.y
	var floor_up := int(us.floor_y) + (up.off as Vector3i).y
	var h := floor_up - floor_lo
	if h <= 0:
		return
	var link: Vector3i = lower.at
	var colour := int(lib[lp.m].turns[lp.t].colour)
	for step: int in STEP_RISES:
		var n := ceili(float(h) / step)
		for f in 4:
			var fd: Vector2i = StructureSpaces.FACINGS[f]
			var across := Vector2i(absi(fd.y), absi(fd.x))
			var fits := true
			for i in n:
				for x in 2:
					var c := Vector2i(link.x, link.z) - fd * i + across * x - Vector2i(loff.x, loff.z)
					if not (ls.cols as Dictionary).has(c):
						fits = false
			if not fits:
				continue
			for i in n:
				# Step i counts down from the link: the link's step is the top one.
				var rise := maxi(h - step * i, 1)
				for x in 2:
					var c2 := Vector2i(link.x, link.z) - fd * i + across * x
					var y := 0
					while y + 3 <= rise:
						adds.append(["brick_1x1", Vector3i(c2.x, floor_lo + 1 + y, c2.y), colour, 0])
						y += 3
					while y < rise:
						adds.append(["plate_1x1", Vector3i(c2.x, floor_lo + 1 + y, c2.y), colour, 0])
						y += 1
					if floor_lo + 1 + rise + HEADROOM > ceil_lo:
						for cy in range(ceil_lo, floor_up + 1):
							cuts[Vector3i(c2.x, cy, c2.y)] = true
			return


## A balcony on its spot, if nothing is where it goes: a slab at the room's floor
## row, BALCONY along the wall and out, a rail round it a brick high, and a
## doorway out to it. Returns whether it was put.
func _balcony(cuts: Dictionary, adds: Array, mk: Dictionary, off: Vector3i, colour: int) -> bool:
	var fd: Vector2i = StructureSpaces.FACINGS[int(mk.facing)]
	var d := Vector3i(fd.x, 0, fd.y)
	var across := Vector3i(absi(fd.y), 0, absi(fd.x))
	var at: Vector3i = (mk.at as Vector3i) + off
	var y0 := int(mk.floor_y) + off.y
	var face := at + d * int(mk.depth)
	var cells := []
	for o in BALCONY.y:
		for x in range(-1, BALCONY.x - 1):
			cells.append(face + d * o + across * x)
	for c: Vector3i in cells:
		for s in occ.get(Vector2i(c.x, c.z), []):
			if y0 < int(s[1]) and int(s[0]) < y0 + 4:
				return false
	for c: Vector3i in cells:
		var w := Vector2i(c.x, c.z)
		if not occ.has(w):
			occ[w] = []
		(occ[w] as Array).append([y0, y0 + 4, -1, false])
		adds.append(["plate_1x1", Vector3i(c.x, y0, c.z), colour, 0])
		var o := (c - face).x * d.x + (c - face).z * d.z
		var x := (c - face).x * across.x + (c - face).z * across.z
		if o == BALCONY.y - 1 or x == -1 or x == BALCONY.x - 2:
			adds.append(["brick_1x1", Vector3i(c.x, y0 + 1, c.z), colour, 0])
	var room_h := int(mk.ceil_y) - int(mk.floor_y) - 1
	_cut_through(cuts, {"at": Vector3i(at.x, 0, at.z), "facing": int(mk.facing), "depth": int(mk.depth)},
			2, mini(15, room_h), y0 + 1)
	return true


static func _glass() -> int:
	for m in BrickWorld.get_material_count():
		if BrickWorld.is_material_translucent(m):
			return m
	return -1


# ---------------------------------------------------------------------------
# Laid as bricks.

## A plan as one build: every placement's bricks (furniture and detail too)
## turned and moved, those in a cut left out; then the caps, stairs, balconies
## and glass where nothing is yet. Fixtures and placed furniture come along.
##
## `on_ground`: as the workshop and the city stand a build -- moved so its
## lowest corner is at (1, 0, 1) and its ground row (the ground floors, row 0)
## left to the ground, the baseplate in the workshop, as a build made there
## has it.
static func lay(library: Array, plan: Dictionary, on_ground := false) -> BuildRecipe:
	var out := BuildRecipe.new()
	out.kind = "building"
	out.name = "generated %d" % int(plan.get("seed", 0))
	if not bool(plan.get("ok", false)):
		return out
	var shift := Vector3i.ZERO
	if on_ground:
		var lo := Vector2i(1 << 30, 1 << 30)
		for pl: Dictionary in plan.placed:
			for c: Vector2i in library[pl.m].turns[pl.t].cols:
				lo = Vector2i(mini(lo.x, c.x + pl.off.x), mini(lo.y, c.y + pl.off.z))
		shift = Vector3i(1 - lo.x, -int(plan.ground_y), 1 - lo.y)
		if plan.has("at"):
			shift = plan.at    # a plan that says where it stands (RoomShell)
	var cuts := {}
	for c in plan.cuts:
		cuts[(c as Vector3i) + shift] = true
	var filled := {}
	for pl: Dictionary in plan.placed:
		var tr: BuildRecipe = library[pl.m].turns[pl.t].recipe
		var off: Vector3i = (pl.off as Vector3i) + shift
		for i in tr.size():
			var c := tr.cell_of(i) + off
			var s := BuildRecipe.part_size(tr.part_of(i))
			var cells := []
			var cut := false
			var taken := false
			for y in s.y:
				for z in s.z:
					for x in s.x:
						var at := c + Vector3i(x, y, z)
						cut = cut or cuts.has(at)
						taken = taken or filled.has(at)
						cells.append(at)
			if taken or (on_ground and c.y < 1):
				continue
			if cut:
				# A box brick partly in a cut: what is left of it, column by column.
				if _boxy(tr.part_of(i)):
					_lay_left(out, filled, cuts, c, s, tr.colour_of(i), tr.role_of(i), tr.material_of(i))
				continue
			for at in cells:
				filled[at] = true
			out.add(tr.part_of(i), c, tr.colour_of(i), 0, tr.role_of(i), tr.material_of(i))
		for i in tr.fixture_count():
			var f := tr.fixture_at(i)
			out.add_fixture(f.kind, (f.cell as Vector3i) + off, f.params, f.role)
		for a in tr.placements:
			var in_cut := false
			for at in AssetPlacements.cells_of(str(a.asset), int(a.get("turn", 0)), BuildRecipe.cell_from(a.cell) + off):
				in_cut = in_cut or cuts.has(at)
			if in_cut:
				continue    # furniture where a stair or a doorway was cut: left out
			out.placements.append(AssetPlacements.make(str(a.asset), BuildRecipe.cell_from(a.cell) + off,
					int(a.get("turn", 0))))
	for a in plan.adds:
		var c: Vector3i = (a[1] as Vector3i) + shift
		if on_ground and c.y < 1:
			continue
		var s := BuildRecipe.part_size(String(a[0]))
		var cells := []
		for y in s.y:
			for z in s.z:
				for x in s.x:
					cells.append(c + Vector3i(x, y, z))
		if cells.any(func(at) -> bool: return filled.has(at)):
			continue
		for at in cells:
			filled[at] = true
		out.add(String(a[0]), c, int(a[2]), 0, BuildRecipe.Role.STRUCTURE, int(a[3]))
	# The rooms, so the spaces tool, interiors and the AI have them: each
	# module's spaces moved to where it is, found again from their seeds.
	var rec := StructureSpaces.empty()
	for pl: Dictionary in plan.placed:
		var off: Vector3i = (pl.off as Vector3i) + shift
		for sp: Dictionary in library[pl.m].turns[pl.t].spaces.values():
			var s: Vector3i = (sp.seed as Vector3i) + off
			var cols := []
			for c: Vector2i in sp.cols:
				cols.append([c.x + off.x, c.y + off.z])
			# A seed a stair or a cap now stands on: the room's first free cell instead.
			if filled.has(s):
				for c in cols:
					var v := Vector3i(int(c[0]), int(sp.floor_y) + off.y + 1, int(c[1]))
					if not filled.has(v):
						s = v
						break
			(rec.spaces as Array).append({"id": (rec.spaces as Array).size(), "kind": String(sp.kind),
					"frame": 0, "seed": [s.x, s.y, s.z], "floor_y": int(sp.floor_y) + off.y,
					"ceil_y": int(sp.ceil_y) + off.y, "columns": cols})
	out.meta["structure"] = rec
	var doors := []
	for dr: Array in plan.get("doors", []):
		var lo: Vector3i = (dr[0] as Vector3i) + shift
		if not on_ground or lo.y >= 1:
			doors.append(BuildDoors.record(lo, dr[1]))
	if not doors.is_empty():
		out.meta["doors"] = doors
	var lifts := []
	for lf: Dictionary in plan.get("lifts", []):
		var lo: Vector3i = (lf.lo as Vector3i) + shift
		lifts.append(BuildLifts.record(lo, lf.size, (lf.stops as Array).map(func(y) -> int: return int(y) + shift.y)))
	if not lifts.is_empty():
		out.meta["lifts"] = lifts
	out.meta["generated"] = {"generator": "grow", "seed": int(plan.seed), "stats": plan.stats,
			"modules": plan.placed.map(func(pl) -> String: return String(library[pl.m].name)),
			"window_style": plan.window_style}
	return out


## A plain plate or brick: a box of cells, so what a cut leaves of it can be laid
## again in 1x1s. A slope, a round or a custom piece is left out whole.
static func _boxy(part: String) -> bool:
	return part.begins_with("plate_") or part.begins_with("brick_")


## What a cut leaves of a box brick at `c`, size `s`: each column's cells out of
## the cut, as bricks (three plates) and plates, in the brick's colour.
static func _lay_left(out: BuildRecipe, filled: Dictionary, cuts: Dictionary, c: Vector3i, s: Vector3i,
		colour: int, role: int, material: int) -> void:
	for z in s.z:
		for x in s.x:
			var y := 0
			while y < s.y:
				var at := c + Vector3i(x, y, z)
				if cuts.has(at):
					y += 1
					continue
				var brick := y + 3 <= s.y
				for k in range(1, 3):
					brick = brick and not cuts.has(at + Vector3i(0, k, 0))
				var n := 3 if brick else 1
				for k in n:
					filled[at + Vector3i(0, k, 0)] = true
				out.add("brick_1x1" if brick else "plate_1x1", at, colour, 0, role, material)
				y += n
