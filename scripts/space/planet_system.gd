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
## Top-level nodes in this group are the player's: they travel, never sleep.
const RIG := &"player_rig"

## `kick`: the world velocity everything that travels takes on at this handoff
## (its velocity already turned with the world).
signal anchor_changed(old_body: PlanetBody, new_body: PlanetBody, kick: Vector3)
## `body` woke as the anchor: what holds world positions for it, and was not
## shifted while it slept, takes `offset`.
signal woke(body: PlanetBody, offset: Vector3)

var sys: StarSystem
## By index in sys.bodies; home's is the scene's own PlanetBody.
var bodies: Array[PlanetBody] = []
## The orbit clock, seconds; `time_scale` 1 is STA's pace.
var t := 0.0
var time_scale := 1.0
## Stopped: no orbit, no spin, no handoff kick (STA's T). Every gate but the
## system's own runs stopped.
var frozen := false
var anchor: PlanetBody = null
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
	for i in sys.bodies.size():
		if i == sys.home and home_body != null:
			bodies.append(home_body)
			continue
		var b := PlanetBody.new()
		add_child(b)
		b.setup(sys.bodies[i], true)
		b.process_mode = Node.PROCESS_MODE_DISABLED
		b.far_only()
		bodies.append(b)
	if home_body != null:
		anchor = home_body
	_build_star()
	_place()


func index_of(b: PlanetBody) -> int:
	return bodies.find(b)


## Space frame to world, now.
func space_to_world() -> Transform3D:
	if anchor != null:
		return Transform3D(Basis(), anchor.global_position) * sys.xform(index_of(anchor), t).affine_inverse()
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


## The world velocity flight there should hold to: still on the anchor; the
## nearest body's orbital velocity in space (a flight computer matching it).
func match_velocity(p: Vector3) -> Vector3:
	if anchor != null or frozen:
		return Vector3.ZERO
	var b := nearest(p)
	return _space_basis * sys.vel(index_of(b), t)


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


func _process(delta: float) -> void:
	if not frozen:
		t += delta * time_scale
	if observer.is_valid():
		_choose_anchor(observer.call())
	_place()
	_gravity()
	if eye.is_valid():
		_light(eye.call())
		_scaled_space(eye.call())
	_bake_service()


## Every body but the anchor, and the star, where the clock has them.
func _place() -> void:
	var s2w := space_to_world()
	star.global_position = s2w.origin
	for i in bodies.size():
		var b := bodies[i]
		if b != anchor:
			b.global_transform = s2w * sys.xform(i, t)
	for b in bodies:
		b.set_sun(b.global_basis.inverse() * (star.global_position - b.global_position).normalized())


func _gravity() -> void:
	var g := anchor
	if g == null and observer.is_valid():
		g = nearest(observer.call())
	if g == null:
		return
	Gravity.planet = g
	Gravity.planet_strength = g.data.gravity_strength
	Gravity.planet_radius = g.data.radius


func _choose_anchor(p: Vector3) -> void:
	if anchor != null and (p - anchor.global_position).length() < anchor.data.radius * SHELL * SHELL_OUT:
		return
	var best: PlanetBody = null
	var best_q := 1.0
	for b in bodies:
		var q := (p - b.global_position).length() / (b.data.radius * SHELL)
		if q < best_q:
			best_q = q
			best = b
	if best != anchor:
		_switch(best, p)


## Hand the frame over from the anchor to `next` (either may be null: space)
## at the player's world point `p`.
func _switch(next: PlanetBody, p: Vector3) -> void:
	var old := anchor
	var s2w := space_to_world()
	var x := s2w.affine_inverse() * p
	var vf_old := _frame_velocity(old, x)
	if old != null:
		# Into the star's frame, at the turn the world has now.
		_space_basis = s2w.basis
		star.global_position = s2w.origin
		anchor = null
		_sleep(old)
	var s2w_new := space_to_world()
	if next != null:
		# `next` is turned to the identity where it is seen from the player:
		# the world turns about the player, who stays put.
		var tx := sys.xform(index_of(next), t)
		var at := p - tx.basis.inverse() * (x - tx.origin)
		s2w_new = Transform3D(Basis(), at) * tx.affine_inverse()
		var m := s2w_new * s2w.affine_inverse()
		next.global_transform = Transform3D(Basis(), at)
		anchor = next
		_travel(m)
		_wake(next)
	var kick := s2w_new.basis * (vf_old - _frame_velocity(next, x))
	handoffs += 1
	last_kick = kick
	print("[system] handoff %s -> %s at t %.1f s: kick %.1f m/s" % [
			old.data.planet_name if old != null else "space", next.data.planet_name if next != null else "space",
			t, kick.length()])
	_place()
	anchor_changed.emit(old, next, kick)


## The space-frame velocity of body `b`'s turning frame at space point `x` (0:
## the star's frame, or the clock stopped).
func _frame_velocity(b: PlanetBody, x: Vector3) -> Vector3:
	if b == null or frozen:
		return Vector3.ZERO
	return sys.frame_velocity(index_of(b), t, x)


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


func _sleep(b: PlanetBody) -> void:
	var list: Array = []
	for n in _top_level():
		if n.is_in_group(RIG):
			continue
		list.append([n, n.process_mode])
	for e in list:
		var n: Node3D = e[0]
		n.process_mode = Node.PROCESS_MODE_DISABLED
		n.reparent(b, true)
	_sleepers[b] = list
	_left_at[b] = b.global_position
	b.deactivate()
	b.process_mode = Node.PROCESS_MODE_DISABLED
	print("[system] %s sleeps with %d thing(s) on it" % [b.data.planet_name, list.size()])


func _wake(b: PlanetBody) -> void:
	b.process_mode = Node.PROCESS_MODE_INHERIT
	for e in _sleepers.get(b, []):
		var n: Node3D = e[0]
		if is_instance_valid(n):
			n.reparent(get_parent(), true)
			n.process_mode = e[1]
			n.reset_physics_interpolation()
	_sleepers.erase(b)
	WorldFrame.origin = -b.global_position
	_full_bake(b)
	b.activate()
	var offset: Vector3 = b.global_position - _left_at.get(b, b.global_position)
	_left_at.erase(b)
	woke.emit(b, offset)


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
