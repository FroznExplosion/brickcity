class_name Hurricane
extends Disaster

## A hurricane (Docs/Disasters.md 18). Made for a coast: the heightfield world,
## whose sea it raises.
##
##   * THE SURGE. The sea rises SURGE_M x intensity at the storm's height and
##     goes back down after it -- low ground floods, a beach goes under, a
##     harbour wall is the shore now. Through the host's sea (ctx.set_sea):
##     BrickWave's own level, so what is drawn, what a swimmer floats in and
##     what the water collides with rise together.
##   * THE WAVES. Their gain is scaled up to WAVE_MUL x intensity over calm.
##   * THE WIND. Gusting, veering slowly, and it leans on whoever is out in
##     it: WIND_PUSH m/s of drift at full strength walking, some of it
##     swimming (DebugCamera.wind). Loose pieces are pushed along it where
##     there are any, and a standing building takes it as a sideways load
##     (BrickWorld.lateral_check), as it does from a tornado -- up to
##     MAX_PUSHED x intensity cut and blown over.
##   * RAIN, driven sideways by the wind, landing and splashing (RainSplash);
##     SURF -- spray bursting where the waves meet the shore, wherever the
##     surge has put the shore now; litter blown across the ground; lightning
##     in the cloud; the sky nearly dark.
##   * THE EYE. Halfway through, EYE_S of calm: the rain stops, the sky opens,
##     the wind drops -- and comes back from the other side.
##
## The strength curve: up over the first RISE share of ACTIVE, the eye in the
## middle, down to AFTER at the end of ACTIVE, and out through ENDING. The
## surge lags the wind by SURGE_LAG seconds, as a real one does, and is back
## to exactly zero at DONE.
##
## Deterministic: the wind's heading, its gusts and every lightning flash come
## from the rng on the physics tick.

const SURGE_M := 1.6              ## m of sea level at full strength, intensity 1
const WAVE_MUL := 1.4             ## extra wave gain at full strength, per intensity
const WIND_PUSH := 2.2            ## m/s of drift on a walker at full strength, intensity 1
const WIND_SPEED := 22.0          ## m/s the rain and spray are carried at
const PIECE_PUSH := 0.35          ## m/s added a tick to a loose piece, before its size
const WIND_G := 0.25              ## sideways load on a building at full strength, intensity 1
const MAX_PUSHED := 1             ## buildings blown over, per intensity
const RISE := 0.3
const EYE_AT := 0.5               ## share of ACTIVE where the eye passes
const EYE_S := 12.0
const AFTER := 0.55               ## strength left at the end of ACTIVE
const SURGE_LAG := 6.0            ## s: the sea follows the wind this slowly
const VEER := 0.5                 ## rad the heading wanders either way
const FLASH_MIN := 3.5
const FLASH_MAX := 9.0
const PUSH_EVERY := 1.0
const RANGE := 120.0
## Surf: the shore is looked for round the player every SURF_EVERY, out to
## SURF_REACH, and up to SURF_SPOTS of the nearest stretches spray.
const SURF_EVERY := 0.6
const SURF_REACH := 100.0
const SURF_SPOTS := 6
const SURF_BAND := 0.35           ## m of ground height either side of the sea that is shore

const SKY_SUN := Color(0.62, 0.66, 0.72)
const SKY_TOP := Color(0.2, 0.22, 0.26)
const SKY_HORIZON := Color(0.36, 0.39, 0.43)
const SKY_SUN_MUL := 0.3

## For the probe.
var strength := 0.0
var surge := 0.0
var wind := Vector3.ZERO
var peak_surge := 0.0
var flashes := 0
var eye_seen := false
var pushed_buildings: Array[int] = []
## The tops it cut, being helped over: {box (from the cut up), dir, t, piece}.
var _tipping: Array[Dictionary] = []
var peak_tilt := 0.0              ## degrees, the most a cut top has leaned
var pieces_pushed := 0
var surf_spots := 0               ## shore stretches spraying, the last look
var peak_surf := 0

var _heading := 0.0
var _gust_phase := Vector3.ZERO
var _veer_phase := 0.0
var _next_flash := 0.0
var _flash := 0.0
var _thunder_in := -1.0
var _next_push := 0.0
var _has_sea := false
var _rain: GPUParticles3D
var _rain_proc: ParticleProcessMaterial
var _litter: GPUParticles3D
var _litter_proc: ParticleProcessMaterial
var _wind_sound: AudioStreamPlayer
var _rain_sound: AudioStreamPlayer
var _thunder: AudioStreamPlayer
var _surf: Array[GPUParticles3D] = []
var _surf_proc: ParticleProcessMaterial
var _next_surf := 0.0


func _init() -> void:
	title = "Hurricane"
	warning_s = 10.0
	active_s = 80.0
	ending_s = 20.0


func _on_begin() -> void:
	_heading = rng.randf() * TAU
	_gust_phase = Vector3(rng.randf() * TAU, rng.randf() * TAU, rng.randf() * TAU)
	_veer_phase = rng.randf() * TAU
	_next_flash = rng.randf_range(FLASH_MIN, FLASH_MAX)
	_build()


func _on_phase(p: Phase) -> void:
	match p:
		Phase.ACTIVE:
			ctx.set_storm(true)
			ctx.raining = true
		Phase.DONE:
			strength = 0.0
			surge = 0.0
			wind = Vector3.ZERO
			ctx.set_sea(0.0, 1.0)
			ctx.set_wind(Vector3.ZERO)
			ctx.gale = Vector3.ZERO
			ctx.set_storm(false)
			ctx.raining = false
			ctx.set_sky(0.0, SKY_SUN, SKY_TOP, SKY_HORIZON, SKY_SUN_MUL)
			ctx.set_weather(0.0, 1.0, 1.0)
			ctx.set_screen(0.0, 0.0)
			_rain.emitting = false
			_litter.emitting = false
			for e in _surf:
				e.emitting = false
			_wind_sound.stop()
			_rain_sound.stop()


# --- The curve -------------------------------------------------------------------

## Strength 0..1 for where the storm is: ramps up, the eye, winds down.
## `calm_eye` false gives the storm's envelope without the eye's lull -- what
## the sea follows: a surge does not drain away in the hour the eye takes.
func _strength_now(calm_eye := true) -> float:
	match phase:
		Phase.WARNING:
			return 0.25 * phase_t / warning_s
		Phase.ACTIVE:
			var u := phase_t / active_s
			var s := 0.25 + 0.75 * minf(1.0, u / RISE)
			if u > EYE_AT:
				s = lerpf(1.0, AFTER, (u - EYE_AT) / (1.0 - EYE_AT))
			# The eye: calm, a few seconds each side to get in and out of it.
			var eye := absf(phase_t - active_s * EYE_AT) - EYE_S * 0.5
			if calm_eye and eye < 3.0:
				s *= lerpf(0.08, 1.0, clampf(eye / 3.0, 0.0, 1.0))
			return s
		Phase.ENDING:
			return AFTER * (1.0 - phase_t / ending_s)
	return 0.0


func in_eye() -> bool:
	return phase == Phase.ACTIVE and absf(phase_t - active_s * EYE_AT) < EYE_S * 0.5


func _tick_warning(dt: float) -> void:
	_step(dt)


func _tick_active(dt: float) -> void:
	_step(dt)
	eye_seen = eye_seen or in_eye()
	_lightning(dt)
	_next_push -= dt
	if _next_push <= 0.0:
		_next_push += PUSH_EVERY
		_push_buildings()
	_tip_tops()


func _tick_ending(dt: float) -> void:
	_step(dt)


func _step(dt: float) -> void:
	strength = _strength_now()
	var k := strength * intensity
	# The wind: its heading veers slowly, and turns round once the eye has
	# passed; gusts ride on it.
	var t := _time()
	var heading := _heading + VEER * sin(t * 0.05 + _veer_phase)
	if phase == Phase.ENDING or (phase == Phase.ACTIVE and phase_t > active_s * EYE_AT):
		heading += PI
	var gust := 0.75 + 0.15 * sin(t * 0.9 + _gust_phase.x) + 0.1 * sin(t * 2.3 + _gust_phase.y) \
			+ 0.08 * sin(t * 5.1 + _gust_phase.z)
	var dir := Vector3(cos(heading), 0.0, sin(heading))
	wind = dir * WIND_PUSH * k * gust
	ctx.set_wind(wind)
	# Trees and buildings sway in it (weather.gdshaderinc).
	ctx.gale = dir * minf(1.5, k * gust)
	# The surge follows, slowly: the sea does not jump with a gust.
	if phase == Phase.ENDING:
		# Down in a straight line to exactly nothing at DONE, from wherever it got.
		surge -= surge * minf(1.0, dt / maxf(ending_s - phase_t + dt, dt))
	else:
		var target := SURGE_M * intensity * _strength_now(false)
		surge = move_toward(surge, target, absf(target - surge) * dt / SURGE_LAG + 0.02 * dt)
	peak_surge = maxf(peak_surge, surge)
	_has_sea = ctx.set_sea(surge, 1.0 + WAVE_MUL * intensity * strength)
	# Weather: the AI sees less and aims badly; the lens streams.
	var dark := clampf(strength * 1.6, 0.0, 1.0)
	ctx.set_sky(dark, SKY_SUN, SKY_TOP, SKY_HORIZON, SKY_SUN_MUL, _flash)
	ctx.set_weather(strength, 0.75, 2.2, intensity)
	ctx.set_screen(clampf(strength * 1.3, 0.0, 1.0), strength * 0.25, Color(0.55, 0.6, 0.66))
	ctx.shake(ctx.player_pos(), 0.004 * k * gust)
	_push_pieces(dir, k * gust)
	_surf_step(dt)
	_flash = maxf(0.0, _flash - dt * 6.0)
	if _thunder_in >= 0.0:
		_thunder_in -= dt
		if _thunder_in < 0.0:
			_thunder.play()
	_sound(strength, gust)


## Where the sea meets the ground near the player, spray goes up -- more of it
## the stronger the storm. The shore is wherever the ground is within
## SURF_BAND of the sea as it is NOW, so it walks inland with the surge.
func _surf_step(dt: float) -> void:
	_next_surf -= dt
	if _next_surf > 0.0:
		return
	_next_surf = SURF_EVERY
	var spots: Array[Vector3] = []
	if _has_sea and strength > 0.2:
		var sea := BrickWave.get_sea_level()
		var stud := BrickWorld.get_stud_metres()
		var plate := BrickWorld.get_plate_metres()
		var at := ctx.player_pos()
		var best := {}
		# Rings outward, nearest first; one spot per direction at most.
		for ring in range(1, 21):
			var r := SURF_REACH * float(ring) / 20.0
			for k in 24:
				if best.has(k):
					continue
				var a := TAU * float(k) / 24.0
				var x := at.x + cos(a) * r
				var z := at.z + sin(a) * r
				var ground := float(BrickTerrain.surface_plate(floori(x / stud), floori(z / stud)) + 1) * plate
				if absf(ground - sea) <= SURF_BAND:
					best[k] = Vector3(x, sea, z)
		for k in best:
			spots.append(best[k])
		spots.sort_custom(func(p: Vector3, q: Vector3) -> bool:
			return p.distance_squared_to(at) < q.distance_squared_to(at))
	surf_spots = mini(spots.size(), SURF_SPOTS)
	peak_surf = maxi(peak_surf, surf_spots)
	var carry := wind.normalized() * 6.0 * strength if wind.length() > 0.01 else Vector3.ZERO
	_surf_proc.gravity = Vector3(carry.x, -6.0, carry.z)
	for i in _surf.size():
		var e := _surf[i]
		if i < surf_spots:
			e.global_position = spots[i]
			e.amount_ratio = clampf(strength * intensity, 0.2, 1.0)
			e.emitting = true
		else:
			e.emitting = false


## Seconds since it began, on the physics tick.
func _time() -> float:
	match phase:
		Phase.WARNING:
			return phase_t
		Phase.ACTIVE:
			return warning_s + phase_t
		_:
			return warning_s + active_s + phase_t


func _lightning(dt: float) -> void:
	_next_flash -= dt
	if _next_flash > 0.0:
		return
	_next_flash = rng.randf_range(FLASH_MIN, FLASH_MAX)
	if strength < 0.4:
		return
	flashes += 1
	_flash = rng.randf_range(0.8, 1.8)
	_thunder_in = rng.randf_range(0.6, 3.0)
	_thunder.volume_db = rng.randf_range(-12.0, -3.0)


## Loose pieces go with the wind -- the small ones most.
func _push_pieces(dir: Vector3, k: float) -> void:
	if ctx.islands == null or k < 0.05 or Engine.get_physics_frames() % 3 != 0:
		return
	var player := ctx.player_pos()
	# Small pieces broken off in it stay bodies, for this to blow about:
	# anywhere else they only fall and shrink away (IslandManager._crumble).
	ctx.islands.windy(get_instance_id(), player, RANGE, 500)
	for isl in ctx.islands_near(player, RANGE):
		if not is_instance_valid(isl.body) or isl.settled:
			continue
		var bricks := ctx.piece_bricks(isl)
		if bricks <= 0:
			continue
		isl.body.linear_velocity += dir * PIECE_PUSH * k * clampf(40.0 / float(bricks), 0.05, 1.0)
		pieces_pushed += 1


## A standing building takes the wind as a sideways load; one that gives is cut
## and blown over (the tornado's way, Docs/Disasters.md 17).
func _push_buildings() -> void:
	if ctx.registry == null or wind.length() < 0.1:
		return
	if pushed_buildings.size() >= maxi(1, int(round(MAX_PUSHED * intensity))):
		return
	var dir := wind.normalized()
	var axis := Vector3(signf(dir.x), 0.0, 0.0) if absf(dir.x) >= absf(dir.z) \
			else Vector3(0.0, 0.0, signf(dir.z))
	var player := ctx.player_pos()
	for pair in ctx.buildings():
		var id: int = pair[0]
		var box: AABB = pair[1]
		var c := box.get_center()
		if pushed_buildings.has(id) or Vector2(c.x - player.x, c.z - player.z).length() > RANGE:
			continue
		var r := ctx.lateral(id, WIND_G * intensity * strength, axis)
		if r.is_empty() or float(r.ratio) < 1.0 or not r.has("level"):
			continue
		var level: Vector3 = r.level
		if ctx.sever(id, level):
			pushed_buildings.append(id)
			_tipping.append({"id": id, "dir": axis, "t": _time(), "piece": null,
					"box": AABB(Vector3(box.position.x, level.y, box.position.z),
							Vector3(box.size.x, box.end.y - level.y, box.size.z))})
			return


## Help each cut top over its downwind edge for Earthquake.PUSH_S, as the
## tornado does.
func _tip_tops() -> void:
	for p in _tipping:
		var box: AABB = p.box
		if p.piece == null:
			var most := Earthquake.TOP_MIN_BRICKS - 1
			for isl in ctx.islands_near(box.get_center(), box.size.length()):
				# Its own top: old rubble lying near is not it.
				if (isl.is_valid() and is_instance_valid(isl.body) and isl.owner == int(p.id)
						and ctx.piece_bricks(isl) > most):
					most = ctx.piece_bricks(isl)
					p.piece = isl
		var isl: BrickIsland = p.piece
		if isl == null or not isl.is_valid() or not is_instance_valid(isl.body):
			continue
		peak_tilt = maxf(peak_tilt, rad_to_deg(acos(clampf(isl.body.global_basis.y.dot(Vector3.UP), -1.0, 1.0))))
		if _time() - float(p.t) <= Earthquake.PUSH_S:
			Earthquake.tip(isl, p.dir, box, intensity)


# --- Look and sound ----------------------------------------------------------------

func _process(_delta: float) -> void:
	if phase == Phase.DONE or _rain == null:
		return
	var at := ctx.player_pos()
	_rain.global_position = at + Vector3.UP * 12.0 - wind.normalized() * 6.0
	_litter.global_position = at
	var k := strength
	var carry := wind.normalized() * WIND_SPEED * minf(1.0, k * 1.5) if wind.length() > 0.01 else Vector3.ZERO
	# Driven: it falls along the wind, not straight down with a drift.
	_rain_proc.direction = Vector3(carry.x, -20.0, carry.z).normalized()
	_rain_proc.gravity = Vector3(carry.x * 0.5, -10.0, carry.z * 0.5)
	_rain.emitting = k > 0.12
	_rain.amount_ratio = clampf(k * 1.4, 0.0, 1.0)
	_litter_proc.gravity = Vector3(carry.x * 1.4, -1.0, carry.z * 1.4)
	_litter.emitting = k > 0.3
	_litter.amount_ratio = clampf((k - 0.3) * 1.6, 0.0, 1.0)


func _sound(k: float, gust: float) -> void:
	_wind_sound.volume_db = lerpf(-40.0, 0.0, clampf(k * gust, 0.0, 1.0))
	_wind_sound.pitch_scale = 0.85 + 0.3 * clampf(k * gust, 0.0, 1.0)
	if not _wind_sound.playing:
		_wind_sound.play()
	_rain_sound.volume_db = lerpf(-40.0, -4.0, clampf(k * 1.3, 0.0, 1.0))
	if not _rain_sound.playing:
		_rain_sound.play()


func _build() -> void:
	var drop_mat := StandardMaterial3D.new()
	drop_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	drop_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	drop_mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	drop_mat.albedo_color = Color(0.75, 0.8, 0.88, 0.35)
	var drop := QuadMesh.new()
	drop.size = Vector2(0.03, 0.8)
	drop.material = drop_mat
	_rain_proc = ParticleProcessMaterial.new()
	_rain_proc.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	_rain_proc.emission_box_extents = Vector3(30.0, 2.0, 30.0)
	_rain_proc.direction = Vector3.DOWN
	_rain_proc.spread = 4.0
	_rain_proc.initial_velocity_min = 22.0
	_rain_proc.initial_velocity_max = 28.0
	_rain_proc.particle_flag_align_y = true
	_rain = GPUParticles3D.new()
	_rain.amount = 7000
	_rain.lifetime = 1.1
	_rain.local_coords = false
	_rain.emitting = false
	_rain.amount_ratio = 0.0
	_rain.process_material = _rain_proc
	_rain.draw_pass_1 = drop
	_rain.visibility_aabb = AABB(Vector3(-50, -40, -50), Vector3(100, 60, 100))
	add_child(_rain)
	RainSplash.add(_rain, _rain_proc, self)

	# Litter and spray: bits of brick, leaf and foam going past low down.
	var bit_mat := StandardMaterial3D.new()
	bit_mat.vertex_color_use_as_albedo = true
	bit_mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	bit_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var bit := QuadMesh.new()
	bit.size = Vector2(0.12, 0.08)
	bit.material = bit_mat
	_litter_proc = ParticleProcessMaterial.new()
	_litter_proc.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	_litter_proc.emission_box_extents = Vector3(25.0, 4.0, 25.0)
	_litter_proc.direction = Vector3.UP
	_litter_proc.spread = 60.0
	_litter_proc.initial_velocity_min = 0.5
	_litter_proc.initial_velocity_max = 3.0
	_litter_proc.angular_velocity_min = -400.0
	_litter_proc.angular_velocity_max = 400.0
	_litter_proc.scale_min = 0.5
	_litter_proc.scale_max = 1.6
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.5, 1.0])
	g.colors = PackedColorArray([Color(0.9, 0.93, 0.95, 0.0), Color(0.45, 0.5, 0.35, 0.9),
			Color(0.6, 0.45, 0.3, 0.0)])
	var ramp := GradientTexture1D.new()
	ramp.gradient = g
	_litter_proc.color_ramp = ramp
	_litter = GPUParticles3D.new()
	_litter.amount = 400
	_litter.lifetime = 2.5
	_litter.local_coords = false
	_litter.emitting = false
	_litter.process_material = _litter_proc
	_litter.draw_pass_1 = bit
	_litter.visibility_aabb = AABB(Vector3(-60, -10, -60), Vector3(120, 30, 120))
	add_child(_litter)

	# Surf: white spray thrown up where waves break, blown downwind.
	var foam_mat := StandardMaterial3D.new()
	foam_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	foam_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	foam_mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	foam_mat.vertex_color_use_as_albedo = true
	var puff := GradientTexture2D.new()
	puff.fill = GradientTexture2D.FILL_RADIAL
	puff.fill_from = Vector2(0.5, 0.5)
	puff.fill_to = Vector2(1.0, 0.5)
	var pg := Gradient.new()
	pg.colors = PackedColorArray([Color(1, 1, 1, 1), Color(1, 1, 1, 0)])
	puff.gradient = pg
	foam_mat.albedo_texture = puff
	var foam := QuadMesh.new()
	foam.size = Vector2(1.8, 1.8)
	foam.material = foam_mat
	_surf_proc = ParticleProcessMaterial.new()
	_surf_proc.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	_surf_proc.emission_box_extents = Vector3(6.0, 0.2, 6.0)
	_surf_proc.direction = Vector3.UP
	_surf_proc.spread = 35.0
	_surf_proc.initial_velocity_min = 3.0
	_surf_proc.initial_velocity_max = 7.0
	_surf_proc.scale_min = 0.5
	_surf_proc.scale_max = 1.8
	var fg := Gradient.new()
	fg.offsets = PackedFloat32Array([0.0, 0.3, 1.0])
	fg.colors = PackedColorArray([Color(1, 1, 1, 0.0), Color(0.95, 0.97, 1.0, 0.75),
			Color(0.9, 0.93, 0.96, 0.0)])
	var framp := GradientTexture1D.new()
	framp.gradient = fg
	_surf_proc.color_ramp = framp
	for i in SURF_SPOTS:
		var e := GPUParticles3D.new()
		e.amount = 140
		e.lifetime = 1.4
		e.local_coords = false
		e.emitting = false
		e.process_material = _surf_proc
		e.draw_pass_1 = foam
		e.visibility_aabb = AABB(Vector3(-15, -5, -15), Vector3(30, 20, 30))
		add_child(e)
		_surf.append(e)

	_wind_sound = AudioStreamPlayer.new()
	_wind_sound.stream = DisasterSounds.wind()
	_wind_sound.volume_db = -40.0
	add_child(_wind_sound)
	_rain_sound = AudioStreamPlayer.new()
	_rain_sound.stream = DisasterSounds.rain()
	_rain_sound.volume_db = -40.0
	add_child(_rain_sound)
	_thunder = AudioStreamPlayer.new()
	_thunder.stream = DisasterSounds.thunder()
	add_child(_thunder)
