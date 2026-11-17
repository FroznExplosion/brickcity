extends SceneTree

## Not headless. A picture to look at: the same small build three times, side
## by side, in the real brick material -- on the left its baked mesh, in the
## middle its stand-in (IslandStandins: a box per brick from
## get_standin_buffers), on the right its bricks lying as a heap does them
## (BrickHeap with the brick material and the stand-in's box, each brick's
## colour from get_block_rgba -- Docs/Interiors.md 8.17). All three should
## match in colour and material; the last two have no studs.
##
##     godot --path . --script tools/shots/standin_shot.gd -- --out=<png path>
##
## Copy tools/test_window.cfg to override.cfg first (CLAUDE.md, test windows).

const Standins := preload("res://scripts/islands/island_standins.gd")

var _out := "user://dev/standin_shot.png"


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.split("=", true, 1)[1]
	var w := BrickWorld.new()
	var palette := TowerRecipe.bake_palette(w)
	var c := w.create_chunk(Vector3i.ZERO, Vector3i(16, 16, 16))
	# A few bricks in a few materials and colours.
	var parts := [["brick_2x4_x", Vector3i(0, 0, 0), 4, 0], ["brick_2x4_x", Vector3i(4, 0, 0), 6, 0],
		["brick_2x4_x", Vector3i(2, 3, 0), 2, 2], ["brick_2x2", Vector3i(0, 3, 0), 5, 3],
		["brick_2x2", Vector3i(6, 3, 0), 1, 4], ["brick_2x4_x", Vector3i(1, 6, 0), 3, 1]]
	for p in parts:
		var b := w.place_block(c, p[1], palette[p[0]], p[2])
		if b >= 0 and int(p[3]) != 0:
			w.set_block_material(c, b, p[3])
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/brick.gdshader")

	var scene := Node3D.new()
	root.add_child(scene)
	var arrays: Array = w.build_chunk_mesh(c)
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var baked := MeshInstance3D.new()
	baked.mesh = mesh
	baked.material_override = mat
	scene.add_child(baked)

	var stand := Node3D.new()
	stand.position = Vector3(3.4, 0.0, 0.0)
	var bufs: Dictionary = w.get_standin_buffers(c)
	for size in bufs:
		var buf: PackedFloat32Array = bufs[size]
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.mesh = Standins._box(size)
		mm.instance_count = buf.size() / 16
		mm.buffer = buf
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.material_override = mat
		stand.add_child(mmi)
	scene.add_child(stand)

	# The same bricks lying on a heap, as fallen bricks are drawn.
	var heap := BrickHeap.new()
	heap.mesh_for = func(size: Vector3) -> Mesh: return Standins._box(size)
	heap.material = mat
	scene.add_child(heap)
	var cs := BrickWorld.get_cell_size()
	var tick_m: float = cs.x / float(BrickWorld.ticks_per_stud())
	for id in w.get_block_count(c):
		var t: Array = w.get_block_ticks(c, id)
		if t.is_empty():
			continue
		var size := Vector3(t[1] as Vector3i) * tick_m
		var local := (Vector3(t[0] as Vector3i) + Vector3(t[1] as Vector3i) * 0.5) * tick_m
		heap.lay(size, Transform3D(Basis(), local + Vector3(6.8, 0.0, 0.0)), w.get_block_rgba(c, id), 0.0, true)

	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(-0.9, 0.6, 0.0)
	scene.add_child(sun)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.55, 0.65, 0.75)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.6, 0.6, 0.6)
	scene.add_child(env)
	var cam := Camera3D.new()
	scene.add_child(cam)
	cam.look_at_from_position(Vector3(4.7, 2.6, 6.4), Vector3(4.7, 0.5, 0.3))
	cam.current = true
	_shoot.call_deferred()


func _shoot() -> void:
	for i in 20:
		await process_frame
	var img := root.get_viewport().get_texture().get_image()
	img.save_png(_out)
	print("standin_shot: saved %s" % _out)
	quit()
