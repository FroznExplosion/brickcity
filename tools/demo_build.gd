extends SceneTree

## Write a two-frame demo build, so the city can be shown placing one without
## anyone hand-building it first.
##
##     godot --headless --path . --script tools/demo_build.gd
##     godot --path . -- --build
##
## A house in frame 0 and a sideways panel in a frame of its own, welded to the
## wall -- the smallest thing that is not expressible in one grid at all
## (Docs/BuildMode.md section 2.1). The workshop writes the same file with F5;
## this is the same recipe without the mouse.

const OUT := "user://workshop_build.json"


func _init() -> void:
	var w := BrickWorld.new()
	var palette := BrickPalette.bake(w)
	var r := BuildRecipe.new()
	r.name = "demo house and panel"

	# Four walls, six courses, laid so the courses interlock rather than
	# standing as four independent slabs.
	var wide := 14
	var deep := 12
	for course in 6:
		var y := 1 + course * 3
		var col := 4 + (course % 3)
		var flip := course % 2 == 1
		for x in range(0 if flip else 2, wide if flip else wide - 2, 2):
			r.add("brick_2x2", Vector3i(x, y, 0), col)
			r.add("brick_2x2", Vector3i(x, y, deep - 2), col)
		for z in range(2 if flip else 0, deep - 2 if flip else deep, 2):
			r.add("brick_2x2", Vector3i(0, y, z), col)
			r.add("brick_2x2", Vector3i(wide - 2, y, z), col)
	# Two plate layers for the roof, and the second one STAGGERED by half a
	# plate. Stud connectivity is vertical, so plates laid side by side are not
	# joined to each other at all -- two layers on the same grid are two
	# unbonded sheets, and everything that is not directly over a wall comes
	# away as an island the moment the solve runs. Offsetting the second layer
	# is what ties them into one slab, which is the same reason TowerRecipe
	# offsets its floors.
	for x in range(0, wide, 4):
		for z in range(0, deep, 4):
			r.add("plate_4x4", Vector3i(x, 19, z), 2)
	for x in range(2, wide - 2, 4):
		for z in range(2, deep - 2, 4):
			r.add("plate_4x4", Vector3i(x, 20, z), 2)

	# A floor for it, one plate thick, which is what the staircase stands on --
	# and what has to be blown away for the staircase to fall.
	# Short of the +X wall on purpose: the panel hangs off that side, and a floor
	# running right up to it would put house bricks inside a blast aimed at the
	# panel -- which is the one thing the placement gate is there to tell apart.
	for x in range(0, wide - 4, 4):
		for z in range(0, deep, 4):
			r.add("plate_4x4", Vector3i(x, 0, z), 2)

	# The panel: its own frame, turned so its up points along world +X, welded
	# to two courses of the wall it hangs off.
	var rot := _rotation_with_up(w, Vector3(1.0, 0.0, 0.0))
	if rot < 0:
		push_error("[demo] no rotation maps up to +X")
		quit(1)
		return
	var t := BrickWorld.ticks_per_stud()
	# Where the panel's bricks go IN ITS OWN GRID, worked out before the frame
	# is declared: the frame's offset depends on how big it is, because a
	# rotation can send a grid's own (0,0,0) corner anywhere -- including into
	# space the chunk has no cells in. Same correction the workshop applies when
	# it stands its six grids up.
	var cells: Array[Vector3i] = []
	for i in 6:
		@warning_ignore("integer_division")
		var row: int = i / 2
		cells.append(Vector3i(0, row * 3, (i % 2) * 4 + 2))
	var part := BrickPalette.size_of("brick_2x4_z")
	var dims := Vector3i.ONE
	for c in cells:
		dims = Vector3i(maxi(dims.x, c.x + part.x), maxi(dims.y, c.y + part.y),
				maxi(dims.z, c.z + part.z))
	var frame := r.add_frame(rot, Vector3i(wide * t, 0, 0) + _origin_for(w, rot, dims))
	var panel := PackedInt32Array()
	for c in cells:
		panel.push_back(r.add("brick_2x4_z", c, 7, frame))
	r.add_weld(_block_at(r, Vector3i(wide - 2, 1, 4)), panel[0])
	r.add_weld(_block_at(r, Vector3i(wide - 2, 7, 4)), panel[2])

	# A staircase inside, which is Stage 5's half of this: a fixture is
	# authored in the build's own grid and travels with the recipe, dormant,
	# costing nothing until somebody walks into the house.
	@warning_ignore("integer_division")
	var flight: int = (21 - 1) / StaircaseRecipe.STEP_PLATES
	r.add_fixture("staircase", Vector3i(3, 1, 2), {"steps": flight, "colour": 6})

	# Built once here, so a broken recipe is caught by this script rather than
	# by the city three minutes later.
	var asm := Assembly.new(w, palette)
	var placed := r.build_into(asm, palette)
	var err := r.save_to(OUT)
	print("[demo] %d bricks, %d frame(s), %d weld(s), %d fixture(s) -> %s (%s)" % [
			placed, r.frame_count(), asm.live_weld_count(), r.fixture_count(), OUT,
			error_string(err)])
	quit(0 if err == OK and placed == r.size() else 1)


func _block_at(r: BuildRecipe, cell: Vector3i) -> int:
	for i in r.size():
		if r.frame_of(i) == 0 and r.cell_of(i) == cell:
			return i
	return -1


## Where a rotated grid has to start so its own cells land on positive ground
## rather than under it. The workshop's `_origin_for`, for one frame.
func _origin_for(w: BrickWorld, rotation: int, dims: Vector3i) -> Vector3i:
	var probe := w.create_chunk(Vector3i.ZERO, Vector3i(1, 1, 1))
	w.set_chunk_frame(probe, rotation, Vector3i.ZERO)
	var basis: Basis = w.get_chunk_transform(probe).basis
	w.release_chunk(probe)
	var t := BrickWorld.ticks_per_stud()
	var pt := BrickWorld.ticks_per_plate()
	var far: Vector3 = basis * Vector3(dims.x * t, dims.y * pt, dims.z * t)
	return Vector3i(
		int(round(-minf(0.0, far.x))),
		int(round(-minf(0.0, far.y))),
		int(round(-minf(0.0, far.z))))


func _rotation_with_up(w: BrickWorld, up: Vector3) -> int:
	var probe := w.create_chunk(Vector3i.ZERO, Vector3i(1, 1, 1))
	var found := -1
	for r in BrickWorld.rotation_count():
		w.set_chunk_frame(probe, r, Vector3i.ZERO)
		if w.get_chunk_transform(probe).basis.y.is_equal_approx(up):
			found = r
			break
	w.release_chunk(probe)
	return found
