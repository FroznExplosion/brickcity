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
##   -- --gate=bricks: the town's buildings near the player as real bricks --
##   drawn, solid, a way in, and bricks to the AI (11.11).
##   -- --gate=damage: rounds wear a brick out of a planet building, a blast
##   opens its wall; drawing, collision and the AI's map follow (11.11 D1).
##   -- --gate=trees: a tank knocks a tree down; a truck is stopped by one
##   (11.10, trees and vehicles).
##   -- --gate=squad: a squad on the AI's nav region round the town (11.8 N2)
##   walks to the player round the curve, takes cover, fires.
##   -- --gate=travel: a squad ordered 200 m out of the town on the nav net
##   (11.8 N4), across the regions' borders.
##   -- --gate=far: two squads fight on the far side of the town, in a region
##   the player is not in: each agent asks its own region (AIServices.focus).
##   -- --gate=drive: an AI tank driven 200 m out of the town on the nav net's
##   tank map, across the regions' borders.

var data: PlanetData
var planet: PlanetBody
var buildings: PlanetBuildings
var trees: PlanetTrees
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
## The firefight's player kit round the pawn: arsenal, HUD, aim assist (PlanetPlayerKit).
var kit: PlanetPlayerKit
var on_foot := false
var _pawn_gate := false
var _mech_gate := false
var _tank_gate := false
var _soldier_gate := false
var _squad_gate := false
var _trees_gate := false
var _bricks_gate := false
var _damage_gate := false
## The AI round the fight (Docs/Planets.md 11.8, N2, N4): the nav net round the
## player's town; ai_world / ai_nav the region the player is in. Made by setup_ai.
var ai: AIServices
var nav_region: PlanetNavRegion
var _travel_gate := false
var _far_gate := false
var _drive_gate := false
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
## The same, from when the walker is let go: what play sees, not the load.
var _play_hitches: Array = []
var _last_us := 0


func _ready() -> void:
	_gate = "--gate" in OS.get_cmdline_user_args()
	_pawn_gate = "--gate=pawn" in OS.get_cmdline_user_args()
	_mech_gate = "--gate=mech" in OS.get_cmdline_user_args()
	_tank_gate = "--gate=tank" in OS.get_cmdline_user_args()
	_soldier_gate = "--gate=soldier" in OS.get_cmdline_user_args()
	_squad_gate = "--gate=squad" in OS.get_cmdline_user_args()
	_trees_gate = "--gate=trees" in OS.get_cmdline_user_args()
	_bricks_gate = "--gate=bricks" in OS.get_cmdline_user_args()
	_damage_gate = "--gate=damage" in OS.get_cmdline_user_args()
	_travel_gate = "--gate=travel" in OS.get_cmdline_user_args()
	_far_gate = "--gate=far" in OS.get_cmdline_user_args()
	_drive_gate = "--gate=drive" in OS.get_cmdline_user_args()
	_gate = _gate or _pawn_gate or _mech_gate or _tank_gate or _soldier_gate or _squad_gate or _travel_gate or _far_gate or _drive_gate or _trees_gate or _bricks_gate or _damage_gate
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
	# Trees by biome, streamed round the camera (11.10).
	trees = PlanetTrees.new()
	planet.add_child(trees)
	trees.setup(data)
	trees.prebake()
	# The brick buildings' shapes round the spawn, while it loads (11.11).
	var tpl_ms := buildings.prepare_templates(planet.global_position + data.surface_point(spawn_dir), 400.0)
	Gravity.planet = planet
	Gravity.planet_strength = data.gravity_strength
	Gravity.planet_radius = data.radius
	print("[planet] %s: radius %.0f m, relief %.0f m, sea %.0f m; impostor baked in %d ms; brick shapes %.0f ms" % [
			data.planet_name, data.radius, data.amplitude, data.sea_level, planet.bake_ms, tpl_ms])
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
		elif _squad_gate:
			_run_squad_gate()
		elif _trees_gate:
			_run_trees_gate()
		elif _bricks_gate:
			_run_bricks_gate()
		elif _damage_gate:
			_run_damage_gate()
		elif _travel_gate:
			_run_travel_gate()
		elif _far_gate:
			_run_far_gate()
		elif _drive_gate:
			_run_drive_gate()
		else:
			_run_gate()


## A round or a blast at a building's bricks (GunController.on_structure_hit):
## the planet's buildings take it (11.11 D1).
func _structure_hit(point: Vector3, _dir: Vector3, shot: Dictionary) -> void:
	buildings.damage(point, shot)


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
	gun.on_structure_hit = _structure_hit
	_face(facing)
	_set_on_foot(true)
	# The AI it fights: the town's region (11.8 N2), unless a gate sets up its own.
	if ai == null and not _gate:
		setup_ai(town_dirs[0])
	var s := ai
	if s == null:
		s = AIServices.new()
		s.world3d = get_world_3d()
	kit = PlanetPlayerKit.attach(self, player, cam, gun, view, s, _gate)


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
	# Under the kit's line of controls (PlayerHud), over its aggro meter.
	hud.position = Vector2(14, 120)
	hud.add_theme_font_size_override("font_size", 13)
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
		if ms > 40.0 and not walker.frozen and _play_hitches.size() < 40:
			_play_hitches.append([snappedf(ms, 0.1), int(planet.altitude_of(_anchor()))])
	_last_us = now
	var cam_pos := _eye()
	var alt := planet.altitude_of(cam_pos)
	# The origin follows the player, by translation, every SHIFT_AT.
	if _anchor().length() > PlanetFrame.SHIFT_AT:
		var offset := PlanetFrame.recentre(self, _anchor())
		buildings.on_origin_shift()
		if ai != null:
			(ai.nav_net as PlanetNavNet).shift_origin(offset)
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
	# collider) and the trees' cards are baked; then, unless this is the
	# walker's own gate, the pawn stands on it.
	if walker.frozen and pawn == null and trees.prebaked and _ground_hit(walker.global_position) != Vector3.INF:
		walker.frozen = false
		if not _gate or _pawn_gate or _mech_gate or _tank_gate or _soldier_gate or _squad_gate or _travel_gate or _far_gate or _drive_gate or _trees_gate or _bricks_gate or _damage_gate:
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
	print("[planet] frames: worst %.1f ms; over 40 ms: %s; of them in play (after the walker is let go): %d %s" % [
			_worst_ms, _hitches, _play_hitches.size(), _play_hitches])
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


# ---------------------------------------------------------------------------
# The AI on the planet (Docs/Planets.md 11.8, N2 and N4): nav regions round the fight.

## Regions are kept round everybody fighting within this (PlanetNavNet.keep_around).
const AI_KEEP_M := 60.0
## How often the regions round the fight are looked at again, seconds.
const AI_KEEP_EVERY := 0.5
var _ai_keep_t := 0.0
## The AI's longest physics tick (us) and its parts: keep_around, the net, the rest.
var ai_worst_us := 0
var ai_worst_parts: Array = []


## Set up the AI services on the nav net (PlanetNavNet) anchored over
## planet-local `dir`: regions of 8 x 8 tiles, each its own framed AIWorld and
## AINav on its ground grid (N1, N1b), made round whoever fights and dropped
## behind them. The buildings go into the regions they reach as proxy boxes --
## solid to walk round, bricks to hide behind (their own bricks in the AI's
## world are later work, 11.8 "Not here"). ai_world and ai_nav are the region
## the player is in; a soldier's paths go through the net, across regions. The
## floating origin moves every region's frame with the scene (_process).
func setup_ai(dir: Vector3) -> void:
	var t0 := Time.get_ticks_usec()
	var stud := BrickWorld.get_stud_metres()
	var sites: Array = []
	for s in buildings.sites:
		var size := Vector3(s.fx * stud, s.height, s.fz * stud)
		sites.append([s.frame * Transform3D(Basis(), size * 0.5), size])
	var net := PlanetNavNet.make(data, dir, planet)
	net.set_sites(sites)
	# The buildings' bricks (11.11): the regions read them, a site's box goes
	# while its bricks stand.
	net.bricks = buildings.bricks
	buildings.site_bricks.connect(func(i: int, on: bool) -> void: net.set_site_bricks(i, on, buildings.site_box(i)))
	for i in buildings.sites.size():
		if buildings.sites[i].bricked:
			net.set_site_bricks(i, true, buildings.site_box(i))
	# The trees' trunks too: walked round, and cover; one knocked down goes (11.10).
	net.tree_source = trees.trees_near
	trees.tree_knocked.connect(net.remove_tree)
	# What breaks the buildings' bricks (11.11 D1): a soldier's rounds, a squad's
	# breaching charge; the maps forget where bricks went.
	buildings.site_damaged.connect(func(_i: int, box: AABB) -> void: net.invalidate_box(box))
	var at := planet.global_transform * data.surface_point(dir)
	net.keep_around([at], AI_KEEP_M, 99)
	# From here on regions' grids are built on worker threads, off the frame.
	net.threaded = true
	var r := net.region_at(at)
	nav_region = r.nav_region
	ai = AIServices.new()
	ai.nav_net = net
	ai.ai_world = r.world
	ai.ai_nav = r.nav
	ai.sched = AIScheduler.new()
	ai.sched.set_base_budget_ms(2.5)
	ai.world3d = get_world_3d()
	ai.rng.seed = 0x9A7E7
	ai.on_structure_hit = _structure_hit
	ai.on_breach = func(p: Vector3, r: float) -> void: buildings.damage(p, {"blast": true, "radius": r, "hp": 0})
	print("[planet] AI nav net over the town: %d region(s) in %.0f ms (%.0f ms the one there), %d building(s)" % [
			net.regions.size(), (Time.get_ticks_usec() - t0) / 1000.0, r.made_ms, sites.size()])


func _physics_process(delta: float) -> void:
	if ai == null:
		return
	var net := ai.nav_net as PlanetNavNet
	var t_ai := Time.get_ticks_usec()
	_ai_keep_t += delta
	if _ai_keep_t >= AI_KEEP_EVERY:
		_ai_keep_t = 0.0
		var points: Array = []
		if pawn != null:
			points.append(pawn.feet())
		for p in ai.pawns:
			if is_instance_valid(p) and p.health != null and not p.health.is_dead():
				points.append(p.feet())
		net.keep_around(points, AI_KEEP_M, 1)
		var here := net.region_at(pawn.feet()) if pawn != null else null
		if here != null:
			nav_region = here.nav_region
	var t_keep := Time.get_ticks_usec()
	# Between thinkers the services are the player's region (AIServices.focus).
	if pawn != null:
		ai.focus(pawn.feet())
	ai.ai_world.sync()
	net.service(800)
	var t_net := Time.get_ticks_usec()
	ai.sched.run()
	# Each thinker focused the services on its own region; the shared tick is the player's.
	if pawn != null:
		ai.focus(pawn.feet())
	ai.tick()
	var t_end := Time.get_ticks_usec()
	if t_end - t_ai > ai_worst_us:
		ai_worst_us = t_end - t_ai
		ai_worst_parts = [t_keep - t_ai, t_net - t_keep, t_end - t_net]


# The squad's gate: four soldiers set down in the town walk to the player round
# the curve, take cover and fire, on the region's nav (11.8 N2).

func _surface(dir: Vector3) -> Vector3:
	return planet.global_transform * data.surface_point(dir)


func _run_squad_gate() -> void:
	var t0 := Time.get_ticks_msec()
	while pawn == null and Time.get_ticks_msec() - t0 < 60000:
		await _frames(1)
	await get_tree().create_timer(1.0).timeout
	var town: Vector3 = town_dirs[0]
	# The player at the town's edge on the spawn's side, the squad inside it.
	var p_feet := _surface(_round_dir(town, spawn_dir, 88.0))
	var q_spot := _surface(_round_dir(town, spawn_dir, 28.0))
	pawn.place(p_feet + Gravity.up_at(p_feet) * 0.3)
	pawn.health.layer_configs[0].max_value = 1e7
	pawn.health.reset()
	_face(Gravity.flat(q_spot - p_feet, Gravity.up_at(p_feet)).normalized())
	t0 = Time.get_ticks_msec()
	while _ground_hit(p_feet) == Vector3.INF and Time.get_ticks_msec() - t0 < 30000:
		await _frames(1)
	await get_tree().create_timer(1.5).timeout
	setup_ai(town)
	# The cover mechanics, not the engage decision's dice (as soldier_probe).
	ai.policy = CombatPolicy.new()
	var plate := BrickWorld.get_plate_metres()
	_check("the region builds off the fight's path (< 2 s)", nav_region.build_ms < 2000.0,
			"%.0f ms" % nav_region.build_ms)
	pawn.set_meta(&"player", 0)
	ai.add_pawn(pawn)
	# The nav's own path from the squad to the player first: on the ground.
	var path := (ai.nav_net as PlanetNavNet).find_path(q_spot, pawn.feet(), 200000)
	var worst := 0.0
	for p in path:
		worst = maxf(worst, absf(_over_ground(p)))
	_check("a path from the squad to the player round the curve", path.size() > 2
			and path[path.size() - 1].distance_to(pawn.feet()) < 1.5, "%d points" % path.size())
	_check("the path is on the ground (within a plate, %.3f m)" % plate, path.size() > 2 and worst <= plate,
			"worst %.3f m" % worst)
	# The ground's colliders where the squad is set down, before it is: a body
	# dropped on ground not streamed yet falls into the planet.
	var marker := Node3D.new()
	add_child(marker)
	marker.global_position = q_spot
	PlanetBody.track(marker)
	t0 = Time.get_ticks_msec()
	while _ground_hit(q_spot) == Vector3.INF and Time.get_ticks_msec() - t0 < 30000:
		await _frames(1)
	await get_tree().create_timer(0.5).timeout
	_check("the ground streams in where the squad is set down", _ground_hit(q_spot) != Vector3.INF)
	var lib := GunPlaceholderParts.build_library()
	var up_q := Gravity.up_at(q_spot)
	var side := Gravity.flat(p_feet - q_spot, up_q).normalized().cross(up_q)
	var members: Array[Soldier] = []
	for i in 4:
		var at := ai.ai_nav.snap(q_spot + side * (i - 1.5) * 1.4 + up_q * 0.3)
		var gun := GunInstance.from_result(GunGenerator.generate(lib, 50 + i, WeaponClass.builtin(&"rifle"), 1))
		var so := Soldier.spawn(ai, self, at + Gravity.up_at(at) * 0.1, 1, gun)
		PlanetBody.track(so.pawn.body)
		members.append(so)
	var q := Squad.make(ai, self, members, 1)
	var start := INF
	for m in members:
		start = minf(start, m.pawn.feet().distance_to(pawn.feet()))
	var nearest := start
	var ordered := false
	var ticks := 0
	var floor_ticks := 0
	var body_ticks := 0
	var sunk := 0.0
	var covered := 0
	var fired_at := -1.0
	var t1 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t1 < 60000:
		await get_tree().physics_frame
		ticks += 1
		if not ordered and q.contact() != null:
			var o := SquadMsg.Order.make(SquadMsg.OrderKind.ADVANCE)
			o.point = pawn.feet()
			q.give(o)
			ordered = true
		var shots := 0
		for m in q.alive():
			var f := m.pawn.feet()
			nearest = minf(nearest, f.distance_to(pawn.feet()))
			body_ticks += 1
			if m.pawn.body.is_on_floor():
				floor_ticks += 1
			sunk = minf(sunk, _over_ground(f))
			shots += m.shots
			# In cover: still, with bricks between the player's eye and its chest
			# (a bound ends on a CoverSearch spot; a soldier's own cover tactic too).
			var still := Gravity.flat(m.pawn.body.velocity, m.pawn.up).length() < 0.3
			if still and ai.ai_world.bricks_between(pawn.eye.global_position, f + m.pawn.up * 1.1) > 0:
				covered += 1
		if shots > 0 and fired_at < 0.0:
			fired_at = (Time.get_ticks_msec() - t1) / 1000.0
		if start - nearest >= 15.0 and fired_at >= 0.0 and covered >= 60:
			break
	var states := {}
	for m in members:
		states[m.state] = int(states.get(m.state, 0)) + 1
	print("[planet] squad: %s; play %s; %d of %d alive" % [states, q.play, q.alive().size(), members.size()])
	_check("the squad sees the player and is ordered on", ordered)
	_check("it walks to the player round the curve (closes >= 15 m)", start - nearest >= 15.0,
			"%.1f m -> %.1f m" % [start, nearest])
	_check("its feet on the ground on the way (> 90% of body-ticks)", floor_ticks > body_ticks * 0.9,
			"%d of %d" % [floor_ticks, body_ticks])
	_check("nobody falls through the planet (never > 0.5 m under the ground)", sunk > -0.5, "%.2f m" % sunk)
	_check("it takes cover (still, hidden from the player)", covered >= 60, "%d member-ticks" % covered)
	_check("it fires at the player", fired_at >= 0.0, "first at %.1f s" % fired_at)
	await _shot("planet_squad")
	print("[planet] frames: worst %.1f ms; over 40 ms: %s" % [_worst_ms, _hitches])
	print("[planet] squad gate: %d ok, %d FAIL" % [_ok, _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# The travel gate (11.8 N4): a squad of four, on the player's side, ordered to a
# point 200 m out of the town, walks it on the nav net -- across the borders of
# regions made round it as it goes.

func _run_travel_gate() -> void:
	var t0 := Time.get_ticks_msec()
	while pawn == null and Time.get_ticks_msec() - t0 < 60000:
		await _frames(1)
	await get_tree().create_timer(1.0).timeout
	var town: Vector3 = town_dirs[0]
	var p_feet := _surface(_round_dir(town, spawn_dir, 88.0))
	var q_spot := _surface(_round_dir(town, spawn_dir, 80.0))
	var goal := _surface(_round_dir(town, spawn_dir, 280.0))
	pawn.place(p_feet + Gravity.up_at(p_feet) * 0.3)
	pawn.health.layer_configs[0].max_value = 1e7
	pawn.health.reset()
	var marker := Node3D.new()
	add_child(marker)
	marker.global_position = q_spot
	PlanetBody.track(marker)
	t0 = Time.get_ticks_msec()
	while (_ground_hit(p_feet) == Vector3.INF or _ground_hit(q_spot) == Vector3.INF) \
			and Time.get_ticks_msec() - t0 < 30000:
		await _frames(1)
	await get_tree().create_timer(1.0).timeout
	setup_ai(town)
	var net := ai.nav_net as PlanetNavNet
	pawn.set_meta(&"player", 0)
	ai.add_pawn(pawn)
	var plate := BrickWorld.get_plate_metres()
	# The net's own path first.
	var path := net.find_path(q_spot, goal, 200000)
	var worst := 0.0
	var crossed := 0
	var last := net.key_at(q_spot)
	for p in path:
		worst = maxf(worst, absf(_over_ground(p)))
		var k := net.key_at(p)
		if k != last:
			crossed += 1
			last = k
	var worst_join := 0.0
	for j in net.last_joins:
		worst_join = maxf(worst_join, j)
	_check("a path 200 m out of the town on the nav net", path.size() > 2
			and path[path.size() - 1].distance_to(goal) < 1.5, "%d points" % path.size())
	_check("across the regions' borders (>= 2)", crossed >= 2, "%d" % crossed)
	_check("its stretches meet at the borders (<= 0.36 m)", worst_join <= 0.36, "%.3f m" % worst_join)
	_check("on the ground (within 1.5 plates)", path.size() > 2 and worst <= plate * 1.5, "worst %.3f m" % worst)
	var lib := GunPlaceholderParts.build_library()
	var up_q := Gravity.up_at(q_spot)
	var side := Gravity.flat(goal - q_spot, up_q).normalized().cross(up_q)
	var members: Array[Soldier] = []
	for i in 4:
		var at := ai.ai_nav.snap(q_spot + side * (i - 1.5) * 1.4 + up_q * 0.3)
		var gun := GunInstance.from_result(GunGenerator.generate(lib, 70 + i, WeaponClass.builtin(&"rifle"), 1))
		var so := Soldier.spawn(ai, self, at + Gravity.up_at(at) * 0.1, 0, gun)
		PlanetBody.track(so.pawn.body)
		members.append(so)
	var q := Squad.make(ai, self, members, 0)
	await get_tree().create_timer(0.5).timeout
	var o := SquadMsg.Order.make(SquadMsg.OrderKind.MOVE)
	o.point = goal
	var order_id := q.give(o)
	var made0 := net.regions_made
	var ticks := 0
	var floor_ticks := 0
	var body_ticks := 0
	var sunk := 0.0
	var report: Variant = null
	var keys := {}
	var t1 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t1 < 150000:
		await get_tree().physics_frame
		ticks += 1
		for m in q.alive():
			body_ticks += 1
			if m.pawn.body.is_on_floor():
				floor_ticks += 1
			sunk = minf(sunk, _over_ground(m.pawn.feet()))
			keys[net.key_at(m.pawn.feet())] = true
		for r in q.reports:
			if r.order_id == order_id and r.kind != SquadMsg.ReportKind.ACCEPTED:
				report = r
		if report != null:
			break
	var secs := (Time.get_ticks_msec() - t1) / 1000.0
	var near := 0
	var nearest := INF
	for m in q.alive():
		var d := Gravity.flat(m.pawn.feet() - goal, Gravity.up_at(goal)).length()
		nearest = minf(nearest, d)
		if d < 12.0:
			near += 1
	print("[planet] travel: %s after %.0f s; %d of %d within 12 m (nearest %.1f m); %d cell(s) walked, %d region(s) made on the way, %d dropped" % [
			report, secs, near, members.size(), nearest, keys.size(), net.regions_made - made0, net.regions_dropped])
	_check("the squad gets there: MOVE reported DONE", report != null and report.kind == SquadMsg.ReportKind.DONE,
			str(report))
	_check("all of it (>= 3 of 4 within 12 m)", near >= 3, "%d" % near)
	_check("through several regions (>= 3 cells walked)", keys.size() >= 3, "%d" % keys.size())
	_check("regions made round it as it went", net.regions_made > made0, "%d" % (net.regions_made - made0))
	_check("its feet on the ground on the way (> 90% of body-ticks)", floor_ticks > body_ticks * 0.9,
			"%d of %d" % [floor_ticks, body_ticks])
	_check("nobody falls through the planet (never > 0.5 m under the ground)", sunk > -0.5, "%.2f m" % sunk)
	print("[planet] frames: worst %.1f ms; over 40 ms: %s" % [_worst_ms, _hitches])
	print("[planet] nav net service: worst %.1f ms %s (builds, region queues, routes, legs; us)" % [
			net.worst_service_us / 1000.0, net.worst_service_parts])
	print("[planet] AI tick: worst %.1f ms (keep_around %.1f, net %.1f, scheduler and services %.1f)" % [
			ai_worst_us / 1000.0, ai_worst_parts[0] / 1000.0, ai_worst_parts[1] / 1000.0, ai_worst_parts[2] / 1000.0])
	print("[planet] travel gate: %d ok, %d FAIL" % [_ok, _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# The far gate (11.8): a fight away from the player. Two squads -- one on the
# player's side, one against it -- meet on the town's far side, ~170 m from the
# player and in another region. What they see, hide behind and walk on is their
# own region's (AIServices.focus): the player's region has no ground there.

func _run_far_gate() -> void:
	var t0 := Time.get_ticks_msec()
	while pawn == null and Time.get_ticks_msec() - t0 < 60000:
		await _frames(1)
	await get_tree().create_timer(1.0).timeout
	var town: Vector3 = town_dirs[0]
	var e := Gravity.flat(spawn_dir - town, town).normalized()
	var p_feet := _surface(_round_dir(town, spawn_dir, 88.0))
	var a_spot := _surface(_round_dir(town, town - e, 80.0))
	var b_spot := _surface(_round_dir(town, town - e, 112.0))
	pawn.place(p_feet + Gravity.up_at(p_feet) * 0.3)
	pawn.health.layer_configs[0].max_value = 1e7
	pawn.health.reset()
	for at in [a_spot, b_spot]:
		var marker := Node3D.new()
		add_child(marker)
		marker.global_position = at
		PlanetBody.track(marker)
	t0 = Time.get_ticks_msec()
	while (_ground_hit(p_feet) == Vector3.INF or _ground_hit(a_spot) == Vector3.INF
			or _ground_hit(b_spot) == Vector3.INF) and Time.get_ticks_msec() - t0 < 30000:
		await _frames(1)
	await get_tree().create_timer(1.0).timeout
	setup_ai(town)
	ai.policy = CombatPolicy.new()
	var net := ai.nav_net as PlanetNavNet
	pawn.set_meta(&"player", 0)
	ai.add_pawn(pawn)
	net.keep_around([a_spot, b_spot], AI_KEEP_M, 99)
	var kp := net.key_at(p_feet)
	var ka := net.key_at(a_spot)
	var kb := net.key_at(b_spot)
	print("[planet] far: player in %s, the squads in %s and %s, %.0f m off" % [kp, ka, kb, p_feet.distance_to(a_spot)])
	_check("the fight is in another region than the player's", ka != kp and kb != kp)
	var here: AINav = net.regions[kp].nav
	_check("where the player's region has no ground to stand on", not here.can_stand(a_spot)
			and net.nav_at(a_spot).can_stand(net.nav_at(a_spot).snap(a_spot)))
	var lib := GunPlaceholderParts.build_library()
	var sides: Array = []
	for team in [0, 1]:
		var at: Vector3 = a_spot if team == 0 else b_spot
		var other: Vector3 = b_spot if team == 0 else a_spot
		var up := Gravity.up_at(at)
		var side := Gravity.flat(other - at, up).normalized().cross(up)
		var members: Array[Soldier] = []
		for i in 4:
			var feet := net.snap(at + side * (i - 1.5) * 1.4 + up * 0.3)
			var gun := GunInstance.from_result(GunGenerator.generate(lib, 90 + team * 10 + i,
					WeaponClass.builtin(&"rifle"), 1))
			var so := Soldier.spawn(ai, self, feet + Gravity.up_at(feet) * 0.1, team, gun)
			PlanetBody.track(so.pawn.body)
			members.append(so)
		sides.append({"squad": Squad.make(ai, self, members, team), "members": members,
				"ordered": false, "covered": 0, "seen": false})
	var ticks := 0
	var floor_ticks := 0
	var body_ticks := 0
	var sunk := 0.0
	var t1 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t1 < 60000:
		await get_tree().physics_frame
		ticks += 1
		var all_done := true
		for k in 2:
			var sd: Dictionary = sides[k]
			var q: Squad = sd.squad
			var c := q.contact()
			if c != null:
				sd.seen = true
				if not sd.ordered:
					var o := SquadMsg.Order.make(SquadMsg.OrderKind.ADVANCE)
					o.point = c.pos
					q.give(o)
					sd.ordered = true
			var foe: Dictionary = sides[1 - k]
			for m in q.alive():
				var f := m.pawn.feet()
				body_ticks += 1
				if m.pawn.body.is_on_floor():
					floor_ticks += 1
				sunk = minf(sunk, _over_ground(f))
				var still := Gravity.flat(m.pawn.body.velocity, m.pawn.up).length() < 0.3
				var w := net.world_at(f)
				if still and w != null:
					for fm in (foe.squad as Squad).alive():
						if fm.pawn.eye.global_position.distance_to(f) < 60.0 								and w.bricks_between(fm.pawn.eye.global_position, f + m.pawn.up * 1.1) > 0:
							sd.covered += 1
							break
			var shots := 0
			for m in (sd.members as Array):
				if is_instance_valid(m):
					shots += (m as Soldier).shots
			sd["shots"] = shots
			if not (sd.seen and shots > 0 and int(sd.covered) >= 60):
				all_done = false
		if all_done:
			break
	var hurt := 0
	for k in 2:
		for m in (sides[k].members as Array):
			if not is_instance_valid(m) or (m as Soldier).is_dead() 					or (m as Soldier).pawn.health.total_current() < (m as Soldier).max_health:
				hurt += 1
	for k in 2:
		var sd: Dictionary = sides[k]
		var who := "ours" if k == 0 else "theirs"
		print("[planet] far: %s -- seen %s, %d round(s), %d member-ticks in cover, %d of 4 alive" % [
				who, sd.seen, int(sd.get("shots", 0)), int(sd.covered), (sd.squad as Squad).alive().size()])
		_check("%s see the other side" % who, bool(sd.seen))
		_check("%s fire on it" % who, int(sd.get("shots", 0)) > 0, "%d round(s)" % int(sd.get("shots", 0)))
		_check("%s take cover (still, bricks between them and the other side's eyes)" % who,
				int(sd.covered) >= 60, "%d member-ticks" % int(sd.covered))
	_check("rounds land: somebody is hurt", hurt > 0, "%d" % hurt)
	_check("feet on the ground (> 90% of body-ticks)", floor_ticks > body_ticks * 0.9,
			"%d of %d" % [floor_ticks, body_ticks])
	_check("nobody falls through the planet (never > 0.5 m under the ground)", sunk > -0.5, "%.2f m" % sunk)
	print("[planet] frames: worst %.1f ms; over 40 ms: %s" % [_worst_ms, _hitches])
	print("[planet] AI tick: worst %.1f ms" % (ai_worst_us / 1000.0))
	print("[planet] far gate: %d ok, %d FAIL" % [_ok, _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# The drive gate (11.8): an AI tank, crewed, on the player's side, sent 200 m out
# of the town. Its road is the nav net's tank map (AIServices.vehicle_nav on a
# planet: a PlanetNavMap, its own AINav in each region), across the borders.

func _run_drive_gate() -> void:
	var t0 := Time.get_ticks_msec()
	while pawn == null and Time.get_ticks_msec() - t0 < 60000:
		await _frames(1)
	await get_tree().create_timer(1.0).timeout
	var town: Vector3 = town_dirs[0]
	var p_feet := _surface(_round_dir(town, spawn_dir, 88.0))
	var start := _surface(_round_dir(town, spawn_dir, 100.0))
	var goal := _surface(_round_dir(town, spawn_dir, 300.0))
	pawn.place(p_feet + Gravity.up_at(p_feet) * 0.3)
	pawn.health.layer_configs[0].max_value = 1e7
	pawn.health.reset()
	var marker := Node3D.new()
	add_child(marker)
	marker.global_position = start
	PlanetBody.track(marker)
	t0 = Time.get_ticks_msec()
	while (_ground_hit(p_feet) == Vector3.INF or _ground_hit(start) == Vector3.INF) \
			and Time.get_ticks_msec() - t0 < 30000:
		await _frames(1)
	await get_tree().create_timer(1.0).timeout
	setup_ai(town)
	var net := ai.nav_net as PlanetNavNet
	pawn.set_meta(&"player", 0)
	ai.add_pawn(pawn)
	var vn = ai.vehicle_nav(&"tank")
	_check("on a planet the tank's map is the nav net's", vn is PlanetNavMap)
	var at: Vector3 = vn.snap(start)
	var lib := GunPlaceholderParts.build_library()
	var main := GunInstance.from_result(GunGenerator.generate(lib, 5, WeaponClass.builtin(&"rocket_launcher"), 1))
	var mg := GunInstance.from_result(GunGenerator.generate(lib, 6, WeaponClass.builtin(&"lmg"), 1))
	var face := Gravity.flat(goal - at, Gravity.up_at(at))
	var tk := Tank.make(ai, self, at + Gravity.up_at(at) * 0.3, 0.0, 0, main, mg, Callable(), ai.rng)
	PlanetBody.track(tk)
	ai.add_pawn(tk.make_target())
	var br := TankBrain.attach(ai, tk)
	for seat in [Tank.Seat.DRIVER, Tank.Seat.GUNNER]:
		var so := Soldier.spawn(ai, self, at + Gravity.up_at(at) * 0.3 + face.normalized().cross(Gravity.up_at(at)) * 5.0,
				0, GunInstance.from_result(GunGenerator.generate(lib, 60 + seat, WeaponClass.builtin(&"rifle"), 1)))
		PlanetBody.track(so.pawn.body)
		tk.board(so.pawn, seat, true)
	await get_tree().create_timer(2.0).timeout
	br.send(goal)
	var keys := {}
	var sunk := 0.0
	var roads := {}
	var t1 := Time.get_ticks_msec()
	var left := INF
	while Time.get_ticks_msec() - t1 < 150000:
		await get_tree().physics_frame
		var f := tk.feet()
		keys[net.key_at(f)] = true
		sunk = minf(sunk, _over_ground(f))
		roads[br.road] = true
		left = Gravity.flat(goal - f, Gravity.up_at(goal)).length()
		if left < 8.0 and br.state in ["hold", "idle"]:
			break
	var secs := (Time.get_ticks_msec() - t1) / 1000.0
	print("[planet] drive: %.1f m short after %.0f s, state %s, roads %s, %d cell(s), %d region(s) now" % [
			left, secs, br.state, roads.keys(), keys.size(), net.regions.size()])
	_check("the tank gets there (< 8 m)", left < 8.0, "%.1f m short, %s" % [left, br.state])
	_check("on the tank's own map (its road the vehicle map)", roads.has("vehicle") and not roads.has("foot"),
			str(roads.keys()))
	_check("across the regions (>= 3 cells driven)", keys.size() >= 3, "%d" % keys.size())
	_check("never under the ground (> -1 m)", sunk > -1.0, "%.2f m" % sunk)
	print("[planet] frames: worst %.1f ms; over 40 ms: %s" % [_worst_ms, _hitches])
	print("[planet] AI tick: worst %.1f ms" % (ai_worst_us / 1000.0))
	print("[planet] drive gate: %d ok, %d FAIL" % [_ok, _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# The trees gate (11.10): a tank, its tracks, knocks a tree down and drives on; a
# truck's body is stopped by a trunk; walkers and rounds still meet trunks.

func _run_trees_gate() -> void:
	var t0 := Time.get_ticks_msec()
	while pawn == null and Time.get_ticks_msec() - t0 < 60000:
		await _frames(1)
	await get_tree().create_timer(3.0).timeout
	var xf := planet.global_transform
	var near: Array = trees.nearest(xf.affine_inverse() * pawn.feet(), 1)
	_check("trees round the spawn", not near.is_empty())
	if near.is_empty():
		get_tree().quit(1)
		return
	# Stand by the tree, so its cell is solid and its ground streamed.
	var w1: Vector3 = xf * (near[0].at as Vector3)
	var up1 := Gravity.up_at(w1)
	var d := Gravity.flat(w1 - pawn.feet(), up1)
	d = d.normalized() if d.length() > 0.5 else Gravity.tangent_basis(w1).x
	var stand := _ground_hit(w1 - d * 18.0 + Gravity.tangent_basis(w1).z * 6.0 + up1 * 20.0)
	pawn.place((stand if stand != Vector3.INF else w1 - d * 18.0) + up1 * 0.3)
	t0 = Time.get_ticks_msec()
	while _ground_hit(w1 - d * 10.0 + up1 * 20.0) == Vector3.INF and Time.get_ticks_msec() - t0 < 20000:
		await _frames(1)
	await get_tree().create_timer(1.5).timeout
	var hit := get_world_3d().direct_space_state.intersect_ray(
			PhysicsRayQueryParameters3D.create(w1 - d * 3.0 + up1 * 1.0, w1 + d * 3.0 + up1 * 1.0, Layers.HITSCAN_MASK))
	_check("a round meets the trunk (FIXTURE, as before)", not hit.is_empty() and (hit.collider as Object).has_meta(&"on_vehicle"))
	# The tank: 10 m back from the tree, facing it, driven straight at it.
	var at := _ground_hit(w1 - d * 10.0 + up1 * 20.0)
	var tk := Tank.make(null, self, at + up1 * 0.3, 0.0, 0, null, null, Callable(), RandomNumberGenerator.new())
	PlanetBody.track(tk)
	await get_tree().create_timer(1.5).timeout
	var l := tk._local(d)
	tk.yaw = atan2(-l.x, -l.z)
	_check("the player takes the wheel", tk.take_player(0, Tank.Seat.DRIVER) and tk.driven())
	tk.throttle = 1.0
	var key: Vector3i = near[0].key
	var idx: int = near[0].index
	var t1 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t1 < 8000:
		await get_tree().physics_frame
		if trees.is_knocked(key, idx) and (tk.feet() - w1).dot(d) > 4.0:
			break
	tk.throttle = 0.0
	var past := (tk.feet() - w1).dot(d)
	_check("the tank knocks the tree down", trees.is_knocked(key, idx))
	_check("and drives on past where it stood (> 4 m)", past > 4.0, "%.1f m" % past)
	await get_tree().create_timer(PlanetTrees.FALL_S + 0.5).timeout
	var lying: Variant = trees.fallen_xf(key, idx)
	var lean := 90.0 if lying == null else rad_to_deg((lying as Transform3D).basis.y.normalized().angle_to(
			xf.affine_inverse().basis * up1))
	var toward := -1.0 if lying == null else (xf.basis * (lying as Transform3D).basis.y).normalized().dot(d)
	_check("it lies on the ground, away from the tank (85-95 deg over, top along its way)",
			lying != null and lean > 85.0 and lean < 95.0 and toward > 0.9, "%.1f deg, %.2f along" % [lean, toward])
	await _shot("planet_tree_knocked")
	# A truck's body: a trunk in its way stops it.
	var others: Array = trees.nearest(xf.affine_inverse() * pawn.feet(), 6, [[key, idx]])
	var stopped := false
	var tried := 0
	for o in others:
		var w2: Vector3 = xf * (o.at as Vector3)
		var up2 := Gravity.up_at(w2)
		var d2 := Gravity.flat(w2 - pawn.feet(), up2).normalized()
		var g2 := _ground_hit(w2 - d2 * 6.0 + up2 * 20.0)
		if g2 == Vector3.INF:
			continue
		tried += 1
		var body := CharacterBody3D.new()
		body.collision_layer = 0
		body.collision_mask = TransportTruck.BODY_MASK
		var cs := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(2.3, 1.2, 5.0)
		cs.shape = box
		body.add_child(cs)
		add_child(body)
		var basis := Gravity.tangent_basis(w2)
		var start := Transform3D(basis.looking_at(d2, up2), g2 + up2 * 1.4)
		body.global_transform = start
		await get_tree().physics_frame
		var col := KinematicCollision3D.new()
		var met := body.test_move(start, d2 * 12.0, col)
		var by_tree := met and col.get_collider() != null and (col.get_collider() as Object).has_meta(&"on_vehicle")
		body.queue_free()
		if by_tree:
			stopped = true
			break
	_check("a truck's body is stopped by a trunk (Layers.TREE)", stopped, "%d tried" % tried)
	print("[planet] trees: %d knocked; frames worst %.1f ms" % [trees.knocked_count, _worst_ms])
	print("[planet] trees gate: %d ok, %d FAIL" % [_ok, _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# The bricks gate (11.11): near the player the town's buildings are bricks --
# drawn by band, solid, the shell gone -- a building has a way in at the ground,
# and the AI's world has the bricks: the nav net's path goes in through it.

func _run_bricks_gate() -> void:
	var t0 := Time.get_ticks_msec()
	while pawn == null and Time.get_ticks_msec() - t0 < 60000:
		await _frames(1)
	var town: Vector3 = town_dirs[0]
	var p_feet := _surface(_round_dir(town, spawn_dir, 88.0))
	pawn.place(p_feet + Gravity.up_at(p_feet) * 0.3)
	t0 = Time.get_ticks_msec()
	while _ground_hit(p_feet) == Vector3.INF and Time.get_ticks_msec() - t0 < 30000:
		await _frames(1)
	setup_ai(town)
	var net := ai.nav_net as PlanetNavNet
	# Which buildings should be bricks: every one but a landmark within BRICK_M.
	var want: Array[int] = []
	for i in buildings.sites.size():
		var st: PlanetBuildings.Site = buildings.sites[i]
		if not st.landmark and cam.global_position.distance_to(planet.global_position + st.frame.origin) < PlanetBuildings.BRICK_M - 10.0:
			want.append(i)
	t0 = Time.get_ticks_msec()
	var all_in := false
	# Frame times over the brick-in, and 3 s after: what walking into town costs.
	# With -- --no-bricks the same 8 s with shells only, for the A/B.
	var frame_ms: Array[float] = []
	var last_us := Time.get_ticks_usec()
	var settle_until := -1
	# The renderer's own clock (a test window's frames are paced): GPU ms a frame,
	# over the settled window (all in, or the shells' last 3 s).
	var vp_rid := get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(vp_rid, true)
	var gpu_ms: Array[float] = []
	var cpu_ms: Array[float] = []
	while Time.get_ticks_msec() - t0 < 60000:
		await _frames(1)
		var now_us := Time.get_ticks_usec()
		frame_ms.append((now_us - last_us) / 1000.0)
		last_us = now_us
		if settle_until > 0 or (not buildings.bricks_on and Time.get_ticks_msec() - t0 > 5000):
			gpu_ms.append(RenderingServer.viewport_get_measured_render_time_gpu(vp_rid))
			cpu_ms.append(RenderingServer.viewport_get_measured_render_time_cpu(vp_rid))
		if not buildings.bricks_on:
			if Time.get_ticks_msec() - t0 > 8000:
				break
			continue
		if settle_until > 0:
			if Time.get_ticks_msec() > settle_until:
				break
			continue
		# Held where it stands: a long frame (an unwatched window's stall) can
		# drop a body through the voxel ground, and the bricks follow the camera.
		if _over_ground(pawn.feet()) < -0.5:
			pawn.place(p_feet + Gravity.up_at(p_feet) * 0.3)
		all_in = true
		for i in want:
			if not buildings.sites[i].bricked:
				all_in = false
				break
		if all_in and settle_until < 0:
			settle_until = Time.get_ticks_msec() + 3000
	var sorted := frame_ms.duplicate()
	sorted.sort()
	var over25 := 0
	var over40 := 0
	var sum := 0.0
	for f in frame_ms:
		sum += f
		if f > 25.0:
			over25 += 1
		if f > 40.0:
			over40 += 1
	print("[planet] frames over the brick-in%s: %d, mean %.1f ms, 95th %.1f, 99th %.1f, worst %.1f; over 25 ms %d, over 40 ms %d" % [
			"" if buildings.bricks_on else " (no bricks)", frame_ms.size(), sum / maxf(frame_ms.size(), 1),
			sorted[int(sorted.size() * 0.95)], sorted[int(sorted.size() * 0.99)], sorted[sorted.size() - 1], over25, over40])
	var g_sum := 0.0
	var c_sum := 0.0
	for g in gpu_ms:
		g_sum += g
	for c in cpu_ms:
		c_sum += c
	print("[planet] settled, the renderer: GPU %.1f ms, render CPU %.1f ms a frame (%d frames)" % [
			g_sum / maxf(gpu_ms.size(), 1), c_sum / maxf(cpu_ms.size(), 1), gpu_ms.size()])
	if not buildings.bricks_on:
		get_tree().quit(0)
		return
	var secs := (Time.get_ticks_msec() - t0) / 1000.0
	print("[planet] bricks: %d of %d buildings near in %.1f s; the worst brick step %.1f ms (%s)" % [
			buildings.bricked_count, want.size(), secs, buildings.brick_worst_us / 1000.0, buildings.brick_worst_what])
	_check("the buildings near the player are bricks", not want.is_empty() and all_in,
			"%d of %d in %.1f s" % [buildings.bricked_count, want.size(), secs])
	_check("brick work stays small a frame (< 12 ms)", buildings.brick_worst_us < 12000,
			"%.1f ms" % (buildings.brick_worst_us / 1000.0))
	if want.is_empty():
		get_tree().quit(1)
		return
	# The nearest of them.
	var bi: int = want[0]
	for i in want:
		if pawn.feet().distance_to(planet.global_position + buildings.sites[i].frame.origin) \
				< pawn.feet().distance_to(planet.global_position + buildings.sites[bi].frame.origin):
			bi = i
	var site: PlanetBuildings.Site = buildings.sites[bi]
	var bxf := planet.global_transform * site.frame
	var stud := BrickWorld.get_stud_metres()
	var w := site.fx * stud
	var dd := site.fz * stud
	_check("its shell is gone (only its shadow drawn, not solid)", site.shell == null
			or (site.shell.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY and site.body.collision_layer == 0))
	# A ray at the building: bricks, not the shell. Through the front door, so
	# it meets the staircase in the middle (or the back wall).
	var space := get_world_3d().direct_space_state
	var mid := bxf * Vector3(w * 0.5, 1.2, -3.0)
	var into := bxf * Vector3(w * 0.5, 1.2, dd * 0.9)
	var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(mid, into, Layers.STRUCTURE))
	_check("a ray at a wall meets its bricks", not hit.is_empty() and site.collision != null
			and site.collision.owns(hit.rid), str(hit.get("rid", "nothing")))
	# The AI: its world has the bricks, and the nav net walks in.
	# Just inside the brick the ray met.
	var wall_pt: Vector3 = (hit.position as Vector3) + (into - mid).normalized() * 0.1 if not hit.is_empty() else mid
	var aw := net.world_at(wall_pt)
	_check("the AI's world has its bricks (where the ray met a wall is solid)", aw != null and aw.solid_at(wall_pt))
	# The room the front door opens into.
	var inside_pt := net.snap(bxf * Vector3(w * 0.5, 0.3, 2.5))
	# Its front door (PlanetBuildings._cut_door): a ray through it at a metre
	# meets nothing; the nav net walks in through it to a ground-floor room.
	var door_out := bxf * Vector3(w * 0.5, 1.0, -1.5)
	var door_in := bxf * Vector3(w * 0.5, 1.0, 2.5)
	_check("a front door: a ray goes through it", space.intersect_ray(
			PhysicsRayQueryParameters3D.create(door_out, door_in, Layers.STRUCTURE)).is_empty())
	var path := net.find_path(pawn.feet(), inside_pt, 200000)
	var li := bxf.affine_inverse() * (path[path.size() - 1] if path.size() > 0 else Vector3.INF)
	var by_door := false
	for p in path:
		var lp := bxf.affine_inverse() * p
		if lp.z > -0.5 and lp.z < 1.0 and absf(lp.x - w * 0.5) < 1.5:
			by_door = true
	_check("the nav net walks in, to the room behind the door", path.size() > 2 and li.x > stud and li.x < w - stud
			and li.z > 2.0 * stud and li.z < dd - stud and absf(li.y) < 1.0, "%d points, ends at %s" % [path.size(), li])
	_check("through the door", by_door)
	# Up the stairs: a spot on the first floor beside the stairwell, and the nav
	# net's way to it from outside.
	var plate := BrickWorld.get_plate_metres()
	var floor1 := float(TowerRecipe.SLAB_PLATES + TowerRecipe.STOREY_PLATES) * plate
	var sx := TowerRecipe.stair_line(site.fx)
	var sz := TowerRecipe.stair_line(site.fz)
	var up_pt := Vector3.INF
	var shaft := StaircaseRecipe.DIAMETER
	for off in [Vector2i(-2, shaft / 2), Vector2i(shaft + 1, shaft / 2), Vector2i(shaft / 2, -2), Vector2i(shaft / 2, shaft + 1)]:
		var q := net.snap(bxf * Vector3((sx + off.x + 0.5) * stud, floor1 + 0.3, (sz + off.y + 0.5) * stud))
		var lq := bxf.affine_inverse() * q
		if net.can_stand(q) and absf(lq.y - floor1) < 0.5:
			up_pt = q
			break
	var up_path := net.find_path(pawn.feet(), up_pt, 200000) if up_pt != Vector3.INF else PackedVector3Array()
	var lu := bxf.affine_inverse() * (up_path[up_path.size() - 1] if up_path.size() > 0 else Vector3.INF)
	var climbed := 0.0
	for p in up_path:
		climbed = maxf(climbed, (bxf.affine_inverse() * p).y)
	_check("a staircase: the nav net walks up to the first floor", up_pt != Vector3.INF and up_path.size() > 2
			and absf(lu.y - floor1) < 0.5, "%d points, up to %.2f m (the floor %.2f m)" % [up_path.size(), climbed, floor1])
	await _shot("planet_bricks_town")
	print("[planet] frames: worst %.1f ms; over 40 ms: %s" % [_worst_ms, _hitches])
	print("[planet] bricks gate: %d ok, %d FAIL" % [_ok, _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# The damage gate (11.11 D1): the town in bricks, then a rifle's rounds at a wall
# until a brick goes, and a charge at another wall. What the bricks lost is gone
# from the collision, the drawing and the AI's world; the charge's hole is a way in.

func _run_damage_gate() -> void:
	var t0 := Time.get_ticks_msec()
	while pawn == null and Time.get_ticks_msec() - t0 < 60000:
		await _frames(1)
	var town: Vector3 = town_dirs[0]
	var p_feet := _surface(_round_dir(town, spawn_dir, 88.0))
	pawn.place(p_feet + Gravity.up_at(p_feet) * 0.3)
	t0 = Time.get_ticks_msec()
	while _ground_hit(p_feet) == Vector3.INF and Time.get_ticks_msec() - t0 < 30000:
		await _frames(1)
	setup_ai(town)
	var net := ai.nav_net as PlanetNavNet
	# The nearest building, once it is bricks.
	var bi := -1
	t0 = Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 60000:
		await _frames(1)
		if _over_ground(pawn.feet()) < -0.5:
			pawn.place(p_feet + Gravity.up_at(p_feet) * 0.3)
		var best := INF
		bi = -1
		for i in buildings.sites.size():
			var st: PlanetBuildings.Site = buildings.sites[i]
			var d := pawn.feet().distance_to(planet.global_position + st.frame.origin)
			if not st.landmark and d < best:
				best = d
				bi = i
		if bi >= 0 and buildings.sites[bi].bricked and buildings.sites[bi].band_jobs.is_empty():
			break
	var site: PlanetBuildings.Site = buildings.sites[bi]
	_check("the nearest building is bricks", site.bricked)
	_check("the player's gun and the AI's break the planet's bricks", gun.on_structure_hit.is_valid()
			and ai.on_structure_hit.is_valid() and ai.on_breach.is_valid())
	var bxf := planet.global_transform * site.frame
	var stud := BrickWorld.get_stud_metres()
	var w := site.fx * stud
	var dd := site.fz * stud
	var space := get_world_3d().direct_space_state
	# Rounds: a rifle's, at the -Z wall a stud right of the door's edge, 1.2 m up.
	# The first spot along the wall where a ray meets a brick in the wall's own
	# plane (not a window: through one it meets the room's far side).
	var from := Vector3.ZERO
	var to := Vector3.ZERO
	var hit := {}
	var tried := []
	for fx in [0.25, 0.2, 0.3, 0.15, 0.35, 0.1]:
		for fy in [0.6, 1.2, 2.0]:
			from = bxf * Vector3(w * fx, fy, -4.0)
			to = bxf * Vector3(w * fx, fy, dd * 0.5)
			hit = space.intersect_ray(PhysicsRayQueryParameters3D.create(from, to, Layers.STRUCTURE))
			var lz := 99.0 if hit.is_empty() else (bxf.affine_inverse() * (hit.position as Vector3)).z
			tried.append("%.2f/%.1f:%.2f" % [fx, fy, lz])
			if not hit.is_empty() and lz < stud * 1.5:
				break
			hit = {}
		if not hit.is_empty():
			break
	var dir := (to - from).normalized()
	_check("a ray at the wall meets its bricks", not hit.is_empty() and site.collision.owns(hit.rid),
			"" if not hit.is_empty() else " ".join(tried))
	if hit.is_empty():
		get_tree().quit(1)
		return
	var at: Vector3 = hit.position
	var shot := StructuralDamage.for_shot(WeaponClass.builtin(&"rifle"))
	var killed0 := buildings.bricks_killed
	var rounds := 0
	var band0 := 0
	var aw := net.world_at(at)
	var solid0 := aw.solid_at(at + dir * 0.1)
	while rounds < 200 and buildings.bricks_killed == killed0:
		_structure_hit(at + dir * 0.05, dir, shot)
		rounds += 1
	_check("a rifle's rounds wear a brick out", buildings.bricks_killed > killed0,
			"%d brick(s) after %d round(s), %d hp a round" % [buildings.bricks_killed - killed0, rounds, int(shot.hp)])
	var bands: Array = site.remesh.duplicate()
	for b in bands:
		if site.band_nodes.has(b):
			band0 = (site.band_nodes[b] as Node).get_instance_id()
	await _frames(20)
	_check("the AI's world has lost it (no longer solid there)", solid0 and not aw.solid_at(at + dir * 0.1))
	var hit2 := space.intersect_ray(PhysicsRayQueryParameters3D.create(from, to, Layers.STRUCTURE))
	var deeper := hit2.is_empty() or (hit2.position as Vector3).distance_to(from) > at.distance_to(from) + 0.1
	_check("and the collision (a ray goes further in)", deeper,
			"from %.2f m to %s" % [at.distance_to(from), "through" if hit2.is_empty() else "%.2f m" % (hit2.position as Vector3).distance_to(from)])
	var redrawn: bool = site.remesh.is_empty() and site.band_jobs.is_empty() and band0 != 0 \
			and site.band_nodes.has(bands[0]) and (site.band_nodes[bands[0]] as Node).get_instance_id() != band0
	_check("its band is drawn again", redrawn, "bands %s" % [bands])
	# A charge: at the middle of the +X wall, a metre up -- no door there.
	var c_out := bxf * Vector3(w + 3.0, 0.3, dd * 0.5)
	var c_at := bxf * Vector3(w - stud * 0.5, 1.0, dd * 0.5)
	var c_in := net.snap(bxf * Vector3(w - 2.5, 0.3, dd * 0.5))
	var before := net.find_path(net.snap(c_out), c_in, 60000)
	var k1 := buildings.bricks_killed
	buildings.damage(c_at, {"blast": true, "radius": 1.6, "hp": 0})
	await _frames(20)
	_check("a charge blows bricks out of the wall", buildings.bricks_killed - k1 >= 8, "%d" % (buildings.bricks_killed - k1))
	var after := net.find_path(net.snap(c_out), c_in, 200000)
	var through := false
	# A leg of the path that crosses the +X wall's plane by the hole.
	for k in range(1, after.size()):
		var a := bxf.affine_inverse() * after[k - 1]
		var b := bxf.affine_inverse() * after[k]
		if (a.x - w) * (b.x - w) <= 0.0 and absf(a.x - b.x) > 0.001:
			var z := lerpf(a.z, b.z, (w - a.x) / (b.x - a.x))
			if absf(z - dd * 0.5) < 2.0:
				through = true
	_check("and its hole is a way in: the nav net walks through it", after.size() > 2 and through,
			"%d points (before: %d)" % [after.size(), before.size()])
	var hole := space.intersect_ray(PhysicsRayQueryParameters3D.create(c_at + bxf.basis.x.normalized() * 2.0,
			c_at - bxf.basis.x.normalized() * 1.0, Layers.STRUCTURE))
	_check("and the collision has the hole", hole.is_empty())
	await _shot("planet_damage")
	print("[planet] damage: %d bricks killed; frames worst %.1f ms" % [buildings.bricks_killed, _worst_ms])
	print("[planet] damage gate: %d ok, %d FAIL" % [_ok, _fail])
	get_tree().quit(0 if _fail == 0 else 1)
