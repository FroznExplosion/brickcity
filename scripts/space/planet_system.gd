class_name PlanetSystem
extends Node3D

## A star system in the scene (Docs/Planets.md 11.12). After STA's SolarSystem
## (C:\Users\lbaun\Documents\sta\scripts\solar_system.gd): the star, every body
## of a StarSystem (impostors; voxel ground only on the one the player is on),
## the orbit clock, and the frames.
##
## ANCHORED (the player inside a body's shell): that body holds still with an
## identity basis -- its co-rotating frame -- and the star and the other bodies
## turn round it, so nothing on its ground ever moves or turns. IN SPACE: the
## star's frame, held at the turn it had when the player left; every body
## orbits and spins. Crossing a shell is a handoff: the player's velocity
## changes by the two frames' velocities at its point (STA Docs/12 §3, with the
## spin, `anchor_changed`'s kick); arriving, the body is turned back to the
## identity by turning the world once about the player -- only what is not
## asleep on a body moves, rigidly, so nothing seen changes.
##
## A body left behind SLEEPS: the scene's top-level things on it (all but the
## player's, group RIG) go under its node with their process off (bodies leave
## physics), so they ride its orbit and spin exactly and no origin shift
## touches them; on arrival they come back where they were on its ground, and
## `woke` gives what holds world positions for it the offset to take.
##
## The scene says where the player is (`observer`) and the camera (`eye`), and
## owns the sun light (`sun`); this aims it from the star and says how much of
## the star's disc the camera sees (`sunlight`: night, a planet's shadow, an
## eclipse) and how high it stands there (`sun_height`).

## Inside SHELL radii of a body's centre the player is ON it (STA's
## active_shell_radius_mult is 3; 5 keeps the walker gate's 30 km climb on the
## home planet). Left again only past SHELL_OUT of that.
const SHELL := 5.0
const SHELL_OUT := 1.03
## The sun light turns in steps this big (rad, 0.05 deg), not every frame, so
## the shadow cascades do not crawl.
const SUN_STEP := 0.00087
## Impostor maps: small first for every body, then the full set (the voxel
## ground's biome map) nearest first.
const BAKE_SMALL := Vector2i(192, 96)
const BAKE_FULL := Vector2i(512, 256)
## Scaled space: what is further than FAR_VIEW from the camera is drawn at
## FAR_VIEW (plus a little by the log of its distance, so what is behind stays
## behind), shrunk to the same size on screen. Cameras need not reach further
## than SEE_FAR (a far plane of 5e7 m broke the renderer's light culler).
const FAR_VIEW := 100000.0
const SEE_FAR := 250000.0
## A settled world's buildings are made within POPULATE_AT of the player, and
## its far tier kept up within FAR_TIER_AT (past it they are gone from the screen).
const POPULATE_AT := 700000.0
const FAR_TIER_AT := 1000000.0
## Top-level nodes in this group are the player's: they travel, never sleep.
const RIG := &"player_rig"

## `kick`: the world velocity everything that travels takes on at this handoff
## (its velocity already turned with the world). A frame is a PlanetBody, a
## SpaceStation, or null (space).
signal anchor_changed(old_frame: Node3D, new_frame: Node3D, kick: Vector3)
## `frame` woke as the anchor: what holds world positions for it, and was not
## shifted while it slept, takes `offset`.
signal woke(frame: Node3D, offset: Vector3)

## The system is another now (step 5): nothing of the last is left but home.
signal jumped(index: int)

## A station nearer than this is the velocity flight matches (docking).
const MATCH_STATION := 6000.0

var sys: StarSystem
var universe: Universe
var system_index := 0
var _home_sys: StarSystem
var _home_body: PlanetBody
## By index in sys.bodies; home's is the scene's own PlanetBody.
var bodies: Array[PlanetBody] = []
## By index in sys.orbitals.
var stations: Array[SpaceStation] = []
## The orbit clock, seconds; `time_scale` 1 is STA's pace.
var t := 0.0
var time_scale := 1.0
## Stopped: no orbit, no spin, no handoff kick (STA's T). Every gate but the
## system's own runs stopped.
var frozen := false
## The planet the player is on, or null (in space, or on a station).
var anchor: PlanetBody = null
## The station the player is on, or null.
var station: SpaceStation = null
## Ships (step 3), and the one the player is aboard in space, or null.
var ships: Array[SpaceShip] = []
var ship: SpaceShip = null
## Body -> its PlanetBuildings (the home planet's is the scene's) and PlanetTrees.
var built := {}
var trees_of := {}
## Where the star truly is (its node); `star_look` draws it.
var star: Node3D
var star_look: MeshInstance3D
var sun: DirectionalLight3D
var sun_energy := 1.1
var observer: Callable
var eye: Callable
## How much of the star's disc the camera sees, 0..1.
var sunlight := 1.0
## sin of the sun's height over the horizon of the body nearest the camera.
var sun_height := 1.0
var handoffs := 0
var last_kick := Vector3.ZERO

var _space_basis := Basis()
var _sleepers := {}
var _left_at := {}
var _sun_dir := Vector3.ZERO
var _bake_task := -1
var _bake_body: PlanetBody
var _bake_data: PlanetData
var _bake_size := Vector2i.ZERO
var _bake_result := {}


## The bodies of `p_sys`; `home_body` (the scene's, already built and anchored)
## for the home planet's index.
func setup(p_sys: StarSystem, home_body: PlanetBody = null) -> void:
	sys = p_sys
	name = "System_" + sys.system_name
	process_priority = -1
	_home_sys = p_sys
	_home_body = home_body
	_build_bodies()
	if home_body != null:
		anchor = home_body
	_build_star()
	_place()


## The bodies, stations and satellites of `sys`.
func _build_bodies() -> void:
	for i in sys.bodies.size():
		if i == sys.home and _home_body != null:
			bodies.append(_home_body)
			_home_body.visible = true
			continue
		var b := PlanetBody.new()
		add_child(b)
		b.setup(sys.bodies[i], true)
		b.process_mode = Node.PROCESS_MODE_DISABLED
		b.far_only()
		bodies.append(b)
	for k in sys.orbitals.size():
		var st := SpaceStation.new()
		add_child(st)
		st.setup(sys.orbitals[k])
		st.process_mode = Node.PROCESS_MODE_DISABLED
		stations.append(st)
		# Home's stations' bricks while the scene loads.
		if sys.orbitals[k].parent == sys.home and _home_body != null:
			st.prepare()


## At the ship's controls in open space: its jump drive works.
func can_jump() -> bool:
	return ship != null and ship.piloted and ship.ref == null


## Swap the system round the ship for system `index` of the universe. All of
## this one goes but the home planet: hidden, with all that sleeps on it, and
## kept with its StarSystem, so it comes back on its own orbit. The ship is set
## down short of the new system's first settled world (else its first planet),
## on the sun's side.
func jump(index: int) -> bool:
	if not can_jump() or index == system_index:
		return false
	var t0 := Time.get_ticks_usec()
	if _bake_task >= 0:
		WorkerThreadPool.wait_for_task_completion(_bake_task)
		_bake_task = -1
		_bake_result = {}
	_bake_body = null
	for b in bodies:
		if b == _home_body:
			b.visible = false
		else:
			built.erase(b)
			_sleepers.erase(b)
			_left_at.erase(b)
			b.queue_free()
	for st in stations:
		st.queue_free()
	bodies.clear()
	stations.clear()
	trees_of.clear()
	system_index = index
	sys = _home_sys if index == 0 else universe.system(index)
	_build_bodies()
	(star_look.mesh as SphereMesh).radius = sys.star_radius
	(star_look.mesh as SphereMesh).height = sys.star_radius * 2.0
	(star_look.material_override as StandardMaterial3D).albedo_color = sys.star_color
	var at := 0
	for i in sys.bodies.size():
		if sys.bodies[i].parent < 0 and (not sys.bodies[i].towns.is_empty() or i == sys.home):
			at = i
			break
	var p := sys.pos(at, t)
	var off := sys.bodies[at].radius * SHELL * 1.3 + 30000.0
	ship.rel = Transform3D(ship.rel.basis, p * (1.0 - off / p.length()))
	ship.vel = sys.vel(at, t)
	_place()
	print("[system] jumped to %s (%d): %d bodies in %.1f ms" % [sys.system_name, index, bodies.size(), (Time.get_ticks_usec() - t0) / 1000.0])
	jumped.emit(index)
	return true


func index_of(b: PlanetBody) -> int:
	return bodies.find(b)


## The frame the player is in: its station, its planet, or null (space).
func frame_node() -> Node3D:
	if ship != null:
		return ship
	return station if station != null else anchor


## A ship into the system, in planet `ref`'s frame (null: the star's) at `rel`.
func add_ship(d: OrbitalData, ref: PlanetBody, rel: Transform3D) -> SpaceShip:
	var s := SpaceShip.new()
	add_child(s)
	s.setup_ship(d)
	s.ref = ref
	s.rel = rel
	s.landed = ref != null
	ships.append(s)
	_place()
	return s


## Frame `n`'s transform, space frame, now.
func _frame_xform(n: Node3D) -> Transform3D:
	if n is SpaceShip:
		return (n as SpaceShip).space_xform(self)
	return sys.frame_xform(_fi(n), t)


## A frame's index in StarSystem's frames.
func _fi(n: Node3D) -> int:
	if n is PlanetBody:
		return bodies.find(n)
	return bodies.size() + stations.find(n)


static func name_of(n: Node3D) -> String:
	if n is PlanetBody:
		return (n as PlanetBody).data.planet_name
	if n is SpaceStation:
		return (n as SpaceStation).data.orbital_name
	return "space"


## Space frame to world, now.
func space_to_world() -> Transform3D:
	var f := frame_node()
	if f != null:
		return Transform3D(Basis(), f.global_position) * _frame_xform(f).affine_inverse()
	return Transform3D(_space_basis, star.global_position)


## The body whose ground is nearest a world point.
func nearest(p: Vector3) -> PlanetBody:
	var best: PlanetBody = null
	var best_d := INF
	for b in bodies:
		var d := (p - b.global_position).length() - b.data.radius
		if d < best_d:
			best_d = d
			best = b
	return best


## The world velocity flight there should hold to (a flight computer): a
## station's within MATCH_STATION of it, to dock; else still on a planet or
## station; in space the nearest body's orbital velocity.
func match_velocity(p: Vector3) -> Vector3:
	if frozen:
		return Vector3.ZERO
	var s2w := space_to_world()
	var x := s2w.affine_inverse() * p
	var here := _frame_velocity(frame_node(), x)
	for st in stations:
		if st.is_station() and st != station and (st.global_position - p).length() < MATCH_STATION:
			return s2w.basis * (_frame_velocity(st, x) - here)
	if frame_node() != null:
		return Vector3.ZERO
	return s2w.basis * sys.vel(index_of(nearest(p)), t)


## The hour of the day (0..24) at a world point on the anchor: 12 with the sun
## over its meridian.
func hour_at(p: Vector3) -> float:
	var b := anchor if anchor != null else nearest(p)
	var i := index_of(b)
	var axis := b.global_basis * b.data.climate_axis.normalized()
	var here := (p - b.global_position)
	here -= axis * here.dot(axis)
	var s := star.global_position - b.global_position
	s -= axis * s.dot(axis)
	if here.length_squared() < 1.0 or s.length_squared() < 1.0 or sys.bodies[i].day <= 0.0:
		return 12.0
	return fposmod(12.0 - here.signed_angle_to(s, axis) * 12.0 / PI, 24.0)


## The buildings of the world the player is on, or null.
func buildings_here() -> PlanetBuildings:
	return built.get(anchor) if anchor != null else null


## The floating origin moved the scene: a station's or ship's bricks follow,
## and a generated world's (the scene moves home's, with its AI).
func on_origin_shift() -> void:
	if anchor != null and index_of(anchor) != sys.home and built.has(anchor):
		(built[anchor] as PlanetBuildings).on_origin_shift()
	if station != null:
		station.on_origin_shift()
	for s in ships:
		s.on_origin_shift()


func _process(delta: float) -> void:
	if not frozen:
		t += delta * time_scale
	for s in ships:
		s.fly(self, delta)
	_ship_refs()
	# Where everything is this frame before asking which frame the player is in.
	_place()
	if observer.is_valid():
		_choose_anchor(observer.call())
		_prepare_near(observer.call())
		_ship_bricks(observer.call())
		_populate_near(observer.call())
	_place()
	_gravity()
	if eye.is_valid():
		_light(eye.call())
		_scaled_space(eye.call())
		_far_tiers(eye.call())
	_bake_service()


## One settled world's buildings a frame, once the player is near enough to see them.
func _populate_near(p: Vector3) -> void:
	for b in bodies:
		if not b.data.towns.is_empty() and not built.has(b) \
				and (b.global_position - p).length() < POPULATE_AT:
			_populate(b)
			return


func _populate(b: PlanetBody) -> void:
	var t0 := Time.get_ticks_usec()
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(str("build:", b.data.planet_seed))
	var pb := PlanetBuildings.new()
	b.add_child(pb)
	pb.setup(b)
	for dir in b.data.towns:
		pb.add_town(dir, rng.randi_range(3, 6), 30.0, rng)
	for dir in b.data.landmarks:
		pb.add_landmark(dir, 80, 80, rng.randi_range(400, 900), rng)
	pb.finish()
	built[b] = pb
	print("[system] %s: %d buildings in %.1f ms" % [b.data.planet_name, pb.sites.size(), (Time.get_ticks_usec() - t0) / 1000.0])


## A world asleep is still seen from space: its far tier, while it could show.
func _far_tiers(e: Vector3) -> void:
	for b in built:
		if b != anchor and b in bodies and ((b as PlanetBody).global_position - e).length() < FAR_TIER_AT:
			(built[b] as PlanetBuildings).far_tier()


## A station's template built once the player is within PREPARE_AT of it.
const PREPARE_AT := 20000.0


func _prepare_near(p: Vector3) -> void:
	for st in stations:
		if st.is_station() and st._template < 0 and (st.global_position - p).length() < PREPARE_AT:
			st.prepare()
			print("[system] %s prepared on the way in: %.1f ms" % [st.data.orbital_name, st.template_ms])
			return


## Every frame but the player's, and the star, where the clock has them.
func _place() -> void:
	var s2w := space_to_world()
	var f := frame_node()
	star.global_position = s2w.origin
	for i in bodies.size():
		if bodies[i] != f:
			bodies[i].global_transform = s2w * sys.xform(i, t)
	for k in stations.size():
		if stations[k] != f:
			stations[k].global_transform = s2w * sys.orbital_xform(k, t)
	for s in ships:
		if s != f:
			s.global_transform = s2w * s.space_xform(self)
	for b in bodies:
		b.set_sun(b.global_basis.inverse() * (star.global_position - b.global_position).normalized())


func _gravity() -> void:
	var on := frame_node()
	if on is SpaceStation:
		Gravity.planet = (on as SpaceStation).gravity_centre
		Gravity.planet_strength = (on as SpaceStation).data.gravity
		Gravity.planet_radius = SpaceStation.DEPTH
		return
	var g := anchor
	if g == null and observer.is_valid():
		g = nearest(observer.call())
	if g == null:
		return
	Gravity.planet = g
	Gravity.planet_strength = g.data.gravity_strength
	Gravity.planet_radius = g.data.radius


## A station's field first (it is in its planet's shell), then the planets'.
func _choose_anchor(p: Vector3) -> void:
	# A ship in open space first: aboard it, it is the frame.
	if ship != null and ship.ref == null and (p - ship.global_position).length() < ship.field * SHELL_OUT:
		return
	for s in ships:
		if s.ref == null and (p - s.global_position).length() < s.field:
			if s != frame_node():
				_switch(s, p)
			return
	if station != null and (p - station.global_position).length() < station.field * SHELL_OUT:
		return
	for st in stations:
		if st.is_station() and (p - st.global_position).length() < st.field:
			if st != frame_node():
				_switch(st, p)
			return
	if station == null and anchor != null \
			and (p - anchor.global_position).length() < anchor.data.radius * SHELL * SHELL_OUT:
		return
	var best: PlanetBody = null
	var best_q := 1.0
	for b in bodies:
		var q := (p - b.global_position).length() / (b.data.radius * SHELL)
		if q < best_q:
			best_q = q
			best = b
	if best != frame_node():
		_switch(best, p)


## Hand the frame over from the player's to `next` (a body, a station, or null:
## space) at the player's world point `p`.
func _switch(next: Node3D, p: Vector3) -> void:
	var old := frame_node()
	var s2w := space_to_world()
	var x := s2w.affine_inverse() * p
	var vf_old := _frame_velocity(old, x)
	if old != null:
		# Into the star's frame, at the turn the world has now.
		_space_basis = s2w.basis
		star.global_position = s2w.origin
		anchor = null
		station = null
		ship = null
		_sleep(old)
	var s2w_new := space_to_world()
	if next != null:
		# `next` is turned to the identity where it is seen from the player:
		# the world turns about the player, who stays put.
		var tx := _frame_xform(next)
		var at := p - tx.basis.inverse() * (x - tx.origin)
		s2w_new = Transform3D(Basis(), at) * tx.affine_inverse()
		var m := s2w_new * s2w.affine_inverse()
		next.global_transform = Transform3D(Basis(), at)
		if next is SpaceShip:
			ship = next
		elif next is SpaceStation:
			station = next
		else:
			anchor = next
		_travel(m)
		_wake(next)
	var kick := s2w_new.basis * (vf_old - _frame_velocity(next, x))
	handoffs += 1
	last_kick = kick
	print("[system] handoff %s -> %s at t %.1f s: kick %.1f m/s" % [name_of(old), name_of(next), t, kick.length()])
	_place()
	anchor_changed.emit(old, next, kick)


## The space-frame velocity of frame `n` at space point `x` (0: the star's
## frame, or the clock stopped).
func _frame_velocity(n: Node3D, x: Vector3) -> Vector3:
	if n is SpaceShip:
		return (n as SpaceShip).frame_velocity(self, x)
	if n == null or frozen:
		return Vector3.ZERO
	return sys.frame_velocity_of(_fi(n), t, x)


## For ship `s`, by a station within MATCH_STATION: [its velocity in the ship's
## reference frame, its distance]; else [zero, -1].
func ship_match(s: SpaceShip) -> Array:
	var x := s.space_xform(self).origin
	for k in stations.size():
		if not stations[k].is_station():
			continue
		var d := (sys.orbital_xform(k, t).origin - x).length()
		if d < MATCH_STATION:
			var v := _frame_velocity(stations[k], x)
			if s.ref == null:
				return [v, d]
			var i := index_of(s.ref)
			return [sys.spin(i, t).inverse() * (v - _frame_velocity(s.ref, x)), d]
	return [Vector3.ZERO, -1.0]


## Ship `s` in the space frame, were it at `at` in its reference frame.
func ship_xform_at(s: SpaceShip, at: Vector3) -> Transform3D:
	var l := Transform3D(s.rel.basis, at)
	return l if s.ref == null else sys.xform(index_of(s.ref), t) * l


## Each ship's reference: a planet's frame inside its shell, the star's out of
## every shell; its place and velocity carried over unchanged in space.
func _ship_refs() -> void:
	for s in ships:
		var x := s.space_xform(self)
		var nb := s.ref
		if s.ref == null:
			for b in bodies:
				if (x.origin - sys.pos(index_of(b), t)).length() < b.data.radius * SHELL:
					nb = b
					break
		elif (x.origin - sys.pos(index_of(s.ref), t)).length() > s.ref.data.radius * SHELL * SHELL_OUT:
			nb = null
		if nb == s.ref:
			continue
		var v := s.frame_velocity(self, x.origin)
		var bx := sys.xform(index_of(nb), t) if nb != null else Transform3D()
		s.rel = bx.affine_inverse() * x
		s.vel = bx.basis.inverse() * (v - (_frame_velocity(nb, x.origin) if nb != null else Vector3.ZERO))
		print("[system] %s: from %s's frame into %s's at %.0f m/s" % [s.data.orbital_name, name_of(s.ref), name_of(nb), s.vel.length()])
		s.ref = nb
		s.landed = false


## A ship's bricks while it is the frame, or sits landed on the planet the
## player is on with the player near and nobody at its controls.
func _ship_bricks(p: Vector3) -> void:
	for s in ships:
		var want := s == ship or (s.ref != null and s.ref == anchor and s.landed and not s.piloted
				and (p - s.global_position).length() < s.field)
		if want and s.chunk < 0:
			s.process_mode = Node.PROCESS_MODE_INHERIT
			s.activate()
		elif not want and s.chunk >= 0 and s != frame_node():
			s.deactivate()


## The scene's top-level 3D nodes but the system's own, the bodies and the sun.
func _top_level() -> Array[Node3D]:
	var out: Array[Node3D] = []
	for c in get_parent().get_children():
		if c is Node3D and c != self and not c is PlanetBody and c != sun:
			out.append(c)
	return out


## Move what is not asleep by the rigid `m`, velocities turned with it.
func _travel(m: Transform3D) -> void:
	for n in _top_level():
		n.global_transform = m * n.global_transform
		if n is CharacterBody3D:
			(n as CharacterBody3D).velocity = m.basis * (n as CharacterBody3D).velocity
		elif n is RigidBody3D:
			(n as RigidBody3D).linear_velocity = m.basis * (n as RigidBody3D).linear_velocity
			(n as RigidBody3D).angular_velocity = m.basis * (n as RigidBody3D).angular_velocity
		if "inertia" in n:
			n.set(&"inertia", m.basis * (n.get(&"inertia") as Vector3))
		n.reset_physics_interpolation()


func _sleep(f: Node3D) -> void:
	var list: Array = []
	for n in _top_level():
		if n.is_in_group(RIG):
			continue
		list.append([n, n.process_mode])
	for e in list:
		var n: Node3D = e[0]
		n.process_mode = Node.PROCESS_MODE_DISABLED
		n.reparent(f, true)
	_sleepers[f] = list
	_left_at[f] = f.global_position
	f.call(&"deactivate")
	f.process_mode = Node.PROCESS_MODE_DISABLED
	print("[system] %s sleeps with %d thing(s) on it" % [name_of(f), list.size()])


func _wake(f: Node3D) -> void:
	f.process_mode = Node.PROCESS_MODE_INHERIT
	for e in _sleepers.get(f, []):
		var n: Node3D = e[0]
		if is_instance_valid(n):
			n.reparent(get_parent(), true)
			n.process_mode = e[1]
			n.reset_physics_interpolation()
	_sleepers.erase(f)
	WorldFrame.origin = -f.global_position
	if f is PlanetBody:
		_full_bake(f)
		if not (f as PlanetBody).data.towns.is_empty() and not built.has(f):
			_populate(f)
		if (f as PlanetBody).data.has_air and index_of(f) != sys.home and not trees_of.has(f):
			var tr := PlanetTrees.new()
			f.add_child(tr)
			tr.setup((f as PlanetBody).data)
			tr.prebake()
			trees_of[f] = tr
	f.call(&"activate")
	var offset: Vector3 = f.global_position - _left_at.get(f, f.global_position)
	_left_at.erase(f)
	if index_of(f as PlanetBody) != sys.home and built.has(f):
		(built[f] as PlanetBuildings).on_origin_shift()
	woke.emit(f, offset)


# --- the light -----------------------------------------------------------------

## Aim the sun from the star at the camera; how much of the star's disc the
## bodies leave it.
func _light(e: Vector3) -> void:
	var to_s := star.global_position - e
	var ds := to_s.length()
	var sd := to_s / ds
	var a_s := asin(clampf(sys.star_radius / ds, 0.0, 1.0))
	var seen := 1.0
	for b in bodies:
		var to_b := b.global_position - e
		var db := to_b.length()
		if db > ds:
			continue
		var a_b := asin(clampf(b.data.radius / db, 0.0, 1.0))
		var theta := acos(clampf(to_b.dot(sd) / db, -1.0, 1.0))
		seen = minf(seen, clampf((theta - (a_b - a_s)) / (2.0 * a_s), 0.0, 1.0))
	sunlight = seen
	var near := nearest(e)
	sun_height = (e - near.global_position).normalized().dot(sd) if near != null else 1.0
	if sun == null:
		return
	if _sun_dir == Vector3.ZERO or _sun_dir.angle_to(-sd) > SUN_STEP:
		_sun_dir = -sd
		var up := Vector3.UP if absf(sd.y) < 0.99 else Vector3.FORWARD
		sun.global_basis = Basis.looking_at(_sun_dir, up)
	sun.light_energy = sun_energy * seen
	sun.visible = seen > 0.0


## Each body's look, and the star's, where the camera at `e` can draw it.
func _scaled_space(e: Vector3) -> void:
	for b in bodies:
		var near := _draw_at(b.look, b.global_transform, e)
		if b.ocean != null:
			b.ocean.visible = near or b == anchor
	for st in stations:
		_draw_at(st.look, st.global_transform, e)
	for s in ships:
		_draw_at(s.look, s.global_transform, e)
	_draw_at(star_look, star.global_transform, e)


## `look` drawn as `true_xform` would be from `e`: there if near, else nearer
## and smaller on the same line. True when near.
static func _draw_at(look: Node3D, true_xform: Transform3D, e: Vector3) -> bool:
	var to := true_xform.origin - e
	var d := to.length()
	if d <= FAR_VIEW:
		look.transform = Transform3D()
		return true
	var shown := FAR_VIEW * (1.0 + 0.1 * log(d / FAR_VIEW))
	var k := shown / d
	look.global_transform = Transform3D(true_xform.basis.scaled(Vector3(k, k, k)), e + to * k)
	return false


# --- the star ----------------------------------------------------------------------

func _build_star() -> void:
	star = Node3D.new()
	star.name = "Star"
	add_child(star)
	star_look = MeshInstance3D.new()
	star_look.name = "Look"
	var sm := SphereMesh.new()
	sm.radius = sys.star_radius
	sm.height = sys.star_radius * 2.0
	sm.radial_segments = 48
	sm.rings = 24
	star_look.mesh = sm
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = sys.star_color
	star_look.material_override = mat
	star_look.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	star.add_child(star_look)


# --- impostor bakes on a worker ------------------------------------------------------

## One bake at a time: the full set for a body near the player first, then the
## small set for every body without one, then the full set for the rest; the
## nearest first each time.
func _bake_service() -> void:
	if _bake_task >= 0:
		if not WorkerThreadPool.is_task_completed(_bake_task):
			return
		WorkerThreadPool.wait_for_task_completion(_bake_task)
		_bake_task = -1
		if is_instance_valid(_bake_body):
			_bake_body.apply_bake(PlanetImpostorBake.textured(_bake_result))
		_bake_result = {}
	var e: Vector3 = eye.call() if eye.is_valid() else Vector3.ZERO
	var pick: PlanetBody = null
	var size := BAKE_FULL
	var best := INF
	for b in bodies:
		var d := (b.global_position - e).length()
		if b.baked_width < BAKE_FULL.x and d < b.data.radius * SHELL * 4.0 and d < best:
			best = d
			pick = b
	if pick == null:
		size = BAKE_SMALL
		for b in bodies:
			var d := (b.global_position - e).length()
			if b.baked_width == 0 and d < best:
				best = d
				pick = b
	if pick == null:
		size = BAKE_FULL
		for b in bodies:
			var d := (b.global_position - e).length()
			if b.baked_width < BAKE_FULL.x and d < best:
				best = d
				pick = b
	if pick == null:
		return
	_bake_body = pick
	_bake_data = pick.data.duplicate()
	_bake_size = size
	_bake_task = WorkerThreadPool.add_task(_bake_run, false, "impostor bake")


func _bake_run() -> void:
	_bake_result = PlanetImpostorBake.bake(_bake_data, _bake_size.x, _bake_size.y, false)


## `b`'s full maps now, before its ground needs them (a worker's, waited for,
## or baked here: a hitch, only if the player outran the bakes).
func _full_bake(b: PlanetBody) -> void:
	if b.baked_width >= BAKE_FULL.x:
		return
	if _bake_task >= 0 and _bake_body == b and _bake_size == BAKE_FULL:
		WorkerThreadPool.wait_for_task_completion(_bake_task)
		_bake_task = -1
		b.apply_bake(PlanetImpostorBake.textured(_bake_result))
		_bake_result = {}
		return
	var t0 := Time.get_ticks_msec()
	b.apply_bake(PlanetImpostorBake.bake(b.data, BAKE_FULL.x, BAKE_FULL.y))
	print("[system] %s baked on arrival: %d ms" % [b.data.planet_name, Time.get_ticks_msec() - t0])


func _exit_tree() -> void:
	if _bake_task >= 0:
		WorkerThreadPool.wait_for_task_completion(_bake_task)
		_bake_task = -1
