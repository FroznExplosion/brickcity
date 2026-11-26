class_name ItemIcons
extends RefCounted
## Item icons, and the frames that spin them (Docs/Inventory.md 4, stage 4).
##
## Rendered ONCE, at load (`build`, the mine world awaits it as it starts):
## every catalog item is a small 3D model, laid out FRAMES times in a row --
## each copy turned a further 1/FRAMES of a circle about its up -- one row an
## item, in one SubViewport with an orthographic camera at a 3/4 view. One
## render draws every icon and every spin frame. The picture is then copied
## ONCE into an ImageTexture (a read-back at load, which CLAUDE.md allows;
## none during play) and the viewport freed: kept alive, its 3D buffers at
## MSAA 4x over 1792x2408 px held ~300 MB of video memory for a picture of
## ~17 MB (Docs/TerrainRegions.md 2.1). Slots draw their frame from it.
##
## A slot spins its icon by choosing the frame (`draw_icon(.., angle)`):
## zylanntest's SlotHoverFx spins only the hovered slot and eases it home
## when the mouse leaves; InvSlot does that, and the HUD spins the hand's
## slot. The models: a 2x2 brick of the block's colour; a translucent block
## for a fluid; a bucket; a pickaxe; a chest; a box for anything else.
## Headless (no renderer) there are no icons and slots draw swatches.

const SIZE := 56
const FRAMES := 32
## World size of one cell; the models are fitted to 1.0.
const CELL := 1.8
const PITCH := -28.0
const YAW := 35.0

static var texture: Texture2D = null
static var ready := false
static var _rows := {}
static var _viewport: SubViewport = null


## Render every catalog item's frames under `host` (any node in the tree).
## Await it; `ready` says it worked.
static func build(host: Node) -> void:
	ready = false
	texture = null
	_rows.clear()
	if DisplayServer.get_name() == "headless" or host == null or not host.is_inside_tree():
		return
	if _viewport != null and is_instance_valid(_viewport):
		_viewport.queue_free()
	var ids := ItemCatalog.ids()
	var n := ids.size()
	var vp := SubViewport.new()
	vp.name = "ItemIcons"
	vp.size = Vector2i(FRAMES * SIZE, n * SIZE)
	vp.own_world_3d = true
	vp.transparent_bg = true
	vp.msaa_3d = Viewport.MSAA_4X
	vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	var basis := Basis.from_euler(Vector3(deg_to_rad(PITCH), deg_to_rad(YAW), 0.0))
	var w := FRAMES * CELL
	var h := n * CELL
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = h
	cam.near = 0.1
	cam.far = 200.0
	cam.transform = Transform3D(basis, basis * Vector3(w * 0.5, -h * 0.5, 60.0))
	cam.current = true
	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.background_color = Color(0, 0, 0, 0)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.72, 0.72, 0.76)
	env.ambient_light_energy = 0.9
	cam.environment = env
	vp.add_child(cam)
	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(deg_to_rad(-55.0), deg_to_rad(-25.0), 0.0)
	sun.light_energy = 1.25
	vp.add_child(sun)
	var models := Node3D.new()
	vp.add_child(models)
	for i in n:
		_rows[ids[i]] = i
		var model := _model(ItemCatalog.get_def(ids[i]))
		for f in FRAMES:
			var copy := model.duplicate() as Node3D
			var at := basis * Vector3((f + 0.5) * CELL, -(i + 0.5) * CELL, 0.0)
			copy.transform = Transform3D(Basis(Vector3.UP, TAU * f / FRAMES), at)
			models.add_child(copy)
		model.free()
	host.add_child(vp)
	_viewport = vp
	vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	if not is_instance_valid(vp):
		return
	models.queue_free()
	var img := vp.get_texture().get_image()
	vp.queue_free()
	_viewport = null
	if img == null or img.is_empty():
		return
	texture = ImageTexture.create_from_image(img)
	ready = true


static func has_icon(id: StringName) -> bool:
	return ready and _rows.has(id)


## Draw item `id` into `r`, turned `angle` radians (the nearest of FRAMES).
## False when there is no icon for it (then draw a swatch instead).
static func draw_icon(ci: CanvasItem, r: Rect2, id: StringName, angle := 0.0,
		tint := Color.WHITE) -> bool:
	if not has_icon(id):
		return false
	var frame := posmod(roundi(angle / TAU * FRAMES), FRAMES)
	ci.draw_texture_rect_region(texture, r, Rect2(frame * SIZE, int(_rows[id]) * SIZE, SIZE, SIZE), tint)
	return true


# ---------------------------------------------------------------------------
# The models, fitted to 1.0 and centred on their middle

static func _mat(c: Color, rough := 0.4, alpha := 1.0, glow := false) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(c.r, c.g, c.b, alpha)
	m.roughness = rough
	if alpha < 1.0:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	if glow:
		m.emission_enabled = true
		m.emission = c
		m.emission_energy_multiplier = 0.8
	return m


static func _part(root: Node3D, mesh: Mesh, mat: Material, at: Vector3, rot := Basis()) -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.transform = Transform3D(rot, at)
	root.add_child(mi)


static func _box(sz: Vector3) -> BoxMesh:
	var b := BoxMesh.new()
	b.size = sz
	return b


static func _cyl(top: float, bottom: float, h: float, seg := 20) -> CylinderMesh:
	var c := CylinderMesh.new()
	c.top_radius = top
	c.bottom_radius = bottom
	c.height = h
	c.radial_segments = seg
	return c


static func _model(d: Dictionary) -> Node3D:
	var inner := Node3D.new()
	var col: Color = d.get("colour", Color(0.8, 0.8, 0.8))
	var kind := str(d.get("kind", ""))
	# Produce (a carrot, a pumpkin): a round brick with a leafy top.
	if str(d.get("model", "")) == "produce":
		kind = "produce"
	elif str(d.get("model", "")) == "sapling":
		kind = "sapling"
	match kind:
		"produce":
			_part(inner, _cyl(0.45, 0.45, 0.6, 18), _mat(col, 0.4), Vector3(0, 0.3, 0))
			_part(inner, _cyl(0.16, 0.16, 0.12), _mat(col, 0.4), Vector3(0, 0.66, 0))
			_part(inner, _box(Vector3(0.1, 0.3, 0.1)), _mat(Color(0.3, 0.6, 0.25), 0.6), Vector3(0, 0.85, 0))
		"block":
			var m := _mat(col, 0.35)
			_part(inner, _box(Vector3(1.0, 0.6, 1.0)), m, Vector3(0, 0.3, 0))
			var stud := _cyl(0.16, 0.16, 0.18)
			for x in [-0.25, 0.25]:
				for z in [-0.25, 0.25]:
					_part(inner, stud, m, Vector3(x, 0.69, z))
		"fluid":
			var lava := int(d.get("fluid", 1)) == 2
			_part(inner, _box(Vector3(1.0, 0.75, 1.0)), _mat(col, 0.1, 1.0 if lava else 0.78, lava),
					Vector3(0, 0.375, 0))
		"bucket", "source_bucket":
			var m := _mat(col, 0.3)
			_part(inner, _cyl(0.44, 0.33, 0.75), m, Vector3(0, 0.375, 0))
			_part(inner, _cyl(0.39, 0.39, 0.02), _mat(col.darkened(0.6), 0.6), Vector3(0, 0.751, 0))
			var handle := TorusMesh.new()
			handle.inner_radius = 0.4
			handle.outer_radius = 0.45
			_part(inner, handle, m, Vector3(0, 0.75, 0), Basis(Vector3.RIGHT, PI * 0.5))
		"tool":
			var wood := _mat(Color(0.45, 0.3, 0.16), 0.7)
			var tilt := Basis(Vector3.BACK, deg_to_rad(-35.0))
			_part(inner, _box(Vector3(0.1, 1.2, 0.1)), wood, Vector3.ZERO, tilt)
			_part(inner, _box(Vector3(0.85, 0.15, 0.17)), _mat(col, 0.25), tilt * Vector3(0, 0.55, 0), tilt)
		"gun":
			# A body, a barrel, a grip, a magazine.
			var m := _mat(col, 0.35)
			var dark := _mat(col.darkened(0.5), 0.5)
			_part(inner, _box(Vector3(0.7, 0.3, 0.2)), m, Vector3(0.0, 0.55, 0))
			_part(inner, _box(Vector3(0.3, 0.12, 0.12)), dark, Vector3(0.48, 0.6, 0))
			_part(inner, _box(Vector3(0.18, 0.4, 0.16)), dark, Vector3(-0.2, 0.28, 0), Basis(Vector3.BACK, 0.25))
			_part(inner, _box(Vector3(0.16, 0.3, 0.14)), m, Vector3(0.12, 0.3, 0))
		"backpack":
			# A pack: body, a lid flap over its top front, a front pocket, two straps.
			var m := _mat(col, 0.7)
			var dark := _mat(col.darkened(0.3), 0.7)
			_part(inner, _box(Vector3(0.7, 0.9, 0.42)), m, Vector3(0, 0.45, 0))
			_part(inner, _box(Vector3(0.74, 0.2, 0.46)), dark, Vector3(0, 0.86, 0.01))
			_part(inner, _box(Vector3(0.46, 0.32, 0.12)), dark, Vector3(0, 0.3, 0.26))
			for x in [-0.2, 0.2]:
				_part(inner, _box(Vector3(0.08, 0.8, 0.06)), dark, Vector3(x, 0.45, -0.24))
		"grenade":
			_part(inner, _cyl(0.36, 0.36, 0.62), _mat(col, 0.5), Vector3(0, 0.31, 0))
			_part(inner, _cyl(0.16, 0.16, 0.16), _mat(Color(0.75, 0.75, 0.78), 0.3), Vector3(0, 0.7, 0))
			_part(inner, _box(Vector3(0.08, 0.45, 0.12)), _mat(Color(0.75, 0.75, 0.78), 0.3), Vector3(0.24, 0.55, 0))
		"station":
			if str(d.get("model", "")) == "bin":
				# A slatted wooden box, open at the top, dark compost in it.
				var m := _mat(col, 0.8)
				for i in 4:
					_part(inner, _box(Vector3(1.0, 0.16, 1.0)), m, Vector3(0, 0.1 + i * 0.22, 0))
				_part(inner, _box(Vector3(0.86, 0.04, 0.86)), _mat(Color(0.22, 0.15, 0.1), 0.9), Vector3(0, 0.84, 0))
			elif str(d.get("model", "")) == "furnace":
				# A stone box, a dark mouth with a glow in it, a chimney.
				_part(inner, _box(Vector3(1.0, 0.9, 0.8)), _mat(col, 0.8), Vector3(0, 0.45, 0))
				_part(inner, _box(Vector3(0.5, 0.32, 0.04)), _mat(Color(1.0, 0.45, 0.1), 0.3, 1.0, true),
						Vector3(0, 0.3, 0.41))
				_part(inner, _box(Vector3(0.22, 0.3, 0.22)), _mat(col.darkened(0.3), 0.8), Vector3(0.3, 1.05, -0.2))
			else:
				# A table: a thick top, four legs, a tool on it.
				var m := _mat(col, 0.7)
				_part(inner, _box(Vector3(1.0, 0.16, 0.7)), m, Vector3(0, 0.72, 0))
				for x in [-0.42, 0.42]:
					for z in [-0.27, 0.27]:
						_part(inner, _box(Vector3(0.1, 0.64, 0.1)), m, Vector3(x, 0.32, z))
				_part(inner, _box(Vector3(0.4, 0.06, 0.12)), _mat(Color(0.7, 0.72, 0.76), 0.3), Vector3(0.1, 0.83, 0))
		"hoe":
			# A handle and a flat blade at right angles to it (Docs/MineFarming.md).
			var wood := _mat(Color(0.45, 0.3, 0.16), 0.7)
			var tilt := Basis(Vector3.BACK, deg_to_rad(-35.0))
			_part(inner, _box(Vector3(0.1, 1.2, 0.1)), wood, Vector3.ZERO, tilt)
			_part(inner, _box(Vector3(0.42, 0.08, 0.3)), _mat(col, 0.25), tilt * Vector3(-0.17, 0.58, 0), tilt)
		"scythe":
			# A long handle, a grip, and a long blade off its top.
			var wood := _mat(Color(0.45, 0.3, 0.16), 0.7)
			var tilt := Basis(Vector3.BACK, deg_to_rad(-20.0))
			_part(inner, _box(Vector3(0.08, 1.3, 0.08)), wood, Vector3.ZERO, tilt)
			_part(inner, _box(Vector3(0.22, 0.06, 0.06)), wood, tilt * Vector3(0.08, 0.05, 0), tilt)
			_part(inner, _box(Vector3(0.75, 0.06, 0.12)), _mat(col, 0.2),
					tilt * Vector3(-0.36, 0.62, 0), tilt * Basis(Vector3.BACK, deg_to_rad(-12.0)))
		"can":
			# A can, a spout up and out of its side, a handle over it.
			var m := _mat(col, 0.35)
			_part(inner, _cyl(0.32, 0.36, 0.6), m, Vector3(0, 0.3, 0))
			_part(inner, _cyl(0.05, 0.07, 0.6), m, Vector3(0.42, 0.42, 0), Basis(Vector3.BACK, deg_to_rad(-55.0)))
			_part(inner, _box(Vector3(0.08, 0.08, 0.5)), m, Vector3(-0.1, 0.72, 0), Basis(Vector3.UP, PI * 0.5))
		"sapling":
			# A short trunk and a leafy block on it (Docs/MineFarming.md 17).
			_part(inner, _cyl(0.1, 0.12, 0.6), _mat(Color(0.45, 0.3, 0.16), 0.7), Vector3(0, 0.3, 0))
			_part(inner, _box(Vector3(0.6, 0.45, 0.6)), _mat(col, 0.6), Vector3(0, 0.75, 0))
			_part(inner, _box(Vector3(0.36, 0.2, 0.36)), _mat(col.lightened(0.1), 0.6), Vector3(0, 1.05, 0))
		"seed", "fertiliser":
			# A little heap of seeds (or compost).
			var m := _mat(col, 0.5)
			for i in 7:
				var a := TAU * float(i) / 7.0
				var r := 0.0 if i == 0 else 0.3
				_part(inner, _cyl(0.12, 0.12, 0.16, 10), m, Vector3(cos(a) * r, 0.08 + (0.14 if i == 0 else 0.0), sin(a) * r))
		"chest":
			_part(inner, _box(Vector3(1.0, 0.6, 0.72)), _mat(col, 0.6), Vector3(0, 0.3, 0))
			_part(inner, _box(Vector3(1.04, 0.24, 0.76)), _mat(col.darkened(0.25), 0.6), Vector3(0, 0.72, 0))
			_part(inner, _box(Vector3(0.14, 0.18, 0.06)), _mat(Color(0.95, 0.78, 0.3), 0.2),
					Vector3(0, 0.6, 0.39))
		"wire":
			# A smooth grey tile with a cable along it (Docs/MineWiring.md 3.3).
			_part(inner, _box(Vector3(1.0, 0.3, 1.0)), _mat(Color(0.24, 0.25, 0.27), 0.5), Vector3(0, 0.15, 0))
			_part(inner, _box(Vector3(1.0, 0.12, 0.26)), _mat(col, 0.35), Vector3(0, 0.36, 0))
			_part(inner, _box(Vector3(0.26, 0.12, 0.5)), _mat(col, 0.35), Vector3(0, 0.36, 0.25))
		"wrench":
			var steel := _mat(col, 0.25)
			var tilt := Basis(Vector3.BACK, deg_to_rad(-40.0))
			_part(inner, _box(Vector3(0.14, 1.0, 0.08)), steel, Vector3.ZERO, tilt)
			_part(inner, _box(Vector3(0.36, 0.14, 0.1)), steel, tilt * Vector3(-0.08, 0.55, 0), tilt)
			_part(inner, _box(Vector3(0.1, 0.22, 0.1)), steel, tilt * Vector3(-0.22, 0.66, 0), tilt)
		"device":
			var dm := str(d.get("model", ""))
			if dm == "lamp":
				_part(inner, _box(Vector3(0.6, 0.85, 0.6)), _mat(col, 0.2, 1.0, true), Vector3(0, 0.425, 0))
				_part(inner, _cyl(0.18, 0.18, 0.12), _mat(col, 0.2, 1.0, true), Vector3(0, 0.91, 0))
			elif dm == "gate":
				# A slab, a coloured brick, a white arrow at the front.
				_part(inner, _box(Vector3(1.0, 0.3, 1.0)), _mat(Color(0.5, 0.5, 0.52), 0.6), Vector3(0, 0.15, 0))
				_part(inner, _box(Vector3(0.8, 0.5, 0.8)), _mat(col, 0.45), Vector3(0, 0.55, 0))
				_part(inner, _box(Vector3(0.16, 0.3, 0.36)), _mat(Color(0.95, 0.95, 0.9), 0.4), Vector3(0.48, 0.5, 0))
			elif dm == "button":
				_part(inner, _box(Vector3(0.9, 0.4, 0.9)), _mat(Color(0.5, 0.5, 0.52), 0.6), Vector3(0, 0.2, 0))
				_part(inner, _box(Vector3(0.5, 0.2, 0.5)), _mat(col, 0.35), Vector3(0, 0.5, 0))
			elif dm == "pressure":
				_part(inner, _box(Vector3(1.0, 0.18, 1.0)), _mat(col, 0.55), Vector3(0, 0.09, 0))
				_part(inner, _box(Vector3(0.6, 0.06, 0.6)), _mat(col.darkened(0.2), 0.55), Vector3(0, 0.2, 0))
			elif dm == "trip":
				_part(inner, _box(Vector3(0.12, 0.9, 0.12)), _mat(col, 0.7), Vector3(0, 0.45, 0))
				_part(inner, _box(Vector3(0.4, 0.08, 0.08)), _mat(Color(0.7, 0.7, 0.72), 0.3), Vector3(0.2, 0.8, 0))
				_part(inner, _box(Vector3(0.7, 0.02, 0.02)), _mat(Color(0.9, 0.88, 0.8), 0.6), Vector3(0.6, 0.8, 0))
			else:
				# A lever: a stone plate, a stick leaning, a red knob.
				_part(inner, _box(Vector3(0.8, 0.25, 0.8)), _mat(col, 0.6), Vector3(0, 0.125, 0))
				var lean := Basis(Vector3.BACK, deg_to_rad(-30.0))
				_part(inner, _box(Vector3(0.12, 0.7, 0.12)), _mat(Color(0.45, 0.3, 0.16), 0.7), Vector3(0.15, 0.55, 0), lean)
				_part(inner, _box(Vector3(0.22, 0.22, 0.22)), _mat(Color(0.75, 0.1, 0.08), 0.4), Vector3(0.33, 0.86, 0))
		_:
			_part(inner, _box(Vector3(0.8, 0.8, 0.8)), _mat(col, 0.5), Vector3.ZERO)
	# Fit: the biggest extent 1.0, the middle on the origin.
	var box := AABB()
	var first := true
	for c in inner.get_children():
		var mi := c as MeshInstance3D
		var b := mi.transform * mi.mesh.get_aabb()
		box = b if first else box.merge(b)
		first = false
	var k := 1.0 / maxf(box.get_longest_axis_size(), 0.001)
	inner.transform = Transform3D(Basis.from_scale(Vector3.ONE * k), -box.get_center() * k)
	var root := Node3D.new()
	root.add_child(inner)
	return root
