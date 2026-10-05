class_name Snowfall
extends Disaster

## Snowfall (Docs/Disasters.md 21). Flakes come down round the player, drifting
## on a light wind; the sky goes a flat grey-white; and the snow LIES -- smooth
## tiles on every top open to the sky, on the ground and on buildings
## (SnowCover), filling in a cell at a time and thickening while it falls, and
## melting slowly after it stops (the disaster context eases it either way, so
## it outlasts the disaster). Soldiers see less in it, aim worse, and shelter.
##
## Intensity: how fast it lies and how thick the flakes come. The full cover
## takes DisasterContext.SNOW_S at intensity 1.

const WIND := 0.25                ## gale for the sway: a breeze
const DRIFT := 1.6                ## m/s the flakes drift with it

## The tuning, as variables so a heavier fall can be made of this one
## (Blizzard): the gale, the flakes' drift, the push on a walker, the haze on
## the lens, sight and aim, how fast it lies, how many flakes and how big.
var wind_k := WIND
var drift := DRIFT
var push := 0.0
var haze := 0.22
var sight := 0.7
var aim := 1.5
var rate_mul := 1.0
var flake_count := 9000
var flake_size := 0.07
var flake_life := 9.0
var _dir := Vector3.RIGHT
## For the probe: the wind on a walker now.
var wind := Vector3.ZERO

const SKY_SUN := Color(0.86, 0.88, 0.92)
const SKY_TOP := Color(0.62, 0.65, 0.7)
const SKY_HORIZON := Color(0.82, 0.84, 0.88)
const SKY_SUN_MUL := 0.55

## For the probe.
var flakes_on := false

var _sky := 0.0
var _sky_t := 0.0
var _sky_from := 0.0
var _heading := 0.0
var _flakes: GPUParticles3D
var _flake_proc: ParticleProcessMaterial
var _hush: AudioStreamPlayer


func _init() -> void:
	title = "Snowfall"
	warning_s = 8.0
	active_s = 60.0
	ending_s = 10.0


func _on_begin() -> void:
	_heading = rng.randf() * TAU
	_build()


func _on_phase(p: Phase) -> void:
	match p:
		Phase.ACTIVE:
			ctx.snowing = true
			ctx.snow_rate = maxf(intensity, 0.1) * rate_mul
			ctx.set_storm(true)
		Phase.ENDING:
			_sky_from = _sky
			ctx.snowing = false
		Phase.DONE:
			ctx.snowing = false
			ctx.gale = Vector3.ZERO
			ctx.set_wind(Vector3.ZERO)
			wind = Vector3.ZERO
			ctx.set_storm(false)
			_sky = 0.0
			_apply()
			_flakes.emitting = false
			_hush.stop()


func _tick_warning(_dt: float) -> void:
	_sky = phase_t / warning_s
	_apply()


func _tick_active(dt: float) -> void:
	_sky = 1.0
	_sky_t += dt
	_apply()


func _tick_ending(_dt: float) -> void:
	_sky = _sky_from * (1.0 - phase_t / ending_s)
	_apply()


func _apply() -> void:
	ctx.set_sky(_sky, SKY_SUN, SKY_TOP, SKY_HORIZON, SKY_SUN_MUL)
	# Snow blinds more than rain: sight down further, aim a little worse.
	ctx.set_weather(_sky, sight, aim, intensity)
	ctx.set_screen(0.0, _sky * haze, Color(0.9, 0.92, 0.96))
	var dir := Vector3(cos(_heading), 0.0, sin(_heading))
	ctx.gale = dir * wind_k * _sky
	if push > 0.0:
		# Gusting: a blizzard leans on whoever is out in it.
		var gust := 0.8 + 0.2 * sin(_sky_t * 1.3) + 0.12 * sin(_sky_t * 3.7)
		wind = dir * push * _sky * gust * minf(intensity, 2.0)
		ctx.set_wind(wind)
	if _flakes != null:
		flakes_on = _sky > 0.3
		_flakes.emitting = flakes_on
		_flakes.amount_ratio = clampf(_sky * minf(intensity, 1.5) / 1.5 + 0.2, 0.0, 1.0)
		# Carried at the wind's speed from the start -- a velocity, not a pull,
		# or a flake nine seconds old would be doing a hundred metres a second.
		var v := Vector3(dir.x * drift, -1.1, dir.z * drift)
		_flake_proc.direction = v.normalized()
		_flake_proc.initial_velocity_min = v.length() * 0.8
		_flake_proc.initial_velocity_max = v.length() * 1.2
		_dir = dir
	_hush.volume_db = lerpf(-40.0, -14.0, _sky)
	if _sky > 0.0 and not _hush.playing:
		_hush.play()


func _process(_delta: float) -> void:
	if _flakes != null and phase != Phase.DONE:
		# Upwind, so the flakes are round the player in the middle of their lives.
		_flakes.global_position = ctx.player_pos() + Vector3.UP * (1.1 * flake_life * 0.5 + 2.0) \
				- _dir * drift * flake_life * 0.5


func _build() -> void:
	var puff := GradientTexture2D.new()
	puff.width = 32
	puff.height = 32
	puff.fill = GradientTexture2D.FILL_RADIAL
	puff.fill_from = Vector2(0.5, 0.5)
	puff.fill_to = Vector2(1.0, 0.5)
	var pg := Gradient.new()
	pg.colors = PackedColorArray([Color(1, 1, 1, 1), Color(1, 1, 1, 0)])
	puff.gradient = pg
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.albedo_texture = puff
	mat.albedo_color = Color(1, 1, 1, 0.9)
	var flake := QuadMesh.new()
	flake.size = Vector2(flake_size, flake_size)
	flake.material = mat
	_flake_proc = ParticleProcessMaterial.new()
	_flake_proc.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	_flake_proc.emission_box_extents = Vector3(26.0, 6.0, 26.0)
	_flake_proc.direction = Vector3.DOWN
	_flake_proc.spread = 15.0
	_flake_proc.initial_velocity_min = 0.6
	_flake_proc.initial_velocity_max = 1.4
	_flake_proc.gravity = Vector3(0.0, -0.2, 0.0)
	# The flutter: flakes do not fall straight.
	_flake_proc.turbulence_enabled = true
	_flake_proc.turbulence_noise_strength = 1.5
	_flake_proc.turbulence_noise_scale = 3.0
	_flake_proc.turbulence_influence_min = 0.05
	_flake_proc.turbulence_influence_max = 0.15
	_flake_proc.scale_min = 0.6
	_flake_proc.scale_max = 1.6
	_flakes = GPUParticles3D.new()
	_flakes.amount = flake_count
	_flakes.lifetime = flake_life
	_flakes.preprocess = 4.0
	_flakes.local_coords = false
	_flakes.emitting = false
	_flakes.process_material = _flake_proc
	_flakes.draw_pass_1 = flake
	_flakes.visibility_aabb = AABB(Vector3(-40, -30, -40), Vector3(80, 50, 80))
	add_child(_flakes)
	# The hush of a snowfall: the wind, low.
	_hush = AudioStreamPlayer.new()
	_hush.stream = DisasterSounds.wind()
	_hush.pitch_scale = 0.6
	_hush.volume_db = -40.0
	add_child(_hush)
