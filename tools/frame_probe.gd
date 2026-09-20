extends SceneTree

## Acceptance probe for Stage 4 of build mode: FRAMES.
##
##     godot --headless --path . --script tools/frame_probe.gd
##
## The gate, from Docs/BuildMode.md section 11:
##
##   A sideways-faced wall stands, takes damage locally, and sheds its sideways
##   frame when the bricks holding it die -- with no dangling weld left behind.
##
## Frames are the only thing in build mode that makes DESTRUCTION harder, so
## most of this is about the seams: that cross-frame alignment stays exact
## integers, that occupancy still cannot see across a frame boundary unless
## something asks, and that the one stored graph in the system cannot go stale.

var _pass := 0
var _fail := 0


func _init() -> void:
	print("frame probe (Stage 4)")
	_check_ticks()
	_check_rotations()
	_check_tick_boxes_are_exact()
	_check_cross_frame_overlap()
	_check_welds_derive_aliveness()
	_check_seed_grounding()
	_check_co_located_grids()
	_check_the_gate()
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s" % what)
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _world() -> Array:
	var w := BrickWorld.new()
	return [w, BrickPalette.bake(w)]


## Find the rotation index that turns the part on its side: local +Y ends up
## along world +Z. The enumeration order of the 24 is an implementation detail,
## so the probe looks it up rather than hard-coding a number.
func _sideways_rotation(w: BrickWorld) -> int:
	var c := w.create_chunk(Vector3i.ZERO, Vector3i(2, 2, 2))
	for r in BrickWorld.rotation_count():
		w.set_chunk_frame(c, r, Vector3i.ZERO)
		var b: Basis = w.get_chunk_transform(c).basis
		if b.y.is_equal_approx(Vector3(0, 0, 1)):
			return r
	return -1


# ---------------------------------------------------------------------------

func _check_ticks() -> void:
	print("\nticks")
	_ok("a stud is 5 ticks", BrickWorld.ticks_per_stud() == 5,
			"%d" % BrickWorld.ticks_per_stud())
	_ok("a plate is 2 ticks", BrickWorld.ticks_per_plate() == 2,
			"%d" % BrickWorld.ticks_per_plate())

	# The coincidence the whole design rests on, asserted in integers rather
	# than trusted: 5 plates is exactly 2 studs, so a rotated frame's plate axis
	# is commensurate with an upright frame's stud axis.
	_ok("5 plates == 2 studs, exactly",
			5 * BrickWorld.ticks_per_plate() == 2 * BrickWorld.ticks_per_stud(),
			"%d vs %d" % [5 * BrickWorld.ticks_per_plate(), 2 * BrickWorld.ticks_per_stud()])

	# And in metres, because if the two ever disagree the grid is broken.
	_ok("a tick is 0.07 m from the stud side",
			is_equal_approx(BrickPalette.STUD_M / BrickWorld.ticks_per_stud(), 0.07))
	_ok("and 0.07 m from the plate side",
			is_equal_approx(BrickPalette.PLATE_M / BrickWorld.ticks_per_plate(), 0.07))


func _check_rotations() -> void:
	print("\nrotations")
	_ok("there are 24 axis-aligned rotations", BrickWorld.rotation_count() == 24,
			"%d" % BrickWorld.rotation_count())

	var res := _world()
	var w: BrickWorld = res[0]
	var c: int = w.create_chunk(Vector3i.ZERO, Vector3i(4, 4, 4))

	# Every one must be a proper rotation: orthonormal, determinant +1. A
	# mirrored part is a different part, not a turned one.
	var bad_det := 0
	var bad_axis := 0
	var seen := {}
	for r in BrickWorld.rotation_count():
		w.set_chunk_frame(c, r, Vector3i.ZERO)
		var b: Basis = w.get_chunk_transform(c).basis
		if not is_equal_approx(b.determinant(), 1.0):
			bad_det += 1
		for v in [b.x, b.y, b.z]:
			# Axis-aligned: exactly one component is +-1 and the rest are 0.
			var nonzero := 0
			for i in 3:
				if absf(v[i]) > 0.001:
					nonzero += 1
					if not is_equal_approx(absf(v[i]), 1.0):
						bad_axis += 1
			if nonzero != 1:
				bad_axis += 1
		seen["%v|%v|%v" % [b.x, b.y, b.z]] = true
	_ok("every rotation has determinant +1", bad_det == 0, "%d bad" % bad_det)
	_ok("every axis maps to a signed axis", bad_axis == 0, "%d bad" % bad_axis)
	_ok("all 24 are distinct", seen.size() == 24, "%d" % seen.size())

	_ok("one of them lays the part on its side", _sideways_rotation(w) >= 0)

	# An out-of-range rotation is refused rather than wrapped.
	w.set_chunk_frame(c, 3, Vector3i(10, 0, 0))
	w.set_chunk_frame(c, 99, Vector3i(0, 0, 0))
	_ok("a bad rotation index changes nothing", w.get_chunk_rotation(c) == 3,
			"%d" % w.get_chunk_rotation(c))
	_ok("and neither does the offset it came with",
			w.get_chunk_origin_ticks(c) == Vector3i(10, 0, 0),
			"%v" % w.get_chunk_origin_ticks(c))


func _check_tick_boxes_are_exact() -> void:
	print("\na block's box in world ticks")
	var res := _world()
	var w: BrickWorld = res[0]
	var c: int = w.create_chunk(Vector3i.ZERO, Vector3i(16, 16, 16))
	var b := w.place_block(c, Vector3i(0, 0, 0), res[1]["brick_2x4_x"], 0)
	_ok("placed", b >= 0)

	var box: Array = w.get_block_ticks(c, b)
	_ok("upright: 4 studs x 3 plates x 2 studs in ticks",
			box[1] == Vector3i(20, 6, 10), "%v" % box[1])
	_ok("at the origin", box[0] == Vector3i.ZERO, "%v" % box[0])

	# Rotate the frame: the box has to rotate with it and stay integer. Volume
	# is the invariant -- a signed permutation maps a box to a box exactly, so
	# there is no bounding-box slop to lose.
	var vol: int = box[1].x * box[1].y * box[1].z
	var bad := 0
	for r in BrickWorld.rotation_count():
		w.set_chunk_frame(c, r, Vector3i(3, 5, 7))
		var rb: Array = w.get_block_ticks(c, b)
		var v: Vector3i = rb[1]
		if v.x * v.y * v.z != vol or v.x <= 0 or v.y <= 0 or v.z <= 0:
			bad += 1
	_ok("every rotation keeps the volume and stays positive", bad == 0, "%d bad" % bad)

	# The frame offset lands the box exactly where it says, with no rounding.
	w.set_chunk_frame(c, 0, Vector3i(3, 5, 7))
	_ok("the tick offset moves the box by exactly that much",
			(w.get_block_ticks(c, b)[0] as Vector3i) == Vector3i(3, 5, 7),
			"%v" % w.get_block_ticks(c, b)[0])


func _check_cross_frame_overlap() -> void:
	print("\ncross-frame overlap")
	var res := _world()
	var w: BrickWorld = res[0]
	var asm := Assembly.new(w, res[1])
	var a := asm.add_frame(Vector3i(16, 16, 16), 0, Vector3i.ZERO)
	var brick: int = res[1]["brick_2x4_x"]
	asm.place(a, Vector3i(0, 0, 0), brick, 4)

	# A second frame sitting exactly on top of the first, in ticks.
	var b := asm.add_frame(Vector3i(16, 16, 16), 0, Vector3i.ZERO)
	_ok("occupancy alone does NOT see across a frame boundary",
			w.can_place(b, Vector3i(0, 0, 0), brick))
	_ok("but the assembly does, and refuses it",
			not asm.can_place(b, Vector3i(0, 0, 0), brick))
	_ok("so the placement is rejected",
			asm.place(b, Vector3i(0, 0, 0), brick, 4) < 0)

	# Clear of it in ticks, it is fine. One brick is 20 ticks along X.
	w.set_chunk_frame(b, 0, Vector3i(20, 0, 0))
	_ok("moved clear in tick space, it places",
			asm.place(b, Vector3i(0, 0, 0), brick, 4) >= 0)

	# One tick of overlap still counts: the test is exact, not approximate.
	var d := asm.add_frame(Vector3i(16, 16, 16), 0, Vector3i(39, 0, 0))
	_ok("one tick of overlap is still an overlap",
			not asm.can_place(d, Vector3i(0, 0, 0), brick))
	w.set_chunk_frame(d, 0, Vector3i(40, 0, 0))
	_ok("exactly flush is not an overlap",
			asm.can_place(d, Vector3i(0, 0, 0), brick))


func _check_welds_derive_aliveness() -> void:
	print("\nwelds derive their aliveness, never cache it")
	var res := _world()
	var w: BrickWorld = res[0]
	var asm := Assembly.new(w, res[1])
	var a := asm.add_frame(Vector3i(8, 16, 8))
	var b := asm.add_frame(Vector3i(8, 16, 8), 0, Vector3i(40, 0, 0))
	var ba := asm.place(a, Vector3i(0, 0, 0), res[1]["brick_2x2"], 4)
	var bb := asm.place(b, Vector3i(0, 0, 0), res[1]["brick_2x2"], 5)

	var wid := asm.weld(a, ba, b, bb)
	_ok("welded", wid >= 0)
	_ok("it is alive", w.is_weld_alive(wid))
	_ok("and the assembly counts it", asm.live_weld_count() == 1)

	# THE point: nothing invalidates the weld when a block dies. Killing one end
	# is enough, because aliveness is a question asked of the blocks, not a flag
	# written when they died.
	w.kill_block(a, Vector3i(0, 0, 0))
	_ok("killing one end kills the weld, with no bookkeeping",
			not w.is_weld_alive(wid))
	_ok("and the assembly agrees", asm.live_weld_count() == 0)
	_ok("the weld record is still there, just not load-bearing",
			w.get_weld_count() == 1 and not (w.get_weld(wid).alive as bool))
	_ok("get_live_welds leaves it out", not w.get_live_welds().has(wid))

	# A bad weld is refused rather than stored.
	_ok("a weld to a block that does not exist is refused",
			w.add_weld(a, 999, b, bb) < 0)
	_ok("and a weld into a chunk that does not exist", w.add_weld(a, ba, 999, 0) < 0)

	# Removing a weld is an EDIT: permanent, and distinct from it dying.
	var w2 := asm.weld(b, bb, b, bb)
	_ok("removing a weld works", w.remove_weld(w2))
	_ok("and it stays removed", not w.is_weld_alive(w2))


func _check_seed_grounding() -> void:
	print("\ngrounding from an explicit seed set")
	var res := _world()
	var w: BrickWorld = res[0]
	var c: int = w.create_chunk(Vector3i.ZERO, Vector3i(8, 32, 8))
	var ids := []
	for y in 5:
		ids.append(w.place_block(c, Vector3i(0, y * 3, 0), res[1]["brick_2x2"], 4))

	# With no seeds nothing is grounded -- which is exactly what a rotated frame
	# looks like before its weld is taken into account.
	var none: PackedByteArray = w.solve_grounded_from(c, PackedInt32Array())
	_ok("no seeds, nothing grounded", none.count(1) == 0, "%d" % none.count(1))

	# Seeded from the TOP block, the whole stack is reachable -- grounding is a
	# connectivity question, and a weld can seed it from anywhere.
	var top: PackedByteArray = w.solve_grounded_from(c, PackedInt32Array([ids[4]]))
	_ok("seeded from the top, the whole stack is reached",
			top.count(1) == 5, "%d of 5" % top.count(1))

	# Cut the stack and the far half is no longer reachable from the seed.
	w.kill_block(c, Vector3i(0, 6, 0))
	var cut: PackedByteArray = w.solve_grounded_from(c, PackedInt32Array([ids[0]]))
	_ok("a cut stack only grounds the half joined to the seed",
			cut.count(1) == 2, "%d" % cut.count(1))
	_ok("an out-of-range seed is ignored, not a crash",
			(w.solve_grounded_from(c, PackedInt32Array([9999])) as PackedByteArray).count(1) == 0)


# ---------------------------------------------------------------------------
# Six grids over one volume, which is what makes building sideways usable.
# ---------------------------------------------------------------------------

## The workshop stands all six build grids up front, co-located, rather than
## creating one on demand. This pins the two properties that makes rely on:
##
##   1. every grid's cells land inside the SAME tick cube, so switching grid
##      changes orientation and not where you are;
##   2. a world point converts into any grid and back without drifting more
##      than the cell it is in.
##
## The first version failed both. It created a sideways frame at an offset
## derived from the cursor's cell in the PREVIOUS grid, so the new grid landed
## somewhere unrelated -- and bricks placed in it appeared nowhere near where
## they were aimed.
func _check_co_located_grids() -> void:
	print("\nsix co-located build grids")
	var res := _world()
	var w: BrickWorld = res[0]
	var asm := Assembly.new(w, res[1])

	var studs := 48
	var plates := 120
	var t := BrickWorld.ticks_per_stud()
	var pt := BrickWorld.ticks_per_plate()
	_ok("the build volume is a cube in ticks", studs * t == plates * pt,
			"%d vs %d" % [studs * t, plates * pt])
	var span := studs * t

	var dims := Vector3i(studs, plates, studs)
	var ups := [Vector3(0, 1, 0), Vector3(0, 0, 1), Vector3(0, 0, -1),
			Vector3(1, 0, 0), Vector3(-1, 0, 0), Vector3(0, -1, 0)]
	var probe := w.create_chunk(Vector3i.ZERO, Vector3i(1, 1, 1))

	for up in ups:
		# The rotation whose own +Y points along this world axis.
		var rot := -1
		for r in BrickWorld.rotation_count():
			w.set_chunk_frame(probe, r, Vector3i.ZERO)
			if w.get_chunk_transform(probe).basis.y.is_equal_approx(up):
				rot = r
				break
		_ok("a rotation exists with up = %v" % up, rot >= 0)
		if rot < 0:
			continue

		w.set_chunk_frame(probe, rot, Vector3i.ZERO)
		var b: Basis = w.get_chunk_transform(probe).basis
		var far: Vector3 = b * Vector3(dims.x * t, dims.y * pt, dims.z * t)
		var origin := Vector3i(int(round(-minf(0.0, far.x))),
				int(round(-minf(0.0, far.y))), int(round(-minf(0.0, far.z))))
		asm.add_frame(dims, rot, origin)

	w.release_chunk(probe)
	_ok("six grids stand", asm.frames.size() == 6, "%d" % asm.frames.size())

	# Every grid's near and far corner has to sit inside the one tick cube.
	var outside := 0
	for f in asm.frames:
		var near := w.place_block(f, Vector3i(0, 0, 0), res[1]["brick_1x1"], 4)
		var far_b := w.place_block(f, Vector3i(studs - 1, plates - 3, studs - 1),
				res[1]["brick_1x1"], 4)
		for bid in [near, far_b]:
			if bid < 0:
				outside += 1
				continue
			var box: Array = w.get_block_ticks(f, bid)
			var lo: Vector3i = box[0]
			var hi: Vector3i = lo + (box[1] as Vector3i)
			if lo.x < 0 or lo.y < 0 or lo.z < 0 \
					or hi.x > span or hi.y > span or hi.z > span:
				outside += 1
	_ok("every grid's cells land inside the same tick cube", outside == 0,
			"%d corners outside" % outside)

	# A world point round-trips through any grid to within the cell it is in.
	# This is the conversion the ghost uses, and getting it wrong is exactly the
	# bug: the cursor says one thing and the brick appears somewhere else.
	var p := Vector3(3.25, 0.33, 4.30)
	var drifted := 0
	for f in asm.frames:
		var local: Vector3 = w.get_chunk_transform(f).affine_inverse() * p
		var cell := Vector3i(
			int(floor(local.x / BrickPalette.STUD_M)),
			int(floor(local.y / BrickPalette.PLATE_M)),
			int(floor(local.z / BrickPalette.STUD_M)))
		var back: Vector3 = w.get_chunk_transform(f) * BrickWorld.grid_to_world(cell)
		# One cell is 0.35 m on its longest side, so anything under that is the
		# floor, not a lost point.
		if (back - p).length() > BrickPalette.STUD_M * 1.3:
			drifted += 1
	_ok("a world point converts into every grid without drifting", drifted == 0,
			"%d grids lost it" % drifted)


# ---------------------------------------------------------------------------
# The gate
# ---------------------------------------------------------------------------

func _check_the_gate() -> void:
	print("\nthe gate: a sideways-faced wall")
	var res := _world()
	var w: BrickWorld = res[0]
	var asm := Assembly.new(w, res[1])

	# The wall: an upright frame, eight courses, standing on the ground.
	var wall := asm.add_frame(Vector3i(12, 40, 4), 0, Vector3i.ZERO)
	var wall_blocks := []
	for course in 8:
		for x in range(0, 8, 2):
			wall_blocks.append(asm.place(wall, Vector3i(x, course * 3, 0),
					res[1]["brick_2x2"], 4))
	w.set_foundation_level(wall, 0)
	_ok("the wall stands", wall_blocks.size() == 32 and not wall_blocks.has(-1))

	# The sideways panel: a frame laid on its side, clear of the wall in ticks
	# and held on only by welds. Its own grid is ordinary -- studs are studs and
	# plates are plates inside it -- which is the entire point of a frame.
	var rot := _sideways_rotation(w)
	_ok("found the sideways rotation", rot >= 0)
	# The wall is 8 studs = 40 ticks wide and sits at z in [0, 2 studs) = 10
	# ticks. Put the panel just beyond its far face.
	var panel := asm.add_frame(Vector3i(6, 12, 6), rot, Vector3i(0, 6, 12))
	var panel_blocks := []
	for i in 3:
		panel_blocks.append(asm.place(panel, Vector3i(i * 2, 0, 0),
				res[1]["brick_2x2"], 8))
	_ok("the panel places in its own frame", not panel_blocks.has(-1))
	# It must genuinely be clear of the wall in tick space, not merely welded to
	# it: two frames that overlap would put solid geometry inside solid geometry
	# and nothing in the occupancy grid could ever notice.
	var clash := 0
	for pb in panel_blocks:
		clash += (w.get_frame_overlaps(panel, pb, wall) as PackedInt32Array).size()
	_ok("and no panel brick is inside the wall", clash == 0, "%d clashes" % clash)

	# Weld it on, low down, to two wall bricks.
	var w1 := asm.weld(wall, wall_blocks[0], panel, panel_blocks[0])
	var w2 := asm.weld(wall, wall_blocks[1], panel, panel_blocks[1])
	_ok("welded on by two bricks", w1 >= 0 and w2 >= 0)
	_ok("both welds are live", asm.live_weld_count() == 2)

	# Standing: the wall is grounded by its foundation, the panel THROUGH the
	# welds. Without seed-set grounding the panel has no foundation of its own
	# and would read as ungrounded the moment anything solved.
	var state := asm.detached_frames()
	_ok("the wall is attached", (state.attached as Array).has(wall))
	_ok("and so is the sideways panel", (state.attached as Array).has(panel),
			"attached=%s detached=%s" % [state.attached, state.detached])
	_ok("nothing has come loose", (state.detached as Array).is_empty())

	# Local damage: shoot the wall somewhere else. The panel must not care.
	w.kill_block(wall, Vector3i(6, 18, 0))
	var after_local := asm.detached_frames()
	_ok("damage elsewhere leaves the panel on",
			(after_local.attached as Array).has(panel))
	_ok("and both welds are still live", asm.live_weld_count() == 2)

	# Now kill the bricks the welds actually hold on to.
	w.kill_block(wall, Vector3i(0, 0, 0))
	_ok("one weld died with its brick", asm.live_weld_count() == 1)
	_ok("the panel is still held by the other one",
			(asm.detached_frames().attached as Array).has(panel))

	w.kill_block(wall, Vector3i(2, 0, 0))
	_ok("the second weld died too", asm.live_weld_count() == 0)

	var shed := asm.detached_frames()
	_ok("THE GATE: the panel sheds when the bricks holding it die",
			(shed.detached as Array).has(panel),
			"attached=%s detached=%s" % [shed.attached, shed.detached])
	_ok("the wall itself is still standing", (shed.attached as Array).has(wall))

	# No dangling weld left behind: the records still exist, none are live, and
	# nothing had to be invalidated to make that true.
	_ok("both weld records survive", w.get_weld_count() >= 2)
	_ok("and neither is live", w.get_live_welds().is_empty())
	_ok("the panel's own bricks are untouched -- it sheds, it does not vaporise",
			w.get_alive_block_count(panel) == 3, "%d" % w.get_alive_block_count(panel))
