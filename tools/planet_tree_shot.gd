extends SceneTree

## Not headless. The planet's brick trees up close and far (Docs/Planets.md
## 11.10): the planet scene, its own camera set down by the densest stand of
## trees near the spawn, shots at 20 m (real bricks), 90 m (cards) and 300 m.
##
##   --path . --script res://tools/planet_tree_shot.gd [-- --snow]
##
## Shots in res://shots/planet_trees_*.png. `--snow`: the player is first set
## down by the snowiest stand on the planet (crowns capped, 11.10), shots
## planet_trees_snow_*.png.

var _scene: Node
var _cam: Camera3D


func _initialize() -> void:
	_scene = (load("res://scenes/planet.tscn") as PackedScene).instantiate()
	get_root().add_child(_scene)
	_run()


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _run() -> void:
	await _frames(30)
	var t0 := Time.get_ticks_msec()
	while _scene.get("pawn") == null and Time.get_ticks_msec() - t0 < 60000:
		await _frames(1)
	var tr: PlanetTrees = _scene.get("trees")
	var planet: Node3D = _scene.get("planet")
	var data: PlanetData = _scene.get("data")
	var pawn: Pawn = _scene.get("pawn")
	var snow := "--snow" in OS.get_cmdline_user_args()
	if snow:
		# The snowiest stand: sampled spots, the most full caps within 40 m.
		var rng := RandomNumberGenerator.new()
		rng.seed = 3
		var best_d := Vector3.UP
		var most := 0
		for k in 400:
			var d := Vector3(rng.randfn(), rng.randfn(), rng.randfn()).normalized()
			var n := 0
			for t in tr.trees_near(d, 40.0):
				if int(tr.trees_of(t.key)[t.index].snow) == 2:
					n += 1
			if n > most:
				most = n
				best_d = d
		print("[tree-shot] the snowiest stand: %d capped trees within 40 m" % most)
		# Planet-local: the floating origin moves the scene when the player goes
		# kilometres off.
		var local_at := best_d * (data.radius + data.height(best_d) + 0.5) + best_d.cross(Vector3.FORWARD).normalized() * 25.0
		# Held there until the ground under it has streamed in, then set on it.
		var t1 := Time.get_ticks_msec()
		var ground := Vector3.INF
		while Time.get_ticks_msec() - t1 < 30000:
			pawn.place(planet.to_global(local_at))
			await _frames(1)
			ground = _scene.call(&"_ground_hit", planet.to_global(local_at))
			if ground != Vector3.INF:
				break
		print("[tree-shot] ground there: %s" % (ground != Vector3.INF))
		if ground != Vector3.INF:
			pawn.place(ground + (ground - planet.global_position).normalized() * 0.3)
		await _frames(240)
	# The densest cell within 500 m of the pawn.
	var here := planet.to_local(pawn.feet())
	var best := Vector3i.ZERO
	var best_n := -1
	for k in tr._cells:
		var c: Dictionary = tr._cells[k]
		if (c.centre as Vector3).distance_to(here) < 500.0 and (c.trees as Array).size() > best_n:
			best_n = (c.trees as Array).size()
			best = k
	print("[tree-shot] the densest cell near: %d trees" % best_n)
	if best_n <= 0:
		quit(1)
		return
	var stand: Vector3 = tr._cells[best].centre
	var up := stand.normalized()
	var side := up.cross(Vector3.FORWARD).normalized()
	_cam = Camera3D.new()
	_cam.far = 20000.0
	get_root().add_child(_cam)
	_cam.current = true
	for d in [20.0, 90.0, 300.0]:
		var dir: Vector3 = (stand.normalized() * data.radius + side * float(d)).normalized()
		var p: Vector3 = dir * (data.radius + data.height(dir) + 1.7 + float(d) * 0.15)
		var gp := planet.to_global(p)
		var target := planet.to_global(stand + up * 3.0)
		_cam.global_position = gp
		_cam.look_at(target, planet.to_global(p + dir) - gp)
		await _frames(90)
		await RenderingServer.frame_post_draw
		var path := "res://shots/planet_trees_%s%dm.png" % ["snow_" if snow else "", int(d)]
		get_root().get_viewport().get_texture().get_image().save_png(path)
		print("[tree-shot] %s" % path)
	quit(0)
