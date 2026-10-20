class_name BuildingLayout
extends RefCounted

## A building as the AI walks it once it needs to know it: a graph of SPACES
## (rooms, and the stairwell on each storey) joined by the openings a body can
## walk through (Docs/AI.md 3.6.1).
##
## Everything is in the BUILDING's own space -- cells are studs across and
## plates up from its corner, points are metres from its corner -- so a graph
## is made once per recipe and serves every building of that shape wherever it
## stands, at any turn, on any frame (Docs/Planets.md 7). Turn a world point
## into this space with BuildingRegistry.to_building, and a route back with
## to_world.
##
## Two makers, one graph:
##   for_tower(...)   a generated tower, from its recipe alone -- no bricks are
##                    read, so knowing a pristine building never materialises it
##                    (Docs/AI.md 3.2). Rooms are TowerRecipe.plan's, doorways
##                    TowerRecipe.doorways (the very function the bricks are
##                    cut by), the stairwell its fixture's keep-out.
##   for_record(rec)  anything with a structure record (Docs/Structures.md 3.1):
##                    a workshop build's spaces tool, or StructureSpaces.
##
## What it does NOT know is damage: a room whose bricks changed is walked on the
## brick grid (AINav) inside its own box, and a hole is a way in that the grid
## finds (AI.md 3.6.1, "broken here"). That is the caller's half.

const STUD := 0.35
const PLATE := 0.14
## A figure is two studs across (AINav): a way narrower than this is not one.
const BODY_STUDS := 2

## One per space: {"kind": "room" | "stair" | <record kind>, "storey": int,
## "floor_y": plates, "height": plates, "rect": Rect2i (studs, on plan) or
## "columns": {Vector2i: true} for a record's free-shaped space}.
var spaces: Array[Dictionary] = []
## Per space: [[other space, point (Vector3, building metres), kind], ...].
var links: Array = []
## Openings to the outside: {"space", "point", "kind"} -- windows, and a
## record's doorways with nothing on their far side.
var portals: Array[Dictionary] = []

static var _towers := {}


## The layout of a generated tower. Cached on everything that decides it.
static func for_tower(footprint_x: int, footprint_z: int, courses: int,
		keepouts: Array = []) -> BuildingLayout:
	var key := [footprint_x, footprint_z, courses, keepouts]
	var h := hash(key)
	if _towers.has(h):
		return _towers[h]
	var out := BuildingLayout.new()
	out._make_tower(footprint_x, footprint_z, courses, keepouts)
	_towers[h] = out
	return out


static func for_record(rec: Dictionary) -> BuildingLayout:
	var out := BuildingLayout.new()
	out._make_record(rec)
	return out


func space_count() -> int:
	return spaces.size()


func link_count() -> int:
	var n := 0
	for l in links:
		n += (l as Array).size()
	return n / 2


## The space a point (building metres) stands in, or -1.
func space_at(p: Vector3) -> int:
	var cell := Vector3i(floori(p.x / STUD), floori(p.y / PLATE), floori(p.z / STUD))
	var best := -1
	for i in spaces.size():
		var s: Dictionary = spaces[i]
		var y0 := int(s.floor_y)
		if cell.y < y0 - 1 or cell.y >= y0 + int(s.height):
			continue
		if s.has("rect"):
			if not (s.rect as Rect2i).has_point(Vector2i(cell.x, cell.z)):
				continue
		elif not (s.columns as Dictionary).has(Vector2i(cell.x, cell.z)):
			continue
		# The stairwell wins over the room it stands in: it is the more
		# specific answer, and the way between storeys.
		if best < 0 or s.kind == "stair":
			best = i
	return best


## The way from one point to another (building metres) through the graph:
## the start, every opening passed, the goal. Empty when either point is in no
## space or there is no way. Straight lines between the points stay inside a
## space -- rooms are boxes between walls -- except up a stairwell, where the
## walker climbs the stair between its two points.
func route(from: Vector3, to: Vector3) -> PackedVector3Array:
	var a := space_at(from)
	var b := space_at(to)
	if a < 0 or b < 0:
		return PackedVector3Array()
	if a == b:
		return PackedVector3Array([from, to])
	# Dijkstra over spaces, the cost the walk from opening to opening.
	var n := spaces.size()
	var dist := PackedFloat32Array()
	dist.resize(n)
	dist.fill(INF)
	var prev := PackedInt32Array()
	prev.resize(n)
	prev.fill(-1)
	var via: Array = []
	via.resize(n)
	var at: Array = []
	at.resize(n)
	dist[a] = 0.0
	at[a] = from
	var open := [a]
	while not open.is_empty():
		var best_k := 0
		for k in open.size():
			if dist[open[k]] < dist[open[best_k]]:
				best_k = k
		var u: int = open[best_k]
		open.remove_at(best_k)
		if u == b:
			break
		for l in links[u]:
			var v: int = l[0]
			var p: Vector3 = l[1]
			var d: float = dist[u] + (at[u] as Vector3).distance_to(p)
			if d < dist[v]:
				if dist[v] == INF:
					open.append(v)
				dist[v] = d
				prev[v] = u
				via[v] = p
				at[v] = p
	if dist[b] == INF:
		return PackedVector3Array()
	var points: Array[Vector3] = [to]
	var c := b
	while c != a:
		points.append(via[c])
		c = prev[c]
	points.append(from)
	points.reverse()
	return PackedVector3Array(points)


## Is there a way at all? (A stairwell shot out, every door bricked.)
func reachable(from: Vector3, to: Vector3) -> bool:
	return not route(from, to).is_empty()


# --- makers --------------------------------------------------------------------

func _add_space(s: Dictionary) -> int:
	spaces.append(s)
	links.append([])
	return spaces.size() - 1


func _link(a: int, b: int, p: Vector3, kind: String) -> void:
	links[a].append([b, p, kind])
	links[b].append([a, p, kind])


func _make_tower(fx: int, fz: int, courses: int, keepouts: Array) -> void:
	var pl := TowerRecipe.plan(fx, fz)
	var storeys := RoomManifest.storeys_of(courses)
	var core := Rect2i()
	for k in TowerRecipe.snap_keepouts(keepouts, fx, fz):
		core = k if core.size == Vector2i.ZERO else core.merge(k)
	var rooms_of: Array = []   # per storey: [space index, ...]
	var stair_of: Array = []   # per storey: space index or -1
	for si in storeys.size():
		var st: Dictionary = storeys[si]
		var mine: Array = []
		for entry in (pl.rooms as Array):
			var r: Rect2i = entry
			mine.append(_add_space({"kind": "room", "storey": si, "floor_y": int(st.floor_y),
					"height": int(st.height), "rect": r}))
		rooms_of.append(mine)
		var stair := -1
		if core.size != Vector2i.ZERO:
			stair = _add_space({"kind": "stair", "storey": si, "floor_y": int(st.floor_y),
					"height": int(st.height), "rect": core})
			var mid := Vector3((core.position.x + core.size.x * 0.5) * STUD,
					int(st.floor_y) * PLATE, (core.position.y + core.size.y * 0.5) * STUD)
			# Into the stairwell from every room it opens on: one it stands in,
			# or one across an interior wall the stairwell cuts through -- the
			# wall is not laid where a keep-out crosses its line
			# (TowerRecipe._lay_wall_line), so that stretch is open.
			for ri in mine:
				if _opens_on(spaces[ri].rect, core, pl):
					_link(ri, stair, mid, "stair")
		stair_of.append(stair)
	# Up the stairwell, storey to storey.
	for si in range(1, stair_of.size()):
		if stair_of[si] >= 0 and stair_of[si - 1] >= 0:
			var s: Dictionary = spaces[stair_of[si]]
			var mid := Vector3((core.position.x + core.size.x * 0.5) * STUD,
					int(s.floor_y) * PLATE, (core.position.y + core.size.y * 0.5) * STUD)
			_link(stair_of[si - 1], stair_of[si], mid, "climb")
	# Through the interior walls: the room each side of a doorway.
	for d in TowerRecipe.doorways(fx, fz, courses, keepouts):
		var si: int = d.storey
		if si >= rooms_of.size():
			continue
		var line: int = d.line
		var thick: int = d.thick
		var span := clear_span(d, pl)
		if span.y - span.x < BODY_STUDS:
			continue
		var mid_along := (span.x + span.y) * 0.5
		var near := -1
		var far := -1
		for ri in rooms_of[si]:
			var r: Rect2i = spaces[ri].rect
			var lo_across := r.position.x if d.along_z else r.position.y
			var hi_across := r.end.x if d.along_z else r.end.y
			var lo_along := r.position.y if d.along_z else r.position.x
			var hi_along := r.end.y if d.along_z else r.end.x
			if mid_along < lo_along or mid_along > hi_along:
				continue
			if absi(hi_across - line) <= 1:
				near = ri
			elif absi(lo_across - (line + thick)) <= 1:
				far = ri
		if near < 0 or far < 0:
			continue
		var across := (line + thick * 0.5) * STUD
		var along := mid_along * STUD
		var y := int(d.floor_y) * PLATE
		_link(near, far, Vector3(across, y, along) if d.along_z else Vector3(along, y, across),
				"doorway")
	# Windows: ways in for whatever can climb through one.
	var t := TowerRecipe.WALL_THICK
	for si in storeys.size():
		var y := (int(storeys[si].floor_y) + TowerRecipe.PLATES_PER_COURSE * 2) * PLATE
		for side in 4:
			var along_x := side < 2
			for g in TowerRecipe.window_gaps(fx if along_x else fz):
				var m := ((g as Vector2i).x + (g as Vector2i).y) * 0.5
				var cell := Vector2i(int(m), t) if side == 0 else (
						Vector2i(int(m), fz - t - 1) if side == 1 else (
						Vector2i(t, int(m)) if side == 2 else Vector2i(fx - t - 1, int(m))))
				var room := -1
				for ri in rooms_of[si]:
					if (spaces[ri].rect as Rect2i).grow(1).has_point(cell):
						room = ri
						break
				if room < 0:
					continue
				var face := Vector3(m * STUD, y, 0.0) if side == 0 else (
						Vector3(m * STUD, y, fz * STUD) if side == 1 else (
						Vector3(0.0, y, m * STUD) if side == 2 else Vector3(fx * STUD, y, m * STUD)))
				portals.append({"space": room, "point": face, "kind": "window"})


## The part of a recipe doorway (TowerRecipe.doorways) a body can walk
## through: the doorway less any other interior wall that crosses it. The
## recipe can put a doorway across a junction, and the wall running the other
## way then stands in half of it (40 x 30, storeys 1 and 2: two studs of four
## clear). Counted solid even where that wall has its own doorway there --
## the narrower answer is the safe one. The widest clear run, [from, to).
static func clear_span(d: Dictionary, pl: Dictionary) -> Vector2i:
	var span: Vector2i = d.span
	var thick := TowerRecipe.ROOM_WALL_THICK
	var cuts: Array = []
	for line in (pl.wall_z if d.along_z else pl.wall_x):
		cuts.append(Vector2i(int(line), int(line) + thick))
	var best := Vector2i.ZERO
	var at := span.x
	while at < span.y:
		var end := at
		while end < span.y:
			var cut := false
			for c in cuts:
				if end >= (c as Vector2i).x and end < (c as Vector2i).y:
					cut = true
			if cut:
				break
			end += 1
		if end - at > best.y - best.x:
			best = Vector2i(at, end)
		at = end + 1
	return best


## Does a room open onto the stairwell `core`: is the core in it, or does the
## core cross the interior wall on one of its sides along a stretch a body
## fits through (two studs)?
static func _opens_on(r: Rect2i, core: Rect2i, pl: Dictionary) -> bool:
	if r.intersects(core):
		return true
	var thick := TowerRecipe.ROOM_WALL_THICK
	for line in (pl.wall_x as Array):
		var x := int(line)
		var crosses: bool = core.position.x < x + thick and core.end.x > x
		var beside: bool = r.end.x == x or r.position.x == x + thick
		var along := mini(r.end.y, core.end.y) - maxi(r.position.y, core.position.y)
		if crosses and beside and along >= 2:
			return true
	for line in (pl.wall_z as Array):
		var z := int(line)
		var crosses: bool = core.position.y < z + thick and core.end.y > z
		var beside: bool = r.end.y == z or r.position.y == z + thick
		var along := mini(r.end.x, core.end.x) - maxi(r.position.x, core.position.x)
		if crosses and beside and along >= 2:
			return true
	return false


func _make_record(rec: Dictionary) -> void:
	var index := {}
	for s in rec.get("spaces", []):
		var cols := {}
		for c in s.get("columns", []):
			cols[Vector2i(int(c[0]), int(c[1]))] = true
		var fy := int(s.get("floor_y", 0))
		index[int(s.get("id", -1))] = _add_space({"kind": String(s.get("kind", "room")),
				"storey": -1, "floor_y": fy + 1,
				"height": maxi(int(s.get("ceil_y", fy + 1)) - fy - 1, 1), "columns": cols})
	# The same hole is listed once from each room it opens: two openings that
	# share a cell join their rooms. One with no partner opens to the outside.
	var walk := ["doorway", "door", "arch", "open"]
	var by_cell := {}
	var opens: Array = []
	for o in rec.get("openings", []):
		var sp := int(index.get(int(o.get("space", -1)), -1))
		if sp < 0:
			continue
		var cells: Array = o.get("cells", [])
		var sum := Vector3.ZERO
		var low := 1 << 30
		for c in cells:
			sum += Vector3(float(c[0]) + 0.5, 0.0, float(c[2]) + 0.5)
			low = mini(low, int(c[1]))
		var p := Vector3(sum.x / maxf(cells.size(), 1) * STUD, low * PLATE,
				sum.z / maxf(cells.size(), 1) * STUD)
		var k := String(o.get("kind", ""))
		var entry := {"space": sp, "point": p, "kind": k, "partnered": false}
		opens.append(entry)
		if not walk.has(k):
			continue
		# Each room lists its own face of the wall, so the two halves of one
		# doorway through a two-stud wall touch rather than share a cell.
		for c in cells:
			var key := Vector3i(int(c[0]), int(c[1]), int(c[2]))
			for d in [Vector3i.ZERO, Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
					Vector3i(0, 0, 1), Vector3i(0, 0, -1)]:
				var other = by_cell.get(key + d)
				if other != null and other.space != sp and not entry.partnered:
					_link(other.space, sp, p, k)
					other.partnered = true
					entry.partnered = true
		for c in cells:
			by_cell[Vector3i(int(c[0]), int(c[1]), int(c[2]))] = entry
	for e in opens:
		if not e.partnered:
			portals.append({"space": e.space, "point": e.point, "kind": e.kind})
