extends SceneTree

## Snow (Docs/Disasters.md 21) on the heightfield coast.
##
##     godot --headless --path . --script res://tools/snow_probe.gd
##     godot --path . --resolution 1280x720 --script res://tools/snow_probe.gd -- --snow-shot
##
## It lies -- tiles on the ground round the camera, filling in as it falls --
## but not under what stands over the ground (a site), and not on the sea; the
## crowns of the trees take a cap; it outlasts the snowfall, melting, and its
## cover is let go once it has gone.

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
	print("snow probe")
	var scene: Node3D = load("res://scenes/heightfield_test.tscn").instantiate()
	root.add_child(scene)
	await _ticks(20)
	var dir: DisasterDirector = scene.disasters
	_ok("the heightfield offers a snowfall", dir != null and dir.roll.has("snow"), str(dir.roll))
	var shots := "--snow-shot" in OS.get_cmdline_user_args()
	var cam: DebugCamera = scene.camera
	var tree := _tree_spot(scene)
	if tree != Vector3.INF:
		cam.global_position = tree + Vector3(6.0, 2.5, 6.0)
		cam.look_at(tree + Vector3(-4.0, 0.5, -4.0), Vector3.UP)
	await _ticks(30)
	if shots:
		await _shot("snow_before")

	_ok("a snowfall starts", dir.start("snow", 2.5))
	var s: Snowfall = dir.current
	var ctx := dir.ctx
	var peak := 0.0
	var flakes := false
	var tick_sum := 0.0
	var tick_worst := 0.0
	var tick_n := 0
	var t := 0
	# The height of it: well into ACTIVE, the cover deep.
	while dir.is_running() and t < 30 * 50:
		await physics_frame
		t += 1
		peak = maxf(peak, ctx.snow)
		var ms := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
		tick_sum += ms
		tick_worst = maxf(tick_worst, ms)
		tick_n += 1
		if is_instance_valid(s):
			flakes = flakes or s.flakes_on
	var cover: SnowCover = ctx.snow_cover
	_ok("it falls, and lies deep", flakes and peak > 0.9 and WeatherFx.snow > 0.9,
			"%.2f lying" % peak)
	_ok("tiles on the ground round the camera", cover != null and cover.square_count() >= 20,
			"%d square(s) of ground snow" % (cover.square_count() if cover != null else 0))
	print("  --   physics tick while it lies (a square of ground a tick): mean %.2f ms, worst %.1f ms" % [
			tick_sum / maxf(tick_n, 1), tick_worst])
	if cover != null:
		print("  --   slowest square of ground snow built: %.1f ms" % cover.worst_square_ms)
	if shots:
		await _shot("snow_lying")
		if tree != Vector3.INF:
			var was := cam.global_transform
			cam.global_position = tree + Vector3(2.5, 1.2, 2.5)
			cam.look_at(tree + Vector3(-3.0, 0.0, -3.0), Vector3.UP)
			await _ticks(40)
			await _shot("snow_close")
			cam.global_transform = was

	# None under a site: the ray down meets it, so the cells under it are bare.
	var under := -1
	if cover != null and not scene._sites.is_empty():
		var site: MeshInstance3D = scene._sites[0]
		var box := site.global_transform * site.get_aabb()
		var stud := BrickWorld.get_stud_metres()
		var span := SnowCover.CHUNK * stud
		var key := Vector2i(floori(box.get_center().x / span), floori(box.get_center().z / span))
		var sq = cover._build_square(key)
		under = 0
		if sq != null:
			var arrays: Array = (sq as MeshInstance3D).mesh.surface_get_arrays(0)
			var vs: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var inner := box.grow(-0.4)
			for v in vs:
				if v.x > inner.position.x and v.x < inner.end.x and v.z > inner.position.z \
						and v.z < inner.end.z and v.y < box.position.y + 0.5:
					under += 1
			(sq as Node).queue_free()
	_ok("no snow under what stands over the ground (a site)", under == 0,
			"%d snow vertex(es) under it" % under)

	# It outlasts the snowfall, melting.
	while dir.is_running() and t < 30 * 120:
		await physics_frame
		t += 1
	await _ticks(30)
	_ok("the snowfall ends, the snow lies on, melting", not dir.is_running() and not ctx.snowing
			and ctx.snow > 0.3 and ctx.snow < peak, "%.2f left" % ctx.snow)
	_ok("and leaves the ground wet as it goes", ctx.wet > 0.3, "wet %.2f" % ctx.wet)
	# Melt the rest at once: the cover goes with it.
	ctx.snow = 0.0005
	await _ticks(10)
	_ok("once it has gone, so has its cover", ctx.snow_cover == null and WeatherFx.snow == 0.0)

	# A blizzard: the same snow, with a gale in it.
	cam.set_walking(true)
	await _ticks(30)
	_ok("a blizzard starts", dir.start("blizzard", 1.0))
	var bz: Blizzard = dir.current
	var from := Vector3.INF
	var drift := 0.0
	var gale := 0.0
	var haze := 0.0
	var lay_t := -1.0
	t = 0
	while dir.is_running() and t < 30 * 100:
		await physics_frame
		t += 1
		if not is_instance_valid(bz) or bz.phase != Disaster.Phase.ACTIVE:
			continue
		gale = maxf(gale, ctx.gale.length())
		haze = maxf(haze, float(ctx.screen.get_shader_parameter("dust")) if ctx.screen != null else 0.0)
		if lay_t < 0.0 and ctx.snow >= 0.9:
			lay_t = bz.phase_t
		if bz.phase_t > 10.0 and bz.phase_t < 14.0:
			if from == Vector3.INF:
				from = cam.global_position
			drift = Vector2(cam.global_position.x - from.x, cam.global_position.z - from.z).length()
		if shots and bz.phase_t > 20.0 and not bz.has_meta("shot"):
			bz.set_meta("shot", true)
			cam.set_walking(false)
			await _shot("blizzard")
			cam.set_walking(true)
	_ok("it lies twice as fast as a snowfall", lay_t > 0.0 and lay_t < DisasterContext.SNOW_S / 1.5,
			"deep after %.0f s (a snowfall at intensity 1 takes %.0f)" % [lay_t, DisasterContext.SNOW_S])
	_ok("the gale sways things hard and leans on a walker", gale > 0.9 and (shots or drift > 2.0),
			"gale %.2f, walker carried %.1f m in 4 s" % [gale, drift])
	_ok("the view whites out", ctx.screen == null or haze > 0.5, "haze %.2f" % haze)
	_ok("and the wind drops with it", not dir.is_running() and cam.wind == Vector3.ZERO
			and ctx.gale == Vector3.ZERO)
	_finish(scene)


func _tree_spot(scene: Node) -> Vector3:
	var tree := Vector3.INF
	var trees = scene._trees
	if trees == null:
		return tree
	# Where they stand, as they were scattered (ImpostorLod keeps no list).
	for spot in Trees.scatter(trees.rect, trees.world_seed, TerrainTrees.MAX_TREES):
		var o: Vector3 = Trees.placement(spot.cell, spot.variant).origin
		if o.y > BrickWave.get_sea_level() + 2.5 and (tree == Vector3.INF or o.length() < tree.length()):
			tree = o
	return tree


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
