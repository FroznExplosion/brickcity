extends SceneTree

## PBR texture sets: wood, metal, stone, leaves (Docs/PbrWood.md).
##
##     godot --headless --path . --script res://tools/wood_probe.gd       numbers only
##     godot --path . --script res://tools/wood_probe.gd                  and pictures
##
## The numbers: every brick's vertex alpha carries its material in the low
## five bits and its grain axis in the two above (brick_grid.h grain_axis), in
## the flat mesh, the chamfered mesh and the studs alike -- a board along X
## says X, the same board turned says Z, a post says Y, a square brick says
## what its grid cell's hash says and keeps it when the piece breaks off; and
## a brick of any other material still reads as that material whatever its
## grain bits say (brick_material_id masks them).
##
## Not headless it also leaves pictures in shots/wood_*.png: two boards
## stacked and a turned one beside them, a post, a slope and a round, each
## from a metre or two, and the lot from 25 m (colour only) and 70 m (flat).
## What to look for: the grain runs on round every edge of a brick, and from
## one board to the one stacked on it. Then the same build in metal, stone
## and leaves (shots/wood_<material>_*.png), and for every set with a normal
## map, that it is lighting (_check_relief).

const BEVEL := 0.013
const WOOD := 10
const METAL := 11
const STONE := 12
const LEAF := 13
const SIZE := Vector2i(1280, 720)

var _passed := 0
var _failed := 0
var _view: SubViewport
var _cam: Camera3D
var _holder: Node3D
var _sun: DirectionalLight3D
var _mat: ShaderMaterial


func _initialize() -> void:
	_run.call_deferred()


func _ok(what: String, cond: bool, detail := "") -> void:
	if cond:
		_passed += 1
	else:
		_failed += 1
	print("  %s %s%s" % ["ok  " if cond else "FAIL", what, ("  " + detail) if detail != "" else ""])


## The alpha byte, as brick_materials.gdshaderinc reads it.
static func _code(a: float) -> int:
	return roundi((1.0 - a) * 255.0)


static func _material(a: float) -> int:
	return _code(a) & 31


static func _grain(a: float) -> int:
	return (_code(a) >> 5) & 3


## Which (material, grain) pairs the triangles of the brick in `box` carry:
## a triangle's middle, a centimetre in behind its face, is inside its brick.
static func _pairs_in(arrays: Array, box: AABB) -> Dictionary:
	var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var nn: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var col: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var out := {}
	for i in range(0, idx.size() - 2, 3):
		var a := idx[i]
		if a == idx[i + 1] or idx[i + 1] == idx[i + 2]:
			continue
		var mid := (v[a] + v[idx[i + 1]] + v[idx[i + 2]]) / 3.0 - nn[a] * 0.01
		if box.has_point(mid):
			out[Vector2i(_material(col[a].a), _grain(col[a].a))] = true
	return out


func _place(w: BrickWorld, c: int, pal: Dictionary, part: String, cell: Vector3i, mat: int) -> int:
	# Leaves take filament colours, whose first is white: green (7) for them.
	var b := w.place_block(c, cell, int(pal[part]), 7 if mat == LEAF else 0)
	if b >= 0:
		w.set_block_material(c, b, mat)
	return b


## The test build: chunk cells, a stud across and a plate up.
##   two 2x4 boards along X, stacked; a 4x2 turned beside them; a post; a
##   slope and a round; and a PLA brick for the masks.
func _build(w: BrickWorld, pal: Dictionary, origin: Vector3i, mat := WOOD) -> Dictionary:
	var c := w.create_chunk(origin, Vector3i(24, 24, 12))
	var o := origin
	var parts := {
		"low": _place(w, c, pal, "brick_2x4_x", o + Vector3i(0, 0, 0), mat),
		"high": _place(w, c, pal, "brick_2x4_x", o + Vector3i(0, 3, 0), mat),
		"turned": _place(w, c, pal, "brick_2x4_z", o + Vector3i(5, 0, 0), mat),
		"square": _place(w, c, pal, "brick_2x2", o + Vector3i(5, 3, 0), mat),
		"post": _place(w, c, pal, "column_1x1", o + Vector3i(9, 0, 1), mat),
		# Turned, so its grain bits are not zero.
		"pla": _place(w, c, pal, "brick_2x4_z", o + Vector3i(12, 0, 0), 0),
	}
	for part in ["slope_2x2", "slope_2x2_x", "slope_2x4_x", "round_2x2"]:
		if pal.has(part):
			parts[part] = _place(w, c, pal, part, o + Vector3i(12 + (parts.size() - 6) * 3, 3, 4), mat)
	return {"chunk": c, "blocks": parts}


func _box(w: BrickWorld, c: int, block: int) -> AABB:
	for b in w.get_block_boxes(c):
		if int(b.block) == block:
			return AABB(b.pos - b.size * 0.5, b.size)
	return AABB()


func _check_numbers(w: BrickWorld, pal: Dictionary) -> void:
	print("the grain rides in the vertex alpha")
	var built := _build(w, pal, Vector3i.ZERO)
	var c: int = built.chunk
	var blocks: Dictionary = built.blocks
	var flat: Array = w.build_chunk_mesh(c)
	var near: Array = w.build_chunk_chamfer_mesh(c, BEVEL)
	var want := {"low": 0, "high": 0, "turned": 1, "post": 2}
	for key in want:
		var box := _box(w, c, int(blocks[key]))
		var f := _pairs_in(flat, box)
		var n := _pairs_in(near, box)
		var pair := Vector2i(WOOD, int(want[key]))
		_ok("%s: wood, grain %d, flat and chamfered" % [key, want[key]],
				f.keys() == [pair] and n.keys() == [pair], "%s / %s" % [f.keys(), n.keys()])
	var sq := _pairs_in(flat, _box(w, c, int(blocks["square"])))
	_ok("a square brick picks X or Z", sq.size() == 1
			and (sq.has(Vector2i(WOOD, 0)) or sq.has(Vector2i(WOOD, 1))), "%s" % [sq.keys()])
	var pla := _pairs_in(flat, _box(w, c, int(blocks["pla"])))
	_ok("a PLA brick still reads as PLA past its grain bits", pla.keys() == [Vector2i(0, 1)],
			"%s" % [pla.keys()])

	# Every material, every grain, through the cut to eight bits the renderer
	# makes of a vertex colour -- truncated or rounded. Exact codes came out a
	# hair under their byte from 65 up, and a metal post (75) drew as stone.
	var cut_ok := true
	var cut_bad := []
	for m in BrickWorld.get_material_count():
		var cm := w.create_chunk(Vector3i.ZERO, Vector3i(16, 24, 8))
		for part in [["brick_2x4_x", Vector3i(0, 0, 0)], ["brick_2x4_z", Vector3i(5, 0, 0)],
				["column_1x1", Vector3i(9, 0, 1)]]:
			_place(w, cm, pal, part[0], part[1], m)
		for col in w.build_chunk_chamfer_mesh(cm, BEVEL)[Mesh.ARRAY_COLOR]:
			var a: float = (col as Color).a
			var exact := _code(a)
			for byte in [floori(a * 255.0), roundi(a * 255.0)]:
				if ((255 - byte) & 31) != m or (255 - byte) != exact:
					cut_ok = false
					if cut_bad.size() < 6:
						cut_bad.append([m, exact, 255 - byte])
	_ok("every material and grain survives the cut to eight bits", cut_ok, "%s" % [cut_bad])

	# Studs: the grain in the stud's own frame. A board along X has studs
	# unturned and grain X; the turned board's studs are turned a quarter, so
	# in THEIR frame its grain is X too.
	var buf: PackedFloat32Array = w.get_chunk_studs_section(c, -1)
	var stud_grain := {}
	for i in range(0, buf.size(), 16):
		var a := buf[i + 15]
		if _material(a) != WOOD:
			continue
		var turned := absf(buf[i + 2]) > 0.5   # the basis's x row takes z
		var g := _grain(a)
		if g != 2:
			stud_grain["turned" if turned else "plain"] = stud_grain.get(
					"turned" if turned else "plain", {})
			stud_grain["turned" if turned else "plain"][g] = true
	_ok("studs on a board along X: grain X in the stud's frame",
			stud_grain.get("plain", {}).has(0), "%s" % [stud_grain])

	# A square brick broken off keeps its grain: the hash is of the grid cell,
	# not the chunk's. The same brick at the same grid cell, in chunks that
	# start elsewhere -- as a piece's chunk starts at its own corner.
	var same := true
	var seen := []
	for start in [Vector3i(-3, 0, -2), Vector3i(5, 3, 0), Vector3i(-9, -6, -7)]:
		var c2 := w.create_chunk(start, Vector3i(16, 16, 16))
		var b2 := _place(w, c2, pal, "brick_2x2", Vector3i(5, 3, 0), WOOD)
		var got := _pairs_in(w.build_chunk_mesh(c2), _box(w, c2, b2)).keys()
		seen.append(got)
		same = same and got == sq.keys()
	_ok("a square brick's grain is its grid cell's, wherever its chunk starts", same,
			"%s, then %s" % [sq.keys(), seen])


## A viewport of its own, lit as the gap probe's.
func _stage() -> void:
	_view = SubViewport.new()
	_view.size = SIZE
	_view.own_world_3d = true
	_view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_view.msaa_3d = Viewport.MSAA_4X
	root.add_child(_view)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.55, 0.62, 0.7)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.7, 0.72, 0.76)
	# Dim enough that light oak in full sun is not clipped white: a clipped
	# face shows no relief at all, whatever the normal map does.
	env.ambient_light_energy = 0.3
	# Something to reflect: a metal is lit mostly by what it mirrors, and a flat
	# background colour gave it nothing -- dark, and its relief invisible.
	var sky := Sky.new()
	sky.sky_material = ProceduralSkyMaterial.new()
	env.sky = sky
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var we := WorldEnvironment.new()
	we.environment = env
	_view.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-38, 28, 0)
	sun.shadow_enabled = true
	sun.light_energy = 0.75
	_view.add_child(sun)
	_sun = sun
	_cam = Camera3D.new()
	_cam.fov = 60.0
	_cam.near = 0.02
	_cam.far = 400.0
	_view.add_child(_cam)
	_cam.current = true
	_holder = Node3D.new()
	_view.add_child(_holder)


func _show(w: BrickWorld, c: int) -> void:
	for n in _holder.get_children():
		n.free()
	var sm := ShaderMaterial.new()
	sm.shader = load("res://shaders/brick.gdshader")
	var mat := BrickMaterials.add_glass(sm)
	_mat = mat
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, w.build_chunk_chamfer_mesh(c, BEVEL))
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.set_instance_shader_parameter("geo_bevel", 1.0)
	_holder.add_child(mi)
	var buf: PackedFloat32Array = w.get_chunk_studs_section(c, -1)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = PieceMeshes.stud()
	@warning_ignore("integer_division")
	mm.instance_count = buf.size() / 16
	mm.buffer = buf
	var studs := MultiMeshInstance3D.new()
	studs.multimesh = mm
	studs.material_override = TerrainTile.stud_material()
	_holder.add_child(studs)


func _shot(name: String, eye: Vector3, at: Vector3) -> void:
	_cam.look_at_from_position(eye, at)
	for i in 4:
		await process_frame
	await RenderingServer.frame_post_draw
	var img := _view.get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://shots"))
	img.save_png("res://shots/wood_%s.png" % name)
	# Not a blank frame: some pixel is neither the sky nor black.
	var lit := 0
	var sky := Color(0.55, 0.62, 0.7)
	for y in range(0, img.get_height(), 16):
		for x in range(0, img.get_width(), 16):
			var p := img.get_pixel(x, y)
			if absf(p.r - sky.r) + absf(p.g - sky.g) + absf(p.b - sky.b) > 0.1 and p.get_luminance() > 0.02:
				lit += 1
	_ok("picture %s shows bricks" % name, lit > 20, "%d samples" % lit)


func _run() -> void:
	print("wood probe")
	var w := BrickWorld.new()
	var pal := BrickPalette.bake(w)
	_check_numbers(w, pal)
	if DisplayServer.get_name() == "headless":
		print("\n(headless: no pictures)")
		print("\nwood probe: %d passed, %d failed" % [_passed, _failed])
		quit(1 if _failed > 0 else 0)
		return

	print("pictures, shots/wood_*.png")
	_stage()
	var built := _build(w, pal, Vector3i.ZERO)
	_show(w, built.chunk)
	var s := BrickWorld.get_stud_metres()
	var p := BrickWorld.get_plate_metres()
	# The stacked pair's near end corner: its end, a side, the top.
	var corner := Vector3(0, 6 * p, 0)
	await _shot("stack_corner", corner + Vector3(-1.1, 1.0, -1.2), corner + Vector3(1.0 * s, -1.0 * p, 0.8 * s))
	await _shot("stack_side", Vector3(2 * s, 3 * p, -1.6), Vector3(2 * s, 3 * p, s))
	await _shot("turned", Vector3(6 * s, 9 * p, -1.4), Vector3(7 * s, 3 * p, 2 * s))
	await _shot("post", Vector3(9.5 * s - 1.0, 10 * p, -1.0), Vector3(9.5 * s, 9 * p, 1.5 * s))
	await _shot("slopes", Vector3(16 * s, 12 * p, -1.0), Vector3(16 * s, 4 * p, 5 * s))
	await _shot("mid_25m", Vector3(6 * s, 8.0, -24.0), Vector3(6 * s, 0.5, 2 * s))
	await _shot("far_70m", Vector3(6 * s, 20.0, -66.0), Vector3(6 * s, 0.5, 2 * s))
	await _check_relief("wood", Vector3(2 * s, 3 * p, -1.6), Vector3(2 * s, 3 * p, s), 4.0)

	# The other sets, the same build. Stone is polished: its set has no
	# normal map to light. The last number is how much the relief must show:
	# brushed steel's is fine streaks (its map's spread is 0.06 across them,
	# 0.01 along) and it is lit mostly by what it mirrors, so a little; wood's
	# and the leaves' are grooves and edges, so more.
	for m in [[METAL, "metal", 1.0], [STONE, "stone", 0.0], [LEAF, "leaf", 3.0]]:
		var b := _build(w, pal, Vector3i.ZERO, m[0])
		_show(w, b.chunk)
		await _shot("%s_corner" % m[1], corner + Vector3(-1.1, 1.0, -1.2),
				corner + Vector3(1.0 * s, -1.0 * p, 0.8 * s))
		await _shot("%s_turned" % m[1], Vector3(6 * s, 9 * p, -1.4), Vector3(7 * s, 3 * p, 2 * s))
		if m[2] > 0.0:
			await _check_relief(m[1], Vector3(2 * s, 3 * p, -1.6), Vector3(2 * s, 3 * p, s), m[2])
	print("\nwood probe: %d passed, %d failed" % [_passed, _failed])
	quit(1 if _failed > 0 else 0)


## Luminance, 0-255, of the middle of the view: the side of the stacked pair.
func _luma(tag: String) -> PackedFloat32Array:
	for i in 4:
		await process_frame
	await RenderingServer.frame_post_draw
	var img := _view.get_texture().get_image()
	img.save_png("res://shots/wood_relief_%s.png" % tag)
	var out := PackedFloat32Array()
	for y in range(240, 480, 2):
		for x in range(420, 860, 2):
			out.append(img.get_pixel(x, y).get_luminance() * 255.0)
	return out


static func _diff(a: PackedFloat32Array, b: PackedFloat32Array) -> float:
	var d := 0.0
	for i in a.size():
		d += absf(a[i] - b[i])
	return d / maxf(a.size(), 1)


## The normal map is LIGHTING, not paint: the same face under the same sun
## with the relief off and at its default should differ by more than a shade
## -- grooves turned from the light, ridges to it. The sun is high, raking
## down across the grain, as relief shows best (a sun behind the face lights
## none of it: the first version of this check put it there and measured
## nothing; one square on, or along the grain, shows little, as on real wood).
## And it must still show from under a metre: shots/wood_<what>_close.png.
func _check_relief(what: String, eye: Vector3, at: Vector3, least: float) -> void:
	_cam.look_at_from_position(eye, at)
	_sun.rotation_degrees = Vector3(-62, 195, 0)
	_mat.set_shader_parameter("pbr_bump", 0.0)
	var off := await _luma("%s_off" % what)
	_mat.set_shader_parameter("pbr_bump", null)
	var on := await _luma("%s_on" % what)
	var d := _diff(off, on)
	_ok("%s: the normal map is lighting" % what, d > least,
			"%.1f levels in 255 between relief off and on" % d)
	await _shot("%s_close" % what, at + (eye - at).normalized() * 0.6 + Vector3(0, 0.15, 0), at)
	_sun.rotation_degrees = Vector3(-38, 28, 0)
