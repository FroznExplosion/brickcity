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
		flashes = h.flashes
		raining = raining or dir.ctx.raining
		if h.phase == Disaster.Phase.ACTIVE:
			var u := h.phase_t / h.active_s
			# The height of it, and then the eye.
			if shots and not shot_taken and u > 0.33:
				shot_taken = true
				await _shot("storm")
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
	_ok("the wind has stopped, the lens is clear", cam.wind == Vector3.ZERO and not dir.ctx.raining
			and float(dir.ctx.screen.get_shader_parameter("rain")) == 0.0)
	print("  --   re-reading the seabed map: %.1f ms" % refresh_ms)
	_finish(scene)


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
