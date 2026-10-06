class_name Earthquake
extends Disaster

## An earthquake (Docs/Disasters.md section 10).
##
## The whole city shakes at once, which is the problem the design is built
## around: every building collapsing together would be the worst tick the
## game has. So the shaking is cheap and city-wide -- the camera, loose pieces
## jolted, pawns stumbling, bricks shaken off facades a few at a time -- and
## COLLAPSES are rationed:
##
##   * a building whose bricks are in fails where its JOINTS do. Every
##     PULSE_S the ground's acceleration -- PGA g at intensity 1, full shaking,
##     along the quake's axis, both ways -- is put to it as a sideways load
##     (BrickWorld.lateral_check): at each course boundary, the overturning
##     moment of everything above against what holds it, gravity and the
##     studs across the boundary. Where that fails, the building is cut there
##     -- a clean seam, a committed SEVER -- and the freed top is tipped over
##     its toe on the side it was thrown toward. Tall, slender towers go in a
##     medium quake; squat ones need an extreme one; a tower already shot
##     through fails sooner, because its studs are gone.
##   * a building out of reach has no bricks to ask. It rolls, at the start,
##     whether it will fail and when -- slender ones likelier -- and fails as a
##     SOFT STOREY, the cheap way: a band of blasts through the ground storey
##     on one side, and the city's own topple takes it over whole. If it still
##     stands after UNDERMINE_WAIT, the band is cut deeper once.
##
##     (Big tops once would not turn when tipped -- 1,100 bricks at 0.00 rad/s.
##     That was the staircase threading through the cut; CityScene._with_stairs
##     takes the stairs with the piece now, and they turn.)
##   * no more than `max_collapse_at_once` are falling at a time (a collapse
##     counts until its piece has come to rest), and no more than
##     `max_collapse_total` in the whole quake. A failure that finds the cap
##     full waits for a slot; if the shaking ends first, it never happens.
##

const RANGE := 120.0              ## m from the player a building may fail
const FACADE_RANGE := 80.0
const MIN_STOREYS := 4            ## shorter buildings do not collapse, only shed
const RISK := 0.12                ## per unit of slenderness, at intensity 1
const JOLT_EVERY := 6             ## ticks between jolts to pieces and pawns
const PIECE_JOLT := 1.4           ## m/s at intensity 1, full shaking
const PAWN_JOLT := 1.3
const FACADE_EVERY := 0.25        ## s
const CHIP_HP := 70
const UNDERMINE_DEPTH := 0.6      ## share of the building's depth the ground storey loses
const UNDERMINE_DEEPER := 0.8     ## if that was not enough
const UNDERMINE_WAIT := 3.0       ## s before cutting deeper
const GIVE_UP_S := 7.0            ## s: still standing, it survived
const BAND_STEP := 1.5            ## m between blasts in the band
const BAND_RADIUS := 1.1
const COLLAPSE_MAX_S := 14.0      ## a collapse stops counting after this, settled or not
const TIP_ANGLE := 50.0           ## degrees: past this its centre is over the edge (~37 for a
                                  ## five-storey block) and gravity has it
const TIP_SPIN := 0.5             ## rad/s over the edge
const PUSH_S := 4.0               ## s it is helped over after it starts to topple
const HAZARD_BASE := 20
## Peak ground acceleration, in g, at intensity 1 and full shaking. Calibrated
## on the small city: its 35 m towers fail from ~0.4 g, the 27 m ones from
## ~0.55-0.8, 19 m from ~0.9, and the 8 m blocks hold past 3 g.
const PGA := 0.45
const PULSE_S := 1.0
## A cut's top must be at least this many bricks to be the piece that tips.
const TOP_MIN_BRICKS := 100

var max_collapse_at_once := 2
var max_collapse_total := 6

## Per building (registry order): the numbers it will fail with, rolled in begin().
var _rolls: Array[Dictionary] = []
## Buildings that will fail, in time order: {id, t, storey_roll, side, risk}.
var plan: Array[Dictionary] = []
## Failures begun: {id, dir, box, at, deeper, toppled, toppled_at, piece, tilt,
## done, survived, blasts}.
var collapses: Array[Dictionary] = []
## For the probe and the HUD.
var peak_at_once := 0
var held := 0                     ## ticks a failure waited for a slot
var dropped := 0                  ## failures the total cap or the end refused
var facade_chips := 0
var facade_shears := 0
var amplitude := 0.0

var _next_facade := 0.0
var _next_pulse := 0.0
## The axis the ground moves along, both ways. From the seed.
var axis := Vector3.RIGHT
## Buildings failing or already failed, by id: one failure each.
var _failing := {}
## For the probe: solver checks, and the failures they found.
var lateral_checks := 0
var lateral_fails := 0
var _rumble: AudioStreamPlayer
var _booms: Array[AudioStreamPlayer3D] = []
var _boom_i := 0
var _dust: Array[GPUParticles3D] = []
var _dust_i := 0


func _init() -> void:
	title = "Earthquake"
	warning_s = 4.0
	active_s = 20.0
	ending_s = 6.0


func _on_begin() -> void:
	max_collapse_at_once = int(options.get("max_collapse_at_once", 2))
	max_collapse_total = int(options.get("max_collapse_total", 6))
	active_s = 14.0 + 6.0 * intensity
	for i in ctx.registry.buildings.size():
		_rolls.append({"u": rng.randf(), "fail": rng.randf(), "t": rng.randf(),
				"storey": rng.randf(), "side": rng.randi_range(0, 3)})
	axis = Vector3.RIGHT if rng.randf() < 0.5 else Vector3.BACK
	_build()


func _on_phase(p: Phase) -> void:
	match p:
		Phase.ACTIVE:
			_plan()
		Phase.ENDING:
			dropped += plan.size()
			plan.clear()
		Phase.DONE:
			_rumble.stop()
			ctx.set_weather(0.0, 1.0, 1.0)
			ctx.set_screen(0.0, 0.0)
			for i in collapses.size():
				ctx.clear_hazard(HAZARD_BASE + i)


## Who fails, and when, from the rolls -- resolved now, against the buildings
## that are standing and near the player.
func _plan() -> void:
	var player := ctx.player_pos()
	var index := 0
	for b in ctx.registry.buildings:
		var roll: Dictionary = _rolls[index] if index < _rolls.size() else {}
		index += 1
		if roll.is_empty() or b.toppled or b.is_build():
			continue
		var storeys := ctx.storeys_of(b.id)
		if storeys < MIN_STOREYS:
			continue
		var box := CityPlacer.box_of(b)
		var c := box.get_center()
		if Vector2(c.x - player.x, c.z - player.z).length() > RANGE:
			continue
		var slender := box.size.y / maxf(minf(box.size.x, box.size.z), 1.0)
		var risk := clampf(RISK * intensity * slender * (0.5 + float(roll.u)), 0.0, 0.95)
		if float(roll.fail) >= risk:
			continue
		plan.append({"id": b.id, "t": lerpf(2.5, active_s * 0.75, float(roll.t)),
				"storey_roll": roll.storey, "side": roll.side, "risk": risk, "storeys": storeys})
	plan.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.t < b.t)


# --- Shaking ----------------------------------------------------------------------

func _tick_warning(_dt: float) -> void:
	amplitude = 0.15 * phase_t / warning_s
	_shake()


func _tick_active(dt: float) -> void:
	var rise := minf(1.0, phase_t / 2.5)
	var fall := 1.0 if phase_t < active_s * 0.7 else lerpf(1.0, 0.3, (phase_t - active_s * 0.7) / (active_s * 0.3))
	amplitude = rise * fall
	_shake()
	_facades(dt)
	_pulse(dt)
	_fail()
	_follow()


## The ground's push, put to every building whose bricks are in: those whose
## joints give way go into the plan now, cut where they failed.
func _pulse(dt: float) -> void:
	_next_pulse -= dt
	if _next_pulse > 0.0:
		return
	_next_pulse += PULSE_S
	var accel := PGA * intensity * amplitude
	if accel < 0.02:
		return
	var player := ctx.player_pos()
	var due := false
	for b in ctx.registry.buildings:
		if b.toppled or b.is_build() or b.chunk < 0 or _failing.has(b.id):
			continue
		var c := CityPlacer.box_of(b).get_center()
		if Vector2(c.x - player.x, c.z - player.z).length() > RANGE:
			continue
		var worst := {}
		var worst_dir := axis
		for d in [axis, -axis]:
			var r := ctx.lateral(b.id, accel, d)
			lateral_checks += 1
			if not r.is_empty() and (worst.is_empty() or float(r.ratio) > float(worst.ratio)):
				worst = r
				worst_dir = d
		if worst.is_empty() or float(worst.ratio) < 1.0 or not worst.has("level"):
			continue
		lateral_fails += 1
		_failing[b.id] = true
		plan.append({"id": b.id, "t": phase_t, "lateral": true, "dir": worst_dir,
				"level": worst.level, "ratio": float(worst.ratio)})
		due = true
	if due:
		plan.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.t < b.t)


func _tick_ending(dt: float) -> void:
	# Aftershocks: short pulses on a falling level.
	var k := 1.0 - phase_t / ending_s
	amplitude = 0.3 * k * (0.4 + 0.6 * absf(sin(phase_t * 2.3)))
	_shake()
	_facades(dt)
	_follow()


func _shake() -> void:
	var a := amplitude * intensity
	# Nobody shoots straight on moving ground; eyes are fine.
	ctx.set_weather(amplitude, 1.0, 3.0, intensity)
	ctx.set_screen(0.0, amplitude * 0.3, Color(0.62, 0.6, 0.56))
	ctx.shake(ctx.player_pos(), 0.008 + 0.02 * a)
	_rumble.volume_db = lerpf(-40.0, 2.0, clampf(amplitude, 0.0, 1.0))
	if not _rumble.playing:
		_rumble.play()
	if Engine.get_physics_frames() % JOLT_EVERY != 0 or a < 0.05:
		return
	# Loose pieces bounce; the ground moves under them. Cosmetic randomness:
	# pieces are physics, which the log does not carry.
	for isl in ctx.islands.islands:
		if not isl.is_valid() or not is_instance_valid(isl.body) or isl.settled:
			continue
		isl.body.linear_velocity += Vector3(randf_range(-1, 1), randf_range(0.2, 0.6),
				randf_range(-1, 1)) * PIECE_JOLT * a
	for p in ctx.pawns():
		p.shove = Vector3(randf_range(-1, 1), 0.0, randf_range(-1, 1)) * PAWN_JOLT * a


## Bricks shaken off the faces of buildings near the player, a few at a time:
## chips wear, shears knock a clump loose that falls.
func _facades(dt: float) -> void:
	_next_facade -= dt
	if _next_facade > 0.0:
		return
	_next_facade += FACADE_EVERY
	var n := int(round(2.0 * intensity * amplitude))
	if n <= 0:
		return
	var player := ctx.player_pos()
	var near: Array = []
	for pair in ctx.buildings():
		var box: AABB = pair[1]
		var c := box.get_center()
		if Vector2(c.x - player.x, c.z - player.z).length() <= FACADE_RANGE:
			near.append(box)
	if near.is_empty():
		return
	for i in n:
		var box: AABB = near[rng.randi_range(0, near.size() - 1)]
		var side := rng.randi_range(0, 3)
		var along := rng.randf()
		var h := rng.randf_range(0.3, 1.0)
		var shear := rng.randf() < 0.4
		var y := box.position.y + box.size.y * h
		var p: Vector3
		match side:
			0: p = Vector3(box.position.x + 0.2, y, lerpf(box.position.z, box.end.z, along))
			1: p = Vector3(box.end.x - 0.2, y, lerpf(box.position.z, box.end.z, along))
			2: p = Vector3(lerpf(box.position.x, box.end.x, along), y, box.position.z + 0.2)
			_: p = Vector3(lerpf(box.position.x, box.end.x, along), y, box.end.z - 0.2)
		if shear:
			if ctx.shear(p, 0.7):
				facade_shears += 1
		else:
			ctx.chip(p, 0.45, int(CHIP_HP * intensity))
			facade_chips += 1


# --- Collapses ----------------------------------------------------------------------

func active_collapses() -> int:
	var n := 0
	for c in collapses:
		if not c.done:
			n += 1
	return n


## Start the failures that are due, as far as the caps allow.
func _fail() -> void:
	while not plan.is_empty() and float(plan[0].t) <= phase_t:
		if collapses.size() >= max_collapse_total:
			dropped += plan.size()
			plan.clear()
			return
		if active_collapses() >= max_collapse_at_once:
			held += 1
			return
		var f: Dictionary = plan.pop_front()
		if not f.get("lateral", false):
			var rb = ctx.registry.get_building(int(f.id))
			# Its bricks are in: its joints decide (_pulse), not its roll.
			if rb == null or rb.chunk >= 0 or _failing.has(int(f.id)):
				continue
			_failing[int(f.id)] = true
		_collapse(f)


func _collapse(f: Dictionary) -> void:
	var id := int(f.id)
	var b = ctx.registry.get_building(id)
	if b == null or b.toppled:
		return
	var lateral: bool = f.get("lateral", false)
	var dir: Vector3 = f.dir if lateral \
			else [Vector3.LEFT, Vector3.RIGHT, Vector3.FORWARD, Vector3.BACK][int(f.side)]
	var box := CityPlacer.box_of(b)
	# Its bricks went while it waited for a slot (handed back, far now): no
	# joints to cut, so it goes the cheap way.
	if lateral and not ctx.sever(id, f.level):
		lateral = false
	if lateral:
		var level: Vector3 = f.level
		# From the cut up: the piece that goes over, and the edge it turns on.
		box = AABB(Vector3(box.position.x, level.y, box.position.z),
				Vector3(box.size.x, box.end.y - level.y, box.size.z))
	var c := {"id": id, "dir": dir, "box": box,
			"at": phase_t if phase == Phase.ACTIVE else active_s + phase_t,
			"deeper": lateral, "toppled": lateral, "toppled_at": 0.0, "piece": null, "tilt": 0.0,
			"done": false, "survived": false, "blasts": 0, "lateral": lateral}
	collapses.append(c)
	if not lateral:
		c.blasts = _undermine(box, dir, 0.0, UNDERMINE_DEPTH)
	ctx.set_hazard(HAZARD_BASE + collapses.size() - 1, box.grow(8.0))
	peak_at_once = maxi(peak_at_once, active_collapses())
	var base := Vector3(box.get_center().x, box.position.y + 1.0, box.get_center().z)
	var dust := _dust[_dust_i]
	_dust_i = (_dust_i + 1) % _dust.size()
	dust.global_position = base
	dust.restart()
	var s := _booms[_boom_i]
	_boom_i = (_boom_i + 1) % _booms.size()
	s.global_position = base
	s.play()
	ctx.shake(base, 0.3)


## Blast a band through the ground storey on side `dir`, from `from` to `to`
## of the building's depth, its full width across. Blasts through the
## authority, queued and budgeted like any other. Returns how many.
func _undermine(box: AABB, dir: Vector3, from: float, to: float) -> int:
	var along_x := absf(dir.x) > 0.5
	var depth := box.size.x if along_x else box.size.z
	var width := box.size.z if along_x else box.size.x
	var centre := box.get_center()
	var side := Vector3(0, 0, 1) if along_x else Vector3(1, 0, 0)
	# The ground storey's walls, a course up from the pad: low enough that
	# what is above has nothing under it.
	var y := box.position.y + 0.7
	var n := 0
	var dd := depth * from
	while dd <= depth * to:
		var w := -width * 0.5 + 0.4
		while w <= width * 0.5 - 0.4:
			# From the face on `dir`'s side, inward.
			var p := centre + dir * (depth * 0.5 - 0.3 - dd) + side * w
			p.y = y
			ctx.blast(p, BAND_RADIUS)
			n += 1
			w += BAND_STEP
		dd += BAND_STEP
	return n


## Watch each failure: toppled, still standing (cut deeper, then give up), or
## down and at rest.
func _follow() -> void:
	var now := phase_t if phase == Phase.ACTIVE else active_s + phase_t
	for i in collapses.size():
		var c: Dictionary = collapses[i]
		if c.done:
			continue
		var age := now - float(c.at)
		var b = ctx.registry.get_building(int(c.id))
		if not c.toppled:
			if b != null and b.toppled:
				c.toppled = true
				c.toppled_at = age
			elif age > UNDERMINE_WAIT and not c.deeper:
				c.deeper = true
				c.blasts = int(c.blasts) + _undermine(c.box, c.dir, UNDERMINE_DEPTH, UNDERMINE_DEEPER)
			elif age > GIVE_UP_S:
				c.survived = true
				c.done = true
		else:
			if c.piece == null:
				c.piece = _find_piece(c)
			var isl: BrickIsland = c.piece
			if isl != null and isl.is_valid() and is_instance_valid(isl.body):
				var tilt := rad_to_deg(acos(clampf(isl.body.global_basis.y.dot(Vector3.UP), -1.0, 1.0)))
				c.tilt = maxf(float(c.tilt), tilt)
				# It topples the moment its centre is past what is left -- often
				# barely, and it came to rest leaning at 7 degrees. While the
				# ground still shakes it is tipped on over its undermined edge,
				# until gravity has it.
				if tilt < TIP_ANGLE and age - float(c.toppled_at) < PUSH_S:
					if isl.settled:
						ctx.hold_awake(isl, 1000)
					else:
						tip(isl, c.dir, c.box, intensity)
				elif isl.settled and age - float(c.toppled_at) > 2.0:
					c.done = true
			elif c.piece != null:
				c.done = true
		if age > COLLAPSE_MAX_S:
			c.done = true
		if c.done:
			ctx.clear_hazard(HAZARD_BASE + i)


## Tip `isl` over the bottom edge of `box` on side `dir`: a rigid turn about
## that edge -- its centre rises and moves out as it turns, which is how a
## building goes over. (About its centre it cannot turn at all while it rests
## flat.) Only ever helps: one already going over faster is left alone.
static func tip(isl: BrickIsland, dir: Vector3, box: AABB, strength := 1.0) -> void:
	var body := isl.body
	var half := (box.size.x if absf(dir.x) > 0.5 else box.size.z) * 0.5
	var pivot := Vector3(box.get_center().x, box.position.y, box.get_center().z) + dir * half
	var w := Vector3.UP.cross(dir) * TIP_SPIN * sqrt(maxf(strength, 0.1))
	if body.angular_velocity.dot(w) >= w.length_squared():
		return
	body.angular_velocity = w
	body.linear_velocity = w.cross(body.global_position - pivot)
	body.sleeping = false


## The toppled building: the biggest piece near where it stood.
func _find_piece(c: Dictionary) -> BrickIsland:
	var box: AABB = c.box
	var best: BrickIsland = null
	# A cut's top, not a clump shaken off a facade beside it.
	var most := TOP_MIN_BRICKS - 1 if c.get("lateral", false) else 0
	for isl in ctx.islands_near(box.get_center(), box.size.length()):
		# Its own: old rubble lying near, in a city already wrecked, is not it.
		if not isl.is_valid() or not is_instance_valid(isl.body) or isl.owner != int(c.id):
			continue
		var n := ctx.piece_bricks(isl)
		if n > most:
			most = n
			best = isl
	return best


# --- Look and sound -------------------------------------------------------------------

func _build() -> void:
	_rumble = AudioStreamPlayer.new()
	_rumble.stream = DisasterSounds.rumble()
	_rumble.volume_db = -40.0
	add_child(_rumble)
	for i in 3:
		var s := AudioStreamPlayer3D.new()
		s.stream = DisasterSounds.boom()
		s.unit_size = 40.0
		s.max_distance = 600.0
		s.volume_db = 6.0
		s.pitch_scale = 0.6
		add_child(s)
		_booms.append(s)
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
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.vertex_color_use_as_albedo = true
	mat.albedo_texture = puff
	var quad := QuadMesh.new()
	quad.size = Vector2(6.0, 6.0)
	quad.material = mat
	var proc := ParticleProcessMaterial.new()
	proc.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_RING
	proc.emission_ring_axis = Vector3.UP
	proc.emission_ring_radius = 9.0
	proc.emission_ring_inner_radius = 4.0
	proc.emission_ring_height = 1.0
	proc.direction = Vector3(0, 0.3, 0)
	proc.spread = 90.0
	proc.initial_velocity_min = 3.0
	proc.initial_velocity_max = 8.0
	proc.damping_min = 1.5
	proc.damping_max = 3.0
	proc.gravity = Vector3(0, 0.2, 0)
	proc.scale_min = 0.8
	proc.scale_max = 2.0
	var ramp := Gradient.new()
	ramp.offsets = PackedFloat32Array([0.0, 0.2, 1.0])
	ramp.colors = PackedColorArray([Color(0.6, 0.57, 0.52, 0.0), Color(0.58, 0.55, 0.5, 0.8),
			Color(0.55, 0.53, 0.5, 0.0)])
	var rt := GradientTexture1D.new()
	rt.gradient = ramp
	proc.color_ramp = rt
	for i in 3:
		var p := GPUParticles3D.new()
		p.one_shot = true
		p.emitting = false
		p.explosiveness = 0.8
		p.amount = 90
		p.lifetime = 5.0
		p.process_material = proc
		p.draw_pass_1 = quad
		p.visibility_aabb = AABB(Vector3(-30, -3, -30), Vector3(60, 30, 60))
		add_child(p)
		_dust.append(p)
