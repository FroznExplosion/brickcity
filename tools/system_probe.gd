extends SceneTree

## The universe's star systems (Docs/Planets.md 11.12): StarSystem's generator
## and its clockwork, and PlanetSystem's frames.
##
##   --headless --path . --script res://tools/system_probe.gd
##
## Is a system the same every time it is made, and in the ranges the plan
## gives? Are the orbits and spins what the clock says -- velocities the
## derivatives of positions, so a handoff carries the player at the speed the
## ground had? Is home on its orbit at noon over the spawn, and does its sun go
## round once a day? Anchoring a body turns it to the identity without moving
## anything relative to anything else; leaving it and coming back puts what
## slept on it where it was; the light goes when the planet is between the
## camera and the star.

var ok := 0
var fail := 0


func _check(what: String, cond: bool, detail := "") -> void:
	if cond:
		ok += 1
	else:
		fail += 1
	print("  %s %s%s" % ["ok  " if cond else "FAIL", what, (" -- " + detail) if detail else ""])


var _done := false
## Where the player is, for the PlanetSystem under test (a member: lambdas copy locals).
var who := Vector3.ZERO


func _process(_d: float) -> bool:
	if _done:
		return true
	_done = true
	_run()
	print("[system] %d ok, %d FAIL" % [ok, fail])
	quit(1 if fail > 0 else 0)
	return true


func _run() -> void:
	var uni := Universe.new(1)
	# The same every time.
	var a := uni.system(3)
	var b := uni.system(3)
	var same := a.bodies.size() == b.bodies.size() and a.system_name == b.system_name
	for i in mini(a.bodies.size(), b.bodies.size()):
		same = same and a.bodies[i].radius == b.bodies[i].radius and a.bodies[i].orbit_radius == b.bodies[i].orbit_radius \
				and a.bodies[i].planet_seed == b.bodies[i].planet_seed and a.pos(i, 77.0) == b.pos(i, 77.0)
	_check("a system is the same every time it is made", same, a.system_name)
	_check("and another index is another system", uni.system(4).system_name != a.system_name or uni.system(4).bodies.size() != a.bodies.size())

	# The ranges, over 60 systems.
	var counts := {}
	var in_range := true
	var why := ""
	var moons := 0
	var planets := 0
	for k in range(1, 61):
		var s := uni.system(k)
		var n := 0
		var inner := INF
		for i in s.bodies.size():
			var d := s.bodies[i]
			if d.parent < 0:
				n += 1
				inner = minf(inner, d.orbit_radius)
				if d.radius < 6000.0 or d.radius > 16000.0 or d.day < 600.0 or d.day > 2400.0:
					in_range = false
					why = "planet %s r %.0f day %.0f" % [d.planet_name, d.radius, d.day]
				if d.orbit_radius - d.radius * PlanetSystem.SHELL < s.star_radius * 2.0:
					in_range = false
					why = "%s too near its star" % d.planet_name
			else:
				moons += 1
				var p := s.bodies[d.parent]
				if d.radius < 2500.0 or d.radius > 5000.0 or d.has_air or d.day != d.orbit_period:
					in_range = false
					why = "moon %s" % d.planet_name
				if d.orbit_radius < p.radius * PlanetSystem.SHELL + d.radius:
					in_range = false
					why = "moon %s inside its planet's shell" % d.planet_name
		planets += n
		counts[n] = int(counts.get(n, 0)) + 1
		if n < 2 or n > 8:
			in_range = false
			why = "%d planets" % n
		for i in s.bodies.size():
			var d := s.bodies[i]
			if d.parent < 0 and d.orbit_radius == inner and absf(TAU * d.orbit_radius / d.orbit_period - StarSystem.V_IN) > 0.01:
				in_range = false
				why = "innermost speed %.1f" % (TAU * d.orbit_radius / d.orbit_period)
			if d.orbit_period < d.day * 8.0 and d.parent < 0:
				in_range = false
				why = "%s: a year of %.0f s, a day of %.0f s" % [d.planet_name, d.orbit_period, d.day]
	print("[system] planets a system over 60: %s; %d planets, %d moons" % [str(counts), planets, moons])
	_check("every system 2-8 planets, planets 6-16 km with 10-40 min days, moons 2.5-5 km, airless, locked, clear of shells; innermost at STA's 200 m/s; years over 8 days", in_range, why)

	# Home's system.
	var home := PlanetData.new()
	var hs := uni.system(0, home)
	_check("system 0 holds the home planet", hs.home >= 0 and hs.bodies[hs.home] == home and home.t_offset == 0.0,
			"%d bodies, home %d at %.0f km" % [hs.bodies.size(), hs.home, home.orbit_radius / 1000.0])
	var hot := 0
	var cold := 0
	for d in hs.bodies:
		if d.parent < 0 and d != home:
			if d.orbit_radius < home.orbit_radius:
				hot += int(d.t_offset > 0.0)
			else:
				cold += int(d.t_offset < 0.0)
	_check("worlds sunward of home are warmer, outward colder", hot + cold == _planets(hs) - 1)
	var spawn := Vector3(0.12, 1.0, -0.08).normalized()
	home.spin_phase = hs.noon_phase(hs.home, spawn, 0.0)
	var noon := hs.sun_local(hs.home, 0.0).dot(spawn)
	var midnight := hs.sun_local(hs.home, home.day * 0.5).dot(spawn)
	var next := hs.sun_local(hs.home, home.day).dot(spawn)
	print("[system] home: day %.0f s, year %.0f s; the sun's height at the spawn: noon %.2f, half a day on %.2f, a day on %.2f" % [
			home.day, home.orbit_period, noon, midnight, next])
	_check("the spawn has the sun high at noon and none at midnight", noon > 0.5 and midnight < 0.0)
	_check("a day on it is noon again (less a year's share)", absf(next - noon) < 0.15)

	# The clockwork: velocities are derivatives.
	var worst := 0.0
	var worst_f := 0.0
	var dt := 5.0
	for i in hs.bodies.size():
		var t := 123.0
		var fd := (hs.pos(i, t + dt) - hs.pos(i, t - dt)) / (2.0 * dt)
		worst = maxf(worst, (fd - hs.vel(i, t)).length() / maxf(fd.length(), 1.0))
		# A point on the ground: its space velocity is the frame velocity.
		var local := Vector3(0.3, 0.8, -0.5).normalized() * hs.bodies[i].radius
		var p0 := hs.xform(i, t - dt) * local
		var p1 := hs.xform(i, t + dt) * local
		var fv := hs.frame_velocity(i, t, hs.xform(i, t) * local)
		worst_f = maxf(worst_f, ((p1 - p0) / (2.0 * dt) - fv).length() / maxf(fv.length(), 1.0))
	print("[system] velocity against a finite difference: orbits %s, ground points %s (relative)" % [str(worst), str(worst_f)])
	_check("orbit velocities are the derivative of positions (moons too)", worst < 1e-3)
	_check("a point on a turning body moves at its frame velocity", worst_f < 1e-3)

	# What orbits (step 2): home's station and satellites, on their own frames.
	var st := 0
	var sat := 0
	var worst_o := 0.0
	var radial := 1.0
	for k in hs.orbitals.size():
		var o := hs.orbitals[k]
		if o.parent == hs.home:
			st += int(o.kind == "station")
			sat += int(o.kind == "satellite")
		var f := hs.bodies.size() + k
		var t := 321.0
		var local := Vector3(3.0, 10.0, -4.0)
		# A short step: a station goes round in minutes.
		var fv := hs.frame_velocity_of(f, t, hs.frame_xform(f, t) * local)
		var fd := (hs.frame_xform(f, t + 1.0) * local - hs.frame_xform(f, t - 1.0) * local) / 2.0
		worst_o = maxf(worst_o, (fd - fv).length() / maxf(fv.length(), 1.0))
		var x := hs.frame_xform(f, t)
		radial = minf(radial, x.basis.y.dot((x.origin - hs.pos(o.parent, t)).normalized()))
	print("[system] home: %d station(s), %d satellite(s); %d orbitals in the system" % [st, sat, hs.orbitals.size()])
	_check("home has its station and three satellites", st == 1 and sat == 3)
	_check("an orbital's points move at its frame velocity, its +Y away from its planet", worst_o < 1e-3 and radial > 0.9999,
			"%s, %.5f" % [str(worst_o), radial])

	_frames(hs, home)


func _planets(s: StarSystem) -> int:
	var n := 0
	for d in s.bodies:
		n += int(d.parent < 0)
	return n


## PlanetSystem's frames on system 2, all generated bodies.
func _frames(_hs: StarSystem, _home: PlanetData) -> void:
	var sys := Universe.new(1).system(2)
	var ps := PlanetSystem.new()
	ps.process_mode = Node.PROCESS_MODE_DISABLED
	root.add_child(ps)
	ps.setup(sys)
	ps.t = 300.0
	ps.observer = func() -> Vector3: return who
	ps.eye = func() -> Vector3: return who
	# Start in space, far from everything.
	who = ps.star.global_position + Vector3(0, 1.0e7, 0)
	ps._process(0.016)
	_check("far from every body: in space", ps.anchor == null)
	# Over body k's ground: it anchors.
	var k := 0
	for i in sys.bodies.size():
		if sys.bodies[i].parent < 0:
			k = i
			break
	var body := ps.bodies[k]
	var up := Vector3(0.2, 0.9, 0.3).normalized()
	who = body.global_position + body.global_basis * up * (body.data.radius + 200.0)
	var rel_before := _relations(ps)
	var who_before := who
	var t0 := Time.get_ticks_msec()
	ps._process(0.0)
	var ms := Time.get_ticks_msec() - t0
	_check("over a body's ground: it is the anchor", ps.anchor == body, "arrival %d ms (the full bake on it, the ground made)" % ms)
	_check("anchored, it has the identity basis", body.global_basis.is_equal_approx(Basis()))
	var moved := _worst(rel_before, _relations(ps))
	_check("arriving moved nothing relative to anything (bodies, star: under 1 m in 1,000 km, float32)", moved < 1e-6, "worst %s of the distance" % str(moved))
	var star_local := body.global_transform.affine_inverse() * ps.star.global_position
	ps.t += 60.0
	ps._process(0.0)
	_check("anchored, a minute later it has not moved or turned", body.global_basis.is_equal_approx(Basis()) and body.global_position.is_equal_approx(who_before - up * (body.data.radius + 200.0)))
	var star_local2 := body.global_transform.affine_inverse() * ps.star.global_position
	var turned := rad_to_deg(star_local.angle_to(star_local2))
	var off := rad_to_deg(star_local2.normalized().angle_to(sys.sun_local(k, ps.t)))
	_check("and its sky turned, the star where the clock has it", turned > 1.0 and off < 0.1,
			"%.1f deg in a minute, %.3f deg off" % [turned, off])
	# The light: on the day side lit, the far side dark.
	var to_star := (ps.star.global_position - body.global_position).normalized()
	who = body.global_position + to_star * (body.data.radius + 50.0)
	ps._light(who)
	var day_light := ps.sunlight
	who = body.global_position - to_star * (body.data.radius + 50.0)
	ps._light(who)
	_check("noon is lit, midnight is not", day_light > 0.99 and ps.sunlight < 0.01, "%.2f / %.2f" % [day_light, ps.sunlight])
	# Something on its ground sleeps when the player leaves, and is back after.
	var thing := Node3D.new()
	thing.name = "Thing"
	root.add_child(thing)
	var on := body.global_position + up.rotated(Vector3.RIGHT, 0.1).normalized() * body.data.radius
	thing.global_transform = Transform3D(Basis(Vector3.UP, 0.7), on)
	var thing_local := body.global_transform.affine_inverse() * thing.global_transform
	who = body.global_position + Vector3(1, 0, 0) * body.data.radius * PlanetSystem.SHELL * 1.2
	ps._process(0.0)
	_check("leaving its shell: in space, the kick its ground's speed", ps.anchor == null and ps.last_kick.length() > 1.0, "%.0f m/s" % ps.last_kick.length())
	_check("what was on it sleeps under it", thing.get_parent() == body and thing.process_mode == Node.PROCESS_MODE_DISABLED)
	# Far off in space while it goes round (placed first, it could come back to an
	# old point).
	who = ps.star.global_position + Vector3(0, 1.0e7, 0)
	ps.t += 200.0
	ps._process(0.0)
	_check("in space it moves and turns, what sleeps with it", (body.global_transform.affine_inverse() * thing.global_transform).is_equal_approx(thing_local)
			and not body.global_basis.is_equal_approx(Basis()))
	who = body.global_position + body.global_basis * up * (body.data.radius + 300.0)
	ps._process(0.0)
	var back := body.global_transform.affine_inverse() * thing.global_transform
	_check("back on it: what slept is on the scene's root, where it was on the ground",
			ps.anchor == body and thing.get_parent() == root and back.is_equal_approx(thing_local)
			and thing.process_mode == Node.PROCESS_MODE_INHERIT)
	# Gravity keeps the last body it was given in a static: not a freed one.
	Gravity.planet = null
	ps.queue_free()
	thing.queue_free()


## Every body's and the star's position relative to body 0's.
func _relations(ps: PlanetSystem) -> Array:
	var out := []
	var o := ps.bodies[0].global_position
	for b in ps.bodies:
		out.append(b.global_position - o)
	out.append(ps.star.global_position - o)
	return out


## The worst change of a distance, as a share of it (relative positions turn
## with the world on arrival; their lengths do not).
func _worst(a: Array, b: Array) -> float:
	var w := 0.0
	for i in a.size():
		var la := (a[i] as Vector3).length()
		if la > 1.0:
			w = maxf(w, absf(la - (b[i] as Vector3).length()) / la)
	return w
