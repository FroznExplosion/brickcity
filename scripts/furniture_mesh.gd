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


## Drop a chunk's furniture node, if it has one.
static func drop(chunk: int, held: Dictionary) -> void:
	var node: MultiMeshInstance3D = held.get(chunk)
	if node != null:
		node.queue_free()
	held.erase(chunk)
