extends SceneTree

## Not headless. A frozen kill's ice shards (VfxPool.spawn_shatter, drawn by
## fx/shaders/ice_shard.gdshader; Docs/GpuOffload.md 2.7). Each picture also
## draws, as a see-through red box, where the old CPU step (fall, bounce on the
## floor: up speed * -0.35, all * 0.7) puts every shard, stepped finely from
## what the burst wrote: the drawn shards sit in them.
## Saved to res://shots/shatter/{rising,bouncing,lying}.png.
##
##     godot --path . --script res://tools/shots/shatter_look.gd

const FLOOR := 0.0


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
	sun.shadow_enabled = true
	root.add_child(sun)
	var ground := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(40, 40)
	ground.mesh = pm
	root.add_child(ground)
	var cam := Camera3D.new()
	root.add_child(cam)
	cam.current = true
	cam.global_transform = Transform3D(Basis.looking_at(Vector3(0.0, -0.45, -1.0)), Vector3(0.0, 2.6, 5.0))
	var dots := MultiMeshInstance3D.new()
	dots.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	var box := BoxMesh.new()
	box.size = Vector3(0.1, 0.1, 0.1)
	mm.mesh = box
	var red := StandardMaterial3D.new()
	red.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	red.albedo_color = Color(1.0, 0.0, 0.0, 0.4)
	red.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	dots.material_override = red
	mm.instance_count = 80
	dots.multimesh = mm
	root.add_child(dots)
	for i in 3:
		await process_frame
	var pool: Node = root.get_node("VfxPool")
	pool.spawn_shatter(Vector3(0.0, 0.9, 0.0), Vector3(0.8, 1.6, 0.8), 60, FLOOR)
	var b = pool._shatters[pool._shatters.size() - 1]
	var smm: MultiMesh = b.mmi.multimesh
	var fall: Vector3 = b.mat.get_shader_parameter("fall")
	var pos := PackedVector3Array()
	var vel := PackedVector3Array()
	for i in smm.instance_count:
		pos.append(smm.get_instance_transform(i).origin)
		var c := smm.get_instance_custom_data(i)
		vel.append(Vector3(c.r, c.g, c.b))
	print("shatter look: %d shards" % smm.instance_count)
	var out := "res://shots/shatter"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out))
	for shot in [["rising", 0.15], ["bouncing", 0.6], ["lying", 1.1]]:
		while b.life < float(shot[1]):
			await process_frame
		# The shader's age is set; hold it while the picture is drawn.
		var age: float = b.life
		pool.set_process(false)
		mm.visible_instance_count = pos.size()
		for i in pos.size():
			mm.set_instance_transform(i, Transform3D(Basis(), _cpu(pos[i], vel[i], fall, age)))
		await process_frame
		await RenderingServer.frame_post_draw
		root.get_viewport().get_texture().get_image().save_png(out.path_join(shot[0] + ".png"))
		print("  %s at %.2f s" % [shot[0], age])
		pool.set_process(true)
	quit(0)


## The old CPU step, at 1/2000 s.
func _cpu(p: Vector3, v: Vector3, fall: Vector3, age: float) -> Vector3:
	var dt := 0.0005
	var t := 0.0
	while t < age:
		var h := minf(dt, age - t)
		v += fall * h
		p += v * h
		if p.y < FLOOR + 0.05:
			p.y = FLOOR + 0.05
			v.y *= -0.35
			v *= 0.7
		t += h
	return p
