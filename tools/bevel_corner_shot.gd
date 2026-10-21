extends SceneTree

## Seam junctions of the chamfered near mesh, drawn with the bevel blown up
## (6 cm, not BrickNear.BEVEL's 1.3) and seen square on from above and from
## below, so how a corner is cut can be read off the picture: two bricks side
## by side at an edge, and a running-bond T, on a ledge (over air) and resting
## on a course below. Pictures, not checks.
##
##     godot --path . --script res://tools/bevel_corner_shot.gd -- --out=<dir> [--bevel=0.06]
##             [--layout=wall|checker]
##
## `wall` is a wall one brick thick in stack bond, `checker` 1x1 bricks on
## edge touching only at their corners: where the corner posts go (2.6).
##
## Not headless. Writes <dir>/bevel_corner_<view>.png.

const VIEWS := [
	["above", Vector3(1.4, 6.0, 1.4), Vector3(1.4, 0.0, 1.4)],
	["below", Vector3(1.4, -6.0, 1.4), Vector3(1.4, 0.0, 1.4)],
	["above_angle", Vector3(2.4, 2.4, 3.4), Vector3(1.4, 0.84, 1.4)],
	["below_angle", Vector3(2.4, -0.4, 3.4), Vector3(1.4, 0.42, 1.4)],
]

var _out := "user://"
var _bevel := 0.06
var _layout := ""
var _cam: Camera3D
var _frame := 0


func _init() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.substr(6)
		elif a.begins_with("--bevel="):
			_bevel = float(a.substr(8))
		elif a.begins_with("--layout="):
			_layout = a.substr(9)
	var root3 := Node3D.new()
	get_root().add_child(root3)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.2, 0.2, 0.25)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.6, 0.6, 0.6)
	var we := WorldEnvironment.new()
	we.environment = env
	root3.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 30, 0)
	root3.add_child(sun)
	var sun2 := DirectionalLight3D.new()
	sun2.rotation_degrees = Vector3(50, -150, 0)
	sun2.light_energy = 0.5
	root3.add_child(sun2)

	var w := BrickWorld.new()
	var pal := BrickPalette.bake(w)
	var c := w.create_chunk(Vector3i.ZERO, Vector3i(16, 12, 16))
	if _layout == "wall":
		var run_x := -1
		for name in pal:
			if String(name).begins_with("brick_1x4") \
					and w.get_archetype_size(int(pal[name])) == Vector3i(4, 3, 1):
				run_x = int(pal[name])
		for course in 4:
			for k in 3:
				w.place_block(c, Vector3i(k * 4, course * 3, 2), run_x, (course + k) % 4 * 2)
	elif _layout == "checker":
		for a in 6:
			for b in 4:
				if (a + b) % 2 == 0:
					w.place_block(c, Vector3i(a + 1, b * 3, 2), pal["brick_1x1"], (a + b) % 4 * 2)
	else:
		# A course on the ground, and on it a course in running bond that
		# reaches out over its edge (a ledge) on +Z: 2x4s along X.
		for k in 3:
			w.place_block(c, Vector3i(k * 4, 0, 0), pal["brick_2x4_x"], [0, 2, 4][k])
			w.place_block(c, Vector3i(k * 4, 0, 2), pal["brick_2x4_x"], [6, 8, 0][k])
		for k in 3:
			w.place_block(c, Vector3i(k * 4 + 2, 3, 2), pal["brick_2x4_x"], [2, 4, 6][k])
			w.place_block(c, Vector3i(k * 4, 3, 4), pal["brick_2x4_x"], [8, 0, 2][k])
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/brick.gdshader")
	mat.set_shader_parameter("tier_debug", true)
	var arrays: Array = w.build_chunk_chamfer_mesh(c, _bevel)
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	root3.add_child(mi)
	mi.set_instance_shader_parameter("geo_bevel", 1.0)
	_cam = Camera3D.new()
	root3.add_child(_cam)
	_cam.current = true


## Wall and checker: square on, and from the side, at the junction at
## (4 studs, 6 plates) on the wall's front (z = 3 studs).
const FRONT_VIEWS := [
	["front", Vector3(1.4, 0.84, 3.2), Vector3(1.4, 0.84, 1.05)],
	["front_angle", Vector3(2.3, 1.3, 2.4), Vector3(1.4, 0.84, 1.05)],
]


func _process(_d: float) -> bool:
	var i := _frame / 6
	var phase := _frame % 6
	_frame += 1
	var views: Array = FRONT_VIEWS if _layout != "" else VIEWS
	if i >= views.size():
		quit()
		return false
	var v: Array = views[i]
	if phase == 0:
		var up := Vector3.FORWARD if absf((v[2] - v[1]).normalized().y) > 0.99 else Vector3.UP
		_cam.look_at_from_position(v[1], v[2], up)
		_cam.fov = 30.0
	elif phase == 5:
		var path := "%s/bevel_corner_%s%s.png" % [_out, (_layout + "_") if _layout != "" else "", v[0]]
		get_root().get_texture().get_image().save_png(path)
		print("saved ", path)
	return false
