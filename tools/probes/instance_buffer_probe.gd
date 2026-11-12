extends SceneTree
## Not headless (the dummy renderer has no buffer). Every mesh with an
## instance shader parameter SET (whether its shader uses it or not) takes 16
## slots of the renderer's global buffer (Godot's InstanceUniforms) until it is
## freed; at Godot's default 65,536 that is 4,096 meshes, and past it:
## "Too many instances using shader instance variables". project.godot sets
## rendering/limits/global_shader_variables/buffer_size = 262,144 (16,384).
## This makes `count` meshes and shows them; the output must have no
## "Too many instances" line.
##   godot --path . --script res://tools/probes/instance_buffer_probe.gd -- [count]

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var count := int(args[0]) if args.size() > 0 else 6000
	var size: int = ProjectSettings.get_setting("rendering/limits/global_shader_variables/buffer_size")
	print("[buffer] buffer_size %d: room for %d instances; making %d" % [size, size / 16, count])
	var holder := Node3D.new()
	root.add_child.call_deferred(holder)
	await process_frame
	var cam := Camera3D.new()
	holder.add_child(cam)
	cam.position = Vector3(0, 0, 60)
	var mesh := BoxMesh.new()
	for i in count:
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		mi.position = Vector3(i % 80 - 40, i / 80 - 40, 0) * 0.5
		holder.add_child(mi)
		mi.set_instance_shader_parameter(&"grid_light", Vector4(1, 2, 3, 4))
	for i in 10:
		await process_frame
	print("[buffer] %d meshes drawn; the output above must have no 'Too many instances'" % count)
	quit(0)
