extends "res://tools/collapse_probe.gd"

## Wreckage under fire (Docs/CollapseNext.md 1.10): four towers brought down in
## a city of their own, each with four blasts a tick into and round where it
## falls for eight seconds -- and what the pieces did about it.
##
##     godot --headless --path . --script tools/barrage_probe.gd
##
## A loose piece is a rigid chunk: it parts where a hit disconnects it and
## where a landing snaps it, and is never stress-solved. And one at rest that
## is shot stays at rest unless the shot cut it in two or took what it stood on.
##
## These are counts over a collapse, not one case: no single piece could be
## built that the old stress solve failed (float_probe has the cases, and they
## pass either way), yet over a barrage it made a body of a hit on a piece that
## was down 14-18 % of the time, where cutting alone makes one 2-3 % (two runs
## of this each way, 2026-10-13). The lines are drawn between the two.


func _only(_name: String) -> bool:
	return false


func _run() -> void:
	print("barrage probe: wreckage under fire")
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
		# And keep firing into what comes down: low, in and round the footprint.
		for t in 240:
			for k in 4:
				city._blast(Vector3(rng.randf_range(box.position.x - 6.0, box.end.x + 6.0),
						rng.randf_range(0.3, 7.0),
						rng.randf_range(box.position.z - 6.0, box.end.z + 6.0)), 1.3)
			await physics_frame
		await _ticks(90)
	var isl: IslandManager = city.islands
	print("  --   %s" % isl.hit_census_line())
	var down: Array = isl.hit_census[1]
	var rest: Array = isl.hit_census[2]
	_ok("four towers came down under fire, and their wreckage was hit", towers == 4 and int(down[0]) > 100,
			"%d tower(s); %d hit(s) on pieces that were down" % [towers, int(down[0])])
	var share := float(down[1]) / maxf(float(down[0]), 1.0)
	_ok("a hit on a piece that is down makes a new body less than one time in twelve",
			share < 0.08, "%d of %d, %.1f %%" % [int(down[1]), int(down[0]), share * 100.0])
	_ok("some hits found wreckage at rest, and more of them left it at rest than woke it",
			int(rest[0]) > 0 and isl.rest_hits_kept > isl.rest_hits_woke,
			"%d at rest: %d left at rest, %d woke" % [int(rest[0]), isl.rest_hits_kept, isl.rest_hits_woke])
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
