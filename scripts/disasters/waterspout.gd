class_name Waterspout
extends Tornado

## A waterspout (Docs/Disasters.md 26): a tornado over the sea. It forms on
## open water near the player and wanders across it -- a pale, watery funnel,
## spray thrown up in a ring at its foot -- with its own rain cell travelling
## with it: rain falls, splashes and patters (RainSplash, SurfaceSounds) only
## inside the cell, so a dry beach watches it come and is drenched only if it
## comes ashore. Everything a tornado does to what it reaches is the
## tornado's: loose pieces pulled round, people shoved, facades chipped.
##
## Where there is no sea it wanders as a small tornado instead.

const SEA_REACH := 160.0          ## m round the player it may form
const DEEP := 0.8                 ## m of water under a point it may walk on
const WANDER := 4                 ## waypoints
const RAIN_RADIUS := 32.0         ## m of its rain cell

## For the probe.
var over_water := 0               ## ticks it stood on the sea
var cell_wet := false             ## the player was in its rain

var _cell_rain: GPUParticles3D
var _cell_proc: ParticleProcessMaterial
var _splash: RainSplash
var _spray: GPUParticles3D


func _init() -> void:
	super()
	title = "Waterspout"


func _on_begin() -> void:
	super()
	_funnel_mat.set_shader_parameter("dust_colour", Color(0.72, 0.78, 0.84, 1.0))
	_funnel_mat.set_shader_parameter("dark_colour", Color(0.36, 0.42, 0.48, 1.0))
	_build_water()


## Over water: a seeded wander between sea points near the player.
func _plan(toward_player: bool) -> void:
	var sea := BrickWave.get_sea_level()
	var at := ctx.player_pos()
	var points: Array[Vector3] = []
	var stud := BrickWorld.get_stud_metres()
	var plate := BrickWorld.get_plate_metres()
	var tries := 0
	while points.size() < WANDER and tries < 400:
		tries += 1
		var a := rng.randf() * TAU
		var d := lerpf(40.0, SEA_REACH, rng.randf())
		var p := Vector3(at.x + cos(a) * d, sea, at.z + sin(a) * d)
		var ground := float(BrickTerrain.surface_plate(floori(p.x / stud), floori(p.z / stud)) + 1) * plate
		if ground < sea - DEEP:
			points.append(p)
	if points.size() < 2 or not ctx.city.has_method("has_terrain") or not ctx.city.has_terrain():
		super(toward_player)
		return
	# Nearest the player in the middle of the walk, so it comes close.
	if toward_player:
		points.sort_custom(func(p: Vector3, q: Vector3) -> bool:
			return p.distance_to(at) > q.distance_to(at))
		var near: Vector3 = points.pop_back()
		points.insert(points.size() >> 1, near)
	var ctrl: Array = [points[0]] + points + [points[points.size() - 1]]
	path = PackedVector3Array()
	for seg in range(1, ctrl.size() - 2):
		for i in 24:
			path.append(Tornado._catmull(ctrl[seg - 1], ctrl[seg], ctrl[seg + 1], ctrl[seg + 2], i / 24.0))
	path.append(points[points.size() - 1])
	_along = PackedFloat32Array([0.0])
	for i in range(1, path.size()):
		_along.append(_along[i - 1] + path[i].distance_to(path[i - 1]))
	var length := _along[_along.size() - 1]
	active_s = clampf(length / WALK + 2.0, 30.0, 70.0)
	speed = length / (active_s - 2.0)


func _tick_active(dt: float) -> void:
	super(dt)
	_water_step()


func _tick_ending(dt: float) -> void:
	super(dt)
	_water_step()


## The rain cell, the spray, and whether the player is in it.
func _water_step() -> void:
	var sea := BrickWave.get_sea_level()
	var stud := BrickWorld.get_stud_metres()
	var plate := BrickWorld.get_plate_metres()
	var ground := float(BrickTerrain.surface_plate(floori(pos.x / stud), floori(pos.z / stud)) + 1) * plate
	var wet_foot := ground < sea - 0.1
	if wet_foot:
		over_water += 1
	_spray.emitting = wet_foot and strength > 0.2
	_spray.global_position = Vector3(pos.x, sea, pos.z)
	_cell_rain.emitting = strength > 0.15
	_cell_rain.amount_ratio = strength
	_cell_rain.global_position = Vector3(pos.x, maxf(sea, ground) + 26.0, pos.z)
	_splash.area = Vector3(pos.x, pos.z, RAIN_RADIUS)
	var pl := ctx.player_pos()
	var d := Vector2(pl.x - pos.x, pl.z - pos.z).length()
	var inside := d < RAIN_RADIUS * 1.1 and strength > 0.15
	cell_wet = cell_wet or inside
	ctx.raining = inside
	var k := clampf(1.0 - d / (RAIN_RADIUS * 1.6), 0.0, 1.0) * strength
	ctx.set_screen(k, strength * 0.2 * k, Color(0.6, 0.66, 0.72))


func _on_phase(p: Phase) -> void:
	super(p)
	if p == Phase.DONE:
		ctx.raining = false
		_cell_rain.emitting = false
		_spray.emitting = false


func _build_water() -> void:
	var drop_mat := StandardMaterial3D.new()
	drop_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	drop_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	drop_mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	drop_mat.albedo_color = Color(0.78, 0.84, 0.9, 0.35)
	var drop := QuadMesh.new()
	drop.size = Vector2(0.03, 0.7)
	drop.material = drop_mat
	_cell_proc = ParticleProcessMaterial.new()
	_cell_proc.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	_cell_proc.emission_sphere_radius = RAIN_RADIUS
	_cell_proc.direction = Vector3.DOWN
	_cell_proc.spread = 4.0
	_cell_proc.initial_velocity_min = 20.0
	_cell_proc.initial_velocity_max = 26.0
	_cell_proc.gravity = Vector3(0.0, -6.0, 0.0)
	_cell_proc.particle_flag_align_y = true
	_cell_rain = GPUParticles3D.new()
	_cell_rain.amount = 6000
	_cell_rain.lifetime = 1.4
	_cell_rain.local_coords = false
	_cell_rain.emitting = false
	_cell_rain.process_material = _cell_proc
	_cell_rain.draw_pass_1 = drop
	_cell_rain.visibility_aabb = AABB(Vector3(-50, -40, -50), Vector3(100, 60, 100))
	add_child(_cell_rain)
	_splash = RainSplash.add(_cell_rain, _cell_proc, self, Color(0.9, 0.94, 1.0, 0.9), "rain", ctx)

	var puff := GradientTexture2D.new()
	puff.fill = GradientTexture2D.FILL_RADIAL
	puff.fill_from = Vector2(0.5, 0.5)
	puff.fill_to = Vector2(1.0, 0.5)
	var pg := Gradient.new()
	pg.colors = PackedColorArray([Color(1, 1, 1, 1), Color(1, 1, 1, 0)])
	puff.gradient = pg
	var spray_mat := StandardMaterial3D.new()
	spray_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	spray_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	spray_mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	spray_mat.vertex_color_use_as_albedo = true
	spray_mat.albedo_texture = puff
	var spray_quad := QuadMesh.new()
	spray_quad.size = Vector2(3.0, 3.0)
	spray_quad.material = spray_mat
	var sp := ParticleProcessMaterial.new()
	sp.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_RING
	sp.emission_ring_axis = Vector3.UP
	sp.emission_ring_radius = 7.0
	sp.emission_ring_inner_radius = 3.0
	sp.emission_ring_height = 0.5
	sp.direction = Vector3.UP
	sp.spread = 30.0
	sp.initial_velocity_min = 4.0
	sp.initial_velocity_max = 9.0
	sp.gravity = Vector3(0.0, -4.0, 0.0)
	sp.tangential_accel_min = 6.0
	sp.tangential_accel_max = 10.0
	sp.scale_min = 0.6
	sp.scale_max = 1.8
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.3, 1.0])
	g.colors = PackedColorArray([Color(1, 1, 1, 0.0), Color(0.93, 0.96, 1.0, 0.8),
			Color(0.9, 0.93, 0.96, 0.0)])
	var ramp := GradientTexture1D.new()
	ramp.gradient = g
	sp.color_ramp = ramp
	_spray = GPUParticles3D.new()
	_spray.amount = 220
	_spray.lifetime = 1.8
	_spray.local_coords = false
	_spray.emitting = false
	_spray.process_material = sp
	_spray.draw_pass_1 = spray_quad
	_spray.visibility_aabb = AABB(Vector3(-20, -5, -20), Vector3(40, 30, 40))
	add_child(_spray)
