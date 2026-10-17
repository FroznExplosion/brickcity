extends SceneTree

## Close-ups of printed bricks under each finish (BrickMaterials.set_look):
## sides with their 57 layers, a top with its walls and infill, a bottom off
## the bed, and a wall at range for the anisotropic sheen. Pictures, not
## checks: look at them.
##
##     godot --path . --script res://tools/print_look_shot.gd -- --out=<dir> [--looks=glass,pei]
##
## Not headless (it renders; the test window draws at 1280x720 -- no
## --resolution). Writes <dir>/print_look_<look>_<view>.png. The bricks are the
## chamfered mesh, as anything this close is drawn (BrickNear), and the studs
## come from BrickWorld.get_chunk_studs, as every stud in the game does. A
## floor of 2x4s both ways round, 2x2s and a 1x4 shows whether neighbouring
## tops and their studs agree; a 2x4, a 1x4 and a 2x2 hang in the air to be
## seen from below. The look is set in memory only and put back as it was:
## a pass never saves settings.

const LOOKS := [
	["glass", BrickMaterials.Finish.PRINTED, BrickMaterials.Bed.GLASS],
	["pei", BrickMaterials.Finish.PRINTED, BrickMaterials.Bed.SMOOTH_PEI],
	["textured", BrickMaterials.Finish.PRINTED, BrickMaterials.Bed.TEXTURED_PEI],
	["moulded", BrickMaterials.Finish.MOULDED, BrickMaterials.Bed.GLASS],
]
## [name, camera position, look-at point]
const VIEWS := [
	["side", Vector3(1.05, 0.62, 1.55), Vector3(0.35, 0.45, 0.6)],
	["skin", Vector3(0.72, 1.12, 1.88), Vector3(0.62, 0.84, 1.68)],
	["stud", Vector3(0.5, 1.12, 0.95), Vector3(0.15, 0.9, 0.55)],
	["top", Vector3(0.55, 1.55, 1.25), Vector3(0.35, 0.85, 0.55)],
	["bottom", Vector3(2.2, 0.05, 1.3), Vector3(2.45, 0.6, 0.6)],
	["under", Vector3(3.3, 0.15, 1.5), Vector3(3.3, 0.84, 0.35)],
	["tops", Vector3(6.2, 1.25, 5.9), Vector3(6.2, 0.42, 3.9)],
	["tops_close", Vector3(5.6, 0.9, 4.1), Vector3(5.6, 0.42, 3.4)],
	["seam", Vector3(-0.42, 0.3, -0.3), Vector3(0.05, 0.2, 0.05)],
	["corner", Vector3(6.6, 0.62, 3.85), Vector3(6.3, 0.44, 3.5)],
	["shapes", Vector3(2.3, 1.1, 8.6), Vector3(2.3, 0.25, 6.0)],
	["shapes_close", Vector3(1.0, 0.75, 7.0), Vector3(0.8, 0.2, 6.0)],
	["arch_close", Vector3(5.95, 0.4, 7.1), Vector3(5.95, 0.25, 5.75)],
	["wall", Vector3(6.5, 1.6, 9.0), Vector3(5.6, 0.8, 0.7)],
	# The ceiling (ROOM, away from the rest, so it shades nothing of it).
	["ceiling", Vector3(41.4, 0.9, 4.2), Vector3(42.6, 2.3, 3.0)],
	["ceiling_close", Vector3(42.2, 1.6, 3.6), Vector3(42.5, 2.3, 3.1)],
	["ledge", Vector3(41.0, 1.4, 5.6), Vector3(41.5, 2.6, 4.4)],
	# Terraces of bricks at range, their studs drawn by BrickNear as in the
	# game: cards past 18 m (_card on, _nocard with that ring off).
	["far22_card", Vector3(84.0, 8.0, 30.0), Vector3(84.0, 1.0, 4.0)],
	["far22_nocard", Vector3(84.0, 8.0, 30.0), Vector3(84.0, 1.0, 4.0), 0.0],
	["far35_card", Vector3(84.0, 12.0, 43.0), Vector3(84.0, 1.0, 4.0)],
	["far35_nocard", Vector3(84.0, 12.0, 43.0), Vector3(84.0, 1.0, 4.0), 0.0],
	["far17", Vector3(84.0, 6.5, 24.0), Vector3(84.0, 1.0, 4.0)],
	# The same through a long lens: the tiers at their distance, blown up.
	["far22_card_zoom", Vector3(84.0, 8.0, 30.0), Vector3(84.0, 1.0, 4.0), 45.0, 12.0],
	["far22_nocard_zoom", Vector3(84.0, 8.0, 30.0), Vector3(84.0, 1.0, 4.0), 0.0, 12.0],
	["far17_zoom", Vector3(84.0, 6.5, 24.0), Vector3(84.0, 1.0, 4.0), 45.0, 12.0],
	# One top, through a very long lens: as a card at 30 m, a square post at 15.
	["one_card", Vector3(84.0, 8.0, 30.0), Vector3(84.2, 2.55, 0.7), 45.0, 2.5],
	["one_square", Vector3(84.0, 4.5, 15.5), Vector3(84.2, 2.55, 0.7), 45.0, 5.0],
	# The same lens with the detail left at the bare distance: the far tiers
	# themselves, magnified (the views above are a scope, and get theirs back).
	["one_card_raw", Vector3(84.0, 8.0, 30.0), Vector3(84.2, 2.55, 0.7), 70.0, 2.5, false],
	["one_card_high", Vector3(84.0, 22.0, 18.0), Vector3(84.2, 2.55, 0.7), 70.0, 2.5, false],
]
const ROOM := Vector3(40, 0, 0)
const FAR := Vector3(80, 0, 0)
var _near: BrickNear

var _out := "user://"
var _looks := ["glass"]
var _shots: Array = []
var _frame := 0
var _cam: Camera3D
var _was: Array


func _init() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.substr(6)
		elif a.begins_with("--looks="):
			_looks = Array(a.substr(8).split(","))
	BrickMaterials.load_look()
	_was = [BrickMaterials.finish, BrickMaterials.bed]
	_build()
	for look in LOOKS:
		if not _looks.has(look[0]):
			continue
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
	# A red 2x4 on the ground with a blue one on top of it, a yellow 2x4
	# hanging in the air to be seen from below, and a white wall for range.
	var red := w.place_block(c, Vector3i(0, 0, 0), pal["brick_2x4_z"], 4)      # red
	var blue := w.place_block(c, Vector3i(0, 3, 1), pal["brick_2x4_z"], 8)      # blue
	var yel := w.place_block(c, Vector3i(6, 6, 0), pal["brick_2x4_z"], 6)      # yellow
	# Beside it in the air, a 1x4 and a 2x2: the three undersides a part has.
	w.place_block(c, Vector3i(9, 6, 0), pal["brick_1x4_z"], 6)
	w.place_block(c, Vector3i(11, 6, 0), pal["brick_2x2"], 6)
	for y in 4:
		for i in 3:
			w.place_block(c, Vector3i(10 + i * 4 + (y % 2) * 2, y * 3, 2), pal["brick_2x4_x"], 0)
	# A floor of tops, every way round: does each brick agree with its studs,
	# and with its neighbours?
	var field := [
		["brick_2x4_x", Vector3i(14, 0, 8), 2], ["brick_2x4_x", Vector3i(14, 0, 10), 0],
		["brick_2x4_z", Vector3i(18, 0, 8), 4], ["brick_2x2", Vector3i(20, 0, 8), 8],
		["brick_1x4_z", Vector3i(20, 0, 10), 6], ["brick_2x2", Vector3i(14, 0, 12), 4],
		["brick_2x4_x", Vector3i(16, 0, 12), 8], ["brick_2x2", Vector3i(21, 0, 10), 0],
	]
	for f in field:
		w.place_block(c, f[1], pal[f[0]], f[2])
	# Two wall bricks standing on that floor, side by side: the foot of a wall,
	# a wall seam coming down to it, a floor seam running up to it -- the
	# inside corner, seen from a hand's breadth (corner view).
	w.place_block(c, Vector3i(14, 3, 8), pal["brick_2x4_x"], 2)
	w.place_block(c, Vector3i(18, 3, 8), pal["brick_2x4_x"], 2)
	# A row of the parts that are not boxes -- authored surfaces, every one:
	# slopes, a cheese, a round brick, a curve, an arch.
	var x := 0
	for name in ["slope_2x2_y0", "slope_2x4_y0", "cheese_2x2_y0", "round_2x2", "curve_2x2_y0",
			"arch_1x4_x", "round_1x1"]:
		if not pal.has(name):
			print("print_look_shot: no part ", name)
			continue
		var arch: int = pal[name]
		w.place_block(c, Vector3i(x, 0, 16), arch, [4, 8, 6, 0, 2][x % 5])
		x += w.get_archetype_size(arch).x + 1
	for b in [red, blue, yel]:
		w.set_block_material(c, b, 0)
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/brick.gdshader")
	BrickMaterials.add_glass(mat)
	var arrays: Array = w.build_chunk_chamfer_mesh(c, BrickNear.BEVEL)
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	root3.add_child(mi)
	mi.set_instance_shader_parameter("geo_bevel", 1.0)

	var stud_mat := ShaderMaterial.new()
	stud_mat.shader = load("res://shaders/printed.gdshader")
	stud_mat.set_shader_parameter("top_mode", 1)
	stud_mat.set_shader_parameter("contour_sides", PieceMeshes.SIDES)
	stud_mat.set_shader_parameter("contour_radius", PieceMeshes.STUD_R * PieceMeshes.STUD_TAPER)
	var buffer: PackedFloat32Array = w.get_chunk_studs(c)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = PieceMeshes.stud()
	@warning_ignore("integer_division")
	mm.instance_count = buffer.size() / 16
	mm.set_buffer(buffer)
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = stud_mat
	root3.add_child(mmi)

	# A ceiling overhead, as a storey's floor is seen from the room under it:
	# 2x4s in a running bond, its front edge a ledge with a wall standing on
	# it (ceiling, ledge views).
	var room := w.create_chunk(Vector3i.ZERO, Vector3i(16, 24, 16))
	for row in 6:
		for k in 4:
			var xx := k * 4 + (row % 2) * 2
			if xx + 4 <= 16:
				w.place_block(room, Vector3i(xx, 15, row * 2), pal["brick_2x4_x"], [0, 2, 4][(row + k) % 3])
	for xx in [0, 4, 8]:
		w.place_block(room, Vector3i(xx, 18, 10), pal["brick_2x4_x"], 6)
	w.place_block(room, Vector3i(2, 21, 10), pal["brick_2x4_x"], 6)
	var room_arrays: Array = w.build_chunk_chamfer_mesh(room, BrickNear.BEVEL)
	var room_mesh := ArrayMesh.new()
	room_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, room_arrays)
	var rmi := MeshInstance3D.new()
	rmi.mesh = room_mesh
	rmi.material_override = mat
	rmi.position = ROOM
	root3.add_child(rmi)
	rmi.set_instance_shader_parameter("geo_bevel", 1.0)

	# Terraces for range: courses stepping back so every top shows.
	var far := w.create_chunk(Vector3i.ZERO, Vector3i(24, 18, 24))
	for course in 6:
		for z in range(0, 21 - course * 4, 4):
			for xx in range(0, 23, 2):
				w.place_block(far, Vector3i(xx, course * 3, z), pal["brick_2x4_z"],
						[0, 2, 4, 6, 8][(course + xx / 2 + z / 4) % 5])
	var far_arrays: Array = w.build_chunk_mesh(far)
	var far_mesh := ArrayMesh.new()
	far_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, far_arrays)
	var fmi := MeshInstance3D.new()
	fmi.mesh = far_mesh
	fmi.material_override = mat
	fmi.position = FAR
	root3.add_child(fmi)
	_near = BrickNear.new(w)
	_near.track(fmi, far)

	_cam = Camera3D.new()
	_cam.fov = 50.0
	root3.add_child(_cam)


func _process(_d: float) -> bool:
	var i := _frame / 6
	var phase := _frame % 6
	_frame += 1
	if i >= _shots.size():
		BrickMaterials.set_look(_was[0], _was[1], false)
		quit()
		return false
	var look: Array = _shots[i][0]
	var v: Array = _shots[i][1]
	if phase == 0:
		BrickMaterials.set_look(look[1], look[2], false)
		_cam.look_at_from_position(v[1], v[2])
		BrickNear.stud_card_radius = v[3] if v.size() > 3 else 70.0
		_cam.fov = v[4] if v.size() > 4 else 50.0
		# A long lens is a scope: detail goes by distance over the zoom, as
		# the city does it (lod_zoom, BrickNear.zoom).
		_near.zoom = tan(deg_to_rad(25.0)) / tan(deg_to_rad(_cam.fov * 0.5)) \
				if v.size() <= 5 or v[5] else 1.0
		RenderingServer.global_shader_parameter_set(&"lod_zoom", 1.0 / _near.zoom)
		_near.settle(_cam.global_position)
	elif phase == 5:
		var path := "%s/print_look_%s_%s.png" % [_out, look[0], v[0]]
		get_root().get_texture().get_image().save_png(path)
		print("saved ", path)
	return false
