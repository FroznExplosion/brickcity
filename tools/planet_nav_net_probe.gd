extends SceneTree

## Many nav regions on a planet (Docs/Planets.md 11.8, N4): PlanetNavNet over
## the default planet, a path of ~400 m across several regions.
##
##   --headless --path . --script res://tools/planet_nav_net_probe.gd
##
## A wall stands across the first border with one gap in it. So: is there a path
## from one end to the other; does it cross the borders it must; do its
## stretches meet where the regions' frames do (within a stud); is every point
## on the planet's ground (within a plate); does it go through the gap and never
## through the wall; is it a sensible length; how long do regions and legs take;
## with the legs worked out, is the path no worse; and do regions behind the
## fight get dropped?

var ok := 0
var fail := 0


func _check(what: String, cond: bool, detail := "") -> void:
	if cond:
		ok += 1
	else:
		fail += 1
	print("  %s %s%s" % ["ok  " if cond else "FAIL", what, (" -- " + detail) if detail else ""])


var _done := false


func _process(_d: float) -> bool:
	if _done:
		return true
	_done = true
	_run()
	print("[nav-net] %d ok, %d FAIL" % [ok, fail])
	quit(1 if fail > 0 else 0)
	return true


func _err(data: PlanetData, p: Vector3) -> float:
	return absf(p.length() - data.radius - data.height(p.normalized()))


func _run() -> void:
	var data := PlanetData.new()
	var dir := Vector3(0.12, 1.0, -0.08).normalized()
	var net := PlanetNavNet.make(data, dir)
	var w := net.cell_m
	var plate := BrickWorld.get_plate_metres()
	# Along the anchor's tangent plane: q -> the ground there (planet-local = world here).
	var at := func(q: Vector2) -> Vector3: return data.surface_point(net._dir_of(q))
	# The wall: across the border x = 0.5 w, from z = -0.5 w to 0.3 w (its gap
	# near the +z corner), 6 m over the ground at its middle and 10 m into it,
	# so nothing crouches under it where the ground falls away.
	var wall_q := Vector2(0.5 * w, -0.1 * w)
	var wall_up := net._dir_of(wall_q)
	var base: Vector3 = at.call(wall_q)
	var wall_xf := Transform3D(Gravity.carry(Basis(net.ax, net.anchor, net.az), wall_up), base + wall_up * -2.0)
	var wall_size := Vector3(1.0, 16.0, 0.8 * w)
	# A building 54 m past cell (0, 0)'s east edge, off the route: a sight line
	# asked in (0, 0) must meet it (PlanetNavNet.LINE_REACH).
	var hut_q := Vector2(1.1 * w, 0.3 * w)
	var hut_up := net._dir_of(hut_q)
	var hut_xf := Transform3D(Gravity.carry(Basis(net.ax, net.anchor, net.az), hut_up),
			(at.call(hut_q) as Vector3) + hut_up * 4.0)
	net.set_sites([[wall_xf, wall_size], [hut_xf, Vector3(8.0, 10.0, 8.0)]])
	var from: Vector3 = at.call(Vector2(-0.3 * w, -0.2 * w))
	var to: Vector3 = at.call(Vector2(4.2 * w, 0.3 * w))
	var t0 := Time.get_ticks_usec()
	net.keep_around([from], 60.0, 99)
	var keep_ms := (Time.get_ticks_usec() - t0) / 1000.0
	var made0 := net.regions_made
	t0 = Time.get_ticks_usec()
	var path := net.find_path(from, to, 200000)
	var path_ms := (Time.get_ticks_usec() - t0) / 1000.0
	var per := 0.0
	for r in net.regions.values():
		per += (r as PlanetNavNet.Region).made_ms
	per /= maxf(1.0, net.regions.size())
	print("[nav-net] cells %.1f m; %d regions round the start in %.0f ms (%.1f ms each); the path: %d points in %.0f ms, %d regions now, %d replan(s)" % [
			w, made0, keep_ms, per, path.size(), path_ms, net.regions.size(), net.last_tries])
	_check("a path ~400 m across the regions", path.size() > 2
			and path[0].distance_to(from) < 1.0 and path[path.size() - 1].distance_to(to) < 1.0,
			"%d points" % path.size())
	if path.size() < 2:
		return
	var crossed := 0
	var last := net.key_at(path[0])
	for p in path:
		var k := net.key_at(p)
		if k != last:
			crossed += 1
			last = k
	_check("it crosses the borders between (>= 4)", crossed >= 4, "%d" % crossed)
	var worst_join := 0.0
	for j in net.last_joins:
		worst_join = maxf(worst_join, j)
	_check("its stretches meet at the borders (<= 0.36 m, a stud column)", not net.last_joins.is_empty()
			and worst_join <= 0.36, "%d join(s), worst %.3f m" % [net.last_joins.size(), worst_join])
	var worst := 0.0
	for p in path:
		worst = maxf(worst, _err(data, p))
	# A plate, and a little for a node's point on a slope: it stands on its
	# column's floor (read at the column's centre) at the corner of the 2 x 2.
	_check("every point on the planet's ground (within 1.5 plates, %.3f m)" % (plate * 1.5), worst <= plate * 1.5,
			"worst %.3f m" % worst)
	var inv := wall_xf.affine_inverse()
	var inside := 0
	for i in range(1, path.size()):
		for s in 4:
			var l := inv * path[i - 1].lerp(path[i], s / 4.0)
			if absf(l.x) < 0.5 and absf(l.z) < wall_size.z * 0.5 and l.y < 8.0:
				inside += 1
	_check("it never goes through the wall", inside == 0, "%d sample(s) in it" % inside)
	var len0 := PlanetNavNet._length(path)
	var straight := from.distance_to(to)
	_check("a sensible length (< 1.6 x the straight line)", len0 < straight * 1.6,
			"%.0f m for %.0f m" % [len0, straight])
	# The legs, worked out in service()'s time.
	# The legs, in service()'s time: a game's budget a call.
	t0 = Time.get_ticks_usec()
	net.worst_service_us = 0
	var calls := 0
	var over := 0
	while net.legs_pending() > 0 and Time.get_ticks_usec() - t0 < 120000000:
		var c0 := Time.get_ticks_usec()
		net.service(2000)
		if Time.get_ticks_usec() - c0 > 3000:
			over += 1
		calls += 1
	var legs_s := (Time.get_ticks_usec() - t0) / 1e6
	print("[nav-net] %d legs worked out in %.1f s, %d service(2 ms) calls, the longest %.1f ms %s" % [
			net.legs_done, legs_s, calls, net.worst_service_us / 1000.0, net.worst_service_parts])
	var worst_stats := {}
	for r in net.regions.values():
		var st: Dictionary = (r as PlanetNavNet.Region).nav.get_stats()
		for key in st:
			if String(key).begins_with("worst_"):
				worst_stats[key] = maxi(int(worst_stats.get(key, 0)), int(st[key]))
	print("[nav-net] the regions' AINav worst parts (us): %s" % worst_stats)
	_check("every leg worked out", net.legs_pending() == 0 and net.legs_done > 0, "%d" % net.legs_done)
	# A call can be stretched by the machine (another process, a page of
	# memory); what matters is that it does not happen call after call.
	_check("inside service()'s budget while it does (< 0.5% of 2 ms calls over 3 ms)",
			over * 200 < calls, "%d of %d; the longest %.1f ms" % [over, calls, net.worst_service_us / 1000.0])
	var path2 := net.find_path(from, to, 200000)
	var len2 := PlanetNavNet._length(path2)
	_check("with the legs known, the path is no worse (<= +5%)", path2.size() > 2 and len2 <= len0 * 1.05,
			"%.0f m, was %.0f m" % [len2, len0])
	# Sight lines across borders: the ground off a region's grid is its
	# neighbour's (AIWorld.set_peers). Against the planet's own ground.
	var r0: PlanetNavNet.Region = net.regions[Vector2i(0, 0)]
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	var agree := 0
	var agree_alone := 0
	var blocked := 0
	var n_lines := 0
	var lines: Array = []
	while lines.size() < 300:
		var qa := Vector2(rng.randf_range(-0.4, 0.4), rng.randf_range(-0.4, 0.4)) * w
		var ang := rng.randf() * TAU
		var qb := qa + Vector2(cos(ang), sin(ang)) * rng.randf_range(0.6, 1.2) * w
		var cb := Vector2i(roundi(qb.x / w), roundi(qb.y / w))
		if cb == Vector2i(0, 0) or not net.regions.has(cb):
			continue
		var pa: Vector3 = at.call(qa)
		var pb: Vector3 = at.call(qb)
		lines.append([pa + pa.normalized() * 1.5, pb + pb.normalized() * 1.5])
	var slack := plate * 1.5
	for ln in lines:
		var a0: Vector3 = ln[0]
		var b0: Vector3 = ln[1]
		var truth := false
		var steps := int(ceil(a0.distance_to(b0) / 0.35))
		for i in steps + 1:
			var p := a0.lerp(b0, float(i) / steps)
			if p.length() - data.radius < data.height(p.normalized()) - slack:
				truth = true
				break
		if truth:
			blocked += 1
		if r0.world.ground_blocks(a0, b0) == truth:
			agree += 1
		n_lines += 1
	r0.world.set_peers([])
	for ln in lines:
		var a1: Vector3 = ln[0]
		var b1: Vector3 = ln[1]
		var truth1 := false
		var steps1 := int(ceil(a1.distance_to(b1) / 0.35))
		for i in steps1 + 1:
			var p := a1.lerp(b1, float(i) / steps1)
			if p.length() - data.radius < data.height(p.normalized()) - slack:
				truth1 = true
				break
		if r0.world.ground_blocks(a1, b1) == truth1:
			agree_alone += 1
	net._relink(Vector2i(0, 0))
	print("[nav-net] %d sight lines from (0, 0) into its neighbours, %d blocked by the ground: asked in (0, 0) %d agree; without its neighbours' ground %d" % [
			n_lines, blocked, agree, agree_alone])
	_check("a sight line into the next region is blocked by that region's ground (>= 97% agree)",
			agree * 100 >= n_lines * 97, "%d of %d" % [agree, n_lines])
	var hut_far: Vector3 = at.call(Vector2(1.5 * w, 0.3 * w))
	var hut_near: Vector3 = at.call(Vector2(0.2 * w, 0.3 * w))
	var up_n := hut_near.normalized()
	var up_f := hut_far.normalized()
	_check("a building 54 m past a region's edge is in its world for sight",
			r0.world.bricks_between(hut_near + up_n * 3.0, hut_far + up_f * 3.0) > 0)
	# Danger: in every region it reaches, and in one made later.
	var on_border: Vector3 = at.call(Vector2(0.5 * w, 0.0))
	net.set_danger(7, AABB(on_border - Vector3.ONE * 3.0, Vector3.ONE * 6.0))
	var r1: PlanetNavNet.Region = net.regions[Vector2i(1, 0)]
	_check("a danger box on a border is in both regions", r0.world.in_danger(on_border) and r1.world.in_danger(on_border))
	var later_q := Vector2(9.0 * w, 0.0)
	var later: Vector3 = at.call(later_q)
	net.set_danger(8, AABB(later - Vector3.ONE * 3.0, Vector3.ONE * 6.0))
	var r9 := net.ensure(Vector2i(9, 0))
	_check("and in a region made after it was set", r9.world.in_danger(later))
	net.remove_danger(7)
	net.remove_danger(8)
	_check("taken down from all of them", not r0.world.in_danger(on_border) and not r1.world.in_danger(on_border)
			and not r9.world.in_danger(later))
	net.drop(Vector2i(9, 0))
	# The fight moves on: round the far end only.
	var before := net.regions.size()
	net.keep_around([to], 60.0, 99)
	_check("regions behind the fight are dropped", net.regions_dropped > 0 and net.region_at(from) == null,
			"%d -> %d regions, %d dropped" % [before, net.regions.size(), net.regions_dropped])
	_check("and the ones round it kept", net.region_at(to) != null)
	# Built on worker threads, a region is the one built in the call.
	var tnet := PlanetNavNet.make(data, dir)
	tnet.threaded = true
	tnet.keep_around([from], 60.0)
	var t1 := Time.get_ticks_msec()
	while tnet.regions_building() > 0 and Time.get_ticks_msec() - t1 < 20000:
		tnet.service(1000)
	var same := tnet.regions.size() > 0
	var snet := PlanetNavNet.make(data, dir)
	for k in tnet.regions:
		var a: PlanetNavRegion = (tnet.regions[k] as PlanetNavNet.Region).nav_region
		var b: PlanetNavRegion = snet.ensure(k).nav_region
		same = same and a.heights == b.heights and a.frame == b.frame
	_check("regions built on worker threads are the ones built in the call", same,
			"%d region(s)" % tnet.regions.size())
