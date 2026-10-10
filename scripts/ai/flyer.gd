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
##   DIVE    a bomber: straight at its target, under the clearance at the end,
##           and off it goes (Soldier's fuse and blast)
##
## Tiered like the others (AgentTier): SMART decides at THINK_HZ, DIRECTED at a
## third of it; it flies every tick either way.
##
## A flyer is a type from the roster like any other (set_type, Docs/AIRoster.md
## RO5): its name over it, its facts for the casebook, and -- when the casebook is
## the policy -- what it does next is the book's move, turned into a mode
## (BookCombatPolicy.decide_air). With no book it flies the fixed pattern above.
##
## A HOVER CRAFT (a recipe whose body is "hover"; AIRoster.md 7, R10) is the same
## agent, slower and higher, held to a LOITER area round where it was put: it
## circles inside it and makes slow attack passes, and a target outside the area
## is fought from its edge, never chased. Shot down, any flyer falls; a hover
## craft comes down with a crash (CRASH).

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

enum Mode { ORBIT, RUN, CLIMB, DIVE }
## The casebook is asked again after this long, drawn in this range.
const DECIDE_EVERY := [2.5, 4.5]
## A diving bomber may come under the clearance within this of its target.
const DIVE_LOW := 18.0
const DIVE_SPEED := 15.0
const TAG_ABOVE := 0.9
## A hover craft: how fast it circles and passes, how high, and the area it keeps.
const HOVER_SPEED := 6.0
const HOVER_RUN := 9.0
const HOVER_UP := 12.0
const LOITER := 40.0
## Coming down: gravity, and a hover craft's crash -- [damage, reach].
const FALL_G := 20.0
const CRASH := [90.0, 5.0]

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
## What it is (Roster): as a soldier has them (Soldier.set_type).
var type_id := ""
var type_facts: Array = []
var attack_kind := "shooter"
var role := "line"
var no_gun := false
var tier_cap := AgentTier.SMART
var name_tag: Label3D
var max_health := HEALTH
## The casebook's plan behind its mode, when the book decides.
var book := {}
## Which way round it circles: a flank is the other way.
var orbit_dir := 1.0
## A bomber's fuse and what its blast hurt, for gates.
var fuse_at := INF
var blast_hits: Array = []
var _went_off := false
var _decide_at := 0.0
## A hover craft (above), and the centre of the area it keeps.
var hover := false
var loiter_center := Vector3.INF
## Shot down and on the ground.
var crashed := false


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


## Make it the type `id` of `roster`: its facts, its name over it, its attack and
## the best brain it may run. (Health is the spawner's: UnitCatalog.apply_health.)
func set_type(id: String, roster: Roster) -> void:
	if roster == null or not roster.has(id):
		return
	type_id = id
	type_facts = roster.facts(id).duplicate()
	var d := roster.derived(id)
	attack_kind = str(d.get("attack", "shooter"))
	role = str(d.get("role", "line"))
	no_gun = attack_kind == "melee" or attack_kind == "bomber"
	max_health = health.total_current()
	if name_tag == null or not is_instance_valid(name_tag):
		name_tag = TypeKit.make_tag(body, TypeKit.tag_text(d), team, TAG_ABOVE)
	else:
		name_tag.text = TypeKit.tag_text(d)
	tier_cap = TypeKit.tier_cap(str(d.get("tier", "smart")))
	if tier_cap == AgentTier.DIRECTED and tier_hsm != null:
		tier_hsm.demote()
	hover = str(roster.recipe(id).get("body", "")) == "hover"
	if hover and loiter_center == Vector3.INF:
		loiter_center = body.global_position


## Keep it over `center` (a hover craft's loiter area).
func set_loiter(center: Vector3) -> void:
	loiter_center = center


## `p` brought inside the loiter area, if it has one.
func in_area(p: Vector3) -> Vector3:
	if not hover or loiter_center == Vector3.INF:
		return p
	var rel := Vector2(p.x - loiter_center.x, p.z - loiter_center.z)
	if rel.length() <= LOITER:
		return p
	rel = rel.normalized() * LOITER
	return Vector3(loiter_center.x + rel.x, p.y, loiter_center.z + rel.y)


func from_center() -> float:
	if loiter_center == Vector3.INF:
		return 0.0
	var p := body.global_position
	return Vector2(p.x - loiter_center.x, p.z - loiter_center.z).length()


## A bomber goes off: the blast, and it is gone.
func go_off() -> void:
	if _went_off:
		return
	_went_off = true
	fuse_at = INF
	blast_hits = Grenade.blast(services, body.global_position - Vector3.UP * 0.3, null,
			Soldier.BLAST_DAMAGE, Soldier.BLAST_RADIUS)
	health.apply_impact(1e9, &"")
	body.queue_free()


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
		_fall(delta)
		return
	var now := services.now()
	if now >= fuse_at:
		go_off()
		return
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
	# A bomber on its last stretch comes down to its target: nothing else may.
	if mode == Mode.DIVE and target != null and is_instance_valid(target) \
			and Vector2(p.x - target.feet().x, p.z - target.feet().z).length() < DIVE_LOW:
		# Steered every tick, not at the think's rate: at this speed a second-old
		# heading misses by metres.
		v = (target.chest() - p).normalized() * DIVE_SPEED
		body.velocity = body.velocity.lerp(v, clampf(delta * 6.0, 0.0, 1.0))
		body.move_and_slide()
		if p.distance_to(target.chest()) <= Soldier.DETONATE_REACH and fuse_at == INF:
			fuse_at = now + Soldier.FUSE
		return
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


## Shot down: it falls, and a hover craft hits the ground with a crash.
func _fall(delta: float) -> void:
	if crashed or _went_off or not is_instance_valid(body) or not body.is_inside_tree():
		return
	body.velocity.x *= 0.98
	body.velocity.z *= 0.98
	body.velocity.y -= FALL_G * delta
	body.move_and_slide()
	var p := body.global_position
	# Off the edge of the world: down, with nothing to crash on.
	if p.y < -60.0:
		crashed = true
		body.velocity = Vector3.ZERO
		return
	if body.get_slide_collision_count() > 0 or p.y - _top(p.x, p.z) < 0.7:
		crashed = true
		body.velocity = Vector3.ZERO
		if hover:
			blast_hits = Grenade.blast(services, p, null, CRASH[0], CRASH[1])


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
		# A hover craft with nothing to fight goes back over its area.
		if hover and from_center() > LOITER * 0.5:
			var home := loiter_center - p
			home.y = height_at(loiter_center) + HOVER_UP - p.y
			_want = home.normalized() * HOVER_SPEED
		return
	var t := target.feet()
	# What next: the casebook's, when it is the policy; a bomber with no book dives.
	if services.policy.has_method(&"decide_air"):
		# A dive is not thought better of.
		if now >= _decide_at and mode != Mode.CLIMB and mode != Mode.DIVE and (mode != Mode.RUN or now > _mode_until):
			_decide_at = now + services.rng.randf_range(DECIDE_EVERY[0], DECIDE_EVERY[1])
			mode = services.policy.call(&"decide_air", self, target, services.rng)
			_mode_until = now + (RUN_SECONDS * (1.6 if hover else 1.0) if mode == Mode.RUN else CLIMB_SECONDS)
			# A hover craft does not dive: it has no bomb to go off.
			if hover and mode == Mode.DIVE:
				mode = Mode.ORBIT
			if mode == Mode.RUN:
				var over := t - p
				over.y = 0.0
				_run_dir = over.normalized()
	elif attack_kind == "bomber":
		mode = Mode.DIVE
	match mode:
		Mode.DIVE:
			state = "dive"
			_want = (target.chest() - p).normalized() * DIVE_SPEED
		Mode.CLIMB:
			state = "climb"
			_want = Vector3.UP * (CLIMB_OUT / CLIMB_SECONDS) + (p - t).normalized() * 4.0
			if now > _mode_until:
				mode = Mode.ORBIT
		Mode.RUN:
			state = "run"
			var rs := HOVER_RUN if hover else RUN_SPEED
			var alt := maxf(height_at(p), height_at(p + _run_dir * rs)) + CLEARANCE + 3.0
			_want = _run_dir * rs + Vector3.UP * (alt - p.y) * 1.5
			# A pass that would take a hover craft out of its area is broken off.
			var next := p + _run_dir * rs * 1.5
			if hover and in_area(next) != next:
				_mode_until = now - 0.01
				_want = Vector3.ZERO
			if now > _mode_until:
				mode = Mode.ORBIT
				_next_run = now + RUN_EVERY
		Mode.ORBIT:
			state = "orbit"
			if not services.policy.has_method(&"decide_air") and now >= _next_run and _next_run > 0.0:
				mode = Mode.RUN
				_mode_until = now + RUN_SECONDS
				var across := t - p
				across.y = 0.0
				_run_dir = across.normalized()
				return
			if _next_run == 0.0:
				_next_run = now + RUN_EVERY
			var rel := Vector2(p.x - t.x, p.z - t.z)
			_orbit_angle = rel.angle() + 0.35 * orbit_dir
			var spot := in_area(t + Vector3(cos(_orbit_angle), 0.0, sin(_orbit_angle)) * ORBIT)
			spot.y = height_at(spot) + (HOVER_UP if hover else ORBIT_UP)
			var to := spot - p
			_want = to.normalized() * minf(HOVER_SPEED if hover else SPEED, to.length() * 2.0)


func _pick_target() -> Pawn:
	var c := services.knowledge_of(team).best(services.now())
	if c != null and c.pawn != null and is_instance_valid(c.pawn) and c.age(services.now()) < 5.0 \
			and c.pawn.health != null and not c.pawn.health.is_dead():
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
	if no_gun or target == null or not is_instance_valid(target) or mode == Mode.CLIMB:
		gun.set_trigger(false)
		return
	var from := body.global_position
	var at := MechLayers.aim_point(target, from)
	if from.distance_to(at) > 0.5:
		aim.look_at(at, Vector3.UP)
	var clear := services.ai_world.bricks_between(from, at) == 0 and from.distance_to(at) < 60.0
	gun.set_trigger(clear)


func _on_fired(_info: Dictionary) -> void:
	shots += 1
	if target != null and is_instance_valid(target) \
			and services.ai_world.bricks_between(body.global_position, target.chest()) > 0:
		blocked_shots += 1
