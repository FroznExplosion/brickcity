extends SceneTree
## Not a gate: counts the live instances whose shader has instance uniforms
## (each takes slots in the renderer's global buffer, 65,536 by default).
## Godot gives each such instance 16 slots whatever it uses: 4,096 instances.
## On the planet the walker is moved ~`step` metres every 300 frames.
##   godot --headless --path . --script res://tools/instance_uniform_count.gd -- <scene> [frames] [step]

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var scene: String = args[0] if args.size() > 0 else "res://scenes/planet.tscn"
	var frames := int(args[1]) if args.size() > 1 else 900
	var step := float(args[2]) if args.size() > 2 else 0.0
	change_scene_to_file(scene)
	for i in frames:
		await process_frame
		if i % 300 == 299:
			_count(i + 1)
			var sc := current_scene
			if step > 0.0 and sc != null and "walker" in sc and sc.walker != null:
				var c: Vector3 = sc.planet.global_position
				var d: Vector3 = (sc.walker.global_position - c).normalized()
				var axis := d.cross(Vector3.FORWARD if absf(d.y) > 0.9 else Vector3.UP).normalized()
				var nd := d.rotated(axis, step / d.length() / (sc.walker.global_position - c).length())
				sc.walker.place(c + sc.data.surface_point(nd) + nd * 1.0, axis)
	quit(0)


func _count(frame: int) -> void:
	var by := {}
	var slots := 0
	var total := 0
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		stack.append_array(n.get_children(true))
		var g := n as GeometryInstance3D
		if g == null:
			continue
		var mats: Array = []
		if g.material_override != null:
			mats.append(g.material_override)
		elif g is MeshInstance3D and (g as MeshInstance3D).mesh != null:
			var m := (g as MeshInstance3D).mesh
			for s in m.get_surface_count():
				var sm := (g as MeshInstance3D).get_active_material(s)
				if sm != null:
					mats.append(sm)
		var most := 0
		var name := ""
		for mat in mats:
			var sh := mat as ShaderMaterial
			if sh == null or sh.shader == null:
				continue
			var c := sh.shader.code.count("instance uniform")
			for inc in ["weather.gdshaderinc", "grid_light.gdshaderinc", "printed_core.gdshaderinc"]:
				if sh.shader.code.contains(inc):
					c += {"weather.gdshaderinc": 2, "grid_light.gdshaderinc": 1,
							"printed_core.gdshaderinc": 4}[inc]
			if c > most:
				most = c
				name = sh.shader.resource_path.get_file()
		# Godot allocates for any parameter SET on the instance too, whatever
		# its material has (InstanceUniforms::set keeps it).
		var set_names: Array = []
		for pr in g.get_property_list():
			var pn: String = pr.name
			if pn.begins_with("instance_shader_parameters/"):
				set_names.append(pn.get_slice("/", 1))
		if most == 0 and not set_names.is_empty():
			most = 16
			name = "NO SHADER USE: %s on %s" % [",".join(set_names), g.get_class()]
		if most > 0:
			total += 1
			slots += most
			var key := "%s  %s" % [name, n.get_parent().name if n.get_parent() else ""]
			by[key] = int(by.get(key, 0)) + 1
	var sc := current_scene
	var at := ""
	if sc != null and "walker" in sc and sc.walker != null:
		at = " walker %s" % sc.walker.global_position
	print("[count] frame %d: %d instances, ~%d slots; orphan nodes %d, objects %d%s" % [frame, total,
			slots, Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT),
			Performance.get_monitor(Performance.OBJECT_COUNT), at])
	var keys := by.keys()
	keys.sort_custom(func(a, b): return by[a] > by[b])
	for k in keys.slice(0, 12):
		print("   %6d  %s" % [by[k], k])
