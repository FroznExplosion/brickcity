extends SceneTree

## Acceptance probe for AIWorld and AIScheduler (Docs/AIPlan.md P2).
##
##     godot --headless --path . --script tools/ai_world_probe.gd
##
## The AI reads the city instead of probing it (Docs/AI.md section 3). So the
## count of bricks between two points has to be RIGHT: through a wall, through a
## tilted slab, through a hole, across two chunks -- checked against a hand
## count, and then against brute-force sampling on random rays. Cover life has to
## be what the gun will actually do. And it has to be cheap: ten thousand cover
## queries, timed. Then the scheduler: it holds its budget under a flood, serves
## the important first, starves nobody, never defers what must run; and the
## arbiter steps the AI down under a destruction load and back up after.

const CS := Vector3(0.35, 0.14, 0.35)

var _pass := 0
var _fail := 0
var w: BrickWorld
var palette: Dictionary
var ai: AIWorld


func _init() -> void:
	print("ai world probe")
	w = BrickWorld.new()
	palette = TowerRecipe.bake_palette(w)
	ai = AIWorld.new()
	ai.set_world(w)
	_check_counts()
	_check_random_rays()
	_check_cover()
	_check_not_bricks()
	_check_speed()
	_check_scheduler()
	_check_arbiter()
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


## A solid block of 1x1 bricks, nx studs by ny courses by nz studs, placed at
## `xform`. One chunk.
func _wall(nx: int, ny: int, nz: int, xform: Transform3D) -> int:
	var origin := Vector3i.ZERO
	var chunk := w.create_chunk(origin, Vector3i(nx, ny * 3, nz))
	for x in nx:
		for y in ny:
			for z in nz:
				w.place_block(chunk, origin + Vector3i(x, y * 3, z), palette["brick_1x1"], 1)
	w.set_chunk_transform(chunk, xform)
	return chunk


# ---------------------------------------------------------------------------

var _wall_a := -1


func _check_counts() -> void:
	print("\nhand counts")
	# A wall 8 studs wide, 3 courses tall, 3 studs thick, at the origin.
	_wall_a = _wall(8, 3, 3, Transform3D())
	ai.sync()
	var mid := Vector3(4.5 * CS.x, 1.5 * 0.42, 0.0)
	var t := ai.trace(mid + Vector3(0, 0, -5), mid + Vector3(0, 0, 5))
	_ok("straight through a wall three bricks thick: 3", int(t.bricks) == 3,
			"%d, %.2f m solid" % [int(t.bricks), float(t.solid_m)])
	_ok("and 1.05 m of it solid", absf(float(t.solid_m) - 1.05) < 0.01)
	_ok("the first brick is where the wall starts", t.hit and absf((t.point as Vector3).z) < 0.01,
			"%v" % [t.point])

	# A slab one brick thick, tilted 30 degrees about X, somewhere else entirely.
	var tilt := Transform3D(Basis(Vector3.RIGHT, deg_to_rad(30.0)), Vector3(20.0, 5.0, 0.0))
	var slab := _wall(10, 1, 10, tilt)
	ai.sync()
	var centre := tilt * Vector3(5.0 * CS.x, 0.21, 5.0 * CS.z)
	var n := tilt.basis.y
	var s := ai.trace(centre - n * 3.0, centre + n * 3.0)
	_ok("through a slab tilted 30 degrees, along its normal: 1", int(s.bricks) == 1,
			"%d, %.3f m solid" % [int(s.bricks), float(s.solid_m)])
	_ok("and one course (0.42 m) of it solid", absf(float(s.solid_m) - 0.42) < 0.02)
	# Along the slab's own plane, it is the whole slab.
	var along := tilt.basis.x
	var s2 := ai.trace(centre - along * 5.0, centre + along * 5.0)
	_ok("along the tilted slab's plane: all ten studs of it", int(s2.bricks) == 10,
			"%d" % int(s2.bricks))

	# A second wall behind the first, a chunk of its own.
	var wall_b := _wall(8, 3, 2, Transform3D(Basis(), Vector3(0.0, 0.0, 3.0)))
	ai.sync()
	var both := ai.bricks_between(mid + Vector3(0, 0, -5), mid + Vector3(0, 0, 8))
	_ok("across two chunks: 3 + 2", both == 5, "%d" % both)

	# A hole shot through the first wall; the line through it is clear of it.
	w.apply_hit(_wall_a, mid + Vector3(0, 0, 0.5), 0.5)
	var through := ai.bricks_between(mid + Vector3(0, 0, -5), mid + Vector3(0, 0, 2.5))
	_ok("through a hole: 0", through == 0, "%d" % through)
	# Two studs over: outside the hole's half-metre, inside the 2.8 m wall.
	var beside := ai.bricks_between(mid + Vector3(0.7, 0, -5), mid + Vector3(0.7, 0, 2.5))
	_ok("and two studs beside it, still 3", beside == 3, "%d" % beside)
	w.release_chunk(slab)
	w.release_chunk(wall_b)
	ai.sync()


## Random rays through a pile of chunks at odd angles, each counted twice: by
## the DDA, and by walking the ray a millimetre at a time and asking the chunk
## what is at each step.
func _check_random_rays() -> void:
	print("\nrandom rays against brute force")
	var chunks: Array[int] = []
	var rng := RandomNumberGenerator.new()
	rng.seed = 91
	for i in 4:
		var b := Basis.from_euler(Vector3(rng.randf() * TAU, rng.randf() * TAU, rng.randf() * TAU))
		chunks.append(_wall(6, 2, 5, Transform3D(b, Vector3(40.0 + i * 1.3, 2.0, i * 0.9))))
	ai.sync()
	var agree := 0
	var n := 200
	for k in n:
		var a := Vector3(40.0 + rng.randf_range(-4.0, 8.0), rng.randf_range(-2.0, 6.0), rng.randf_range(-5.0, 6.0))
		var b := Vector3(40.0 + rng.randf_range(-4.0, 8.0), rng.randf_range(-2.0, 6.0), rng.randf_range(-5.0, 6.0))
		if ai.bricks_between(a, b) == _brute(chunks, a, b):
			agree += 1
	# Brute force at a millimetre can clip a corner the exact walk counts; allow
	# a ray or two in two hundred for that, and nothing more.
	_ok("the DDA agrees with brute force", agree >= n - 2, "%d of %d" % [agree, n])
	for c in chunks:
		w.release_chunk(c)
	ai.sync()


func _brute(chunks: Array[int], a: Vector3, b: Vector3) -> int:
	var seen := {}
	var steps := int(a.distance_to(b) / 0.001)
	for c in chunks:
		var inv := w.get_chunk_transform(c).affine_inverse()
		var origin := w.get_chunk_origin(c)
		for i in steps + 1:
			var p: Vector3 = inv * a.lerp(b, float(i) / steps)
			var cell := Vector3i(floori(p.x / CS.x), floori(p.y / CS.y), floori(p.z / CS.z))
			var id := w.block_at(c, origin + cell)
			if id >= 0 and w.is_solid(c, origin + cell):
				seen[c * 100000 + id] = true
	return seen.size()


func _check_cover() -> void:
	print("\ncover is how long it lasts")
	var mid := Vector3(1.5 * CS.x, 1.5 * 0.42, 0.0)
	var from := mid + Vector3(0, 0, -20)
	var to := mid + Vector3(0, 0, 5)
	var pistol := StructuralDamage.chip_hp(WeaponClass.builtin(&"pistol"))
	var rate := 6.0
	# Three bricks, each three pistol rounds: nine rounds at six a second.
	var secs := ai.cover_seconds(from, to, pistol, rate)
	_ok("three bricks against a pistol: 9 rounds, 1.5 s", absf(secs - 1.5) < 0.01, "%.3f s" % secs)
	# Wear the first brick once: one round fewer.
	w.chip_hit(_wall_a, mid + Vector3(0, 0, 0.1), 0.0, pistol)
	secs = ai.cover_seconds(from, to, pistol, rate)
	_ok("one of them already worn: 8 rounds", absf(secs - 8.0 / 6.0) < 0.01, "%.3f s" % secs)
	var sniper := StructuralDamage.chip_hp(WeaponClass.builtin(&"sniper"))
	var s2 := ai.cover_seconds(from, to, sniper, 1.35)
	_ok("against a sniper, a round a brick", absf(s2 - 3.0 / 1.35) < 0.01, "%.3f s" % s2)
	var batch := ai.cover_seconds_batch(from, PackedVector3Array([to, to + Vector3(20, 0, 0)]),
			pistol, rate)
	_ok("a batch answers each position", batch.size() == 2 and absf(batch[0] - 8.0 / 6.0) < 0.01
			and batch[1] == 0.0, "%s" % batch)


func _check_not_bricks() -> void:
	print("\nwhat is not bricks: proxies, smoke, danger")
	var a := Vector3(100, 1, -5)
	var b := Vector3(100, 1, 5)
	_ok("open ground is clear", ai.line_clear(a, b))
	# A pristine building's wall slab, one brick thick, as a proxy.
	ai.set_proxy(1, Transform3D(Basis(), Vector3(100, 1, 0)), Vector3(4.0, 2.5, 0.35), 1.0 / 0.35)
	_ok("a proxy wall one brick thick counts one brick", ai.bricks_between(a, b) == 1,
			"%d" % ai.bricks_between(a, b))
	ai.remove_proxy(1)
	_ok("and is gone when removed", ai.line_clear(a, b))
	ai.set_smoke(7, Vector3(100, 1.5, 1.0), 2.0)
	_ok("smoke blocks the line of sight", not ai.line_clear(a, b) and ai.smoke_blocks(a, b))
	_ok("but is not a brick", ai.bricks_between(a, b) == 0)
	ai.clear_smoke()
	ai.set_danger(3, AABB(Vector3(95, 0, -2), Vector3(4, 6, 4)))
	_ok("a danger box knows what is in it", ai.in_danger(Vector3(97, 1, 0))
			and not ai.in_danger(Vector3(100, 1, 0)))
	_ok("and how far away the rest is", absf(ai.danger_distance(Vector3(100, 1, 0)) - 1.0) < 0.01)
	ai.clear_danger()


func _check_speed() -> void:
	print("\nten thousand cover queries")
	var reg := BuildingRegistry.new(w, palette)
	var ids: Array[int] = []
	for i in 6:
		var id := reg.register(16, 16, 30, Transform3D(Basis(), Vector3(200.0 + (i % 3) * 13.0, 0.0, (i / 3) * 13.0)))
		reg.materialise(id)
		ids.append(id)
	ai.sync()
	ai.reset_stats()
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	var pistol := StructuralDamage.chip_hp(WeaponClass.builtin(&"pistol"))
	var froms := []
	var tos := []
	for i in 10000:
		froms.append(Vector3(rng.randf_range(185.0, 245.0), rng.randf_range(0.5, 12.0), rng.randf_range(-15.0, 35.0)))
		tos.append(Vector3(rng.randf_range(195.0, 235.0), rng.randf_range(0.5, 12.0), rng.randf_range(-5.0, 25.0)))
	var t0 := Time.get_ticks_usec()
	var with_cover := 0
	for i in 10000:
		if ai.cover_seconds(froms[i], tos[i], pistol, 6.0) > 0.0:
			with_cover += 1
	var ms := float(Time.get_ticks_usec() - t0) / 1000.0
	var stats := ai.get_stats()
	print("  %d chunks indexed; %.1f ms for 10,000 (%.2f us each in C++, %.2f with the call); %d found cover; %d cells walked" % [
		ai.get_indexed_chunks(), ms, float(stats.mean_usec), ms, with_cover, int(stats.cells_walked)])
	# AI.md 10.1 gives tactical queries 0.5 ms a frame. Ten thousand of them is
	# a whole squad re-scoring its cover many times over; they have to be
	# microseconds each, or a cover search is a frame.
	_ok("they are cheap: under 20 us each, the call included", ms / 10000.0 * 1000.0 < 20.0,
			"%.2f us" % (ms / 10.0))
	_ok("and most of these crossed a building", with_cover > 2000, "%d" % with_cover)
	for id in ids:
		reg.dematerialise(id)
	ai.sync()


func _check_scheduler() -> void:
	print("\nthe scheduler")
	var sch := AIScheduler.new()
	var order: Array = []
	var busy := func(us: int, tag: Variant) -> void:
		var until := Time.get_ticks_usec() + us
		while Time.get_ticks_usec() < until:
			pass
		order.append(tag)
	# A flood: 2,000 jobs of 50 us each, a hundred milliseconds of work.
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	for i in 2000:
		sch.submit(rng.randi() % AIScheduler.SUBSYSTEM_COUNT, rng.randf() * 10.0,
				busy.bind(50, i))
	var worst_over := 0
	var over_frames := 0
	var frames := 0
	var first_frame: Array = []
	while sch.queued() > 0 and frames < 500:
		order.clear()
		sch.run_for(2500)
		worst_over = maxi(worst_over, sch.get_last_overrun_usec())
		if sch.get_last_overrun_usec() > 300:
			over_frames += 1
		if frames == 0:
			first_frame = order.duplicate()
		frames += 1
	# At most one job over, every frame -- bar one: a headless process on a busy
	# machine is sometimes simply not scheduled for a few milliseconds, and no
	# budget can see that coming.
	_ok("a flood is served inside the budget, one job over at most",
			over_frames <= 1, "%d of %d frames over by more than a job; worst %d us" % [
			over_frames, frames, worst_over])
	_ok("and all of it gets done", sch.queued() == 0 and frames > 30, "%d frames" % frames)

	# Importance first.
	order.clear()
	for i in 20:
		sch.submit(AIScheduler.TREES, float(i), busy.bind(10, i))
	sch.run_for(100000)
	_ok("the most important runs first", order.size() == 20 and order[0] == 19 and order[19] == 0,
			"%s" % [order.slice(0, 5)])

	# Nothing starves: a low-priority job queued behind a stream of important
	# ones gets its turn as it ages.
	order.clear()
	sch.submit(AIScheduler.COMMANDER, 0.0, busy.bind(10, "old"))
	var turned := -1
	for f in 200:
		sch.submit(AIScheduler.TREES, 5.0, busy.bind(400, f))
		sch.submit(AIScheduler.TREES, 5.0, busy.bind(400, f))
		sch.run_for(500)
		if order.has("old"):
			turned = f
			break
	_ok("nothing starves: a low job waited, then ran", turned > 0, "after %d frames" % turned)
	sch.clear()

	# Must-run jobs run even with no budget at all.
	order.clear()
	sch.submit(AIScheduler.PERCEPTION, 0.0, busy.bind(10, "evade"), true)
	sch.submit(AIScheduler.TREES, 9.0, busy.bind(10, "tree"))
	sch.run_for(0)
	_ok("evade runs whatever the budget", order == ["evade"], "%s" % [order])
	var stats: Dictionary = sch.get_stats()
	_ok("stats say what was deferred", int((stats.trees as Dictionary).deferred) == 1,
			"%s" % [stats.trees])


func _check_arbiter() -> void:
	print("\nthe arbiter shares the frame with destruction")
	var sch := AIScheduler.new()
	sch.set_base_budget_ms(2.5)
	sch.set_thresholds(8.0, 4.0)
	sch.set_hysteresis(3, 30)
	var full := sch.get_budget_ms()
	for i in 12:
		sch.report_destruction_ms(14.0)
	_ok("a collapse eating the frame steps the AI down", sch.get_level() >= 3,
			"level %d, budget %.2f ms" % [sch.get_level(), sch.get_budget_ms()])
	_ok("with a smaller budget", sch.get_budget_ms() < full * 0.5)
	_ok("and the directed trees and the rays thinned first",
			sch.rate_scale(AIScheduler.TREES) < 1.0 and sch.rate_scale(AIScheduler.PERCEPTION) < 1.0)
	for i in 20:
		sch.report_destruction_ms(7.0)
	var held := sch.get_level()
	_ok("a middling frame holds the level", held >= 3, "baseline %.1f ms" % sch.get_baseline_ms())
	for i in 200:
		sch.report_destruction_ms(1.0)
	_ok("and a quiet one brings it back up", sch.get_level() == 0
			and is_equal_approx(sch.get_budget_ms(), full))
	# A big city at rest ticks at several milliseconds doing nothing. After a
	# collapse it must still come back up -- its own normal is quiet, not an
	# absolute number.
	for i in 12:
		sch.report_destruction_ms(18.0)
	var down := sch.get_level()
	for i in 600:
		sch.report_destruction_ms(6.0)
	_ok("a sustained load becomes the new normal, and the AI comes back up",
			down >= 3 and sch.get_level() == 0, "down to %d, baseline %.1f ms, level %d" % [
			down, sch.get_baseline_ms(), sch.get_level()])
