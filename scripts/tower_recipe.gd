class_name TowerRecipe

## A building as a recipe rather than as brick data.
##
## Today it is a test fixture. It is also the shape M3 needs: a building at rest
## is its recipe plus a baked mesh, and brick data is generated on first damage
## (Docs/Plan.md section 2 / spec section 5). Keeping the generator pure and
## re-runnable from parameters is the whole trick, so it is written that way.

const WALL_THICK := 2        # studs
const PLATES_PER_COURSE := 3
## Four brick courses, then a floor, then four more on top of it. The floor
## spans the WHOLE footprint -- walls included -- so it is part of the exterior,
## reads as a band from outside, and the walls above genuinely sit on it.
##
## It is TWO plate layers, offset from each other by half a plate in both
## directions. That is not decoration and it is not thickness for its own sake:
## stud connections are vertical, so plates lying side by side in ONE layer are
## not joined to each other at all. A single-layer floor is held only where its
## edges meet the walls, every interior plate is ungrounded the moment bricks
## exist, and the whole floor drops out on the first solve -- which is exactly
## what it did, twice.
##
## Two offset layers interlock: each plate in the upper layer bridges four in the
## lower one. It is a running bond laid flat, and it is how a real brick floor
## holds together too.
const COURSES_PER_FLOOR := 4
const SLAB_PLATES := 2
const SLAB_COLOUR := 2

# Filament indices, matching brick_grid.h.
const COURSE_COLOURS := [4, 5, 6, 11, 2, 8]  # red, orange, yellow, tan, grey, blue
const BASE_COLOUR := 3                        # dark grey


## Bake the parts this recipe needs: the standard palette plus its own cornice.
##
## The palette itself lives in BrickPalette -- one table, one naming rule, one
## mass rule -- because build mode needs the same list and a test tower has no
## business owning it.
static func bake_palette(world: BrickWorld) -> Dictionary:
	var out := BrickPalette.bake(world)
	out["buttress_2x2"] = bake_buttress(world)
	return out


## A part that does NOT fill its bounding box, used as a cornice so the masked
## path is exercised by the real scene rather than only by a probe.
##
## Profile, looking along +X, with +Z to the right:
##
##     y=2  # .
##     y=1  # .
##     y=0  # #
##          z0 z1
##
## The z=1 column only reaches one plate, so it carries no stud at the bounding
## box top -- and the stud mask says so, which is what stops the next course
## clipping to thin air. That mask is a structural fact the connectivity graph
## reads, not decoration.
static func bake_buttress(world: BrickWorld) -> int:
	var size := Vector3i(2, 3, 2)
	var cells := PackedByteArray()
	cells.resize(size.x * size.y * size.z)
	for z in size.z:
		for y in size.y:
			for x in size.x:
				var solid := 1 if (z == 0 or y == 0) else 0
				cells[x + size.x * (y + size.y * z)] = solid

	var studs := PackedByteArray()
	studs.resize(size.x * size.z)
	for z in size.z:
		for x in size.x:
			studs[x + size.x * z] = 1 if z == 0 else 0

	# Solid all across the underside, so it clips down onto anything.
	var sockets := PackedByteArray()
	sockets.resize(size.x * size.z)
	sockets.fill(1)

	return world.bake_shaped_archetype("buttress_2x2", size, 0.9, cells, studs, sockets)


## The vertical layout of a building, band by band. Both the brick recipe and
## the shell mesh walk this, so what you see at a distance and what you get when
## it materialises are the same building by construction.
static func layout(courses: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var y := 0
	out.append({"kind": "base", "y": y, "plates": SLAB_PLATES})
	y += SLAB_PLATES
	for c in courses:
		out.append({"kind": "course", "y": y, "plates": PLATES_PER_COURSE, "index": c})
		y += PLATES_PER_COURSE
		if (c + 1) % COURSES_PER_FLOOR == 0:
			@warning_ignore("integer_division")
			var floor_number := (c + 1) / COURSES_PER_FLOOR
			out.append({"kind": "slab", "y": y, "plates": SLAB_PLATES, "floor": floor_number})
			y += SLAB_PLATES
	out.append({"kind": "cornice", "y": y, "plates": PLATES_PER_COURSE})
	return out


static func total_plates(courses: int) -> int:
	var l := layout(courses)
	var last: Dictionary = l[l.size() - 1]
	return int(last.y) + int(last.plates)


static func chunk_dims(footprint_x: int, footprint_z: int, courses: int) -> Vector3i:
	return Vector3i(footprint_x, total_plates(courses) + 1, footprint_z)


## Hollow tower: one plate layer of base, then `courses` of bonded brickwork.
##
## Courses alternate which pair of walls owns the corners. On an even course the
## long walls run the full width and the short walls fit between them; on an odd
## course it is the other way round. That quoin bond does two jobs at once:
##
##   * it offsets every wall by WALL_THICK course to course, so vertical joints
##     never line up and a wall is not a stack of independent columns;
##   * it makes the four walls ONE structure. Stud connections need footprints
##     to overlap in XZ, and with a fixed corner the front wall and the side
##     wall never overlap at all -- they would stand and fall separately, which
##     is what the first version of this recipe did.
static func build(world: BrickWorld, chunk_id: int, palette: Dictionary,
		footprint_x: int, footprint_z: int, courses: int) -> void:
	var t := WALL_THICK

	for band in layout(courses):
		match band.kind:
			"base":
				_lay_slab(world, chunk_id, palette, band.y, footprint_x, footprint_z, BASE_COLOUR)
			"slab":
				# Full footprint, walls included. This is what ties the four
				# walls together across the span AND what you see from outside.
				_lay_slab(world, chunk_id, palette, band.y, footprint_x, footprint_z, SLAB_COLOUR)
			"course":
				var colour: int = COURSE_COLOURS[int(band.index) % COURSE_COLOURS.size()]
				var y: int = band.y
				if int(band.index) % 2 == 0:
					_run_x(world, chunk_id, palette, y, 0, footprint_x, 0, colour)
					_run_x(world, chunk_id, palette, y, 0, footprint_x, footprint_z - t, colour)
					_run_z(world, chunk_id, palette, y, t, footprint_z - t, 0, colour)
					_run_z(world, chunk_id, palette, y, t, footprint_z - t, footprint_x - t, colour)
				else:
					_run_z(world, chunk_id, palette, y, 0, footprint_z, 0, colour)
					_run_z(world, chunk_id, palette, y, 0, footprint_z, footprint_x - t, colour)
					_run_x(world, chunk_id, palette, y, t, footprint_x - t, 0, colour)
					_run_x(world, chunk_id, palette, y, t, footprint_x - t, footprint_z - t, colour)
			"cornice":
				for x in range(0, footprint_x - 1, 2):
					world.place_block(chunk_id, Vector3i(x, band.y, 0), palette.buttress_2x2, 1)


## A floor: two full-footprint plate layers, the upper one offset by half a
## plate so it bridges the seams of the lower one. See COURSES_PER_FLOOR for why
## one layer is not a floor.
static func _lay_slab(world: BrickWorld, chunk_id: int, palette: Dictionary,
		y: int, footprint_x: int, footprint_z: int, colour: int) -> void:
	_plate_layer(world, chunk_id, palette, y, 0, footprint_x, footprint_z, colour)
	if SLAB_PLATES > 1:
		_plate_layer(world, chunk_id, palette, y + 1, 2, footprint_x, footprint_z, colour)


## One layer of plates on a 4-stud grid starting at `offset`, closing the edges
## with 2x2s so the footprint is covered whatever the offset leaves over.
static func _plate_layer(world: BrickWorld, chunk_id: int, palette: Dictionary,
		y: int, offset: int, footprint_x: int, footprint_z: int, colour: int) -> void:
	# The strip the offset leaves uncovered at the near edge.
	if offset > 0:
		_fill_2x2(world, chunk_id, palette, y, 0, offset, 0, footprint_z, colour)
		_fill_2x2(world, chunk_id, palette, y, offset, footprint_x, 0, offset, colour)

	var x := offset
	while x < footprint_x:
		var z := offset
		while z < footprint_z:
			if footprint_x - x >= 4 and footprint_z - z >= 4:
				world.place_block(chunk_id, Vector3i(x, y, z), palette.plate_4x4, colour)
				z += 4
			else:
				_fill_2x2(world, chunk_id, palette, y, x, mini(x + 4, footprint_x),
						z, footprint_z, colour)
				break
		x += 4


static func _fill_2x2(world: BrickWorld, chunk_id: int, palette: Dictionary,
		y: int, x0: int, x1: int, z0: int, z1: int, colour: int) -> void:
	var x := x0
	while x + 2 <= x1:
		var z := z0
		while z + 2 <= z1:
			world.place_block(chunk_id, Vector3i(x, y, z), palette.plate_2x2, colour)
			z += 2
		x += 2


## Lay a course along X. Largest piece that fits wins, so a run closes its ends
## with shorter bricks instead of leaving a gap.
static func _run_x(world: BrickWorld, chunk_id: int, palette: Dictionary,
		y: int, x0: int, x1: int, z: int, colour: int) -> void:
	var x := x0
	while x < x1:
		var remaining := x1 - x
		if remaining >= 4 and world.place_block(chunk_id, Vector3i(x, y, z), palette.brick_2x4_x, colour) >= 0:
			x += 4
		elif remaining >= 2 and world.place_block(chunk_id, Vector3i(x, y, z), palette.brick_2x2, colour) >= 0:
			x += 2
		elif world.place_block(chunk_id, Vector3i(x, y, z), palette.brick_1x2_z, colour) >= 0:
			x += 1
		else:
			x += 1  # cell already taken; step over it


static func _run_z(world: BrickWorld, chunk_id: int, palette: Dictionary,
		y: int, z0: int, z1: int, x: int, colour: int) -> void:
	var z := z0
	while z < z1:
		var remaining := z1 - z
		if remaining >= 4 and world.place_block(chunk_id, Vector3i(x, y, z), palette.brick_2x4_z, colour) >= 0:
			z += 4
		elif remaining >= 2 and world.place_block(chunk_id, Vector3i(x, y, z), palette.brick_2x2, colour) >= 0:
			z += 2
		elif world.place_block(chunk_id, Vector3i(x, y, z), palette.brick_1x2_x, colour) >= 0:
			z += 1
		else:
			z += 1


## Rooms, as the recipe knows them. One per floor, the volume between slabs.
## No contents, no doors, no stairs yet -- Docs/Interiors.md.
static func rooms(footprint_x: int, footprint_z: int, courses: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var floor_index := 0
	var lo_y := 1
	for band in layout(courses):
		if band.kind != "slab":
			continue
		out.append({
			"id": floor_index,
			"lo": Vector3i(WALL_THICK, lo_y, WALL_THICK),
			"hi": Vector3i(footprint_x - WALL_THICK, int(band.y), footprint_z - WALL_THICK),
		})
		floor_index += 1
		lo_y = int(band.y) + 1
	return out
## A slab across the interior, lapped onto the wall tops so the walls are tied
## together rather than each standing alone.
static func _lay_floor(world: BrickWorld, chunk_id: int, palette: Dictionary,
		y: int, footprint_x: int, footprint_z: int) -> void:
	var colour := 2  # grey
	var x := 0
	while x < footprint_x:
		var z := 0
		while z < footprint_z:
			var placed := false
			if footprint_x - x >= 4 and footprint_z - z >= 4:
				placed = world.place_block(chunk_id, Vector3i(x, y, z), palette.plate_4x4, colour) >= 0
			if not placed and footprint_x - x >= 2 and footprint_z - z >= 2:
				placed = world.place_block(chunk_id, Vector3i(x, y, z), palette.plate_2x2, colour) >= 0
			z += 4 if footprint_z - z >= 4 else 2
		x += 4 if footprint_x - x >= 4 else 2
