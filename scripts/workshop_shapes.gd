class_name BrickShapes
extends RefCounted

## Shapes on the brick grid, and the courses that lay them (Docs/BuildTools.md, sections 2
## and 3). Static and shared: the building workshop's Shapes, Cut and Sketch tools all come
## through here.
##
## A shape or a cut is a Dictionary, saved as it is in the recipe's meta.shapes:
##
##   kind    rect, hollow, circle, ring, triangle, line, arch, or outline (`points`)
##   lie     flat (on a plane: u = x, v = z, stacked up y), wall_x (standing, u = x,
##           v = y, stacked along z) or wall_z (u = z, v = y, stacked along x)
##   a, b    the corners dragged, [u, v] cells; the box between them is the shape's
##   at      the first layer along the stacking axis; `depth` layers from there
##   rim     a hollow rectangle's, ring's or line's thickness, in studs
##   points  an outline's corners, [[u, v], ...] in cells (its kind is "outline")
##
## A kept shape has more (tall/thick, bond, part, colour, cuts, bricks): `WorkshopTools`.

const KINDS := [["rect", "rectangle"], ["hollow", "hollow rectangle"], ["circle", "circle"],
		["ring", "ring (donut)"], ["triangle", "triangle"], ["line", "line"], ["arch", "arch"]]
const LIES := ["flat", "wall_x", "wall_z"]


## How tall a v cell is next to a u cell, in metres: 1 on a flat plane, 0.4 standing up
## (v is plates there, u studs).
static func aspect(lie: String) -> float:
	return 1.0 if lie == "flat" else BrickPalette.PLATE_M / BrickPalette.STUD_M


## A cell of the shape's plane, `w` layers along: the grid cell.
static func to_3d(lie: String, c: Vector2i, w: int) -> Vector3i:
	match lie:
		"flat": return Vector3i(c.x, w, c.y)
		"wall_x": return Vector3i(c.x, c.y, w)
	return Vector3i(w, c.y, c.x)


## A grid cell in a lie's own terms: (u, v, w).
static func from_3d(lie: String, c: Vector3i) -> Vector3i:
	match lie:
		"flat": return Vector3i(c.x, c.z, c.y)
		"wall_x": return Vector3i(c.x, c.y, c.z)
	return Vector3i(c.z, c.y, c.x)


## The cells (Vector2i -> true) of a kind in the box between `a` and `b`, ends included.
## `rim` in studs; `asp` how tall a v cell is next to a u one (`aspect`).
static func cells_2d(kind: String, a: Vector2i, b: Vector2i, rim: int = 1, asp: float = 1.0,
		points: Array = []) -> Dictionary:
	if kind == "outline":
		return outline_cells(points)
	var lo := Vector2i(mini(a.x, b.x), mini(a.y, b.y))
	var hi := Vector2i(maxi(a.x, b.x), maxi(a.y, b.y))
	var w := hi.x - lo.x + 1
	var h := hi.y - lo.y + 1
	var r := maxi(1, rim)
	var rv := maxi(1, int(round(r / asp)))   # the rim in v cells: a stud is 2.5 plates up
	var out := {}
	# In metres, u cells 1 wide and v cells `asp` tall: circles come out round.
	var cx := lo.x + w * 0.5
	var cy := lo.y + h * 0.5
	var rx := w * 0.5
	var ry := h * 0.5
	for u in range(lo.x, hi.x + 1):
		for v in range(lo.y, hi.y + 1):
			var pu := u + 0.5
			var pv := v + 0.5
			var inside := true
			match kind:
				"hollow":
					inside = u - lo.x < r or hi.x - u < r or v - lo.y < rv or hi.y - v < rv
				"circle":
					inside = _in_ellipse(pu, pv, cx, cy, rx, ry)
				"ring":
					# Out of the inner ellipse only when the whole cell is: a ring one stud
					# thick stays joined edge to edge, not only at its corners.
					inside = _in_ellipse(pu, pv, cx, cy, rx, ry) and not (rx - r > 0.0 and ry - rv > 0.0
							and _in_ellipse(u, v, cx, cy, rx - r, ry - rv)
							and _in_ellipse(u + 1, v, cx, cy, rx - r, ry - rv)
							and _in_ellipse(u, v + 1, cx, cy, rx - r, ry - rv)
							and _in_ellipse(u + 1, v + 1, cx, cy, rx - r, ry - rv))
				"triangle":
					# Its base along the row the drag started on, its point at the far one.
					var t := (pv - lo.y) / h if b.y >= a.y else (hi.y + 1 - pv) / h
					inside = absf(pu - cx) <= rx * (1.0 - t) + 0.25
				"line":
					inside = _segment_dist(Vector2(pu, pv * asp), Vector2(a.x + 0.5, (a.y + 0.5) * asp),
							Vector2(b.x + 0.5, (b.y + 0.5) * asp)) <= r * 0.5 + 0.01
				"arch":
					# Straight sides, a round top as wide as it is: a doorway or a window.
					var top_h := rx / asp   # the half circle's height, in v cells
					var spring := hi.y + 1 - top_h
					inside = pv <= spring or _in_ellipse(pu, pv, cx, spring, rx, top_h)
			if inside:
				out[Vector2i(u, v)] = true
	return out


static func _in_ellipse(u: float, v: float, cx: float, cy: float, rx: float, ry: float) -> bool:
	var du := (u - cx) / rx
	var dv := (v - cy) / ry
	return du * du + dv * dv <= 1.0 + 1e-6


static func _segment_dist(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var t := 0.0 if ab.length_squared() < 1e-9 else clampf((p - a).dot(ab) / ab.length_squared(), 0.0, 1.0)
	return p.distance_to(a + ab * t)


## The cells inside an outline ([[u, v], ...] or Vector2s), by winding: a stretch circled
## twice is in, not cancelled out. A cell is in when its centre is.
static func outline_cells(points: Array) -> Dictionary:
	var pts := PackedVector2Array()
	for q in points:
		pts.append(q if q is Vector2 else Vector2(float(q[0]), float(q[1])))
	var out := {}
	if pts.size() < 3:
		return out
	var lo_y := INF
	var hi_y := -INF
	for q in pts:
		lo_y = minf(lo_y, q.y)
		hi_y = maxf(hi_y, q.y)
	var n := pts.size()
	for v in range(int(floor(lo_y)), int(ceil(hi_y))):
		var y := v + 0.5
		var xs := []
		for i in n:
			var a := pts[i]
			var b := pts[(i + 1) % n]
			if (a.y <= y) == (b.y <= y):
				continue
			xs.append([a.x + (y - a.y) / (b.y - a.y) * (b.x - a.x), 1 if b.y > a.y else -1])
		xs.sort_custom(func(p: Array, q: Array) -> bool: return p[0] < q[0])
		var wind := 0
		for j in range(xs.size() - 1):
			wind += int(xs[j][1])
			if wind == 0:
				continue
			for u in range(int(ceil(float(xs[j][0]) - 0.5)), int(ceil(float(xs[j + 1][0]) - 0.5))):
				out[Vector2i(u, v)] = true
	return out


## Every grid cell a shape (or a cut) fills, before its cuts: its 2D cells, `depth`
## layers from `at`.
static func solid_cells(sh: Dictionary) -> Dictionary:
	var lie := String(sh.get("lie", "flat"))
	var a := _v2(sh.get("a", [0, 0]))
	var b := _v2(sh.get("b", [0, 0]))
	var c2 := cells_2d(String(sh.get("kind", "rect")), a, b, int(sh.get("rim", 1)), aspect(lie),
			sh.get("points", []))
	var at := int(sh.get("at", 0))
	var out := {}
	for k in maxi(1, int(sh.get("depth", 1))):
		for c in c2:
			out[to_3d(lie, c, at + k)] = true
	return out


## A kept shape's cells: what it fills less what its cuts take out.
static func shape_cells(sh: Dictionary) -> Dictionary:
	var out := solid_cells(sh)
	for cut in sh.get("cuts", []):
		for c in solid_cells(cut):
			out.erase(c)
	return out


static func _v2(q: Variant) -> Vector2i:
	if q is Vector2i:
		return q
	return Vector2i(int(q[0]), int(q[1]))


# ---------------------------------------------------------------------------
# Courses: cells to bricks of the held kind
# ---------------------------------------------------------------------------

## The parts a shape of `held` is laid with: `held` itself, the biggest, and the smaller
## ones of its family as tall as it with a footprint inside its own; then plates of those
## footprints, for where less than a brick's height is left. Each both ways round, as
## [variant name, size], biggest first. `palette`: name -> archetype, so only parts the
## workshop has.
static func parts_for(held: String, palette: Dictionary) -> Array:
	var part := BrickPalette.part_of(held)
	var hs := BrickPalette.part_size(part)
	var fam := BrickPalette.family_of(part)
	var foot := Vector2i(mini(hs.x, hs.z), maxi(hs.x, hs.z))
	var names := []
	for p in BrickPalette.parts():
		var ps := BrickPalette.part_size(String(p))
		if ps == Vector3i.ZERO:
			continue
		var pf := Vector2i(mini(ps.x, ps.z), maxi(ps.x, ps.z))
		if pf.x > foot.x or pf.y > foot.y:
			continue
		var same: bool = BrickPalette.family_of(String(p)) == fam and ps.y == hs.y
		var plate: bool = hs.y > 1 and String(p).begins_with("plate_") and ps.y == 1
		if same or plate:
			names.append(String(p))
	var out := []
	var seen := {}
	for name in names:
		for yaw in 2:
			var v := BrickPalette.variant_name(name, yaw, false)
			var size := BrickPalette.size_of(v)
			if palette.has(v) and not seen.has(size):
				seen[size] = true
				out.append([v, size])
	out.sort_custom(func(p: Array, q: Array) -> bool:
		var vp: int = p[1].x * p[1].y * p[1].z
		var vq: int = q[1].x * q[1].y * q[1].z
		return vp > vq if vp != vq else p[1].y > q[1].y)
	return out


## Cover `cells` with `parts` (`parts_for`), a course at a time, bottom up. Returns
## [[variant name, min cell]].
##
## Each course's cells go in runs: a cell runs along X or Z, whichever way the shape is
## longer through it (a wall's own way). Where both are as long -- a corner, a floor --
## `staggered` takes X on even courses and Z on odd ones, so at a corner one course's brick
## runs through it one way and the next course's the other: the corners interlock.
## (Long both ways means longer than two bricks are wide: a wall two studs thick still
## runs its own way.) Along a
## run the longest part that fits is laid; `staggered` starts every other course (and every
## other row of a floor) with a part half as long, so no seam runs straight up (running
## bond). Aligned: the same every course, seams straight up (stack bond).
##
## `taken`: cells already built in (Vector3i -> true) -- the courses go round them.
## `base`: the layer the courses count from (default the lowest cell's).
static func pack_courses(cells: Dictionary, parts: Array, staggered: bool = true,
		taken: Dictionary = {}, base: int = 1 << 30) -> Array:
	var out := []
	var left := {}
	var ys := {}
	for c in cells:
		if not taken.has(c):
			left[c] = true
			ys[c.y] = true
	if left.is_empty() or parts.is_empty():
		return out
	var layers := ys.keys()
	layers.sort()
	if base == 1 << 30:
		base = int(layers[0])
	var tall := 1
	var long := 1
	var wide := 1
	for p in parts:
		tall = maxi(tall, p[1].y)
		long = maxi(long, maxi(p[1].x, p[1].z))
		wide = maxi(wide, mini(p[1].x, p[1].z))
	for y in layers:
		var course: int = floori(float(y - base) / tall)
		var on_course: bool = posmod(y - base, tall) == 0
		var along_x: bool = not staggered or course % 2 == 0
		var here := []
		for c in left:
			if c.y == y:
				here.append(c)
		# Row by row along the course's own way, from the low corner.
		here.sort_custom(func(p: Vector3i, q: Vector3i) -> bool:
			if along_x:
				return p.z < q.z if p.z != q.z else p.x < q.x
			return p.x < q.x if p.x != q.x else p.z < q.z)
		for c in here:
			if not left.has(c):
				continue
			var nx := _run(cells, c, Vector3i(1, 0, 0))
			var nz := _run(cells, c, Vector3i(0, 0, 1))
			# Long both ways (a corner, a floor): the course says which way; else the
			# shape's own way through the cell.
			var run_x := along_x if mini(nx, nz) > 2 * wide else nx > nz
			var dir := Vector3i(1, 0, 0) if run_x else Vector3i(0, 0, 1)
			# A run's first cell, on an odd phase: start with half a brick.
			var half := 0
			if staggered and not cells.has(c - dir):
				var row: int = floori(float(c.z if run_x else c.x) / wide)
				if posmod(course + row, 2) == 1:
					half = maxi(1, long >> 1)
			var pick := _best(left, c, parts, run_x, half, on_course)
			if pick.is_empty():
				continue
			var size: Vector3i = pick[1]
			for dx in size.x:
				for dy in size.y:
					for dz in size.z:
						left.erase(c + Vector3i(dx, dy, dz))
			out.append([pick[0], c])
	return out


## How many cells of the shape run through `c` along `dir`, both ways.
static func _run(cells: Dictionary, c: Vector3i, dir: Vector3i) -> int:
	var n := 1
	var p := c + dir
	while cells.has(p) and n < 64:
		n += 1
		p += dir
	p = c - dir
	while cells.has(p) and n < 128:
		n += 1
		p -= dir
	return n


## The part to lay with its low corner at `c`: along the run, the longest that fits
## (`half`: as near that length as fits, for a staggered start), then the widest, then the
## tallest; else anything that fits, biggest first. Bricks only on a course's first layer.
static func _best(left: Dictionary, c: Vector3i, parts: Array, run_x: bool, half: int,
		on_course: bool) -> Array:
	var best := []
	var score := -INF
	for p in parts:
		var size: Vector3i = p[1]
		if size.y > 1 and not on_course:
			continue
		if not _fits(left, c, size):
			continue
		var along := size.x if run_x else size.z
		var across := size.z if run_x else size.x
		var s := 0.0
		if along < across:
			s -= 1000.0   # turned across the run: only if nothing else fits
		if half > 0:
			s -= absi(along - half) * 100.0
		else:
			s += along * 100.0
		s += across * 10.0 + size.y
		if s > score:
			score = s
			best = p
	return best


static func _fits(left: Dictionary, at: Vector3i, size: Vector3i) -> bool:
	for dx in size.x:
		for dy in size.y:
			for dz in size.z:
				if not left.has(at + Vector3i(dx, dy, dz)):
					return false
	return true
