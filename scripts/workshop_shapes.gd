class_name BrickShapes
extends RefCounted

## Shapes on the brick grid, and the courses that lay them (Docs/BuildTools.md, sections 2
## and 3). Static and shared: the building workshop's Shapes, Cut and Sketch tools all come
## through here.
##
## A shape or a cut is a Dictionary, saved as it is in the recipe's meta.shapes:
##
##   kind    rect, hollow, circle, ring, triangle, line, arch, stairs, jamb (a hollow
##           rectangle with no bottom: a door's frame), outline (`points`: drawn), polyline
##           (`points` {pts, closed}: a wall line), cells (`points`: the cells themselves, a
##           floor), roof (its own: `roof_plan`), or plan (a floor plan: `points`
##           {adds, subs} of strokes; filled, walls along its outline, or a building with a
##           floor each storey -- `plan_cells`)
##   lie     flat (on a plane: u = x, v = z, stacked up y), wall_x (standing, u = x,
##           v = y, stacked along z) or wall_z (u = z, v = y, stacked along x)
##   a, b    the corners dragged, [u, v] cells; the box between them is the shape's
##   at      the first layer along the stacking axis; `depth` layers from there
##   rim     a hollow rectangle's, ring's or line's thickness, in studs
##   points  a sketched shape's outline, [[u, v], ...] in cells, or its brush stroke
##           (SketchPen.brush_entry); its kind is "outline"
##
## A kept shape has more (tall/thick, bond, part, colour, cuts, bricks): `WorkshopTools`.

const KINDS := [["rect", "rectangle"], ["hollow", "hollow rectangle"], ["circle", "circle"],
		["ring", "ring (donut)"], ["triangle", "triangle"], ["line", "line"], ["arch", "arch"],
		["stairs", "stairs (standing: drag bottom to top)"]]
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
				"stairs":
					inside = _stair_has(u, v, a, b)
				"arch":
					# Straight sides, a round top as wide as it is: a doorway or a window.
					var top_h := rx / asp   # the half circle's height, in v cells
					var spring := hi.y + 1 - top_h
					inside = pv <= spring or _in_ellipse(pu, pv, cx, spring, rx, top_h)
			if inside:
				out[Vector2i(u, v)] = true
	return out


## Stairs between `a` and `b` (standing: u along, v up): from the lower end, a step every
## three plates up, each as deep as the run allows and reaching a stud over the next one, so
## each stands on the one below.
static func _stair_has(u: int, v: int, a: Vector2i, b: Vector2i) -> bool:
	var bottom := a if a.y <= b.y else b
	var top := b if a.y <= b.y else a
	var h := top.y - bottom.y + 1
	var n := maxi(1, ceili(h / 3.0))
	var run := absi(top.x - bottom.x) + 1
	var each := maxi(1, floori(float(run) / n))
	var k := (u - bottom.x) if top.x >= bottom.x else (bottom.x - u)
	if k < 0 or k >= run or v < bottom.y or v > top.y:
		return false
	var i := floori((v - bottom.y) / 3.0)
	var from := i * each
	var to := mini(run - 1, from + each)
	if i == n - 1:
		to = run - 1
	return k >= from and k <= to


## A wall line's cells: each segment of `points` ({pts: [[u, v], ...], closed}) `rim` wide.
## A segment along u or v is a band, grown past its ends by the same so corners close;
## any other is every cell within half the rim of it.
static func polyline_cells(points: Variant, r: int, asp: float = 1.0) -> Dictionary:
	var pts: Array = points.get("pts", []) if points is Dictionary else points
	var closed: bool = points is Dictionary and bool(points.get("closed", false))
	var res := {}
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
		var a := _v2(pts[i])
		var b := _v2(pts[(i + 1) % n])
		if a.x == b.x or a.y == b.y:
			for u in range(mini(a.x, b.x) + lo_off, maxi(a.x, b.x) + hi_off + 1):
				for v in range(mini(a.y, b.y) + lo_off, maxi(a.y, b.y) + hi_off + 1):
					res[Vector2i(u, v)] = true
			continue
		for u in range(mini(a.x, b.x) - r, maxi(a.x, b.x) + r + 1):
			for v in range(mini(a.y, b.y) - r, maxi(a.y, b.y) + r + 1):
				if _segment_dist(Vector2(u + 0.5, (v + 0.5) * asp), Vector2(a.x + 0.5, (a.y + 0.5) * asp),
						Vector2(b.x + 0.5, (b.y + 0.5) * asp)) <= r * 0.5 + 0.01:
					res[Vector2i(u, v)] = true
	return res


static func _in_ellipse(u: float, v: float, cx: float, cy: float, rx: float, ry: float) -> bool:
	var du := (u - cx) / rx
	var dv := (v - cy) / ry
	return du * du + dv * dv <= 1.0 + 1e-6


static func _segment_dist(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var t := 0.0 if ab.length_squared() < 1e-9 else clampf((p - a).dot(ab) / ab.length_squared(), 0.0, 1.0)
	return p.distance_to(a + ab * t)


## The cells inside an outline ([[u, v], ...] or Vector2s), or under a brush stroke: the
## sketch pen's (SketchPen.region_cells), so both workshops' sketches fill the same.
static func outline_cells(points: Variant) -> Dictionary:
	return SketchPen.region_cells(points)


## Every grid cell a shape (or a cut) fills, before its cuts: its 2D cells, `depth`
## layers from `at`.
static func solid_cells(sh: Dictionary) -> Dictionary:
	if String(sh.get("kind", "")) == "roof":
		return roof_plan(sh).cells
	if String(sh.get("kind", "")) == "plan":
		return plan_cells(sh)
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


## A floor plan's area: every stroke drawn into it (`points.adds`: outlines and brush
## strokes, as the sketch pen gives them) less every one drawn out (`points.subs`).
static func plan_region(points: Variant) -> Dictionary:
	var res := {}
	if not (points is Dictionary):
		return res
	for e in points.get("adds", []):
		res.merge(SketchPen.region_cells(e))
	for e in points.get("subs", []):
		for c in SketchPen.region_cells(e):
			res.erase(c)
	return res


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


## Which band layer `y` of a plan is: "floor" (the whole plan) or "wall" (its outline, or
## all of it when filled). A building's storey is a floor (`floor` plates) and `storey`
## plates of wall over it; a flat roof (`roof`) is a floor over the last storey.
static func plan_band(sh: Dictionary, y: int) -> String:
	var storey := int(sh.get("storey", 0))
	if storey <= 0:
		return "wall"
	var ft := maxi(1, int(sh.get("floor", 1)))
	var rel := y - int(sh.get("at", 0))
	var depth := int(sh.get("depth", 1))
	if bool(sh.get("roof", false)) and rel >= depth - ft:
		return "floor"
	return "floor" if posmod(rel, storey + ft) < ft else "wall"


## Every cell of a plan: its floors the whole plan, its walls the outline `rim` wide (or the
## whole plan, `fill`).
static func plan_cells(sh: Dictionary) -> Dictionary:
	var region := plan_region(sh.get("points", {}))
	var walls := region if bool(sh.get("fill", false)) else ring(region, int(sh.get("rim", 1)))
	var at := int(sh.get("at", 0))
	var out := {}
	for y in range(at, at + maxi(1, int(sh.get("depth", 1)))):
		var band := region if plan_band(sh, y) == "floor" else walls
		for c in band:
			out[Vector3i(c.x, y, c.y)] = true
	return out


## The layers a brick `tall` plates high may start on, for a shape whose courses restart
## (a building's walls, a course at a time up from each floor); empty for the rest -- their
## courses count from their bottom.
static func course_starts(sh: Dictionary, tall: int) -> Dictionary:
	var res := {}
	if String(sh.get("kind", "")) != "plan" or int(sh.get("storey", 0)) <= 0:
		return res
	var at := int(sh.get("at", 0))
	var y := at
	var end := at + int(sh.get("depth", 1))
	while y < end:
		if plan_band(sh, y) == "wall" and (y == at or plan_band(sh, y - 1) == "floor"):
			var k := y
			while k < end and plan_band(sh, k) == "wall":
				res[k] = true
				k += maxi(1, tall)
			y = k
		else:
			y += 1
	return res


## A roof on a footprint (Docs/BuildTools.md sections 7, 8): {slopes: [[facing, min cell,
## part?], ...] -- 45-degree slopes (1 stud wide, 2 deep) facing out, and at a hip roof's
## corners a corner slope (its part named) -- and cells: every cell it fills}.
## `a`, `b` the footprint's corners (x, z), `at` its first layer, `ridge` "x" or "z" (the way
## the ridge runs), `style` gable (sloped on the two long sides, the ends closed) or hip (all
## four sides, brick corners). A course a brick high, each stepped in a stud; the last, two or
## three studs across, is the ridge, bricks.
static func roof_plan(sh: Dictionary) -> Dictionary:
	var a := _v2(sh.a)
	var b := _v2(sh.b)
	var along_x := String(sh.get("ridge", "x")) == "x"
	var hip := String(sh.get("style", "gable")) == "hip"
	# Ridge-wise: `al` runs along the ridge, `ac` across it.
	var al := Vector2i(mini(a.x, b.x), maxi(a.x, b.x)) if along_x else Vector2i(mini(a.y, b.y), maxi(a.y, b.y))
	var ac := Vector2i(mini(a.y, b.y), maxi(a.y, b.y)) if along_x else Vector2i(mini(a.x, b.x), maxi(a.x, b.x))
	var y0 := int(sh.get("at", 1))
	var slopes := []
	var cells := {}
	var to3 := func(t: int, c: int, y: int) -> Vector3i:
		return Vector3i(t, y, c) if along_x else Vector3i(c, y, t)
	var out_ac := Vector3i(0, 0, 1) if along_x else Vector3i(1, 0, 0)
	var out_al := Vector3i(1, 0, 0) if along_x else Vector3i(0, 0, 1)
	for k in 200:
		var y := y0 + 3 * k
		var w := ac.y - ac.x + 1
		var l := al.y - al.x + 1
		if w <= 3 or (hip and l <= 3) or w <= 0 or l <= 0:
			for t in range(al.x, al.y + 1):
				for c in range(ac.x, ac.y + 1):
					for dy in 3:
						cells[to3.call(t, c, y + dy)] = true
			break
		var end := 2 if hip else 0
		# A slope fills its back cell and the lower two plates of its front one (the top
		# plate there is the slope's face, open).
		for t in range(al.x + end, al.y - end + 1):
			slopes.append([-out_ac, to3.call(t, ac.x, y)])
			slopes.append([out_ac, to3.call(t, ac.y - 1, y)])
			for c in [ac.x, ac.x + 1, ac.y - 1, ac.y]:
				var front: bool = c == ac.x or c == ac.y
				for dy in (2 if front else 3):
					cells[to3.call(t, c, y + dy)] = true
		if hip:
			for c in range(ac.x + 2, ac.y - 1):
				slopes.append([-out_al, to3.call(al.x, c, y)])
				slopes.append([out_al, to3.call(al.y - 1, c, y)])
				for t in [al.x, al.x + 1, al.y - 1, al.y]:
					var front: bool = t == al.x or t == al.y
					for dy in (2 if front else 3):
						cells[to3.call(t, c, y + dy)] = true
			# The corners: a corner slope each (slopecorner_2x2), low toward both sides.
			for corner in [[al.x, ac.x, -1, -1], [al.y - 1, ac.x, 1, -1], [al.x, ac.y - 1, -1, 1],
					[al.y - 1, ac.y - 1, 1, 1]]:
				var t0: int = corner[0]
				var c0: int = corner[1]
				slopes.append([out_al * int(corner[2]) + out_ac * int(corner[3]), to3.call(t0, c0, y),
						"slopecorner_2x2"])
				# The back cell (toward the middle) is whole; the other three fall away.
				var bt := t0 + (1 if corner[2] < 0 else 0)
				var bc := c0 + (1 if corner[3] < 0 else 0)
				for t in [t0, t0 + 1]:
					for c in [c0, c0 + 1]:
						for dy in (3 if t == bt and c == bc else 2):
							cells[to3.call(t, c, y + dy)] = true
		else:
			# The gable ends, closed.
			for t in [al.x, al.y]:
				for c in range(ac.x + 2, ac.y - 1):
					for dy in 3:
						cells[to3.call(t, c, y + dy)] = true
		ac = Vector2i(ac.x + 1, ac.y - 1)
		if hip:
			al = Vector2i(al.x + 1, al.y - 1)
	return {"slopes": slopes, "cells": cells}


## A shape mirrored across a plane: `axis` 0 (across X) or 2 (across Z), the plane at
## `plane` studs. Its corners, layer, outline, cuts and opening with it; not its bricks.
static func reflected(sh: Dictionary, axis: int, plane: float) -> Dictionary:
	var out := sh.duplicate(true)
	var unit := Vector3i.ZERO
	unit[axis] = 1
	var m := from_3d(String(sh.get("lie", "flat")), unit)
	if m.z != 0:
		if out.has("at"):
			out.at = int(round(2.0 * plane - int(sh.at) - maxi(1, int(sh.get("depth", 1)))))
	else:
		var i := 0 if m.x != 0 else 1
		for k in ["a", "b"]:
			if out.has(k):
				out[k][i] = int(round(2.0 * plane - int(out[k][i]) - 1))
		if out.has("points") and out.points is Dictionary and out.points.has("adds"):
			var fl := func(q: Vector2) -> Vector2:
				var v := q
				v[i] = 2.0 * plane - v[i]
				return v
			out.points = map_plan(out.points, fl)
		elif out.has("points"):
			# A drawn outline is in plane numbers (cell edges); the others are cells.
			var cont := String(sh.get("kind", "")) == "outline"
			var flip := func(q: Variant) -> Array:
				var v := [float(q[0]), float(q[1])]
				v[i] = (2.0 * plane - v[i]) if cont else float(round(2.0 * plane - v[i] - 1))
				return v if cont else [int(v[0]), int(v[1])]
			var pts = out.points
			if pts is Dictionary and pts.has("brush"):
				pts.brush = (pts.brush as Array).map(flip)
			elif pts is Dictionary and pts.has("pts"):
				pts.pts = (pts.pts as Array).map(flip)
			else:
				out.points = (pts as Array).map(flip)
	if out.has("cuts"):
		out.cuts = (out.cuts as Array).map(func(c: Dictionary) -> Dictionary: return reflected(c, axis, plane))
	if out.has("opening"):
		out.opening = reflected(out.opening, axis, plane)
	if out.has("bricks"):
		out.bricks = []
	return out


## A plan's strokes, every point put through `f` (Vector2 -> Vector2, in plane numbers).
static func map_plan(points: Dictionary, f: Callable) -> Dictionary:
	var out := {}
	for k in ["adds", "subs"]:
		var list := []
		for e in points.get(k, []):
			if e is Dictionary:
				var d: Dictionary = e.duplicate(true)
				d.brush = (d.brush as Array).map(func(q: Array) -> Array:
					var v: Vector2 = f.call(Vector2(float(q[0]), float(q[1])))
					return [v.x, v.y])
				list.append(d)
			else:
				list.append((e as Array).map(func(q: Variant) -> Array:
					var v: Vector2 = f.call(q if q is Vector2 else Vector2(float(q[0]), float(q[1])))
					return [v.x, v.y]))
		out[k] = list
	return out


## A shape, a cut or a door's or window's spec moved `d` grid cells: its corners, its layer,
## its outline or brush stroke, its cuts and its opening with it. Its bricks are not (a copy
## is laid fresh).
static func shifted(sh: Dictionary, d: Vector3i) -> Dictionary:
	var out := sh.duplicate(true)
	var m := from_3d(String(sh.get("lie", "flat")), d)
	for k in ["a", "b"]:
		if out.has(k):
			out[k] = [int(out[k][0]) + m.x, int(out[k][1]) + m.y]
	if out.has("at"):
		out.at = int(out.at) + m.z
	if out.has("points") and out.points is Dictionary and out.points.has("adds"):
		var mv := func(q: Vector2) -> Vector2: return q + Vector2(m.x, m.y)
		out.points = map_plan(out.points, mv)
	elif out.has("points"):
		var pts = out.points
		if pts is Dictionary and pts.has("brush"):
			pts.brush = (pts.brush as Array).map(func(q: Array) -> Array: return [float(q[0]) + m.x, float(q[1]) + m.y])
		elif pts is Dictionary and pts.has("pts"):
			pts.pts = (pts.pts as Array).map(func(q: Array) -> Array: return [int(q[0]) + m.x, int(q[1]) + m.y])
		else:
			out.points = (pts as Array).map(func(q: Variant) -> Array:
				var v := q as Vector2 if q is Vector2 else Vector2(float(q[0]), float(q[1]))
				return [v.x + m.x, v.y + m.y])
	if out.has("cuts"):
		out.cuts = (out.cuts as Array).map(func(c: Dictionary) -> Dictionary: return shifted(c, d))
	if out.has("opening"):
		out.opening = shifted(out.opening, d)
	if out.has("bricks"):
		out.bricks = []
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
## `base`: the layer the courses count from (default the lowest cell's). `starts`: if given,
## the layers bricks may start on (`course_starts`), counted as courses in order.
static func pack_courses(cells: Dictionary, parts: Array, staggered: bool = true,
		taken: Dictionary = {}, base: int = 1 << 30, starts: Dictionary = {}) -> Array:
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
	var start_list := starts.keys()
	start_list.sort()
	for y in layers:
		var course: int = floori(float(y - base) / tall)
		var on_course: bool = posmod(y - base, tall) == 0
		if not starts.is_empty():
			on_course = starts.has(y)
			course = start_list.bsearch(y, false) - 1 if not on_course else start_list.find(y)
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
