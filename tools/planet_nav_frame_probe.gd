extends SceneTree

## The AI's world and nav seen through a planet region's frame (Docs/Planets.md
## 11.8, N1 and N1b): a 1024-stud PlanetNavRegion over the default planet, an
## AIWorld framed on it (`set_frame`) with the region's ground as its ground
## (`set_ground_grid`), and an AINav on that.
##
##   --headless --path . --script res://tools/planet_nav_frame_probe.gd
##
## The bound methods take and return WORLD values, so: does a path between two
## world points on the ground stay on the planet's ground (within a plate of
## PlanetData.height); is it the unframed nav's path over the same grid, moved
## by the frame; do a wall set in the world, cover against a threat, snap,
## the flow field's direction, danger and the nav_changed box all come back in
## the world; does a translation re-centre (shift_origin) move the region
## whole; and is the region's edge a wall?

var ok := 0
var fail := 0
var _changed: Array = []


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
	print("[nav-frame] %d ok, %d FAIL" % [ok, fail])
	quit(1 if fail > 0 else 0)
	return true


## An AIWorld + AINav on the region's grid; framed or in the region's own coordinates.
func _nav(r: PlanetNavRegion, framed: bool) -> AINav:
	var aw := AIWorld.new()
	aw.set_world(BrickWorld.new())
	if framed:
		aw.set_frame(r.frame)
	aw.set_ground_grid(Vector2(-r.half, -r.half), r.step_m, r.size, r.heights)
	aw.set_terrain_ground(true)
	aw.sync()
	var nav := AINav.new()
	nav.set_ai_world(aw)
	if not is_nan(r.sea_y):
		nav.set_water_level(r.sea_y)
	_worlds[nav] = aw
	return nav


func _altitude_error(data: PlanetData, p: Vector3) -> float:
	return absf(p.length() - data.radius - data.height(p.normalized()))


func _run() -> void:
	var data := PlanetData.new()
	var dir := Vector3(0.12, 1.0, -0.08).normalized()
	data.pads.append({"dir": dir, "height": 20.0, "flat": 60.0, "blend": 40.0})
	var r := PlanetNavRegion.make(data, dir)
	var plate := BrickWorld.get_plate_metres()
	var nav := _nav(r, true)
	var flat := _nav(r, false)
	# Two points on the ground, ~150 m apart across the pad and off it.
	var la := Vector3(-70.0, 0.0, -50.0)
	var lb := Vector3(75.0, 0.0, 40.0)
	la.y = r.ground_at(la.x, la.z)
	lb.y = r.ground_at(lb.x, lb.z)
	var a := r.frame * la
	var b := r.frame * lb
	var t0 := Time.get_ticks_usec()
	var path := nav.find_path(a, b, 200000)
	var ms := float(Time.get_ticks_usec() - t0) / 1000.0
	print("[nav-frame] path of %d points in %.0f ms; sea %.2f m in the frame" % [path.size(), ms, r.sea_y])
	_check("a path between two world points on the ground", path.size() > 2)
	if path.size() > 2:
		_check("it starts and ends by them (< 1 m)", path[0].distance_to(a) < 1.0
				and path[path.size() - 1].distance_to(b) < 1.0,
				"%.2f, %.2f m" % [path[0].distance_to(a), path[path.size() - 1].distance_to(b)])
		var worst := 0.0
		for p in path:
			worst = maxf(worst, _altitude_error(data, p))
		_check("its points are on the planet's ground (within a plate, %.3f m)" % plate, worst <= plate,
				"worst %.3f m" % worst)
		var lpath := flat.find_path(la, lb, 200000)
		var same := lpath.size() == path.size()
		var off := 0.0
		if same:
			for k in path.size():
				off = maxf(off, path[k].distance_to(r.frame * lpath[k]))
		_check("it is the unframed nav's path over the same grid, moved by the frame",
				same and off < 0.01, "%d vs %d points, %.4f m" % [path.size(), lpath.size(), off])
	# The ground under a world point, and the top over it, in the world.
	var w0 := _world_of(nav)
	var gu: Vector3 = w0.ground_under(a + r.frame.basis.y * 3.0 + r.frame.basis.x * 0.2)
	_check("ground_under is on the planet's ground, in the world", _altitude_error(data, gu) <= plate,
			"%.3f m" % _altitude_error(data, gu))
	var to: Vector3 = w0.top_over(a + r.frame.basis.y * 3.0)
	_check("top_over is the ground's top with nothing on it", to.distance_to(w0.ground_under(a)) < 0.01)
	# snap / can_stand in the world.
	var above := a + r.frame.basis.y * 0.4
	var s := nav.snap(above)
	_check("snap comes back on the ground in the world", _altitude_error(data, s) <= plate
			and s.distance_to(a) < 1.0, "%.3f m off the ground, %.2f m away" % [_altitude_error(data, s), s.distance_to(a)])
	_check("can_stand at a world point on the ground", nav.can_stand(s))
	# A wall set in the world, square to the region, between a threat and a spot.
	var w_aw := _world_of(nav)
	var lc := Vector3(0.0, r.ground_at(0.0, 10.0), 10.0)
	var wall := Transform3D(r.frame.basis, r.frame * (lc + Vector3(0.0, 1.5, 0.0)))
	w_aw.set_proxy(1, wall, Vector3(6.0, 3.0, 0.7), 1.0 / BrickWorld.get_stud_metres())
	w_aw.sync()
	nav.invalidate_box(AABB(wall.origin - Vector3(4, 4, 4), Vector3(8, 8, 8)))
	var eye_l := Vector3(0.0, r.ground_at(0.0, -10.0) + 1.5, -10.0)
	var eye := r.frame * eye_l
	var behind := r.frame * Vector3(0.0, r.ground_at(0.0, 12.0) + 1.0, 12.0)
	_check("the wall blocks the line in the world", not w_aw.line_clear(eye, behind))
	var tr: Dictionary = w_aw.trace(eye, behind)
	var hit: Vector3 = tr.get("point", Vector3.ZERO)
	var hit_l := r.frame.affine_inverse() * hit
	_check("trace's point is on the wall, in the world", bool(tr.get("hit", false))
			and absf(hit_l.z - (10.0 - 0.35)) < 0.2, "region z %.2f" % hit_l.z)
	var cover: Dictionary = nav.find_cover(r.frame * Vector3(1.0, r.ground_at(1.0, 13.0), 13.0), eye, 20, 8.0, 15.0)
	var cp: Vector3 = cover.get("cover", Vector3.INF)
	var cp_l := r.frame.affine_inverse() * cp if cover else Vector3.INF
	_check("find_cover finds the wall's lee, in the world", not cover.is_empty()
			and cp_l.z > 10.0 and absf(cp_l.x) < 3.5 and _altitude_error(data, cp) <= plate,
			str(cp_l))
	# The flow field, against the unframed nav's over the same grid: its cost at
	# a world point, its direction turned by the frame. (field_dir is zero
	# everywhere on main as well, flat ground too: it only takes a neighbour
	# STRICTLY cheaper than the Dijkstra's own parent, which ties exactly. Not
	# the frame's to fix -- it would move the flat game.)
	var fid := nav.request_field(b, 30.0, 1.0)
	var lfid := flat.request_field(lb, 30.0, 1.0)
	for k in 200:
		nav.service(5000)
		flat.service(5000)
		if nav.get_field_status(fid) == AINav.DONE and flat.get_field_status(lfid) == AINav.DONE:
			break
	var lf := Vector3(lb.x - 12.0, r.ground_at(lb.x - 12.0, lb.z), lb.z)
	var from_f := r.frame * lf
	var fc := nav.field_cost(fid, from_f)
	_check("field_cost at a world point is the unframed field's", is_finite(fc)
			and absf(fc - flat.field_cost(lfid, lf)) < 1e-4, "%.3f m" % fc)
	var fd := nav.field_dir(fid, from_f)
	_check("field_dir is the unframed field's, turned by the frame",
			fd.distance_to(r.frame.basis * flat.field_dir(lfid, lf)) < 1e-4, str(fd))
	# Danger, set and asked in the world.
	w_aw.set_danger(1, AABB(b - Vector3(1, 1, 1), Vector3(2, 2, 2)))
	_check("danger is asked in the world", w_aw.in_danger(b) and not w_aw.in_danger(a)
			and w_aw.danger_distance(b + r.frame.basis.x * 3.0) < 2.5)
	# nav_changed carries the world box.
	nav.nav_changed.connect(func(box: AABB) -> void: _changed.append(box))
	var box := AABB(b - Vector3(2, 2, 2), Vector3(4, 4, 4))
	nav.invalidate_box(box)
	_check("nav_changed carries the world box", _changed.size() == 1 and _changed[0] == box)
	# The edge: a wall. A world point just outside the region is no floor.
	var out := r.frame * Vector3(r.half + 3.0, r.ground_at(r.half - 0.1, 0.0), 0.0)
	_check("outside the region nobody stands", not nav.can_stand(out))
	# A translation re-centre: the region moves whole.
	var shift := Vector3(-35.0, 12.5, 80.0)
	w_aw.shift_origin(shift)
	w_aw.sync()
	var path2 := nav.find_path(a + shift, b + shift, 200000)
	var off2 := 0.0 if path2.size() == path.size() else INF
	if path2.size() == path.size():
		for k in path.size():
			off2 = maxf(off2, path2[k].distance_to(path[k] + shift))
	_check("shift_origin moves the region whole", off2 < 0.01, "%.4f m" % off2)
	_check("its frame moved by the shift", w_aw.get_frame().origin.is_equal_approx(r.frame.origin + shift))


## The AIWorld under a nav made by _nav (kept here so the probe can talk to it).
var _worlds := {}
func _world_of(nav: AINav) -> AIWorld:
	return _worlds[nav]
