extends SceneTree

## Not headless. The planet's brick trees up close and far (Docs/Planets.md
## 11.10): the planet scene, its own camera set down by the densest stand of
## trees near the spawn, shots at 20 m (real bricks), 90 m (cards) and 300 m.
##
##   --path . --script res://tools/planet_tree_shot.gd
##
## Shots in res://shots/planet_trees_*.png.

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
		var path := "res://shots/planet_trees_%dm.png" % int(d)
		get_root().get_viewport().get_texture().get_image().save_png(path)
		print("[tree-shot] %s" % path)
	quit(0)
