extends SceneTree

## What solid PBR wood costs the renderer (Docs/PbrWood.md, "Cost").
##
##     godot --path . --script res://tools/probes/wood_cost_probe.gd
##
## Not headless, and a timing pass: only with the editor closed and no other
## test running (CLAUDE.md). A wall of 2x4s, chamfered, fills a 1280x720 view
## from three metres -- every pixel a brick -- and the renderer's own clock
## (viewport_get_measured_render_time_gpu; a test window's frame is pinned at
## 16.6 ms) is read over FRAMES frames, the median kept, for:
##
##   pla          the house plastic, layer lines and all (baked, Docs/PbrWood.md 7)
##   pla_drawn    the same, its layers drawn by the rules (print_bead_texture off)
##   pla_top      a floor of 2x4s from above: tops and studs, baked lines
##   pla_top_drawn  the same, drawn
##   wood_pbr     wood, the full set: colour, roughness, normal map
##   wood_colour  wood past pbr_range: colour and roughness, one read
##   wood_flat    wood past pbr_far_range: the flat colour
##
## Each is measured twice, interleaved, so drift shows.

const FRAMES := 240
const SIZE := Vector2i(1280, 720)
const BEVEL := 0.013

var _view: SubViewport
var _cam: Camera3D
var _mi: MeshInstance3D


func _initialize() -> void:
	_run.call_deferred()


func _stage() -> void:
	_view = SubViewport.new()
	_view.size = SIZE
	_view.own_world_3d = true
	_view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(_view)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.7, 0.72, 0.76)
	env.ambient_light_energy = 0.5
	var we := WorldEnvironment.new()
	we.environment = env
	_view.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-38, 28, 0)
	sun.shadow_enabled = true
	_view.add_child(sun)
	_cam = Camera3D.new()
	_cam.fov = 60.0
	_view.add_child(_cam)
	_cam.current = true
	RenderingServer.viewport_set_measure_render_time(_view.get_viewport_rid(), true)


func _wall(w: BrickWorld, pal: Dictionary, mat: int) -> Mesh:
	var c := w.create_chunk(Vector3i.ZERO, Vector3i(40, 120, 4))
	for course in 36:
		for k in 10:
			var b := w.place_block(c, Vector3i(k * 4 + (course % 2) * 2 - 2, course * 3, 0),
					int(pal["brick_2x4_x"]), 0)
			if b >= 0:
				w.set_block_material(c, b, mat)
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, w.build_chunk_chamfer_mesh(c, BEVEL))
	return mesh


## A floor of 2x4s one course deep, seen from above: every pixel a top (the
## studs are instanced elsewhere in the game, and not drawn here). A world of
## its own, so it overlaps nothing of the wall's.
func _floor(w: BrickWorld, pal: Dictionary) -> Mesh:
	var c := w.create_chunk(Vector3i.ZERO, Vector3i(48, 3, 48))
	for row in 22:
		for k in 11:
			w.place_block(c, Vector3i(k * 4 + (row % 2) * 2, 0, row * 2), int(pal["brick_2x4_x"]), 0)
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, w.build_chunk_chamfer_mesh(c, BEVEL))
	return mesh


func _material(path: String) -> ShaderMaterial:
	var sm := ShaderMaterial.new()
	sm.shader = load(path)
	return sm


func _measure() -> float:
	for i in 20:
		await process_frame
	var t := []
	for i in FRAMES:
		await RenderingServer.frame_post_draw
		t.append(RenderingServer.viewport_get_measured_render_time_gpu(_view.get_viewport_rid()))
	t.sort()
	return t[t.size() / 2]


func _run() -> void:
	print("wood cost probe")
	if DisplayServer.get_name() == "headless":
		print("  needs a renderer")
		quit(1)
		return
	_stage()
	var w := BrickWorld.new()
	var pal := BrickPalette.bake(w)
	var pla := _wall(w, pal, 0)
	var wood := _wall(w, pal, 10)
	var fw := BrickWorld.new()
	var floor_mesh := _floor(fw, BrickPalette.bake(fw))
	var s := BrickWorld.get_stud_metres()
	var p := BrickWorld.get_plate_metres()
	var wall_eye := [Vector3(19 * s, 50 * p, -3.0), Vector3(19 * s, 50 * p, 0)]
	# The floor's middle, from 3 m above and a little back.
	var mid := Vector3(22 * s, 3 * p, 22 * s)
	var floor_eye := [mid + Vector3(0, 3.0, -1.2), mid]
	_mi = MeshInstance3D.new()
	_mi.set_instance_shader_parameter("geo_bevel", 1.0)
	_view.add_child(_mi)

	var current := _material("res://shaders/brick.gdshader")
	var configs := {
		"pla": [pla, current, {}],
		"pla_drawn": [pla, current, {"print_bead_texture": false}],
		"pla_top": [floor_mesh, current, {}, true],
		"pla_top_drawn": [floor_mesh, current, {"print_bead_texture": false}, true],
		"wood_pbr": [wood, current, {}],
		"wood_colour": [wood, current, {"pbr_range": 0.0}],
		"wood_flat": [wood, current, {"pbr_far_range": 0.0}],
	}
	var got := {}
	for round_ in 2:
		for key in configs:
			var cfg: Array = configs[key]
			var mat: ShaderMaterial = (cfg[1] as ShaderMaterial).duplicate()
			for k in cfg[2]:
				mat.set_shader_parameter(k, cfg[2][k])
			var eye: Array = floor_eye if cfg.size() > 3 else wall_eye
			_cam.look_at_from_position(eye[0], eye[1])
			_mi.mesh = cfg[0]
			_mi.material_override = mat
			var ms: float = await _measure()
			got[key] = got.get(key, []) + [ms]
	print("  GPU ms a frame, median of %d, two rounds:" % FRAMES)
	for key in got:
		print("    %-12s %s" % [key, ", ".join(got[key].map(func(v): return "%.2f" % v))])
	quit(0)
