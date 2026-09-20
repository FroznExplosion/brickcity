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
## Outside diameter, in studs. 8 studs is 2.8 m across, which leaves a
## three-stud tread -- just over a metre, for a figure a little under three
## bricks tall.
const DIAMETER := 8
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
	return world.bake_shaped_archetype("stair_step_%d" % sector, size,
			float(n) * BrickPalette.MASS_PER_CELL, cells, solid, solid)


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


## The chunk a flight of this many steps needs, with its foot at the origin.
static func chunk_dims(steps: int) -> Vector3i:
	return Vector3i(DIAMETER, maxi(steps, 1) * STEP_PLATES, DIAMETER)


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
