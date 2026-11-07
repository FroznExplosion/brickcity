class_name WkShapes
extends RefCounted

## Shapes on a grid, as cells (workshop_kit): rectangles, hollow rectangles, ellipses, rings,
## triangles, lines, arches, stairs, wall lines, drawn outlines and plans -- all static, no
## editor classes. An editor packs the cells into its own pieces.
##
## A shape lies on a plane of the grid: `lie` "flat" (u = x, v = z, stacked up y), "wall_x"
## (u = x, v = y, stacked along z) or "wall_z" (u = z, v = y, stacked along x). `asp` is how
## tall a v cell is next to a u cell (1 on a flat plane), so circles come out round.

const KINDS := [["rect", "rectangle"], ["hollow", "hollow rectangle"], ["circle", "circle"],
		["ring", "ring (donut)"], ["triangle", "triangle"], ["line", "line"], ["arch", "arch"],
		["stairs", "stairs (standing: drag bottom to top)"]]
const LIES := ["flat", "wall_x", "wall_z"]
## Stairs: a step every this many v cells up.
const STAIR_STEP := 3


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
		points: Variant = []) -> Dictionary:
	match kind:
		"outline":
			return outline_cells(points)
		"cells":
			var cs := {}
			for q in points:
				cs[Vector2i(int(q[0]), int(q[1]))] = true
			return cs
		"polyline":
			return polyline_cells(points, rim, asp)
		"plan":
			return plan_region(points)
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
				"jamb":
					inside = u - lo.x < r or hi.x - u < r or hi.y - v < rv
				"circle":
					inside = in_ellipse(pu, pv, cx, cy, rx, ry)
				"ring":
					# Out of the inner ellipse only when the whole cell is: a ring one stud
					# thick stays joined edge to edge, not only at its corners.
					inside = in_ellipse(pu, pv, cx, cy, rx, ry) and not (rx - r > 0.0 and ry - rv > 0.0
							and in_ellipse(u, v, cx, cy, rx - r, ry - rv)
							and in_ellipse(u + 1, v, cx, cy, rx - r, ry - rv)
							and in_ellipse(u, v + 1, cx, cy, rx - r, ry - rv)
							and in_ellipse(u + 1, v + 1, cx, cy, rx - r, ry - rv))
				"triangle":
					# Its base along the row the drag started on, its point at the far one.
					var t := (pv - lo.y) / h if b.y >= a.y else (hi.y + 1 - pv) / h
					inside = absf(pu - cx) <= rx * (1.0 - t) + 0.25
				"line":
					inside = segment_dist(Vector2(pu, pv * asp), Vector2(a.x + 0.5, (a.y + 0.5) * asp),
							Vector2(b.x + 0.5, (b.y + 0.5) * asp)) <= r * 0.5 + 0.01
				"stairs":
					inside = _stair_has(u, v, a, b)
				"arch":
					# Straight sides, a round top as wide as it is: a doorway or a window.
					var top_h := rx / asp   # the half circle's height, in v cells
					var spring := hi.y + 1 - top_h
					inside = pv <= spring or in_ellipse(pu, pv, cx, spring, rx, top_h)
			if inside:
				out[Vector2i(u, v)] = true
	return out


## Stairs between `a` and `b` (standing: u along, v up): from the lower end, a step every
## `STAIR_STEP` cells up, each as deep as the run allows and reaching a cell over the next one, so
## each stands on the one below.
static func _stair_has(u: int, v: int, a: Vector2i, b: Vector2i) -> bool:
	var bottom := a if a.y <= b.y else b
	var top := b if a.y <= b.y else a
	var h := top.y - bottom.y + 1
	var n := maxi(1, ceili(h / float(STAIR_STEP)))
	var run := absi(top.x - bottom.x) + 1
	var each := maxi(1, floori(float(run) / n))
	var k := (u - bottom.x) if top.x >= bottom.x else (bottom.x - u)
	if k < 0 or k >= run or v < bottom.y or v > top.y:
		return false
	var i := floori((v - bottom.y) / float(STAIR_STEP))
	var from := i * each
	var to := mini(run - 1, from + each)
	if i == n - 1:
		to = run - 1
	return k >= from and k <= to


## A wall line's cells: each segment of `points` ({pts: [[u, v], ...], closed, more}) `rim`
## wide, and of each line in `more` (walls joined to it at a corner or a T). A segment along
## u or v is a band, grown past its ends by the same so corners close; any other is every
## cell within half the rim of it.
static func polyline_cells(points: Variant, r: int, asp: float = 1.0) -> Dictionary:
	var pts: Array = points.get("pts", []) if points is Dictionary else points
	var closed: bool = points is Dictionary and bool(points.get("closed", false))
	var res := {}
	if points is Dictionary:
		for line in points.get("more", []):
			res.merge(polyline_cells({"pts": line}, r, asp))
	var n := pts.size()
	if n == 0:
		return res
	r = maxi(1, r)
	var lo_off := -((r - 1) >> 1)
	var hi_off := r >> 1
	var segs := n - 1 + (1 if closed and n > 2 else 0)
	if n == 1:
		segs = 1
	for i in segs:
		var a := v2i(pts[i])
		var b := v2i(pts[(i + 1) % n])
		if a.x == b.x or a.y == b.y:
			for u in range(mini(a.x, b.x) + lo_off, maxi(a.x, b.x) + hi_off + 1):
				for v in range(mini(a.y, b.y) + lo_off, maxi(a.y, b.y) + hi_off + 1):
					res[Vector2i(u, v)] = true
			continue
		for u in range(mini(a.x, b.x) - r, maxi(a.x, b.x) + r + 1):
			for v in range(mini(a.y, b.y) - r, maxi(a.y, b.y) + r + 1):
				if segment_dist(Vector2(u + 0.5, (v + 0.5) * asp), Vector2(a.x + 0.5, (a.y + 0.5) * asp),
						Vector2(b.x + 0.5, (b.y + 0.5) * asp)) <= r * 0.5 + 0.01:
					res[Vector2i(u, v)] = true
	return res


static func in_ellipse(u: float, v: float, cx: float, cy: float, rx: float, ry: float) -> bool:
	var du := (u - cx) / rx
	var dv := (v - cy) / ry
	return du * du + dv * dv <= 1.0 + 1e-6


static func segment_dist(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var t := 0.0 if ab.length_squared() < 1e-9 else clampf((p - a).dot(ab) / ab.length_squared(), 0.0, 1.0)
	return p.distance_to(a + ab * t)


## The cells inside an outline ([[u, v], ...] or Vector2s), or under a brush stroke: the
## sketch pen's (WkSketchPen.region_cells), so both workshops' sketches fill the same.
static func outline_cells(points: Variant) -> Dictionary:
	return WkSketchPen.region_cells(points)


## A floor plan's area: every stroke drawn into it (`points.adds`: outlines and brush
## strokes, as the sketch pen gives them) less every one drawn out (`points.subs`).
static func plan_region(points: Variant) -> Dictionary:
	var res := {}
	if not (points is Dictionary):
		return res
	for e in points.get("adds", []):
		res.merge(entry_cells(e))
	for e in points.get("subs", []):
		for c in entry_cells(e):
			res.erase(c)
	return res


## A stroke's cells, or a drawn shape's: {kind, a, b, rim} in a plan is a shape on the grid.
static func entry_cells(e: Variant) -> Dictionary:
	if e is Dictionary and e.has("kind"):
		return cells_2d(String(e.kind), v2i(e.a), v2i(e.b), int(e.get("rim", 1)))
	return WkSketchPen.region_cells(e)


## The cells of `region` within `rim` cells of its outside (corners too): walls along its
## outline, as thick as `rim`.
static func ring(region: Dictionary, rim: int) -> Dictionary:
	var res := {}
	var r := maxi(1, rim)
	for c in region:
		var edge := false
		for dx in range(-r, r + 1):
			for dy in range(-r, r + 1):
				if not region.has(c + Vector2i(dx, dy)):
					edge = true
					break
			if edge:
				break
		if edge:
			res[c] = true
	return res


static func v2i(q: Variant) -> Vector2i:
	if q is Vector2i:
		return q
	return Vector2i(int(q[0]), int(q[1]))
