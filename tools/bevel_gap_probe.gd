extends SceneTree

## Does the geometry chamfer open the ground? (Docs/Terrain.md 17.24, 22.13)
##
##     godot --path . --script res://tools/bevel_gap_probe.gd
##
## Not headless: it counts pixels. The sea is hidden and a huge unlit MAGENTA
## plane is put far under the world; any magenta pixel seen from above the
## ground is a hole through it. Many low views (where a slit shows) round the
## origin, inside the chamfer's range, with the geometry chamfer OFF and ON.
## The chamfer must add no holes.

const MAGENTA := Color(1, 0, 1)

var _passed := 0
var _failed := 0


func _initialize() -> void:
	_run.call_deferred()


func _ok(what: String, cond: bool, detail := "") -> void:
	if cond:
		_passed += 1
	else:
		_failed += 1
	print("  %s %s%s" % ["ok  " if cond else "FAIL", what, ("  " + detail) if detail != "" else ""])


func _magenta(img: Image) -> int:
	var n := 0
	for y in range(0, img.get_height(), 1):
		for x in range(0, img.get_width(), 1):
			var c := img.get_pixel(x, y)
			if c.r > 0.85 and c.b > 0.85 and c.g < 0.2:
				n += 1
	return n


func _views(scene: Node3D) -> Array:
	var out := []
	var plate := BrickWorld.get_plate_metres()
	var stud := BrickWorld.get_stud_metres()
	for k in 16:
		var a := TAU * k / 16.0
		var r := 4.0 + float(k % 4) * 6.0
		var x := cos(a) * r
		var z := sin(a) * r
		var g := float(BrickTerrain.surface_plate(int(floor(x / stud)), int(floor(z / stud))) + 1) * plate
		var eye := Vector3(x, g + 0.5 + float(k % 3) * 0.6, z)
		var look := Vector3(x + cos(a + 2.2) * 6.0, g - 0.3, z + sin(a + 2.2) * 6.0)
		out.append(Transform3D(Basis(), eye).looking_at(look))
	return out


func _count(scene: Node3D, views: Array, tag: String) -> int:
	var cam: Camera3D = scene._camera
	var total := 0
	var worst := 0
	var worst_i := -1
	for i in views.size():
		cam.global_transform = views[i]
		scene._streamer.settle(Vector2(cam.global_position.x, cam.global_position.z))
		for f in 4:
			await process_frame
		await RenderingServer.frame_post_draw
		var img := root.get_viewport().get_texture().get_image()
		var n := _magenta(img)
		total += n
		if n > worst:
			worst = n
			worst_i = i
			img.save_png("res://shots/bevel_gap_%s.png" % tag)
	print("  [%s] magenta pixels over %d views: %d (worst view %d: %d)" % [tag, views.size(), total, worst_i, worst])
	return total


## Every detail tile again, with the current chamfer setting.
func _rebuild(scene: Node3D) -> void:
	var r: int = scene.FAR_TILES
	scene._streamer.invalidate(Rect2i(-r, -r, r * 2 + 1, r * 2 + 1))


func _run() -> void:
	print("bevel gap probe")
	var scene: Node3D = load("res://scenes/heightfield_test.tscn").instantiate()
	root.add_child(scene)
	for i in 120:
		await process_frame
	if scene._sea != null:
		scene._sea.enabled = false
		scene._sea.visible = false
	if scene._trees != null:
		scene._trees.visible = false
	# Far down and huge, unlit, so anything showing through is unmistakable.
	var floor_mi := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(4000, 4000)
	floor_mi.mesh = pm
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = MAGENTA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	floor_mi.material_override = mat
	floor_mi.position = Vector3(0, -80, 0)
	scene.add_child(floor_mi)
	var views := _views(scene)

	TerrainTile.bevel_enabled = false
	_rebuild(scene)
	var off := await _count(scene, views, "off")
	TerrainTile.bevel_enabled = true
	_rebuild(scene)
	var on := await _count(scene, views, "on")
	var tris := 0
	for t in scene._streamer.tiles():
		tris += t.bevel_tri_count
	_ok("the chamfered tiles were built", tris > 0, "%d chamfered triangles held" % tris)
	_ok("the chamfer opens no holes in the ground", on <= off,
			"%d magenta with it, %d without" % [on, off])
	print("bevel gap probe: %d passed, %d failed" % [_passed, _failed])
	quit(1 if _failed > 0 else 0)
