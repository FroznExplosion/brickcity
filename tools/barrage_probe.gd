extends "res://tools/collapse_probe.gd"

## Wreckage under fire (Docs/CollapseNext.md 1.10): four towers brought down in
## a city of their own, each with four blasts a tick into and round where it
## falls, in three bursts of BURST_TICKS with QUIET_TICKS after each --
## and what the pieces did about it.
##
##     godot --headless --path . --script tools/barrage_probe.gd
##     ... -- --stud=1      the same at another stud strength (BrickStrength.
##                          times), to see what that number moves: read the
##                          "studs at" line
##     ... -- --push=N      a blast's push at N times (IslandManager.push_times)
##     ... -- --bounce=F    a crumb's bounce (IslandManager.crumb_bounce)
##
## A loose piece is a rigid chunk: it parts where a hit disconnects it and
## where a landing snaps it, and is never stress-solved. And one at rest that
## is shot stays at rest unless the shot cut it in two or took what it stood on.
##
## And what the blasts kill is thrown out, all but the middle of each
## (IslandManager.BLAST_CORE; the cases are tools/blast_ring_probe.gd): here it
## is counted over a collapse, with what throwing it costs.
##
## These are counts over a collapse, not one case: no single piece could be
## built that the old stress solve failed (float_probe has the cases, and they
## pass either way), yet over a barrage it made a body of a hit on a piece that
## was down 14-18 % of the time, where cutting alone makes one 2-3 % (two runs
## of this each way, 2026-10-13). The lines are drawn between the two.


## Ticks of firing, then of quiet, then firing again. The quiet is long enough
## for what was shoved to settle (IslandManager.SETTLE_SLOW_NEAR_MS and _MIN_MS).
const BURST_TICKS := 40
const QUIET_TICKS := 80


func _only(_name: String) -> bool:
	return false


func _run() -> void:
	print("barrage probe: wreckage under fire")
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--stud="):
			BrickStrength.times = float(a.split("=", true, 1)[1])
		if a.begins_with("--push="):
			IslandManager.push_times = float(a.split("=", true, 1)[1])
		if a.begins_with("--bounce="):
			IslandManager.crumb_bounce = float(a.split("=", true, 1)[1])
	city = load("res://scenes/city.tscn").instantiate()
	root.add_child(city)
	await _ticks(30)
	var rng := RandomNumberGenerator.new()
	rng.seed = 12345
	var towers := 0
	for round_i in 4:
		var id := _tower(5)
		if id < 0:
			break
		towers += 1
		var box := _box(id)
		city.camera.global_position = box.get_center() + Vector3(-28.0, 10.0, -28.0)
		city.camera.look_at(box.get_center())
		city._promote(id)
		await _ticks(20)
		_undercut(id)
		# And keep firing into what comes down: low, in and round the footprint,
		# in bursts. Without a pause nothing under fire gets to rest at all --
		# a blast pushes what it reaches (IslandManager.push_near) -- and what
		# happens to wreckage at rest when it is shot is half of what this asks.
		for t in 3 * (BURST_TICKS + QUIET_TICKS):
			if t % (BURST_TICKS + QUIET_TICKS) < BURST_TICKS:
				for k in 4:
					city._blast(Vector3(rng.randf_range(box.position.x - 6.0, box.end.x + 6.0),
							rng.randf_range(0.3, 7.0),
							rng.randf_range(box.position.z - 6.0, box.end.z + 6.0)), 1.3)
			await physics_frame
		await _ticks(90)
	var isl: IslandManager = city.islands
	print("  --   %s" % isl.hit_census_line())
	print("  --   %s" % city.stud_census_line())
	print("  --   %s" % isl.blast_census_line())
	print("  --   %s" % isl.crumb_cost_line())
	print("  --   %s" % isl.snap_census_line())
	print("  --   %s" % isl.push_census_line())
	print("  --   %s" % isl.shed_census_line())
	print("  --   %s" % isl.heap.census_line())
	var down: Array = isl.hit_census[1]
	var rest: Array = isl.hit_census[2]
	_ok("four towers came down under fire, and their wreckage was hit", towers == 4 and int(down[0]) > 100,
			"%d tower(s); %d hit(s) on pieces that were down" % [towers, int(down[0])])
	var share := float(down[1]) / maxf(float(down[0]), 1.0)
	_ok("a hit on a piece that is down makes a new body less than one time in twelve",
			share < 0.08, "%d of %d, %.1f %%" % [int(down[1]), int(down[0]), share * 100.0])
	_ok("some hits found wreckage at rest, and none woke it but by cutting it in two",
			int(rest[0]) > 0 and isl.rest_hits_woke == 0
			and isl.rest_hits_kept + isl.rest_hits_cut == int(rest[0]),
			"%d at rest: %d left at rest, %d cut in two, %d woken with nothing cut" % [
				int(rest[0]), isl.rest_hits_kept, isl.rest_hits_cut, isl.rest_hits_woke])
	# What the blasts killed: the middle of each gone, the ring round it thrown
	# out as crumbs where this machine could see it (IslandManager.BLAST_CORE).
	var bc: Array = isl.blast_census
	var undrawn := int(bc[3]) + int(bc[4]) + int(bc[5]) + int(bc[6])
	_ok("the bricks the blasts killed are all accounted for, and most were thrown out, not gone in a core",
			int(bc[0]) > 500 and int(bc[1]) + int(bc[2]) + undrawn == int(bc[0])
			and int(bc[2]) * 2 > int(bc[0]),
			"%d killed: %d in a core, %d thrown, %d not drawn" % [bc[0], bc[1], bc[2], undrawn])
	# About 0.02 ms a brick and 1.5 ms the worst blast (48 bricks, or the first
	# of a size, which makes its mesh), 2026-10-13; the lines are well clear of
	# both, for a machine with other work on.
	_ok("and throwing them is a small part of a blast",
			isl.blast_throw_ms[1] < 5.0 and isl.blast_throw_ms[0] < float(bc[2]) * 0.08,
			"%.1f ms for %d bricks, %.2f ms the worst blast" % [
				isl.blast_throw_ms[0], int(bc[2]), isl.blast_throw_ms[1]])
	# And when the firing stops, nothing is left moving or hanging: everything
	# settles (the watchdog and support_gone are what say so, not this probe).
	var moving := 0
	for t in 30 * 20:
		await physics_frame
		moving = 0
		for p in isl.islands:
			if p.is_valid() and not p.settled and not p.disposable:
				moving += 1
		if moving == 0:
			break
	_ok("once the firing stops, every piece comes to rest", moving == 0, "%d still moving" % moving)
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
