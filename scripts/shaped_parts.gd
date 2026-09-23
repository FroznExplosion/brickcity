class_name ShapedParts

## Parts that are not boxes: slopes, curved slopes, round bricks, arches.
##
## Gap 8 made these cheap. An archetype can carry an authored surface the face
## bake draws and convex hulls both collision paths use, while its CELL MASK
## stays the truth for connectivity, stress and occupancy. So a shaped part is
## three things -- cells, triangles, hulls -- and the whole trick of this file
## is that all three come from ONE description of the shape:
##
##   * the shape is a polygon PROFILE extruded along one axis;
##   * the triangles are that extrusion's faces;
##   * the profile is also cut into convex pieces, and each piece's corners
##     are one collision hull;
##   * the cell mask is the pieces SAMPLED -- a cell is solid when at least half
##     of it is inside the shape.
##
## Written three times, the three would drift, and a part drawn one shape,
## colliding as another and connecting as a third is exactly the bug gap 8
## exists to prevent. Written once, they cannot.
##
## Every part is authored in its canonical orientation (W along X, H plates up
## Y, L along Z) and the extension turns it for every other orientation --
## cells, faces, triangles and hulls together (BrickWorld.bake_variant).
##
## Studs and sockets are not written down either. A column carries a stud when
## the solid reaches the part's full height there, and a socket when it reaches
## the floor: that is what gives a slope studs only on its flat back strip and
## an arch sockets only under its pillars.

const S := BrickPalette.STUD_M
const P := BrickPalette.PLATE_M

## Samples per cell side when computing the mask. 6 x 6 x 6 tells "mostly
## inside" from "mostly outside" with room to spare, and the whole palette of
## these bakes in a few milliseconds, once.
const SAMPLES := 6
## Low poly, on purpose. Every curve is facets at 45 degrees -- a round brick
## is an octagon, a curved slope two facets, an arch half an octagon -- the
## same language as the octagonal studs and the staircase's newel. Octagons
## rather than hexagons because the grid is square: an octagon turned a
## quarter is itself, so a round brick keeps one orientation, where a hexagon
## would have a front and need four.
const ROUND_SEGMENTS := 8
## Facets in a quarter turn of curve (a curved slope's fall, half an arch).
const ARC_SEGMENTS := 2
## Facets are shaded flat. The smooth-normal path stays for a smooth variant
## one day; set this false and every curve edge shades round again.
const FACETED := true


## Everything the palette needs to bake one shaped part in its canonical size:
## {cells, studs, sockets, solid, positions, normals, hulls}.
##
## `kind` is "slope", "curve", "round" or "arch". `axis` ("z" or "x") is the
## direction a slope or curve falls along -- toward -axis, so the low edge is
## the part's front at 0 and the high back carries the studs.
static func build(kind: String, size: Vector3i, axis := "z") -> Dictionary:
	var shape := _shape(kind, size, axis)
	var out := _mask(shape.pieces, size)
	var mesh := _mesh(shape.draw)
	out["positions"] = mesh[0]
	out["normals"] = mesh[1]
	var hulls := []
	for pr in shape.pieces:
		hulls.append(_hull(pr))
	out["hulls"] = hulls
	# A curved slope is smooth all over, like the real part: nothing clips to a
	# curve, and a stud stood on one would float half in the air.
	if kind == "curve":
		out["studs"] = _zeros(size.x * size.z)
	return out


# ---------------------------------------------------------------------------
# The shapes
#
# A prism is {poly, plane, lo, hi, smooth}: a polygon in `plane` ("zy", "xy" or
# "xz" -- the two axes it is drawn in, in that order) extruded along the third
# axis from `lo` to `hi` metres. `smooth[i]` marks edge i (poly[i] ->
# poly[i+1]) as part of a curve, shaded smooth rather than faceted.
#
# A shape is {draw, pieces}: prisms to DRAW (any simple polygon) and convex
# prisms to COLLIDE and SAMPLE. For a convex shape they are the same prism.
# ---------------------------------------------------------------------------

static func _shape(kind: String, size: Vector3i, axis: String) -> Dictionary:
	match kind:
		"slope":
			var p := _slope_prism(size, axis, false)
			return {"draw": [p], "pieces": [p]}
		"curve":
			var p := _slope_prism(size, axis, true)
			return {"draw": [p], "pieces": [p]}
		"round":
			var p := _round_prism(size)
			return {"draw": [p], "pieces": [p]}
		"arch":
			return _arch(size)
		"spiral":
			return _spiral(size, false)
		"spiral_ccw":
			return _spiral(size, true)
	push_error("ShapedParts: no shape '%s'" % kind)
	var box := _prism(PackedVector2Array([Vector2(0, 0), Vector2(size.z * S, 0),
			Vector2(size.z * S, size.y * P), Vector2(0, size.y * P)]), "zy", 0.0, size.x * S)
	return {"draw": [box], "pieces": [box]}


static func _prism(poly: PackedVector2Array, plane: String, lo: float, hi: float,
		smooth: Array = []) -> Dictionary:
	if smooth.is_empty():
		smooth.resize(poly.size())
		smooth.fill(false)
	return {"poly": poly, "plane": plane, "lo": lo, "hi": hi, "smooth": smooth}


## A slope falling toward the part's front along `axis`: a flat strip one stud
## deep at the back carries the studs, the slope falls across the rest, and a
## one-plate lip stands at the front. Those are the real part's proportions,
## and like the real "45 degree" slope the angle is not 45: two plates down
## over one stud is atan(6.4 / 8.0), 38.7 degrees, in print and in game alike.
##
## `curved` bows the fall outward instead, a quarter ellipse from the top of the
## back to the front of the floor, with no lip and no flat strip.
static func _slope_prism(size: Vector3i, axis: String, curved: bool) -> Dictionary:
	var h := size.y * P
	# The profile is drawn across the depth the slope falls over and extruded
	# along its width.
	var depth := (size.z if axis == "z" else size.x) * S
	var width := (size.x if axis == "z" else size.z) * S
	var plane := "zy" if axis == "z" else "xy"
	var poly := PackedVector2Array([Vector2(0, 0), Vector2(depth, 0), Vector2(depth, h)])
	var smooth := [false, false]                 # floor, back
	if curved:
		# Centred on the back corner of the floor, bulging out: ARC_SEGMENTS
		# facets from the top of the back round to the front of the floor.
		for i in range(1, ARC_SEGMENTS):
			var t := float(i) / ARC_SEGMENTS * PI * 0.5
			poly.append(Vector2(depth - depth * sin(t), h * cos(t)))
		# Every remaining edge is curve -- including the one closing back to
		# (0, 0), which is the curve's last facet.
		while smooth.size() < poly.size():
			smooth.append(true)
	else:
		var flat := minf(S, depth * 0.5)          # the stud-bearing back strip
		poly.append(Vector2(depth - flat, h))
		poly.append(Vector2(0, P))
		smooth.append_array([false, false, false])
	return _prism(poly, plane, 0.0, width, smooth)


## A round brick: an octagonal prism with its flats on the footprint's edges,
## so it is exactly as wide as the brick it replaces and only the corners are
## cut. The studs on top fit inside it: a 2x2's studs reach 0.35 m out along
## the diagonal and the diagonal flat is 0.35 m from the centre.
static func _round_prism(size: Vector3i) -> Dictionary:
	var apothem := minf(size.x, size.z) * S * 0.5
	var r := apothem / cos(PI / ROUND_SEGMENTS)
	var c := Vector2(size.x * S * 0.5, size.z * S * 0.5)
	var poly := PackedVector2Array()
	var smooth := []
	for i in ROUND_SEGMENTS:
		# Offset half a segment so the first flat, not a corner, faces +X.
		var a := TAU * (float(i) + 0.5) / ROUND_SEGMENTS
		poly.append(c + Vector2(cos(a), sin(a)) * r)
		smooth.append(true)
	return _prism(poly, "xz", 0.0, size.y * P, smooth)


## An arch along its length (Z): a pillar one stud long at each end, a beam one
## plate thick across the top, and between them an opening that springs from
## the floor at the pillars and rises to the beam at mid-span.
##
## The opening makes the profile non-convex, so it is DRAWN as one outline and
## COLLIDES as convex pieces: the two pillars, the beam, and the haunches
## between curve and beam in slices. A single hull would fill the opening in.
static func _arch(size: Vector3i) -> Dictionary:
	var w := size.x * S
	var h := size.y * P
	var l := size.z * S
	var rise := h - P
	var a0 := S
	var a1 := l - S
	# The opening's underside: half an ellipse spanning a0..a1 and rising to
	# the beam, in ARC_SEGMENTS facets a side -- half an octagon.
	var mid := (a0 + a1) * 0.5
	var half := (a1 - a0) * 0.5
	var curve := PackedVector2Array()
	var n := ARC_SEGMENTS * 2
	for i in n + 1:
		var t := PI * float(i) / n
		curve.append(Vector2(mid - half * cos(t), rise * sin(t)))
	curve[0] = Vector2(a0, 0.0)
	curve[n] = Vector2(a1, 0.0)

	# The outline, counter-clockwise: floor under the near pillar, up and over
	# the opening, floor under the far pillar, up the far end, back along the
	# top, down the near end.
	var outline := PackedVector2Array([Vector2(0, 0)])
	var smooth := [false]
	for i in n + 1:
		outline.append(curve[i])
		smooth.append(i < n)
	outline.append_array([Vector2(l, 0), Vector2(l, h), Vector2(0, h)])
	smooth.append_array([false, false, false])
	var draw := _prism(outline, "zy", 0.0, w, smooth)

	var rect := func(z0: float, z1: float, y0: float, y1: float) -> Dictionary:
		return _prism(PackedVector2Array([Vector2(z0, y0), Vector2(z1, y0),
				Vector2(z1, y1), Vector2(z0, y1)]), "zy", 0.0, w)
	var pieces := [rect.call(0.0, a0, 0.0, h), rect.call(a1, l, 0.0, h),
			rect.call(a0, a1, rise, h)]
	# Haunches: one per facet, between it and the underside of the beam.
	for i in n:
		var p0 := curve[i]
		var p1 := curve[i + 1]
		if rise - minf(p0.y, p1.y) < 1e-4:
			continue  # the crown: nothing between curve and beam
		var poly := PackedVector2Array([p0, p1])
		# A facet touching the crown makes a triangle; a quad there would repeat
		# a corner, and a hull does not want a zero-length edge.
		if rise - p1.y > 1e-4:
			poly.append(Vector2(p1.x, rise))
		if rise - p0.y > 1e-4:
			poly.append(Vector2(p0.x, rise))
		pieces.append(_prism(poly, "zy", 0.0, w))
	return {"draw": [draw], "pieces": pieces}


## A quarter of a spiral staircase: the newel, and two steps.
##
## The real part this follows is the spiral stair step, whose inner end is a
## round 2x2 that stacks on the step below and turns on it. Here the turn is a
## quarter -- the grid allows no other -- so one piece carries TWO steps, 45
## degrees each, and four pieces make a revolution of eight. Each piece is:
##
##   * the newel, the full height of the piece: the same octagon as a
##     `round_2x2`, centred in the footprint, with its studs on top and its
##     sockets underneath. That is the load path -- piece stacks on piece by
##     four stud joints, compression all the way down -- and a round brick
##     stacks on it as well as on itself;
##   * the lower tread, the sector from 0 to 45 degrees, from the floor to one
##     rise; and the upper tread, 45 to 90 degrees, from one rise to two. Tread
##     thickness equals the rise, so the flight is continuous underneath.
##
## Every tread edge runs along the grid or at exactly 45 degrees through grid
## points, and the outline is the octagon whose corners are on the grid (a cut
## at x + z = R + round(R (sqrt 2 - 1))). So a cell is whole, empty or cut
## straight across its diagonal, and the stud rule -- a stud only where its
## whole footprint is on the part -- leaves no stud hanging off a curve.
##
## Winding. Seen from above, +X to +Z is CLOCKWISE (a quarter turn about +Y
## takes +X to -Z). The clockwise piece has its lower tread toward +X and its
## upper toward +Z, and the next piece up is it turned one quarter (yaw + 1).
## `ccw` mirrors it across the diagonal: lower toward +Z, upper toward +X, and
## the next piece is turned the other way (yaw - 1). A mirror is not one of the
## eight grid orientations -- a flip turns studs down -- so the two windings
## are two parts, as the two hands of a real stair are.
static func _spiral(size: Vector3i, ccw: bool) -> Dictionary:
	var h := size.y * P
	var rise := h * 0.5
	var R := size.x * 0.5                              # radius, in studs
	var c0 := roundf(R * (sqrt(2.0) - 1.0))
	var m := (R + c0) * 0.5                            # where the cut meets the diagonal
	var centre := Vector2(size.x * S * 0.5, size.z * S * 0.5)
	var at := func(u: float, v: float) -> Vector2:
		return centre + (Vector2(v, u) if ccw else Vector2(u, v)) * S
	var newel: Dictionary = _round_prism(Vector3i(2, size.y, 2))
	var np := PackedVector2Array()
	for q in (newel.poly as PackedVector2Array):
		np.append(q - Vector2(S, S) + centre)
	newel.poly = np
	var lower := _prism(PackedVector2Array([at.call(0, 0), at.call(R, 0), at.call(R, c0),
			at.call(m, m)]), "xz", 0.0, rise)
	var upper := _prism(PackedVector2Array([at.call(0, 0), at.call(m, m), at.call(c0, R),
			at.call(0, R)]), "xz", rise, h)
	# The treads run into the newel: three convex pieces whose union is the
	# part, each one a collision hull. The overlap is inside the newel, where
	# the faces it leaves are buried.
	var pieces := [newel, lower, upper]
	return {"draw": pieces, "pieces": pieces, "overlapping": true}


# ---------------------------------------------------------------------------
# Profile space <-> part space
# ---------------------------------------------------------------------------

## A profile point plus the extrusion coordinate -> a point in the part.
static func _to3(plane: String, p: Vector2, e: float) -> Vector3:
	match plane:
		"zy":
			return Vector3(e, p.y, p.x)
		"xy":
			return Vector3(p.x, p.y, e)
		_:  # "xz"
			return Vector3(p.x, e, p.y)


## The inverse: a point in the part -> [profile point, extrusion coordinate].
static func _from3(plane: String, v: Vector3) -> Array:
	match plane:
		"zy":
			return [Vector2(v.z, v.y), v.x]
		"xy":
			return [Vector2(v.x, v.y), v.z]
		_:
			return [Vector2(v.x, v.z), v.y]


static func _axis(plane: String) -> Vector3:
	return _to3(plane, Vector2.ZERO, 1.0)


static func _signed_area(poly: PackedVector2Array) -> float:
	var a := 0.0
	for i in poly.size():
		a += poly[i].cross(poly[(i + 1) % poly.size()])
	return a * 0.5


## Inside a CONVEX polygon: on the inner side of every edge.
static func _inside(poly: PackedVector2Array, q: Vector2) -> bool:
	var sgn := signf(_signed_area(poly))
	for i in poly.size():
		var a := poly[i]
		var e := poly[(i + 1) % poly.size()] - a
		if e.cross(q - a) * sgn < -1e-9:
			return false
	return true


static func _prism_has(pr: Dictionary, v: Vector3) -> bool:
	var f := _from3(pr.plane, v)
	if f[1] < pr.lo - 1e-6 or f[1] > pr.hi + 1e-6:
		return false
	return _inside(pr.poly, f[0])


# ---------------------------------------------------------------------------
# The three things
# ---------------------------------------------------------------------------

## Cells, studs, sockets and the solid-cell count, sampled from the pieces.
static func _mask(pieces: Array, size: Vector3i) -> Dictionary:
	var cells := PackedByteArray()
	cells.resize(size.x * size.y * size.z)
	var solid := 0
	var total := SAMPLES * SAMPLES * SAMPLES
	for z in size.z:
		for y in size.y:
			for x in size.x:
				var hit := 0
				for sy in SAMPLES:
					for sz in SAMPLES:
						for sx in SAMPLES:
							var v := Vector3(
								(x + (sx + 0.5) / SAMPLES) * S,
								(y + (sy + 0.5) / SAMPLES) * P,
								(z + (sz + 0.5) / SAMPLES) * S)
							for pr in pieces:
								if _prism_has(pr, v):
									hit += 1
									break
				var on := hit * 2 >= total
				cells[x + size.x * (y + size.y * z)] = 1 if on else 0
				solid += 1 if on else 0

	# A stud stands on a column's highest solid cell -- at whatever height that
	# is, which is how the extension reads it (a spiral piece's lower tread has
	# studs a rise below its top) -- and only where the stud's whole footprint
	# is on the part: its centre and eight points round it, just under the
	# face. Half a cell is enough to CONNECT through; it is not enough to stand
	# a stud on, which would hang off a curve or a slope.
	var studs := _zeros(size.x * size.z)
	var sockets := _zeros(size.x * size.z)
	for z in size.z:
		for x in size.x:
			var top := -1
			for y in size.y:
				if cells[x + size.x * (y + size.y * z)] != 0:
					top = y
			if top >= 0 and _covered(pieces, x, z, (top + 1) * P - 1e-4):
				studs[x + size.x * z] = 1
			if cells[x + size.x * (size.y * z)] != 0:
				sockets[x + size.x * z] = 1
	return {"cells": cells, "studs": studs, "sockets": sockets, "solid": solid}


## Is a stud's footprint on the part at height `y`, over column (x, z)? The
## stud is 0.6 of a stud across; its inner 0.4 is what is sampled, which lets a
## 2x2 round's corner studs stand on its octagon as a real one's do on its
## circle.
static func _covered(pieces: Array, x: int, z: int, y: float) -> bool:
	for du in [-0.2, 0.0, 0.2]:
		for dv in [-0.2, 0.0, 0.2]:
			var v := Vector3((x + 0.5 + du) * S, y, (z + 0.5 + dv) * S)
			var hit := false
			for pr in pieces:
				if _prism_has(pr, v):
					hit = true
					break
			if not hit:
				return false
	return true


## Every face of the drawn prisms, as triangles with normals.
##
## Winding is the extension's job -- it turns each triangle to face along its
## normals (BrickWorld.set_archetype_mesh) -- so only the normals matter here.
##
## Flat walls are cut on the cell grid. The bake hides a triangle lying on a
## cell boundary when the cell beyond holds an ordinary brick, judging by the
## cell at the triangle's centre; a slope's floor drawn as one quad across four
## cells would vanish whole on a plate covering one. Cut per cell, exactly the
## covered part goes. (Caps are not cut. A cap is a side of the part, and a
## neighbour beside a slope covers all of that side or none of it far more
## often than not; where it does not, the cap shows or hides whole.)
static func _mesh(prisms: Array) -> Array:
	var pos := PackedVector3Array()
	var nrm := PackedVector3Array()
	var cell := Vector3(S, P, S)
	for pr in prisms:
		var poly: PackedVector2Array = pr.poly
		var plane: String = pr.plane
		var n := poly.size()
		var ax := _axis(plane)
		var ccw := _signed_area(poly) > 0.0

		# Caps, triangulated -- the arch's outline is not convex, so no fan.
		var tris := Geometry2D.triangulate_polygon(poly)
		for e in [pr.lo, pr.hi]:
			var cap_n: Vector3 = ax if e == pr.hi else -ax
			for i in tris.size():
				pos.append(_to3(plane, poly[tris[i]], e))
				nrm.append(cap_n)

		# Outward edge normals: to the right of travel for a counter-clockwise
		# polygon, to the left for a clockwise one.
		var edge_n := []
		for i in n:
			var d := poly[(i + 1) % n] - poly[i]
			var out := Vector2(d.y, -d.x).normalized()
			edge_n.append(out if ccw else -out)

		var smooth: Array = pr.smooth
		for i in n:
			var j := (i + 1) % n
			var fn: Vector2 = edge_n[i]
			var ni := fn
			var nj := fn
			if smooth[i] and not FACETED:
				var prev := (i - 1 + n) % n
				if smooth[prev]:
					ni = ((edge_n[prev] as Vector2) + fn).normalized()
				if smooth[j]:
					nj = (fn + (edge_n[j] as Vector2)).normalized()
			var p0 := poly[i]
			var p1 := poly[j]
			var n3i := _to3(plane, ni, 0.0)
			var n3j := _to3(plane, nj, 0.0)
			var flat := absf(fn.x) > 0.9999 or absf(fn.y) > 0.9999
			# Where to cut: along the extrusion for a flat wall, and along the
			# edge too -- a flat wall's edge runs along a grid axis.
			var e_cuts := _cuts(pr.lo, pr.hi, ax.dot(cell)) if flat else [pr.lo, pr.hi]
			var t_cuts := [0.0, 1.0]
			if flat:
				var a3 := _to3(plane, p0, 0.0)
				var b3 := _to3(plane, p1, 0.0)
				for k in 3:
					if absf(b3[k] - a3[k]) > 1e-6:
						t_cuts = []
						for c in _cuts(minf(a3[k], b3[k]), maxf(a3[k], b3[k]), cell[k]):
							t_cuts.append(inverse_lerp(a3[k], b3[k], c))
						t_cuts.sort()
			for ti in t_cuts.size() - 1:
				var q0 := p0.lerp(p1, t_cuts[ti])
				var q1 := p0.lerp(p1, t_cuts[ti + 1])
				var m0 := n3i.lerp(n3j, t_cuts[ti]).normalized()
				var m1 := n3i.lerp(n3j, t_cuts[ti + 1]).normalized()
				for ei in e_cuts.size() - 1:
					var a0 := _to3(plane, q0, e_cuts[ei])
					var a1 := _to3(plane, q1, e_cuts[ei])
					var b0 := _to3(plane, q0, e_cuts[ei + 1])
					var b1 := _to3(plane, q1, e_cuts[ei + 1])
					pos.append_array([a0, a1, b1, a0, b1, b0])
					nrm.append_array([m0, m1, m1, m0, m1, m0])
	return [pos, nrm]


## Grid lines strictly between lo and hi at pitch `step`, with both ends.
static func _cuts(lo: float, hi: float, step: float) -> Array:
	var out := [lo]
	var k := floori(lo / step + 1e-4) + 1
	while k * step < hi - 1e-4:
		out.append(k * step)
		k += 1
	out.append(hi)
	return out


## A convex piece's corners, which is all a convex hull needs.
static func _hull(pr: Dictionary) -> PackedVector3Array:
	var out := PackedVector3Array()
	for e in [pr.lo, pr.hi]:
		for p in (pr.poly as PackedVector2Array):
			out.append(_to3(pr.plane, p, e))
	return out


static func _zeros(n: int) -> PackedByteArray:
	var a := PackedByteArray()
	a.resize(n)
	a.fill(0)
	return a
