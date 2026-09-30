class_name Tornado
extends Disaster

## A tornado (Docs/Disasters.md section 4). It forms at the city's edge, walks a
## seeded curve across it -- bent to pass near the player -- and ropes out at
## the far side.
##
## What it does, per physics tick while it has strength:
##   * LOOSE PIECES within LIFT_RADIUS are pulled round, in and up, by a
##     velocity change that shrinks with the piece's brick count: rubble flies,
##     a toppled tower half barely slides. Nothing is pushed past
##     MAX_DEBRIS_SPEED's share. Settled small pieces are woken first.
##   * FACADES: four times a second, a few rays go out from the axis at random
##     heights; a building face they meet within the funnel is CHIPPED -- the
##     skin comes off, windows and corners first. Chips, never blasts: a
##     tornado does not crater.
##   * PAWNS within PAWN_RADIUS are shoved round and off their feet (Pawn.shove).
##   * SOLDIERS are told where not to be: the funnel, swept two seconds ahead.
##   * STANDING BUILDINGS within PUSH_REACH of the funnel take the wind as a
##     sideways load, the earthquake's (BrickWorld.lateral_check): up to WIND_G
##     at the funnel wall, along the swirl. One whose joints give way is cut
##     there (a SEVER seam) and its top is tipped over downwind -- no more than
##     MAX_PUSHED in a tornado. Once a second, for buildings whose bricks are in.
##
## Deterministic: the path's shape and every facade ray come from the rng on
## the physics tick. Where it bends toward the player is resolved when ACTIVE
## begins, from numbers rolled in begin().

## At intensity 1. Radii grow with its square root, forces and damage with it.
## The first tornado was too weak to see work: 25 m, 18 m/s, only rubble under
## 800 bricks, and nothing torn off a building -- it chipped facades and there
## was little loose for it to lift. Now it tears CLUMPS off (SHEAR) as well, and
## those are what it throws.
const LIFT_RADIUS := 30.0
const LIFT_MAX_BRICKS := 2500     ## heavier pieces are left to lie
const LIFT_REF_BRICKS := 80.0     ## a piece this size takes the full pull
const SPIN := 24.0                ## m/s round the axis at the funnel wall
const INFLOW := 7.0
const LIFT := 14.0
const TOP := 38.0                 ## m: above this a piece is flung out
const FLING := 10.0               ## m/s outward, above TOP
const PULL := 0.3                 ## share of the gap to the target velocity closed per tick
const PAWN_RADIUS := 14.0
const PAWN_SPIN := 11.0
const PAWN_LIFT := 4.5
const CHIP_EVERY := 0.25          ## s
const CHIP_HP := 180
const CHIP_RADIUS := 0.6
const SHEAR_SHARE := 0.5          ## of facade hits, how many tear a clump off
const SHEAR_RADIUS := 0.9
const FORM_S := 4.0               ## s to form at the start of ACTIVE
const WALK := 5.0                 ## m/s along its path
const HOLD_MS := 1500             ## a piece the wind has let go of may settle this long after
const HAZARD := 0                 ## this disaster's hazard id
## The wind on a standing building, as the g of sideways load it puts on it at
## the funnel wall at intensity 1. A medium tornado takes the tallest towers;
## an extreme one the mid-rise too.
const WIND_G := 0.45
const PUSH_REACH := 0.6           ## of the lift radius, from the axis to the building
const PUSH_EVERY := 1.0           ## s
const MAX_PUSHED := 3             ## at intensity 1

const SKY_SUN := Color(0.78, 0.82, 0.72)
const SKY_TOP := Color(0.3, 0.33, 0.3)
const SKY_HORIZON := Color(0.52, 0.53, 0.46)
const SKY_SUN_MUL := 0.5

## The path, dense: world points on the ground, and the distance along it at each.
var path := PackedVector3Array()
var _along := PackedFloat32Array()
var speed := 5.0
## Where the axis stands now, and its velocity.
var pos := Vector3.ZERO
var vel := Vector3.ZERO
## 0..1: how much tornado there is. Forms, holds, ropes out.
var strength := 0.0

## For the probe and the HUD.
var pieces_pulled := {}          ## chunk id -> true
var fastest_piece := 0.0
var chips: Array[Dictionary] = []   ## {point, axis}
var pawns_shoved := 0
var nearest_player := INF

var _entry := 0.0
var _exit := 0.0
var _bend := Vector2.ZERO        ## how far each middle waypoint leans to the player
var _travel := 0.0
var _next_chip := 0.0
var _sky := 0.0
var _sky_from := 0.0
var _form := 0.0

## The constants above, scaled by intensity in begin().
var _lift_r := LIFT_RADIUS
var _max_bricks := LIFT_MAX_BRICKS
var _spin := SPIN
var _lift := LIFT
var _pawn_r := PAWN_RADIUS
var _chip_hp := CHIP_HP
var _shear_r := SHEAR_RADIUS
var _rays := 1.0
var _size := 1.0
var shears := 0
## Buildings the wind put over: {id, box (from the cut up), dir, t, piece}.
var pushed: Array[Dictionary] = []
var _next_push := 0.0

var _funnel: MeshInstance3D
var _funnel_mat: ShaderMaterial
var _orbit: MultiMeshInstance3D
var _dust: GPUParticles3D
var _wind: AudioStreamPlayer
var _roar: AudioStreamPlayer3D


func _init() -> void:
	title = "Tornado"
	warning_s = 8.0
	active_s = 60.0
	ending_s = 6.0


func _on_begin() -> void:
	_entry = rng.randf() * TAU
	_exit = _entry + PI + rng.randf_range(-0.6, 0.6)
	_bend = Vector2(rng.randf_range(0.45, 0.85), rng.randf_range(0.45, 0.85))
	var k := maxf(intensity, 0.1)
	_size = sqrt(k)
	_lift_r = LIFT_RADIUS * _size
	_pawn_r = PAWN_RADIUS * _size
	_shear_r = SHEAR_RADIUS * _size
	_spin = SPIN * _size
	_lift = LIFT * _size
	_max_bricks = int(LIFT_MAX_BRICKS * k)
	_chip_hp = int(CHIP_HP * k)
	_rays = k
	_plan(false)
	pos = path[0]
	_build()
	_place_visuals()


## The route: from the city's edge at the entry angle to the far edge, through
## two waypoints leaned toward the player. `toward_player` false for the first
## guess in begin() -- the warning's dust needs a place to rise -- and true once
## ACTIVE begins and the player's position is what it will be.
func _plan(toward_player: bool) -> void:
	var bounds := ctx.city_bounds()
	var c := bounds.get_center()
	c.y = 0.0
	var reach := maxf(bounds.size.x, bounds.size.z) * 0.5 + 30.0
	var p0 := c + Vector3(cos(_entry), 0.0, sin(_entry)) * reach
	var p3 := c + Vector3(cos(_exit), 0.0, sin(_exit)) * reach
	var m1 := p0.lerp(p3, 0.35)
	var m2 := p0.lerp(p3, 0.65)
	if toward_player:
		var pl := ctx.player_pos()
		pl.y = 0.0
		m1 = m1.lerp(pl, _bend.x)
		m2 = m2.lerp(pl, _bend.y)
	var ctrl := [p0, p0, m1, m2, p3, p3]
	path = PackedVector3Array()
	for seg in range(1, ctrl.size() - 2):
		for i in 24:
			path.append(_catmull(ctrl[seg - 1], ctrl[seg], ctrl[seg + 1], ctrl[seg + 2], i / 24.0))
	path.append(p3)
	_along = PackedFloat32Array([0.0])
	for i in range(1, path.size()):
		_along.append(_along[i - 1] + path[i].distance_to(path[i - 1]))
	# A tornado walks at its own pace; how long it lasts follows from the
	# city's size, not the other way round -- the small city is a 30 s crossing.
	var length := _along[_along.size() - 1]
	active_s = clampf(length / WALK + 2.0, 25.0, 75.0)
	speed = length / (active_s - 2.0)


static func _catmull(a: Vector3, b: Vector3, c: Vector3, d: Vector3, t: float) -> Vector3:
	var t2 := t * t
	var t3 := t2 * t
	return 0.5 * ((2.0 * b) + (-a + c) * t + (2.0 * a - 5.0 * b + 4.0 * c - d) * t2
			+ (-a + 3.0 * b - 3.0 * c + d) * t3)


func _point_at(dist: float) -> Vector3:
	var n := _along.size()
	if dist <= 0.0:
		return path[0]
	if dist >= _along[n - 1]:
		return path[n - 1]
	var i := _along.bsearch(dist)
	var t := (dist - _along[i - 1]) / maxf(_along[i] - _along[i - 1], 0.001)
	return path[i - 1].lerp(path[i], t)


# --- Phases -------------------------------------------------------------------

func _on_phase(p: Phase) -> void:
	match p:
		Phase.ACTIVE:
			_plan(true)
			pos = path[0]
			_travel = 0.0
			# Out of the open and under a roof, as in a storm (BTShelter).
			ctx.set_storm(true)
		Phase.ENDING:
			_sky_from = _sky
		Phase.DONE:
			ctx.set_storm(false)
			ctx.gale = Vector3.ZERO
			_sky = 0.0
			ctx.set_sky(0.0, SKY_SUN, SKY_TOP, SKY_HORIZON, SKY_SUN_MUL)
			ctx.set_weather(0.0, 1.0, 1.0)
			ctx.set_screen(0.0, 0.0)
			ctx.clear_hazard(HAZARD)
			_wind.stop()
			_roar.stop()
			_dust.emitting = false


func _tick_warning(_dt: float) -> void:
	var k := phase_t / warning_s
	_sky = k
	ctx.set_sky(k, SKY_SUN, SKY_TOP, SKY_HORIZON, SKY_SUN_MUL)
	_loop(_wind, lerpf(-40.0, -12.0, k))
	# Dust starts turning where it will form.
	_dust.emitting = k > 0.4
	_dust.amount_ratio = clampf((k - 0.4) * 1.6, 0.0, 1.0)
	_place_visuals()


func _tick_active(dt: float) -> void:
	_sky = 1.0
	ctx.set_sky(1.0, SKY_SUN, SKY_TOP, SKY_HORIZON, SKY_SUN_MUL)
	_form = minf(1.0, phase_t / FORM_S)
	strength = _form
	_walk(dt)
	_act(dt)


func _tick_ending(dt: float) -> void:
	var k := 1.0 - phase_t / ending_s
	_sky = _sky_from * k
	ctx.set_sky(_sky, SKY_SUN, SKY_TOP, SKY_HORIZON, SKY_SUN_MUL)
	strength = k
	_loop(_wind, lerpf(-40.0, -8.0, k))
	_walk(dt)
	_act(dt)


func _walk(dt: float) -> void:
	var before := pos
	_travel += speed * dt
	pos = _point_at(_travel)
	vel = (pos - before) / maxf(dt, 0.0001)
	var pl := ctx.player_pos()
	nearest_player = minf(nearest_player, Vector2(pl.x - pos.x, pl.z - pos.z).length())
	# Soldiers: the funnel, and where it will be in two seconds.
	var half := 14.0 * _size
	var here := AABB(pos - Vector3(half, 1.0, half), Vector3(half * 2.0, TOP, half * 2.0))
	var ahead := here
	ahead.position += vel * 2.0
	ctx.set_hazard(HAZARD, here.merge(ahead))
	_place_visuals()


func _act(dt: float) -> void:
	# Wind and dust, city-wide while it is on the ground.
	ctx.set_weather(strength, 0.9, 1.8, intensity)
	# Dust, thicker the nearer the funnel.
	var near := clampf(1.0 - Vector2(ctx.player_pos().x - pos.x, ctx.player_pos().z - pos.z).length() / 80.0, 0.0, 1.0)
	# Trees and buildings lean along its walk, harder the nearer it is.
	var heading := vel.normalized() if vel.length() > 0.1 else Vector3.RIGHT
	ctx.gale = heading * strength * (0.3 + 0.9 * near)
	ctx.set_screen(0.0, strength * (0.25 + 0.5 * near), Color(0.46, 0.46, 0.4))
	if strength <= 0.01:
		return
	_pull_pieces()
	_shove_pawns()
	_next_chip -= dt
	if _next_chip <= 0.0:
		_next_chip += CHIP_EVERY
		_strip_facades()
	_next_push -= dt
	if _next_push <= 0.0:
		_next_push += PUSH_EVERY
		_push_buildings()
	_tip_pushed()
	ctx.shake(pos, 0.035 * strength)


func _pull_pieces() -> void:
	var wake_now := Engine.get_physics_frames() % 15 == 0
	for isl in ctx.islands_near(pos, _lift_r + 10.0):
		if not isl.is_valid() or not is_instance_valid(isl.body):
			continue
		var body := isl.body
		var rel := body.global_position - pos
		var r := Vector2(rel.x, rel.z).length()
		if r > _lift_r or rel.y > TOP + 20.0:
			continue
		var bricks := ctx.piece_bricks(isl)
		if bricks <= 0 or bricks > _max_bricks:
			continue
		if isl.settled:
			if wake_now:
				ctx.hold_awake(isl, HOLD_MS)
			continue
		var f := strength * (1.0 - r / _lift_r)
		var flat := Vector3(rel.x, 0.0, rel.z)
		var inward := -flat.normalized() if r > 0.01 else Vector3.ZERO
		var swirl := Vector3(-rel.z, 0.0, rel.x).normalized() if r > 0.01 else Vector3.ZERO
		var want: Vector3
		if rel.y < TOP:
			want = (swirl * _spin + inward * INFLOW + Vector3.UP * _lift) * f
		else:
			# Out of the top: thrown clear, and it falls where it lands.
			want = (swirl * _spin * 0.5 - inward * FLING) * f + Vector3.DOWN * 2.0
		var k := clampf(LIFT_REF_BRICKS / float(bricks), 0.05, 1.0) * PULL
		var v := body.linear_velocity.lerp(want, k)
		var cap := IslandManager.MAX_DEBRIS_SPEED * 0.9
		if v.length() > cap:
			v = v.normalized() * cap
		body.linear_velocity = v
		body.sleeping = false
		pieces_pulled[isl.chunk] = true
		# In the wind it is slow at the top of its climb and touching nothing:
		# not at rest. It may not settle until the wind has let it go.
		ctx.hold_awake(isl, HOLD_MS)
		fastest_piece = maxf(fastest_piece, v.length())


## Put the wind to each standing building in reach; cut the one that gives.
func _push_buildings() -> void:
	var cap := maxi(1, int(round(MAX_PUSHED * intensity)))
	if pushed.size() >= cap:
		return
	var reach := _lift_r * PUSH_REACH
	for pair in ctx.buildings():
		var id: int = pair[0]
		var box: AABB = pair[1]
		var done := false
		for p in pushed:
			done = done or int(p.id) == id
		if done:
			continue
		# From the axis to the nearest point of the building's footprint.
		var near := Vector3(clampf(pos.x, box.position.x, box.end.x), 0.0,
				clampf(pos.z, box.position.z, box.end.z))
		var d := Vector2(near.x - pos.x, near.z - pos.z).length()
		if d > reach:
			continue
		var rel := box.get_center() - pos
		if Vector2(rel.x, rel.z).length() < 0.01:
			continue
		var swirl := Vector3(-rel.z, 0.0, rel.x).normalized()
		# Snapped to the building's grid: it tips over one of its edges.
		var dir := Vector3(signf(swirl.x), 0.0, 0.0) if absf(swirl.x) >= absf(swirl.z) \
				else Vector3(0.0, 0.0, signf(swirl.z))
		var accel := WIND_G * intensity * strength * (1.0 - d / reach)
		var r := ctx.lateral(id, accel, dir)
		if r.is_empty() or float(r.ratio) < 1.0 or not r.has("level"):
			continue
		var level: Vector3 = r.level
		if not ctx.sever(id, level):
			continue
		pushed.append({"id": id, "dir": dir, "t": phase_t, "piece": null,
				"box": AABB(Vector3(box.position.x, level.y, box.position.z),
						Vector3(box.size.x, box.end.y - level.y, box.size.z))})
		if pushed.size() >= cap:
			return


## Help each freed top over its downwind edge for Earthquake.PUSH_S.
func _tip_pushed() -> void:
	for p in pushed:
		if phase_t - float(p.t) > Earthquake.PUSH_S:
			continue
		var box: AABB = p.box
		if p.piece == null:
			var most := Earthquake.TOP_MIN_BRICKS - 1
			for isl in ctx.islands_near(box.get_center(), box.size.length()):
				if isl.is_valid() and is_instance_valid(isl.body) and ctx.piece_bricks(isl) > most:
					most = ctx.piece_bricks(isl)
					p.piece = isl
		var isl: BrickIsland = p.piece
		if isl != null and isl.is_valid() and is_instance_valid(isl.body):
			Earthquake.tip(isl, p.dir, box, intensity)


func _shove_pawns() -> void:
	for p in ctx.pawns():
		var rel := p.chest() - pos
		var r := Vector2(rel.x, rel.z).length()
		if r > _pawn_r:
			continue
		var f := strength * (1.0 - r / _pawn_r)
		var swirl := Vector3(-rel.z, 0.0, rel.x).normalized() if r > 0.01 else Vector3.ZERO
		var inward := -Vector3(rel.x, 0.0, rel.z).normalized() if r > 0.01 else Vector3.ZERO
		p.shove = (swirl * PAWN_SPIN * _size + inward * 2.0 + Vector3.UP * PAWN_LIFT * _size) * f
		pawns_shoved += 1


## A few rays out from the axis; whatever building face they meet inside the
## funnel loses its skin.
func _strip_facades() -> void:
	var n := int(round(rng.randi_range(4, 7) * _rays))
	for i in n:
		var ang := rng.randf() * TAU
		var h := rng.randf_range(0.5, 25.0)
		var tear := rng.randf() < SHEAR_SHARE
		var reach := (5.0 + h * 0.25) * _size + 2.0
		var from := pos + Vector3.UP * h
		var to := from + Vector3(cos(ang), 0.0, sin(ang)) * reach
		var hit := ctx.ray(from, to)
		if hit.is_empty() or ctx.building_at(hit.position) < 0:
			continue
		if tear and strength > 0.5:
			# A clump torn off whole: it becomes a piece, and the funnel has it.
			if ctx.shear(hit.position, _shear_r):
				shears += 1
				chips.append({"point": hit.position, "axis": pos})
			continue
		var hp := int(round(_chip_hp * strength))
		if hp <= 0:
			continue
		ctx.chip(hit.position, CHIP_RADIUS, hp)
		chips.append({"point": hit.position, "axis": pos})


# --- Look and sound -------------------------------------------------------------

func _place_visuals() -> void:
	var ground := pos
	_dust.global_position = ground + Vector3.UP * 0.5
	var form := _form if phase != Phase.ENDING else strength
	var showing := phase == Phase.ACTIVE or phase == Phase.ENDING
	_funnel.visible = showing and form > 0.02
	_orbit.visible = _funnel.visible
	if _funnel.visible:
		# Grows up out of the dust as it forms; thins and narrows as it ropes out.
		var wide := lerpf(0.3, 1.0, form) * _size
		_funnel.scale = Vector3(wide, maxf(form, 0.05), wide)
		_funnel.global_position = ground + Vector3.UP * 25.0 * maxf(form, 0.05)
		_funnel_mat.set_shader_parameter("density", 1.1 * form)
		_orbit.global_position = ground
		_orbit.scale = Vector3(_size, 1.0, _size) * maxf(form, 0.05)
	if _roar != null:
		_roar.global_position = ground + Vector3.UP * 5.0
		if showing and not _roar.playing:
			_roar.play()
		_roar.volume_db = lerpf(-30.0, 4.0, form if showing else 0.0)


func _loop(p: AudioStreamPlayer, db: float) -> void:
	p.volume_db = db
	if not p.playing:
		p.play()


func _build() -> void:
	_funnel_mat = ShaderMaterial.new()
	_funnel_mat.shader = load("res://shaders/disaster_funnel.gdshader")
	var cyl := CylinderMesh.new()
	cyl.top_radius = 16.0
	cyl.bottom_radius = 2.5
	cyl.height = 50.0
	cyl.radial_segments = 32
	cyl.rings = 12
	cyl.cap_top = false
	cyl.cap_bottom = false
	_funnel = MeshInstance3D.new()
	_funnel.mesh = cyl
	_funnel.material_override = _funnel_mat
	_funnel.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_funnel.visible = false
	add_child(_funnel)

	# Bricks caught up in it: one MultiMesh spun on the GPU.
	var brick := BoxMesh.new()
	brick.size = Vector3(0.7, 0.42, 1.4)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = brick
	mm.instance_count = 300
	var look := RandomNumberGenerator.new()
	look.seed = 0x70A
	var palette := [Color(0.8, 0.1, 0.1), Color(0.05, 0.3, 0.75), Color(0.95, 0.8, 0.1),
			Color(0.9, 0.9, 0.88), Color(0.15, 0.55, 0.2), Color(0.95, 0.45, 0.1),
			Color(0.35, 0.35, 0.37)]
	for i in mm.instance_count:
		mm.set_instance_transform(i, Transform3D())
		mm.set_instance_color(i, palette[look.randi() % palette.size()])
		mm.set_instance_custom_data(i, Color(look.randf_range(2.5, 13.0),
				look.randf_range(0.0, 40.0), look.randf() * TAU, look.randf_range(1.4, 3.4)))
	var orbit_mat := ShaderMaterial.new()
	orbit_mat.shader = load("res://shaders/disaster_orbit.gdshader")
	_orbit = MultiMeshInstance3D.new()
	_orbit.multimesh = mm
	_orbit.material_override = orbit_mat
	_orbit.custom_aabb = AABB(Vector3(-25, -2, -25), Vector3(50, 50, 50))
	_orbit.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_orbit.visible = false
	add_child(_orbit)

	# Dust turning at the foot.
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
	var dust_mat := StandardMaterial3D.new()
	dust_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	dust_mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	dust_mat.vertex_color_use_as_albedo = true
	dust_mat.albedo_texture = puff
	var quad := QuadMesh.new()
	quad.size = Vector2(5.0, 5.0)
	quad.material = dust_mat
	var proc := ParticleProcessMaterial.new()
	proc.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_RING
	proc.emission_ring_axis = Vector3.UP
	proc.emission_ring_radius = 9.0
	proc.emission_ring_inner_radius = 2.0
	proc.emission_ring_height = 1.0
	proc.direction = Vector3.UP
	proc.spread = 25.0
	proc.initial_velocity_min = 2.0
	proc.initial_velocity_max = 6.0
	proc.orbit_velocity_min = 0.25
	proc.orbit_velocity_max = 0.45
	proc.gravity = Vector3(0, -0.5, 0)
	proc.scale_min = 0.7
	proc.scale_max = 1.8
	var ramp := Gradient.new()
	ramp.offsets = PackedFloat32Array([0.0, 0.3, 1.0])
	ramp.colors = PackedColorArray([Color(0.45, 0.4, 0.34, 0.0), Color(0.42, 0.38, 0.33, 0.7),
			Color(0.4, 0.38, 0.35, 0.0)])
	var rt := GradientTexture1D.new()
	rt.gradient = ramp
	proc.color_ramp = rt
	_dust = GPUParticles3D.new()
	_dust.amount = 220
	_dust.lifetime = 3.0
	_dust.emitting = false
	_dust.process_material = proc
	_dust.draw_pass_1 = quad
	_dust.visibility_aabb = AABB(Vector3(-25, -3, -25), Vector3(50, 30, 50))
	add_child(_dust)

	_wind = AudioStreamPlayer.new()
	_wind.stream = DisasterSounds.wind()
	_wind.volume_db = -40.0
	add_child(_wind)
	_roar = AudioStreamPlayer3D.new()
	_roar.stream = DisasterSounds.rumble()
	_roar.unit_size = 25.0
	_roar.max_distance = 400.0
	_roar.volume_db = -30.0
	add_child(_roar)
