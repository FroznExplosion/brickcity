extends SceneTree

## The real print beside the game's: every extrusion of a sliced part, drawn
## as the bead it lays down, next to the same part as the game draws it, the
## same size, under the same sky and sun, from the same camera. Pictures, not
## checks (Docs/PrintLook.md says what they showed).
##
##     godot --path . --script res://tools/toolpath_compare.gd -- --gcode=<dir> --out=<dir>
##         [--pieces=brick_2x4,slope_2x2,...]
##
## Not headless. <dir> holds PrusaSlicer G-code named after the part
## (brick_2x4.gcode, sliced as Docs/PrintLook.md 1 says). Writes
## <out>/tp_<part>_<view>_real.png and _game.png. A bead is a flattened
## cylinder along each extruding move, as wide as the move's ;WIDTH and as
## tall as its layer, scaled 1:43.75 like everything else; the part is put
## square to the game's grid and the same way round.

const MM := 0.04375   # metres a millimetre at 1:43.75 (a stud, 8 mm, is 0.35 m)
const GAP := 3.0                  # metres between the real part and the game's
## [part, its palette name]
const PIECES := [
	["brick_2x4", "brick_2x4_x"], ["brick_1x2", "brick_1x2_x"], ["plate_2x2", "plate_2x2"],
	["tile_2x2", "tile_2x2"], ["slope_2x2", "slope_2x2_y0"], ["slope_2x4", "slope_2x4_y0"],
	["round_2x2", "round_2x2"], ["round_1x1", "round_1x1"], ["curve_2x2", "curve_2x2_y0"],
	["arch_1x4", "arch_1x4_x"],
]
## [view, camera offset from the part's top centre, look-at offset] -- metres.
const VIEWS := [
	["top", Vector3(0.0, 0.55, 0.42), Vector3(0.0, -0.02, 0.0)],
	["top_edge", Vector3(0.32, 0.3, 0.42), Vector3(0.12, -0.03, 0.1)],
	["stud", Vector3(0.12, 0.22, 0.24), Vector3(0.0, 0.0, 0.0)],
	["side", Vector3(0.25, -0.15, 0.7), Vector3(0.0, -0.22, 0.0)],
	["corner", Vector3(0.5, -0.05, 0.6), Vector3(0.18, -0.2, 0.12)],
	["under", Vector3(0.1, -0.95, 0.35), Vector3(0.0, -0.4, 0.0)],
	# A hand's breadth from the top between the studs, and from the side.
	["macro_top", Vector3(0.0, 0.16, 0.06), Vector3(0.0, 0.0, 0.0)],
	["macro_side", Vector3(0.06, -0.2, 0.62), Vector3(0.06, -0.21, 0.0)],
]

var _gcode_dir := ""
var _out := "user://"
var _want: Array = []
var _shots: Array = []   # [piece name, view, camera xf real, camera xf game]
var _frame := 0
var _cam: Camera3D


func _init() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--gcode="):
			_gcode_dir = a.substr(8)
		elif a.begins_with("--out="):
			_out = a.substr(6)
		elif a.begins_with("--pieces="):
			_want = Array(a.substr(9).split(","))
	_build()


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
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/brick.gdshader")
	BrickMaterials.add_glass(mat)
	var stud_mat := ShaderMaterial.new()
	stud_mat.shader = load("res://shaders/printed.gdshader")
	stud_mat.set_shader_parameter("top_mode", 1)
	stud_mat.set_shader_parameter("contour_sides", PieceMeshes.SIDES)
	stud_mat.set_shader_parameter("contour_radius", PieceMeshes.STUD_R * PieceMeshes.STUD_TAPER)

	var row := 0
	for p in PIECES:
		if not _want.is_empty() and not _want.has(p[0]):
			continue
		var path := "%s/%s.gcode" % [_gcode_dir, p[0]]
		if not FileAccess.file_exists(path) or not pal.has(p[1]):
			print("toolpath_compare: skipping ", p[0])
			continue
		var at := Vector3(0.0, 0.0, row * 4.0)
		row += 1
		# The game's part, on its own chunk.
		var arch: int = pal[p[1]]
		var size: Vector3i = w.get_archetype_size(arch)
		var c := w.create_chunk(Vector3i.ZERO, size + Vector3i(2, 2, 2))
		w.place_block(c, Vector3i(1, 1, 1), arch, 4)
		var cs: Vector3 = w.get_cell_size()
		var arrays: Array = w.build_chunk_chamfer_mesh(c, BrickNear.BEVEL)
		var colour: Color = (arrays[Mesh.ARRAY_COLOR] as PackedColorArray)[0]
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		mi.material_override = mat
		# The part's low corner at `at` + GAP along x.
		var game_at := at + Vector3(GAP, 0.0, 0.0)
		mi.position = game_at - cs
		root3.add_child(mi)
		mi.set_instance_shader_parameter("geo_bevel", 1.0)
		var buffer: PackedFloat32Array = w.get_chunk_studs(c)
		if buffer.size() > 0:
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
			mmi.position = game_at - cs
			root3.add_child(mmi)
		var body := Vector3(size.x * cs.x, size.y * cs.y, size.z * cs.z)

		# The real one, bead by bead.
		var beads := _beads(path, body, colour)
		beads.position = at
		root3.add_child(beads)

		var top := Vector3(body.x * 0.5, body.y, body.z * 0.5)
		for v in VIEWS:
			var eye: Vector3 = top + v[1]
			var look: Vector3 = top + v[2]
			_shots.append([p[0], v[0], at + eye, at + look, game_at + eye, game_at + look])

	_cam = Camera3D.new()
	_cam.fov = 40.0
	_cam.near = 0.01
	root3.add_child(_cam)


## Every extruding move of the G-code as a bead, in a MultiMesh: a flattened
## cylinder as wide as the move's line and as tall as its layer, along the
## move and half a line past each end so the corners close. Put square to
## the game's axes the same way round as the part (`body`: its size there),
## its low corner at the origin.
func _beads(path: String, body: Vector3, colour: Color) -> MultiMeshInstance3D:
	var f := FileAccess.open(path, FileAccess.READ)
	var segs: Array = []   # [x0, y0, x1, y1, z, width, height]
	var x := 0.0
	var y := 0.0
	var z := 0.0
	var hgt := 0.2
	var width := 0.45
	var kind := ""
	while not f.eof_reached():
		var line := f.get_line()
		if line.begins_with(";Z:"):
			z = float(line.substr(3))
			continue
		if line.begins_with(";HEIGHT:"):
			hgt = float(line.substr(8))
			continue
		if line.begins_with(";WIDTH:"):
			width = float(line.substr(7))
			continue
		if line.begins_with(";TYPE:"):
			kind = line.substr(6).strip_edges()
			continue
		if not (line.begins_with("G1 ") or line.begins_with("G0 ")):
			continue
		var code := line.get_slice(";", 0)
		var nx := x
		var ny := y
		var extrudes := false
		for tok in code.split(" ", false):
			match tok[0]:
				"X": nx = float(tok.substr(1))
				"Y": ny = float(tok.substr(1))
				"E": extrudes = float(tok.substr(1)) > 0.0
		if extrudes and (nx != x or ny != y) and kind != "Skirt/Brim" and kind != "Custom":
			segs.append([x, y, nx, ny, z, width, hgt])
		x = nx
		y = ny
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for s in segs:
		lo = Vector2(minf(lo.x, minf(s[0], s[2])), minf(lo.y, minf(s[1], s[3])))
		hi = Vector2(maxf(hi.x, maxf(s[0], s[2])), maxf(hi.y, maxf(s[1], s[3])))
	# Long along the game's x if the part is: turned a quarter if the print
	# was long along its y.
	var span := (hi - lo) * MM
	var turn := (span.x > span.y) != (body.x > body.z) and absf(body.x - body.z) > 0.01
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	var cyl := CylinderMesh.new()
	cyl.top_radius = 1.0
	cyl.bottom_radius = 1.0
	cyl.height = 1.0
	cyl.radial_segments = 10
	cyl.rings = 1
	cyl.cap_top = false
	cyl.cap_bottom = false
	mm.mesh = cyl
	mm.instance_count = segs.size()
	for i in segs.size():
		var s: Array = segs[i]
		var a := _to_game(Vector2(s[0], s[1]) - lo, hi - lo, turn)
		var b := _to_game(Vector2(s[2], s[3]) - lo, hi - lo, turn)
		var w := float(s[5]) * MM
		var h := float(s[6]) * MM
		var zc := (float(s[4]) - float(s[6]) * 0.5) * MM
		var d := b - a
		var l := d.length()
		var along := Vector3(d.x, 0.0, d.y) / maxf(l, 1e-6)
		var across := Vector3(-along.z, 0.0, along.x)
		var basis := Basis(across * (w * 0.5), along * (l + w), Vector3.UP * (h * 0.5))
		var mid := (a + b) * 0.5
		mm.set_instance_transform(i, Transform3D(basis, Vector3(mid.x, zc, mid.y)))
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	var m := StandardMaterial3D.new()
	# The game's vertex colour is linear; a material's colour is sRGB.
	m.albedo_color = colour.linear_to_srgb()
	m.roughness = 0.42
	m.metallic_specular = 0.55
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	mmi.material_override = m
	print("toolpath_compare: %s, %d beads%s" % [path.get_file(), segs.size(), " (turned)" if turn else ""])
	return mmi


func _to_game(p: Vector2, span: Vector2, turn: bool) -> Vector2:
	# G-code y is the bed's depth; the game's z runs toward the viewer.
	var q := Vector2(p.x, span.y - p.y) * MM
	if turn:
		q = Vector2(span.y * MM - q.y, q.x)
	return q


func _process(_d: float) -> bool:
	@warning_ignore("integer_division")
	var i := _frame / 10
	var phase := _frame % 10
	_frame += 1
	if i >= _shots.size() * 2:
		quit()
		return false
	@warning_ignore("integer_division")
	var s: Array = _shots[i / 2]
	var game := i % 2 == 1
	if phase == 0:
		_cam.look_at_from_position(s[4] if game else s[2], s[5] if game else s[3])
	elif phase == 9:
		var path := "%s/tp_%s_%s_%s.png" % [_out, s[0], s[1], "game" if game else "real"]
		get_root().get_texture().get_image().save_png(path)
	return false
