class_name FurnitureMesh

## How a room's contents are DRAWN, now that they are not in the building's
## face bake.
##
## A chunk's face bake is whole-chunk: one room opening in a 50,000-brick tower
## invalidated the lot, and on the `--big` shapes that cost **225 ms a room**,
## 56% of it re-baking faces that had not moved and another 35% re-uploading a
## vertex buffer that had barely changed. Measured three ways in `--interiors`,
## and the per-unit cost came out roughly the same whether the unit was a room,
## a storey or a whole building -- because the cost was never proportional to
## what changed. Picking a bigger unit only paid the same bill fewer times.
##
## So interiors came out of the bake entirely (`Block::decorative`,
## `place_block(..., decorative = true)`) and are drawn from here instead.
##
## **Every item part is a box.** `_add_room_shapes` has always relied on that --
## it builds one collision box per block from `get_block_ticks` -- so the same
## description draws them: one `MultiMesh` per chunk, one instance per live
## decorative block, scaled and coloured per instance. Rebuilding it is a walk
## over the decorative blocks alone, which is hundreds rather than the tens of
## thousands a bake walks.
##
## It hangs off the node that draws the chunk, so it inherits that node's
## transform. A building's furniture is parented to the building's mesh; an
## island's is parented to the island's, and rides the collapse for free --
## which is Interiors §4.2 kept working, since the alternative was furniture
## vanishing the instant its building came down.

## One unit cube, shared by every furniture MultiMesh in the world. Instance
## transforms scale it; nothing here needs a mesh of its own.
static var _unit: BoxMesh
## And one material. Plain, not the brick shader: that shader reads UV as
## METRES across a face and UV2 as the face's size, which is what lets it draw
## seams and chamfers at a constant width -- and a unit cube scaled by an
## instance transform has neither. Furniture is small, close, and mostly seen
## against brickwork that does have them, so it takes the same road the single
## bricks in IslandManager's shared MultiMesh already take.
static var _material: StandardMaterial3D


static func material() -> StandardMaterial3D:
	if _material == null:
		_material = StandardMaterial3D.new()
		# Which is what makes the per-instance colours mean anything at all.
		_material.vertex_color_use_as_albedo = true
		_material.roughness = 0.75
	return _material


static func unit_mesh() -> BoxMesh:
	if _unit == null:
		_unit = BoxMesh.new()
		_unit.size = Vector3.ONE
	return _unit


## A MultiMesh holding every live decorative block of `chunk`, or null if there
## are none. `into` is reused when given, so a room opening next to one that is
## already open does not churn a resource.
static func build(world: BrickWorld, chunk: int, into: MultiMesh = null) -> MultiMesh:
	if chunk < 0 or not world.is_chunk_alive(chunk):
		return null
	var ids: PackedInt32Array = world.get_decorative_blocks(chunk)
	if ids.is_empty():
		return null
	var tick_m: float = BrickWorld.get_cell_size().x / float(BrickWorld.ticks_per_stud())
	var mm := into
	if mm == null:
		mm = MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.mesh = unit_mesh()
	# Allocated to the count first: instance_count is destructive, so setting a
	# transform before it is sized throws every one of them away.
	mm.instance_count = ids.size()
	var n := 0
	for id in ids:
		var ticks: Array = world.get_block_ticks(chunk, id)
		if ticks.is_empty():
			continue
		var lo: Vector3 = Vector3(ticks[0] as Vector3i) * tick_m
		var size: Vector3 = Vector3(ticks[1] as Vector3i) * tick_m
		mm.set_instance_transform(n, Transform3D(
				Basis().scaled(size), lo + size * 0.5))
		mm.set_instance_color(n, BrickWorld.get_filament_colour(
				world.get_block_colour(chunk, id)))
		n += 1
	# A block that answered with no ticks leaves a hole at the end rather than
	# an identity transform sitting at the chunk origin.
	mm.visible_instance_count = n
	return mm


## Put a chunk's furniture under `parent`, making, refreshing or freeing the
## node as the chunk requires. Returns how many instances are drawn.
##
## `held` is the caller's own map of chunk -> MultiMeshInstance3D; it is kept up
## to date here so that every owner of a chunk does this the same way.
static func attach(world: BrickWorld, chunk: int, parent: Node3D,
		held: Dictionary) -> int:
	var node: MultiMeshInstance3D = held.get(chunk)
	# A node whose parent was freed is not null, it is FREED, and reading
	# anything off it is an error rather than a null check.
	if node != null and not is_instance_valid(node):
		held.erase(chunk)
		node = null
	var mm := build(world, chunk, node.multimesh if node != null else null)
	if mm == null:
		if node != null:
			node.queue_free()
			held.erase(chunk)
		return 0
	if node == null:
		node = MultiMeshInstance3D.new()
		# The furniture is drawn in the chunk's own space, and the parent is
		# already in it: a building's brick mesh and an island's node both carry
		# the chunk transform, so this stays at the origin and inherits it.
		node.transform = Transform3D.IDENTITY
		# Same reason the brick mesh turns it off: a static building's mesh is
		# rewritten in place rather than moved, and interpolating a node that
		# never moves costs a frame of lag on everything that does.
		node.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		node.multimesh = mm
		node.material_override = material()
		parent.add_child(node)
		held[chunk] = node
	elif node.get_parent() != parent:
		node.reparent(parent, false)
	node.multimesh = mm
	return mm.visible_instance_count


## Floats per instance in a drawn room's buffer: a 3x4 transform and a colour.
const STRIDE := 16


## Draw a building's DRAWN rooms -- the ones with no blocks at all -- under
## `parent`. [Scale §4.1](../Docs/Scale.md) rung 2.
##
## The other half of this file draws from blocks. This draws from the
## manifest: each room worked out its buffer once when it was drawn
## (`RoomManifest.draw_items`), so a redraw is a concatenation, not a walk over
## anything. `key` is the caller's key into `held` -- a building id, since a
## drawn room belongs to a standing building and never to an island.
static func attach_drawn(rooms: Array, parent: Node3D, held: Dictionary, key: int) -> int:
	var buffers: Array[PackedFloat32Array] = []
	for room in rooms:
		buffers.append((room as Room).drawn_buffer)
	return _attach_buffers(buffers, parent, held, key, material())


## The same for FAKED rooms: seen through a window from further off, drawn
## unlit, with no collision anywhere. See shaders/fake_interior.gdshader.
static func attach_fake(rooms: Array, parent: Node3D, held: Dictionary, key: int) -> int:
	var buffers: Array[PackedFloat32Array] = []
	for room in rooms:
		buffers.append((room as Room).fake_buffer)
	var n := _attach_buffers(buffers, parent, held, key, fake_material())
	# No shadows: the fake rung is only ever seen through a window, and a
	# shadow pass over furniture nobody can reach is the cost it exists to cut.
	var node: MultiMeshInstance3D = held.get(key)
	if node != null:
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return n


static var _fake_material: ShaderMaterial


static func fake_material() -> ShaderMaterial:
	if _fake_material == null:
		_fake_material = ShaderMaterial.new()
		_fake_material.shader = load("res://shaders/fake_interior.gdshader")
	return _fake_material


## One MultiMesh from a list of buffers of STRIDE floats an instance, made,
## refreshed or freed as they require.
static func _attach_buffers(buffers: Array[PackedFloat32Array], parent: Node3D,
		held: Dictionary, key: int, mat: Material) -> int:
	var node: MultiMeshInstance3D = held.get(key)
	if node != null and not is_instance_valid(node):
		held.erase(key)
		node = null
	var buffer := PackedFloat32Array()
	for b in buffers:
		buffer.append_array(b)
	@warning_ignore("integer_division")
	var count: int = buffer.size() / STRIDE
	if count == 0:
		if node != null:
			node.queue_free()
			held.erase(key)
		return 0
	var mm: MultiMesh = node.multimesh if node != null else null
	if mm == null:
		mm = MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.mesh = unit_mesh()
	mm.instance_count = count
	mm.buffer = buffer
	mm.visible_instance_count = -1
	if node == null:
		node = MultiMeshInstance3D.new()
		node.transform = Transform3D.IDENTITY
		node.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		node.material_override = mat
		parent.add_child(node)
		held[key] = node
	elif node.get_parent() != parent:
		node.reparent(parent, false)
	node.multimesh = mm
	return count


## Drop a chunk's furniture node, if it has one.
static func drop(chunk: int, held: Dictionary) -> void:
	var node: MultiMeshInstance3D = held.get(chunk)
	# Valid, not merely non-null: this node hangs off the building's own,
	# and freeing that takes this with it while leaving the map pointing at
	# a freed object.
	if node != null and is_instance_valid(node):
		node.queue_free()
	held.erase(chunk)
