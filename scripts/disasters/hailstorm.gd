class_name Hailstorm
extends Disaster

## A hailstorm (Docs/Disasters.md 24). Stones of ice come down hard out of a
## green-grey sky for half a minute, and what they hit is HEARD: each stone
## sounds as the material it struck -- a plastic roof clatters, a metal one
## rings, the ground thuds, the sea plips (SurfaceSounds, on the points
## RainSplash finds open to the sky; a floor under a roof is never hit, and
## from indoors the storm is on the roof overhead).
##
##   * The stones bounce: each landing throws up a few pellets.
##   * They wear what they land on -- a CHIP at a share of the landings each
##     refresh, by how much the material minds it (plastic most, metal and
##     stone hardly) -- and anyone out in it is bruised.
##   * They lie: a thin white of ice, patchy (the snow cover, capped at
##     LIE_CAP), melting after.
##
## Deterministic: which landings chip comes from the rng on the physics tick.

const LIE_CAP := 0.4
const CHIP_EVERY := 0.4           ## s
const CHIPS := 4                  ## a round, at intensity 1
const CHIP_HP := 22
const CHIP_RADIUS := 0.25
const PAWN_DAMAGE := 0.6          ## a round, to anyone with no roof
## How much each material minds it, by index (brick_grid.h): PLA, PLA matte,
## PLA silk, ABS, PETG, TPU, Nylon, Glow PLA, Carbon PLA, Wood PLA, Wood,
## Metal, Stone, Leaf.
const HARD := [1.0, 1.0, 1.0, 0.7, 0.6, 0.2, 0.5, 1.0, 0.6, 0.9, 0.5, 0.1, 0.05, 0.8]

const SKY_SUN := Color(0.72, 0.8, 0.72)
const SKY_TOP := Color(0.26, 0.32, 0.28)
const SKY_HORIZON := Color(0.46, 0.54, 0.48)
const SKY_SUN_MUL := 0.45

## For the probe.
var landings := 0
var chips := 0
var bruised := 0

var _sky := 0.0
var _sky_from := 0.0
var _next := 0.0
var _hail: GPUParticles3D
var _proc: ParticleProcessMaterial
var _splash: RainSplash
var _roar: AudioStreamPlayer


func _init() -> void:
	title = "Hailstorm"
	warning_s = 6.0
	active_s = 35.0
	ending_s = 8.0


func _on_begin() -> void:
	_build()


func _on_phase(p: Phase) -> void:
	match p:
		Phase.ACTIVE:
			ctx.set_storm(true)
			ctx.snowing = true
			ctx.snow_cap = LIE_CAP
			ctx.snow_rate = maxf(intensity, 0.1) * 3.0
		Phase.ENDING:
			_sky_from = _sky
			ctx.snowing = false
		Phase.DONE:
			ctx.snowing = false
			ctx.set_storm(false)
			_sky = 0.0
			_apply()
			_hail.emitting = false
			_roar.stop()


func _tick_warning(_dt: float) -> void:
	_sky = phase_t / warning_s
	_apply()


func _tick_active(dt: float) -> void:
	_sky = 1.0
	_apply()
	_next -= dt
	if _next <= 0.0:
		_next += CHIP_EVERY
		_round()


func _tick_ending(_dt: float) -> void:
	_sky = _sky_from * (1.0 - phase_t / ending_s)
	_apply()


func _apply() -> void:
	ctx.set_sky(_sky, SKY_SUN, SKY_TOP, SKY_HORIZON, SKY_SUN_MUL)
	ctx.set_weather(_sky, 0.85, 1.6, intensity)
	ctx.set_screen(_sky * 0.35, _sky * 0.08, Color(0.8, 0.85, 0.85), Color(0.92, 0.95, 1.0))
	ctx.gale = Vector3(0.5, 0.0, -0.8) * 0.35 * _sky
	if _hail != null:
		_hail.emitting = _sky > 0.35
		_hail.amount_ratio = clampf(_sky * minf(intensity, 1.5) / 1.5 + 0.15, 0.0, 1.0)
	_roar.volume_db = lerpf(-40.0, -16.0, _sky)
	if _sky > 0.0 and not _roar.playing:
		_roar.play()


## A share of the stones that landed this refresh wear what they hit; anyone
## out in it is bruised.
func _round() -> void:
	var hits: Array = _splash.hits
	landings += hits.size()
	if not hits.is_empty():
		var n := maxi(1, int(round(CHIPS * intensity)))
		for i in n:
			var h: Array = hits[rng.randi() % hits.size()]
			var p: Vector3 = h[0]
			if ctx.building_at(p, 0.3) < 0:
				continue
			var m := ctx.material_at(p - (h[1] as Vector3) * 0.05)
			if m < 0:
				continue
			var k: float = HARD[m] if m < HARD.size() else 0.6
			ctx.chip(p, CHIP_RADIUS, int(round(CHIP_HP * k * intensity)))
			chips += 1
	var s = ctx.city.get("ai_services")
	for p in ctx.pawns():
		if s == null or not BTShelter.covered(s, p.feet()):
			if ctx.damage_pawns(p.chest(), 0.5, PAWN_DAMAGE * intensity) > 0:
				bruised += 1


func _process(_delta: float) -> void:
	if _hail != null and phase != Phase.DONE:
		_hail.global_position = ctx.player_pos() + Vector3.UP * 16.0


func _build() -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.9, 0.95, 1.0)
	mat.roughness = 0.2
	mat.metallic_specular = 0.8
	var stone := SphereMesh.new()
	stone.radius = 0.035
	stone.height = 0.07
	stone.radial_segments = 6
	stone.rings = 3
	stone.material = mat
	_proc = ParticleProcessMaterial.new()
	_proc.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	_proc.emission_box_extents = Vector3(26.0, 1.0, 26.0)
	_proc.direction = Vector3(0.08, -1.0, -0.12)
	_proc.spread = 4.0
	_proc.initial_velocity_min = 20.0
	_proc.initial_velocity_max = 26.0
	_proc.gravity = Vector3(0.0, -9.8, 0.0)
	_proc.scale_min = 0.6
	_proc.scale_max = 1.6
	_hail = GPUParticles3D.new()
	_hail.amount = 5000
	_hail.lifetime = 1.0
	_hail.local_coords = false
	_hail.emitting = false
	_hail.amount_ratio = 0.0
	_hail.process_material = _proc
	_hail.draw_pass_1 = stone
	_hail.visibility_aabb = AABB(Vector3(-40, -40, -40), Vector3(80, 60, 80))
	add_child(_hail)
	# Each landing heard as what it hit, and bouncing pellets where they land.
	_splash = RainSplash.add(_hail, _proc, self, Color(0.92, 0.96, 1.0, 1.0), "hail", ctx)
	_splash.bounce(stone)
	_roar = AudioStreamPlayer.new()
	_roar.stream = DisasterSounds.rain()
	_roar.pitch_scale = 1.6
	_roar.volume_db = -40.0
	add_child(_roar)
