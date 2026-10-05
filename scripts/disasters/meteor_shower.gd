class_name MeteorShower
extends Disaster

## A meteor shower (Docs/Disasters.md section 2): 25-40 meteors in 3-4 bursts
## over thirty seconds, all from one side of the sky.
##
## Every impact is the city's own blast, requested of the world authority like a
## rocket's -- nothing here changes a brick. What the shower adds is WHERE, and
## the warning: the sky reddens first, streaks cross it that hit nothing, and a
## glowing ring marks each landing spot 2.5 s before the meteor arrives.
##
## Deterministic: the whole schedule -- times, sizes, which meteors go for a
## building, and the random numbers each will use to pick its spot -- is rolled
## in begin() from the seed. A target is only RESOLVED when its ring appears
## (it depends on where the player and the standing buildings are then), but
## resolving it draws nothing more from the rng.

const SPEED := 120.0            ## m/s
const SPAWN_DIST := 250.0       ## m back along the path from the aim point
const MARK_LEAD := 2.5          ## s the ring shows before impact
const SCORCH_RIM := 1.0         ## m of blackened brick round a crater
const POOL := 8                 ## meteors drawn at once; more still land, unseen
const GROUND_MIN := 8.0         ## m from the player, never closer
const GROUND_MAX := 80.0
const BUILDING_SHARE := 0.6
const BUILDING_RANGE := 120.0   ## m from the player a building target may be
const RADIUS_MIN := 1.5
const RADIUS_MAX := 3.0
const BIG_CHANCE := 0.1
const BIG_RADIUS := 4.8         ## BIG_BLAST * 1.5
const IGNITE_CHANCE := 0.2
const STREAKS := 5              ## harmless ones during the warning
## A GIANT (Docs/Disasters.md 23): its ring shows longer, and where it lands a
## shockwave throws what is loose and knocks people down, ejecta blast the
## ground round the crater, and fires start in a ring.
const GIANT_LEAD := 6.0
const GIANT_RADIUS := 11.0
const SHOCK_REACH := 4.0          ## x the crater's radius
const SHOCK_PUSH := 14.0          ## m/s at the crater's edge, falling off
const SHOCK_DAMAGE := 60.0        ## at the edge, falling off
const EJECTA := 8
const GIANT_RING := 8             ## blasts the crater is made of, after its core

## A warm, dusty cast rather than a red wash: the bricks must keep their own
## colours, or a player cannot read what is being hit.
const SKY_SUN := Color(1.0, 0.8, 0.66)
const SKY_TOP := Color(0.46, 0.36, 0.38)
const SKY_HORIZON := Color(0.9, 0.62, 0.46)
const SKY_SUN_MUL := 0.85

enum Stage { WAITING, MARKED, FLYING, DONE }

## Direction every meteor travels: down and across, from one side of the sky.
var entry_dir := Vector3.DOWN
## The schedule, sorted by impact time. Each: {t, radius, big, ignite,
## to_building, u, v, w, burst, stage, aim, pos, rock, marker}.
var meteors: Array[Dictionary] = []
var bursts := 0
## What landed: {pos, radius, big, burst, player_dist, structure}.
var impacts: Array[Dictionary] = []

## Seconds since ACTIVE began; keeps running through ENDING so meteors already
## in the air land.
var _clock := 0.0
var _sky := 0.0
var _sky_from := 0.0
var _streaks: Array[Dictionary] = []   ## {t, from, vel, rock, life}

var _rocks: Array[Node3D] = []
var _free_rocks: Array[Node3D] = []
var _markers: Array[Decal] = []
var _free_markers: Array[Decal] = []
var _dust: Array[GPUParticles3D] = []
var _dust_i := 0
var _flashes: Array[OmniLight3D] = []
var _flash_i := 0
var _booms: Array[AudioStreamPlayer3D] = []
var _boom_i := 0
var _rumble: AudioStreamPlayer


func _init() -> void:
	title = "Meteor shower"
	warning_s = 8.0
	active_s = 30.0
	ending_s = 4.0


func _on_begin() -> void:
	var yaw := rng.randf() * TAU
	var tilt := deg_to_rad(rng.randf_range(30.0, 60.0))
	entry_dir = Vector3(sin(tilt) * cos(yaw), -cos(tilt), sin(tilt) * sin(yaw)).normalized()
	_roll_schedule()
	_roll_streaks()
	_build_pools()


## The whole shower, from the rng alone. The variants (meteor_storm.gd,
## meteor_mixed.gd, big_meteor.gd) roll their own from the same two parts.
func _roll_schedule() -> void:
	meteors.clear()
	_add_shower(rng.randi_range(25, 40), rng.randi_range(3, 4), RADIUS_MIN, RADIUS_MAX, BIG_CHANCE)
	_sort()


## `count` meteors (scaled by intensity) in `bursts` bursts over ACTIVE, of
## radius `rmin`..`rmax`, a `big_chance` share of them big.
func _add_shower(count: int, p_bursts: int, rmin: float, rmax: float, big_chance: float) -> void:
	# Intensity: more of them, and bigger. At 1 the count is exactly as drawn.
	count = clampi(int(round(count * intensity)), 6, 240)
	bursts = p_bursts
	var grow := sqrt(maxf(intensity, 0.1))
	for i in count:
		var b := floori(float(i * bursts) / count)
		var centre := active_s * (b + 0.5) / bursts
		var big := rng.randf() < big_chance * intensity
		meteors.append({
			"t": clampf(centre + rng.randf_range(-3.0, 3.0), MARK_LEAD + 0.5, active_s - 0.5),
			"radius": (BIG_RADIUS if big else rng.randf_range(rmin, rmax)) * grow,
			"big": big,
			"ignite": rng.randf() < minf(IGNITE_CHANCE * intensity, 0.8),
			"to_building": rng.randf() < BUILDING_SHARE,
			"u": rng.randf(), "v": rng.randf(), "w": rng.randf(),
			"burst": b,
			"stage": Stage.WAITING,
		})


## One giant, landing at `t` into ACTIVE: a building near the player for
## preference, never on top of them.
func _add_giant(t: float, radius := GIANT_RADIUS) -> void:
	var e := []
	for i in EJECTA:
		e.append([rng.randf_range(0.4, 2.5), rng.randf() * TAU, rng.randf_range(1.2, 2.4),
				rng.randf_range(0.8, 1.8)])
	meteors.append({
		"t": clampf(t, GIANT_LEAD + 0.5, active_s - 0.5),
		"radius": minf(radius * sqrt(maxf(intensity, 0.1)), 15.0),
		"big": true, "giant": true, "lead": GIANT_LEAD,
		"ignite": true,
		"to_building": rng.randf() < 0.8,
		"u": rng.randf(), "v": rng.randf(), "w": rng.randf(),
		"burst": bursts,
		"stage": Stage.WAITING,
		"ejecta": e,
	})


func _sort() -> void:
	meteors.sort_custom(func(a: Dictionary, c: Dictionary) -> bool: return a.t < c.t)


func _roll_streaks() -> void:
	var across := Vector3(entry_dir.x, 0.0, entry_dir.z).normalized()
	for i in STREAKS:
		_streaks.append({
			"t": rng.randf_range(1.5, warning_s - 1.0),
			"side": rng.randf_range(-250.0, 250.0),
			"height": rng.randf_range(260.0, 360.0),
			"vel": (across + Vector3.DOWN * 0.12).normalized() * SPEED * 1.4,
			"rock": null, "life": 0.0,
		})


# --- Phases -------------------------------------------------------------------

func _on_phase(p: Phase) -> void:
	match p:
		Phase.ACTIVE:
			# Things falling out of the sky: soldiers with nothing to fight get
			# under a roof (BTShelter), as in a storm.
			ctx.set_storm(true)
		Phase.ENDING:
			_sky_from = _sky
		Phase.DONE:
			ctx.set_storm(false)
			_set_sky(0.0)
			for m in meteors:
				if m.has("hazard"):
					ctx.clear_hazard(int(m.hazard))
			if _rumble != null:
				_rumble.stop()


func _tick_warning(dt: float) -> void:
	_set_sky(phase_t / warning_s)
	_rumble_to(-8.0 * phase_t / warning_s + -30.0 * (1.0 - phase_t / warning_s))
	for s in _streaks:
		if s.rock == null and phase_t >= s.t and s.life == 0.0:
			var r := _take_rock()
			if r == null:
				continue
			var across := Vector3(s.vel.x, 0.0, s.vel.z).normalized()
			var side := across.cross(Vector3.UP)
			s.rock = r
			s.from = ctx.player_pos() - across * 300.0 + side * float(s.side) \
					+ Vector3.UP * float(s.height)
			r.scale = Vector3.ONE * 0.8
		if s.rock != null:
			s.life += dt
			(s.rock as Node3D).global_position = s.from + s.vel * s.life
			if s.life > 4.5:
				_give_rock(s.rock)
				s.rock = null
				s.life = -1.0


func _tick_active(dt: float) -> void:
	_set_sky(1.0)
	_finish_streaks()
	_clock += dt
	_step_meteors(true)
	_step_ejecta()


func _tick_ending(dt: float) -> void:
	_set_sky(_sky_from * (1.0 - phase_t / ending_s))
	_rumble_to(lerpf(-8.0, -40.0, phase_t / ending_s))
	_finish_streaks()
	_clock += dt
	_step_meteors(false)
	_step_ejecta()


func _finish_streaks() -> void:
	for s in _streaks:
		if s.rock != null:
			_give_rock(s.rock)
			s.rock = null


# --- Meteors ------------------------------------------------------------------

## Every meteor, one step. `new` false in ENDING: those not yet marked are
## called off, those already marked still land.
func _step_meteors(new: bool) -> void:
	var flight := SPAWN_DIST / SPEED
	for m in meteors:
		match m.stage:
			Stage.WAITING:
				if not new:
					m.stage = Stage.DONE
				elif _clock >= float(m.t) - float(m.get("lead", MARK_LEAD)):
					_mark(m)
			Stage.MARKED:
				if _clock >= float(m.t) - flight:
					m.stage = Stage.FLYING
					m.pos = _pos_at(m, _clock)
					m.rock = _take_rock()
					if m.rock != null:
						(m.rock as Node3D).scale = Vector3.ONE * clampf(float(m.radius) / 2.6, 1.0, 6.0)
						(m.rock as Node3D).global_position = m.pos
			Stage.FLYING:
				_fly(m)


func _pos_at(m: Dictionary, t: float) -> Vector3:
	return (m.aim as Vector3) - entry_dir * SPEED * maxf(float(m.t) - t, 0.0)


## Where it will land, decided now, and the ring that says so.
func _mark(m: Dictionary) -> void:
	var player := ctx.player_pos()
	var aim = null
	if m.to_building:
		aim = _roof_point(m, player)
	if aim == null:
		aim = _ground_point(m, player)
	m.aim = aim
	m.stage = Stage.MARKED
	# Soldiers see the ring too, and get out of it.
	var reach := float(m.radius) + 1.5
	m.hazard = meteors.find(m)
	ctx.set_hazard(int(m.hazard), AABB((aim as Vector3) - Vector3(reach, 1.0, reach),
			Vector3(reach * 2.0, 6.0, reach * 2.0)))
	m.marker = _take_marker()
	if m.marker != null:
		var d: Decal = m.marker
		var span := float(m.radius) * 2.0 + 1.0
		d.size = Vector3(span, 6.0, span)
		d.global_position = (aim as Vector3) + Vector3.UP * 1.0


## A point on the roof of a standing building within reach, or null.
func _roof_point(m: Dictionary, player: Vector3):
	var near: Array[AABB] = []
	for box in ctx.building_boxes():
		var c := box.get_center()
		var d := Vector2(c.x - player.x, c.z - player.z).length()
		if d <= BUILDING_RANGE:
			near.append(box)
	if near.is_empty():
		return null
	var box := near[mini(int(float(m.u) * near.size()), near.size() - 1)]
	var inset := minf(1.0, box.size.x * 0.25)
	var p := Vector3(lerpf(box.position.x + inset, box.end.x - inset, float(m.v)), box.end.y,
			lerpf(box.position.z + inset, box.end.z - inset, float(m.w)))
	if Vector2(p.x - player.x, p.z - player.z).length() < GROUND_MIN:
		return null
	return p


## A point on whatever is under a spot near the player -- street, rubble or roof.
func _ground_point(m: Dictionary, player: Vector3) -> Vector3:
	var ang := float(m.v) * TAU
	var dist := lerpf(GROUND_MIN, GROUND_MAX, sqrt(float(m.w)))
	var p := Vector3(player.x + cos(ang) * dist, 0.0, player.z + sin(ang) * dist)
	var hit := ctx.ray(p + Vector3.UP * 400.0, p + Vector3.DOWN * 50.0)
	if not hit.is_empty():
		p = hit.position
	return p


## One physics step of a meteor in the air: sweep the segment it covered, so
## at 4 m a tick it cannot pass through a wall.
func _fly(m: Dictionary) -> void:
	var from: Vector3 = m.pos
	var to := _pos_at(m, _clock)
	if _clock >= float(m.t):
		# At the aim and nothing in the way yet: carry on through it a little,
		# in case the ring was resolved onto something that has since fallen.
		to = (m.aim as Vector3) + entry_dir * 30.0
	var hit := ctx.ray(from - entry_dir * 0.5, to)
	if not hit.is_empty():
		_impact(m, hit.position, hit.normal, ctx.building_at(hit.position) >= 0)
	elif _clock >= float(m.t):
		_impact(m, m.aim, -entry_dir, false)
	else:
		m.pos = to


func _impact(m: Dictionary, pos: Vector3, normal: Vector3, structure: bool) -> void:
	var t_us := Time.get_ticks_usec()
	m.stage = Stage.DONE
	if m.rock != null:
		_give_rock(m.rock)
		m.rock = null
	if m.marker != null:
		_give_marker(m.marker)
		m.marker = null
	if m.has("hazard"):
		ctx.clear_hazard(int(m.hazard))
	var r := float(m.radius)
	# Char first: the crater's rim is left black (SCORCH), its middle blown away.
	ctx.scorch(pos, r + SCORCH_RIM)
	if m.get("giant", false):
		# The same hole in pieces: a core now, a ring of overlapping blasts
		# over the next few ticks. One blast this big was the whole crater's
		# work in one tick -- 125-175 ms.
		ctx.blast(pos, r * 0.55)
		for i in GIANT_RING:
			var a := TAU * float(i) / GIANT_RING
			_ejecta.append([_clock + 0.034 * float(i + 1), pos + Vector3(cos(a), 0.0, sin(a)) * r * 0.5,
					r * 0.52])
	else:
		ctx.blast(pos, r)
	ctx.impact_fx(pos, normal)
	ctx.shake(pos, 0.5 if m.big else 0.25)
	if m.ignite:
		ctx.ignite(pos, 1.0 if m.big else 0.6)
	_burst(pos, r, m.big)
	if m.get("giant", false):
		_giant_impact(m, pos, r)
	var player := ctx.player_pos()
	impact_ms = maxf(impact_ms, float(Time.get_ticks_usec() - t_us) / 1000.0)
	impacts.append({"pos": pos, "radius": r, "big": m.big, "burst": m.burst,
			"structure": structure,
			"player_dist": Vector2(pos.x - player.x, pos.z - player.z).length()})


# --- Giants -------------------------------------------------------------------

## Pending ejecta: [at clock, point, radius]. Pending shock pulses: [at clock,
## point, crater radius] -- the crater's own rubble only comes loose a few
## ticks after the blast, so the wave goes through it then.
var _ejecta: Array = []
var _shocks: Array = []
var giants_landed := 0
var impact_ms := 0.0             ## the slowest impact, for the probe
var shocked_pieces := 0
var shocked_pawns := 0


## What a giant does beyond its crater.
func _giant_impact(m: Dictionary, pos: Vector3, r: float) -> void:
	giants_landed += 1
	var reach := r * SHOCK_REACH
	ctx.shake(pos, 1.4)
	ctx.wake_near(pos, reach)
	# The shockwave: what is loose is thrown out and up, now and again as the
	# crater's rubble comes free; people knocked over.
	_shock(pos, r)
	_shocks.append([_clock + 0.25, pos, r])
	_shocks.append([_clock + 0.7, pos, r])
	_shocks.append([_clock + 1.5, pos, r])
	_shocks.append([_clock + 2.5, pos, r])
	for p in ctx.pawns():
		var d := p.chest().distance_to(pos)
		if d > reach:
			continue
		var k := clampf(1.0 - (d - r) / (reach - r), 0.0, 1.0)
		var away := Vector3(p.chest().x - pos.x, 0.0, p.chest().z - pos.z).normalized()
		p.shove = away * 9.0 * k + Vector3.UP * 3.0 * k
		ctx.damage_pawns(p.chest(), 0.4, SHOCK_DAMAGE * k)
		shocked_pawns += 1
	# Fires in a ring round the rim.
	for i in 4:
		var a := TAU * float(i) / 4.0 + float(m.u) * TAU
		ctx.ignite(pos + Vector3(cos(a), 1.0, sin(a)) * (r * 0.9), 0.9)
	# Ejecta: smaller blasts round it over the next seconds.
	for e in m.ejecta:
		var a: float = e[1]
		var d: float = r * float(e[2])
		var p2 := pos + Vector3(cos(a) * d, 0.0, sin(a) * d)
		var hit := ctx.ray(p2 + Vector3.UP * 60.0, p2 + Vector3.DOWN * 40.0)
		if not hit.is_empty():
			p2 = hit.position
		_ejecta.append([_clock + float(e[0]), p2, float(e[3])])
	# The dust of it: every pool's cloud at once, round the crater.
	for i in _dust.size():
		var dust := _dust[i]
		var a := TAU * float(i) / _dust.size()
		dust.global_position = pos + Vector3(cos(a), 0.0, sin(a)) * r * 0.6
		dust.scale = Vector3.ONE * (r / 1.2)
		dust.restart()


func _shock(pos: Vector3, r: float) -> void:
	var reach := r * SHOCK_REACH
	for isl in ctx.islands_near(pos, reach):
		if not isl.is_valid() or not is_instance_valid(isl.body):
			continue
		var rel := isl.body.global_position - pos
		var d := maxf(rel.length(), 0.5)
		var k := clampf(1.0 - (d - r) / (reach - r), 0.0, 1.0) if d > r else 1.0
		if k <= 0.0:
			continue
		var bricks := maxf(float(ctx.piece_bricks(isl)), 1.0)
		var out := (Vector3(rel.x, 0.0, rel.z).normalized() + Vector3.UP * 0.6).normalized()
		isl.body.linear_velocity += out * SHOCK_PUSH * k * clampf(60.0 / bricks, 0.15, 1.0)
		isl.body.sleeping = false
		shocked_pieces += 1


func _step_ejecta() -> void:
	var waves: Array = []
	for w in _shocks:
		if _clock >= float(w[0]):
			_shock(w[1], float(w[2]))
		else:
			waves.append(w)
	_shocks = waves
	var keep: Array = []
	for e in _ejecta:
		if _clock >= float(e[0]):
			ctx.blast(e[1], float(e[2]))
			ctx.scorch(e[1], float(e[2]) + 0.6)
			ctx.impact_fx(e[1], Vector3.UP)
		else:
			keep.append(e)
	_ejecta = keep


# --- Look and sound -------------------------------------------------------------

func _process(_delta: float) -> void:
	if phase == Phase.DONE:
		return
	# Drawn between physics ticks: at 30 ticks a second a meteor moves 4 m a
	# tick, which reads as stutter unless the rock is placed per frame.
	var ahead := Engine.get_physics_interpolation_fraction() / Engine.physics_ticks_per_second
	for m in meteors:
		if m.stage == Stage.FLYING and m.rock != null:
			(m.rock as Node3D).global_position = _pos_at(m, _clock + ahead)
		elif m.stage == Stage.MARKED and m.marker != null:
			var d: Decal = m.marker
			d.emission_energy = 2.0 + 1.5 * sin(Time.get_ticks_msec() * 0.012)
	for f in _flashes:
		if f.visible:
			f.light_energy *= 0.8
			if f.light_energy < 0.2:
				f.visible = false


func _burst(pos: Vector3, r: float, big: bool) -> void:
	var dust := _dust[_dust_i]
	_dust_i = (_dust_i + 1) % _dust.size()
	dust.global_position = pos
	dust.scale = Vector3.ONE * (r / 2.0)
	dust.restart()
	var f := _flashes[_flash_i]
	_flash_i = (_flash_i + 1) % _flashes.size()
	f.global_position = pos + Vector3.UP * 1.5
	f.light_energy = clampf(5.0 + r * 1.8, 7.0, 40.0)
	f.omni_range = maxf(f.omni_range, r * 6.0)
	f.visible = true
	var s := _booms[_boom_i]
	_boom_i = (_boom_i + 1) % _booms.size()
	s.global_position = pos
	# Cosmetic, so not from the disaster's rng: that is the schedule's alone.
	s.pitch_scale = clampf(1.0 - (r - 2.0) * 0.06, 0.45, 1.0) * randf_range(0.92, 1.08)
	s.volume_db = clampf((r - 3.0) * 1.5, 0.0, 12.0)
	s.play()


func _set_sky(a: float) -> void:
	_sky = a
	ctx.set_sky(a, SKY_SUN, SKY_TOP, SKY_HORIZON, SKY_SUN_MUL)
	# Dust in the air and the ground jumping: a little.
	ctx.set_weather(a, 0.95, 1.3, intensity)
	ctx.set_screen(0.0, a * 0.35, Color(0.75, 0.52, 0.38))


func _rumble_to(db: float) -> void:
	if _rumble == null:
		return
	_rumble.volume_db = db
	if not _rumble.playing:
		_rumble.play()


# --- Pools: everything is made in begin(), nothing mid-shower ------------------

func _build_pools() -> void:
	# One soft round puff for every particle: a bare quad reads as a square.
	var puff := GradientTexture2D.new()
	puff.width = 64
	puff.height = 64
	puff.fill = GradientTexture2D.FILL_RADIAL
	puff.fill_from = Vector2(0.5, 0.5)
	puff.fill_to = Vector2(1.0, 0.5)
	var pg := Gradient.new()
	pg.offsets = PackedFloat32Array([0.0, 0.5, 1.0])
	pg.colors = PackedColorArray([Color(1, 1, 1, 1), Color(1, 1, 1, 0.45), Color(1, 1, 1, 0)])
	puff.gradient = pg
	var rock_mat := StandardMaterial3D.new()
	rock_mat.albedo_color = Color(0.25, 0.12, 0.08)
	rock_mat.emission_enabled = true
	rock_mat.emission = Color(1.0, 0.45, 0.12)
	rock_mat.emission_energy_multiplier = 3.0
	var trail_mat := StandardMaterial3D.new()
	trail_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	trail_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	trail_mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	trail_mat.vertex_color_use_as_albedo = true
	trail_mat.albedo_texture = puff
	var trail_quad := QuadMesh.new()
	trail_quad.size = Vector2(3.2, 3.2)
	trail_quad.material = trail_mat
	var trail_proc := ParticleProcessMaterial.new()
	trail_proc.spread = 180.0
	trail_proc.initial_velocity_min = 0.0
	trail_proc.initial_velocity_max = 2.0
	trail_proc.gravity = Vector3.ZERO
	trail_proc.scale_min = 0.6
	trail_proc.scale_max = 1.6
	trail_proc.color_ramp = _ramp([Color(1.0, 0.8, 0.3, 1.0), Color(1.0, 0.4, 0.1, 0.8),
			Color(0.25, 0.22, 0.2, 0.5), Color(0.2, 0.2, 0.2, 0.0)])
	var shape_rng := RandomNumberGenerator.new()
	shape_rng.seed = 0x5707E
	for i in POOL:
		var root := Node3D.new()
		# A meteor made of bricks: a few boxes on the stud lattice's
		# proportions, jumbled, glowing.
		for k in 5:
			var mi := MeshInstance3D.new()
			var bm := BoxMesh.new()
			bm.size = Vector3(0.7, 0.42, 0.7) * shape_rng.randf_range(0.9, 1.6)
			mi.mesh = bm
			mi.material_override = rock_mat
			mi.position = Vector3(shape_rng.randf_range(-0.4, 0.4),
					shape_rng.randf_range(-0.4, 0.4), shape_rng.randf_range(-0.4, 0.4))
			mi.rotation = Vector3(shape_rng.randf() * TAU, shape_rng.randf() * TAU, 0.0)
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			root.add_child(mi)
		var light := OmniLight3D.new()
		light.light_color = Color(1.0, 0.55, 0.2)
		light.light_energy = 4.0
		light.omni_range = 14.0
		root.add_child(light)
		var trail := GPUParticles3D.new()
		# Emission steps once per particle frame, and at 120 m/s the default
		# 30 fps is a puff every 4 m: a row of dots. Every rendered frame, and
		# puffs wider than the step, make it a line.
		trail.amount = 320
		trail.lifetime = 0.8
		trail.fixed_fps = 0
		trail.local_coords = false
		trail.process_material = trail_proc
		trail.draw_pass_1 = trail_quad
		trail.visibility_aabb = AABB(Vector3(-200, -200, -200), Vector3(400, 400, 400))
		trail.name = "Trail"
		root.add_child(trail)
		_park(root)
		add_child(root)
		_rocks.append(root)
		_free_rocks.append(root)

	var ring := GradientTexture2D.new()
	ring.width = 128
	ring.height = 128
	ring.fill = GradientTexture2D.FILL_RADIAL
	ring.fill_from = Vector2(0.5, 0.5)
	ring.fill_to = Vector2(1.0, 0.5)
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.55, 0.78, 0.9, 1.0])
	g.colors = PackedColorArray([Color(1.0, 0.35, 0.1, 0.25), Color(1.0, 0.35, 0.1, 0.1),
			Color(1.0, 0.5, 0.15, 1.0), Color(1.0, 0.35, 0.1, 0.6), Color(1.0, 0.3, 0.1, 0.0)])
	ring.gradient = g
	# Emission ignores alpha: the glow needs its own texture, black wherever
	# the ring is clear, or the decal's whole square lights up.
	var glow := ring.duplicate() as GradientTexture2D
	var gg := Gradient.new()
	gg.offsets = g.offsets
	var premul := PackedColorArray()
	for c in g.colors:
		premul.append(Color(c.r * c.a, c.g * c.a, c.b * c.a, 1.0))
	gg.colors = premul
	glow.gradient = gg
	for i in POOL + 4:
		var d := Decal.new()
		d.texture_albedo = ring
		d.texture_emission = glow
		d.emission_energy = 2.0
		d.normal_fade = 0.5
		d.visible = false
		add_child(d)
		_markers.append(d)
		_free_markers.append(d)

	var dust_mat := StandardMaterial3D.new()
	dust_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	dust_mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	dust_mat.vertex_color_use_as_albedo = true
	dust_mat.albedo_texture = puff
	var dust_quad := QuadMesh.new()
	dust_quad.size = Vector2(3.5, 3.5)
	dust_quad.material = dust_mat
	var dust_proc := ParticleProcessMaterial.new()
	dust_proc.direction = Vector3.UP
	dust_proc.spread = 70.0
	dust_proc.initial_velocity_min = 3.0
	dust_proc.initial_velocity_max = 10.0
	dust_proc.gravity = Vector3(0, -4.0, 0)
	dust_proc.damping_min = 2.0
	dust_proc.damping_max = 4.0
	dust_proc.scale_min = 0.8
	dust_proc.scale_max = 2.0
	dust_proc.color_ramp = _ramp([Color(1.0, 0.6, 0.25, 1.0), Color(0.5, 0.46, 0.42, 0.9),
			Color(0.4, 0.4, 0.4, 0.0)])
	for i in 4:
		var p := GPUParticles3D.new()
		p.one_shot = true
		p.emitting = false
		p.explosiveness = 0.95
		p.amount = 64
		p.lifetime = 1.8
		p.process_material = dust_proc
		p.draw_pass_1 = dust_quad
		p.visibility_aabb = AABB(Vector3(-20, -5, -20), Vector3(40, 30, 40))
		add_child(p)
		_dust.append(p)
	for i in 4:
		var f := OmniLight3D.new()
		f.light_color = Color(1.0, 0.6, 0.3)
		f.omni_range = 26.0
		f.visible = false
		add_child(f)
		_flashes.append(f)
	for i in 4:
		var s := AudioStreamPlayer3D.new()
		s.stream = DisasterSounds.boom()
		s.unit_size = 40.0
		s.max_distance = 500.0
		s.volume_db = 4.0
		add_child(s)
		_booms.append(s)
	_rumble = AudioStreamPlayer.new()
	_rumble.stream = DisasterSounds.rumble()
	_rumble.volume_db = -40.0
	add_child(_rumble)


func _ramp(colours: Array) -> GradientTexture1D:
	var g := Gradient.new()
	var offs := PackedFloat32Array()
	for i in colours.size():
		offs.append(float(i) / (colours.size() - 1))
	g.offsets = offs
	g.colors = PackedColorArray(colours)
	var t := GradientTexture1D.new()
	t.gradient = g
	return t


func _take_rock() -> Node3D:
	if _free_rocks.is_empty():
		return null
	var r: Node3D = _free_rocks.pop_back()
	r.visible = true
	(r.get_node("Trail") as GPUParticles3D).emitting = true
	return r


func _give_rock(r: Node3D) -> void:
	_park(r)
	_free_rocks.append(r)


func _park(r: Node3D) -> void:
	r.visible = false
	var trail := r.get_node_or_null("Trail") as GPUParticles3D
	if trail != null:
		trail.emitting = false


func _take_marker() -> Decal:
	if _free_markers.is_empty():
		return null
	var d: Decal = _free_markers.pop_back()
	d.visible = true
	return d


func _give_marker(d: Decal) -> void:
	d.visible = false
	_free_markers.append(d)
