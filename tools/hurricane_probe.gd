extends SceneTree

## The hurricane on the heightfield coast (Docs/Disasters.md 18).
##
##     godot --headless --path . --script res://tools/hurricane_probe.gd
##
## The sea rises by the surge at the storm's height and goes back to exactly
## where it was; the waves grow and shrink with it; more ground is wet at the
## peak; the wind leans on a walker, turns round after the eye, and stops;
## lightning flashes; the director here offers only what needs no buildings.

var _passed := 0
var _failed := 0


func _initialize() -> void:
	_run.call_deferred()


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_passed += 1
	else:
		_failed += 1
	print("  %s %s%s" % ["ok  " if cond else "FAIL", what, ("  " + detail) if detail != "" else ""])


func _ticks(n: int) -> void:
	for i in n:
		await physics_frame


func _run() -> void:
	print("hurricane probe")
	var scene: Node3D = load("res://scenes/heightfield_test.tscn").instantiate()
	root.add_child(scene)
	await _ticks(20)
	var dir: DisasterDirector = scene.disasters
	_ok("the heightfield scene has a director", dir != null)
	if dir == null:
		_finish(scene)
		return
	_ok("offering only the hurricane: no buildings here to hit", dir.roll == ["hurricane"],
			str(dir.roll))
	var sea = scene._sea
	var base_level := BrickWave.get_sea_level()
	var base_gain: float = sea.wave_gain
	var base_wet: int = sea._wet_count
	var t0 := Time.get_ticks_usec()
	sea.refresh_seabed()
	var refresh_ms := (Time.get_ticks_usec() - t0) / 1000.0

	# A walker on land, to be leaned on -- except for pictures, which want the
	# scene's own view over the coast held still.
	var cam: DebugCamera = scene.camera
	var shots := "--hurricane-shot" in OS.get_cmdline_user_args()
	if shots:
		await _ticks(10)
		await _shot("calm")
		await _land_shot(cam, "land_dry")
	else:
		cam.set_walking(true)
		await _ticks(30)
	_ok("a hurricane starts", dir.start("hurricane", 1.0))
	var h: Hurricane = dir.current
	var h_active := h.active_s
	var shot_taken := false
	var eye_shot := false
	var peak := 0.0
	var peak_gain := 0.0
	var peak_wet := 0
	var peak_wind := 0.0
	var peak_soak := 0.0
	var peak_gale := 0.0
	var peak_rain := 0.0
	var peak_surf := 0
	var splash_points := 0
	var before_eye := Vector3.ZERO
	var after_eye := Vector3.ZERO
	var eye := false
	var eye_calm := INF
	var drift := 0.0
	var from := Vector3.INF
	var flashes := 0
	var raining := false
	var ticks := 0
	while dir.is_running() and ticks < 30 * 150:
		await physics_frame
		ticks += 1
		if not is_instance_valid(h):
			continue
		peak = maxf(peak, BrickWave.get_sea_level() - base_level)
		peak_gain = maxf(peak_gain, sea.wave_gain)
		peak_wet = maxi(peak_wet, sea._wet_count)
		peak_wind = maxf(peak_wind, h.wind.length())
		peak_soak = maxf(peak_soak, float(scene._brick_material().get_shader_parameter("weather_wet")))
		peak_gale = maxf(peak_gale, dir.ctx.gale.length())
		peak_rain = maxf(peak_rain, WeatherFx.rain)
		peak_surf = maxi(peak_surf, h.peak_surf)
		var rs = h.get_node_or_null("RainSplash")
		if rs != null:
			splash_points = maxi(splash_points, (rs as RainSplash).points)
		flashes = h.flashes
		raining = raining or dir.ctx.raining
		if h.phase == Disaster.Phase.ACTIVE:
			var u := h.phase_t / h.active_s
			# The height of it, and then the eye.
			if shots and not shot_taken and u > 0.33:
				shot_taken = true
				await _shot("storm")
				await _land_shot(cam, "land_wet")
				await _wall_shot(cam, scene)
			if shots and not eye_shot and h.in_eye() and h.phase_t > h.active_s * 0.5:
				eye_shot = true
				await _shot("eye")
			if u > 0.3 and u < 0.4:
				before_eye = h.wind
			if h.in_eye():
				eye = true
				eye_calm = minf(eye_calm, h.wind.length())
			if u > 0.62 and u < 0.7:
				after_eye = h.wind
			# The walker, over two seconds at the height of it.
			if u > 0.25 and u < 0.32:
				if from == Vector3.INF:
					from = cam.global_position
				drift = Vector2(cam.global_position.x - from.x, cam.global_position.z - from.z).length()
	await _ticks(6)   # the context eases wet and wind per frame; give it a few
	_ok("it runs its course", not dir.is_running(), "%.0f s" % (ticks / 30.0))
	_ok("the sea rises by the surge", peak > Hurricane.SURGE_M * 0.6 and peak <= Hurricane.SURGE_M + 0.01,
			"+%.2f m at the peak" % peak)
	_ok("and more of the ground is under it", peak_wet >= base_wet and peak > 0.0,
			"%d wet cell(s), %d before" % [peak_wet, base_wet])
	_ok("the waves grow", peak_gain > base_gain * 1.8, "gain %.2f -> %.2f" % [base_gain, peak_gain])
	_ok("the wind leans on a walker", shots or drift > 1.0, "%.1f m over %.1f s, wind up to %.1f m/s" % [drift,
			h_active * 0.07, peak_wind])
	_ok("the eye passes: calm", eye and eye_calm < peak_wind * 0.2, "%.2f m/s in it" % eye_calm)
	_ok("and the wind comes back from the other side", before_eye.dot(after_eye) < 0.0,
			"%s then %s" % [before_eye, after_eye])
	_ok("rain, and lightning in the cloud", raining and flashes > 0, "%d flash(es)" % flashes)
	_ok("the sea is back exactly where it was", BrickWave.get_sea_level() == base_level
			and sea.wave_gain == base_gain and sea._wet_count == base_wet,
			"%.3f / %.3f, gain %.2f" % [BrickWave.get_sea_level(), base_level, sea.wave_gain])
	# Wet, and swaying (Docs/Disasters.md 19).
	var ground_wet := float(TerrainTile.instance_material().get_shader_parameter("weather_wet"))
	_ok("everything gets wet in the rain: bricks, the ground's pieces, the terrain",
			peak_soak > 0.9 and WeatherFx.is_registered(TerrainTile.instance_material())
			and WeatherFx.is_registered(scene._mat), "bricks %.2f at the peak" % peak_soak)
	_ok("and dries slowly after it", dir.ctx.wet > 0.5 and dir.ctx.wet < 1.0 and ground_wet > 0.5,
			"%.2f just after" % dir.ctx.wet)
	var swaying := 0
	if scene._trees != null:
		for set in scene._trees.get_children():
			if set is ImpostorLod and (set as ImpostorLod).sway.x > 0.0:
				swaying += 1
	var grass := 0
	for tile in scene._tiles:
		var tufts = tile.get_node_or_null("Tufts")
		if tufts != null and (tufts.get_instance_shader_parameter("weather_sway") as Vector3).x > 0.0:
			grass += 1
	_ok("rain falls on the surfaces while it rains (ripples, running streaks), and stops",
			peak_rain > 0.9 and WeatherFx.rain < peak_rain, "%.2f at the height, %.2f after" % [peak_rain,
			WeatherFx.rain])
	_ok("the grass is set to move in the wind", grass > 0, "%d tile(s) of tufts" % grass)
	_ok("the rain splashes where it lands -- ground, roofs, water", splash_points > RainSplash.RAYS / 2,
			"%d of %d rays found somewhere to land" % [splash_points, RainSplash.RAYS])
	_ok("surf sprays where the waves meet the shore", peak_surf > 0,
			"%d shore stretch(es) spraying at most" % peak_surf)
	_ok("trees sway in the gale, and it stops with the storm",
			peak_gale > 0.5 and dir.ctx.gale == Vector3.ZERO and WeatherFx.wind == Vector3.ZERO
			and (scene._trees == null or swaying > 0),
			"gale up to %.2f; %d tree set(s) swaying" % [peak_gale, swaying])
	_ok("the wind has stopped, the lens is clear", cam.wind == Vector3.ZERO and not dir.ctx.raining
			and float(dir.ctx.screen.get_shader_parameter("rain")) == 0.0)
	print("  --   re-reading the seabed map: %.1f ms" % refresh_ms)
	_finish(scene)


## Over the land by the start, trees in view, and back where it was.
func _land_shot(cam: DebugCamera, name: String) -> void:
	var was := cam.global_transform
	# The tree nearest the start that stands above the sea.
	var tree := Vector3.INF
	var scene := cam.get_parent()
	if scene._trees != null:
		for set in scene._trees.get_children():
			if not (set is ImpostorLod):
				continue
			for xf: Transform3D in (set as ImpostorLod)._xf:
				if xf.origin.y > BrickWave.get_sea_level() + 2.5 and (tree == Vector3.INF
						or xf.origin.length() < tree.length()):
					tree = xf.origin
	if tree == Vector3.INF:
		return
	cam.global_position = tree + Vector3(9.0, 5.0, 9.0)
	cam.look_at(tree + Vector3(0.0, 3.0, 0.0), Vector3.UP)
	await process_frame
	await process_frame
	await _shot(name)
	# And close: the ground at a low angle, where puddles and ripples show.
	cam.global_position = tree + Vector3(4.0, 1.4, 4.0)
	cam.look_at(tree + Vector3(-3.0, 0.0, -3.0), Vector3.UP)
	for i in 70:   # the rain has to fall to here, and the collision field follow
		await process_frame
	await _shot(name + "_close")
	cam.global_transform = was


## Close to a site's wall in the rain: the streaks running down it.
func _wall_shot(cam: DebugCamera, scene: Node) -> void:
	if scene._sites.is_empty():
		return
	var was := cam.global_transform
	var site: MeshInstance3D = scene._sites[0]
	var box := site.global_transform * site.get_aabb()
	var face := Vector3(box.position.x - 4.0, box.position.y + 3.0, box.get_center().z)
	cam.global_position = face
	cam.look_at(Vector3(box.position.x, box.position.y + 2.5, box.get_center().z + 1.0), Vector3.UP)
	for i in 70:
		await process_frame
	await _shot("wall_wet")
	cam.global_transform = was


func _shot(name: String) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://shots"))
	await RenderingServer.frame_post_draw
	var path := "res://shots/hurricane_%s.png" % name
	root.get_texture().get_image().save_png(ProjectSettings.globalize_path(path))
	print("  --   saved %s" % path)


func _finish(scene: Node) -> void:
	root.remove_child(scene)
	scene.free()
	print("")
	print("%d passed, %d failed" % [_passed, _failed])
	quit(1 if _failed > 0 else 0)
