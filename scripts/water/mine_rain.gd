class_name MineRain
extends Node3D
## RAIN IN THE MINE WORLD (R10, Docs/MineWaterNext.md 8): weather as storms
## that are born, drift and die -- not a switch over the whole world.
##
##   * BORN where the air is wet: every BIRTH_EVERY seconds a point some way
##     out (upwind mostly) is tried, and the biome there (BrickTerrain.biome_at,
##     its climate `humid` in the generator's table) sets the odds: a jungle
##     or a dark forest often, plains now and then, a desert or badlands
##     almost never (BIRTH_DRY). The sea, beaches and rivers count as wet.
##   * DRIFT with the wind (a direction turning slowly), over any biome.
##   * DIE: each storm has a life; over dry ground it is used up faster
##     (DRY_BURN times in a desert), so a storm that wanders into a desert
##     rains there a little and is gone -- desert rain is rare, not never.
##
## Where one covers the player it is drawn (falling drops and splashes,
## RainSplash; the ground darkens wet, WeatherFx) and it RAINS WATER: drops
## of still water on the open ground (BrickFluid.rain), which pool in hollows
## and dry on flat ground like any poured water. Storms are weather, not
## state: a save does not keep them (the puddles are the water's).

const BIRTH_EVERY := 15.0          ## s between tries
const BIRTH_ODDS := 0.35           ## a try's odds where it is wettest
const BIRTH_DRY := 0.03            ## ...and where it is driest
const MAX_STORMS := 3
const BIRTH_NEAR := 120.0          ## m from the player a storm is born, at least
const BIRTH_FAR := 700.0
const GONE_PAST := 1600.0          ## m: a storm this far is dropped
const DRY_BURN := 4.0              ## a storm's life used up this much faster over a desert
const WIND_MS := 3.0               ## m/s the storms drift
## Rain on the ground: tiles a column a second at full strength (one every
## four minutes). The water's own rules do the rest (pooling, drying).
const DROPS_PER_COLUMN_S := 1.0 / 240.0
const DROP_EVERY := 0.5
const STUD_M := 0.35

## Set (0..1) to rain here at that strength whatever the storms say; -1 off.
## The gate's and the probes' handle. Static: a test sets it before the world.
static var forced := -1.0

var host: Node3D = null
var storms: Array[Dictionary] = []
var wind := Vector2(1.0, 0.3).normalized()
## Rain at the player now (0..1), eased; what is drawn.
var here := 0.0
var wet := 0.0
## Open sky over the player (0..1): rain is not drawn in a cave.
var sky := 1.0

var _humid: PackedFloat32Array = PackedFloat32Array()
var _rng := RandomNumberGenerator.new()
var _birth_in := 5.0
var _drop_in := 0.0
var _sky_in := 0.0
var _burn_in := 0.0
var _rain: GPUParticles3D = null
var _splash: RainSplash = null
var _hiss: AudioStreamPlayer = null


func setup(p_host: Node3D) -> void:
	host = p_host
	_rng.randomize()
	# Scripted passes keep their pictures: no weather of its own (forced and
	# add_storm still work).
	if bool(host.get("_gate")):
		_birth_in = INF
	_build()
	set_process(true)


## A new world: no storms, its biomes' climate read again.
func reset_world() -> void:
	storms.clear()
	here = 0.0
	wet = 0.0
	if not is_inf(_birth_in):
		_birth_in = 5.0
	_humid = PackedFloat32Array()
	var gp: Dictionary = BrickTerrain.get_gen_params()
	for b in gp.get("biomes", []):
		var d: Dictionary = b
		_humid.append(_kind_humid(int(d.get("kind", 0)), float(d.get("humid", 0.0))))


## The generator's non-climate kinds (terrain_biomes.h BiomeKind): the sea,
## its coasts and the rivers are where storms come from; peaks are dry-ish.
static func _kind_humid(kind: int, humid: float) -> float:
	match kind:
		0: return humid           # chosen by climate
		1: return 0.5             # ocean
		2, 3: return 0.3          # beach, stony shore
		4: return 0.4             # river
		8: return 0.1             # snowy beach
		_: return 0.0             # hills, peaks


## Climate humidity at (x, z) metres in the water's frame, -1..1.
func humid_at(p: Vector2) -> float:
	if _humid.is_empty():
		return 0.0
	var b := BrickTerrain.biome_at(int(floor(p.x / STUD_M)), int(floor(p.y / STUD_M)))
	return _humid[b] if b >= 0 and b < _humid.size() else 0.0


## How readily rain is born at humidity `h`: BIRTH_DRY in a desert, 1 in a
## jungle.
static func birth_weight(h: float) -> float:
	return lerpf(BIRTH_DRY, 1.0, smoothstep(-0.55, 0.55, h))


## How fast a storm's life goes over humidity `h`: DRY_BURN times over a
## desert, slower than its clock over a jungle.
static func burn_rate(h: float) -> float:
	return lerpf(DRY_BURN, 0.6, smoothstep(-0.6, 0.3, h))


## A storm's strength now: up over its first 15 %, down over its last 25 %.
static func strength(s: Dictionary) -> float:
	var k: float = clampf(float(s.age) / float(s.life), 0.0, 1.0)
	return float(s.peak) * minf(smoothstep(0.0, 0.15, k), 1.0 - smoothstep(0.75, 1.0, k))


## Its rain at `p`, 0..1: full inside, fading over its outer quarter.
static func rain_at(s: Dictionary, p: Vector2) -> float:
	var d: float = (s.pos as Vector2).distance_to(p)
	return strength(s) * (1.0 - smoothstep(float(s.r) * 0.75, float(s.r), d))


## A storm at `p` (tests, the gate): radius m, strength 0..1, life s.
func add_storm(p: Vector2, r := 150.0, peak := 1.0, life := 300.0, age := -1.0) -> Dictionary:
	var s := {"pos": p, "r": r, "peak": peak, "life": life,
		"age": life * 0.3 if age < 0.0 else age, "humid": humid_at(p)}
	storms.append(s)
	return s


func _eye2() -> Vector2:
	var e: Vector3 = host._eye()
	return Vector2(e.x, e.z)


func _process(delta: float) -> void:
	if host == null:
		return
	step(delta)
	_draw(delta)


## The weather's clock: births, drift, deaths, rain on the ground.
func step(delta: float) -> void:
	var eye := _eye2()
	# The wind turns slowly (a full turn in about an hour).
	wind = wind.rotated(_rng.randf_range(-1.0, 1.0) * 0.02 * delta)
	_birth_in -= delta
	if _birth_in <= 0.0:
		_birth_in = BIRTH_EVERY
		_try_birth(eye)
	_burn_in -= delta
	var look := _burn_in <= 0.0
	if look:
		_burn_in = 2.0
	for i in range(storms.size() - 1, -1, -1):
		var s := storms[i]
		s.pos = (s.pos as Vector2) + wind * WIND_MS * delta
		if look:
			s.humid = humid_at(s.pos)
		s.age = float(s.age) + delta * burn_rate(float(s.humid))
		if float(s.age) >= float(s.life) or (s.pos as Vector2).distance_to(eye) > GONE_PAST:
			storms.remove_at(i)
	_drop_in -= delta
	if _drop_in <= 0.0:
		_drop_in += DROP_EVERY
		_rain_water(eye)


func _try_birth(eye: Vector2) -> void:
	if storms.size() >= MAX_STORMS:
		return
	# Upwind mostly: the weather comes to the player.
	var a := wind.angle() + PI + _rng.randf_range(-1.2, 1.2) if _rng.randf() < 0.7 else _rng.randf() * TAU
	var p := eye + Vector2.from_angle(a) * _rng.randf_range(BIRTH_NEAR, BIRTH_FAR)
	var h := humid_at(p)
	if _rng.randf() >= BIRTH_ODDS * birth_weight(h):
		return
	# Wet ground makes the bigger, stronger, longer storms.
	var wetness := smoothstep(-0.6, 0.7, h)
	storms.append({"pos": p, "r": _rng.randf_range(70.0, 140.0) + 90.0 * wetness,
		"peak": _rng.randf_range(0.35, 0.7) + 0.3 * wetness, "life": _rng.randf_range(150.0, 300.0) + 240.0 * wetness,
		"age": 0.0, "humid": h})


## Each storm near enough rains its drops (only the sim radius gets them).
func _rain_water(eye: Vector2) -> void:
	if forced >= 0.0:
		if forced > 0.0:
			var r := 60.0
			BrickFluid.rain(Vector3(eye.x, 0.0, eye.y), r, _drops(r, forced))
		return
	for s in storms:
		var st := strength(s)
		if st <= 0.01:
			continue
		var r: float = s.r
		if (s.pos as Vector2).distance_to(eye) > r + 120.0:
			continue
		BrickFluid.rain(Vector3((s.pos as Vector2).x, 0.0, (s.pos as Vector2).y), r, _drops(r, st))


static func _drops(r_m: float, st: float) -> float:
	var r_st := r_m / STUD_M
	return PI * r_st * r_st * DROPS_PER_COLUMN_S * st * DROP_EVERY


## Rain at the player, 0..1, before easing.
func rain_here() -> float:
	if forced >= 0.0:
		return forced
	var eye := _eye2()
	var best := 0.0
	for s in storms:
		best = maxf(best, rain_at(s, eye))
	return best


func _draw(delta: float) -> void:
	_sky_in -= delta
	if _sky_in <= 0.0:
		_sky_in = 0.5
		var e: Vector3 = host._eye()
		sky = clampf(BrickTerrain.sky_light_at(e) / 15.0, 0.0, 1.0) if BrickTerrain.get_sky_light() else 1.0
	here = move_toward(here, rain_here(), delta * 0.15)
	# Wet comes with the rain and goes over a minute after it.
	wet = move_toward(wet, here, delta * 0.2 if here > wet else delta / 60.0)
	var shown := here * sky
	var e3: Vector3 = host._eye()
	_rain.position = e3 + Vector3.UP * 14.0
	_rain.emitting = shown > 0.02
	_rain.amount_ratio = shown
	_hiss.volume_db = linear_to_db(maxf(shown, 0.0001)) - 8.0
	if shown > 0.02 and not _hiss.playing:
		_hiss.play()
	elif shown <= 0.02 and _hiss.playing:
		_hiss.stop()
	WeatherFx.set_weather(wet, Vector3(wind.x, 0.0, wind.y) * 0.25 * here, shown)


func _exit_tree() -> void:
	WeatherFx.clear()


func _build() -> void:
	var drop_mat := StandardMaterial3D.new()
	drop_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	drop_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	drop_mat.billboard_mode = BaseMaterial3D.BILLBOARD_FIXED_Y
	drop_mat.billboard_keep_scale = true
	drop_mat.albedo_color = Color(0.75, 0.82, 0.95, 0.35)
	var drop := QuadMesh.new()
	drop.size = Vector2(0.025, 0.6)
	drop.material = drop_mat
	var proc := ParticleProcessMaterial.new()
	proc.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	proc.emission_box_extents = Vector3(28.0, 1.0, 28.0)
	proc.direction = Vector3(0.05, -1.0, 0.05)
	proc.spread = 2.0
	proc.initial_velocity_min = 18.0
	proc.initial_velocity_max = 24.0
	proc.gravity = Vector3.ZERO
	_rain = GPUParticles3D.new()
	_rain.name = "Rain"
	_rain.amount = 5000
	_rain.lifetime = 1.3
	_rain.local_coords = false
	_rain.emitting = false
	_rain.amount_ratio = 0.0
	_rain.process_material = proc
	_rain.draw_pass_1 = drop
	_rain.visibility_aabb = AABB(Vector3(-40, -40, -40), Vector3(80, 60, 80))
	add_child(_rain)
	_splash = RainSplash.add(_rain, proc, self, Color(0.85, 0.9, 1.0, 0.8))
	_hiss = AudioStreamPlayer.new()
	_hiss.name = "Hiss"
	_hiss.stream = DisasterSounds.rain()
	_hiss.volume_db = -40.0
	add_child(_hiss)


func report() -> String:
	return "rain %.2f (sky %.2f) storms %d, %d drops landed, %d soaked in" % [here, sky, storms.size(),
			BrickFluid.rain_landed(), BrickFluid.rain_soaked()]
