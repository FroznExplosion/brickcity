class_name ImpostorBaker

## Octahedral impostors, baked in Godot (Docs/Impostors.md 3.3).
##
## An object photographed from GRID x GRID directions over the upper
## hemisphere, laid out by the hemi-octahedral map, into two atlases: colour
## (with alpha) and the object-space normal. At runtime a camera-facing card
## blends the four views nearest the direction it is seen from
## (shaders/impostor.gdshader), lit by the baked normals -- so it takes the sun
## as the real mesh does.
##
## All the views in ONE render: GRID x GRID copies of the object, each turned
## so its view direction faces an orthographic camera, laid out on a grid the
## size of the atlas. Two renders a bake (colour, normal), not 128.
##
## The background is transparent black, so what comes back is premultiplied
## by coverage; the shader divides it back out after filtering, which is what
## keeps a dark fringe off every card.

const GRID := 8
const TILE := 128


## The hemi-octahedral map, shared with the shader: a direction on the upper
## hemisphere <-> a point in [0, 1]^2.
static func decode(uv: Vector2) -> Vector3:
	var p := uv * 2.0 - Vector2.ONE
	var x := (p.x + p.y) * 0.5
	var z := (p.x - p.y) * 0.5
	return Vector3(x, 1.0 - absf(x) - absf(z), z).normalized()


## A view's frame: right, up and the direction to the camera.
static func frame_basis(d: Vector3) -> Basis:
	var right := Vector3.RIGHT if absf(d.y) > 0.999 else Vector3.UP.cross(d).normalized()
	var up := d.cross(right)
	return Basis(right, up, d)


## Bake `what` -- a Mesh, or a Node3D such as an assembled gun. Needs a node
## in the tree to hang the viewport from, and a renderer: headless, it returns
## an empty Dictionary and callers keep the real thing. Otherwise {albedo,
## normal: Texture2D, centre: Vector3, radius: float, grid: int}.
##
## A MESH carries its colour in its vertices (every brick mesh does) and the
## colour pass draws that, unlit. A NODE brings its own materials, so its
## colour pass draws them lit by a flat white ambient and nothing else -- as
## near to their albedo as a lit render gets. The normal pass is the same for
## both: the geometry, whatever it is dressed in.
static func bake(host: Node, what: Variant, grid: int = GRID, tile: int = TILE) -> Dictionary:
	if DisplayServer.get_name() == "headless" or what == null:
		return {}
	var is_node: bool = what is Node3D
	var box: AABB
	if is_node:
		box = _node_aabb(what as Node3D)
	else:
		if (what as Mesh).get_surface_count() == 0:
			return {}
		box = (what as Mesh).get_aabb()
	if box.size == Vector3.ZERO:
		return {}
	var centre := box.get_center()
	var r := box.size.length() * 0.5
	var vp := SubViewport.new()
	vp.size = Vector2i(grid * tile, grid * tile)
	vp.transparent_bg = true
	vp.own_world_3d = true
	vp.msaa_3d = Viewport.MSAA_4X
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color.WHITE
	env.ambient_light_energy = 1.0
	env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	var we := WorldEnvironment.new()
	we.environment = env
	vp.add_child(we)
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = grid * 2.0 * r
	cam.near = 0.01
	cam.far = r * 8.0
	cam.position = Vector3(0.0, 0.0, r * 4.0)
	vp.add_child(cam)
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/impostor_bake.gdshader")
	var dressed: Array[GeometryInstance3D] = []
	for j in grid:
		for i in grid:
			var d := decode(Vector2(float(i), float(j)) / float(grid - 1))
			var turn := frame_basis(d).inverse()
			var copy: Node3D
			if is_node:
				copy = (what as Node3D).duplicate()
				# A picture of it, not another one of it: no script running.
				copy.set_script(null)
				_collect(copy, dressed)
			else:
				var mi := MeshInstance3D.new()
				mi.mesh = what
				mi.material_override = mat
				copy = mi
			# Row j = 0 at the TOP of the image, so it is row 0 of the atlas.
			var cx := (float(i) + 0.5 - grid * 0.5) * 2.0 * r
			var cy := (float(grid - 1 - j) + 0.5 - grid * 0.5) * 2.0 * r
			copy.transform = Transform3D(turn, Vector3(cx, cy, 0.0)) \
					* Transform3D(Basis(), -centre)
			vp.add_child(copy)
	host.add_child(vp)
	var out := {"centre": centre, "radius": r, "grid": grid}
	for pass_mode in 2:
		mat.set_shader_parameter("mode", pass_mode)
		if is_node and pass_mode == 1:
			for g in dressed:
				g.material_override = mat
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		var img := vp.get_texture().get_image()
		img.generate_mipmaps()
		out["albedo" if pass_mode == 0 else "normal"] = ImageTexture.create_from_image(img)
	vp.queue_free()
	return out


## Everything a node draws, in its own space.
static func _node_aabb(n: Node3D) -> AABB:
	var out := AABB()
	var first := true
	var stack: Array = [[n, Transform3D()]]
	while not stack.is_empty():
		var top: Array = stack.pop_back()
		var node: Node = top[0]
		var xf: Transform3D = top[1]
		if node is VisualInstance3D:
			var b: AABB = xf * (node as VisualInstance3D).get_aabb()
			out = b if first else out.merge(b)
			first = false
		for ch in node.get_children():
			if ch is Node3D:
				stack.append([ch, xf * (ch as Node3D).transform])
	return out


static func _collect(n: Node, into: Array[GeometryInstance3D]) -> void:
	if n is GeometryInstance3D:
		into.append(n)
	for ch in n.get_children():
		_collect(ch, into)


