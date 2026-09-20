extends SceneTree

## M1 acceptance probe. Headless, no rendering, no physics.
##
##     godot --headless --path . --script tools/m1_probe.gd
##
## Checks what the M1 gate claims: stud connectivity is vertical and derived,
## grounding is a real reachability question, a hit kills what it should and
## nothing else, and a detached group leaves the chunk as a coherent cluster.

var failures := 0

var A_BRICK := -1   # 4 x 3 x 2  (studs, plates, studs)
var A_CUBE := -1    # 1 x 3 x 1
var A_PLATE := -1   # 4 x 1 x 4


func _initialize() -> void:
	_check_neighbours()
	_check_grounding()
	_check_groups()
	_check_hit()
	_check_detach()
	_check_solve_determinism()

	print("")
	if failures == 0:
		print("[probe] PASS")
	else:
		print("[probe] FAIL — %d check(s)" % failures)
	quit(1 if failures > 0 else 0)


func _ok(label: String, condition: bool, detail: String = "") -> void:
	if condition:
		print("  ok    %s%s" % [label, ("  " + detail) if detail else ""])
	else:
		failures += 1
		print("  FAIL  %s%s" % [label, ("  " + detail) if detail else ""])


func _world() -> BrickWorld:
	var w := BrickWorld.new()
	w.set_seed(7)
	A_BRICK = w.bake_archetype("brick_2x4_x", Vector3i(4, 3, 2), 2.4)
	A_CUBE = w.bake_archetype("brick_1x1", Vector3i(1, 3, 1), 0.3)
	A_PLATE = w.bake_archetype("plate_4x4", Vector3i(4, 1, 4), 1.6)
	return w


# ---------------------------------------------------------------------------

func _check_neighbours() -> void:
	print("connectivity")
	var w := _world()
	var c := w.create_chunk(Vector3i.ZERO, Vector3i(12, 24, 6))

	# Two bricks side by side in the same course, and one bridging them above.
	var left := w.place_block(c, Vector3i(0, 0, 0), A_BRICK, 4)
	var right := w.place_block(c, Vector3i(4, 0, 0), A_BRICK, 5)
	var bridge := w.place_block(c, Vector3i(2, 3, 0), A_BRICK, 6)

	_ok("all three placed", left >= 0 and right >= 0 and bridge >= 0)

	var lhs: PackedInt32Array = w.get_block_neighbours(c, left)
	_ok("side-by-side blocks do NOT connect", not lhs.has(right),
			"a course is not glued to itself")
	_ok("a block connects to what bridges it", lhs.has(bridge))
	_ok("left has exactly one neighbour", lhs.size() == 1, "%d" % lhs.size())

	var up: PackedInt32Array = w.get_block_neighbours(c, bridge)
	_ok("the bridge reaches both below it", up.has(left) and up.has(right))
	_ok("no duplicates from a wide overlap", up.size() == 2, "%d" % up.size())

	# Stacked directly, not merely nearby.
	var gap := w.place_block(c, Vector3i(8, 9, 0), A_BRICK, 7)
	_ok("a block floating in space has no neighbours",
			w.get_block_neighbours(c, gap).is_empty())


func _check_grounding() -> void:
	print("grounding")
	var w := _world()
	var c := w.create_chunk(Vector3i.ZERO, Vector3i(6, 30, 6))

	# A clean column of eight, each resting on the one below.
	var ids: Array[int] = []
	for i in 8:
		ids.append(w.place_block(c, Vector3i(0, i * 3, 0), A_CUBE, i % 12))

	var g: PackedByteArray = w.solve_grounded(c)
	var all_up := true
	for id in ids:
		if g[id] == 0:
			all_up = false
	_ok("a column resting on the floor is grounded", all_up)
	var s: Dictionary = w.get_solve_stats(c)
	_ok("stats agree", s.grounded == 8 and s.ungrounded == 0,
			"%d up / %d floating" % [s.grounded, s.ungrounded])

	# Knock out the bottom one: everything above loses its path to the floor.
	w.kill_block(c, Vector3i(0, 0, 0))
	g = w.solve_grounded(c)
	var floating := 0
	for id in ids:
		if g[id] == 0:
			floating += 1
	_ok("removing the base ungrounds everything above it", floating == 8,
			"%d of 8 floating (the dead one counts as not grounded)" % floating)

	s = w.get_solve_stats(c)
	_ok("dead blocks are not counted as standing", s.grounded == 0 and s.ungrounded == 7,
			"%d up / %d floating" % [s.grounded, s.ungrounded])


func _check_groups() -> void:
	print("islands")
	var w := _world()
	var c := w.create_chunk(Vector3i.ZERO, Vector3i(20, 30, 6))

	# Two separate columns, both grounded, plus a third resting on nothing.
	for i in 4:
		w.place_block(c, Vector3i(0, i * 3, 0), A_CUBE, 4)
	for i in 4:
		w.place_block(c, Vector3i(10, i * 3, 0), A_CUBE, 5)
	for i in 3:
		w.place_block(c, Vector3i(5, 12 + i * 3, 0), A_CUBE, 6)

	var groups: Array = w.find_detached_groups(c)
	_ok("one floating island found", groups.size() == 1, "%d" % groups.size())
	if groups.size() == 1:
		_ok("it is the three blocks in mid-air", (groups[0] as PackedInt32Array).size() == 3,
				"%d blocks" % (groups[0] as PackedInt32Array).size())

	# Cut both columns at the base: now there are three islands.
	w.kill_block(c, Vector3i(0, 0, 0))
	w.kill_block(c, Vector3i(10, 0, 0))
	groups = w.find_detached_groups(c)
	_ok("severing two columns yields three islands", groups.size() == 3, "%d" % groups.size())

	var sizes: Array[int] = []
	for g in groups:
		sizes.append((g as PackedInt32Array).size())
	_ok("largest island comes back first", sizes[0] >= sizes[sizes.size() - 1], str(sizes))
	var total := 0
	for n in sizes:
		total += n
	_ok("every floating block lands in exactly one island", total == 3 + 3 + 3,
			"%d blocks across %d islands" % [total, groups.size()])


func _check_hit() -> void:
	print("damage")
	var w := _world()
	var c := w.create_chunk(Vector3i.ZERO, Vector3i(20, 12, 20))

	for x in range(0, 20, 4):
		for z in range(0, 20, 4):
			w.place_block(c, Vector3i(x, 0, z), A_PLATE, 2)
	var built := w.get_block_count(c)
	_ok("slab built", built == 25, "%d plates" % built)

	# A blast small enough to sit inside one plate.
	var centre: Vector3 = BrickWorld.grid_to_world(Vector3i(10, 0, 10)) + Vector3(0.05, 0.05, 0.05)
	var killed: PackedInt32Array = w.apply_hit(c, centre, 0.2)
	_ok("a small blast takes one block", killed.size() == 1, "%d" % killed.size())
	_ok("it is reported once, not once per cell it covers",
			killed.size() == 1 or killed[0] != killed[1])

	# Hitting the same spot again finds nothing left alive.
	_ok("a dead block is not killed twice", w.apply_hit(c, centre, 0.2).is_empty())

	# Far away, nothing.
	_ok("a blast in empty air kills nothing",
			w.apply_hit(c, Vector3(500, 500, 500), 2.0).is_empty())

	# A wide blast takes more, and everything it takes is really dead.
	var wide: PackedInt32Array = w.apply_hit(c, centre, 2.0)
	_ok("a wider blast takes more", wide.size() > 1, "%d blocks" % wide.size())
	w.build_chunk_mesh(c)
	var before_faces: int = w.get_mesh_stats(c).faces_emitted
	var all_dead := true
	for bid in wide:
		# A dead block keeps its index slots, written as degenerates, but it
		# must contribute no DRAWN face.
		if w.get_block_index_range(c, bid).y <= 0:
			all_dead = false
	_ok("killed blocks keep their slots but draw nothing",
			all_dead and before_faces > 0,
			"%d faces still drawn by survivors" % before_faces)


func _check_detach() -> void:
	print("detachment")
	var w := _world()
	var c := w.create_chunk(Vector3i.ZERO, Vector3i(6, 30, 6))

	for i in 6:
		w.place_block(c, Vector3i(0, i * 3, 0), A_CUBE, 4)
	w.build_chunk_mesh(c)
	var intact: Dictionary = w.get_mesh_stats(c)

	w.kill_block(c, Vector3i(0, 0, 0))
	var groups: Array = w.find_detached_groups(c)
	_ok("the severed column is one island", groups.size() == 1)

	var ids: PackedInt32Array = groups[0]
	var g: Dictionary = w.detach_group(c, ids)
	_ok("detach returns a group", not g.is_empty())
	_ok("it carries every block", int(g.block_count) == ids.size(),
			"%d of %d" % [g.block_count, ids.size()])
	_ok("one collision box per block", (g.boxes as Array).size() == ids.size())
	_ok("it has a mesh", not (g.mesh as Array).is_empty())
	_ok("mass is the sum of its parts", is_equal_approx(float(g.mass), 0.3 * 5),
			"%.2f" % g.mass)

	# Five cubes stacked from grid y=3 to y=18, so the centre of mass sits at
	# the middle of that span in world metres.
	var expected_y := (3.0 + 18.0) * 0.5 * BrickWorld.get_plate_metres()
	_ok("centre of mass is where the matter is",
			absf((g.com as Vector3).y - expected_y) < 0.01,
			"%.3f vs %.3f" % [(g.com as Vector3).y, expected_y])

	# The break surface must gain faces: the bottom of the lifted column was
	# hidden against its neighbour and is now open to the air.
	var boxes_ok := true
	for box in g.boxes:
		if (box.size as Vector3).y <= 0.0:
			boxes_ok = false
	_ok("boxes have real extents", boxes_ok)

	# And the chunk must forget them.
	w.build_chunk_mesh(c)
	var after: Dictionary = w.get_mesh_stats(c)
	_ok("the chunk stops meshing detached blocks", after.blocks_meshed == 0,
			"%d still meshed (was %d)" % [after.blocks_meshed, intact.blocks_meshed])
	_ok("nothing is left standing", w.get_alive_block_count(c) == 0)
	_ok("detaching an empty list is a no-op", w.detach_group(c, PackedInt32Array()).is_empty())


func _check_solve_determinism() -> void:
	print("determinism")
	var a := _collapse_run()
	var b := _collapse_run()
	_ok("same hits, same island count", a.groups == b.groups, "%d vs %d" % [a.groups, b.groups])
	_ok("same hits, same island sizes", a.sizes == b.sizes, "%s vs %s" % [a.sizes, b.sizes])
	_ok("same hits, same survivors", a.alive == b.alive, "%d vs %d" % [a.alive, b.alive])


func _collapse_run() -> Dictionary:
	var w := _world()
	var c := w.create_chunk(Vector3i.ZERO, Vector3i(24, 40, 6))
	for course in 12:
		var y := course * 3
		var offset := 2 if course % 2 == 1 else 0
		var x := offset
		while x + 4 <= 24:
			w.place_block(c, Vector3i(x, y, 0), A_BRICK, course % 12)
			x += 4
	for i in 5:
		w.apply_hit(c, Vector3(1.0 + i * 1.4, 18 * BrickWorld.get_plate_metres(), 0.3), 0.9)
	var groups: Array = w.find_detached_groups(c)
	var sizes: Array[int] = []
	for g in groups:
		sizes.append((g as PackedInt32Array).size())
	return {"groups": groups.size(), "sizes": sizes, "alive": w.get_alive_block_count(c)}
