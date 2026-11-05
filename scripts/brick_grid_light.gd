class_name BrickGridLight
extends RefCounted

## The light on the brick grid (Docs/Lighting.md 6.1): how open each cell of a
## building is to the sky, and how much lamp light (Glow bricks) reaches it,
## flood-filled in the engine (BrickWorld.chunk_light_tiles) and read by the
## brick shader. A hole blown in a wall lets daylight in; a sealed room goes
## dark; nothing extra each frame on the GPU.
##
## One texture array for every building: a layer (slot) each, its grid's y
## layers laid out as tiles. Each band of a building is told its slot by an
## instance uniform (`grid_light`: slot, cells x, y, z), so every building
## keeps the one shared brick material. A building is lit again when its count
## of live bricks changes, at most one building a frame.

## Plates per cell up (a brick); one stud across.
const CELL_PLATES := 3
## A layer's size in texels, and how many buildings at once.
const SIZE := 512
const SLOTS := 16
## How much sky (of 255) a cell loses a step in from the open; three times
## through glass. 16: about 5.6 m into a room from a wide hole.
const SKY_STEP := 16
## The same for a Glow brick's light: about 3.7 m.
const LAMP_STEP := 24
## The render layer of bricks lit by the grid: the ambient boxes leave them
## alone (ReflectionProbe.reflection_mask), the grid has them.
const RENDER_LAYER := 1 << 10

var texture: Texture2DArray
## Put the lit bricks on RENDER_LAYER (where ambient boxes stand, so the box
## leaves them to the grid). The city has no boxes, and its near tier hides a
## band by its layers: it leaves layers alone.
var use_layer := true
## Every material bound to a grid, and whether the grid's sky shades it (off
## under SDFGI, which shades rooms itself: LightRig.apply_gi).
static var _materials: Array = []
static var _sky_shade := true
## Bound for lamp light only: a ship's or station's bricks (their cabin box
## stands for the ship's own lights; a sealed hull is not a dark room).
static var _skyless: Array = []
const SKY_FLOOR := 0.1
## Real lights at the Glow bricks (Docs/Lighting.md 6.3): unshadowed omni
## lights for what moves -- figures, the gun, pieces -- which the grid does
## not reach; the grid's own lamp term lights the bricks (it stops at walls,
## an unshadowed light would not), so the lights leave RENDER_LAYER out. Only
## with `use_layer`: without it bricks would be lit twice.
const LAMP_RANGE := 4.0
const LAMP_ENERGY := 1.2
const LAMP_COLOUR := Color(1.0, 0.78, 0.52)
## Glow bricks closer than this share a light; at most so many a building.
const LAMP_MERGE := 1.2
const LAMPS_MAX := 8
## Last one lit, for gates and the HUD (ms).
var last_ms := 0.0
var updates := 0

class Entry:
	var bricks: BrickWorld
	var chunk := -1
	var node: Node3D
	var slot := -1
	var dims := Vector3i.ZERO
	var alive := -1
	var bytes := PackedByteArray()
	var param := Vector4(-1.0, 0.0, 0.0, 0.0)
	var lamps: Array = []

var _entries := {}
var _free: Array[int] = []
var _turn := -1


func _init() -> void:
	var images: Array[Image] = []
	for i in SLOTS:
		var img := Image.create_empty(SIZE, SIZE, false, Image.FORMAT_RG8)
		img.fill(Color(1, 0, 0))
		images.append(img)
		_free.append(SLOTS - 1 - i)
	texture = Texture2DArray.new()
	texture.create_from_images(images)


## A material drawing bricks reads this grid; `sky` false: its lamps only.
func bind(mat: ShaderMaterial, sky := true) -> void:
	if not _materials.has(mat):
		_materials.append(mat)
	if not sky and not _skyless.has(mat):
		_skyless.append(mat)
	mat.set_shader_parameter("grid_sky_floor", SKY_FLOOR if _sky_shade and sky else 1.0)
	mat.set_shader_parameter("grid_light_tex", texture)
	mat.set_shader_parameter("grid_light_size", float(SIZE))
	mat.set_shader_parameter("grid_cell", Vector3(BrickWorld.get_stud_metres(), BrickWorld.get_plate_metres() * CELL_PLATES,
			BrickWorld.get_stud_metres()))


static func set_sky_shade(on: bool) -> void:
	_sky_shade = on
	for i in range(_materials.size() - 1, -1, -1):
		var m = _materials[i]
		if not is_instance_valid(m):
			_materials.remove_at(i)
			continue
		(m as ShaderMaterial).set_shader_parameter("grid_sky_floor",
				SKY_FLOOR if on and not _skyless.has(m) else 1.0)


## Light `chunk` of `bricks`, whose bands hang under `node` (chunk-local).
func track(key, bricks: BrickWorld, chunk: int, node: Node3D) -> void:
	if _entries.has(key):
		return
	var e := Entry.new()
	e.bricks = bricks
	e.chunk = chunk
	e.node = node
	_entries[key] = e
	node.child_entered_tree.connect(_on_child.bind(e))
	_light(e)


## Light `key` again now: for a change that leaves the live count as it was
## (a brick's material, one laid as one went).
func relight(key) -> void:
	var e: Entry = _entries.get(key)
	if e != null:
		_light(e)


func tracked(key) -> bool:
	return _entries.has(key)


func release(key) -> void:
	var e: Entry = _entries.get(key)
	if e == null:
		return
	_entries.erase(key)
	if e.slot >= 0:
		_free.append(e.slot)
	if is_instance_valid(e.node):
		if e.node.child_entered_tree.is_connected(_on_child):
			e.node.child_entered_tree.disconnect(_on_child)
		e.param = Vector4(-1.0, 0.0, 0.0, 0.0)
		_apply_all(e)
	_hang_lamps(e, PackedVector3Array())


## Once a frame: drop what has gone; ask one building in turn whether its
## bricks changed (counting them walks every block: all sixteen a frame was
## too much in a city), and light it again if they did.
func step() -> void:
	for key in _entries.keys():
		var e: Entry = _entries[key]
		if not is_instance_valid(e.node) or not e.node.is_inside_tree():
			release(key)
	if _entries.is_empty():
		return
	var keys := _entries.keys()
	_turn = (_turn + 1) % keys.size()
	var e: Entry = _entries[keys[_turn]]
	if e.bricks.get_alive_block_count(e.chunk) != e.alive:
		_light(e)


## Sky and lamp (0..1 each) at world point `at`, from the nearest cell of the
## building it is in; Vector2(-1, 0) outside them all.
func at(pos: Vector3) -> Vector2:
	for key in _entries:
		var e: Entry = _entries[key]
		if e.slot < 0 or e.bytes.is_empty() or not is_instance_valid(e.node):
			continue
		var l := e.node.global_transform.affine_inverse() * pos
		var c := Vector3i(floori(l.x / BrickWorld.get_stud_metres()) + 1,
				floori(l.y / (BrickWorld.get_plate_metres() * CELL_PLATES)) + 1,
				floori(l.z / BrickWorld.get_stud_metres()) + 1)
		if c.x < 1 or c.z < 1 or c.y < 1 or c.x >= e.dims.x - 1 or c.z >= e.dims.z - 1 or c.y >= e.dims.y - 1:
			continue
		var per_row := SIZE / e.dims.x
		var px := (c.y % per_row) * e.dims.x + c.x
		var py := (c.y / per_row) * e.dims.z + c.z
		var i := (py * SIZE + px) * 2
		return Vector2(e.bytes[i] / 255.0, e.bytes[i + 1] / 255.0)
	return Vector2(-1.0, 0.0)


func _light(e: Entry) -> void:
	var t0 := Time.get_ticks_usec()
	e.alive = e.bricks.get_alive_block_count(e.chunk)
	if e.slot < 0:
		if _free.is_empty():
			return
		e.slot = _free.pop_back()
	e.dims = e.bricks.chunk_light_dims(e.chunk, CELL_PLATES)
	e.bytes = e.bricks.chunk_light_tiles(e.chunk, CELL_PLATES, SIZE, SIZE, SKY_STEP, LAMP_STEP)
	if e.bytes.is_empty():
		# Too big for a layer: drawn as before, the sky everywhere.
		_free.append(e.slot)
		e.slot = -1
		e.param = Vector4(-1.0, 0.0, 0.0, 0.0)
	else:
		var img := Image.create_from_data(SIZE, SIZE, false, Image.FORMAT_RG8, e.bytes)
		RenderingServer.texture_2d_update(texture.get_rid(), img, e.slot)
		e.param = Vector4(e.slot, e.dims.x, e.dims.y, e.dims.z)
	_apply_all(e)
	_hang_lamps(e, e.bricks.chunk_glow_points(e.chunk) if use_layer else PackedVector3Array())
	updates += 1
	last_ms = (Time.get_ticks_usec() - t0) / 1000.0


## Glow bricks' lights: `points` (chunk-local) merged within LAMP_MERGE,
## the biggest groups first, at most LAMPS_MAX; children of the building's
## node, so they ride with a ship.
func _hang_lamps(e: Entry, points: PackedVector3Array) -> void:
	var groups: Array = []   # [sum, count]
	for p in points:
		var best := -1
		for i in groups.size():
			if (groups[i][0] / groups[i][1]).distance_to(p) < LAMP_MERGE:
				best = i
				break
		if best < 0:
			groups.append([p, 1])
		else:
			groups[best][0] += p
			groups[best][1] += 1
	groups.sort_custom(func(a, b): return a[1] > b[1])
	groups = groups.slice(0, LAMPS_MAX)
	var valid := is_instance_valid(e.node)
	while e.lamps.size() > groups.size() or (not valid and not e.lamps.is_empty()):
		# Untyped: freed with the building's node, it cannot be held as one.
		var l: Variant = e.lamps.pop_back()
		if is_instance_valid(l):
			(l as Node).queue_free()
	if not valid:
		return
	for i in groups.size():
		if i >= e.lamps.size():
			var l := OmniLight3D.new()
			l.name = "GlowLamp"
			l.shadow_enabled = false
			l.light_color = LAMP_COLOUR
			l.omni_range = LAMP_RANGE
			l.omni_attenuation = 1.0
			l.light_cull_mask = 0xFFFFF & ~RENDER_LAYER
			e.node.add_child(l)
			e.lamps.append(l)
		var lamp := e.lamps[i] as OmniLight3D
		lamp.position = groups[i][0] / groups[i][1]
		# A lone brick a glow; a wall of them a lamp.
		lamp.light_energy = LAMP_ENERGY * minf(1.0 + 0.25 * (groups[i][1] - 1), 3.0)


func lamp_count() -> int:
	var n := 0
	for key in _entries:
		n += (_entries[key] as Entry).lamps.size()
	return n


func _apply_all(e: Entry) -> void:
	_apply(e, e.node)
	for c in e.node.get_children():
		_apply(e, c)


func _on_child(c: Node, e: Entry) -> void:
	_apply(e, c)


func _apply(e: Entry, c: Node) -> void:
	var g := c as GeometryInstance3D
	if g == null:
		return
	if g is MultiMeshInstance3D:
		# A band's studs (BrickNear), when the band is the node itself.
		BrickNear.grid_studs(g, e.param, g.get_parent() as Node3D)
		return
	# Only what draws with a grid's material: an instance parameter set on
	# anything else (a ladder) costs it 16 slots of the renderer's buffer
	# for nothing (Godot's InstanceUniforms keeps it).
	if not _materials.has(g.material_override):
		return
	g.set_instance_shader_parameter(&"grid_light", e.param)
	if use_layer:
		g.layers = RENDER_LAYER if e.param.x >= 0.0 else 1
	# What stands in for a band close up (BrickNear's chamfered mesh) is its
	# child, with the band's material.
	if g != e.node:
		for k in g.get_children():
			var n := k as GeometryInstance3D
			if n != null and n.material_override == g.material_override:
				n.set_instance_shader_parameter(&"grid_light", e.param)
			elif n is MultiMeshInstance3D:
				BrickNear.grid_studs(n, e.param, g)
