class_name TerrainTile
extends Node3D

## One 32x32 stud tile of brick ground — 11.2 m, the same XZ footprint a chunk
## has, so a tile that takes damage becomes exactly one chunk
## ([Docs/Terrain.md](../../Docs/Terrain.md) §3, §11).
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
## ON, for every scene that has ground: the heightfield test, the city on
## terrain, the combat arena. It was a switch each scene set for itself, and
## only the heightfield test did -- so the same ground was chamfered there and
## flat under the city (Docs/Terrain.md §22.13 measured it; §22.15 made it the
## default).
##
## It was off for a long time because two meshes a tile were cross-faded by a
## visibility range, and Godot fades a range per OBJECT: everything 6 to 18 m
## away was see-through (§20.8). Nothing fades now -- the streamer shows one
## mesh or the other by the tile's ring round the camera (`set_near`, §22.14)
## -- and tools/probes/bevel_gap_probe.gd is the gate: no more see-through pixels
## with it than without. Past the near ring the shader's shaded bevel is the
## chamfer, as it always was.
static var bevel_enabled := true

const STUD_RANGE := 18.0      ## §7.2 tier 0 — geometry studs inside this.

const SCATTER_RANGE := 30.0   ## §8.
const BRICK_RANGE := 70.0     ## Terrain.md 18.7: bricks in curved ground.
const RANGE_FADE := 6.0

## MultiMesh.set_buffer, TRANSFORM_3D with use_colors: twelve floats of
## transform then four of colour.
const FLOATS_PER_INSTANCE := 16
## ...and with use_custom_data, four more: the ground's studs with the sky
## light on (build_tile's "stud_stride" 20: each stud's sky and block light,
## Docs/MineWorld.md 20), drawn by sky_stud_material in their own kinds.
const FLOATS_PER_SKY_STUD := 20

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


## NOT physics-interpolated (Docs/MineWorld.md 20): a tile never moves between
## ticks, and its pooled stud MultiMeshes are refilled with another layout --
## interpolated, each stud was drawn for up to a tick halfway between its old
## buffer slot and its new one (the studs that flashed when a brick broke, a
## stray stud beside a block as it started to fall). Children inherit it.
func _init() -> void:
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
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
	recycle()
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
	# The near mesh: the same tile with its tops chamfered. A direct caller
	# gets it now; a STREAMED tile (phases) gets it later from the streamer,
	# baked on a worker and only for tiles near the camera -- building it for
	# every resident tile, here on the main thread, was 1.6 M triangles held
	# and ~8 ms a tile for a mesh drawn only inside BEVEL_RANGE.
	bevel_tri_count = 0
	_bevel_done = false
	var near: Dictionary = {}
	if bevel_enabled and not phases:
		near = BrickTerrain.build_tile_chamfered(tx, tz, BEVEL)
		_bevel_done = true
		# Nobody streams a direct caller's tiles: it is near, all of it.
		_near = true
	piece_count = data["piece_count"]
	tri_count = data["triangle_count"]
	stud_count = data["stud_count"]
	scatter_count = data["scatter_count"]
	curve_cells = int(data.get("curve_cells", 0))
	build_ms = data["build_ms"]

	_material = material
	_far_surface = _add_surface(data["mesh"], material, 0.0, 0.0)
	if not near.is_empty():
		add_bevel(near)
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
	# Bevelled studs on tiles round the camera, plain ones elsewhere; which is
	# shown is the streamer's call, by the tile's ring (set_near). NOT by a
	# visibility range: Godot fades a range per OBJECT, and the object here is
	# a whole 11 m tile -- standing in one, every stud on it was mid-fade,
	# dithered half see-through.
	# Only the set shown now; the other when the tile first switches
	# (_apply_near). A tile rebuilt by an edit is near the player, and its
	# far set was a second node add in the same frame -- the one that
	# sometimes took 12 ms (Docs/MineWorld.md 9).
	_add_studs(_near)
	_apply_near()
	_add_instances("Tufts", PieceMeshes.tuft(), _data["tufts"], SCATTER_RANGE,
			tuft_material())
	_add_instances("Pebbles", PieceMeshes.pebble(), _data["pebbles"], SCATTER_RANGE)
	# Bricks poking out of curved ground (Terrain.md 18.7): further than the
	# scatter, because a brick is big enough to be missed when it goes.
	_add_instances("Bricks", PieceMeshes.chamfered_box(Vector3(
			BrickWorld.get_stud_metres(), BrickTerrain.get_brick_metres(),
			BrickWorld.get_stud_metres())), _data.get("bricks", PackedFloat32Array()),
			BRICK_RANGE)


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
	# The body joins the physics space only once every box is on it. Added to
	# a body already IN the space, Jolt rebuilds the whole compound shape on
	# each box: 670 boxes measured 24.9 ms a tile that way, 0.77 ms added
	# first and put in the space after -- 32x. That rebuild was the dip while
	# sculpting (a refreshed tile adds all of them at once) and the "coll"
	# worst-tile spikes while walking.
	if not _body.is_valid():
		_body = PhysicsServer3D.body_create()
		set_notify_transform(true)
		PhysicsServer3D.body_set_mode(_body, PhysicsServer3D.BODY_MODE_STATIC)
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
		PhysicsServer3D.body_set_space(_body, get_world_3d().space)
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


## Whether this tile casts into the sun's shadow map (set_casts_shadow): a
## tile rebuilt by an edit takes the one it replaces.
func casts_shadow() -> bool:
	return _shadow_on


func has_collision() -> bool:
	return _collision_done


## The chamfered near mesh (BrickTerrain.build_tile_chamfered), shown instead
## of the flat one while the tile is near (set_near).
func add_bevel(near: Dictionary) -> void:
	_bevel_done = true
	var arrays: Array = near.get("mesh", [])
	if arrays.is_empty() or _far_surface == null:
		return
	_near_surface = _add_surface(arrays, _material, 0.0, 0.0)
	if _near_surface != null:
		_near_surface.name = "SurfaceChamfered"
		# The terrain shader fades its drawn outline and shaded chamfer IN
		# with distance on this mesh only: the real chamfer up close, both
		# a little further, the outline alone past that (terrain.gdshader).
		_near_surface.set_instance_shader_parameter("geo_bevel", 1.0)
	bevel_tri_count = near["triangle_count"]
	_apply_near()


## The detailed version of this tile -- chamfered surface, bevelled studs --
## or the plain one. Set by the streamer from the tile's ring round the
## camera; a whole-tile switch a tile or more away, where a 13 mm bevel is a
## pixel or two, so it does not read as a pop.
func set_near(on: bool) -> void:
	if on == _near:
		return
	_near = on
	_apply_near()


## The near (bevelled) or far (plain) stud set, if it is not there yet.
## Studs that carry their light (stud_stride 20) are kinds of their own.
func _add_studs(near: bool) -> void:
	var sky := int(_data.get("stud_stride", FLOATS_PER_INSTANCE)) == FLOATS_PER_SKY_STUD
	var node_name := ("StudsSky" if near else "StudsSkyFar") if sky else ("Studs" if near else "StudsFar")
	if has_node(NodePath(node_name)):
		return
	_add_instances(node_name, PieceMeshes.stud() if near else PieceMeshes.stud_plain(),
			_data["studs"], STUD_RANGE, sky_stud_material() if sky else stud_material(),
			0.0, RANGE_FADE, FLOATS_PER_SKY_STUD if sky else FLOATS_PER_INSTANCE)


func _apply_near() -> void:
	if _instances_done and _studs_shown and not _data.is_empty():
		_add_studs(_near)
	var chamfered := _near and _near_surface != null
	if _near_surface != null:
		_near_surface.visible = chamfered
	if _far_surface != null:
		_far_surface.visible = not chamfered
	for c in get_children():
		if c is MultiMeshInstance3D:
			if c.name == "Studs" or c.name == "StudsSky":
				(c as Node3D).visible = _near and _studs_shown
			elif c.name == "StudsFar" or c.name == "StudsSkyFar":
				(c as Node3D).visible = not _near and _studs_shown


## F4 in the heightfield scene: instances on or off, the near/far choice kept.
func set_studs_shown(on: bool) -> void:
	_studs_shown = on
	_apply_near()


var _near := false
var _studs_shown := true
var _near_surface: MeshInstance3D = null


## Does this tile still want its chamfered mesh?
## Is the tile drawn as it should be up close -- its instances in and, near
## the camera, its chamfered mesh? A tile an edit rebuilt used to show flat
## and bare for a few frames (TerrainStreamer._assemble swaps it whole now).
func is_whole() -> bool:
	if _data.is_empty():
		return true
	if not _instances_done:
		return false
	return not (_near and bevel_enabled and _near_surface == null
			and not (_data.get("mesh", []) as Array).is_empty())


func needs_bevel() -> bool:
	return bevel_enabled and not _bevel_done and not _data.is_empty()


var _bevel_done := false
var _far_surface: MeshInstance3D = null
var _material: Material = null


func _add_surface(arrays: Array, material: Material,
		range_begin: float, range_end: float) -> MeshInstance3D:
	if arrays.is_empty():
		return null
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
	# Block light is in its cells: off the lava lights' layer (RenderLayers).
	if material is ShaderMaterial and _sky_light_shader != null 			and (material as ShaderMaterial).shader == _sky_light_shader:
		mi.layers = RenderLayers.BLOCK_LIT
	mi.visibility_range_begin = range_begin
	mi.visibility_range_end = range_end
	if range_begin > 0.0:
		mi.visibility_range_begin_margin = RANGE_FADE
	if range_end > 0.0:
		mi.visibility_range_end_margin = RANGE_FADE
	mi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	# The tile's shadow choice (set_casts_shadow), for a surface added after
	# it was made -- the chamfered near mesh lands frames later, and it cast
	# whatever the tile said: the ground round the camera shadowed itself into
	# a fine grain (Docs/MineWorld.md 11).
	if not _shadow_on:
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	return mi


## A new ground material: `terrain.gdshader` with the stud's real numbers in
## it and the sun the ground's baked shadow was cast from. One place, because
## every scene with ground made its own and they are meant to be the same
## ground (heightfield_scene, city_scene).
##
## `sun_travel` is the way the light shines: `-sun.global_transform.basis.z`.
## `sky_light`: the copy of the shader that reads the bake's sky light
## (CUSTOM0.a, BrickTerrain.set_sky_light; Docs/MineWorld.md 18) -- the mine
## world's. Every other scene draws the shader as it is.
static func ground_material(sun_travel: Vector3, sky_light := false) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = sky_light_shader() if sky_light else load("res://shaders/terrain.gdshader")
	WeatherFx.register(mat)
	mat.set_shader_parameter("stud_pitch", BrickWorld.get_stud_metres())
	mat.set_shader_parameter("stud_radius", PieceMeshes.STUD_R)
	mat.set_shader_parameter("stud_height", PieceMeshes.STUD_H)
	mat.set_shader_parameter("sun_dir", sun_travel)
	return mat


static var _sky_light_shader: Shader = null


## `terrain.gdshader` with `#define SKY_LIGHT` in front of it, made once.
static func sky_light_shader() -> Shader:
	if _sky_light_shader == null:
		var code: String = (load("res://shaders/terrain.gdshader") as Shader).code
		var at := code.find("\n") + 1
		_sky_light_shader = Shader.new()
		_sky_light_shader.code = code.insert(at, "#define SKY_LIGHT\n")
	return _sky_light_shader


## Instanced pieces need a material that reads the per-instance colour, or
## `use_colors` writes a buffer nothing looks at and every stud renders white —
## which is what the first capture showed. §7.3's "a stud can never disagree
## with its brick" is only true once this exists.
static var _instance_material: ShaderMaterial = null
static var _stud_material: ShaderMaterial = null
static var _sky_stud_material: ShaderMaterial = null
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


## The ground's studs where the bake lights them (the mine world): the stud
## material with `#define INSTANCE_SKY` (printed_core), which reads each
## stud's sky and block light from its custom data -- so a stud in a cave is
## as dark as the floor under it, not lit by the open sky (Docs/MineWorld.md 20).
static func sky_stud_material() -> ShaderMaterial:
	if _sky_stud_material == null:
		var code: String = (load("res://shaders/printed.gdshader") as Shader).code
		var at := code.find("\n") + 1
		var sh := Shader.new()
		sh.code = code.insert(at, "#define INSTANCE_SKY\n")
		_sky_stud_material = ShaderMaterial.new()
		_sky_stud_material.shader = sh
		_sky_stud_material.set_shader_parameter("top_mode", 1)
		_sky_stud_material.set_shader_parameter("contour_sides", PieceMeshes.SIDES)
		_sky_stud_material.set_shader_parameter("contour_radius",
				PieceMeshes.STUD_R * PieceMeshes.STUD_TAPER)
		WeatherFx.register(_sky_stud_material)
	return _sky_stud_material


## Grass blades are single quads with no back, so they need the two-sided
## build of the same shader — `render_mode` is a property of the shader, not
## of the material.
static func tuft_material() -> ShaderMaterial:
	if _tuft_material == null:
		_tuft_material = ShaderMaterial.new()
		_tuft_material.shader = load("res://shaders/printed_double.gdshader")
		WeatherFx.register(_tuft_material)
	return _tuft_material


## Opt-in timing of the instances phase, by kind and step (a pass turns it
## on and prints it): {"<kind> <step>": worst ms}. Off, it costs nothing.
static var profile_instances := false
static var instance_ms := {}


static func _note_ms(key: String, t0: int) -> void:
	var ms := float(Time.get_ticks_usec() - t0) / 1000.0
	instance_ms[key] = maxf(float(instance_ms.get(key, 0.0)), ms)
	instance_ms[key + " n"] = float(instance_ms.get(key + " n", 0.0)) + 1.0
	if ms > 3.0:
		instance_ms[key + " >3ms"] = float(instance_ms.get(key + " >3ms", 0.0)) + 1.0


func _add_instances(node_name: String, mesh: Mesh, buffer: PackedFloat32Array,
		range_end: float, mat: Material = null, range_begin := 0.0, fade := RANGE_FADE,
		stride := FLOATS_PER_INSTANCE) -> void:
	@warning_ignore("integer_division")
	var count := buffer.size() / stride
	if count == 0:
		return
	var t0 := Time.get_ticks_usec()
	# A recycled node first (`recycle`): node, render instance and MultiMesh
	# all drawn before, so filling it is a buffer copy.
	var mi: MultiMeshInstance3D = null
	var mm: MultiMesh = null
	var nodes: Array = _mmi_pool.get(node_name, [])
	while mi == null and not nodes.is_empty():
		var cand = nodes.pop_back()
		if is_instance_valid(cand):
			mi = cand
	if mi != null:
		mm = mi.multimesh
		_mms.append([node_name, mm, mi])
		if profile_instances:
			instance_ms[node_name + " reused"] = float(instance_ms.get(node_name + " reused", 0.0)) + 1.0
	else:
		mm = _take_multimesh(node_name, mesh)
		mi = MultiMeshInstance3D.new()
		mi.multimesh = mm
		(_mms.back() as Array).append(mi)
		if profile_instances:
			instance_ms[node_name + " new"] = float(instance_ms.get(node_name + " new", 0.0)) + 1.0
	mm.instance_count = count
	if profile_instances:
		_note_ms(node_name + " alloc", t0)
		t0 = Time.get_ticks_usec()
	# One upload. C++ already emitted the engine's own buffer layout, so there
	# is no per-instance loop on this side at all.
	mm.set_buffer(buffer)
	if profile_instances:
		_note_ms(node_name + " buffer", t0)
		instance_ms[node_name + " count"] = maxf(float(instance_ms.get(node_name + " count", 0.0)), count)
		t0 = Time.get_ticks_usec()

	mi.name = node_name
	mi.visible = true
	mi.material_override = mat if mat != null else instance_material()
	# §7.4: studs never cast. 8.3k instances through two cascades is ~365k
	# depth-only triangles a frame, to draw a shadow 0.07 m long — and the
	# surface shader draws that shadow analytically for nothing instead.
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.visibility_range_end = range_end
	mi.visibility_range_end_margin = fade
	if range_begin > 0.0:
		mi.visibility_range_begin = range_begin
		mi.visibility_range_begin_margin = fade
	mi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	# Grass moves in the wind (weather.gdshaderinc); studs and pebbles do not.
	if node_name == "Tufts":
		mi.set_instance_shader_parameter("weather_sway",
				WeatherFx.sway_grass(mesh.get_aabb().end.y))
	add_child(mi)
	if profile_instances:
		_note_ms(node_name + " node", t0)


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

## MultiMeshes kept for reuse, by kind ("Studs", "Tufts", "Pebbles").
##
## A NEW MultiMesh entering the tree stalls on the render thread: measured
## 4.5 ms a node on average and 19 ms at worst, whatever its size -- one stud
## or a thousand. That was the "inst" worst-tile spike while walking (21-105
## ms). A MultiMesh that has been drawn before costs 0.04 ms to fill and show
## again, in a brand-new node. So a tile hands its MultiMeshes back when it
## leaves, and the next tile takes them.
static var _mm_pool := {}
## This tile's MultiMeshes, [kind, MultiMesh, MultiMeshInstance3D], to give back.
var _mms: Array = []
## Instance NODES kept for reuse, by kind, each holding its MultiMesh. A tile
## the streamer replaces or drops hands them over at once (`recycle`), not
## when it is finally freed at the end of the frame: a tile rebuilt by an edit
## asks for its instances while the tile it replaces still holds them, the
## MultiMesh pool was empty, and a never-drawn MultiMesh in a new node stalled
## 11-21 ms about one time in 78 (Docs/MineWorld.md 9).
static var _mmi_pool := {}


func _take_multimesh(kind: String, mesh: Mesh) -> MultiMesh:
	var mm: MultiMesh = null
	var free: Array = _mm_pool.get(kind, [])
	if not free.is_empty():
		mm = free.pop_back()
	else:
		mm = MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.use_custom_data = kind.begins_with("StudsSky")
		mm.mesh = mesh
	_mms.append([kind, mm])
	return mm


## PRE-WARMED INSTANCE NODES (Docs/MineWorld.md 14). Until tiles start being
## dropped the pool is empty, so the first new ground after a world is made
## put every tile's studs and scatter into never-drawn nodes -- the spawn
## spike. `prewarm_begin` adds `per_kind[kind]` nodes of each kind, one invisible
## speck each at `at` (in view, so they are really drawn), at load time;
## `prewarm_end`, a few frames later, hands them to the pool.
static func prewarm_begin(parent: Node3D, at: Vector3, per_kind: Dictionary) -> Array:
	var kinds := {
		"Studs": [PieceMeshes.stud(), stud_material()],
		"StudsFar": [PieceMeshes.stud_plain(), stud_material()],
		"StudsSky": [PieceMeshes.stud(), sky_stud_material()],
		"StudsSkyFar": [PieceMeshes.stud_plain(), sky_stud_material()],
		"Tufts": [PieceMeshes.tuft(), tuft_material()],
		"Pebbles": [PieceMeshes.pebble(), instance_material()],
	}
	var out := []
	for kind in kinds:
		for i in int(per_kind.get(kind, 0)):
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.use_colors = true
			mm.use_custom_data = kind.begins_with("StudsSky")
			mm.mesh = kinds[kind][0]
			mm.instance_count = 1
			mm.set_instance_transform(0, Transform3D(Basis().scaled(Vector3.ONE * 0.001),
					parent.to_local(at)))
			mm.set_instance_color(0, Color(0, 0, 0, 0))
			var mi := MultiMeshInstance3D.new()
			mi.name = "Warm%s" % kind
			mi.multimesh = mm
			mi.material_override = kinds[kind][1]
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			mi.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
			parent.add_child(mi)
			out.append([kind, mi])
	return out


static func prewarm_end(warm: Array) -> void:
	for pair in warm:
		var mi = pair[1]
		if not is_instance_valid(mi):
			continue
		(mi as Node).get_parent().remove_child(mi)
		if not _mmi_pool.has(pair[0]):
			_mmi_pool[pair[0]] = []
		(_mmi_pool[pair[0]] as Array).append(mi)


## Let every pooled MultiMesh go. For a streamer leaving the tree (see its
## `_exit_tree`); the pool fills again from the next tiles that leave.
static func clear_pool() -> void:
	_mm_pool.clear()
	# Pooled nodes are out of the tree, so nothing frees them but this.
	for kind in _mmi_pool:
		for mi in _mmi_pool[kind]:
			if is_instance_valid(mi):
				(mi as Node).free()
	_mmi_pool.clear()


## Hand this tile's instance nodes to the pool now, before it is freed: the
## streamer calls it as it replaces or drops a tile. The tile's own children
## are gone after this; the surface and collider are not touched.
func recycle() -> void:
	for pair in _mms:
		var mi = pair[2] if (pair as Array).size() > 2 else null
		if mi != null and is_instance_valid(mi) and (mi as Node).get_parent() == self:
			remove_child(mi)
			if not _mmi_pool.has(pair[0]):
				_mmi_pool[pair[0]] = []
			(_mmi_pool[pair[0]] as Array).append(mi)
		else:
			if not _mm_pool.has(pair[0]):
				_mm_pool[pair[0]] = []
			(_mm_pool[pair[0]] as Array).append(pair[1])
	_mms.clear()


func _release_multimeshes() -> void:
	for pair in _mms:
		if not _mm_pool.has(pair[0]):
			_mm_pool[pair[0]] = []
		(_mm_pool[pair[0]] as Array).append(pair[1])
	_mms.clear()
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
	set_notify_transform(true)
	PhysicsServer3D.body_set_mode(_body, PhysicsServer3D.BODY_MODE_STATIC)
	PhysicsServer3D.body_set_collision_layer(_body, Layers.WORLD)
	PhysicsServer3D.body_set_collision_mask(_body, Layers.STRUCTURE_MASK)
	PhysicsServer3D.body_set_state(_body, PhysicsServer3D.BODY_STATE_TRANSFORM,
			global_transform)
	for i in n:
		var o := i * 6
		PhysicsServer3D.body_add_shape(_body,
			_box_shape(Vector3(boxes[o + 3], boxes[o + 4], boxes[o + 5])),
			Transform3D(Basis(), Vector3(boxes[o], boxes[o + 1], boxes[o + 2])))
	# Into the space last: see add_collision.
	PhysicsServer3D.body_set_space(_body, get_world_3d().space)


## The collider has no node: when the tile is moved (an origin shift moves
## its streamer, Docs/MineWorld.md 15) the body is moved with it.
func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSFORM_CHANGED and _body.is_valid():
		PhysicsServer3D.body_set_state(_body, PhysicsServer3D.BODY_STATE_TRANSFORM,
				global_transform)


func _free_body() -> void:
	if _body.is_valid():
		PhysicsServer3D.free_rid(_body)
		_body = RID()


func _enter_tree() -> void:
	_live_tiles += 1


func _exit_tree() -> void:
	_free_body()
	_release_multimeshes()
	_live_tiles -= 1
	if _live_tiles <= 0:
		for rid in _box_shapes.values():
			PhysicsServer3D.free_rid(rid)
		_box_shapes.clear()
		clear_pool()
