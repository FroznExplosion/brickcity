class_name PlanetBody
extends Node3D

## One planet, at its centre (Docs/Planets.md 11.1). After STA's PlanetUnit
## (C:\Users\lbaun\Documents\sta\scripts\planet_unit.gd), trimmed: no caves, no
## edit stream, no water simulation, one planet. Everything ON the planet is a
## child of this node in planet-local space, so a floating-origin shift moves
## this node and nothing inside it streams again.
##
## Always drawn: the impostor (the planet from afar, baked from the same
## ground), the atmosphere shell and the sea shell. While `active` (the player is
## on or near it): the voxel ground, Zylann's VoxelLodTerrain with Transvoxel
## and clipbox streaming, its colliders, cross-faded with the impostor by the
## camera's altitude over the band tier1..tier2 (STA's 8% and 15% of R).

var data: PlanetData
var terrain: VoxelLodTerrain
var impostor: MeshInstance3D
var atmosphere: MeshInstance3D
var ocean: MeshInstance3D
var active := false
var bake_ms := 0

## The voxel ground reaches this far, the impostor beyond (STA's VOXEL_REACH):
## it caps the LOD pyramid at lod_distance * 2^lod_count.
const VOXEL_REACH := 4096.0
const LOD_DISTANCE := 48.0
const MESH_BLOCK := 32

var tier1 := 800.0
var tier2 := 1500.0
var sun_dir := Vector3(0.4, 0.6, 0.3).normalized()   # planet-local, surface -> sun

var _impostor_mat: ShaderMaterial
var _atmo_mat: ShaderMaterial
var _ocean_mat: ShaderMaterial
var _ground_mat: ShaderMaterial
var _graph: VoxelGeneratorGraph
var _time := 0.0


func setup(p_data: PlanetData) -> void:
	data = p_data
	name = "Planet_" + data.planet_name
	tier1 = data.radius * 0.08
	tier2 = data.radius * 0.15
	_graph = PlanetGraph.build(data)
	_build_impostor()
	_build_atmosphere()
	if not is_nan(data.sea_level):
		_build_ocean()


## The voxel ground, for the planet the player is on.
func activate() -> void:
	if active:
		return
	active = true
	var t := VoxelLodTerrain.new()
	t.name = "Ground"
	t.mesher = VoxelMesherTransvoxel.new()
	t.generator = _graph
	t.material = _ground_material()
	t.streaming_system = VoxelLodTerrain.STREAMING_SYSTEM_CLIPBOX
	t.threaded_update_enabled = true
	t.mesh_block_size = MESH_BLOCK
	t.lod_count = clampi(int(ceil(log(VOXEL_REACH / LOD_DISTANCE) / log(2.0))), 4, 9)
	t.lod_distance = LOD_DISTANCE
	# After mesh_block_size and lod_count: the bounds snap to the octree size
	# those give at the moment they are set (STA's note).
	var half := data.radius + data.peak() + 128.0
	t.voxel_bounds = AABB(Vector3(-half, -half, -half), Vector3(half, half, half) * 2.0)
	t.generate_collisions = true
	t.collision_lod_count = 1
	t.collision_update_delay = 250
	t.view_distance = 6000
	add_child(t)
	terrain = t


func deactivate() -> void:
	if not active:
		return
	active = false
	if terrain != null:
		terrain.queue_free()
		terrain = null


## Ground under `node` wherever it goes: a VoxelViewer of its own, for
## colliders only, `radius` metres round it. The player's viewer streams the
## ground round the PLAYER; a mech, a vehicle or a soldier 150 m off would
## otherwise walk off the edge of the colliders and fall into the planet.
## Zylann's terrain serves any number of viewers.
static func track(node: Node3D, radius := 96) -> VoxelViewer:
	if node.has_node(^"GroundViewer"):
		return node.get_node(^"GroundViewer")
	var v := VoxelViewer.new()
	v.name = "GroundViewer"
	v.view_distance = radius
	v.requires_visuals = false
	v.requires_collisions = true
	node.add_child(v)
	return v


## Altitude of a world point over the datum.
func altitude_of(world: Vector3) -> float:
	return (world - global_position).length() - data.radius


## Planet-local direction of a world point.
func dir_of(world: Vector3) -> Vector3:
	return (world - global_position).normalized()


## The ground under a world point, in world space.
func ground_under(world: Vector3) -> Vector3:
	var d := dir_of(world)
	return global_position + data.surface_point(d)


func _process(delta: float) -> void:
	_time += delta
	if _ocean_mat != null:
		_ocean_mat.set_shader_parameter("time_s", _time)
	if _ground_mat != null:
		_ground_mat.set_shader_parameter("planet_centre", global_position)
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var alt := altitude_of(cam.global_position)
	if terrain != null:
		var fade := clampf(smoothstep(tier1, tier2, alt), 0.0, 1.0)
		impostor.visible = fade > 0.001
		terrain.visible = fade < 0.999
		_impostor_mat.set_shader_parameter("fade", fade)
	else:
		impostor.visible = true
		_impostor_mat.set_shader_parameter("fade", 1.0)


## The horizon from `world` (STA's horizon view distance): eye to horizon,
## plus horizon to the tallest thing of height `top` over the datum behind it.
func horizon_reach(world: Vector3, top: float) -> float:
	var r := data.radius
	var h := maxf(altitude_of(world), 2.0)
	return sqrt(h * (2.0 * r + h)) + sqrt(maxf(top, 0.0) * (2.0 * r + maxf(top, 0.0)))


func set_sun(dir_local: Vector3) -> void:
	sun_dir = dir_local.normalized()
	for m in [_impostor_mat, _atmo_mat]:
		if m != null:
			m.set_shader_parameter("sun_dir", sun_dir)


func _ground_material() -> ShaderMaterial:
	if _ground_mat == null:
		_ground_mat = ShaderMaterial.new()
		_ground_mat.shader = load("res://shaders/planet_ground.gdshader")
		_ground_mat.set_shader_parameter("planet_radius", data.radius)
		_ground_mat.set_shader_parameter("sea_level", data.sea_level if not is_nan(data.sea_level) else -1e9)
	return _ground_mat


func _build_impostor() -> void:
	var b := PlanetImpostorBake.bake(data)
	bake_ms = int(b.ms)
	var sm := SphereMesh.new()
	sm.radius = data.radius
	sm.height = data.radius * 2.0
	sm.radial_segments = 256
	sm.rings = 128
	impostor = MeshInstance3D.new()
	impostor.name = "Impostor"
	impostor.mesh = sm
	_impostor_mat = ShaderMaterial.new()
	_impostor_mat.shader = load("res://shaders/planet_impostor.gdshader")
	_impostor_mat.set_shader_parameter("heightmap", b.heightmap)
	_impostor_mat.set_shader_parameter("color_map", b.color_map)
	_impostor_mat.set_shader_parameter("amplitude", b.amplitude)
	_impostor_mat.set_shader_parameter("atmo_color", data.atmosphere_color)
	_impostor_mat.set_shader_parameter("sun_dir", sun_dir)
	# A few metres under the true ground: where both draw, the voxels win.
	_impostor_mat.set_shader_parameter("sink", 6.0)
	impostor.material_override = _impostor_mat
	impostor.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	impostor.extra_cull_margin = data.radius
	add_child(impostor)


func _build_atmosphere() -> void:
	var r := data.radius * 1.08
	var sm := SphereMesh.new()
	sm.radius = r
	sm.height = r * 2.0
	sm.radial_segments = 96
	sm.rings = 48
	atmosphere = MeshInstance3D.new()
	atmosphere.name = "Atmosphere"
	atmosphere.mesh = sm
	_atmo_mat = ShaderMaterial.new()
	_atmo_mat.shader = load("res://shaders/planet_atmosphere.gdshader")
	_atmo_mat.set_shader_parameter("atmo_color", data.atmosphere_color)
	_atmo_mat.set_shader_parameter("sun_dir", sun_dir)
	atmosphere.material_override = _atmo_mat
	atmosphere.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(atmosphere)


func _build_ocean() -> void:
	var r := data.radius + data.sea_level
	var sm := SphereMesh.new()
	sm.radius = r
	sm.height = r * 2.0
	sm.radial_segments = 1024
	sm.rings = 512
	ocean = MeshInstance3D.new()
	ocean.name = "Sea"
	ocean.mesh = sm
	_ocean_mat = ShaderMaterial.new()
	_ocean_mat.shader = load("res://shaders/planet_ocean.gdshader")
	ocean.material_override = _ocean_mat
	ocean.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	ocean.extra_cull_margin = data.radius
	add_child(ocean)
