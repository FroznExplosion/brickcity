class_name Sandstorm
extends Disaster

## A sandstorm (Docs/Disasters.md 25). A brown wall comes in on the wind --
## a band of dust rolling across from upwind during the warning -- then a
## heavy haze for most of a minute: the sky and sun gone a dull orange,
## sight down to the floor, aim far worse, a strong steady wind leaning on
## whoever is out in it and swaying the trees, and sand streaming low and fast.
##
##   * SAND-BLASTING: what faces the wind wears. Every BLAST_EVERY a few rays
##     go downwind from round the player at head-to-roof height; a wall they
##     meet is chipped a little, by how much its material minds it -- plastic
##     most, metal and stone hardly.
##   * SAND LIES: a thin drift of it (the snow cover, tinted, capped at
##     LIE_CAP), and it blows away after.
##
## Deterministic: the heading and every blasting ray from the rng.

const WIND := 0.85                ## gale, for the sway
const PUSH := 1.4                 ## m/s on a walker at full strength
const LIE_CAP := 0.3
const SAND := Color(0.82, 0.68, 0.48)
const BLAST_EVERY := 0.35         ## s
const RAYS := 5                   ## a round, at intensity 1
const REACH := 45.0               ## m round the player the rays start
const CHIP_HP := 10
const CHIP_RADIUS := 0.35
## How much each material minds it (brick_grid.h order, as Hailstorm.HARD).
const HARD := [1.0, 1.0, 1.0, 0.7, 0.6, 0.4, 0.5, 1.0, 0.6, 0.9, 0.7, 0.05, 0.15, 0.5]

const SKY_SUN := Color(0.95, 0.66, 0.4)
const SKY_TOP := Color(0.58, 0.44, 0.3)
const SKY_HORIZON := Color(0.72, 0.55, 0.36)
const SKY_SUN_MUL := 0.35

## For the probe.
var chips := 0
var wind := Vector3.ZERO

var _sky := 0.0
var _sky_from := 0.0
var _heading := 0.0
var _next := 0.0
var _t := 0.0
var _sand: GPUParticles3D
var _sand_proc: ParticleProcessMaterial
var _wall: GPUParticles3D
var _roar: AudioStreamPlayer
var _hiss: AudioStreamPlayer


func _init() -> void:
	title = "Sandstorm"
	warning_s = 10.0
	active_s = 55.0
	ending_s = 12.0


func _on_begin() -> void:
	_heading = rng.randf() * TAU
	_build()


func _dir() -> Vector3:
	return Vector3(cos(_heading), 0.0, sin(_heading))


func _on_phase(p: Phase) -> void:
	match p:
		Phase.ACTIVE:
			ctx.set_storm(true)
			ctx.snowing = true
			ctx.snow_cap = LIE_CAP
			ctx.snow_tint = SAND
			ctx.snow_rate = maxf(intensity, 0.1) * 1.5
			_wall.emitting = false
		Phase.ENDING:
			_sky_from = _sky
			ctx.snowing = false
		Phase.DONE:
			ctx.snowing = false
			ctx.set_storm(false)
			ctx.gale = Vector3.ZERO
			ctx.set_wind(Vector3.ZERO)
			wind = Vector3.ZERO
			_sky = 0.0
			_apply()
			_sand.emitting = false
			_roar.stop()
			_hiss.stop()


func _tick_warning(dt: float) -> void:
	_sky = 0.35 * phase_t / warning_s
	_t += dt
	_apply()
	# The wall: rolling in from upwind, arriving as ACTIVE begins.
	var k := phase_t / warning_s
	_wall.emitting = true
	_wall.global_position = ctx.player_pos() - _dir() * lerpf(160.0, 10.0, k) + Vector3.UP * 12.0


func _tick_active(dt: float) -> void:
	_sky = minf(1.0, _sky + dt / 3.0)
	_t += dt
	_apply()
	_next -= dt
	if _next <= 0.0:
		_next += BLAST_EVERY
		_blast_round()


func _tick_ending(dt: float) -> void:
	_sky = _sky_from * (1.0 - phase_t / ending_s)
	_t += dt
	_apply()


func _apply() -> void:
	ctx.set_sky(_sky, SKY_SUN, SKY_TOP, SKY_HORIZON, SKY_SUN_MUL)
	ctx.set_weather(_sky, 0.6, 1.9, intensity)
	ctx.set_screen(0.0, _sky * 0.78, Color(0.7, 0.55, 0.38))
	var gust := 0.85 + 0.15 * sin(_t * 0.7) + 0.08 * sin(_t * 2.9)
	ctx.gale = _dir() * WIND * _sky * gust
	wind = _dir() * PUSH * _sky * gust * minf(intensity, 2.0)
	ctx.set_wind(wind)
	if _sand != null:
		_sand.emitting = _sky > 0.2
		_sand.amount_ratio = clampf(_sky * minf(intensity, 1.5) / 1.5 + 0.1, 0.0, 1.0)
		var v := _dir() * 14.0 * maxf(_sky, 0.3)
		_sand_proc.direction = (v + Vector3.DOWN * 0.6).normalized()
		_sand_proc.initial_velocity_min = v.length() * 0.8
		_sand_proc.initial_velocity_max = v.length() * 1.2
	_roar.volume_db = lerpf(-40.0, -4.0, _sky)
	_hiss.volume_db = lerpf(-40.0, -14.0, _sky)
	if _sky > 0.0 and not _roar.playing:
		_roar.play()
		_hiss.play()


## Sand-blasting: rays downwind from round the player; walls met are worn.
func _blast_round() -> void:
	var at := ctx.player_pos()
	var dir := _dir()
	var side := dir.cross(Vector3.UP)
	var n := maxi(1, int(round(RAYS * intensity)))
	for i in n:
		var from := at - dir * rng.randf_range(10.0, REACH) + side * rng.randf_range(-REACH, REACH)
		from.y = at.y + rng.randf_range(-2.0, 18.0)
		var hit := ctx.ray(from, from + dir * 30.0)
		if hit.is_empty() or ctx.building_at(hit.position, 0.3) < 0:
			continue
		var m := ctx.material_at(hit.position + dir * 0.05)
		if m < 0:
			continue
		var k: float = HARD[m] if m < HARD.size() else 0.6
		ctx.chip(hit.position, CHIP_RADIUS, int(round(CHIP_HP * k * intensity)))
		chips += 1


func _process(_delta: float) -> void:
	if _sand != null and phase != Phase.DONE:
		_sand.global_position = ctx.player_pos() - _dir() * 20.0 + Vector3.UP * 3.0


func _build() -> void:
	var puff := GradientTexture2D.new()
	puff.width = 64
	puff.height = 64
	puff.fill = GradientTexture2D.FILL_RADIAL
	puff.fill_from = Vector2(0.5, 0.5)
	puff.fill_to = Vector2(1.0, 0.5)
	var pg := Gradient.new()
	pg.colors = PackedColorArray([Color(1, 1, 1, 1), Color(1, 1, 1, 0)])
	puff.gradient = pg

	# Sand streaming low: specks, fast, along the wind.
	var speck_mat := StandardMaterial3D.new()
	speck_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	speck_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	speck_mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	speck_mat.albedo_color = Color(0.85, 0.7, 0.5, 0.6)
	var speck := QuadMesh.new()
	speck.size = Vector2(0.03, 0.03)
	speck.material = speck_mat
	_sand_proc = ParticleProcessMaterial.new()
	_sand_proc.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	_sand_proc.emission_box_extents = Vector3(30.0, 3.0, 30.0)
	_sand_proc.spread = 6.0
	_sand_proc.gravity = Vector3(0.0, -0.4, 0.0)
	_sand_proc.turbulence_enabled = true
	_sand_proc.turbulence_noise_strength = 1.2
	_sand_proc.turbulence_influence_min = 0.05
	_sand_proc.turbulence_influence_max = 0.12
	_sand = GPUParticles3D.new()
	_sand.amount = 9000
	_sand.lifetime = 3.0
	_sand.local_coords = false
	_sand.emitting = false
	_sand.process_material = _sand_proc
	_sand.draw_pass_1 = speck
	_sand.visibility_aabb = AABB(Vector3(-60, -20, -60), Vector3(120, 40, 120))
	add_child(_sand)

	# The wall: huge slow puffs in a band across the wind.
	var wall_mat := StandardMaterial3D.new()
	wall_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	wall_mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	wall_mat.vertex_color_use_as_albedo = true
	wall_mat.albedo_texture = puff
	var wall_quad := QuadMesh.new()
	wall_quad.size = Vector2(26.0, 26.0)
	wall_quad.material = wall_mat
	var wall_proc := ParticleProcessMaterial.new()
	wall_proc.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	var side := _dir().cross(Vector3.UP)
	wall_proc.emission_box_extents = Vector3(absf(side.x) * 160.0 + 6.0, 14.0, absf(side.z) * 160.0 + 6.0)
	wall_proc.direction = _dir()
	wall_proc.spread = 10.0
	wall_proc.initial_velocity_min = 4.0
	wall_proc.initial_velocity_max = 7.0
	wall_proc.gravity = Vector3.ZERO
	wall_proc.scale_min = 0.7
	wall_proc.scale_max = 1.6
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.3, 1.0])
	g.colors = PackedColorArray([Color(0.6, 0.45, 0.3, 0.0), Color(0.62, 0.47, 0.32, 0.9),
			Color(0.6, 0.46, 0.32, 0.0)])
	var ramp := GradientTexture1D.new()
	ramp.gradient = g
	wall_proc.color_ramp = ramp
	_wall = GPUParticles3D.new()
	_wall.amount = 260
	_wall.lifetime = 7.0
	_wall.local_coords = false
	_wall.emitting = false
	_wall.process_material = wall_proc
	_wall.draw_pass_1 = wall_quad
	_wall.visibility_aabb = AABB(Vector3(-220, -40, -220), Vector3(440, 120, 440))
	add_child(_wall)

	_roar = AudioStreamPlayer.new()
	_roar.stream = DisasterSounds.wind()
	_roar.pitch_scale = 0.8
	_roar.volume_db = -40.0
	add_child(_roar)
	_hiss = AudioStreamPlayer.new()
	_hiss.stream = DisasterSounds.rain()
	_hiss.pitch_scale = 2.2
	_hiss.volume_db = -40.0
	add_child(_hiss)
