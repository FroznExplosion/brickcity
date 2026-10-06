class_name AcidRain
extends Disaster

## Acid rain (Docs/Disasters.md 14). A printed city's own weather: it eats
## filament. For forty seconds drops come down round the player, a few every
## DROP_EVERY; each is followed straight down from the sky to the first thing
## it meets -- a roof, rubble, a floor whose roof is already gone -- and a brick
## there is worn by how much its material minds acid. PLA goes first; metal and
## stone not at all. Rain pools: most drops fall where earlier ones found a
## roof (PUDDLES), so a roof thins in places, then holes, and the rain gets in.
##
## Soldiers caught in the open are burnt a little and go under a roof
## (AIServices.storm, BTShelter). Wear, never blasts: through the world
## authority, as CHIPs, like everything else a disaster does to a brick.
##
## Deterministic: every drop's place comes from the rng on the physics tick.

const REACH := 55.0              ## m round the player the rain falls
const DROP_EVERY := 0.3          ## s
const DROPS := 5                 ## per round, at intensity 1
const HP := 60                   ## a PLA brick's wear per drop, at intensity 1
const RADIUS := 0.45
const PAWN_DAMAGE := 0.3         ## per round, to anyone with no roof: 1 a second, 40 over the storm
const PUDDLES := 24              ## places acid pools, at most
const POOL := 0.65               ## share of drops that fall in a puddle

## How much each material minds acid, by index (brick_grid.h BRICK_MATERIALS):
## PLA, PLA matte, PLA silk, ABS, PETG, TPU, Nylon, Glow PLA, Carbon PLA,
## Wood PLA, Wood, Metal, Stone, Leaf.
const SUSCEPTIBLE := [1.0, 1.0, 1.0, 0.7, 0.5, 0.4, 0.3, 1.0, 0.6, 0.6, 0.2, 0.0, 0.0, 0.8]

## For the probe.
var drops := 0
var worn := 0                    ## drops that wore a brick
var spared := 0                  ## drops on metal or stone
var burnt := 0                   ## pawn-rounds burnt in the open

var _next := 0.0
var _puddles: Array[Vector2] = []
var _sky := 0.0
var _sky_from := 0.0
var _rain: GPUParticles3D
var _hiss: AudioStreamPlayer

const SKY_SUN := Color(0.8, 0.86, 0.66)
const SKY_TOP := Color(0.34, 0.38, 0.3)
const SKY_HORIZON := Color(0.55, 0.6, 0.44)
const SKY_SUN_MUL := 0.6


func _init() -> void:
	title = "Acid rain"
	warning_s = 5.0
	active_s = 40.0
	ending_s = 5.0


func _on_begin() -> void:
	_build()


static func susceptibility(material: int) -> float:
	if material < 0:
		return 0.0
	if material >= SUSCEPTIBLE.size():
		return 0.8
	return SUSCEPTIBLE[material]


func _on_phase(p: Phase) -> void:
	match p:
		Phase.ACTIVE:
			ctx.set_storm(true)
			ctx.raining = true
		Phase.ENDING:
			_sky_from = _sky
		Phase.DONE:
			ctx.set_storm(false)
			ctx.raining = false
			ctx.gale = Vector3.ZERO
			_sky = 0.0
			_apply_sky()
			_rain.emitting = false
			_hiss.stop()


func _tick_warning(_dt: float) -> void:
	_sky = phase_t / warning_s
	_apply_sky()
	_rain.emitting = _sky > 0.5
	_rain.amount_ratio = maxf(0.0, _sky * 2.0 - 1.0)
	_loop(lerpf(-40.0, -12.0, _sky))


func _tick_active(dt: float) -> void:
	_sky = 1.0
	_apply_sky()
	_rain.amount_ratio = 1.0
	_next -= dt
	if _next <= 0.0:
		_next += DROP_EVERY
		_round()


func _tick_ending(_dt: float) -> void:
	_sky = _sky_from * (1.0 - phase_t / ending_s)
	_apply_sky()
	_rain.amount_ratio = _sky
	_loop(lerpf(-40.0, -12.0, _sky))


## One round of drops, and the burn to anyone out in it.
func _round() -> void:
	var player := ctx.player_pos()
	var n := maxi(1, int(round(DROPS * intensity)))
	for i in n:
		var a := rng.randf() * TAU
		var d := sqrt(rng.randf()) * REACH
		var p := Vector3(player.x + cos(a) * d, 0.0, player.z + sin(a) * d)
		var pool := -1
		if not _puddles.is_empty() and rng.randf() < POOL:
			pool = rng.randi() % _puddles.size()
			p = Vector3(_puddles[pool].x, 0.0, _puddles[pool].y)
		drops += 1
		var hit := ctx.ray(p + Vector3.UP * 150.0, p + Vector3.DOWN * 5.0)
		if hit.is_empty() or hit.has("building") or ctx.building_at(hit.position, 0.3) < 0:
			continue   # the street, rubble lying loose, a building out of reach
		var inside: Vector3 = (hit.position as Vector3) - (hit.normal as Vector3) * 0.1
		var k := susceptibility(ctx.material_at(inside))
		if k <= 0.0:
			spared += 1
			continue
		ctx.chip(hit.position, RADIUS, int(round(HP * k * intensity)))
		worn += 1
		if pool < 0:
			if _puddles.size() < PUDDLES:
				_puddles.append(Vector2(p.x, p.z))
			else:
				_puddles[rng.randi() % PUDDLES] = Vector2(p.x, p.z)
	var s: AIServices = ctx.city.ai_services
	for p in ctx.pawns():
		if s == null or not BTShelter.covered(s, p.feet()):
			if ctx.damage_pawns(p.chest(), 0.5, PAWN_DAMAGE * intensity) > 0:
				burnt += 1


func _process(_delta: float) -> void:
	if _rain != null:
		_rain.global_position = ctx.player_pos() + Vector3.UP * 14.0


func _apply_sky() -> void:
	ctx.set_sky(_sky, SKY_SUN, SKY_TOP, SKY_HORIZON, SKY_SUN_MUL)
	ctx.set_weather(_sky, 0.9, 1.3, intensity)
	ctx.gale = Vector3(-0.7, 0.0, 0.7) * 0.2 * _sky
	ctx.set_screen(_sky * 0.8, _sky * 0.12, Color(0.55, 0.65, 0.35), Color(0.72, 0.9, 0.5))


func _loop(db: float) -> void:
	_hiss.volume_db = db
	if not _hiss.playing:
		_hiss.play()


func _build() -> void:
	var drop_mat := StandardMaterial3D.new()
	drop_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	drop_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	drop_mat.billboard_mode = BaseMaterial3D.BILLBOARD_FIXED_Y
	drop_mat.billboard_keep_scale = true
	drop_mat.albedo_color = Color(0.7, 0.9, 0.45, 0.4)
	var drop := QuadMesh.new()
	drop.size = Vector2(0.03, 0.7)
	drop.material = drop_mat
	var proc := ParticleProcessMaterial.new()
	proc.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	proc.emission_box_extents = Vector3(28.0, 1.0, 28.0)
	proc.direction = Vector3(0.05, -1.0, 0.1)
	proc.spread = 2.0
	proc.initial_velocity_min = 20.0
	proc.initial_velocity_max = 26.0
	proc.gravity = Vector3.ZERO
	_rain = GPUParticles3D.new()
	_rain.amount = 4000
	_rain.lifetime = 1.2
	_rain.local_coords = false
	_rain.emitting = false
	_rain.amount_ratio = 0.0
	_rain.process_material = proc
	_rain.draw_pass_1 = drop
	_rain.visibility_aabb = AABB(Vector3(-40, -40, -40), Vector3(80, 60, 80))
	add_child(_rain)
	RainSplash.add(_rain, proc, self, Color(0.75, 0.95, 0.5, 0.85), "rain", ctx)
	_hiss = AudioStreamPlayer.new()
	_hiss.stream = DisasterSounds.rain()
	_hiss.volume_db = -40.0
	_hiss.pitch_scale = 1.25
	add_child(_hiss)
