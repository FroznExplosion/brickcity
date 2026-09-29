extends SceneTree

## The impostor system on its own (Docs/Impostors.md 8): tree recipes, their
## meshes, an octahedral bake, and an ImpostorLod drawing a field of them.
##
##     godot --path . --script res://tools/impostor_probe.gd
##
## Not headless: a bake needs a renderer. Writes shots/impostor_*.png.

var _ok := 0
var _fail := 0


func _check(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_ok += 1
		print("  ok   %s" % what)
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	print("[impostor] trees, meshes, bakes")
	var w := BrickWorld.new()
	var pal := TowerRecipe.bake_palette(w)
	var meshes := []
	for v in Trees.VARIANTS:
		var r := Trees.recipe(v)
		var asm := Assembly.new(w, pal)
		var placed := r.build_into(asm, pal)
		_check("tree %d: all %d pieces placed" % [v, r.size()], placed == r.size(),
				"%d placed" % placed)
		var m := RecipeMesh.build(r, "tree_%d" % v)
		@warning_ignore("integer_division")
		var tris := m.get_faces().size() / 3 if m.get_surface_count() > 0 else 0
		print("[impostor]   tree %d: %d pieces, %.1f m tall, %d triangles" % [
				v, r.size(), Trees.height_m(v), tris])
		_check("tree %d has a mesh" % v, tris > 0)
		meshes.append(m)

	# A scene to look at it in.
	var root := Node3D.new()
	get_root().add_child(root)
	var cam := Camera3D.new()
	cam.far = 2000.0
	root.add_child(cam)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-40, -35, 0)
	sun.shadow_enabled = true
	root.add_child(sun)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.55, 0.7, 0.85)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.6, 0.6, 0.6)
	var we := WorldEnvironment.new()
	we.environment = env
	root.add_child(we)
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(2000, 2000)
	ground.mesh = plane
	root.add_child(ground)

	var brick := ShaderMaterial.new()
	brick.shader = load("res://shaders/brick.gdshader")
	var lod := ImpostorLod.new()
	root.add_child(lod)
	lod.setup(meshes[0], brick, 30.0)
	# A row going away from the camera, and a field behind it.
	for i in 40:
		lod.add(Transform3D(Basis(Vector3.UP, float(i) * 0.7), Vector3(-6.0, 0.0, -8.0 - i * 6.0)))
	for i in 200:
		lod.add(Transform3D(Basis(), Vector3(-60.0 + (i % 20) * 7.0, 0.0, -60.0 - (i / 20) * 9.0)))

	# Wait for the bake.
	var guard := 0
	while lod.bake.is_empty() and guard < 300:
		await process_frame
		guard += 1
	_check("the impostor baked", not lod.bake.is_empty(), "%d frames" % guard)
	if not lod.bake.is_empty():
		var img: Image = (lod.bake.albedo as Texture2D).get_image()
		var covered := 0
		var n := 0
		for y in range(0, img.get_height(), 4):
			for x in range(0, img.get_width(), 4):
				n += 1
				if img.get_pixel(x, y).a > 0.5:
					covered += 1
		print("[impostor]   atlas %dx%d, %.0f%% covered, radius %.2f m" % [
				img.get_width(), img.get_height(), 100.0 * covered / n, float(lod.bake.radius)])
		_check("the atlas has the tree in it", covered > n / 20)
		img.save_png("res://shots/impostor_atlas.png")

	cam.position = Vector3(0.0, 3.0, 4.0)
	cam.look_at(Vector3(-6.0, 3.0, -40.0), Vector3.UP)
	lod.update(cam.position)
	print("[impostor]   %d near, %d far" % [lod.near_count, lod.far_count])
	_check("near and far both drawn", lod.near_count > 0 and lod.far_count > 0)
	for i in 6:
		await process_frame
	get_root().get_texture().get_image().save_png("res://shots/impostor_row.png")

	# The same tree at 60 m, as mesh and as card, side by side.
	var twin := MeshInstance3D.new()
	twin.mesh = meshes[0]
	twin.material_override = brick
	root.add_child(twin)
	twin.position = Vector3(2000.0, 0.0, 0.0)
	var solo := ImpostorLod.new()
	root.add_child(solo)
	solo.setup(meshes[0], brick, 1.0)
	guard = 0
	while solo.bake.is_empty() and guard < 300:
		await process_frame
		guard += 1
	solo.add(Transform3D(Basis(), Vector3(2004.0, 0.0, 0.0)))
	twin.position = Vector3(1996.0, 0.0, 0.0)
	cam.position = Vector3(2000.0, 4.0, 14.0)
	cam.look_at(Vector3(2000.0, 3.0, 0.0), Vector3.UP)
	solo.update(Vector3(2000.0, 0.0, 200.0))   # far, whatever the camera says
	for i in 6:
		await process_frame
	get_root().get_texture().get_image().save_png("res://shots/impostor_pair.png")

	# Small items: a brick gun, a hundred of them on the ground.
	print("[impostor] items")
	var gun := BuildRecipe.new()
	gun.name = "probe_gun"
	# From the min corner, as every recipe is. Long parts name their axis.
	gun.add("brick_1x2_z", Vector3i(0, 0, 4), 1)          # grip
	gun.add("plate_1x2_z", Vector3i(0, 2, 0), 3)          # under the barrel
	gun.add("brick_1x6_z", Vector3i(0, 3, 0), 3)          # barrel and body
	gun.add("plate_1x4_z", Vector3i(0, 6, 1), 1)          # top rail
	var gun_mesh := RecipeMesh.build(gun, "probe_gun")
	_check("the gun has a mesh", gun_mesh.get_surface_count() > 0)
	var items := ImpostorItems.new()
	root.add_child(items)
	items.kind("gun", gun_mesh, brick)
	var base := Vector3(3000.0, 0.0, 0.0)
	var handles := []
	for i in 100:
		var ang := float(i) * 2.399
		var r := 2.0 + float(i) * 2.2          # 2 m out to 220 m
		handles.append(items.add("gun", Transform3D(Basis(Vector3.UP, ang),
				base + Vector3(cos(ang) * r, 0.2, sin(ang) * r))))
	guard = 0
	var gk: ImpostorLod = items._kinds["gun"]
	while gk.bake.is_empty() and guard < 300:
		await process_frame
		guard += 1
	_check("the gun baked", not gk.bake.is_empty())
	cam.position = base + Vector3(0.0, 1.7, 0.0)
	cam.look_at(base + Vector3(10.0, 0.0, 10.0), Vector3.UP)
	items.update()
	var n_near := 0
	var n_far := 0
	var n_cull := 0
	for i in 100:
		match items.tier_of(handles[i]):
			1: n_near += 1
			2: n_far += 1
			_: n_cull += 1
	print("[impostor]   items: %d near, %d cards, %d culled" % [n_near, n_far, n_cull])
	_check("items near are meshes, further cards, furthest culled",
			n_near > 0 and n_far > 0 and n_cull > 0)
	_check("  two draw calls' worth of instances", gk.near_count == n_near and gk.far_count == n_far)
	var last: int = handles[99]
	items.move(last, Transform3D(Basis(), base + Vector3(3.0, 0.2, 3.0)))
	items.update()
	_check("an item moved close is a mesh", items.tier_of(last) == 1)
	items.remove(last)
	items.update()
	_check("an item removed is gone", items.tier_of(last) == 0 and gk.count() == 99)
	for i in 6:
		await process_frame
	get_root().get_texture().get_image().save_png("res://shots/impostor_items.png")

	print("[impostor] %d ok, %d FAIL" % [_ok, _fail])
	quit(1 if _fail > 0 else 0)
