class_name TerrainTile
extends Node3D

## One 32x32 stud tile of brick ground — 11.2 m, the same XZ footprint a chunk
## has, so a tile that takes damage becomes exactly one chunk
## ([Docs/Terrain.md](../Docs/Terrain.md) §3, §11).
##
## **Nothing here decides anything.** The generator, the packer, the surface
## classification and the mesh all live in `BrickTerrain` (D1 — the core is
## C++ from day one, and terrain truth is core). This script is the Godot-side
## assembly: turn one `build_tile` result into nodes.
##
## That split is why there is one boundary crossing a tile rather than one a
## piece. `build_tile` hands back the mesh arrays ready for
## `add_surface_from_arrays`, the stud and scatter buffers in exactly
## `MultiMesh.set_buffer`'s layout, and the collision boxes as six floats each,
## so the loops below are uploads and not work.

const STUD_RANGE := 18.0      ## §7.2 tier 0 — geometry studs inside this.
const SCATTER_RANGE := 30.0   ## §8.
const RANGE_FADE := 6.0

## MultiMesh.set_buffer, TRANSFORM_3D with use_colors: twelve floats of
## transform then four of colour.
const FLOATS_PER_INSTANCE := 16

var tx := 0
var tz := 0

var piece_count := 0
var tri_count := 0
var stud_count := 0
var scatter_count := 0
var build_ms := 0.0


## Throw away every node and build again from the field.
##
## Cheap enough to do on a hit because `build_tile` is ~3 ms and the node
## churn is bounded by the collision merge (§10). A section that stayed
## materialised would be the right answer at city scale; at test-scene scale
## rebuilding is simpler and the cost is measured in the HUD.
func rebuild(material: Material) -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()
	build(tx, tz, material)


func build(tile_x: int, tile_z: int, material: Material) -> void:
	tx = tile_x
	tz = tile_z
	var tile := BrickTerrain.get_tile_studs()
	var stud := BrickWorld.get_stud_metres()
	position = Vector3(tx * tile * stud, 0.0, tz * tile * stud)

	var data: Dictionary = BrickTerrain.build_tile(tx, tz)
	piece_count = data["piece_count"]
	tri_count = data["triangle_count"]
	stud_count = data["stud_count"]
	scatter_count = data["scatter_count"]
	build_ms = data["build_ms"]

	_add_surface(data["mesh"], material)
	_add_instances("Studs", PieceMeshes.stud(), data["studs"], STUD_RANGE)
	_add_instances("Tufts", PieceMeshes.tuft(), data["tufts"], SCATTER_RANGE)
	_add_instances("Pebbles", PieceMeshes.pebble(), data["pebbles"], SCATTER_RANGE)
	_add_collision(data["boxes"])


func _add_surface(arrays: Array, material: Material) -> void:
	if arrays.is_empty():
		return
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mi := MeshInstance3D.new()
	mi.name = "Surface"
	mi.mesh = mesh
	mi.material_override = material
	add_child(mi)


## Instanced pieces need a material that reads the per-instance colour, or
## `use_colors` writes a buffer nothing looks at and every stud renders white —
## which is what the first capture showed. §7.3's "a stud can never disagree
## with its brick" is only true once this exists.
static var _instance_material: StandardMaterial3D = null

static func instance_material() -> StandardMaterial3D:
	if _instance_material == null:
		_instance_material = StandardMaterial3D.new()
		_instance_material.vertex_color_use_as_albedo = true
		_instance_material.roughness = 0.9
		# Tufts are two-sided blades; a stud is never seen from beneath.
		_instance_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	return _instance_material


func _add_instances(node_name: String, mesh: Mesh, buffer: PackedFloat32Array,
		range_end: float) -> void:
	@warning_ignore("integer_division")
	var count := buffer.size() / FLOATS_PER_INSTANCE
	if count == 0:
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = mesh
	mm.instance_count = count
	# One upload. C++ already emitted the engine's own buffer layout, so there
	# is no per-instance loop on this side at all.
	mm.set_buffer(buffer)

	var mi := MultiMeshInstance3D.new()
	mi.name = node_name
	mi.multimesh = mm
	mi.material_override = instance_material()
	# §7.4: studs never cast. 8.3k instances through two cascades is ~365k
	# depth-only triangles a frame, to draw a shadow 0.07 m long — and the
	# surface shader draws that shadow analytically for nothing instead.
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.visibility_range_end = range_end
	mi.visibility_range_end_margin = RANGE_FADE
	mi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	add_child(mi)


## Six floats a box: centre then size. §10 — one box a piece for now, where
## the resident tier will eventually use `add_chunk_shapes(..., merge)`, which
## `brick_world.cpp:1155` already implements.
func _add_collision(boxes: PackedFloat32Array) -> void:
	var body := StaticBody3D.new()
	body.name = "Body"
	body.collision_layer = Layers.WORLD
	body.collision_mask = Layers.STRUCTURE_MASK
	add_child(body)
	@warning_ignore("integer_division")
	var n := boxes.size() / 6
	for i in n:
		var o := i * 6
		var shape := BoxShape3D.new()
		shape.size = Vector3(boxes[o + 3], boxes[o + 4], boxes[o + 5])
		var cs := CollisionShape3D.new()
		cs.shape = shape
		cs.position = Vector3(boxes[o], boxes[o + 1], boxes[o + 2])
		body.add_child(cs)
