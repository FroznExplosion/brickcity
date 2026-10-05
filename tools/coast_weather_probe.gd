extends SceneTree

## Sandstorm and waterspout on the heightfield coast (Docs/Disasters.md 25, 26).
##
##     godot --headless --path . --script res://tools/coast_weather_probe.gd
##     godot --path . --resolution 1280x720 --script res://tools/coast_weather_probe.gd -- --coast-shot
##
## A sandstorm hazes the view, leans on a walker, and leaves sand lying -- in
## sand's colour -- that blows away after. A waterspout forms and walks on open
## water, throws spray, and its rain falls in its own cell: the player is rained
## on only inside it, and nothing is left wet-flagged after.

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
	print("coast weather probe")
	var scene: Node3D = load("res://scenes/heightfield_test.tscn").instantiate()
	root.add_child(scene)
	await _ticks(20)
	var dir: DisasterDirector = scene.disasters
	var ctx := dir.ctx
	var shots := "--coast-shot" in OS.get_cmdline_user_args()
	_ok("the coast offers a sandstorm and a waterspout", dir.roll.has("sandstorm")
			and dir.roll.has("waterspout"), str(dir.roll))
	var cam: DebugCamera = scene.camera
	cam.set_walking(true)
	await _ticks(30)

	# --- Sandstorm ---------------------------------------------------------------
	_ok("a sandstorm starts", dir.start("sandstorm", 1.0))
	var ss: Sandstorm = dir.current
	var haze := 0.0
	var lying := 0.0
	var from := Vector3.INF
	var drift := 0.0
	var colour := Color.WHITE
	var t := 0
	while dir.is_running() and t < 30 * 100:
		await physics_frame
		t += 1
		if not is_instance_valid(ss):
			continue
		haze = maxf(haze, float(ctx.screen.get_shader_parameter("dust")) if ctx.screen != null else 0.0)
		lying = maxf(lying, ctx.snow)
		if ctx.snow > 0.1:
			colour = WeatherFx.snow_colour
		if ss.phase == Disaster.Phase.ACTIVE and ss.phase_t > 15.0 and ss.phase_t < 19.0:
			if from == Vector3.INF:
				from = cam.global_position
			drift = Vector2(cam.global_position.x - from.x, cam.global_position.z - from.z).length()
		if shots and ss.phase == Disaster.Phase.ACTIVE and ss.phase_t > 25.0 and not ss.has_meta("shot"):
			ss.set_meta("shot", true)
			await _shot("sandstorm")
	_ok("the view browns out", ctx.screen == null or haze > 0.6, "haze %.2f" % haze)
	_ok("the wind leans on a walker", drift > 2.0, "%.1f m in 4 s" % drift)
	_ok("sand lies, thin, in sand's colour", lying > 0.2 and lying <= Sandstorm.LIE_CAP + 0.01
			and colour.is_equal_approx(Sandstorm.SAND), "%.2f, %s" % [lying, colour])
	_ok("and the wind drops after", not dir.is_running() and cam.wind == Vector3.ZERO
			and ctx.gale == Vector3.ZERO)
	ctx.snow = 0.0005
	await _ticks(10)

	# --- Waterspout --------------------------------------------------------------
	cam.set_walking(false)
	_ok("a waterspout starts", dir.start("waterspout", 1.0))
	var ws: Waterspout = dir.current
	var water := 0
	var wet_seen := false
	var dry_seen := false
	var spray := false
	t = 0
	while dir.is_running() and t < 30 * 120:
		await physics_frame
		t += 1
		if not is_instance_valid(ws):
			continue
		water = ws.over_water
		spray = spray or ws._spray.emitting
		if ws.phase == Disaster.Phase.ACTIVE and ws.strength > 0.5:
			var d := Vector2(cam.global_position.x - ws.pos.x, cam.global_position.z - ws.pos.z).length()
			if d > Waterspout.RAIN_RADIUS * 1.5:
				dry_seen = dry_seen or not ctx.raining
			# Fly into its cell for a moment: then it rains here.
			if not wet_seen and ws.phase_t > 15.0:
				var was := cam.global_transform
				cam.global_position = Vector3(ws.pos.x + 12.0, BrickWave.get_sea_level() + 6.0, ws.pos.z)
				await _ticks(2)
				wet_seen = ctx.raining
				if shots:
					cam.look_at(ws.pos + Vector3.UP * 15.0, Vector3.UP)
					cam.global_position = Vector3(ws.pos.x + 70.0, BrickWave.get_sea_level() + 12.0, ws.pos.z + 20.0)
					cam.look_at(ws.pos + Vector3.UP * 15.0, Vector3.UP)
					await _ticks(10)
					await _shot("waterspout")
				cam.global_transform = was
	_ok("it walks on open water, throwing spray", water > 30 * 10 and spray,
			"%.0f s on the water" % (water / 30.0))
	_ok("its rain falls in its own cell: dry outside it, wet in it", dry_seen and wet_seen)
	_ok("and nothing is left raining after", not dir.is_running() and not ctx.raining)
	_finish(scene)


func _shot(name: String) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://shots"))
	await RenderingServer.frame_post_draw
	var path := "res://shots/%s.png" % name
	root.get_texture().get_image().save_png(ProjectSettings.globalize_path(path))
	print("  --   saved %s" % path)


func _finish(scene: Node) -> void:
	root.remove_child(scene)
	scene.free()
	print("")
	print("%d passed, %d failed" % [_passed, _failed])
	quit(1 if _failed > 0 else 0)
