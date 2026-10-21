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
##
## And SEEN THROUGH: a wall one brick thick, in running bond and in stack
## bond, against a magenta backdrop, wide and through a scope. Every brick is closed, so a magenta
## pixel there is a way through BETWEEN bricks: the channel their bevels leave
## where corners meet, which a corner post fills (Docs/BrickBevel.md 2.6).
##
## GAP_THROUGH=1 runs only the seen-through cases. With GAP_WHERE=1 in the
## environment it also says, for each view's biggest
## patch, which cell the ray through it meets first, the blocks round that
## cell and their parts: enough to work out which arrangement opened it.

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
var _dbg_w: BrickWorld
var _dbg_chunk := -1


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
## The chamfered mesh's facet vertices (its UV2 is negative).
func _facets(w: BrickWorld, chunk: int) -> int:
	var arrays: Array = w.build_chunk_chamfer_mesh(chunk, BEVEL)
	var n := 0
	for u in arrays[Mesh.ARRAY_TEX_UV2]:
		if u.x < 0.0:
			n += 1
	return n


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
	if OS.get_environment("GAP_WHERE") != "":
		_where(img, best)
	var box := Rect2i(at - Vector2i(64, 36), Vector2i(128, 72)).intersection(
			Rect2i(Vector2i.ZERO, img.get_size()))
	var cut := img.get_region(box)
	cut.resize(box.size.x * 10, box.size.y * 10, Image.INTERPOLATE_NEAREST)
	cut.save_png("res://shots/brick_bevel_gap_%s_zoom.png" % tag)


## Which brick's core the biggest patch shows, and the cells round the point
## the ray meets it: for working out which arrangement opens a slit.
func _where(img: Image, best: Vector2i) -> void:
	var px := Vector2i(-1, -1)
	for y in range(best.y * 32, mini(best.y * 32 + 32, img.get_height())):
		for x in range(best.x * 32, mini(best.x * 32 + 32, img.get_width())):
			var c := img.get_pixel(x, y)
			if px.x < 0 and c.r > 0.85 and c.b > 0.85 and c.g < 0.2:
				px = Vector2i(x, y)
	if px.x < 0:
		return
	var o := _cam.project_ray_origin(Vector2(px))
	var d := _cam.project_ray_normal(Vector2(px))
	var w := _dbg_w
	# Whose core it is, and where on it the ray lands: which brick is open.
	var best_t := INF
	var best_b := {}
	for bx in w.get_block_boxes(_dbg_chunk):
		if not bx.alive:
			continue
		var h: Vector3 = bx.size * 0.5 - Vector3.ONE * CORE_INSET
		var lo: Vector3 = bx.pos - h
		var hi: Vector3 = bx.pos + h
		var t0 := 0.0
		var t1 := INF
		var hit := true
		for ax in 3:
			if absf(d[ax]) < 1e-9:
				if o[ax] < lo[ax] or o[ax] > hi[ax]:
					hit = false
				continue
			var ta := (lo[ax] - o[ax]) / d[ax]
			var tb := (hi[ax] - o[ax]) / d[ax]
			t0 = maxf(t0, minf(ta, tb))
			t1 = minf(t1, maxf(ta, tb))
		if hit and t0 <= t1 and t0 < best_t:
			best_t = t0
			best_b = bx
	if not best_b.is_empty():
		var at: Vector3 = o + d * best_t
		print("    the core is block %d's, met at %s (its box %s .. %s)" % [int(best_b.block), at,
				best_b.pos - best_b.size * 0.5, best_b.pos + best_b.size * 0.5])
	var cs: Vector3 = w.get_cell_size()
	var t := 0.0
	while t < 8.0:
		var p := o + d * t
		var cell: Vector3i = w.world_to_grid(p)
		var blk := w.block_at(_dbg_chunk, cell)
		if blk >= 0:
			var frac := (p - w.grid_to_world(cell)) / cs
			print("    patch at px %s: ray enters block %d at cell %s, %.2f m, in-cell %s, ray dir %s"
					% [px, blk, cell, t, frac, d])
			var rows := []
			for dy in [1, 0, -1]:
				for dz in [-1, 0, 1]:
					var row := "      y%+d z%+d:" % [dy, dz]
					for dx in [-1, 0, 1]:
						row += " %5d" % w.block_at(_dbg_chunk, cell + Vector3i(dx, dy, dz))
					rows.append(row)
			print("\n".join(rows))
			var seen := {}
			var dead := {}
			for bx in w.get_block_boxes(_dbg_chunk):
				if not bx.alive:
					dead[int(bx.block)] = true
			for dx in [-1, 0, 1]:
				for dy in [-1, 0, 1]:
					for dz in [-1, 0, 1]:
						var b := w.block_at(_dbg_chunk, cell + Vector3i(dx, dy, dz))
						if b >= 0 and not seen.has(b):
							seen[b] = true
							var arch := w.get_block_archetype(_dbg_chunk, b)
							print("      %d: %s %s mesh %d%s" % [b, w.get_archetype_name(arch),
									w.get_archetype_size(arch), w.get_archetype_mesh_triangles(arch),
									"  (shot away)" if dead.has(b) else ""])
			return
		t += 0.002


func _case(what: String, w: BrickWorld, chunk: int, views: int, seed_: int, shot := false) -> void:
	print("\n%s" % what)
	_dbg_w = w
	_dbg_chunk = chunk
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
	# Chamfered: it has bevel facets (UV2 negative). Not "more triangles than
	# the flat mesh": a plain brick is now a whole box of its own, under
	# fifty triangles, and a heap shot through has its flat mesh's uncovered
	# faces outnumber them (Docs/BrickBevel.md 2.5).
	_ok("and it is chamfered", _facets(w, chunk) > 0,
			"%d triangles to the flat mesh's %d (x%.1f), %d facet vertices, %.2f ms" % [tris,
				flat_tris, float(tris) / maxf(flat_tris, 1.0), _facets(w, chunk),
				w.get_last_chamfer_ms()])


## Seen through a chunk with no cores, against a backdrop `normal` points
## away from: close views from the `normal` side, wide and through a scope.
## Counted are the pixels magenta with the chamfered mesh and NOT with the
## flat one -- the flat mesh shows the backdrop past the chunk's ends and
## through the gaps that are really there (a checkerboard's empty squares).
##
## A channel between corners is a bevel wide and the wall's thickness long,
## and shows only from nearly dead on: `aims` are junctions to look straight
## into, as well as the views from round about.
func _through(what: String, w: BrickWorld, chunk: int, centre: Vector3, normal: Vector3,
		span: Vector2, aims: Array = []) -> void:
	print("\n%s" % what)
	var t1 := normal.cross(Vector3.FORWARD if absf(normal.y) > 0.9 else Vector3.UP).normalized()
	var t2 := normal.cross(t1).normalized()
	var rng := RandomNumberGenerator.new()
	rng.seed = 77
	var views := []
	for i in 24:
		var at := centre + t1 * rng.randf_range(-span.x, span.x) * 0.5 \
				+ t2 * rng.randf_range(-span.y, span.y) * 0.5
		var eye := at + normal * rng.randf_range(0.4, 1.4) \
				+ t1 * rng.randf_range(-0.3, 0.3) + t2 * rng.randf_range(-0.3, 0.3)
		views.append([Transform3D(Basis(), eye).looking_at(at, t2), 60.0 if i % 2 == 0 else 12.0])
	for at in aims:
		views.append([Transform3D(Basis(), at + normal * 0.6).looking_at(at, t2), 60.0])
		views.append([Transform3D(Basis(), at + normal * 1.5).looking_at(at, t2), 12.0])
	var shots := [[], []]
	for pass_ in 2:
		_show(w, chunk, pass_ == 1)
		for c in _holder.get_children():
			if c is MultiMeshInstance3D:
				c.free()
		var back := MeshInstance3D.new()
		var qm := QuadMesh.new()
		qm.size = Vector2(40, 40)
		back.mesh = qm
		back.material_override = _core_mat
		_holder.add_child(back)
		back.global_transform = Transform3D(Basis(), centre - normal * 3.0).looking_at(
				centre - normal * 4.0, t2)
		for v in views:
			_cam.global_transform = v[0]
			_cam.fov = v[1]
			for f in 2:
				await process_frame
			await RenderingServer.frame_post_draw
			shots[pass_].append(_view.get_texture().get_image())
	_cam.fov = 60.0
	var total := 0
	var worst := 0
	for i in views.size():
		var off: Image = shots[0][i]
		var on: Image = shots[1][i]
		var n := 0
		for y in on.get_height():
			for x in on.get_width():
				var c := on.get_pixel(x, y)
				if c.r > 0.85 and c.b > 0.85 and c.g < 0.2:
					var o := off.get_pixel(x, y)
					if not (o.r > 0.85 and o.b > 0.85 and o.g < 0.2):
						n += 1
		total += n
		if n > worst:
			worst = n
			on.save_png("res://shots/brick_bevel_through_on.png")
			off.save_png("res://shots/brick_bevel_through_off.png")
	print("  magenta with the chamfer and not without, over %d views: %d (worst %d)"
			% [views.size(), total, worst])
	_ok("the chamfer opens no way through", worst <= LONE_PIXELS
			and float(total) <= CRACK_RATE * views.size(),
			"%d in its worst view, %d in all" % [worst, total])


## A wall one brick thick along X: 1x4s, twelve courses, offset by `shift`
## studs a course (2 is running bond, 0 stack bond). Big enough that no view
## reaches its ends: past them the bevelled edge shows a little more of the
## backdrop than a square one, which is no way through.
func _wall(w: BrickWorld, shift: int) -> int:
	var palette := BrickPalette.bake(w)
	var run_x := -1
	for name in palette:
		if String(name).begins_with("brick_1x4") \
				and w.get_archetype_size(int(palette[name])) == Vector3i(4, 3, 1):
			run_x = int(palette[name])
	var chunk := w.create_chunk(Vector3i.ZERO, Vector3i(44, 36, 1))
	w.set_chunk_transform(chunk, Transform3D.IDENTITY)
	for course in 12:
		var off := (course * shift) % 4
		for x in range(off, 41, 4):
			w.place_block(chunk, Vector3i(x, course * 3, 0), run_x, course % 3)
	return chunk


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


## A room's corner: a floor of 2x4s and two walls of 1x4s standing on it,
## meeting at an inside corner, two courses of each. Every foot of a wall and
## the corner where the walls meet is an INSIDE corner (brick::EDGE_INNER_SHIFT):
## square, each face pushed out under the other.
func _room(w: BrickWorld) -> int:
	var palette := BrickPalette.bake(w)
	var floor_arch := -1
	var run_x := -1
	var run_z := -1
	for name in palette:
		var s := w.get_archetype_size(int(palette[name]))
		if String(name).begins_with("brick_2x4") and s == Vector3i(2, 3, 4):
			floor_arch = int(palette[name])
		elif String(name).begins_with("brick_1x4") and s == Vector3i(4, 3, 1):
			run_x = int(palette[name])
		elif String(name).begins_with("brick_1x4") and s == Vector3i(1, 3, 4):
			run_z = int(palette[name])
	var chunk := w.create_chunk(Vector3i.ZERO, Vector3i(16, 9, 16))
	w.set_chunk_transform(chunk, Transform3D.IDENTITY)
	var colour := 0
	for x in range(0, 16, 2):
		for z in range(0, 16, 4):
			w.place_block(chunk, Vector3i(x, 0, z), floor_arch, colour % 3)
			colour += 1
	# The back wall along x at z = 3, the side wall along z at x = 3: they
	# meet at (3, 3), and both stand on the floor with floor in front.
	for course in 2:
		var y := 3 + course * 3
		var shift := course * 2
		for x in range(3 + shift, 15, 4):
			if x + 4 <= 16:
				w.place_block(chunk, Vector3i(x, y, 3), run_x, 4 + course)
		for z in range(4 + shift, 15, 4):
			if z + 4 <= 16:
				w.place_block(chunk, Vector3i(3, y, z), run_z, 6 + course)
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
	var stud := BrickWorld.get_stud_metres()
	var plate := BrickWorld.get_plate_metres()
	# Where corners meet: a running bond's T's (a seam over a brick's
	# middle), a stack bond's crosses.
	var tees := []
	var crosses := []
	for course in range(5, 8):
		for k in range(4, 7):
			var y := course * 3 * plate
			tees.append(Vector3(float(k * 4 + (course % 2) * 2) * stud, y, stud))
			crosses.append(Vector3(float(k * 4) * stud, y, stud))
	var wall := _wall(w, 2)
	await _through("a wall one brick thick, running bond, seen through", w, wall,
			Vector3(22 * stud, 18 * plate, 0.5 * stud), Vector3.BACK, Vector2(8 * stud, 10 * plate), tees)
	var stack := _wall(w, 0)
	await _through("the same wall in stack bond", w, stack,
			Vector3(22 * stud, 18 * plate, 0.5 * stud), Vector3.BACK, Vector2(8 * stud, 10 * plate),
			crosses)
	# GAP_THROUGH=1: only the seen-through cases.
	if OS.get_environment("GAP_THROUGH") == "1":
		print("\nbrick bevel gap probe: %d passed, %d failed" % [_passed, _failed])
		quit(1 if _failed > 0 else 0)
		return

	var tower := _tower(w, 12, 10, 12)
	await _case("a tower's walls, floors and windows", w, tower, 40, 11, true)

	w.apply_hit(tower, Vector3(0.3, 1.2, 1.5), 1.1)
	w.apply_hit(tower, Vector3(2.5, 2.6, 0.2), 0.9)
	w.apply_hit(tower, Vector3(3.9, 0.6, 3.2), 1.3)
	await _case("the same tower, shot through", w, tower, 40, 12)

	var room := _room(w)
	await _case("a room's inside corners", w, room, 40, 15)
	var gone := PackedInt32Array()
	var rr := RandomNumberGenerator.new()
	rr.seed = 9
	for i in w.get_block_count(room):
		if rr.randf() < 0.3:
			gone.append(i)
	w.kill_blocks(room, gone)
	await _case("the room with three bricks in ten gone", w, room, 40, 16)

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
