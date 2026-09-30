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

## Real chamfer geometry, and how far it reaches. ~10 bricks — the bevel is
## 5.9 px at 3 m and 2.2 px at 8 m, so past this it is paying for nothing.
##
## The tile is the granularity, not a sphere around the camera. A per-metre
## radius would mean rebuilding tile meshes as you walk, which is ~11 ms a
## tile and the exact trap M2c exists to avoid. Instead BOTH meshes are built
## when the tile loads and Godot's visibility range swaps them — the same
## zero-runtime-cost pattern the stud and scatter tiers already use.
const BEVEL_RANGE := 12.0
const BEVEL := 0.013
## OFF by default, and ON only in the volumetric bench that measures it.
##
## Two meshes a tile means a cross-fade, and Godot's FADE_SELF makes BOTH
## meshes part-transparent through the fade band -- they do not add up to an
## opaque surface. So everything 6 to 18 m from the camera was see-through:
## a dug pad showed the hillside behind it through its own walls, and a
## sculpted spire read as glass (Docs/Terrain.md §20.8). The heightfield
## scene had it off since §17.22; the editor and the city never did. The
## shader's shaded bevel is the chamfer everywhere else.
static var bevel_enabled := false

const STUD_RANGE := 18.0      ## §7.2 tier 0 — geometry studs inside this.
const SCATTER_RANGE := 30.0   ## §8.
const RANGE_FADE := 6.0

## MultiMesh.set_buffer, TRANSFORM_3D with use_colors: twelve floats of
## transform then four of colour.
const FLOATS_PER_INSTANCE := 16

## The surface format flag for the print-material channel. One place, because
## every mesh that uses `terrain.gdshader` needs the same one.
const CUSTOM0_FLAGS := Mesh.ARRAY_CUSTOM_RGBA8_UNORM << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT

var tx := 0
var tz := 0

var piece_count := 0
var tri_count := 0
var stud_count := 0
var scatter_count := 0
var build_ms := 0.0
## Cells drawn as curved ground rather than packed into pieces (§18.5).
var curve_cells := 0

## The tile's collider, owned directly rather than through nodes.
var _body := RID()
var bevel_tri_count := 0


## Throw away every node and build again from the field.
##
## Cheap enough to do on a hit because `build_tile` is ~3 ms and the node
## churn is bounded by the collision merge (§10). A section that stayed
## materialised would be the right answer at city scale; at test-scene scale
## rebuilding is simpler and the cost is measured in the HUD.
func rebuild(material: Material) -> void:
	_free_body()
	_instances_done = false
	_collision_done = false
	_coll_i = 0
	for child in get_children():
		remove_child(child)
		child.queue_free()
	build(tx, tz, material)


## The C++ half, with no scene tree involved — safe to run on a worker
## thread, because `build_tile` only READS the field and returns fresh
## arrays. Hand the result to `build()`.
static func bake(tile_x: int, tile_z: int) -> Dictionary:
	return BrickTerrain.build_tile(tile_x, tile_z)


## Build the surface only and leave the rest to `add_instances()` and
## `add_collision()`. Set by the streamer; direct callers get all of it.
var phases := false
var _data := {}
var _instances_done := false
var _collision_done := false
var _shadow_on := true
var _coll_i := 0


func build(tile_x: int, tile_z: int, material: Material,
		baked: Dictionary = {}) -> void:
	tx = tile_x
	tz = tile_z
	var tile := BrickTerrain.get_tile_studs()
	var stud := BrickWorld.get_stud_metres()
	position = Vector3(tx * tile * stud, 0.0, tz * tile * stud)

	# The far mesh: flat faces, what has always been built.
	BrickTerrain.set_face_bevel(0.0)
	var data: Dictionary = baked if not baked.is_empty() \
			else BrickTerrain.build_tile(tx, tz)
	# The near mesh: the same tile with every face chamfered. Built now, once,
	# so walking never rebuilds anything.
	bevel_tri_count = 0
	var near: Dictionary = {}
	if bevel_enabled:
		BrickTerrain.set_face_bevel(BEVEL)
		near = BrickTerrain.build_tile(tx, tz)
		BrickTerrain.set_face_bevel(0.0)
	piece_count = data["piece_count"]
	tri_count = data["triangle_count"]
	stud_count = data["stud_count"]
	scatter_count = data["scatter_count"]
	curve_cells = int(data.get("curve_cells", 0))
	build_ms = data["build_ms"]

	if near.is_empty():
		_add_surface(data["mesh"], material, 0.0, 0.0)
	else:
		# near: drawn out to BEVEL_RANGE.  far: picks up from there.
		_add_surface(near["mesh"], material, 0.0, BEVEL_RANGE)
		_add_surface(data["mesh"], material, BEVEL_RANGE, 0.0)
		bevel_tri_count = near["triangle_count"]
	_data = data
	if phases:
		return   # the streamer will ask for the rest, a frame at a time
	add_instances()
	add_collision()


## The instanced half: studs, tufts, pebbles. Three MultiMesh uploads.
##
## Separate from the surface because assembling a whole tile in one frame is
## a 54 ms hitch, and a hitch is what streaming exists to avoid. Split three
## ways it is three frames of a few milliseconds.
func add_instances() -> void:
	if _instances_done or _data.is_empty():
		return
	_instances_done = true
	_add_instances("Studs", PieceMeshes.stud(), _data["studs"], STUD_RANGE,
			stud_material())
	_add_instances("Tufts", PieceMeshes.tuft(), _data["tufts"], SCATTER_RANGE,
			tuft_material())
	_add_instances("Pebbles", PieceMeshes.pebble(), _data["pebbles"], SCATTER_RANGE)


## The collider: 200-300 merged boxes through the physics server.
##
## The most expensive phase and the one nobody can see, so the streamer only
## asks for it on tiles close enough to stand on.
## Returns true when the collider is complete. `max_shapes` caps how many
## boxes go in on this call, because one tile's collider is 200-300 of them
## and doing them all at once measured an 18.9 ms spike — a budget checked
## between tiles cannot help with a single tile that big.
func add_collision(max_shapes := 0) -> bool:
	if _collision_done:
		return true
	if _data.is_empty():
		return true
	var boxes: PackedFloat32Array = _data["boxes"]
	@warning_ignore("integer_division")
	var n := boxes.size() / 6
	if n == 0:
		_collision_done = true
		return true
	if not _body.is_valid():
		_body = PhysicsServer3D.body_create()
		PhysicsServer3D.body_set_mode(_body, PhysicsServer3D.BODY_MODE_STATIC)
		PhysicsServer3D.body_set_space(_body, get_world_3d().space)
		PhysicsServer3D.body_set_collision_layer(_body, Layers.WORLD)
		PhysicsServer3D.body_set_collision_mask(_body, Layers.STRUCTURE_MASK)
		PhysicsServer3D.body_set_state(_body, PhysicsServer3D.BODY_STATE_TRANSFORM,
				global_transform)
	var stop := n if max_shapes <= 0 else mini(n, _coll_i + max_shapes)
	while _coll_i < stop:
		var o := _coll_i * 6
		PhysicsServer3D.body_add_shape(_body,
			_box_shape(Vector3(boxes[o + 3], boxes[o + 4], boxes[o + 5])),
			Transform3D(Basis(), Vector3(boxes[o], boxes[o + 1], boxes[o + 2])))
		_coll_i += 1
	if _coll_i >= n:
		_collision_done = true
	return _collision_done


## Whether this tile's ground casts into the sun's shadow map.
##
## Measured at a 145 m detail radius: the shadow pass was 290k triangles and
## 167 draw calls of the 429 drawn, and turning it off took the frame from
## 9.1 ms to 2.6. A brick terrace a hundred metres away casts almost nothing
## anyone can see on ground this gentle, so distance decides it.
func set_casts_shadow(on: bool) -> void:
	if on == _shadow_on:
		return
	_shadow_on = on
	var mode := GeometryInstance3D.SHADOW_CASTING_SETTING_ON if on 			else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for child in get_children():
		if child is MeshInstance3D:
			(child as MeshInstance3D).cast_shadow = mode


func has_collision() -> bool:
	return _collision_done


func _add_surface(arrays: Array, material: Material,
		range_begin: float, range_end: float) -> void:
	if arrays.is_empty():
		return
	var mesh := ArrayMesh.new()
	# CUSTOM0 carries the print material (§18.3). A custom channel is
	# ignored unless the surface says what format it is in, so the flag
	# travels with every upload of a terrain surface — including the coarse
	# tier's, which shares this shader.
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {},
			CUSTOM0_FLAGS)
	var mi := MeshInstance3D.new()
	mi.name = "Surface"
	mi.mesh = mesh
	mi.material_override = material
	mi.visibility_range_begin = range_begin
	mi.visibility_range_end = range_end
	if range_begin > 0.0:
		mi.visibility_range_begin_margin = RANGE_FADE
	if range_end > 0.0:
		mi.visibility_range_end_margin = RANGE_FADE
	mi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	add_child(mi)


## Instanced pieces need a material that reads the per-instance colour, or
## `use_colors` writes a buffer nothing looks at and every stud renders white —
## which is what the first capture showed. §7.3's "a stud can never disagree
## with its brick" is only true once this exists.
static var _instance_material: ShaderMaterial = null
static var _stud_material: ShaderMaterial = null
static var _tuft_material: ShaderMaterial = null

## Scatter and debris: printed plastic with a 45° raster on top faces.
##
## A `StandardMaterial3D` until it was noticed that the studs — the single
## most numerous thing on screen, and the thing the player's eye is closest
## to — were the only surface in the world with no layer lines on them,
## because a standard material cannot draw any.
static func instance_material() -> ShaderMaterial:
	if _instance_material == null:
		_instance_material = ShaderMaterial.new()
		_instance_material.shader = load("res://shaders/printed.gdshader")
		WeatherFx.register(_instance_material)   # wet in rain (Disasters.md 19)
	return _instance_material


## Studs: the same plastic, with the nozzle walking the outline instead of
## rastering it. A stud is an OCTAGON (PieceMeshes.SIDES), so concentric
## circles would be visibly the wrong shape on the part there are most of.
static func stud_material() -> ShaderMaterial:
	if _stud_material == null:
		_stud_material = ShaderMaterial.new()
		_stud_material.shader = load("res://shaders/printed.gdshader")
		_stud_material.set_shader_parameter("top_mode", 1)
		_stud_material.set_shader_parameter("contour_sides", PieceMeshes.SIDES)
		_stud_material.set_shader_parameter("contour_radius",
				PieceMeshes.STUD_R * PieceMeshes.STUD_TAPER)
		WeatherFx.register(_stud_material)
	return _stud_material


## Grass blades are single quads with no back, so they need the two-sided
## build of the same shader — `render_mode` is a property of the shader, not
## of the material.
static func tuft_material() -> ShaderMaterial:
	if _tuft_material == null:
		_tuft_material = ShaderMaterial.new()
		_tuft_material.shader = load("res://shaders/printed_double.gdshader")
		WeatherFx.register(_tuft_material)
	return _tuft_material


func _add_instances(node_name: String, mesh: Mesh, buffer: PackedFloat32Array,
		range_end: float, mat: Material = null) -> void:
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
	mi.material_override = mat if mat != null else instance_material()
	# §7.4: studs never cast. 8.3k instances through two cascades is ~365k
	# depth-only triangles a frame, to draw a shadow 0.07 m long — and the
	# surface shader draws that shadow analytically for nothing instead.
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.visibility_range_end = range_end
	mi.visibility_range_end_margin = RANGE_FADE
	mi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	# Grass moves in the wind (weather.gdshaderinc); studs and pebbles do not.
	if node_name == "Tufts":
		mi.set_instance_shader_parameter("weather_sway",
				WeatherFx.sway_grass(mesh.get_aabb().end.y))
	add_child(mi)


## Six floats a box: centre then size. §10 — one box a piece for now, where
## the resident tier will eventually use `add_chunk_shapes(..., merge)`, which
## `brick_world.cpp:1155` already implements.
## Collision goes through the PHYSICS SERVER, not through nodes.
##
## A node each was 200-300 `CollisionShape3D` per tile, and at 21x21 that is
## ~100,000 nodes: measured, the C++ bake of that field was 141 ms and
## assembling it took another 3.2 seconds, nearly all of it here. A server
## body takes the same boxes as transforms with no scene tree behind them.
##
## Box shapes are SHARED by size. A merged tile collider is mostly a few
## repeated footprints, so a couple of dozen shape RIDs cover a whole field
## and every tile after the first reuses them. `brick_sandbox.gd` has done
## this since M3; terrain simply never did.
static var _box_shapes := {}
## Live tiles. The shared shapes outlive any one tile and have to be freed
## when the last one goes, or Jolt reports them leaked at exit — which it
## did, 305 of them, the first time this ran.
static var _live_tiles := 0

static func _box_shape(size: Vector3) -> RID:
	var key := size.snapped(Vector3(0.001, 0.001, 0.001))
	if not _box_shapes.has(key):
		var rid := PhysicsServer3D.box_shape_create()
		PhysicsServer3D.shape_set_data(rid, size * 0.5)   # half extents
		_box_shapes[key] = rid
	return _box_shapes[key]


func _add_collision(boxes: PackedFloat32Array) -> void:
	_free_body()
	@warning_ignore("integer_division")
	var n := boxes.size() / 6
	if n == 0:
		return
	_body = PhysicsServer3D.body_create()
	PhysicsServer3D.body_set_mode(_body, PhysicsServer3D.BODY_MODE_STATIC)
	PhysicsServer3D.body_set_space(_body, get_world_3d().space)
	PhysicsServer3D.body_set_collision_layer(_body, Layers.WORLD)
	PhysicsServer3D.body_set_collision_mask(_body, Layers.STRUCTURE_MASK)
	PhysicsServer3D.body_set_state(_body, PhysicsServer3D.BODY_STATE_TRANSFORM,
			global_transform)
	for i in n:
		var o := i * 6
		PhysicsServer3D.body_add_shape(_body,
			_box_shape(Vector3(boxes[o + 3], boxes[o + 4], boxes[o + 5])),
			Transform3D(Basis(), Vector3(boxes[o], boxes[o + 1], boxes[o + 2])))


func _free_body() -> void:
	if _body.is_valid():
		PhysicsServer3D.free_rid(_body)
		_body = RID()


func _enter_tree() -> void:
	_live_tiles += 1


func _exit_tree() -> void:
	_free_body()
	_live_tiles -= 1
	if _live_tiles <= 0:
		for rid in _box_shapes.values():
			PhysicsServer3D.free_rid(rid)
		_box_shapes.clear()
