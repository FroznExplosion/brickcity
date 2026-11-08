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
##           (`points` {pts, closed, more}: a wall line, `more` the lines joined to it),
##           cells (`points`: the cells themselves, a
##           floor), roof (its own: `roof_plan`), or plan (a floor plan: `points`
##           {adds, subs} of strokes; filled, walls along its outline, or a building with a
##           floor each storey -- `plan_cells`)
##   lie     flat (on a plane: u = x, v = z, stacked up y), wall_x (standing, u = x,
##           v = y, stacked along z) or wall_z (u = z, v = y, stacked along x)
##   a, b    the corners dragged, [u, v] cells; the box between them is the shape's
##   at      the first layer along the stacking axis; `depth` layers from there
##   rim     a hollow rectangle's, ring's or line's thickness, in studs
##   points  a sketched shape's outline, [[u, v], ...] in cells, or its brush stroke
##           (WkSketchPen.brush_entry); its kind is "outline"
##
## A kept shape has more (tall/thick, bond, part, colour, cuts, bricks): `WorkshopTools`.

## The grid geometry is the editor kit's (WkShapes, addons/workshop_kit): this file keeps what
## is bricks -- kept shapes, plans, roofs, courses.
const KINDS := WkShapes.KINDS
const LIES := WkShapes.LIES


## How tall a v cell is next to a u cell, in metres: 1 on a flat plane, 0.4 standing up
## (v is plates there, u studs).
static func aspect(lie: String) -> float:
	return 1.0 if lie == "flat" else BrickPalette.PLATE_M / BrickPalette.STUD_M


## Every grid cell a shape (or a cut) fills, before its cuts: its 2D cells, `depth`
## layers from `at`.
static func solid_cells(sh: Dictionary) -> Dictionary:
	if String(sh.get("kind", "")) == "roof":
		return roof_plan(sh).cells
	if String(sh.get("kind", "")) == "plan":
		return plan_cells(sh)
	var lie := String(sh.get("lie", "flat"))
	var a := WkShapes.v2i(sh.get("a", [0, 0]))
	var b := WkShapes.v2i(sh.get("b", [0, 0]))
	var c2 := WkShapes.cells_2d(String(sh.get("kind", "rect")), a, b, int(sh.get("rim", 1)), aspect(lie),
			sh.get("points", []))
	var at := int(sh.get("at", 0))
	var out := {}
	for k in maxi(1, int(sh.get("depth", 1))):
		for c in c2:
			out[WkShapes.to_3d(lie, c, at + k)] = true
	return out


## A kept shape's cells: what it fills less what its cuts take out.
static func shape_cells(sh: Dictionary) -> Dictionary:
	var out := solid_cells(sh)
	for cut in sh.get("cuts", []):
		for c in solid_cells(cut):
			out.erase(c)
	return out


## `shape_cells`, only inside `box`: a big building's cells are many and a cut reaches few.
static func shape_cells_in(sh: Dictionary, box: AABB) -> Dictionary:
	var lo := Vector3i(box.position.floor())
	var hi := Vector3i(box.end.ceil())
	var out := {}
	if String(sh.get("kind", "")) == "plan":
		var region := WkShapes.plan_region(sh.get("points", {}))
		var walls := region if bool(sh.get("fill", false)) else WkShapes.ring(region, int(sh.get("rim", 1)))
		var near_floor := []
		var near_wall := []
		for c in region:
			if c.x >= lo.x and c.x < hi.x and c.y >= lo.z and c.y < hi.z:
				near_floor.append(c)
				if walls.has(c):
					near_wall.append(c)
		var at := int(sh.get("at", 0))
		for y in range(maxi(at, lo.y), mini(at + maxi(1, int(sh.get("depth", 1))), hi.y)):
			for c in near_floor if plan_band(sh, y) == "floor" else near_wall:
				out[Vector3i(c.x, y, c.y)] = true
	else:
		for c in solid_cells(sh):
			if c.x >= lo.x and c.y >= lo.y and c.z >= lo.z and c.x < hi.x and c.y < hi.y and c.z < hi.z:
				out[c] = true
	for cut in sh.get("cuts", []):
		if _misses(cut, lo, hi):
			continue
		for c in solid_cells(cut):
			out.erase(c)
	return out


## True for a rect cut clear of this box, told without working out its cells.
static func _misses(cut: Dictionary, lo: Vector3i, hi: Vector3i) -> bool:
	if String(cut.get("kind", "")) != "rect":
		return false
	var l := String(cut.get("lie", "flat"))
	var at := int(cut.get("at", 0))
	var a := WkShapes.to_3d(l, WkShapes.v2i(cut.a), at)
	var b := WkShapes.to_3d(l, WkShapes.v2i(cut.b), at + maxi(1, int(cut.get("depth", 1))) - 1)
	return mini(a.x, b.x) >= hi.x or maxi(a.x, b.x) < lo.x or mini(a.y, b.y) >= hi.y or maxi(a.y, b.y) < lo.y \
			or mini(a.z, b.z) >= hi.z or maxi(a.z, b.z) < lo.z


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
	var region := WkShapes.plan_region(sh.get("points", {}))
	var walls := region if bool(sh.get("fill", false)) else WkShapes.ring(region, int(sh.get("rim", 1)))
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
	var a := WkShapes.v2i(sh.a)
	var b := WkShapes.v2i(sh.b)
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
	var m := WkShapes.from_3d(String(sh.get("lie", "flat")), unit)
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
				if pts.has("more"):
					pts.more = (pts.more as Array).map(func(line: Array) -> Array: return line.map(flip))
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
			if e is Dictionary and e.has("kind"):
				var c: Dictionary = e.duplicate(true)
				for end in ["a", "b"]:
					var w: Vector2 = f.call(Vector2(float(c[end][0]) + 0.5, float(c[end][1]) + 0.5)) - Vector2(0.5, 0.5)
					c[end] = [int(round(w.x)), int(round(w.y))]
				list.append(c)
			elif e is Dictionary:
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
	var m := WkShapes.from_3d(String(sh.get("lie", "flat")), d)
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
			var mv2 := func(q: Array) -> Array: return [int(q[0]) + m.x, int(q[1]) + m.y]
			pts.pts = (pts.pts as Array).map(mv2)
			if pts.has("more"):
				pts.more = (pts.more as Array).map(func(line: Array) -> Array: return line.map(mv2))
		else:
			out.points = (pts as Array).map(func(q: Variant) -> Array:
				var v := q as Vector2 if q is Vector2 else Vector2(float(q[0]), float(q[1]))
				return [v.x + m.x, v.y + m.y])
	if out.has("cuts"):
		out.cuts = (out.cuts as Array).map(func(c: Dictionary) -> Dictionary: return shifted(c, d))
	if out.has("opening"):
		out.opening = shifted(out.opening, d)
	if out.has("openings"):
		out.openings = (out.openings as Array).map(func(c: Dictionary) -> Dictionary: return shifted(c, d))
	if out.has("bricks"):
		out.bricks = []
	return out


# ---------------------------------------------------------------------------
# Courses: cells to bricks of the held kind
# ---------------------------------------------------------------------------

## The parts a shape of `held` is laid with: `held` itself, the biggest, and the smaller
## ones of its family as tall as it with a footprint inside its own; then plates of those
## footprints, for where less than a brick's height is left. Each both ways round, as
## [variant name, size], biggest first. `palette`: name -> archetype, so only parts the
## workshop has.
static func parts_for(held: String, palette: Dictionary, strict: bool = false) -> Array:
	var part := BrickPalette.part_of(held)
	if part == "":
		part = held
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
		# `strict`: this brick and no other (as many as fit; the rest stays empty).
		if (same or plate) and (not strict or String(p) == part):
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
## the layers bricks may start on (`course_starts`), counted as courses in order. `strict`:
## only the held brick, so a staggered course's start is a gap, not a half brick.
static func pack_courses(cells: Dictionary, parts: Array, staggered: bool = true,
		taken: Dictionary = {}, base: int = 1 << 30, starts: Dictionary = {}, strict: bool = false) -> Array:
	if parts.is_empty() or not ClassDB.class_has_method("BrickWorld", "pack_courses"):
		return pack_courses_script(cells, parts, staggered, taken, base, starts, strict)
	# In the engine (Docs/BuildTools.md section 18): the same rule as below, line for line.
	var sizes := PackedInt32Array()
	for p in parts:
		var size: Vector3i = p[1]
		sizes.append_array([size.x, size.y, size.z])
	var got: PackedInt32Array = ClassDB.class_call_static("BrickWorld", "pack_courses", cells, sizes, staggered,
			taken, base, starts, strict)
	var out := []
	@warning_ignore("integer_division")
	out.resize(got.size() / 4)
	for i in out.size():
		out[i] = [parts[got[i * 4]][0], Vector3i(got[i * 4 + 1], got[i * 4 + 2], got[i * 4 + 3])]
	return out


## `pack_courses` in script: what a library without `BrickWorld.pack_courses` uses, and what a
## probe holds the engine's to.
static func pack_courses_script(cells: Dictionary, parts: Array, staggered: bool = true,
		taken: Dictionary = {}, base: int = 1 << 30, starts: Dictionary = {}, strict: bool = false) -> Array:
	var out := []
	var left := {}
	var by_y := {}
	for c in cells:
		if not taken.has(c):
			left[c] = true
			(by_y.get_or_add(c.y, []) as Array).append(c)
	if left.is_empty() or parts.is_empty():
		return out
	var layers := by_y.keys()
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
	# All a run is asked is whether it passes two widths, and which way is longer.
	var run_cap := 2 * wide + 1
	var start_list := starts.keys()
	start_list.sort()
	for y in layers:
		var course: int = floori(float(y - base) / tall)
		var on_course: bool = posmod(y - base, tall) == 0
		if not starts.is_empty():
			on_course = starts.has(y)
			course = start_list.bsearch(y, false) - 1 if not on_course else start_list.find(y)
		var along_x: bool = not staggered or course % 2 == 0
		for c in _row_order(by_y[y], along_x):
			if not left.has(c):
				continue
			var nx := _run(cells, c, Vector3i(1, 0, 0), run_cap)
			var nz := _run(cells, c, Vector3i(0, 0, 1), run_cap)
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
					if strict:
						# No half brick to start with: the gap, and the run goes on after it.
						for k in half:
							for dy in tall:
								left.erase(c + dir * k + Vector3i(0, dy, 0))
						continue
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


## One layer's cells row by row along the course's own way, from the low corner. Sorted as
## numbers: a floor is thousands of cells, and a comparison in script is slow.
static func _row_order(list: Array, along_x: bool) -> Array:
	const OFF := 1 << 20
	var y: int = (list[0] as Vector3i).y
	var keys := PackedInt64Array()
	keys.resize(list.size())
	var i := 0
	for c: Vector3i in list:
		var row := c.z if along_x else c.x
		var at := c.x if along_x else c.z
		keys[i] = (row + OFF) << 24 | (at + OFF)
		i += 1
	keys.sort()
	var out := []
	out.resize(keys.size())
	i = 0
	for k in keys:
		var row := (k >> 24) - OFF
		var at := (k & 0xFFFFFF) - OFF
		out[i] = Vector3i(at, y, row) if along_x else Vector3i(row, y, at)
		i += 1
	return out


## How many cells of the shape run through `c` along `dir`, both ways: up to `cap`.
static func _run(cells: Dictionary, c: Vector3i, dir: Vector3i, cap: int) -> int:
	var n := 1
	var p := c + dir
	while n < cap and cells.has(p):
		n += 1
		p += dir
	p = c - dir
	while n < cap and cells.has(p):
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
