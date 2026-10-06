extends SceneTree

## Close-ups of printed bricks under each finish (BrickMaterials.set_look):
## sides with their 57 layers, a top with its walls and infill, a bottom off
## the bed, and a wall at range for the anisotropic sheen. Pictures, not
## checks: look at them.
##
##     godot --path . --resolution 1280x720 --script res://tools/print_look_shot.gd -- --out=<dir>
##
## Not headless (it renders). Writes <dir>/print_look_<look>_<view>.png, and
## leaves the look as it found it.

const LOOKS := [
	["glass", BrickMaterials.Finish.PRINTED, BrickMaterials.Bed.GLASS],
	["pei", BrickMaterials.Finish.PRINTED, BrickMaterials.Bed.SMOOTH_PEI],
	["textured", BrickMaterials.Finish.PRINTED, BrickMaterials.Bed.TEXTURED_PEI],
	["moulded", BrickMaterials.Finish.MOULDED, BrickMaterials.Bed.GLASS],
]
## [name, camera position, look-at point]
const VIEWS := [
	["side", Vector3(1.05, 0.62, 1.55), Vector3(0.35, 0.45, 0.6)],
	["top", Vector3(0.55, 1.55, 1.25), Vector3(0.35, 0.85, 0.55)],
	["bottom", Vector3(2.2, 0.05, 1.3), Vector3(2.45, 0.6, 0.6)],
	["wall", Vector3(6.5, 1.6, 9.0), Vector3(5.6, 0.8, 0.7)],
]

var _out := "user://"
var _shots: Array = []
var _frame := 0
var _cam: Camera3D
var _was: Array


func _init() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.substr(6)
	BrickMaterials.load_look()
	_was = [BrickMaterials.finish, BrickMaterials.bed]
	_build()
	for look in LOOKS:
		for v in VIEWS:
			_shots.append([look, v])


func _build() -> void:
	var root3 := Node3D.new()
	get_root().add_child(root3)

	var env := Environment.new()
	var sky := Sky.new()
	sky.sky_material = ProceduralSkyMaterial.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var we := WorldEnvironment.new()
	we.environment = env
	root3.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-38, 35, 0)
	sun.shadow_enabled = true
	root3.add_child(sun)

	var w := BrickWorld.new()
	var pal := BrickPalette.bake(w)
	var c := w.create_chunk(Vector3i.ZERO, Vector3i(24, 24, 24))
	var studs: Array[Vector3] = []
	# A red 2x4 on the ground with a blue one on top of it, a yellow 2x4
	# hanging in the air to be seen from below, and a white wall for range.
	var red := w.place_block(c, Vector3i(0, 0, 0), pal["brick_2x4_z"], 4)      # red
	var blue := w.place_block(c, Vector3i(0, 3, 1), pal["brick_2x4_z"], 8)      # blue
	var yel := w.place_block(c, Vector3i(6, 6, 0), pal["brick_2x4_z"], 6)      # yellow
	for x in 2:
		for z in 4:
			if z == 0:
				studs.append(Vector3(x + 0.5, 3, z + 0.5))
			studs.append(Vector3(x + 0.5, 6, z + 1.5))
	for y in 4:
		for i in 3:
			w.place_block(c, Vector3i(10 + i * 4 + (y % 2) * 2, y * 3, 2), pal["brick_2x4_x"], 0)
	for b in [red, blue, yel]:
		w.set_block_material(c, b, 0)
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/brick.gdshader")
	BrickMaterials.add_glass(mat)
	var arrays: Array = w.build_chunk_mesh(c)
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	root3.add_child(mi)

	var stud_mat := ShaderMaterial.new()
	stud_mat.shader = load("res://shaders/printed.gdshader")
	stud_mat.set_shader_parameter("top_mode", 1)
	stud_mat.set_shader_parameter("contour_sides", PieceMeshes.SIDES)
	var stud := BrickWorld.get_stud_metres()
	var plate := stud * 0.4
	for s in studs:
		var smi := MeshInstance3D.new()
		smi.mesh = PieceMeshes.stud()
		smi.material_override = stud_mat
		smi.position = Vector3(s.x * stud, s.y * plate, s.z * stud)
		root3.add_child(smi)
	stud_mat.set_shader_parameter("tint", Color(0.13, 0.35, 0.68))

	_cam = Camera3D.new()
	_cam.fov = 50.0
	root3.add_child(_cam)


func _process(_d: float) -> bool:
	var i := _frame / 6
	var phase := _frame % 6
	_frame += 1
	if i >= _shots.size():
		BrickMaterials.set_look(_was[0], _was[1])
		quit()
		return false
	var look: Array = _shots[i][0]
	var v: Array = _shots[i][1]
	if phase == 0:
		BrickMaterials.set_look(look[1], look[2], false)
		_cam.look_at_from_position(v[1], v[2])
	elif phase == 5:
		var path := "%s/print_look_%s_%s.png" % [_out, look[0], v[0]]
		get_root().get_texture().get_image().save_png(path)
		print("saved ", path)
	return false
