class_name Flyer
extends Node
## A flyer (Docs/AI.md 5.2; AIPlan P8): a drone that moves on the HEIGHT FIELD --
## the highest thing under it, from AIWorld's bricks (top_at) -- never through a
## building, never lower than CLEARANCE over whatever it is over:
##
##   ORBIT   round its target at ORBIT metres, ORBIT_UP over the height field,
##           shooting when the line is clear
##   RUN     every RUN_EVERY seconds a strafing run: a straight line over the
##           target, low, fast, firing
##   CLIMB   hit: straight up CLIMB_OUT metres, out of the fight for a moment
##
## Tiered like the others (AgentTier): SMART decides at THINK_HZ, DIRECTED at a
## third of it; it flies every tick either way.

const THINK_HZ := 5.0
const DIRECTED_THINK_HZ := 1.5
const CLEARANCE := 5.0
const ORBIT := 22.0
const ORBIT_UP := 9.0
const SPEED := 11.0
const RUN_SPEED := 17.0
const RUN_EVERY := 10.0
const RUN_SECONDS := 3.5
const CLIMB_OUT := 10.0
const CLIMB_SECONDS := 2.0
const SIGHT := 120.0
## The height field is sampled over a patch this wide round the flyer, and this
## many seconds of flight ahead of it: it climbs before a building, not into one.
const SAMPLE := 3.0
const LOOK_AHEAD := 1.2
const HEALTH := 150.0

enum Mode { ORBIT, RUN, CLIMB }

var services: AIServices
var body: CharacterBody3D
var health: HealthPool
var gun: GunController
var aim: Node3D
var team := 1
var tier: int = AgentTier.SMART
var tier_hsm: AgentTier
var swarm_born := false
var mode := Mode.ORBIT
var target: Pawn
var state := "orbit"
## For gates: the lowest it has been over the height field, and shots.
var lowest_clearance := INF
var shots := 0
var blocked_shots := 0

var _next_think := -INF
var _queued := false
var _want := Vector3.ZERO
var _mode_until := 0.0
var _next_run := 0.0
var _run_dir := Vector3.FORWARD
var _orbit_angle := 0.0
var _hp_seen := -1.0


static func spawn(s: AIServices, parent: Node, at: Vector3, p_team: int, g: GunInstance,
		start_tier := AgentTier.SMART) -> Flyer:
	var b := CharacterBody3D.new()
	b.name = "FlyerBody"
	b.collision_layer = Layers.PAWN
	b.collision_mask = Layers.WORLD | Layers.STRUCTURE
	b.motion_mode = CharacterBody3D.MOTION_MODE_FLOATING
	var sh := CollisionShape3D.new()
	var sp := SphereShape3D.new()
	sp.radius = 0.6
	sh.shape = sp
	b.add_child(sh)
	var f := Flyer.new()
	f.name = "Flyer"
	f.services = s
	f.body = b
	f.team = p_team
	b.add_child(f)
	var pool := HealthPool.new()
	pool.name = "HealthPool"
	var layer := DefenseLayer.new()
	layer.max_value = HEALTH
	pool.layer_configs = [layer]
	b.add_child(pool)
	f.health = pool
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(1.4, 0.35, 1.4)
	mi.mesh = bm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.3, 0.3, 0.35)
	mi.material_override = mat
	b.add_child(mi)
	f.aim = Node3D.new()
	f.aim.name = "Aim"
	b.add_child(f.aim)
	f.gun = GunController.new()
	f.gun.name = "Gun"
	f.gun.aim = f.aim
	f.gun.rng = s.rng
	f.gun.exclude = [b.get_rid()] as Array[RID]
	f.gun.on_structure_hit = s.on_structure_hit
	b.add_child(f.gun)
	if g != null:
		g.visible = false
		f.aim.add_child(g)
		f.gun.equip(g)
	f.gun.fired.connect(f._on_fired)
	parent.add_child(b)
	b.global_position = at
	f.tier_hsm = AgentTier.attach(f, start_tier)
	return f


func set_tier(t: int) -> void:
	tier = t


func is_dead() -> bool:
	return health == null or health.is_dead()


func budget_pos() -> Vector3:
	return body.global_position


func budget_bonus(_now: float) -> float:
	return 20.0 if mode == Mode.RUN else 10.0


## The top of what is under `p`, over a patch round it: the ground, the tallest
## brick, whichever is higher.
func height_at(p: Vector3) -> float:
	var h := services.ai_world.ground_at(p.x, p.z) if services.ai_world.get_terrain_ground() else 0.0
	for dx in [-SAMPLE, 0.0, SAMPLE]:
		for dz in [-SAMPLE, 0.0, SAMPLE]:
			var t := services.ai_world.top_at(p.x + dx, p.z + dz)
			if is_finite(t):
				h = maxf(h, t)
	return h


## The top of what is straight under (x, z): the ground or a brick.
func _top(x: float, z: float) -> float:
	var h := services.ai_world.ground_at(x, z) if services.ai_world.get_terrain_ground() else 0.0
	var t := services.ai_world.top_at(x, z)
	return maxf(h, t) if is_finite(t) else h


func _physics_process(delta: float) -> void:
	if is_dead():
		gun.set_trigger(false)
		return
	var now := services.now()
	if now >= _next_think and not _queued:
		_queued = true
		services.sched.submit(AIScheduler.TREES, 5.0, _think)
	var p := body.global_position
	# What it is over, for the gate: straight down.
	lowest_clearance = minf(lowest_clearance, p.y - _top(p.x, p.z))
	# Never below CLEARANCE over the height field -- round it and ahead of it --
	# whatever it wants.
	var ahead := p + Vector3(body.velocity.x, 0.0, body.velocity.z) * LOOK_AHEAD
	var floor_h := maxf(height_at(p), height_at(ahead))
	var v := _want
	var min_y := floor_h + CLEARANCE
	if p.y < min_y + 0.5:
		v.y = maxf(v.y, (min_y + 1.0 - p.y) * 3.0)
		# Too low for what is ahead: hold off until it has climbed.
		if p.y < min_y - 0.5:
			v.x *= 0.2
			v.z *= 0.2
	body.velocity = body.velocity.lerp(v, clampf(delta * 3.0, 0.0, 1.0))
	# The floor is hard: under it, it climbs NOW, not as the velocity eases round.
	if p.y < min_y + 1.0:
		body.velocity.y = maxf(body.velocity.y, (min_y + 1.5 - p.y) * 4.0)
	body.move_and_slide()
	_fire()


func _think() -> void:
	_queued = false
	var now := services.now()
	var hz := THINK_HZ if tier == AgentTier.SMART else DIRECTED_THINK_HZ
	_next_think = now + 1.0 / (hz * services.sched.rate_scale(AIScheduler.TREES))
	var hp := health.total_current()
	if _hp_seen >= 0.0 and hp < _hp_seen and mode != Mode.CLIMB:
		mode = Mode.CLIMB
		_mode_until = now + CLIMB_SECONDS
	_hp_seen = hp
	target = _pick_target()
	var p := body.global_position
	if target == null:
		state = "patrol"
		_want = Vector3.ZERO
		return
	var t := target.feet()
	match mode:
		Mode.CLIMB:
			state = "climb"
			_want = Vector3.UP * (CLIMB_OUT / CLIMB_SECONDS) + (p - t).normalized() * 4.0
			if now > _mode_until:
				mode = Mode.ORBIT
		Mode.RUN:
			state = "run"
			var alt := maxf(height_at(p), height_at(p + _run_dir * RUN_SPEED)) + CLEARANCE + 3.0
			_want = _run_dir * RUN_SPEED + Vector3.UP * (alt - p.y) * 1.5
			if now > _mode_until:
				mode = Mode.ORBIT
				_next_run = now + RUN_EVERY
		Mode.ORBIT:
			state = "orbit"
			if now >= _next_run and _next_run > 0.0:
				mode = Mode.RUN
				_mode_until = now + RUN_SECONDS
				var across := t - p
				across.y = 0.0
				_run_dir = across.normalized()
				return
			if _next_run == 0.0:
				_next_run = now + RUN_EVERY
			var rel := Vector2(p.x - t.x, p.z - t.z)
			_orbit_angle = rel.angle() + 0.35
			var spot := t + Vector3(cos(_orbit_angle), 0.0, sin(_orbit_angle)) * ORBIT
			spot.y = height_at(spot) + ORBIT_UP
			var to := spot - p
			_want = to.normalized() * minf(SPEED, to.length() * 2.0)


func _pick_target() -> Pawn:
	var c := services.knowledge_of(team).best(services.now())
	if c != null and c.pawn != null and is_instance_valid(c.pawn) and c.age(services.now()) < 5.0:
		return c.pawn
	var best: Pawn = null
	var best_d := SIGHT
	for h in services.hostiles_of(team):
		var d := h.feet().distance_to(body.global_position)
		if d < best_d and services.ai_world.bricks_between(body.global_position, h.chest()) == 0:
			best = h
			best_d = d
	if best != null:
		services.knowledge_of(team).saw(best, best.feet(), services.now(), self)
	return best


func _fire() -> void:
	if target == null or not is_instance_valid(target) or mode == Mode.CLIMB:
		gun.set_trigger(false)
		return
	var from := body.global_position
	var at := target.chest()
	if from.distance_to(at) > 0.5:
		aim.look_at(at, Vector3.UP)
	var clear := services.ai_world.bricks_between(from, at) == 0 and from.distance_to(at) < 60.0
	gun.set_trigger(clear)


func _on_fired(_info: Dictionary) -> void:
	shots += 1
	if target != null and is_instance_valid(target) \
			and services.ai_world.bricks_between(body.global_position, target.chest()) > 0:
		blocked_shots += 1
