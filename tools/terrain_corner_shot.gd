extends SceneTree

## Free terrain corners (both sides drop to the same height), framed close
## through a narrow lens the way a scope sees them: one picture per drop
## (a plate, two plates, a brick, more). Pictures, not checks.
##
##     godot --path . --script res://tools/terrain_corner_shot.gd -- --out=<dir> [--fov=14]
##
## Not headless. Writes <dir>/terrain_corner_<drop>_<n>.png.

var _out := "user://"
var _fov := 14.0


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.substr(6)
		elif a.begins_with("--fov="):
			_fov = float(a.substr(6))
	_run.call_deferred()


func _run() -> void:
	var scene: Node3D = load("res://scenes/heightfield_test.tscn").instantiate()
	root.add_child(scene)
	for i in 120:
		await process_frame
	if scene._sea != null:
		scene._sea.enabled = false
		scene._sea.visible = false
	if scene._trees != null:
		scene._trees.visible = false
	var cam: Camera3D = scene._camera
	var plate := BrickWorld.get_plate_metres()
	var stud := BrickWorld.get_stud_metres()
	# Corners (x1, z0) of a column: +X and -Z neighbours lower, and level.
	var found := {}
	for r in range(2, 60):
		for x in range(-r, r + 1):
			for z in [-r, r]:
				for p in [Vector2i(x, z), Vector2i(z, x)]:
					var h := BrickTerrain.surface_plate(p.x, p.y)
					var hx := BrickTerrain.surface_plate(p.x + 1, p.y)
					var hz := BrickTerrain.surface_plate(p.x, p.y - 1)
					if hx >= h or hx != hz:
						continue
					var drop := h - hx
					var key := mini(drop, 4)
					var list: Array = found.get(key, [])
					if list.size() < 3:
						list.append([p, h])
						found[key] = list
	for key in found:
		var n := 0
		for e in found[key]:
			var p: Vector2i = e[0]
			var top := float(e[1] + 1) * plate
			var corner := Vector3(float(p.x + 1) * stud, top, float(p.y) * stud)
			var out := Vector3(1, 0, -1).normalized()
			var eye := corner + out * 1.1 + Vector3(0, 0.45, 0) + Vector3(-out.z, 0, out.x) * 0.5
			cam.global_transform = Transform3D(Basis(), eye).looking_at(corner - Vector3(0, 0.15, 0))
			cam.fov = _fov
			scene._streamer.settle(Vector2(eye.x, eye.z))
			for f in 6:
				await process_frame
			await RenderingServer.frame_post_draw
			var path := "%s/terrain_corner_%d_%d.png" % [_out, key, n]
			root.get_viewport().get_texture().get_image().save_png(path)
			print("drop %d plates at %s -> %s" % [key, p, path])
			n += 1
	quit()
