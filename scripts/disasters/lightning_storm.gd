class_name LightningStorm
extends Disaster

## A lightning storm (Docs/Disasters.md section 3): the sky darkens, rain comes
## in on the wind, and for 45 s strokes land every 1.5-4 s -- most of them on
## the tallest building near where they were rolled, because lightning goes for
## the highest thing.
##
## A stroke is a small blast (a bite out of a roof edge, not a crater) through
## the world authority, a shock to anyone within 3 m, and a 35% chance to start
## a fire. Thunder arrives late by distance at 343 m/s.
##
## Deterministic like the shower: every stroke's time and the random numbers it
## will place itself with are rolled in begin(); the target is resolved from
## them, 0.6 s before the stroke, when its leader starts to flicker.

const LEADER_S := 0.6
const STRIKE_RADIUS := 0.8
const SCORCH_RIM := 0.7         ## m of blackened brick round a stroke's hole
const TALL_SHARE := 0.7
const TALL_SEARCH := 40.0       ## m around the rolled point to look for the tallest
const ROLL_RANGE := 60.0        ## m from the player a stroke is rolled
const GROUND_MIN := 10.0
const SHOCK_RADIUS := 3.0
const SHOCK_DAMAGE := 60.0
const IGNITE_CHANCE := 0.35
const SOUND_SPEED := 343.0
const BOLT_WIDTH := 0.45
const DUCK_RADIUS := 12.0
## Soldiers told to get low, for the probe.
var ducked := 0

const SKY_SUN := Color(0.62, 0.66, 0.76)
const SKY_TOP := Color(0.2, 0.22, 0.26)
const SKY_HORIZON := Color(0.36, 0.38, 0.42)
const SKY_SUN_MUL := 0.35

## On/off pattern of one stroke, in seconds: three flashes, the last longest.
const FLICKER := [0.06, 0.05, 0.05, 0.04, 0.1]

## Each: {t, tall, ignite, u, v, w, stage, target, building, hit, thunder_at}.
var strikes: Array[Dictionary] = []
## What landed: {pos, building (id or -1), aimed (the tallest's id or -1),
## player_dist, thunder_delay, hurt}.
var landed: Array[Dictionary] = []

var _clock := 0.0
var _sky := 0.0
var _sky_from := 0.0
var _flash := 0.0

var _bolt: MeshInstance3D
var _bolt_mesh: ImmediateMesh
var _bolt_t := -1.0             ## seconds into the flicker, -1 when dark
## Captures only: keep each stroke lit for a second, so a screenshot can find it.
var hold_bolt := false
var _bolt_pts: Array = []       ## Array of PackedVector3Array polylines
var _leader: OmniLight3D
var _leader_until := -1.0
var _strike_light: OmniLight3D
var _thunders: Array = []       ## [clock time, position]
var _thunder_players: Array[AudioStreamPlayer3D] = []
var _thunder_i := 0
var _rain: GPUParticles3D
var _wind: AudioStreamPlayer
var _rain_sound: AudioStreamPlayer


func _init() -> void:
	title = "Lightning storm"
	warning_s = 6.0
	active_s = 45.0
	ending_s = 6.0


func _on_begin() -> void:
	var t := rng.randf_range(0.5, 2.0)
	while t < active_s - 0.5:
		strikes.append({
			"t": t,
			"tall": rng.randf() < TALL_SHARE,
			"ignite": rng.randf() < minf(IGNITE_CHANCE * intensity, 0.9),
			"u": rng.randf(), "v": rng.randf(), "w": rng.randf(),
			"stage": 0,
		})
		# Intensity: strokes come faster.
		t += rng.randf_range(1.5, 4.0) / maxf(intensity, 0.25)
	_build()


func _on_phase(p: Phase) -> void:
	match p:
		Phase.WARNING:
			ctx.raining = false
		Phase.ACTIVE:
			ctx.raining = true
			ctx.set_storm(true)
		Phase.ENDING:
			_sky_from = _sky
		Phase.DONE:
			ctx.raining = false
			ctx.gale = Vector3.ZERO
			ctx.set_storm(false)
			ctx.clear_hazard(0)
			_sky = 0.0
			_flash = 0.0
			_apply_sky()
			_wind.stop()
			_rain_sound.stop()
			_rain.emitting = false


func _tick_warning(_dt: float) -> void:
	var k := phase_t / warning_s
	_sky = k
	_rain.amount_ratio = maxf(0.0, k * 2.0 - 1.0)
	_rain.emitting = k > 0.5
	# Rain from halfway through the warning: fire already feels it.
	ctx.raining = k > 0.5
	_loop(_wind, lerpf(-40.0, -10.0, k))
	_loop(_rain_sound, lerpf(-40.0, -14.0, maxf(0.0, k * 2.0 - 1.0)))


func _tick_active(dt: float) -> void:
	_sky = 1.0
	_rain.amount_ratio = 1.0
	_clock += dt
	_step_strikes(true)


func _tick_ending(dt: float) -> void:
	var k := 1.0 - phase_t / ending_s
	_sky = _sky_from * k
	_rain.amount_ratio = k
	ctx.raining = k > 0.3
	_loop(_wind, lerpf(-40.0, -10.0, k))
	_loop(_rain_sound, lerpf(-40.0, -14.0, k))
	_clock += dt
	_step_strikes(false)


# --- Strokes ------------------------------------------------------------------

func _step_strikes(new: bool) -> void:
	for s in strikes:
		match int(s.stage):
			0:
				if not new:
					s.stage = 3
				elif _clock >= float(s.t) - LEADER_S:
					_aim(s)
			1:
				if _clock >= float(s.t):
					_strike(s)
	while not _thunders.is_empty() and _clock >= float(_thunders[0][0]):
		var th: Array = _thunders.pop_front()
		var pl := _thunder_players[_thunder_i]
		_thunder_i = (_thunder_i + 1) % _thunder_players.size()
		pl.global_position = th[1]
		pl.pitch_scale = randf_range(0.85, 1.1)
		pl.play()


## Where it will land, from the numbers rolled for it, and the leader's flicker.
func _aim(s: Dictionary) -> void:
	var player := ctx.player_pos()
	var ang := float(s.u) * TAU
	var target = null
	s.aimed = -1
	if s.tall:
		var around := player + Vector3(cos(ang), 0.0, sin(ang)) * float(s.v) * ROLL_RANGE
		var tall := ctx.tallest_near(around, TALL_SEARCH)
		if not tall.is_empty():
			# The highest brick it still has: what sticks up most.
			target = tall.top
			s.aimed = int(tall.building)
	if target == null:
		var d := lerpf(GROUND_MIN, ROLL_RANGE, float(s.v))
		var p := player + Vector3(cos(ang), 0.0, sin(ang)) * d
		p.y = 0.0
		var hit := ctx.ray(p + Vector3.UP * 300.0, p + Vector3.DOWN * 50.0)
		target = hit.position if not hit.is_empty() else p
	s.target = target
	s.stage = 1
	# Anybody near gets low; a soldier on that roof has 0.6 s: it may not make
	# it, but it tries.
	ducked += ctx.duck_near(target, DUCK_RADIUS, LEADER_S + 1.0)
	ctx.set_hazard(0, AABB((target as Vector3) - Vector3(SHOCK_RADIUS, 1.0, SHOCK_RADIUS),
			Vector3(SHOCK_RADIUS * 2.0, 4.0, SHOCK_RADIUS * 2.0)))
	_leader.global_position = (target as Vector3) + Vector3.UP * 2.0
	_leader_until = _clock + LEADER_S


func _strike(s: Dictionary) -> void:
	s.stage = 2
	ctx.clear_hazard(0)
	var target: Vector3 = s.target
	# The stroke comes down on whatever is on top now -- the roof may have gone
	# since the leader, and the building with it: all the way to the ground.
	var hit := ctx.ray(target + Vector3.UP * 60.0, Vector3(target.x, -50.0, target.z))
	var pos: Vector3 = hit.position if not hit.is_empty() else target
	var normal: Vector3 = hit.normal if not hit.is_empty() else Vector3.UP
	var r := STRIKE_RADIUS * sqrt(maxf(intensity, 0.1))
	ctx.scorch(pos, r + SCORCH_RIM)   # the stroke's black mark round its hole
	ctx.blast(pos, r)
	ctx.impact_fx(pos, normal)
	ctx.shake(pos, 0.35)
	var hurt := ctx.damage_pawns(pos, SHOCK_RADIUS, SHOCK_DAMAGE * intensity)
	if s.ignite:
		ctx.ignite(pos, 0.8)
	var player := ctx.player_pos()
	var dist := player.distance_to(pos)
	var delay := dist / SOUND_SPEED
	_thunders.append([_clock + delay, pos])
	_thunders.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	landed.append({"pos": pos, "building": ctx.building_at(pos, 0.6), "aimed": s.aimed,
			"player_dist": dist, "thunder_delay": delay, "hurt": hurt})
	_make_bolt(pos)
	_strike_light.global_position = pos + Vector3.UP * 4.0
	_bolt_t = 0.0


# --- Look and sound -------------------------------------------------------------

func _process(delta: float) -> void:
	if phase == Phase.DONE:
		return
	var cam: Camera3D = ctx.city.camera
	_rain.global_position = cam.global_position + Vector3.UP * 14.0
	# Leader: a faint, nervous glow where the stroke is about to land.
	_leader.visible = _clock < _leader_until
	if _leader.visible:
		_leader.light_energy = randf_range(0.5, 3.0)
	# The stroke: on/off per FLICKER, the scene lit while it is on.
	_flash = 0.0
	if _bolt_t >= 0.0:
		_bolt_t += delta
		var on := false
		var acc := 0.0
		for i in FLICKER.size():
			acc += float(FLICKER[i])
			if _bolt_t < acc:
				on = i % 2 == 0
				break
		if hold_bolt and _bolt_t < 1.0:
			on = true
		elif _bolt_t >= acc:
			_bolt_t = -1.0
		_bolt.visible = on
		_strike_light.visible = on
		if on:
			_flash = 1.6
			_draw_bolt(cam.global_position)
	else:
		_bolt.visible = false
		_strike_light.visible = false
	_apply_sky()


func _apply_sky() -> void:
	ctx.set_sky(_sky, SKY_SUN, SKY_TOP, SKY_HORIZON, SKY_SUN_MUL, _flash)
	# Rain and dark: a little shorter sight, a much worse shot.
	ctx.set_weather(_sky, 0.85, 2.2, intensity)
	ctx.set_screen(_sky, 0.0)
	# A stiff breeze with it: trees move (weather.gdshaderinc).
	ctx.gale = Vector3(0.6, 0.0, 0.8) * 0.4 * _sky


## A jagged path from high above down to `to`, by midpoint displacement, and one
## or two branches off it. Cosmetic: its own randomness, not the storm's rng.
func _make_bolt(to: Vector3) -> void:
	var from := to + Vector3(randf_range(-25, 25), 180.0, randf_range(-25, 25))
	var main := PackedVector3Array([from, to])
	for level in 5:
		var next := PackedVector3Array()
		var jitter := 22.0 / pow(2.0, level)
		for i in main.size() - 1:
			next.append(main[i])
			var mid := (main[i] + main[i + 1]) * 0.5
			next.append(mid + Vector3(randf_range(-jitter, jitter), randf_range(-jitter, jitter) * 0.3,
					randf_range(-jitter, jitter)))
		next.append(main[main.size() - 1])
		main = next
	_bolt_pts = [main]
	for b in randi_range(1, 2):
		var at := randi_range(4, floori(main.size() / 2.0))
		var branch := PackedVector3Array([main[at]])
		var dir := Vector3(randf_range(-1, 1), -1.2, randf_range(-1, 1)).normalized()
		for i in 5:
			branch.append(branch[i] + dir * randf_range(5.0, 9.0)
					+ Vector3(randf_range(-3, 3), 0, randf_range(-3, 3)))
		_bolt_pts.append(branch)


## Every polyline as camera-facing strips.
func _draw_bolt(eye: Vector3) -> void:
	_bolt_mesh.clear_surfaces()
	_bolt_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	for li in _bolt_pts.size():
		var line: PackedVector3Array = _bolt_pts[li]
		var w := BOLT_WIDTH * (1.0 if li == 0 else 0.5)
		for i in line.size() - 1:
			var a := line[i]
			var b := line[i + 1]
			var side := (b - a).cross(eye - a).normalized() * w
			_bolt_mesh.surface_add_vertex(a - side)
			_bolt_mesh.surface_add_vertex(a + side)
			_bolt_mesh.surface_add_vertex(b + side)
			_bolt_mesh.surface_add_vertex(a - side)
			_bolt_mesh.surface_add_vertex(b + side)
			_bolt_mesh.surface_add_vertex(b - side)
	_bolt_mesh.surface_end()


func _loop(p: AudioStreamPlayer, db: float) -> void:
	p.volume_db = db
	if not p.playing:
		p.play()


func _build() -> void:
	_bolt_mesh = ImmediateMesh.new()
	_bolt = MeshInstance3D.new()
	_bolt.mesh = _bolt_mesh
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_color = Color(0.88, 0.92, 1.0)
	_bolt.material_override = mat
	_bolt.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_bolt.visible = false
	add_child(_bolt)

	_leader = OmniLight3D.new()
	_leader.light_color = Color(0.7, 0.8, 1.0)
	_leader.omni_range = 6.0
	_leader.visible = false
	add_child(_leader)
	_strike_light = OmniLight3D.new()
	_strike_light.light_color = Color(0.8, 0.86, 1.0)
	_strike_light.light_energy = 16.0
	_strike_light.omni_range = 60.0
	_strike_light.visible = false
	add_child(_strike_light)

	for i in 4:
		var s := AudioStreamPlayer3D.new()
		s.stream = DisasterSounds.thunder()
		s.unit_size = 80.0
		s.max_distance = 1500.0
		s.volume_db = 6.0
		add_child(s)
		_thunder_players.append(s)
	_wind = AudioStreamPlayer.new()
	_wind.stream = DisasterSounds.wind()
	_wind.volume_db = -40.0
	add_child(_wind)
	_rain_sound = AudioStreamPlayer.new()
	_rain_sound.stream = DisasterSounds.rain()
	_rain_sound.volume_db = -40.0
	add_child(_rain_sound)

	# Rain: one box of streaks that follows the camera, never a city-sized one.
	var drop_mat := StandardMaterial3D.new()
	drop_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	drop_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	drop_mat.billboard_mode = BaseMaterial3D.BILLBOARD_FIXED_Y
	drop_mat.billboard_keep_scale = true
	drop_mat.albedo_color = Color(0.75, 0.8, 0.88, 0.35)
	var drop := QuadMesh.new()
	drop.size = Vector2(0.025, 0.7)
	drop.material = drop_mat
	var proc := ParticleProcessMaterial.new()
	proc.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	proc.emission_box_extents = Vector3(28.0, 1.0, 28.0)
	proc.direction = Vector3(0.12, -1.0, 0.05)
	proc.spread = 2.0
	proc.initial_velocity_min = 24.0
	proc.initial_velocity_max = 30.0
	proc.gravity = Vector3.ZERO
	_rain = GPUParticles3D.new()
	_rain.amount = 5000
	_rain.lifetime = 1.1
	_rain.local_coords = false
	_rain.emitting = false
	_rain.amount_ratio = 0.0
	_rain.process_material = proc
	_rain.draw_pass_1 = drop
	_rain.visibility_aabb = AABB(Vector3(-40, -40, -40), Vector3(80, 60, 80))
	add_child(_rain)
	RainSplash.add(_rain, proc, self, Color(0.9, 0.94, 1.0, 0.9), "rain", ctx)   # it lands, splashes, patters
