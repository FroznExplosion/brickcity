extends SceneTree

## Probe for the walking map's hierarchy (AINav.set_hierarchy, HPA*; Docs/AI.md
## 4.3.1) and for breaching (AINav.set_breach).
##
##     godot --headless --path . --script tools/nav_hier_probe.gd
##
## A. Same ways: across a field of walls and rooms, the hierarchy finds a path
##    wherever the plain search does, none where it does not, and no more than
##    a fifth longer.
## B. Floors: up a staircase onto a platform, through the hierarchy.
## C. Changes: a door bricked up, the long way round the wall's end is found
##    (where the plain search, given the same budget, gives up); a hole blown in
##    the wall, the way through it at once.
## D. Breaching: a breacher's path goes through a wall where a body's goes
##    round to the door, and says where it goes in; a stone's throw through a
##    thick wall is still the door for it.
## E. Every size: a tank's map with its own hierarchy finds the long way.
## F. Cost: the same long queries, plain against hierarchical, cold and warm
##    (with other runs going, numbers are rough).

const Arena := preload("res://tools/ai_arena.gd")
const STUD := 0.35

var _pass := 0
var _fail := 0
var a: Arena


func _init() -> void:
	print("nav hierarchy probe")
	a = Arena.new(self, 61)
	_build()
	_run()
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _nav(hier: int, breach := 0.0) -> AINav:
	var n := AINav.new()
	n.set_ai_world(a.s.ai_world)
	if breach > 0.0:
		n.set_breach(breach)
	n.set_hierarchy(hier)
	return n


func _w(cx: float, cz: float, plates := 0) -> Vector3:
	return Vector3(cx * STUD, plates * 0.14, cz * STUD)


func _build() -> void:
	# A long wall at z = 100 studs, 4 courses, one door at x 150..153.
	a.bricks(Vector3i(-200, 0, 100), Vector3i(350, 4, 1))
	a.bricks(Vector3i(153, 0, 100), Vector3i(47, 4, 1))
	# A field of rooms south of it: 6 x 4 rooms 20 studs square, doors in their
	# south walls at alternating ends.
	for i in 6:
		for j in 4:
			var x0 := -150 + i * 40
			var z0 := 130 + j * 40
			a.room(x0, z0, 20, 20, 4, x0 + (3 if (i + j) % 2 == 0 else 14), 3, 1 + i * 4 + j)
	# A platform two metres and a half up (a slab, 5 courses up), and stairs
	# to it a course a step.
	a.bricks(Vector3i(100, 15, 200), Vector3i(40, 1, 40))
	for k in range(1, 6):
		a.bricks(Vector3i(140 + 2 * (k - 1), 0, 210), Vector3i(2, 6 - k, 6))
	# A thick wall: 8 studs of bricks, 4 courses, z 300..308, x -60..60.
	a.bricks(Vector3i(-60, 0, 300), Vector3i(120, 4, 8))


static func _len(p: PackedVector3Array) -> float:
	var n := 0.0
	for i in range(1, p.size()):
		n += p[i - 1].distance_to(p[i])
	return n


func _run() -> void:
	var plain := _nav(0)
	var hier := _nav(24)

	print("A. same ways")
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var pairs := []
	for i in 40:
		pairs.append([_w(rng.randf_range(-180, 180), rng.randf_range(20, 290)),
				_w(rng.randf_range(-180, 180), rng.randf_range(20, 290))])
	var same := 0
	var worse := 0.0
	var both := 0
	var miss := []
	for pr in pairs:
		var p0 := plain.find_path(plain.snap(pr[0]), plain.snap(pr[1]), 300000)
		var p1 := hier.find_path(hier.snap(pr[0]), hier.snap(pr[1]), 300000)
		if p0.is_empty() == p1.is_empty():
			same += 1
		else:
			miss.append("%v -> %v: plain %d, hier %d" % [pr[0], pr[1], p0.size(), p1.size()])
		if not p0.is_empty() and not p1.is_empty():
			both += 1
			worse = maxf(worse, _len(p1) / maxf(_len(p0), 0.01))
	_ok("the hierarchy finds a way wherever the plain search does, and none where it does not",
			same == pairs.size(), "%d of %d agree %s" % [same, pairs.size(), "; ".join(miss)])
	_ok("no more than a fifth longer", worse <= 1.2, "worst %.2f x over %d paths" % [worse, both])
	var st := hier.get_stats()
	_ok("and it did use the hierarchy", int(st.hier_paths) > 10, "%d hierarchical paths, %d sides" % [st.hier_paths, st.hier_sides])

	print("B. floors")
	var up := hier.find_path(hier.snap(_w(160, 230)), hier.snap(_w(110, 210, 18)), 200000)
	var top := up[up.size() - 1] if not up.is_empty() else Vector3.ZERO
	var from_far := hier.find_path(hier.snap(_w(-170, 40)), hier.snap(_w(110, 210, 18)), 300000)
	_ok("up the stairs onto the platform", not up.is_empty() and top.y > 2.4,
			"%d points, ends %.2f m up" % [up.size(), top.y])
	_ok("and from across the map, through the hierarchy", not from_far.is_empty()
			and from_far[from_far.size() - 1].y > 2.4, "%d points, %.0f m" % [from_far.size(), _len(from_far)])

	print("C. changes")
	var n_side := _w(0, 95)
	var s_side := _w(0, 110)
	var round := hier.find_path(hier.snap(n_side), hier.snap(s_side), 300000)
	_ok("round the wall by its door", not round.is_empty() and _len(round) > 90.0, "%.0f m" % _len(round))
	# The door bricked up: no way at all now.
	a.bricks(Vector3i(150, 0, 100), Vector3i(3, 4, 1))
	for n in [plain, hier]:
		n.invalidate_box(AABB(_w(150, 100) - Vector3(1, 0, 1), Vector3(3.0, 3.0, 3.0)))
	var t0 := Time.get_ticks_usec()
	var none := hier.find_path(hier.snap(n_side), hier.snap(s_side), 60000)
	var t_fail := (Time.get_ticks_usec() - t0) / 1000.0
	t0 = Time.get_ticks_usec()
	var none_plain := plain.find_path(plain.snap(n_side), plain.snap(s_side), 60000)
	var t_plain := (Time.get_ticks_usec() - t0) / 1000.0
	t0 = Time.get_ticks_usec()
	hier.find_path(hier.snap(n_side), hier.snap(s_side), 60000)
	var t_again := (Time.get_ticks_usec() - t0) / 1000.0
	_ok("the door bricked up: round the wall's far end, where the plain search gives up in the same budget",
			not none.is_empty() and _len(none) > 140.0 and none_plain.is_empty(),
			"%.0f m in %.1f ms (%.1f ms asked again); plain gave up in %.1f ms" % [_len(none), t_fail, t_again, t_plain])
	# A hole blown in the wall in front of them.
	a.breach(_w(1, 100.5, 6), 1.4)
	for n in [plain, hier]:
		n.invalidate_box(AABB(_w(-4, 96), Vector3(3.5, 3.0, 3.5)))
	var through := hier.find_path(hier.snap(n_side), hier.snap(s_side), 300000)
	_ok("a hole blown in it: the way through at once", not through.is_empty() and _len(through) < 15.0,
			"%.1f m" % _len(through))

	print("D. breaching")
	var breacher := _nav(24, 6.0)
	var foot := hier
	var w_from := _w(100, 92)
	var w_to := _w(100, 108)
	var walked := foot.find_path(foot.snap(w_from), foot.snap(w_to), 300000)
	var opened := breacher.find_path(breacher.snap(w_from), breacher.snap(w_to), 300000)
	var where := breacher.get_last_breaches()
	_ok("a body goes round to the hole; a breacher goes through the wall", not walked.is_empty() and not opened.is_empty()
			and _len(opened) < _len(walked) - 10.0, "%.0f m against %.0f m" % [_len(opened), _len(walked)])
	_ok("and says where it goes in", where.size() == 1 and absf(where[0].z - 100.0 * STUD) < 1.0,
			"%d breach(es) %s" % [where.size(), where])
	var thick_from := _w(0, 290)
	var thick_to := _w(0, 318)
	var thick := breacher.find_path(breacher.snap(thick_from), breacher.snap(thick_to), 300000)
	var thick_breaches := breacher.get_last_breaches()
	_ok("eight studs of wall cost more than the walk round: it goes round", not thick.is_empty() and thick_breaches.is_empty(),
			"%.0f m, %d breaches" % [_len(thick), thick_breaches.size()])

	print("E. every size")
	var tank := VehicleNav.make(a.s.ai_world, &"tank")
	tank.set_hierarchy(VehicleNav.span_of(&"tank") * 4)
	var tp := tank.find_path(tank.snap(_w(-170, 20)), tank.snap(_w(170, 120)), 300000)
	_ok("a tank's map with its own hierarchy finds the long way", not tp.is_empty() and int(tank.get_stats().hier_paths) == 1,
			"%d points, %.0f m" % [tp.size(), _len(tp)])

	print("F. cost")
	var longs := []
	rng.seed = 11
	while longs.size() < 30:
		var p := _w(rng.randf_range(-180, 180), rng.randf_range(110, 290))
		var q := _w(rng.randf_range(-180, 180), rng.randf_range(110, 290))
		if p.distance_to(q) > 50.0:
			longs.append([p, q])
	for run in ["cold", "warm"]:
		var times := {}
		for which in ["plain", "hier"]:
			var n: AINav = plain if which == "plain" else hier
			if run == "cold":
				n.clear_cache()
			n.reset_stats()
			var t := Time.get_ticks_usec()
			for pr in longs:
				n.find_path(n.snap(pr[0]), n.snap(pr[1]), 300000)
			times[which] = (Time.get_ticks_usec() - t) / 1000.0
			var s := n.get_stats()
			print("   %s %s: %.1f ms for %d, %d nodes (%d in the hierarchy)" % [run, which, times[which], longs.size(),
					int(s.expansions) + int(s.hier_nodes), s.hier_nodes])
		if run == "warm":
			_ok("warm, the hierarchy is faster on long ways", times.hier < times.plain,
					"%.1f ms against %.1f ms" % [times.hier, times.plain])
