extends SceneTree

## Test 5 of the sphere-planet feasibility tests (Docs/Planets.md 10b):
## walking round a sphere on local down, with the radial walker
## (tools/planet_radial_body.gd, after STA doc 05).
##
##   --headless --fixed-fps 30 --path . --script res://tools/planet_walk_probe.gd
##
## On a 150 m planet of plain mesh (a trimesh, as tiles would be):
##   * a full great circle walking forward -- over both poles -- and one
##     strafing: how far the path leaves its great circle, where it ends, how
##     often the feet leave the ground, whether the camera ever rolls;
##   * standing jumps at the equator, 45 degrees and the pole: where they land;
##   * a 30 degree ramp (walked up) and a 60 degree one (not);
## and on a 10 km planet (an exact sphere, the origin at the walker, as a
## shifted origin puts it): 2 km forward and 2 km strafing.
## Pawn-sized, then mech-sized (a capsule 7 m tall, 1.4 m round, 6 m/s).

const Radial := preload("res://tools/planet_radial_body.gd")

var step := 0
var ok := 0
var fail := 0


func _initialize() -> void:
	pass


func _process(_delta: float) -> bool:
	if step == 0:
		step = 1
		_run()
	return false


func _ticks(n: int) -> void:
	for i in n:
		await physics_frame


func _check(what: String, cond: bool, detail := "") -> void:
	if cond:
		ok += 1
	else:
		fail += 1
	print("  %s %s%s" % ["ok  " if cond else "FAIL", what, (" -- " + detail) if detail else ""])


func _run() -> void:
	var world := Node3D.new()
	root.add_child(world)
	var small := _sphere_mesh_body(150.0, Vector3.ZERO)
	world.add_child(small)
	for kind in ["pawn", "mech"]:
		var w = Radial.new()
		if kind == "mech":
			_make_mech(w)
		w.centre = Vector3.ZERO
		world.add_child(w)
		print("[walk] %s on a 150 m planet (trimesh)" % kind)
		await _loop(w, 150.0, false)
		await _loop(w, 150.0, true)
		await _jumps(w, 150.0)
		w.queue_free()
	# Ramps, pawn only.
	var w2 = Radial.new()
	w2.centre = Vector3.ZERO
	world.add_child(w2)
	await _ramps(w2, 150.0, world)
	w2.queue_free()
	small.queue_free()
	await _ticks(2)

	# 10 km: an exact sphere, its centre 10 km under the origin.
	var big_c := Vector3(0.0, -10000.0, 0.0)
	var big := StaticBody3D.new()
	var bcs := CollisionShape3D.new()
	var bs := SphereShape3D.new()
	bs.radius = 10000.0
	bcs.shape = bs
	big.add_child(bcs)
	world.add_child(big)
	big.global_position = big_c
	for kind in ["pawn", "mech"]:
		var w = Radial.new()
		if kind == "mech":
			_make_mech(w)
		w.centre = big_c
		world.add_child(w)
		print("[walk] %s on a 10 km planet, origin at the walker" % kind)
		await _stretch(w, big_c, 10000.0, false, 2000.0)
		await _stretch(w, big_c, 10000.0, true, 2000.0)
		w.queue_free()
	print("[walk] %d ok, %d FAIL" % [ok, fail])
	quit(1 if fail > 0 else 0)


func _make_mech(w) -> void:
	for c in w.get_children():
		if c is CollisionShape3D:
			var cap := CapsuleShape3D.new()
			cap.radius = 1.4
			cap.height = 7.0
			c.shape = cap
			c.position = Vector3(0.0, 3.5, 0.0)
	w.camera.position = Vector3(0.0, 6.0, 0.0)
	w.speed = 6.0
	w.floor_max_angle = deg_to_rad(40.0)
	w.floor_snap_length = 0.6


func _sphere_mesh_body(r: float, at: Vector3) -> StaticBody3D:
	var sm := SphereMesh.new()
	sm.radius = r
	sm.height = r * 2.0
	sm.radial_segments = 512
	sm.rings = 256
	var body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	cs.shape = sm.create_trimesh_shape()
	body.add_child(cs)
	body.position = at
	return body


## A great circle from the equator: forward (north, over both poles) or
## strafing. Its plane is fixed by the start: the walker's right for forward,
## its forward for a strafe.
func _loop(w, r: float, strafe: bool) -> void:
	var start := Vector3(r + 0.02, 0.0, 0.0)
	w.place(start, Vector3.UP)
	await _ticks(20)
	var n0: Vector3 = w.global_transform.basis.z if strafe else w.global_transform.basis.x
	var p0: Vector3 = w.global_position
	w.wish = Vector2(1.0, 0.0) if strafe else Vector2(0.0, 1.0)
	var length := TAU * r
	var ticks := int(ceil(length / w.speed * 30.0))
	var off := 0.0
	var roll := 0.0
	var air0: int = w.air_ticks
	var gone := 0.0
	var prev: Vector3 = w.global_position
	var lifted := 0.0
	for i in ticks:
		await physics_frame
		var p: Vector3 = w.global_position
		off = maxf(off, absf((p - w.centre).normalized().dot(n0)) * r)
		gone += p.distance_to(prev)
		prev = p
		lifted = maxf(lifted, absf((p - w.centre).length() - r))
		var cup: Vector3 = w.camera.global_transform.basis.x
		roll = maxf(roll, rad_to_deg(asin(clampf(absf(cup.dot(w.up)), 0.0, 1.0))))
	w.wish = Vector2.ZERO
	await _ticks(5)
	var end: Vector3 = w.global_position
	var what := "strafing" if strafe else "forward, over both poles"
	print("[walk]   great circle %s: walked %.1f m of %.1f; off its plane at most %.3f m; ends %.2f m from the start; feet off the ground %d of %d ticks; feet at most %.3f m off the surface; camera roll at most %.3f deg" % [
			what, gone, length, off, end.distance_to(p0), w.air_ticks - air0, ticks, lifted, roll])
	_check("%s: no drift off the great circle (< 0.1 m)" % what, off < 0.1, "%.3f m" % off)
	_check("%s: back where it began (< 1 m)" % what, end.distance_to(p0) < 1.0, "%.2f m" % end.distance_to(p0))
	_check("%s: feet on the ground (> 99%% of ticks)" % what, w.air_ticks - air0 < ticks / 100, "%d off" % (w.air_ticks - air0))
	_check("%s: the camera never rolls (< 0.01 deg)" % what, roll < 0.01, "%.3f" % roll)


## Standing jumps at the equator, 45 degrees up and the pole.
func _jumps(w, r: float) -> void:
	for lat in [0.0, 45.0, 89.9]:
		var d := Vector3(cos(deg_to_rad(lat)), sin(deg_to_rad(lat)), 0.0)
		w.place(d * (r + 0.02), Vector3(0, 0, 1))
		await _ticks(15)
		var p0: Vector3 = w.global_position
		w.jump = true
		var t := 0
		var peak := 0.0
		var left := false
		while t < 120:
			await physics_frame
			t += 1
			peak = maxf(peak, (w.global_position - w.centre).length() - r)
			if not w.is_on_floor():
				left = true
			elif left:
				break
		var drift: float = w.global_position.distance_to(p0)
		print("[walk]   jump at %.0f deg: %.2f s in the air, %.2f m high, lands %.3f m from where it left" % [
				lat, t / 30.0, peak, drift])
		_check("jump at %.0f deg lands where it left (< 0.05 m)" % lat, left and drift < 0.05, "%.3f m" % drift)


## A ramp standing on the sphere at 20 degrees round, tilted `deg` from the
## ground there; the walker sets off at it from 6 m away.
func _ramps(w, r: float, parent: Node) -> void:
	for deg in [30.0, 60.0]:
		var at := deg_to_rad(20.0)
		var up := Vector3(cos(at), sin(at), 0.0)
		var fwd := Vector3(-sin(at), cos(at), 0.0)   # toward the pole, tangent
		var side := up.cross(fwd)
		var ramp := StaticBody3D.new()
		var cs := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(4.0, 0.4, 12.0)
		cs.shape = box
		ramp.add_child(cs)
		parent.add_child(ramp)
		# Rising along fwd at `deg` from its low end, which is on the ground at
		# `at`; its top face passes through that point.
		var th := deg_to_rad(deg)
		var d := fwd * cos(th) + up * sin(th)
		var n := up * cos(th) - fwd * sin(th)
		var low := up * r
		ramp.global_transform = Transform3D(Basis(side, n, -d), low + d * 6.0 - n * 0.2)
		var start_d := Vector3(cos(at - 6.0 / r), sin(at - 6.0 / r), 0.0)
		w.place(start_d * (r + 0.02), fwd)
		await _ticks(10)
		w.wish = Vector2(0.0, 1.0)
		var best := 0.0
		var floor_on_ramp := 0
		for i in 150:
			await physics_frame
			var h: float = (w.global_position - w.centre).length() - r
			best = maxf(best, h)
			if w.is_on_floor() and h > 0.5:
				floor_on_ramp += 1
		w.wish = Vector2.ZERO
		print("[walk]   ramp %.0f deg: climbed to %.2f m over the ground, on its floor for %d ticks" % [
				deg, best, floor_on_ramp])
		if deg < 50.0:
			_check("a 30 deg ramp is walked up (over 2 m, on its floor)", best > 2.0 and floor_on_ramp > 10, "%.2f m" % best)
		else:
			_check("a 60 deg ramp is not walked up (under 1 m)", best < 1.0, "%.2f m" % best)
		ramp.queue_free()
		await _ticks(2)


## On the 10 km planet: `dist` metres forward or strafing from the point
## under the origin.
func _stretch(w, c: Vector3, r: float, strafe: bool, dist: float) -> void:
	w.place(Vector3(0.0, 0.02, 0.0), Vector3(0, 0, -1))
	await _ticks(20)
	var n0: Vector3 = w.global_transform.basis.z if strafe else w.global_transform.basis.x
	w.wish = Vector2(1.0, 0.0) if strafe else Vector2(0.0, 1.0)
	var ticks := int(dist / w.speed * 30.0)
	var off := 0.0
	var air0: int = w.air_ticks
	var first_off := -1
	var last_off := -1
	for i in ticks:
		await physics_frame
		off = maxf(off, absf((w.global_position - c).normalized().dot(n0)) * r)
		if not w.is_on_floor():
			if first_off < 0:
				first_off = i
			last_off = i
	w.wish = Vector2.ZERO
	if first_off >= 0:
		print("[walk]   (off the floor first at tick %d, last at %d; %.1f m up there)" % [
				first_off, last_off, (w.global_position - c).length() - r])
	var p: Vector3 = w.global_position
	var arc := (p - c).normalized().angle_to(Vector3.UP) * r
	var what := "strafing" if strafe else "forward"
	print("[walk]   %s %.0f m: %.1f m along the surface, off its great circle %.3f m, feet off %d of %d ticks, %.1f m out from the origin" % [
			what, dist, arc, off, w.air_ticks - air0, ticks, p.length()])
	_check("10 km, %s: no drift (< 0.1 m over %.0f m)" % [what, dist], off < 0.1, "%.3f m" % off)
