class_name StaircaseRecipe

## A spiral staircase, as masked wedge archetypes and no frames at all.
##
## Docs/BuildMode.md section 9.1, option A. Eight steps per revolution is 45
## degrees a step, which divides 90, so every step has an integer footprint and
## is an ordinary masked archetype on the fixture's own grid. Option B -- a
## frame per step -- costs 48 entries in a weld table that has to be
## invalidated on block death and 48 per-chunk solves with fixed overhead, and
## buys a smoothness the house style does not want: a brick-built spiral is a
## chunky sequence of eighth turns, and the cheapest option is also the
## correct-looking one.
##
## **The steps rest on the newel, they do not hang off it.** Section 9.3 has the
## number: two studs of contact holds about seven hanging bricks at game scale
## and a step is roughly eight, so a step cantilevered off a central column is
## right at the failure threshold. Each step here carries its own slice of the
## column and stacks on the one below -- compression, which is free
## (BrickFailure section 4.1). What overhangs is the tread, which is meant to
## shed when something hits the building.

## Eight per revolution: 45 degrees, which divides 90.
const STEPS_PER_TURN := 8
## Outside diameter, in studs. Exactly one floor panel, so the stairwell IS a
## lattice cell: the cell is left out of the floor and the flight fills it, with
## its outer edge against the panels around it to clip to.
##
## It was 8, which is a perfectly good stair and the wrong number. A shaft of 8
## inside a cell of 10 touches nothing -- the steps hang on the newel alone and
## every one of them reads as detached.
##
## 10 studs is 3.5 m across, leaving a four-stud tread: a metre and a half, for
## a figure a little under three bricks tall.
const DIAMETER := TowerRecipe.PANEL
## The central column every step carries a slice of, in studs. Two: wide enough
## to be a real load path with a stud joint between one step and the next,
## narrow enough to leave a three-stud tread to walk on.
const NEWEL := 2
## Tread thickness AND rise, in plates. They are the same number on purpose:
## each tread's top is the next tread's underside, so the flight is a
## continuous helicoid rather than a ladder with gaps to fall through.
const STEP_PLATES := 2

## Steps per course of the host building. A course is 3 plates and a step rises
## 2, so a storey of six courses is nine steps.
const STEPS_PER_COURSE := 1.5


## Bake the eight sector archetypes. Returns sector index -> archetype id, as a
## PackedInt32Array indexed by step % STEPS_PER_TURN.
##
## Eight explicit masks rather than one mask in four yaws: the sectors are
## authored from the angle directly, so which way the flight winds is a
## property of this file rather than of the extension's rotation enumeration.
## THE staircase: the workshop's own spiral stair piece (spiralcw_10x10), the
## one a player builds a flight out of by aiming at the newel below, stacked
## the way that aim stacks it -- each piece the next one's quarter turn
## (BrickPalette.next_in_flight). A city tower's stair and a saved build's
## stair fixture are built from it too, so there is one staircase in the game,
## not a player's one and an older generated one beside it.
##
## Returns the four turns of the piece, in flight order, as archetype ids from
## `palette` (BrickPalette.bake's name -> id).
const FLIGHT_PART := "spiralcw_10x10"


static func flight_parts(palette: Dictionary) -> PackedInt32Array:
	var out := PackedInt32Array()
	var name := BrickPalette.variant_name(FLIGHT_PART, 0, false)
	for i in 4:
		if not palette.has(name):
			push_error("StaircaseRecipe: no '%s' in the palette" % name)
			return PackedInt32Array()
		out.push_back(palette[name])
		name = BrickPalette.next_in_flight(name)
	return out


## Plates a flight piece climbs: two steps of STEP_PLATES.
static func flight_piece_plates() -> int:
	return BrickPalette.part_size(FLIGHT_PART).y


## Pieces a flight of `steps` steps takes: a piece is two steps, rounded up.
static func flight_pieces(steps: int) -> int:
	var rise := flight_piece_plates()
	@warning_ignore("integer_division")
	return (steps * STEP_PLATES + rise - 1) / rise


## Lay a flight of `steps` steps at `at`: one spiral piece per two steps,
## stacked and turning. Same shaft and height as the old wedge flight
## (`chunk_dims`), so a stairwell carved for one fits the other.
static func build_flight(world: BrickWorld, chunk: int, parts: PackedInt32Array,
		steps: int, colour: int = 11, at: Vector3i = Vector3i.ZERO) -> int:
	if parts.size() < 4:
		push_error("StaircaseRecipe: the flight pieces are missing")
		return 0
	var rise := flight_piece_plates()
	var placed := 0
	for i in flight_pieces(steps):
		if world.place_block(chunk, at + Vector3i(0, i * rise, 0), parts[i % 4], colour) >= 0:
			placed += 1
	return placed


## The old generated flight's step wedges. Nothing in the game builds with them
## any more (see flight_parts); kept for the probes that pin their shape.
static func bake_parts(world: BrickWorld) -> PackedInt32Array:
	var out := PackedInt32Array()
	for s in STEPS_PER_TURN:
		out.push_back(_bake_step(world, s))
	return out


static func _bake_step(world: BrickWorld, sector: int) -> int:
	var size := Vector3i(DIAMETER, STEP_PLATES, DIAMETER)
	var solid := _mask(sector)
	var cells := PackedByteArray()
	cells.resize(size.x * size.y * size.z)
	var n := 0
	for z in size.z:
		for x in size.x:
			var on: int = 1 if solid[x + size.x * z] != 0 else 0
			for y in size.y:
				cells[x + size.x * (y + size.y * z)] = on
				n += on
	# Studs on top and sockets underneath wherever the part is solid: that is
	# what clips one step's slice of newel to the next one's and makes the
	# column a real load path rather than a drawing of one.
	var id := world.bake_shaped_archetype("stair_step_%d" % sector, size,
			float(n) * BrickPalette.MASS_PER_CELL, cells, solid, solid)
	if id >= 0:
		# Drawn as its real shape rather than as its cells (gap 8). The mask
		# above stays the truth for connectivity, stress and collision -- only
		# the drawing changes -- so a flight still stands, loads and breaks
		# exactly as it did.
		var m := step_mesh(sector)
		world.set_archetype_mesh(id, m[0], m[1])
		# And COLLIDES as that shape, so a figure stands on the tread where it
		# is drawn rather than on the square cells under it.
		world.set_archetype_hulls(id, step_hulls(sector))
	return id


## The two convex pieces a step collides as, in the step's own metres: the
## octagonal newel and the tread.
##
## Both are genuinely convex, which is what a convex shape needs: an octagonal
## prism, and an eighth of an annulus cut off by a straight chord -- a sector of
## 45 degrees is convex, and the chord only removes a convex piece of it. They
## use exactly the vertices step_mesh() draws, so what you see is what you hit.
static func step_hulls(sector: int) -> Array:
	var S := BrickPalette.STUD_M
	var y0 := 0.0
	var y1 := float(STEP_PLATES) * BrickPalette.PLATE_M
	var cx := float(DIAMETER) * 0.5 * S
	var cz := cx
	var rn := float(NEWEL) * 0.5 * S / cos(PI / 8.0)
	var ro := float(DIAMETER) * 0.5 * S
	var step := TAU / float(STEPS_PER_TURN)
	var lo := float(sector) * step
	var hi := lo + step

	var newel := PackedVector3Array()
	for k in STEPS_PER_TURN:
		var a := float(k) * step
		for y in [y0, y1]:
			newel.push_back(Vector3(cx + rn * cos(a), y, cz + rn * sin(a)))

	var tread := PackedVector3Array()
	for y in [y0, y1]:
		tread.push_back(Vector3(cx + rn * cos(lo), y, cz + rn * sin(lo)))
		tread.push_back(Vector3(cx + rn * cos(hi), y, cz + rn * sin(hi)))
		for i in ARC_SEGMENTS + 1:
			var a := lerpf(lo, hi, float(i) / ARC_SEGMENTS)
			tread.push_back(Vector3(cx + ro * cos(a), y, cz + ro * sin(a)))
	return [newel, tread]


## Arc segments per step. Four across 45 degrees keeps the outer edge reading as
## a curve at a metre, which is where the workshop puts the camera.
const ARC_SEGMENTS := 4


## One step's surface, in the step's own metres: [positions, normals], three of
## each a triangle.
##
## An octagonal newel and a tread that is an eighth of an annulus. The octagon's
## vertices sit on the SECTOR boundaries, so a tread's inner edge is exactly one
## side of the octagon and the two meet along it instead of overlapping -- two
## coplanar tops over the same patch would z-fight. That side is the one this
## step leaves out of its newel.
##
## Winding is left to the extension, which turns every triangle to face along
## its normals.
static func step_mesh(sector: int) -> Array:
	var pos := PackedVector3Array()
	var nrm := PackedVector3Array()
	var S := BrickPalette.STUD_M
	var y0 := 0.0
	var y1 := float(STEP_PLATES) * BrickPalette.PLATE_M
	var cx := float(DIAMETER) * 0.5 * S
	var cz := cx
	# The newel's INradius is the mask's half-width, so the octagon sits inside
	# the square column the connectivity graph sees, touching its sides.
	var rn := float(NEWEL) * 0.5 * S / cos(PI / 8.0)
	var ro := float(DIAMETER) * 0.5 * S
	var step := TAU / float(STEPS_PER_TURN)
	var lo := float(sector) * step
	var hi := lo + step

	var at := func(r: float, a: float, y: float) -> Vector3:
		return Vector3(cx + r * cos(a), y, cz + r * sin(a))
	var radial := func(a: float) -> Vector3:
		return Vector3(cos(a), 0.0, sin(a))
	var tri := func(a: Vector3, b: Vector3, c: Vector3, na: Vector3, nb: Vector3, nc: Vector3) -> void:
		pos.append_array([a, b, c])
		nrm.append_array([na, nb, nc])
	var flat := func(a: Vector3, b: Vector3, c: Vector3, n: Vector3) -> void:
		tri.call(a, b, c, n, n, n)

	var up := Vector3.UP
	var down := Vector3.DOWN
	var p_lo: Vector3 = at.call(rn, lo, 0.0)
	var p_hi: Vector3 = at.call(rn, hi, 0.0)

	# --- tread: top and bottom, a strip from the chord out to the arc -------
	for i in ARC_SEGMENTS:
		var t0 := float(i) / ARC_SEGMENTS
		var t1 := float(i + 1) / ARC_SEGMENTS
		for y in [y0, y1]:
			var n: Vector3 = up if y == y1 else down
			var in0 := p_lo.lerp(p_hi, t0) + Vector3(0, y, 0)
			var in1 := p_lo.lerp(p_hi, t1) + Vector3(0, y, 0)
			var o0: Vector3 = at.call(ro, lerpf(lo, hi, t0), y)
			var o1: Vector3 = at.call(ro, lerpf(lo, hi, t1), y)
			flat.call(in0, in1, o1, n)
			flat.call(in0, o1, o0, n)

	# --- tread: the outer wall, shaded smooth so it reads as a curve --------
	for i in ARC_SEGMENTS:
		var a0 := lerpf(lo, hi, float(i) / ARC_SEGMENTS)
		var a1 := lerpf(lo, hi, float(i + 1) / ARC_SEGMENTS)
		var b0: Vector3 = at.call(ro, a0, y0)
		var b1: Vector3 = at.call(ro, a1, y0)
		var t0: Vector3 = at.call(ro, a0, y1)
		var t1: Vector3 = at.call(ro, a1, y1)
		var n0: Vector3 = radial.call(a0)
		var n1: Vector3 = radial.call(a1)
		tri.call(b0, b1, t1, n0, n1, n1)
		tri.call(b0, t1, t0, n0, n1, n0)

	# --- tread: the two risers, one at each end of the sector ---------------
	for end in [[lo, Vector3(sin(lo), 0.0, -cos(lo))], [hi, Vector3(-sin(hi), 0.0, cos(hi))]]:
		var a: float = end[0]
		var n: Vector3 = end[1]
		var i0: Vector3 = at.call(rn, a, y0)
		var i1: Vector3 = at.call(rn, a, y1)
		var o0: Vector3 = at.call(ro, a, y0)
		var o1: Vector3 = at.call(ro, a, y1)
		flat.call(i0, o0, o1, n)
		flat.call(i0, o1, i1, n)

	# --- newel: an octagonal prism, less the side the tread joins -----------
	var c0 := Vector3(cx, y0, cz)
	var c1 := Vector3(cx, y1, cz)
	for k in STEPS_PER_TURN:
		var a0 := float(k) * step
		var a1 := float(k + 1) * step
		flat.call(c1, at.call(rn, a0, y1), at.call(rn, a1, y1), up)
		flat.call(c0, at.call(rn, a1, y0), at.call(rn, a0, y0), down)
		if k == sector:
			continue  # the tread's inner edge; inside solid
		var n: Vector3 = radial.call((a0 + a1) * 0.5)
		var b0: Vector3 = at.call(rn, a0, y0)
		var b1: Vector3 = at.call(rn, a1, y0)
		var u0: Vector3 = at.call(rn, a0, y1)
		var u1: Vector3 = at.call(rn, a1, y1)
		flat.call(b0, b1, u1, n)
		flat.call(b0, u1, u0, n)

	return [pos, nrm]


## Which columns of the bounding box this sector fills: the whole newel, plus
## the eighth of the annulus this step treads on.
static func _mask(sector: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(DIAMETER * DIAMETER)
	var centre := float(DIAMETER) * 0.5
	var half_newel := float(NEWEL) * 0.5
	var outer := float(DIAMETER) * 0.5
	var lo := float(sector) * TAU / float(STEPS_PER_TURN)
	var hi := float(sector + 1) * TAU / float(STEPS_PER_TURN)
	for z in DIAMETER:
		for x in DIAMETER:
			var dx := float(x) + 0.5 - centre
			var dz := float(z) + 0.5 - centre
			var on := false
			if absf(dx) <= half_newel and absf(dz) <= half_newel:
				on = true  # the newel, carried by every step
			else:
				var r := sqrt(dx * dx + dz * dz)
				var a := fposmod(atan2(dz, dx), TAU)
				on = r <= outer and a >= lo and a < hi
			out[x + DIAMETER * z] = 1 if on else 0
	return out


## How many steps reach the top of a building of this many courses.
static func steps_for_courses(courses: int) -> int:
	return maxi(int(round(float(courses) * STEPS_PER_COURSE)), STEPS_PER_TURN)


## The chunk a flight of this many steps needs, with its foot at the origin:
## whole spiral pieces, so an odd flight's top piece has its room carved too.
static func chunk_dims(steps: int) -> Vector3i:
	return Vector3i(DIAMETER, maxi(flight_pieces(steps), 1) * flight_piece_plates(), DIAMETER)


## Local bounds of the flight, in metres, for the volume tests that wake it.
static func bounds(steps: int) -> AABB:
	var d: Vector3i = chunk_dims(steps)
	var cell := BrickWorld.get_cell_size()
	return AABB(Vector3.ZERO, Vector3(d.x * cell.x, d.y * cell.y, d.z * cell.z))


## Place the flight into a chunk, at `at` in that chunk's own cells. Returns how
## many steps went in.
##
## Every step goes at the same footprint corner and only the height changes: the
## sector lives in the mask, so the recipe is a loop over y.
##
## A step that does not fit is SKIPPED rather than aborting the flight -- the
## host's own bricks are already there and a staircase that runs into a floor
## should lose that step, not fail to exist.
static func build(world: BrickWorld, chunk: int, parts: PackedInt32Array,
		steps: int, colour: int = 11, at: Vector3i = Vector3i.ZERO) -> int:
	if parts.size() < STEPS_PER_TURN:
		push_error("StaircaseRecipe: the step archetypes have not been baked")
		return 0
	var placed := 0
	for i in steps:
		var id: int = parts[i % STEPS_PER_TURN]
		if world.place_block(chunk, at + Vector3i(0, i * STEP_PLATES, 0), id, colour) >= 0:
			placed += 1
	return placed
