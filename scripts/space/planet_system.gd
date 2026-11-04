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
## owns the light (`rig`, Docs/Lighting.md); this aims its sun from the star and
## says how much of the star's disc the camera sees (`sunlight`: night, a
## planet's shadow, an eclipse), how high it stands there (`sun_height`), its
## size and brightness by distance, the fill from the brightest body in the
## sky, and each body's shadows from the others.

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
const SEE_FAR := 400000.0
## Pieces drifting (step 6): at most this many, gone past `drift_reach` of the
## player; a tumble and a push at random up to these.
const DRIFT_CAP := 64
## The most places a ship's step is looked at for rocks, a frame.
const ROCK_STEPS := 12
const DRIFT_PUSH := 3.0
const DRIFT_SPIN := 0.4
## A piece with someone aboard leaves at this share of the push, turning a tenth of that.
const DRIFT_RIDDEN := 0.25
## Within FALL_AT of a planet's ground a piece is falling to it: near the player
## (DRIFT_CATCH) a body under it that lands, else gone in DRIFT_DIE seconds.
const FALL_AT := 2000.0
const DRIFT_CATCH := 1500.0
const DRIFT_DIE := 1.0
## Fallen pieces lying about at most; still this long, a fallen one is frozen.
const FALLEN_CAP := 32
const FALLEN_STILL := 1.0
## In air a fallen piece slows (1/s): one come in at a station's 70-150 m/s
## lands within a few hundred metres instead of skating away.
const FALLEN_DRAG := 0.5
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
## World `b`'s buildings are made.
signal populated(b: PlanetBody)

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
## Each a Drift: no body, no physics, a place worked out from its age.
var drifts: Array = []
var drift_reach := 5000.0
## Pieces fallen to a planet: bodies under it (_fall).
var fallen: Array[RigidBody3D] = []
## Times a fallen piece was put back on the ground (_over_ground).
var under_ground_saves := 0
## ... and past this from where it left, so a wreck's pieces wait round it.
var drift_home := 3000.0
## A piece is its full size inside `drift_seen` of the player, nothing at
## `drift_hidden`: out and back by size, its material being opaque.
var drift_seen := 2500.0
var drift_hidden := 5000.0
var _drift_clock := 0.0
## Where the star truly is (its node); `star_look` draws it.
var star: Node3D
var star_look: MeshInstance3D
## This system's belt, or null, and its far disc.
var belt: RockField
var _belt_disc: MeshInstance3D
var rig: LightRig
## The star's light at home (luminosity / distance^2), for the sun's brightness.
var _flux_home := 0.0
## The most bodies whose shadows a body's far look takes.
const SHADOWERS := 4
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
	var hd: PlanetData = _home_sys.bodies[_home_sys.home] if _home_sys.home >= 0 else null
	var hr: float = hd.orbit_radius if hd != null and hd.orbit_radius > 0.0 else StarSystem.HABITABLE
	_flux_home = _home_sys.luminosity / (hr * hr)
	_place()


## The bodies, stations and satellites of `sys`.
func _build_bodies() -> void:
	for i in sys.bodies.size():
		if i == sys.home and _home_body != null:
			bodies.append(_home_body)
			_home_body.visible = true
			continue
		var b := PlanetBody.new()
		b.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		add_child(b)
		b.setup(sys.bodies[i], true)
		b.process_mode = Node.PROCESS_MODE_DISABLED
		b.far_only()
		bodies.append(b)
	for k in sys.orbitals.size():
		var st := SpaceStation.new()
		st.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		add_child(st)
		st.setup(sys.orbitals[k])
		st.drifted.connect(_on_drifted.bind(st))
		st.process_mode = Node.PROCESS_MODE_DISABLED
		stations.append(st)
		# Home's stations' bricks while the scene loads.
		if sys.orbitals[k].parent == sys.home and _home_body != null:
			st.prepare()


## At the ship's controls in open space: its jump drive works.
func can_jump() -> bool:
	return ship != null and ship.ref == null


## Why no jump can be made from here, for the player ("": one can).
func jump_block() -> String:
	if can_jump():
		return ""
	if anchor != null:
		var left := anchor.data.radius * SHELL * SHELL_OUT - (observer.call() - anchor.global_position).length() as float
		return "In %s's gravity: open space %.0f km further out" % [anchor.data.planet_name, maxf(left, 0.0) / 1000.0]
	if station != null:
		return "Too near %s" % station.data.orbital_name
	return "Aboard the ship only"


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
	for f in drifts:
		_drop_body(f)
		(f as Drift).node.queue_free()
	drifts.clear()
	bodies.clear()
	stations.clear()
	trees_of.clear()
	system_index = index
	sys = _home_sys if index == 0 else universe.system(index)
	_build_bodies()
	(star_look.mesh as SphereMesh).radius = sys.star_radius
	(star_look.mesh as SphereMesh).height = sys.star_radius * 2.0
	(star_look.material_override as StandardMaterial3D).albedo_color = sys.star_color
	_build_belt()
	var at := 0
	for i in sys.bodies.size():
		if sys.bodies[i].parent < 0 and (not sys.bodies[i].towns.is_empty() or i == sys.home):
			at = i
			break
	var p := sys.pos(at, t)
	var off := sys.bodies[at].radius * SHELL * 1.3 + 30000.0
	ship.rel = Transform3D(ship.rel.basis, p * (1.0 - off / p.length()))
	ship.vel = sys.vel(at, t)
	ship.fine = Vector3.ZERO
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
	s.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	add_child(s)
	s.setup_ship(d)
	s.drifted.connect(_on_drifted.bind(s))
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
	if frame_node() != null or in_belt(x):
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
## How high a world's air reaches, as a share of its radius (its sky's shell is at
## 1.08): full to AIR_FULL, thinning to none at AIR_TOP.
const AIR_FULL := 0.04
const AIR_TOP := 0.08


## Each ship's and station's outside pressure (Docs/Hulls.md 4): a world's air
## where it is in it -- parked, its airlock open lets nothing out -- else space's none.
func _outside_air() -> void:
	for st in stations:
		if st.air == null:
			continue
		var b := nearest(st.global_position)
		var p := 0.0
		if b != null and b.data.has_air:
			var h := b.altitude_of(st.global_position) / maxf(b.data.radius, 1.0)
			p = clampf((AIR_TOP - h) / (AIR_TOP - AIR_FULL), 0.0, 1.0)
		st.outside_pressure = p


## The air at world point `p` inside a ship or station (SpaceStation.air_at): {pressure,
## pull, breached}, or empty when `p` is in none.
func air_at(p: Vector3, near := false) -> Dictionary:
	for st in stations:
		var a := st.air_at(p, near)
		if not a.is_empty():
			return a
	return {}


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
	_outside_air()
	for s in ships:
		s.fly(self, delta)
	_ship_refs()
	_drift_clock += delta
	# Where everything is this frame before asking which frame the player is in.
	_place()
	if observer.is_valid():
		_choose_anchor(observer.call())
		_prepare_near(observer.call())
		_ship_bricks(observer.call())
		_populate_near(observer.call())
		_drift_keep(observer.call())
		_rocks(observer.call(), delta)
	_place()
	_gravity()
	if eye.is_valid():
		_light(eye.call())
		_scaled_space(eye.call())
		_far_tiers(eye.call())
	_bake_service()


## A piece that left `from`: a record in its frame -- a station's, which it
## goes on orbiting with; for a ship, the star's frame where it left, at the
## ship's velocity -- with a push from `from`'s middle and a tumble.
func _on_drifted(arrays: Array, com: Transform3D, local_com: Vector3, count: int, material: Material, from: SpaceStation) -> void:
	var s2w := space_to_world()
	var e := Drift.new()
	e.bricks = count
	e.born = _drift_clock
	var carried := Vector3.ZERO
	if from is SpaceShip:
		e.base = s2w.affine_inverse() * from.global_transform
		carried = e.base.basis.inverse() * (from as SpaceShip).frame_velocity(self, e.base.origin)
	else:
		e.frame = from
		e.base = _frame_xform(from)
	var to_base := (s2w * e.base).affine_inverse()
	var here := to_base * com
	e.p0 = here.origin
	e.q0 = here.basis
	var away := here.origin
	away = away.normalized() if away.length_squared() > 0.01 else Vector3.UP
	e.v = carried + (away + Vector3(randf_range(-0.5, 0.5), randf_range(-0.5, 0.5), randf_range(-0.5, 0.5))) * randf_range(1.0, DRIFT_PUSH)
	e.axis = Vector3(randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1)).normalized()
	e.rate = randf_range(0.05, DRIFT_SPIN)
	if from != null and from.drift_body.is_valid():
		# Someone aboard: its bricks to stand on, and it leaves gently, barely turning.
		e.body = from.drift_body
		from.drift_body = RID()
		e.riders = from.drift_riders.duplicate()
		e.v = carried + (e.v - carried) * DRIFT_RIDDEN
		e.rate *= DRIFT_RIDDEN * 0.1
		PhysicsServer3D.body_set_state(e.body, PhysicsServer3D.BODY_STATE_TRANSFORM, com)
		PhysicsServer3D.body_set_space(e.body, get_world_3d().space)
	if from != null:
		e.record = from.drift_record
		e.source = from
	e.material = material
	e.draw_at = -local_com
	_drift_node(e, arrays, com)
	if e.body.is_valid() and from.gravity_centre != null:
		e.grav = Node3D.new()
		e.grav.name = "Down"
		e.node.add_child(e.grav)
		e.grav.position = com.affine_inverse() * from.gravity_centre.global_position
		e.pull = from.data.gravity
	print("[system] %d bricks of %s drift off%s" % [count, name_of(from),
			"" if e.riders.is_empty() else ", %d aboard" % e.riders.size()])


## Piece `e`'s node at `at` (world), and its mesh made from `arrays` on a
## worker, as a band's: on the main thread it is 10-25 ms.
func _drift_node(e: Drift, arrays: Array, at: Transform3D) -> void:
	e.node = Node3D.new()
	e.node.name = "Drift"
	e.node.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	add_child(e.node)
	e.node.global_transform = at
	var holder := [null]
	e.task = WorkerThreadPool.add_task(func() -> void:
			if arrays.is_empty():
				return
			var m := ArrayMesh.new()
			m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, IslandManager.UPLOAD_COMPRESS)
			holder[0] = m, false, "drift piece")
	e.holder = holder
	drifts.append(e)


## Meshes in, pieces out of reach gone, the oldest over the cap.
func _drift_keep(p: Vector3) -> void:
	var k := drifts.size() - 1
	while k >= 0:
		var e: Drift = drifts[k]
		if e.task >= 0 and WorkerThreadPool.is_task_completed(e.task):
			WorkerThreadPool.wait_for_task_completion(e.task)
			e.task = -1
			var mesh: ArrayMesh = e.holder[0]
			if mesh != null:
				var mi := MeshInstance3D.new()
				mi.mesh = mesh
				mi.material_override = e.material
				mi.position = e.draw_at
				e.node.add_child(mi)
				e.look = mi
		if e.task >= 0:
			k -= 1
			continue
		var at := e.node.global_position
		var off := (at - p).length()
		var ridden := _ridden(e)
		var over := _falling_to(at)
		if over != null and e.dying < 0.0:
			# Ridden, it falls just the same (they stand on its box); it never fades.
			if over == anchor and off < DRIFT_CATCH and e.look != null:
				_fall(e, over)
				drifts.remove_at(k)
				k -= 1
				continue
			if not ridden:
				e.dying = _drift_clock
		var dead := e.dying >= 0.0 and _drift_clock - e.dying >= DRIFT_DIE
		if e.look != null:
			var size := 1.0 - smoothstep(drift_seen, drift_hidden, off)
			if e.dying >= 0.0:
				size *= 1.0 - clampf((_drift_clock - e.dying) / DRIFT_DIE, 0.0, 1.0)
			e.look.visible = size > 0.0
			if size > 0.0 and size != e.look.scale.x:
				e.look.scale = Vector3.ONE * size
				e.look.position = e.draw_at * size
		var left := (e.v * (_drift_clock - e.born)).length()
		if not ridden and (dead or off > drift_reach and left > drift_home or drifts.size() > DRIFT_CAP and k == 0):
			_drop_body(e)
			e.node.queue_free()
			drifts.remove_at(k)
		k -= 1
	_fallen_step(p)


## Is anyone still on piece `e`: a rider it left with, near it (within its
## mesh's box and a couple of metres)?
func _ridden(e: Drift) -> bool:
	if not e.body.is_valid():
		return false
	var k := e.riders.size() - 1
	while k >= 0:
		if not is_instance_valid(e.riders[k]):
			e.riders.remove_at(k)
		k -= 1
	if e.look == null:
		return not e.riders.is_empty()
	for r: Node3D in e.riders:
		if _on_piece(e, r.global_position):
			return true
	return false


## Is world point `p` on piece `e`: in its mesh's box and a couple of metres
## (before its mesh is in, within a few metres of its middle)?
func _on_piece(e: Drift, p: Vector3) -> bool:
	if e.look == null:
		return e.node.global_position.distance_to(p) < 6.0
	var box := e.look.mesh.get_aabb()
	box.position += e.draw_at
	return box.grow(2.0).has_point(e.node.global_transform.affine_inverse() * p)


func _drop_body(e: Drift) -> void:
	if e.body.is_valid():
		PhysicsServer3D.free_rid(e.body)
	e.body = RID()


## Its colliders not in yet (it outran them), a fallen piece under the ground
## is put back on it, its fall stopped (PlanetScene.keep_over_ground).
func _over_ground(body: RigidBody3D) -> void:
	var b := body.get_parent() as PlanetBody
	var dir := b.dir_of(body.global_position)
	if b.altitude_of(body.global_position) < b.data.height(dir) - 1.0:
		var at := b.global_transform * b.data.surface_point(dir)
		var up := Gravity.up_at(at)
		body.global_position = at + up * 1.0
		var v := body.linear_velocity
		body.linear_velocity = v - up * minf(v.dot(up), 0.0)
		under_ground_saves += 1


## Piece `e`'s velocity over the anchored ground, world axes: from its record
## and its frame's motion, so a piece caught the frame it is made has it too.
func _drift_velocity(e: Drift) -> Vector3:
	var s2w := space_to_world()
	var x := s2w.affine_inverse() * e.node.global_position
	var base: Transform3D = e.base if e.frame == null else _frame_xform(e.frame)
	var v := base.basis * e.v
	if e.frame != null:
		v += _frame_velocity(e.frame, x)
	return s2w.basis * (v - _frame_velocity(anchor, x))


## The body whose ground a world point is within FALL_AT of, or null.
func _falling_to(at: Vector3) -> PlanetBody:
	for b in bodies:
		if (at - b.global_position).length() - b.data.radius < FALL_AT:
			return b
	return null


## Piece `e` falling to the player's world, near them: a body under it, its
## mesh and a box round it, at the speed it had.
func _fall(e: Drift, b: PlanetBody) -> void:
	var now := e.node.global_transform
	var body := _fallen_body(b, now, e.bricks)
	# Ground colliders round it while it falls: past a few hundred metres of the
	# player there are none, and it would fall through.
	PlanetBody.track(body)
	e.look.reparent(body, false)
	e.look.scale = Vector3.ONE
	e.look.position = e.draw_at
	e.look.visible = true
	_fallen_box(body, e.look, e.draw_at)
	body.linear_velocity = _drift_velocity(e)
	var turn := now.basis * e.at(_drift_clock).basis.inverse()
	body.angular_velocity = turn * e.axis * e.rate
	body.set_meta(&"record", e.record)
	body.set_meta(&"from", _source_of(e.source))
	body.set_meta(&"draw_at", e.draw_at)
	_drop_body(e)
	e.node.queue_free()
	print("[system] %d bricks fall to %s at %.0f m/s" % [e.bricks, b.data.planet_name, body.linear_velocity.length()])


## A fallen piece's body under `b` at `at` (world), counted in `fallen`, the
## oldest going over FALLEN_CAP. Its look and box are the caller's.
func _fallen_body(b: PlanetBody, at: Transform3D, count: int) -> RigidBody3D:
	var body := RigidBody3D.new()
	body.name = "Fallen"
	body.mass = maxf(float(count), 1.0)
	body.gravity_scale = 0.0
	body.collision_layer = Layers.FALLING
	body.collision_mask = Layers.FALLING_MASK
	body.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	# Metres a physics step at those speeds: a plain body goes through the ground.
	body.continuous_cd = true
	if b.data.has_air:
		body.linear_damp = FALLEN_DRAG
		body.angular_damp = FALLEN_DRAG
	body.set_meta(&"still", 0.0)
	body.set_meta(&"bricks", count)
	b.add_child(body)
	body.global_transform = at
	fallen.append(body)
	while fallen.size() > FALLEN_CAP:
		if is_instance_valid(fallen[0]):
			fallen[0].queue_free()
		fallen.remove_at(0)
	return body


## A box round `look` (drawn at `draw_at`) for `body` to land on.
func _fallen_box(body: RigidBody3D, look: MeshInstance3D, draw_at: Vector3) -> void:
	var box := look.mesh.get_aabb()
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = box.size.max(Vector3.ONE * 0.2)
	cs.shape = shape
	cs.position = draw_at + box.get_center()
	body.add_child(cs)


# --- saved (Docs/Planets.md, "Plan, rubble in saves") ---------------------------

## Who made a piece, as a save names it: a station by its index, a ship as
## -2 - its index; -1 nobody known.
func _source_of(n: Node3D) -> int:
	if n is SpaceShip:
		var j := ships.find(n)
		return -2 - j if j >= 0 else -1
	if n is SpaceStation:
		return stations.find(n)
	return -1


func _source_node(i: int) -> SpaceStation:
	if i >= 0 and i < stations.size():
		return stations[i]
	if i <= -2 and -2 - i < ships.size():
		return ships[-2 - i]
	return null


## A saved piece's mesh again: its bricks laid in its maker's world (whose
## parts they name), meshed, and let go. [] if that cannot be.
func _record_arrays(rec: Dictionary, src: SpaceStation) -> Array:
	if src == null or rec.is_empty():
		return []
	if src.bricks == null:
		src.prepare()
	if src.bricks == null:
		return []
	var r := ChunkRecord.from_data(src.bricks, rec)
	if r == null:
		return []
	var c := r.restore(src.bricks)
	if c < 0:
		return []
	var arrays: Array = src.bricks.build_chunk_mesh(c)
	src.bricks.release_chunk(c)
	return arrays


## What a save keeps of the pieces adrift in this system: each one's bricks, its
## maker, its record of motion and its age. Not riders, nor one going.
func drifts_to_save() -> Array:
	var out := []
	for e: Drift in drifts:
		if e.record.is_empty() or e.dying >= 0.0:
			continue
		out.append({"record": e.record, "from": _source_of(e.source),
				"frame": stations.find(e.frame) if e.frame != null else -1, "base": e.base,
				"p0": e.p0, "q0": e.q0, "v": e.v, "axis": e.axis, "rate": e.rate,
				"age": _drift_clock - e.born, "bricks": e.bricks, "draw_at": e.draw_at})
	return out


## Back from drifts_to_save, each on its way where its age has it now.
func restore_drifts(saved: Array) -> void:
	for d: Dictionary in saved:
		var src := _source_node(int(d.from))
		var arrays := _record_arrays(d.record, src)
		if arrays.is_empty():
			continue
		var e := Drift.new()
		e.record = d.record
		e.source = src
		e.material = src.brick_material
		var k := int(d.frame)
		e.frame = stations[k] if k >= 0 and k < stations.size() else null
		e.base = d.base
		e.p0 = d.p0
		e.q0 = d.q0
		e.v = d.v
		e.axis = d.axis
		e.rate = float(d.rate)
		e.born = _drift_clock - float(d.age)
		e.bricks = int(d.bricks)
		e.draw_at = d.draw_at
		var base: Transform3D = e.base if e.frame == null else _frame_xform(e.frame)
		_drift_node(e, arrays, space_to_world() * base * e.at(_drift_clock))


## What a save keeps of the pieces fallen on `b` from space: the still ones,
## their bricks and where they lie on it.
func fallen_to_save(b: PlanetBody) -> Array:
	var out := []
	var inv := b.global_transform.affine_inverse()
	for body in fallen:
		if is_instance_valid(body) and body.freeze and body.get_parent() == b and body.has_meta(&"record") \
				and not (body.get_meta(&"record") as Dictionary).is_empty():
			out.append({"record": body.get_meta(&"record"), "from": int(body.get_meta(&"from")),
					"at": inv * body.global_transform, "draw_at": body.get_meta(&"draw_at"),
					"bricks": int(body.get_meta(&"bricks"))})
	return out


## Back from fallen_to_save: each lying still where it lay.
func restore_fallen(b: PlanetBody, saved: Array) -> void:
	for d: Dictionary in saved:
		var src := _source_node(int(d.from))
		var arrays := _record_arrays(d.record, src)
		if arrays.is_empty():
			continue
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, IslandManager.UPLOAD_COMPRESS)
		var look := MeshInstance3D.new()
		look.mesh = mesh
		look.material_override = src.brick_material
		look.position = d.draw_at
		var body := _fallen_body(b, b.global_transform * (d.at as Transform3D), int(d.bricks))
		body.add_child(look)
		_fallen_box(body, look, d.draw_at)
		body.set_meta(&"record", d.record)
		body.set_meta(&"from", int(d.from))
		body.set_meta(&"draw_at", d.draw_at)
		body.freeze = true


## The fallen: pulled down as PlanetPieces pulls its own, frozen once still, gone
## if left behind while falling (the ground far off is coarse).
func _fallen_step(p: Vector3) -> void:
	var dt := get_process_delta_time()
	var k := fallen.size() - 1
	while k >= 0:
		var body := fallen[k]
		if not is_instance_valid(body):
			fallen.remove_at(k)
		elif not body.freeze and body.can_process():
			if (body.global_position - p).length() > DRIFT_CATCH * 2.0:
				body.queue_free()
				fallen.remove_at(k)
			else:
				body.constant_force = Gravity.down_at(body.global_position) * Gravity.strength() * PlanetPieces.GRAVITY_SCALE * body.mass
				_over_ground(body)
				var still := float(body.get_meta(&"still"))
				still = still + dt if body.linear_velocity.length() < 0.3 and body.angular_velocity.length() < 0.3 else 0.0
				body.set_meta(&"still", still)
				if still >= FALLEN_STILL:
					body.constant_force = Vector3.ZERO
					body.freeze = true
					var gv := body.get_node_or_null(^"GroundViewer")
					if gv != null:
						gv.queue_free()
		k -= 1


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
	populated.emit(b)
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
		if st.is_station() and st._template >= 0 and (st.global_position - p).length() < PREPARE_AT:
			st.lay_wreck()


## Every frame but the player's, and the star, where the clock has them.
func _place() -> void:
	var s2w := space_to_world()
	var f := frame_node()
	star.global_transform = s2w
	# On a station's frame its planet comes off the station, not through the star's
	# frame: a ship flying there is placed off the planet, and would shake by 0.5 m.
	var held := -1
	var held_at := Vector3.ZERO
	if f is SpaceStation and not f is SpaceShip:
		var at := stations.find(f)
		held = sys.orbitals[at].parent
		held_at = f.global_position - s2w.basis * sys.orbital_local(at, t).origin
	for i in bodies.size():
		if i == held:
			bodies[i].global_transform = Transform3D(s2w.basis * sys.spin(i, t), held_at)
		elif bodies[i] != f:
			bodies[i].global_transform = s2w * sys.xform(i, t)
	for k in stations.size():
		if stations[k] != f:
			var l := sys.orbital_local(k, t)
			stations[k].global_transform = Transform3D(s2w.basis * l.basis,
					bodies[sys.orbitals[k].parent].global_position + s2w.basis * l.origin)
	for s in ships:
		if s != f:
			s.global_transform = ship_world(s, s.rel.origin)
	for d in drifts:
		var e: Drift = d
		var base: Transform3D = e.base if e.frame == null else _frame_xform(e.frame)
		e.node.global_transform = s2w * base * e.at(_drift_clock)
		if e.body.is_valid():
			# Moved where it is drawn, its velocity its own (not the frame's step
			# or an origin shift): what carries a figure standing on it.
			var turn := (s2w * base).basis
			PhysicsServer3D.body_set_state(e.body, PhysicsServer3D.BODY_STATE_TRANSFORM, e.node.global_transform)
			PhysicsServer3D.body_set_state(e.body, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, turn * e.v)
			PhysicsServer3D.body_set_state(e.body, PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY, turn * e.axis * e.rate)
	for b in bodies:
		b.set_sun(b.global_basis.inverse() * (star.global_position - b.global_position).normalized())
		_shadows_on(b)
	_belt_near(s2w)


## Body `b`'s far look takes the shadows of the bodies between it and the star
## (Lighting.md 2a): each as a sphere in its own frame, in its radii.
func _shadows_on(b: PlanetBody) -> void:
	var to_s := star.global_position - b.global_position
	var ds := to_s.length()
	var sd := to_s / ds
	var inv := b.global_basis.orthonormalized().inverse()
	var r := b.data.radius
	var found: Array = []
	for o in bodies:
		if o == b:
			continue
		var to_o := o.global_position - b.global_position
		var along := to_o.dot(sd)
		if along <= 0.0 or along > ds:
			continue
		# How near the sun's line it passes, against how big it and its
		# penumbra are there: past both it shadows nothing on b.
		var miss := (to_o - sd * along).length()
		var reach := o.data.radius + r + along * sys.star_radius / ds
		if miss > reach:
			continue
		found.append([miss / reach, Vector4(0, 0, 0, 0)])
		var l := inv * to_o / r
		found[-1][1] = Vector4(l.x, l.y, l.z, o.data.radius / r)
	found.sort_custom(func(x, y): return x[0] < y[0])
	var list := PackedVector4Array()
	for k in mini(found.size(), SHADOWERS):
		list.append(found[k][1])
	b.set_shadowers(list, asin(clampf(sys.star_radius / ds, 0.0, 1.0)), rig.star_colour if rig != null else sys.star_color)


func _gravity() -> void:
	# On a piece adrift that someone rode off on: its own down, turning with it.
	if observer.is_valid() and not drifts.is_empty():
		var p: Vector3 = observer.call()
		for e: Drift in drifts:
			if e.grav != null and e.body.is_valid() and _on_piece(e, p):
				Gravity.planet = e.grav
				Gravity.planet_strength = e.pull
				Gravity.planet_radius = SpaceStation.DEPTH
				return
	var on := frame_node()
	if on is SpaceStation:
		Gravity.planet = (on as SpaceStation).gravity_centre
		Gravity.planet_strength = (on as SpaceStation).data.gravity
		Gravity.planet_radius = SpaceStation.DEPTH
		return
	var g := anchor
	# Past every shell nothing pulls: the nearest body only says which way is down.
	var pull := 1.0
	if g == null and observer.is_valid():
		g = nearest(observer.call())
		pull = 0.0
	if g == null:
		return
	Gravity.planet = g
	Gravity.planet_strength = g.data.gravity_strength * pull
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
		star.global_transform = s2w
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


## Ship `s` in the world, were it at `at` in its reference frame: in a planet's
## frame straight off the planet (through the star's it is rounded to 0.125 m,
## which on a 1 m step a frame is a shake you can see).
func ship_world(s: SpaceShip, at: Vector3) -> Transform3D:
	var l := Transform3D(s.rel.basis, at)
	return s.ref.global_transform * l if s.ref != null else space_to_world() * l


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
		s.fine = Vector3.ZERO
		print("[system] %s: from %s's frame into %s's at %.0f m/s" % [s.data.orbital_name, name_of(s.ref), name_of(nb), s.vel.length()])
		s.ref = nb
		s.landed = false


## A ship's bricks while it is the frame, or over the planet the player is on
## with the player near and nobody at its controls.
func _ship_bricks(p: Vector3) -> void:
	for s in ships:
		var want := s == ship or (s.ref != null and s.ref == anchor and not s.piloted
				and (p - s.global_position).length() < s.field)
		# A generated ship flown over the planet keeps its bricks drawn (riding).
		var ride := s.recipe != null and s.piloted and s.ref != null and s != ship
		if want and s.chunk < 0:
			s.process_mode = Node.PROCESS_MODE_INHERIT
			s.activate()
		elif want and s.riding:
			s.unride()
		elif ride and s.chunk >= 0:
			s.ride()
		elif not want and s.chunk >= 0 and s != frame_node():
			s.deactivate()
		s.gangway_step()


## The scene's top-level 3D nodes but the system's own, the bodies and the light.
func _top_level() -> Array[Node3D]:
	var out: Array[Node3D] = []
	for c in get_parent().get_children():
		if c is Node3D and c != self and not c is PlanetBody and c != rig:
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
## bodies leave it; its size and brightness from where the camera is
## (Lighting.md 2); the fill from the brightest body in the sky (5).
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
	if rig == null:
		return
	rig.star_colour = sys.star_color
	var flux := sys.luminosity / (ds * ds)
	rig.set_sun(sd, seen, a_s, flux / _flux_home if _flux_home > 0.0 else 1.0, SUN_STEP)
	_fill(e, sd, near, seen)


## The brightest body in the sky by the light it sends back: albedo x its solid
## angle / pi x how much of the face toward the camera is lit; under the near
## body's horizon it sends none.
func _fill(e: Vector3, sd: Vector3, near: PlanetBody, seen: float) -> void:
	var best: PlanetBody = null
	var best_score := 0.0
	var best_dir := Vector3.ZERO
	var best_ang := 0.0
	var best_over := 0.0
	var up := (e - near.global_position).normalized() if near != null else Vector3.ZERO
	var near_in := near != null and (e - near.global_position).length() < near.data.radius * 1.5
	for b in bodies:
		if b == near and near_in:
			continue
		var to_b := b.global_position - e
		var db := to_b.length()
		var dir := to_b / db
		var over := 1.0
		if near_in:
			over = smoothstep(-0.05, 0.1, dir.dot(up))
			if over <= 0.0:
				continue
		var ang := asin(clampf(b.data.radius / db, 0.0, 1.0))
		var omega := 2.0 * (1.0 - cos(ang))   # its solid angle / pi
		# The lit part of its face toward the camera: (1 + cos phase) / 2, the
		# phase the angle at the body between the star and the camera.
		var to_star := (star.global_position - b.global_position).normalized()
		var lit := (1.0 + to_star.dot(-dir)) * 0.5
		var score := LightRig.FILL_ALBEDO * omega * lit
		if score * over > best_score * best_over or best == null:
			best = b
			best_score = score
			best_dir = dir
			best_ang = ang
			best_over = over
	rig.set_fill(best, best_dir, best_score, best_ang, best_over, seen)


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
	star.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
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
	_build_belt()


## This system's belt, for the last one's.
func _build_belt() -> void:
	if belt != null:
		belt.queue_free()
		_belt_disc.queue_free()
		belt = null
	if sys.belt_outer <= 0.0:
		return
	belt = RockField.new()
	belt.setup(sys.belt_inner, sys.belt_outer, sys.system_seed, Color(0.48, 0.44, 0.40))
	belt.held = true
	star.add_child(belt)
	_belt_disc = belt.build_far(star_look, 0.35)


## The belt's near rocks, straight off the ship when it is the frame: millions of
## metres from the star a float32 is good to half a metre, and rocks going by would
## shake. The sum is exact, the ship's and the cell's numbers being that size alike.
func _belt_near(s2w: Transform3D) -> void:
	if belt == null:
		return
	if ship != null:
		belt.hold_near(Transform3D(s2w.basis, ship.global_position + s2w.basis * (belt.mid() - ship.rel.origin - ship.fine)))
	else:
		belt.hold_near(s2w * Transform3D(Basis(), belt.mid()))


## Whether space point `x` is among the belt's rocks, which hold still in the star's
## frame: stopped there is stopped by them, not going round with the nearest body.
func in_belt(x: Vector3) -> bool:
	return belt != null and belt.near(x)


## Rocks near the player drawn, its ring's and the belt's.
func _rocks(p: Vector3, dt: float) -> void:
	for b in bodies:
		if b.ring != null:
			b.ring.refresh(b.ring.to_local(p), dt)
	if belt != null:
		belt.refresh(belt.to_local(p), dt)


## Whether ship `s`, going to `at` in its reference frame, runs into a rock on
## the way: looked for along the step, or a fast ship steps over them.
func rock_block(s: SpaceShip, at: Vector3) -> bool:
	var f: RockField = belt if s.ref == null else s.ref.ring
	if f == null:
		return false
	var from := s.rel.origin if s.ref == null else f.transform.affine_inverse() * s.rel.origin
	var to := at if s.ref == null else f.transform.affine_inverse() * at
	if not f.near(from) and not f.near(to):
		return false
	var r := s._hull.size.length() * 0.5
	var steps := clampi(ceili(from.distance_to(to) / (r + RockField.ROCK_MIN)), 1, ROCK_STEPS)
	for k in range(1, steps + 1):
		if f.blocked(from.lerp(to, float(k) / steps), r):
			return true
	return false


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
	for e in drifts:
		_drop_body(e)
		if (e as Drift).task >= 0:
			WorkerThreadPool.wait_for_task_completion((e as Drift).task)
			(e as Drift).task = -1
