extends SceneTree

## Does the chamfered brick mesh open the bricks? (Docs/BrickBevel.md;
## the terrain's version is tools/bevel_gap_probe.gd.)
##
##     godot --path . --script res://tools/brick_bevel_gap_probe.gd
##
## Not headless: it counts pixels. Inside every brick goes an unlit MAGENTA
## core, a centimetre in from each face -- inside the chamfered brick too,
## whose bevel cuts 13 mm off an edge and so 9 mm at most off the solid. A
## brick's own faces hide its core from every side, so a magenta pixel is a
## way IN: a slit where a bevelled edge meets a face nobody drew. Counted
## over many close views of a real tower's wall, of that wall shot through,
## and of a heap of every part in the palette thrown together any way they
## fit -- with the flat mesh (the check on the check) and with the chamfered
## one.
##
## "None" is not quite zero, for either mesh: where the corner of one triangle
## lies along the side of another the rasteriser leaves the odd pixel open,
## and a core shows through it -- one to four pixels in a view, the flat mesh
## as much as the chamfered. A slit is a PATCH: the smallest one this probe
## found while the mesh was being written was 36 pixels in one view, the
## largest 6,900. So a view may show LONE_PIXELS and no more, and the
## chamfered mesh no more in all than CRACK_RATE a view.
##
## It leaves the on/off pair in shots/brick_bevel_off.png and _on.png.

const MAGENTA := Color(1, 0, 1)
const CORE_INSET := 0.010
const BEVEL := 0.013
const SIZE := Vector2i(1280, 720)
const LONE_PIXELS := 8
const CRACK_RATE := 2.0

var _passed := 0
var _failed := 0
var _view: SubViewport
var _cam: Camera3D
var _mat: ShaderMaterial
var _core_mat: StandardMaterial3D
var _holder: Node3D
var _case_n := 0


func _initialize() -> void:
	_run.call_deferred()


func _ok(what: String, cond: bool, detail := "") -> void:
	if cond:
		_passed += 1
	else:
		_failed += 1
	print("  %s %s%s" % ["ok  " if cond else "FAIL", what, ("  " + detail) if detail != "" else ""])


func _magenta(img: Image) -> int:
	var n := 0
	for y in img.get_height():
		for x in img.get_width():
			var c := img.get_pixel(x, y)
			if c.r > 0.85 and c.b > 0.85 and c.g < 0.2:
				n += 1
	return n


## A stage of its own: a viewport with its own world, so the picture does not
## depend on the window (a test window is a speck, off the screen).
func _stage() -> void:
	_view = SubViewport.new()
	_view.size = SIZE
	_view.own_world_3d = true
	_view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_view.msaa_3d = Viewport.MSAA_DISABLED
	root.add_child(_view)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.55, 0.62, 0.7)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.7, 0.72, 0.76)
	env.ambient_light_energy = 0.6
	var we := WorldEnvironment.new()
	we.environment = env
	_view.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-48, 35, 0)
	sun.shadow_enabled = true
	_view.add_child(sun)
	_cam = Camera3D.new()
	_cam.fov = 60.0
	_cam.near = 0.02
	_view.add_child(_cam)
	_cam.current = true
	_holder = Node3D.new()
	_view.add_child(_holder)
	var sm := ShaderMaterial.new()
	sm.shader = load("res://shaders/brick.gdshader")
	_mat = BrickMaterials.add_glass(sm)
	_core_mat = StandardMaterial3D.new()
	_core_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_core_mat.albedo_color = MAGENTA
	_core_mat.cull_mode = BaseMaterial3D.CULL_DISABLED


## The bricks of a chunk, flat or chamfered, and a core in every live one.
func _show(w: BrickWorld, chunk: int, chamfered: bool) -> int:
	for c in _holder.get_children():
		c.free()
	var arrays: Array = w.build_chunk_chamfer_mesh(chunk, BEVEL) if chamfered \
			else w.build_chunk_mesh(chunk)
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = _mat
	_holder.add_child(mi)
	if chamfered:
		mi.set_instance_shader_parameter("geo_bevel", 1.0)
	var boxes: Array = w.get_block_boxes(chunk)
	var xf: Array[Transform3D] = []
	for b in boxes:
		if not b.alive:
			continue
		# An authored part (a round brick, a spiral step) is drawn as its shape,
		# not as the cells it fills: a core in a cell would stand out of it.
		if w.get_archetype_mesh_triangles(w.get_block_archetype(chunk, int(b.block))) > 0:
			continue
		var s: Vector3 = b.size - Vector3.ONE * (CORE_INSET * 2.0)
		xf.append(Transform3D(Basis.from_scale(s), b.pos))
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = BoxMesh.new()
	mm.instance_count = xf.size()
	for i in xf.size():
		mm.set_instance_transform(i, xf[i])
	var cores := MultiMeshInstance3D.new()
	cores.multimesh = mm
	cores.material_override = _core_mat
	cores.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_holder.add_child(cores)
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	@warning_ignore("integer_division")
	return idx.size() / 3


## Close views of the chunk: from all round and above and below it, each
## looking at a point of its own on the bricks.
func _views(w: BrickWorld, chunk: int, count: int, seed_: int) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_
	var boxes: Array = w.get_block_boxes(chunk)
	var alive := []
	var lo := Vector3(INF, INF, INF)
	var hi := -lo
	for b in boxes:
		if b.alive:
			alive.append(b)
			lo = lo.min(b.pos - b.size * 0.5)
			hi = hi.max(b.pos + b.size * 0.5)
	var out := []
	while out.size() < count and not alive.is_empty():
		var at: Dictionary = alive[rng.randi() % alive.size()]
		var dir := Vector3(rng.randf_range(-1, 1), rng.randf_range(-0.6, 1), rng.randf_range(-1, 1))
		if dir.length() < 0.2:
			continue
		dir = dir.normalized()
		var eye: Vector3 = at.pos + dir * rng.randf_range(0.5, 4.0)
		# Not from inside a brick: every face there is seen from behind.
		# nor with the near plane in one.
		var clear := true
		for d in [Vector3.ZERO, Vector3.RIGHT, Vector3.LEFT, Vector3.UP, Vector3.DOWN,
				Vector3.FORWARD, Vector3.BACK]:
			if w.block_at(chunk, w.world_to_grid(eye + d * 0.08)) >= 0:
				clear = false
		for b in alive:
			var h: Vector3 = b.size * 0.5 + Vector3.ONE * 0.08
			var rel: Vector3 = (eye - b.pos).abs()
			if rel.x < h.x and rel.y < h.y and rel.z < h.z:
				clear = false
				break
		if not clear:
			continue
		if absf(dir.y) > 0.98:
			continue
		out.append(Transform3D(Basis(), eye).looking_at(at.pos))
	return out


## Magenta over the views: [in all, in the worst one].
func _count(views: Array, tag: String, shot := "") -> Array:
	var total := 0
	var worst := 0
	var worst_i := -1
	for i in views.size():
		_cam.global_transform = views[i]
		for f in 2:
			await process_frame
		await RenderingServer.frame_post_draw
		var img := _view.get_texture().get_image()
		var n := _magenta(img)
		total += n
		if i == 0 and shot != "":
			img.save_png("res://shots/%s.png" % shot)
		if n > worst:
			worst = n
			worst_i = i
			img.save_png("res://shots/brick_bevel_gap_%s.png" % tag)
			if n > LONE_PIXELS:
				_zoom(img, tag)
	print("  [%s] magenta pixels over %d views: %d (worst view %d: %d)"
			% [tag, views.size(), total, worst_i, worst])
	return [total, worst]


## Where the magenta is in the worst view, cut out and blown up: which edge.
## The biggest patch of it -- a lone pixel is a crack between two triangles.
func _zoom(img: Image, tag: String) -> void:
	var cells := {}
	for y in img.get_height():
		for x in img.get_width():
			var c := img.get_pixel(x, y)
			if c.r > 0.85 and c.b > 0.85 and c.g < 0.2:
				@warning_ignore("integer_division")
				var key := Vector2i(x / 32, y / 32)
				cells[key] = int(cells.get(key, 0)) + 1
	var best := Vector2i.ZERO
	var most := 0
	for key in cells:
		if cells[key] > most:
			most = cells[key]
			best = key
	if most == 0:
		return
	var at: Vector2i = best * 32 + Vector2i(16, 16)
	var box := Rect2i(at - Vector2i(64, 36), Vector2i(128, 72)).intersection(
			Rect2i(Vector2i.ZERO, img.get_size()))
	var cut := img.get_region(box)
	cut.resize(box.size.x * 10, box.size.y * 10, Image.INTERPOLATE_NEAREST)
	cut.save_png("res://shots/brick_bevel_gap_%s_zoom.png" % tag)


func _case(what: String, w: BrickWorld, chunk: int, views: int, seed_: int, shot := false) -> void:
	print("\n%s" % what)
	var v := _views(w, chunk, views, seed_)
	if shot:
		# The pair: a wall at the couple of metres a player stands from one.
		var c := Vector3(1.6, 1.3, 0.0)
		v[0] = Transform3D(Basis(), c + Vector3(-0.4, 0.5, -1.7)).looking_at(c)
	var flat_tris := _show(w, chunk, false)
	_case_n += 1
	var off: Array = await _count(v, "%d_off" % _case_n, "brick_bevel_off" if shot else "")
	var tris := _show(w, chunk, true)
	var on: Array = await _count(v, "%d_on" % _case_n, "brick_bevel_on" if shot else "")
	_ok("the flat mesh shows no brick's inside", off[1] <= LONE_PIXELS,
			"%d magenta pixels in its worst view" % off[1])
	_ok("nor does the chamfered one", on[1] <= LONE_PIXELS
			and float(on[0]) <= CRACK_RATE * v.size(),
			"%d in its worst view, %d in all to the flat mesh's %d" % [on[1], on[0], off[0]])
	_ok("and it is chamfered", tris > flat_tris,
			"%d triangles to the flat mesh's %d (x%.1f), %.2f ms" % [tris, flat_tris,
				float(tris) / maxf(flat_tris, 1.0), w.get_last_chamfer_ms()])


func _tower(w: BrickWorld, x: int, z: int, courses: int) -> int:
	var palette := TowerRecipe.bake_palette(w)
	var chunk := w.create_chunk(Vector3i.ZERO, TowerRecipe.chunk_dims(x, z, courses))
	TowerRecipe.build(w, chunk, palette, x, z, courses)
	w.set_chunk_transform(chunk, Transform3D.IDENTITY)
	return chunk


## Every part of the workshop's palette, thrown into a box wherever it fits:
## bricks on slabs, overhangs, steps, parts of every size against each other,
## shaped parts, parts meeting at an edge or a corner only.
func _heap(w: BrickWorld) -> int:
	var palette := BrickPalette.bake(w)
	var ids := []
	for name in palette:
		ids.append(int(palette[name]))
	ids.sort()
	var dims := Vector3i(14, 30, 14)
	var chunk := w.create_chunk(Vector3i.ZERO, dims)
	w.set_chunk_transform(chunk, Transform3D.IDENTITY)
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261008
	var placed := 0
	for i in 6000:
		var arch: int = ids[rng.randi() % ids.size()]
		var s := w.get_archetype_size(arch)
		if s.x > dims.x or s.y > dims.y or s.z > dims.z:
			continue
		var cell := Vector3i(rng.randi_range(0, dims.x - s.x), rng.randi_range(0, dims.y - s.y),
				rng.randi_range(0, dims.z - s.z))
		if w.can_place(chunk, cell, arch):
			w.place_block(chunk, cell, arch, rng.randi() % 8)
			placed += 1
	print("  the heap: %d parts of %d kinds" % [placed, ids.size()])
	return chunk


func _run() -> void:
	print("brick bevel gap probe")
	if DisplayServer.get_name() == "headless":
		print("  needs a renderer: run it without --headless")
		quit(1)
		return
	_stage()
	for i in 4:
		await process_frame

	var w := BrickWorld.new()
	var tower := _tower(w, 12, 10, 12)
	await _case("a tower's walls, floors and windows", w, tower, 40, 11, true)

	w.apply_hit(tower, Vector3(0.3, 1.2, 1.5), 1.1)
	w.apply_hit(tower, Vector3(2.5, 2.6, 0.2), 0.9)
	w.apply_hit(tower, Vector3(3.9, 0.6, 3.2), 1.3)
	await _case("the same tower, shot through", w, tower, 40, 12)

	var heap := _heap(w)
	await _case("a heap of every part in the palette", w, heap, 60, 13)

	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	var n := w.get_block_count(heap)
	var kill := PackedInt32Array()
	for i in n:
		if rng.randf() < 0.3:
			kill.append(i)
	w.kill_blocks(heap, kill)
	await _case("the heap with three bricks in ten gone", w, heap, 60, 14)

	print("\nbrick bevel gap probe: %d passed, %d failed" % [_passed, _failed])
	quit(1 if _failed > 0 else 0)
