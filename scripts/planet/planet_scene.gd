extends Node3D

## A planet to walk on and fly from (Docs/Planets.md 11.5 step 3): one 10 km
## planet of smooth voxel ground (PlanetBody), its sea shell, impostor and
## atmosphere; the radial walker; the floating origin at 4 km; the voxel
## streaming distance from the horizon. scenes/planet.tscn.
##
##   On foot: the game's own pawn, its moves, gun and arms (Planets.md 11.7).
##   F to fly (the walker; wheel for speed, Space up, Ctrl down), F again to
##   land on foot. Left click to look, Esc to let go.
##   -- --gate: the walker -- walk, fly to 30 km and back, land; quit.
##   -- --gate=pawn: the pawn -- walk, strafe, jump, mantle, fire, fly, land.
##   -- --gate=mech, --gate=tank, --gate=soldier: a titan, a tank on the
##   player's controls, a soldier's body moved and aimed as its brain does it.

var data: PlanetData
var planet: PlanetBody
var buildings: PlanetBuildings
var spawn_dir := Vector3.UP
var town_dirs: Array = []
var landmark_dirs: Array = []
var walker: PlanetWalker
## The player on foot: the city's own kit (scripts/city_scene.gd _enter_pawn).
var cam: DebugCamera
var pawn: Pawn
var player: PlayerController
var gun: GunController
var view: PlayerView
var on_foot := false
var _pawn_gate := false
var _mech_gate := false
var _tank_gate := false
var _soldier_gate := false
var sun: DirectionalLight3D
var sky_mat: ProceduralSkyMaterial
var env: Environment
var hud: Label

const VIEW_MIN := 1536
const VIEW_MAX := 6144
const VIEW_STEP := 512
const VIEW_MARGIN := 300.0

var _gate := false
var _worst_ms := 0.0
var _hitches: Array = []
var _last_us := 0


func _ready() -> void:
	_gate = "--gate" in OS.get_cmdline_user_args()
	_pawn_gate = "--gate=pawn" in OS.get_cmdline_user_args()
	_mech_gate = "--gate=mech" in OS.get_cmdline_user_args()
	_tank_gate = "--gate=tank" in OS.get_cmdline_user_args()
	_soldier_gate = "--gate=soldier" in OS.get_cmdline_user_args()
	_gate = _gate or _pawn_gate or _mech_gate or _tank_gate or _soldier_gate
	data = PlanetData.new()
	data.planet_name = "proto"
	# Towns and landmarks: their pads go into the ground before it is built.
	var rng := RandomNumberGenerator.new()
	rng.seed = 0x70C1
	spawn_dir = Vector3(0.12, 1.0, -0.08).normalized()
	var east := spawn_dir.cross(Vector3.FORWARD).normalized()
	town_dirs = [_round_dir(spawn_dir, east, 220.0)]
	for k in 6:
		town_dirs.append(Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1)).normalized())
	landmark_dirs = [_round_dir(spawn_dir, east, 2600.0), _round_dir(spawn_dir, east.rotated(spawn_dir, 2.0), 9000.0),
			Vector3(-0.3, -0.8, 0.5).normalized()]
	for d in town_dirs:
		data.pads.append(PlanetBuildings.town_pad(data, d, 95.0, 70.0))
	for d in landmark_dirs:
		data.pads.append(PlanetBuildings.town_pad(data, d, 30.0, 40.0))
	planet = PlanetBody.new()
	add_child(planet)
	planet.setup(data)
	buildings = PlanetBuildings.new()
	planet.add_child(buildings)
	buildings.setup(planet)
	for d in town_dirs:
		buildings.add_town(d, 6, 30.0, rng)
	buildings.add_landmark(landmark_dirs[0], 80, 80, 900, rng)
	buildings.add_landmark(landmark_dirs[1], 100, 100, 1200, rng)
	buildings.add_landmark(landmark_dirs[2], 80, 80, 700, rng)
	buildings.finish()
	Gravity.planet = planet
	Gravity.planet_strength = data.gravity_strength
	Gravity.planet_radius = data.radius
	print("[planet] %s: radius %.0f m, relief %.0f m, sea %.0f m; impostor baked in %d ms" % [
			data.planet_name, data.radius, data.amplitude, data.sea_level, planet.bake_ms])
	_build_light()
	walker = PlanetWalker.new()
	walker.name = "Walker"
	add_child(walker)
	walker.camera.current = true
	walker.place(planet.global_position + data.surface_point(spawn_dir) + spawn_dir * 1.0,
			east)
	planet.activate()
	# The walker at the origin from the start: the planet's centre is 10 km off.
	PlanetFrame.recentre(self, walker.global_position)
	_build_hud()
	if _gate:
		DebugCamera.hands_off = true
		walker.scripted = true
		var tw := get_node_or_null(^"/root/TestWindow")
		if tw != null:
			tw.use_default_settings()
		if _pawn_gate:
			_run_pawn_gate()
		elif _mech_gate:
			_run_mech_gate()
		elif _tank_gate:
			_run_tank_gate()
		elif _soldier_gate:
			_run_soldier_gate()
		else:
			_run_gate()


## The pawn, its controller, camera, gun and arms, standing at `feet`, looking
## along `facing` (tangent). Built once; placed again after a flight.
func _spawn_player(feet: Vector3, facing: Vector3) -> void:
	cam = DebugCamera.new()
	cam.name = "Camera"
	cam.capture_mouse = false
	cam.allow_walk = false
	cam.far = 200000.0
	add_child(cam)
	cam.set_process(false)
	pawn = Pawn.spawn(self, feet, 0)
	pawn.moves = PawnMoves.new(pawn)
	player = PlayerController.new()
	player.name = "Player"
	player.drive_uncaptured = _gate
	add_child(player)
	player.possess(pawn, cam)
	gun = GunController.new()
	gun.name = "Gun"
	gun.rng = RandomNumberGenerator.new()
	gun.rng.seed = 0xC0FFEE
	gun.aim = cam
	add_child(gun)
	view = PlayerView.new()
	view.name = "PlayerView"
	add_child(view)
	view.setup(cam, pawn, gun)
	player.view = view
	var gi := GunInstance.from_result(GunGenerator.generate(GunPlaceholderParts.build_library(), 7,
			WeaponClass.builtin(&"rifle"), 1))
	gun.equip(gi)
	view.hold(gi)
	pawn.gun = gun
	gun.exclude = [pawn.body.get_rid()] as Array[RID]
	_face(facing)
	_set_on_foot(true)


## Turn the camera, in the pawn's frame, to look along `facing`.
func _face(facing: Vector3) -> void:
	var fr := pawn.body.global_transform.basis.orthonormalized()
	cam.set_frame(fr)
	var local := fr.inverse() * facing
	cam.global_transform.basis = fr * Basis.from_euler(Vector3(0.0, atan2(-local.x, -local.z), 0.0))


## On foot (the pawn and its camera) or flying (the walker). The voxel viewer
## goes with whichever it is, so the ground streams round the player.
func _set_on_foot(on: bool) -> void:
	on_foot = on
	var viewer := walker.viewer
	if on:
		var feet := _ground_hit(walker.global_position)
		if feet == Vector3.INF:
			feet = walker.global_position
		var fwd := -walker.camera.global_transform.basis.z
		pawn.place(feet + Gravity.up_at(feet) * 0.05)
		if not player.is_possessing():
			player.possess(pawn, cam)
		cam.current = true
		_face(Gravity.flat(fwd, Gravity.up_at(feet)).normalized())
		walker.process_mode = Node.PROCESS_MODE_DISABLED
		walker.collision_layer = 0
		walker.collision_mask = 0
		viewer.reparent(pawn.body, false)
		view.rig.visible = true
	else:
		var at := pawn.feet() + pawn.up * 0.3
		walker.process_mode = Node.PROCESS_MODE_INHERIT
		walker.collision_layer = 1
		walker.collision_mask = 1 | Layers.STRUCTURE
		walker.place(at, -cam.global_transform.basis.z)
		walker.flying = true
		walker.frozen = false
		walker.camera.current = true
		player.release()
		viewer.reparent(walker, false)
		view.rig.visible = false


func _unhandled_input(event: InputEvent) -> void:
	if pawn == null or _gate:
		return
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F:
		_set_on_foot(not on_foot)
		get_viewport().set_input_as_handled()


## Who the origin, the streaming and the sky follow.
func _anchor() -> Vector3:
	return pawn.body.global_position if on_foot else walker.global_position


func _eye() -> Vector3:
	return cam.global_position if on_foot else walker.camera.global_position


func _build_light() -> void:
	sun = DirectionalLight3D.new()
	sun.light_energy = 1.1
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 400.0
	add_child(sun)
	sun.look_at_from_position(Vector3.ZERO, -planet.sun_dir, Vector3.UP if absf(planet.sun_dir.y) < 0.99 else Vector3.FORWARD)
	env = Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	sky_mat = ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.36, 0.53, 0.78)
	sky_mat.sky_horizon_color = Color(0.70, 0.77, 0.84)
	sky_mat.ground_bottom_color = Color(0.25, 0.27, 0.24)
	sky_mat.ground_horizon_color = Color(0.70, 0.77, 0.84)
	sky.sky_material = sky_mat
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.6
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)


func _build_hud() -> void:
	var layer := CanvasLayer.new()
	hud = Label.new()
	hud.position = Vector2(14, 12)
	hud.add_theme_color_override("font_color", Color(0.95, 0.96, 0.98))
	hud.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	hud.add_theme_constant_override("outline_size", 4)
	layer.add_child(hud)
	add_child(layer)


func _process(_delta: float) -> void:
	var now := Time.get_ticks_usec()
	if _last_us > 0:
		var ms := float(now - _last_us) / 1000.0
		_worst_ms = maxf(_worst_ms, ms)
		if ms > 40.0 and _hitches.size() < 40:
			_hitches.append([snappedf(ms, 0.1), int(planet.altitude_of(_anchor()))])
	_last_us = now
	var cam_pos := _eye()
	var alt := planet.altitude_of(cam_pos)
	# The origin follows the player, by translation, every SHIFT_AT.
	if _anchor().length() > PlanetFrame.SHIFT_AT:
		PlanetFrame.recentre(self, _anchor())
	# Stream the voxel ground to the horizon and the peaks behind it, no further.
	var want := planet.horizon_reach(cam_pos, data.peak()) + VIEW_MARGIN
	var q := clampi(int(ceil(want / VIEW_STEP)) * VIEW_STEP, VIEW_MIN, VIEW_MAX)
	if q != walker.viewer.view_distance:
		walker.viewer.view_distance = q
	# The sky goes to black as the air thins (to ~the impostor's band).
	var air := 1.0 - clampf(alt / (data.radius * 0.12), 0.0, 1.0)
	sky_mat.sky_top_color = Color(0.36, 0.53, 0.78) * air
	sky_mat.sky_horizon_color = Color(0.70, 0.77, 0.84) * air
	# Under the horizon only a sliver of sky ever shows past the ground: haze.
	sky_mat.ground_horizon_color = Color(0.70, 0.77, 0.84) * air
	sky_mat.ground_bottom_color = Color(0.62, 0.68, 0.74) * air
	sky_mat.sky_energy_multiplier = maxf(air, 0.02)
	env.ambient_light_energy = 0.15 + 0.45 * air
	# The sky's up is the local up: a procedural sky's horizon is its own XZ
	# plane, and the world's Y is the local up only at the pole.
	env.sky_rotation = Quaternion(Vector3.UP, Gravity.up_at(cam_pos)).get_euler()
	# Hold the walker until the ground under it has streamed (and has a
	# collider); then, unless this is the walker's own gate, the pawn stands on it.
	if walker.frozen and pawn == null and _ground_hit(walker.global_position) != Vector3.INF:
		walker.frozen = false
		if not _gate or _pawn_gate or _mech_gate or _tank_gate or _soldier_gate:
			_spawn_player(_ground_hit(walker.global_position), -walker.global_transform.basis.z)
	if not on_foot:
		walker.flying = pawn != null or walker.flying
	if hud != null:
		hud.text = "%s  alt %.0f m  %.0f fps  view %d  shifts %d (last %.1f ms)  buildings %d near, %d far  %s" % [
				"on foot (F flies)" if on_foot else ("FLY %.0f m/s (F lands)" % walker.fly_speed if walker.flying else "walk"), alt,
				Engine.get_frames_per_second(), walker.viewer.view_distance, PlanetFrame.shifts,
				PlanetFrame.last_us / 1000.0, buildings.near_count, buildings.far_count,
				"(waiting for ground)" if walker.frozen else ""]


## `dir` carried `metres` along the surface toward `toward` (tangent).
func _round_dir(dir: Vector3, toward: Vector3, metres: float) -> Vector3:
	var axis := dir.cross(toward).normalized()
	return dir.rotated(axis, metres / data.radius).normalized()


## A ray down from 50 m over `world` to the ground's collider: the hit, or INF.
func _ground_hit(world: Vector3) -> Vector3:
	var up := Gravity.up_at(world)
	var q := PhysicsRayQueryParameters3D.create(world + up * 50.0, world - up * 60.0)
	q.exclude = [walker.get_rid()] if pawn == null else [walker.get_rid(), pawn.body.get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	return Vector3.INF if hit.is_empty() else hit.position


# ---------------------------------------------------------------------------
# The gate.

var _ok := 0
var _fail := 0


func _check(what: String, cond: bool, detail := "") -> void:
	if cond:
		_ok += 1
	else:
		_fail += 1
	print("  %s %s%s" % ["ok  " if cond else "FAIL", what, (" -- " + detail) if detail else ""])


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _shot(name: String) -> void:
	if DisplayServer.get_name() == "headless":
		return
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("res://shots/%s.png" % name)
	print("[planet] shot written: %s.png" % name)


func _run_gate() -> void:
	var t0 := Time.get_ticks_msec()
	while walker.frozen and Time.get_ticks_msec() - t0 < 60000:
		await _frames(1)
	var wait_s := (Time.get_ticks_msec() - t0) / 1000.0
	_check("the ground under the spawn streams in (< 20 s)", not walker.frozen and wait_s < 20.0, "%.1f s" % wait_s)
	await get_tree().create_timer(2.0).timeout
	await _shot("planet_gate_ground")
	# The town, from 90 m up behind the spawn.
	if DisplayServer.get_name() != "headless":
		var town: Vector3 = planet.global_position + data.surface_point(town_dirs[0])
		var up0 := Gravity.up_at(town)
		var over := Camera3D.new()
		over.far = 20000.0
		add_child(over)
		var back := (walker.global_position - town)
		back = (back - up0 * back.dot(up0)).normalized()
		over.look_at_from_position(town + back * 260.0 + up0 * 90.0, town + up0 * 10.0, up0)
		over.current = true
		await _frames(30)
		await _shot("planet_gate_town")
		walker.camera.current = true
		over.queue_free()
	# Walk 30 s forward.
	var start := walker.global_position - planet.global_position
	var air_ticks := 0
	var ticks := 0
	walker.wish = Vector2(0, 1)
	var t1 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t1 < 30000:
		await get_tree().physics_frame
		ticks += 1
		if not walker.is_on_floor():
			air_ticks += 1
	walker.wish = Vector2.ZERO
	var walked := (walker.global_position - planet.global_position).normalized().angle_to(start.normalized()) * data.radius
	_check("walks on the voxel ground (feet down > 97% of ticks)", air_ticks < ticks * 0.03, "%d of %d off, %.0f m walked" % [air_ticks, ticks, walked])
	var h := planet.altitude_of(walker.global_position) - data.height(planet.dir_of(walker.global_position))
	_check("stands ON the ground the CPU says is there (within 0.3 m)", absf(h) < 0.3, "%.2f m" % h)
	# A low cruise toward the first landmark, 2.6 km off: it and the town's
	# towers come up over the horizon ahead.
	walker.flying = true
	walker.pitch = 0.0
	var lm: Vector3 = planet.global_position + data.surface_point(landmark_dirs[0])
	var to_lm := lm - walker.global_position
	walker.place(walker.global_position, to_lm)
	var near_seen := 0
	var t_c := Time.get_ticks_msec()
	var shot_mid := false
	while Time.get_ticks_msec() - t_c < 32000:
		var over := planet.altitude_of(walker.global_position) - data.height(planet.dir_of(walker.global_position))
		walker.fly_speed = 70.0
		walker.wish = Vector2(0, 1)
		walker.rise = clampf((25.0 - over) * 0.1, -1.0, 1.0)
		await get_tree().physics_frame
		near_seen = maxi(near_seen, buildings.near_count)
		if not shot_mid and Time.get_ticks_msec() - t_c > 9000:
			shot_mid = true
			await _shot("planet_gate_cruise")
	walker.wish = Vector2.ZERO
	walker.rise = 0.0
	await _shot("planet_gate_landmark")
	_check("the near tier: shells were built near the town", near_seen > 0, "%d at most" % near_seen)
	# Fly up to 30 km, looking down at the ground ahead.
	walker.flying = true
	walker.pitch = -0.9
	var marks := {300.0: "planet_gate_300m", 1200.0: "planet_gate_1200m", 5000.0: "planet_gate_5km", 30000.0: "planet_gate_30km"}
	var reached := 0.0
	var t2 := Time.get_ticks_msec()
	while reached < 30000.0 and Time.get_ticks_msec() - t2 < 120000:
		var alt := planet.altitude_of(walker.global_position)
		walker.fly_speed = clampf(alt * 0.6, 20.0, 3000.0)
		walker.rise = 1.0
		await _frames(1)
		alt = planet.altitude_of(walker.global_position)
		for m in marks.keys():
			if reached < m and alt >= m:
				walker.rise = 0.0
				await _frames(20)
				await _shot(marks[m])
				print("[planet] at %.0f m: impostor %s (fade %.2f), ground %s, view %d; buildings %d far, %d near" % [
						alt, planet.impostor.visible, float(planet._impostor_mat.get_shader_parameter("fade")),
						planet.terrain.visible, walker.viewer.view_distance, buildings.far_count, buildings.near_count])
		reached = alt
	walker.rise = 0.0
	_check("flew to 30 km", reached >= 30000.0, "%.0f m" % reached)
	_check("from orbit the impostor alone draws", planet.impostor.visible and not planet.terrain.visible)
	_check("the origin followed (shifts > 3)", PlanetFrame.shifts > 3, "%d, the last %.1f ms" % [PlanetFrame.shifts, PlanetFrame.last_us / 1000.0])
	# And back down, near where it left.
	walker.pitch = 0.0
	var t3 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t3 < 120000:
		var alt := planet.altitude_of(walker.global_position) - data.height(planet.dir_of(walker.global_position))
		if alt < 3.0:
			break
		walker.fly_speed = clampf(alt * 0.6, 5.0, 3000.0)
		walker.rise = -1.0
		await _frames(1)
	walker.rise = 0.0
	walker.flying = false
	await get_tree().create_timer(4.0).timeout
	_check("lands and stands on the ground again", walker.is_on_floor(), "%.2f m over it" % (
			planet.altitude_of(walker.global_position) - data.height(planet.dir_of(walker.global_position))))
	await _shot("planet_gate_landed")
	_check("no building popped in plain sight (fade jumped > 1/3 over the horizon)", buildings.pops == 0,
			"%d; the biggest one-frame step %.2f" % [buildings.pops, buildings.max_step])
	print("[planet] frames: worst %.1f ms; over 40 ms: %s" % [_worst_ms, _hitches])
	print("[planet] gate: %d ok, %d FAIL" % [_ok, _fail])
	get_tree().quit(1 if _fail > 0 else 0)


# ---------------------------------------------------------------------------
# The pawn's gate: the game's own player on local down (Planets.md 11.7).

func _hold(action: StringName, seconds: float) -> void:
	Input.action_press(action)
	await get_tree().create_timer(seconds).timeout
	Input.action_release(action)


func _over_ground(p: Vector3) -> float:
	return planet.altitude_of(p) - data.height(planet.dir_of(p))


func _run_pawn_gate() -> void:
	var t0 := Time.get_ticks_msec()
	while pawn == null and Time.get_ticks_msec() - t0 < 60000:
		await _frames(1)
	_check("the pawn stands on the planet once the ground streams in", pawn != null,
			"%.1f s" % ((Time.get_ticks_msec() - t0) / 1000.0))
	if pawn == null:
		get_tree().quit(1)
		return
	await get_tree().create_timer(2.0).timeout
	_check("standing on its feet", pawn.is_on_floor(), "%.2f m over the ground" % _over_ground(pawn.feet()))
	await _shot("planet_pawn_stand")
	# Walk forward 15 s.
	var c := planet.global_position
	var p0 := pawn.feet() - c
	var air := 0
	var ticks := 0
	Input.action_press(&"move_forward")
	var t1 := Time.get_ticks_msec()
	var lift := 0.0
	var runs := 0
	var was_air := false
	var states := {}
	while Time.get_ticks_msec() - t1 < 15000:
		await get_tree().physics_frame
		ticks += 1
		var st: int = pawn.moves.state
		if pawn.is_auto_crouched():
			states["crouched"] = int(states.get("crouched", 0)) + 1
		if pawn.body.get_slide_collision_count() == 0:
			states["no_contact"] = int(states.get("no_contact", 0)) + 1
		states[st] = int(states.get(st, 0)) + 1
		if not pawn.is_on_floor():
			air += 1
			lift = maxf(lift, _over_ground(pawn.feet()))
			if not was_air:
				runs += 1
		was_air = not pawn.is_on_floor()
	Input.action_release(&"move_forward")
	print("[planet] walk: off the floor %d ticks in %d runs, the feet at most %.3f m over the ground; move states %s; on_wall %s" % [
			air, runs, lift, states, pawn.body.is_on_wall()])
	var walked := (pawn.feet() - planet.global_position).normalized().angle_to(p0.normalized()) * data.radius
	_check("walks on the voxel ground (feet down > 95% of ticks)", air < ticks * 0.05, "%d of %d off, %.0f m" % [air, ticks, walked])
	_check("at a walk's speed (15 s, 30-55 m)", walked > 30.0 and walked < 55.0, "%.1f m" % walked)
	_check("stands ON the ground the CPU says is there (within 0.3 m)", absf(_over_ground(pawn.feet())) < 0.3,
			"%.2f m" % _over_ground(pawn.feet()))
	var up := pawn.up
	var roll := rad_to_deg(asin(clampf(absf(cam.global_transform.basis.x.dot(up)), 0.0, 1.0)))
	_check("the camera's horizon is the local one (roll < 0.5 deg)", roll < 0.5, "%.3f deg" % roll)
	_check("the body stands along the local up (< 0.5 deg)", rad_to_deg(pawn.body.global_transform.basis.y.angle_to(up)) < 0.5)
	# Strafe 12 s: no drift off the great circle it set off along.
	var s0 := pawn.feet() - planet.global_position
	var side := cam.global_transform.basis.x
	var n := s0.normalized().cross(Gravity.flat(side, pawn.up).normalized()).normalized()
	var off := 0.0
	Input.action_press(&"move_right")
	var t2 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t2 < 12000:
		await get_tree().physics_frame
		off = maxf(off, absf((pawn.feet() - planet.global_position).dot(n)))
	Input.action_release(&"move_right")
	var strafed := (pawn.feet() - planet.global_position).normalized().angle_to(s0.normalized()) * data.radius
	_check("strafes without drift (< 0.3 m off over the strafe)", off < 0.3 and strafed > 20.0,
			"%.3f m off over %.0f m" % [off, strafed])
	await get_tree().create_timer(0.5).timeout
	# A standing jump: up and back down where it left.
	var j0 := pawn.feet()
	var left := false
	var peak := 0.0
	pawn.intents.jump = true
	var t3 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t3 < 3000:
		await get_tree().physics_frame
		peak = maxf(peak, _over_ground(pawn.feet()))
		if not pawn.is_on_floor():
			left = true
		elif left:
			break
	var drift := Gravity.flat(pawn.feet() - j0, pawn.up).length()
	_check("jumps along the local up and lands where it left (< 0.15 m)", left and drift < 0.15,
			"peak %.2f m, %.3f m off" % [peak, drift])
	# A mantle: a ledge a metre high, 1.6 m ahead, square to the ground.
	await get_tree().create_timer(0.5).timeout
	var f := Gravity.flat(-cam.global_transform.basis.z, pawn.up).normalized()
	var base := pawn.feet()
	var gup := pawn.up
	var ledge := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(3.0, 1.0, 1.5)
	cs.shape = box
	ledge.add_child(cs)
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = box.size
	mi.mesh = bm
	ledge.add_child(mi)
	add_child(ledge)
	var lb := Basis(f.cross(gup), gup, -f)
	ledge.global_transform = Transform3D(lb, base + f * 2.3 + gup * 0.4)
	await _frames(5)
	Input.action_press(&"move_forward")
	var climbed := 0.0
	var t4 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t4 < 3500:
		await get_tree().physics_frame
		if (Time.get_ticks_msec() - t4) > 300 and (Time.get_ticks_msec() - t4) < 1500:
			pawn.intents.jump = true
			pawn.intents.jump_held = true
		climbed = maxf(climbed, Gravity.vert(pawn.feet() - base, gup))
	Input.action_release(&"move_forward")
	pawn.intents.jump_held = false
	await _shot("planet_pawn_ledge")
	_check("gets up onto a metre-high ledge (feet > 0.8 m up)", climbed > 0.8, "%.2f m" % climbed)
	ledge.queue_free()
	# Fire: rounds go out of the gun.
	var shots := [0]
	gun.fired.connect(func(_i) -> void: shots[0] += 1)
	await _hold(&"fire", 0.8)
	await get_tree().create_timer(0.3).timeout
	_check("the gun fires on the planet", shots[0] > 0, "%d rounds" % shots[0])
	# Fly up 1 km, look round, land on foot again.
	_set_on_foot(false)
	walker.scripted = true
	walker.pitch = -0.4
	var t5 := Time.get_ticks_msec()
	while planet.altitude_of(walker.global_position) < 1000.0 and Time.get_ticks_msec() - t5 < 30000:
		walker.fly_speed = 120.0
		walker.rise = 1.0
		await _frames(1)
	walker.rise = 0.0
	await _shot("planet_pawn_flying")
	var t6 := Time.get_ticks_msec()
	while _over_ground(walker.global_position) > 3.0 and Time.get_ticks_msec() - t6 < 40000:
		walker.fly_speed = clampf(_over_ground(walker.global_position) * 0.8, 5.0, 300.0)
		walker.rise = -1.0
		await _frames(1)
	walker.rise = 0.0
	_set_on_foot(true)
	await get_tree().create_timer(2.0).timeout
	_check("lands on foot again and stands", on_foot and pawn.is_on_floor(), "%.2f m over the ground" % _over_ground(pawn.feet()))
	await _shot("planet_pawn_landed")
	print("[planet] frames: worst %.1f ms; over 40 ms: %s" % [_worst_ms, _hitches])
	print("[planet] pawn gate: %d ok, %d FAIL" % [_ok, _fail])
	get_tree().quit(1 if _fail > 0 else 0)



# ---------------------------------------------------------------------------
# The mech's gate: a titan on local down (Planets.md 11.7).

func _arc(a: Vector3, b: Vector3) -> float:
	var c := planet.global_position
	return (a - c).normalized().angle_to((b - c).normalized()) * data.radius


func _run_mech_gate() -> void:
	var t0 := Time.get_ticks_msec()
	while pawn == null and Time.get_ticks_msec() - t0 < 60000:
		await _frames(1)
	await get_tree().create_timer(1.0).timeout
	var fwd := Gravity.flat(-cam.global_transform.basis.z, pawn.up).normalized()
	var spot := pawn.feet() + fwd * 25.0
	var ground := _ground_hit(spot + Gravity.up_at(spot) * 20.0)
	if ground == Vector3.INF:
		ground = spot
	var mech := Mech.spawn(self, ground + Gravity.up_at(ground) * 0.2, 0.0)
	PlanetBody.track(mech.body)
	await get_tree().create_timer(3.0).timeout
	var up := mech.motor.up
	var tilt := rad_to_deg(mech.body.global_transform.basis.y.angle_to(up))
	_check("the mech stands upright on the planet (< 0.5 deg)", tilt < 0.5, "%.3f deg" % tilt)
	_check("on the voxel ground", mech.body.is_on_floor(), "%.2f m over it" % _over_ground(mech.feet()))
	# Look at it from the pawn.
	_face(Gravity.flat(mech.body.global_position - pawn.body.global_position, pawn.up).normalized())
	await _frames(10)
	await _shot("planet_mech_stand")
	# Forward 15 s along the torso.
	var p0 := mech.feet()
	var n := (p0 - planet.global_position).normalized().cross(-mech.motor.torso_basis().z).normalized()
	var air := 0
	var ticks := 0
	var off := 0.0
	mech.intents.move_dir = Vector2(0.0, 1.0)
	var t1 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t1 < 15000:
		await get_tree().physics_frame
		ticks += 1
		if not mech.body.is_on_floor():
			air += 1
		off = maxf(off, absf((mech.feet() - planet.global_position).dot(n)))
	mech.intents.move_dir = Vector2.ZERO
	var walked := _arc(p0, mech.feet())
	_check("walks on the voxel ground (feet down > 95% of ticks)", air < ticks * 0.05, "%d of %d off" % [air, ticks])
	_check("covers ground at a walk (15 s, > 40 m)", walked > 40.0, "%.1f m" % walked)
	_check("straight along its great circle (< 1% off)", off < walked * 0.01, "%.2f m off over %.0f m" % [off, walked])
	_check("still upright after the walk (< 0.5 deg)",
			rad_to_deg(mech.body.global_transform.basis.y.angle_to(mech.motor.up)) < 0.5)
	await _shot("planet_mech_walked")
	# Strafe 8 s.
	await get_tree().create_timer(1.5).timeout
	var s0 := mech.feet()
	var n2 := (s0 - planet.global_position).normalized().cross(mech.motor.torso_basis().x).normalized()
	var off2 := 0.0
	mech.intents.move_dir = Vector2(1.0, 0.0)
	var t2 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t2 < 8000:
		await get_tree().physics_frame
		off2 = maxf(off2, absf((mech.feet() - planet.global_position).dot(n2)))
	mech.intents.move_dir = Vector2.ZERO
	var strafed := _arc(s0, mech.feet())
	_check("strafes along its great circle (< 1% off)", strafed > 10.0 and off2 < strafed * 0.01,
			"%.2f m off over %.0f m" % [off2, strafed])
	# A dash: the speed jumps and comes back.
	await get_tree().create_timer(1.5).timeout
	var peak := 0.0
	mech.intents.move_dir = Vector2(0.0, 1.0)
	await get_tree().physics_frame
	mech.intents.dash = true
	for i in 30:
		await get_tree().physics_frame
		mech.intents.dash = false
		peak = maxf(peak, mech.motor.planar_speed())
	mech.intents.move_dir = Vector2.ZERO
	_check("dashes along the ground", peak > mech.motor.max_speed * 1.5, "peak %.1f m/s (walk %.1f)" % [peak, mech.motor.max_speed])
	# The torso turns about the local up.
	await get_tree().create_timer(2.0).timeout
	var f0 := -mech.motor.torso_basis().z
	mech.intents.aim_yaw = mech.motor.torso_yaw + 1.0
	await get_tree().create_timer(3.0).timeout
	var f1 := -mech.motor.torso_basis().z
	var turned := rad_to_deg(Gravity.flat(f0, mech.motor.up).signed_angle_to(Gravity.flat(f1, mech.motor.up), mech.motor.up))
	_check("the torso turns about the local up (57 deg asked)", absf(turned - 57.3) < 3.0, "%.1f deg" % turned)
	_check("and stays square to the ground (forward level, < 1 deg)",
			absf(90.0 - rad_to_deg(f1.angle_to(mech.motor.up))) < 1.0)
	# Dropped from 15 m: lands standing.
	var drop_at := mech.feet() + mech.motor.up * 15.0
	mech.body.global_position = drop_at + mech.motor.up * Mech.HEIGHT * 0.5
	mech.body.velocity = Vector3.ZERO
	mech.body.reset_physics_interpolation()
	var landed := [false]
	mech.motor.landed.connect(func(_f) -> void: landed[0] = true)
	await get_tree().create_timer(4.0).timeout
	_check("dropped 15 m, it lands and stands", landed[0] and mech.body.is_on_floor(),
			"%.2f m over the ground" % _over_ground(mech.feet()))
	print("[planet] frames: worst %.1f ms; over 40 ms: %s" % [_worst_ms, _hitches])
	print("[planet] mech gate: %d ok, %d FAIL" % [_ok, _fail])
	get_tree().quit(1 if _fail > 0 else 0)


# ---------------------------------------------------------------------------
# The tank's gate: the player's tank on local down (Planets.md 11.7). Driven by
# its throttle and steer, as VehiclePilot drives it; no AI services.

## A spot `metres` ahead of the pawn's camera, on the ground.
func _ahead_on_ground(metres: float) -> Vector3:
	var fwd := Gravity.flat(-cam.global_transform.basis.z, pawn.up).normalized()
	var spot := pawn.feet() + fwd * metres
	var ground := _ground_hit(spot + Gravity.up_at(spot) * 20.0)
	return spot if ground == Vector3.INF else ground


func _run_tank_gate() -> void:
	var t0 := Time.get_ticks_msec()
	while pawn == null and Time.get_ticks_msec() - t0 < 60000:
		await _frames(1)
	await get_tree().create_timer(1.0).timeout
	var at := _ahead_on_ground(20.0)
	var tk := Tank.make(null, self, at + Gravity.up_at(at) * 0.3, 0.0, 0, null, null, Callable(),
			RandomNumberGenerator.new())
	PlanetBody.track(tk)
	await get_tree().create_timer(3.0).timeout
	var tilt := rad_to_deg(tk.global_transform.basis.y.angle_to(tk.up))
	_check("the tank stands square to local up (< 0.5 deg)", tilt < 0.5, "%.3f deg" % tilt)
	_check("on the voxel ground", tk.is_on_floor(), "%.2f m over it" % _over_ground(tk.feet()))
	_face(Gravity.flat(tk.global_position - pawn.body.global_position, pawn.up).normalized())
	await _frames(10)
	await _shot("planet_tank_stand")
	_check("the player takes the wheel", tk.take_player(0, Tank.Seat.DRIVER) and tk.driven())
	# Full ahead 12 s: along the great circle its nose points down.
	var p0 := tk.feet()
	var n := (p0 - planet.global_position).normalized().cross(tk.forward()).normalized()
	var air := 0
	var ticks := 0
	var off := 0.0
	tk.throttle = 1.0
	var t1 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t1 < 12000:
		await get_tree().physics_frame
		ticks += 1
		if not tk.is_on_floor():
			air += 1
		off = maxf(off, absf((tk.feet() - planet.global_position).dot(n)))
	var driven := _arc(p0, tk.feet())
	_check("drives on the voxel ground (on it > 95% of ticks)", air < ticks * 0.05, "%d of %d off" % [air, ticks])
	_check("covers ground at its speed (12 s, > 45 m)", driven > 45.0, "%.1f m" % driven)
	_check("straight along its great circle (< 1% off)", off < driven * 0.01, "%.2f m off over %.0f m" % [off, driven])
	_check("still square to local up (< 0.5 deg)",
			rad_to_deg(tk.global_transform.basis.y.angle_to(tk.up)) < 0.5)
	await _shot("planet_tank_driven")
	# Steer left 2 s at speed: it turns about the local up.
	var f0 := tk.forward()
	tk.steer = 1.0
	await get_tree().create_timer(2.0).timeout
	tk.steer = 0.0
	var f1 := tk.forward()
	var turned := rad_to_deg(Gravity.flat(f0, tk.up).signed_angle_to(Gravity.flat(f1, tk.up), tk.up))
	var asked := rad_to_deg(Tank.TURN * 2.0)
	_check("turns left about the local up (~%.0f deg asked)" % asked,
			turned > asked * 0.7 and turned < asked * 1.1, "%.1f deg" % turned)
	_check("its nose level along the ground (< 1 deg)", absf(90.0 - rad_to_deg(f1.angle_to(tk.up))) < 1.0)
	# Off the throttle: it rolls to a stop.
	tk.throttle = 0.0
	await get_tree().create_timer(3.0).timeout
	var sp := Gravity.flat(tk.velocity, tk.up).length()
	_check("off the throttle it stops (< 0.3 m/s)", sp < 0.3, "%.2f m/s" % sp)
	# Back up 3 s: the other way along its nose.
	var b0 := tk.feet()
	tk.throttle = -1.0
	await get_tree().create_timer(3.0).timeout
	tk.throttle = 0.0
	var back := (tk.feet() - b0).dot(-tk.forward())
	_check("reverses along its nose (> 5 m)", back > 5.0, "%.1f m" % back)
	# Dropped from 6 m: down on its tracks.
	await get_tree().create_timer(2.0).timeout
	tk.global_position = tk.feet() + tk.up * (6.0 + Tank.HEIGHT * 0.5)
	tk.velocity = Vector3.ZERO
	tk.reset_physics_interpolation()
	await get_tree().create_timer(4.0).timeout
	_check("dropped 6 m, it lands on the ground", tk.is_on_floor(), "%.2f m over it" % _over_ground(tk.feet()))
	print("[planet] frames: worst %.1f ms; over 40 ms: %s" % [_worst_ms, _hitches])
	print("[planet] tank gate: %d ok, %d FAIL" % [_ok, _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# ---------------------------------------------------------------------------
# The soldier's gate: an AI body on local down (Planets.md 11.7). Moved the way
# Soldier.walk_toward moves it (a world direction along the ground) and aimed
# the way Soldier aims (AimModel's world angles through Pawn.frame_look). The
# brain's world -- nav, sight, the AI grid -- is still the flat game's.

func _run_soldier_gate() -> void:
	var t0 := Time.get_ticks_msec()
	while pawn == null and Time.get_ticks_msec() - t0 < 60000:
		await _frames(1)
	await get_tree().create_timer(1.0).timeout
	var at := _ahead_on_ground(10.0)
	var so := Pawn.spawn(self, at + Gravity.up_at(at) * 0.2, 1)
	so.moves = PawnMoves.new(so)
	PlanetBody.track(so.body)
	await get_tree().create_timer(2.5).timeout
	_check("the soldier stands upright (< 0.5 deg)",
			rad_to_deg(so.body.global_transform.basis.y.angle_to(so.up)) < 0.5)
	_check("on the voxel ground", so.body.is_on_floor(), "%.2f m over it" % _over_ground(so.feet()))
	# Walk to a point 40 m round the planet, steering as walk_toward does.
	var c := planet.global_position
	var radial := (so.feet() - c).normalized()
	var side := Gravity.flat(so.feet() - pawn.feet(), so.up).normalized()
	var goal := c + _round_dir(radial, radial + side, 40.0) * (so.feet() - c).length()
	var ticks := 0
	var air := 0
	var left := INF
	var t1 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t1 < 20000:
		await get_tree().physics_frame
		ticks += 1
		if not so.body.is_on_floor():
			air += 1
		var d := Gravity.flat(goal - so.feet(), so.up)
		left = d.length()
		if left <= 0.6:
			break
		so.intents.move = d.normalized()
		so.intents.run = true
	so.intents.move = Vector3.ZERO
	_check("walks 40 m round the curve to its goal (< 0.6 m)", left <= 0.6, "%.2f m short" % left)
	_check("feet on the ground on the way (> 95% of ticks)", air < ticks * 0.05, "%d of %d off" % [air, ticks])
	_face(Gravity.flat(so.body.global_position - pawn.body.global_position, pawn.up).normalized())
	await _frames(10)
	await _shot("planet_soldier_walked")
	await get_tree().create_timer(1.0).timeout
	# Aim at the player: AimModel's world yaw and pitch, through frame_look.
	var eye := so.eye.global_position
	var to := pawn.chest() - eye
	var wyaw := atan2(-to.x, -to.z)
	var wpitch := atan2(to.y, Vector2(to.x, to.z).length())
	var la := so.frame_look(wyaw, wpitch)
	so.intents.look_yaw = la.x
	so.intents.look_pitch = la.y
	var miss := rad_to_deg(so.look_dir().angle_to(Gravity.flat(to, so.up).normalized()))
	_check("its look turns to the player along the ground (< 0.5 deg)", miss < 0.5, "%.2f deg" % miss)
	var tl := so.body.global_transform.basis.orthonormalized().inverse() * to
	var want_pitch := atan2(tl.y, Vector2(tl.x, tl.z).length())
	_check("and its pitch is the pitch in its own frame (< 0.5 deg)", absf(rad_to_deg(la.y - want_pitch)) < 0.5,
			"%.2f vs %.2f deg" % [rad_to_deg(la.y), rad_to_deg(want_pitch)])
	var la2 := so.look_angles_to(to)
	_check("look_angles_to agrees with frame_look",
			absf(wrapf(la2.x - la.x, -PI, PI)) < 0.002 and absf(la2.y - la.y) < 0.002)
	# Its body fits where it stands, upright to local up; sunk half a metre into
	# the ground it does not. (The voxel collider is one-sided: a capsule with
	# its middle under the surface meets only back faces, which Jolt ignores --
	# never a spot body_fits is asked about, as they are snapped to the ground.)
	_check("body_fits: room where it stands", Soldier.body_fits(get_world_3d(), so.feet(), so.body.get_rid()))
	_check("body_fits: no room half a metre into the ground",
			not Soldier.body_fits(get_world_3d(), so.feet() - so.up * 0.5, so.body.get_rid()))
	print("[planet] frames: worst %.1f ms; over 40 ms: %s" % [_worst_ms, _hitches])
	print("[planet] soldier gate: %d ok, %d FAIL" % [_ok, _fail])
	get_tree().quit(0 if _fail == 0 else 1)
