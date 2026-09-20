extends SceneTree

## M2 acceptance probe. Headless, no rendering, no physics.
##
##     godot --headless --path . --script tools/m2_probe.gd
##
## Checks the stress model: load reaches the ground by whatever path is actually
## holding a block up, joints fail when asked to carry more than their stud
## contact allows, failure removes material, and a cascade terminates.

var failures := 0

var A_BRICK := -1   # 4 x 3 x 2
var A_CUBE := -1    # 1 x 3 x 1
var A_PLATE := -1   # 4 x 1 x 4


func _initialize() -> void:
	_check_load_flow()
	_check_lateral_path()
	_check_capacity()
	_check_cascade()
	_check_determinism()

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
	A_CUBE = w.bake_archetype("brick_1x1", Vector3i(1, 3, 1), 1.0)
	A_PLATE = w.bake_archetype("plate_4x4", Vector3i(4, 1, 4), 1.6)
	return w


# ---------------------------------------------------------------------------

func _check_load_flow() -> void:
	print("load flow")
	var w := _world()
	var c := w.create_chunk(Vector3i.ZERO, Vector3i(6, 40, 6))
	w.set_tension_per_stud(c, 1000.0)  # nothing should break here

	var ids: Array[int] = []
	for i in 10:
		ids.append(w.place_block(c, Vector3i(0, i * 3, 0), A_CUBE, i % 12))

	var s: Dictionary = w.solve_stress(c)
	_ok("nothing fails under a generous capacity", int(s.failures) == 0)
	_ok("every block is reached", int(s.blocks_loaded) == 10, "%d" % s.blocks_loaded)

	# Each cube weighs 1. The top carries only itself, the bottom carries all ten.
	_ok("the top block carries only its own weight",
			is_equal_approx(w.get_block_load(c, ids[9]), 1.0), "%.2f" % w.get_block_load(c, ids[9]))
	_ok("the bottom block carries the whole column",
			is_equal_approx(w.get_block_load(c, ids[0]), 10.0), "%.2f" % w.get_block_load(c, ids[0]))
	_ok("load grows monotonically downward",
			w.get_block_load(c, ids[3]) > w.get_block_load(c, ids[7]))
	_ok("peak load is the base", is_equal_approx(float(s.peak_load), 10.0), "%.2f" % s.peak_load)


func _check_lateral_path() -> void:
	print("lateral load path")
	# Two columns bridged at the top. Knock the base out of one: the bridge now
	# carries the orphaned column's weight sideways to the other column, which
	# is the case a strictly-downward solve gets wrong -- it would report the
	# hanging column as weightless and the tower would levitate.
	var w := _world()
	var c := w.create_chunk(Vector3i.ZERO, Vector3i(12, 40, 6))
	w.set_tension_per_stud(c, 1000.0)

	# Columns three studs apart so a single 4-stud brick laid at x = 0 spans
	# cells 0..3 and therefore overlaps BOTH of them. At four studs apart the
	# brick stops one cell short of the second column and bridges nothing.
	var left: Array[int] = []
	var right: Array[int] = []
	for i in 6:
		left.append(w.place_block(c, Vector3i(0, i * 3, 0), A_CUBE, 4))
		right.append(w.place_block(c, Vector3i(3, i * 3, 0), A_CUBE, 5))
	var bridge := w.place_block(c, Vector3i(0, 18, 0), A_BRICK, 6)
	_ok("bridge placed", bridge >= 0)
	_ok("the bridge reaches both columns",
			w.get_block_neighbours(c, bridge).size() == 2,
			"%d neighbour(s)" % w.get_block_neighbours(c, bridge).size())

	w.solve_stress(c)
	var right_base_before := w.get_block_load(c, right[0])

	# Remove the left column's foot. Everything above it now hangs off the
	# bridge, and its weight has to arrive at the right column.
	w.kill_block(c, Vector3i(0, 0, 0))
	w.solve_stress(c)
	var right_base_after := w.get_block_load(c, right[0])

	_ok("the standing column takes up the orphaned load",
			right_base_after > right_base_before + 3.0,
			"%.2f -> %.2f" % [right_base_before, right_base_after])
	_ok("the hanging column is still carried, not weightless",
			w.get_block_load(c, left[5]) > 0.5, "%.2f" % w.get_block_load(c, left[5]))
	_ok("nothing floats free", w.find_detached_groups(c).is_empty())


func _check_capacity() -> void:
	print("compression is free")
	# A brick joint carries ~4200 N in compression and ~4 N in tension. So a
	# stack never crushes, however tall, whatever the tension constant is set to.
	# Docs/BrickFailure.md.
	var w := _world()
	var c := w.create_chunk(Vector3i.ZERO, Vector3i(6, 200, 6))
	for i in 60:
		w.place_block(c, Vector3i(0, i * 3, 0), A_CUBE, i % 12)

	w.set_tension_per_stud(c, 1.0)  # absurdly weak, and still irrelevant
	var stacked: Dictionary = w.solve_stress(c)
	_ok("a 60-brick column never crushes", int(stacked.failures) == 0,
			"peak load %.0f, max tension ratio %.3f" % [stacked.peak_load, stacked.max_ratio])
	_ok("it carries its whole weight at the base",
			is_equal_approx(float(stacked.peak_load), 60.0), "%.1f" % stacked.peak_load)
	_ok("nothing is standing on nothing", w.find_detached_groups(c).is_empty())

	print("tension governs")
	# A column HANGING from a bridge is the case that can fail: its only path to
	# the ground runs upward, so the joint is in tension.
	var h := _world()
	var hc := h.create_chunk(Vector3i.ZERO, Vector3i(12, 40, 6))
	for i in 6:
		h.place_block(hc, Vector3i(0, i * 3, 0), A_CUBE, 4)          # grounded column
	var bridge := h.place_block(hc, Vector3i(0, 18, 0), A_BRICK, 6)  # spans x 0..4
	var hanging: Array[int] = []
	for i in 5:
		hanging.append(h.place_block(hc, Vector3i(3, 15 - i * 3, 0), A_CUBE, 7))
	_ok("the hanging chain placed", bridge >= 0 and not hanging.has(-1))
	_ok("it reaches the ground only through the bridge",
			h.find_detached_groups(hc).is_empty())

	h.set_tension_per_stud(hc, 100.0)
	var strong: Dictionary = h.solve_stress(hc)
	_ok("a strong connection holds the chain", int(strong.failures) == 0,
			"max ratio %.3f" % strong.max_ratio)

	var w2 := _world()
	var c2 := w2.create_chunk(Vector3i.ZERO, Vector3i(12, 40, 6))
	for i in 6:
		w2.place_block(c2, Vector3i(0, i * 3, 0), A_CUBE, 4)
	w2.place_block(c2, Vector3i(0, 18, 0), A_BRICK, 6)
	for i in 5:
		w2.place_block(c2, Vector3i(3, 15 - i * 3, 0), A_CUBE, 7)
	w2.set_tension_per_stud(c2, 2.0)  # one stud holding five bricks: too much
	var weak: Dictionary = w2.solve_stress(c2)
	_ok("a weak connection lets go", int(weak.failures) > 0,
			"%d joint(s) released" % weak.failures)

	var released: PackedInt32Array = weak.separated
	_ok("released joints are reported", released.size() == int(weak.failures))

	var all_alive := true
	var all_broken := true
	for bid in released:
		if not w2.is_support_broken(c2, bid):
			all_broken = false
	for bid in released:
		if w2.get_block_load(c2, bid) < 0.0:
			all_alive = false
	_ok("released blocks are marked", all_broken)
	# The whole point: ABS does not pulverise. A released brick still exists.
	_ok("NOTHING is destroyed by a released joint",
			w2.get_alive_block_count(c2) == w2.get_block_count(c2) and all_alive,
			"%d of %d still standing" % [w2.get_alive_block_count(c2), w2.get_block_count(c2)])
	_ok("and what let go is now loose", not w2.find_detached_groups(c2).is_empty())


func _check_cascade() -> void:
	print("cascade")
	# A single solve already marks EVERY joint that is over capacity right now,
	# so a plain overloaded column fails in one pass. A cascade needs more than
	# one round only when a failure RE-ROUTES load onto something that was fine
	# a moment ago -- which is the interesting case and the one worth pinning.
	#
	# Three columns in a chain: kill the first one's foot and its weight has to
	# travel through the second, which fails, pushing everything onto the third.
	var w := _world()
	var c := w.create_chunk(Vector3i.ZERO, Vector3i(12, 40, 6))

	for i in 6:
		w.place_block(c, Vector3i(0, i * 3, 0), A_CUBE, 4)
		w.place_block(c, Vector3i(3, i * 3, 0), A_CUBE, 5)
	for i in 7:
		w.place_block(c, Vector3i(6, i * 3, 0), A_CUBE, 6)
	var b1 := w.place_block(c, Vector3i(0, 18, 0), A_BRICK, 7)   # columns 1-2
	var b2 := w.place_block(c, Vector3i(3, 21, 0), A_BRICK, 8)   # bridge 1 - column 3
	_ok("chain assembled", b1 >= 0 and b2 >= 0)

	w.set_tension_per_stud(c, 2.0)
	_ok("the chain stands as built", int(w.solve_stress(c).failures) == 0,
			"max ratio %.2f" % w.get_max_stress_ratio(c))

	w.kill_block(c, Vector3i(0, 0, 0))

	var steps := 0
	var total_released := 0
	var total_detached := 0
	while steps < 100:
		var s: Dictionary = w.solve_stress(c)
		var groups: Array = w.find_detached_groups(c)
		var released := int(s.failures)
		total_released += released
		if released == 0 and groups.is_empty():
			break
		for g in groups:
			total_detached += (g as PackedInt32Array).size()
			w.detach_group(c, g)
		steps += 1

	_ok("the cascade terminates", steps < 100, "%d step(s)" % steps)
	# NOT asserting more than one round any more. That was a property of the
	# crushing model: removing material re-concentrated load, so each round found
	# new victims. Releasing a joint in TENSION does the opposite -- everything
	# above it stops being carried at all -- so a simple structure resolves in one
	# pass. Multi-round cascades still happen, when a detachment removes the path
	# something else was grounded through; they are just not guaranteed.
	_ok("and settles somewhere stable", w.get_max_stress_ratio(c) <= 1.0,
			"%.2f" % w.get_max_stress_ratio(c))
	_ok("it releases joints", total_released > 0, "%d joint(s)" % total_released)
	_ok("it detaches something", total_detached > 0, "%d block(s)" % total_detached)
	_ok("what is left is within capacity", w.get_max_stress_ratio(c) <= 1.0,
			"%.2f" % w.get_max_stress_ratio(c))


func _check_determinism() -> void:
	print("determinism")
	var a := _collapse_run()
	var b := _collapse_run()
	_ok("same input, same steps", a.steps == b.steps, "%d vs %d" % [a.steps, b.steps])
	_ok("same input, same survivors", a.alive == b.alive, "%d vs %d" % [a.alive, b.alive])
	_ok("same input, same release count", a.released == b.released, "%d vs %d" % [a.released, b.released])
	_ok("same input, same max ratio", is_equal_approx(a.ratio, b.ratio),
			"%.4f vs %.4f" % [a.ratio, b.ratio])


func _collapse_run() -> Dictionary:
	var w := _world()
	var c := w.create_chunk(Vector3i.ZERO, Vector3i(24, 60, 6))
	w.set_tension_per_stud(c, 1.0)  # weak, so releases actually happen here
	for course in 16:
		var y := course * 3
		var x := 2 if course % 2 == 1 else 0
		while x + 4 <= 24:
			w.place_block(c, Vector3i(x, y, 0), A_BRICK, course % 12)
			x += 4
	for i in 4:
		w.apply_hit(c, Vector3(2.0 + i * 1.3, 24 * BrickWorld.get_plate_metres(), 0.3), 1.0)

	var steps := 0
	var released_total := 0
	while steps < 100:
		var s: Dictionary = w.solve_stress(c)
		var groups: Array = w.find_detached_groups(c)
		released_total += int(s.failures)
		if int(s.failures) == 0 and groups.is_empty():
			break
		for g in groups:
			w.detach_group(c, g)
		steps += 1
	return {
		"steps": steps,
		"alive": w.get_alive_block_count(c),
		"released": released_total,
		"ratio": w.get_max_stress_ratio(c),
	}
