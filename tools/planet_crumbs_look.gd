extends SceneTree

## Not headless. A planet's crumbs (PlanetCrumbs, drawn by shaders/crumb.gdshader
## with `radial`; Docs/GpuOffload.md 2.1): sixteen bricks thrown off a small
## planet turned out of true and offset, as the floating origin leaves one. Each
## picture draws where the CPU says every crumb is and how it is turned
## (`positions()`, `_turned`) as a see-through red box: the drawn crumbs sit in
## them lying, and lead them by up to a tick's fall while falling (the shader's
## clock carries the fraction since the last tick).
## Saved to res://shots/planet_crumbs/{falling,lower,lying}.png.
##
##     godot --path . --script res://tools/planet_crumbs_look.gd

const R := 300.0


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.45, 0.55, 0.7)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.55, 0.55, 0.6)
	env.environment = e
	root.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(-0.9, 0.5, 0.0)
	root.add_child(sun)
	# The planet: its centre under the scene, turned, so planet-local is not world.
	var planet := Node3D.new()
	root.add_child(planet)
	planet.global_transform = Transform3D(Basis(Vector3(0.3, 1.0, 0.2).normalized(), 0.7), Vector3(0.0, -R, 0.0))
	var ground := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = R
	sm.height = R * 2.0
	sm.radial_segments = 256
	sm.rings = 128
	ground.mesh = sm
	planet.add_child(ground)
	Gravity.planet = planet
	Gravity.planet_radius = R
	Gravity.planet_strength = 9.8
	# Sixteen bricks four metres up.
	var world := BrickWorld.new()
	var pal := BrickPalette.bake(world)
	var c := world.create_chunk(Vector3i.ZERO, Vector3i(8, 8, 8))
	world.set_chunk_transform(c, Transform3D(Basis(), Vector3(-0.7, 4.0, -0.7)))
	var ids := PackedInt32Array()
	for x in 4:
		for z in 4:
			ids.append(world.place_block(c, Vector3i(x, 0, z), pal["brick_1x1"], (x + z) % 4))
	var crumbs := PlanetCrumbs.new()
	root.add_child(crumbs)
	crumbs.setup(planet)
	var cam := Camera3D.new()
	root.add_child(cam)
	cam.current = true
	cam.global_transform = Transform3D(Basis.looking_at(Vector3(-6.0, -1.0, -8.0)), Vector3(6.0, 3.5, 8.0))
	var dots := MultiMeshInstance3D.new()
	# Where it is written, not eased there from the last picture's.
	dots.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	var red := StandardMaterial3D.new()
	red.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	red.albedo_color = Color(1.0, 0.0, 0.0, 0.45)
	red.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	red.no_depth_test = true
	dots.material_override = red
	mm.instance_count = 64
	dots.multimesh = mm
	root.add_child(dots)
	await physics_frame
	var n := crumbs.throw(world, c, ids)
	var st = crumbs._sets.values()[0]
	mm.mesh = st.mmi.multimesh.mesh
	print("planet crumbs look: %d thrown" % n)
	var out := "res://shots/planet_crumbs"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out))
	var tps := float(Engine.physics_ticks_per_second)
	for shot in [["falling", 0.2], ["lower", 0.3], ["lying", 0.9]]:
		for i in int(float(shot[1]) * tps):
			await physics_frame
		var at := crumbs.positions()
		var now := Engine.get_physics_frames()
		mm.visible_instance_count = at.size()
		for i in at.size():
			mm.set_instance_transform(i, planet.global_transform * Transform3D(crumbs._turned(st, i, now), at[i]))
		await process_frame
		await process_frame
		await RenderingServer.frame_post_draw
		root.get_viewport().get_texture().get_image().save_png(out.path_join(shot[0] + ".png"))
		print("  %s: %d alive" % [shot[0], crumbs.alive])
	Gravity.planet = null
	quit(0)
