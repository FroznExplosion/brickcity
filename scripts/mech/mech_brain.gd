class_name MechBrain
extends Node
## A mech that fights on its own (Docs/AI.md 2.1, 5.2, 6.4; AIPlan P7): the enemy's
## mech, and the player's once the pilot is out of it. The brain half of the titan
## contract -- it fills the same TitanIntents the pilot's keys do (MechPilot), so a
## mech moves the same whoever drives.
##
##   SENSING, 5 Hz, a PERCEPTION job: hostiles in sight of the cockpit -- range, a
##     cone, a physics ray, AIWorld's smoke -- into the side's FactionKnowledge;
##   THINKING, 10 Hz, a TREES job: the tree (MechTree) chooses where to go and
##     whether to breach;
##   FIRING, every tick and never deferred: the arm at the nearest hostile it can
##     see with a clear line -- never through a wall, never with a friend in the
##     way. Both brains fight back, whatever their order (AI.md 2.1);
##   MOVING on the MECH MAP: an AINav with a mech's footprint, height and step
##     (AIPlan R8), so a path never asks it through a doorway or under a floor.
##
## A breach is the launcher's (a second gun on the arm, ordnance): rounds into the
## first brick between the mech and infantry it knows are in there, until the line
## is open. Structure goes through the owner's `on_structure_hit` -- in the city,
## the authority -- like any gun's.

enum Order { NONE, FOLLOW, HOLD, ATTACK_AREA }

const SENSE_HZ := 5.0
const THINK_HZ := 10.0
const SIGHT_RANGE := 150.0
const SIGHT_CONE_DEG := 100.0
## The pilot's band when following (BoomerBorder's): closer than FOLLOW_NEAR it
## stops, further than FOLLOW_FAR it comes.
const FOLLOW_NEAR := 5.0
const FOLLOW_FAR := 8.0
const WAYPOINT_REACHED := 1.0
const STUCK_SECONDS := 2.0
## How far off the arm may point and still fire.
const FIRE_CONE_DEG := 4.0

var services: AIServices
var mech: Mech
var nav: AINav
var team := 1
var brain: BTPlayer
var importance := 8.0
## A second gun, for walls: ordnance. Null for none.
var launcher: GunController
## Off while a pilot has the controls: the pilot's keys fill the intents.
var enabled := true
## What the tree is doing, for gates and overlays.
var state := "idle"
## The player's mech: its order, where, and whom it follows.
var order := Order.NONE
var order_point := Vector3.ZERO
var leader: Pawn
## For gates.
var shots := 0
var blocked_shots := 0
var launched := 0

var _next_sense := -INF
var _next_think := -INF
var _last_think := 0.0
var _sense_queued := false
var _think_queued := false
var _target: Pawn
## Where the launcher is to put its rounds (a breach), or INF.
var breach_point := Vector3.INF
var _want_dir := Vector3.ZERO
var _goal := Vector3.INF
var _path_id := -1
var _path := PackedVector3Array()
var _wp := 0
var _stuck_from := Vector3.ZERO
var _stuck_at := 0.0


## Give `m` a brain: `tree` is MechTree.enemy() or MechTree.companion().
static func attach(s: AIServices, m: Mech, p_mech_nav: AINav, tree: BehaviorTree, p_team: int) -> MechBrain:
	var br := MechBrain.new()
	br.name = "MechBrain"
	br.services = s
	br.mech = m
	br.nav = p_mech_nav
	br.team = p_team
	m.team = p_team
	# Before the motor (-10): intents are written, then read.
	br.process_physics_priority = -12
	m.body.add_child(br)
	br.brain = BTPlayer.new()
	br.brain.name = "Brain"
	br.brain.update_mode = BTPlayer.MANUAL
	br.brain.behavior_tree = tree
	br.brain.set_scene_root_hint(m.body)
	m.body.add_child(br.brain)
	m.gun.fired.connect(br._on_fired)
	m.health.died.connect(func() -> void:
		br.mech.intents.clear(br.mech.motor.torso_yaw)
		br.mech.gun.set_trigger(false)
		br.state = "dead")
	return br


## The mech map's numbers for a mech: its footprint in studs, its height and its
## step in plates, and a drop no further than a storey's worth of fall rule.
static func mech_nav(ai_world: AIWorld) -> AINav:
	var n := AINav.new()
	n.set_ai_world(ai_world)
	var span := int(round(Mech.RADIUS * 2.0 / Mech.STUD))
	var head := int(ceil(Mech.HEIGHT / 0.14))
	n.set_agent(span, head, head, 9, 17, 17)
	return n


## A launcher on the arm: ordnance, for walls.
func arm_launcher(gun: GunInstance, rng: RandomNumberGenerator, on_hit: Callable) -> void:
	launcher = GunController.new()
	launcher.name = "Launcher"
	launcher.aim = mech.muzzle
	launcher.rng = rng
	launcher.exclude = [mech.body.get_rid()] as Array[RID]
	launcher.on_structure_hit = on_hit
	mech.body.add_child(launcher)
	gun.visible = false
	mech.arm.add_child(gun)
	launcher.equip(gun)
	launcher.fired.connect(func(_i: Dictionary) -> void: launched += 1)


func is_dead() -> bool:
	return mech.health.is_dead()


func knowledge() -> FactionKnowledge:
	return services.knowledge_of(team)


func contact() -> FactionKnowledge.Contact:
	return knowledge().best(services.now())


func eye() -> Vector3:
	return mech.body.global_position + Vector3.UP * (Mech.COCKPIT_Y - Mech.HEIGHT * 0.5)


# --- the tick -------------------------------------------------------------------

func _physics_process(_delta: float) -> void:
	if is_dead() or not enabled:
		return
	var now := services.now()
	if now >= _next_sense and not _sense_queued:
		_sense_queued = true
		services.sched.submit(AIScheduler.PERCEPTION, importance, _sense)
	if now >= _next_think and not _think_queued:
		_think_queued = true
		services.sched.submit(AIScheduler.TREES, importance, _think)
	_steer()
	_fire(now)


func _sense() -> void:
	_sense_queued = false
	var now := services.now()
	_next_sense = now + 1.0 / (SENSE_HZ * services.sched.rate_scale(AIScheduler.PERCEPTION))
	var k := knowledge()
	for h in services.hostiles_of(team):
		if can_see(h):
			k.saw(h, h.feet(), now, self)
		else:
			k.lost_sight(h, self)


func _think() -> void:
	_think_queued = false
	var now := services.now()
	_next_think = now + 1.0 / (THINK_HZ * services.sched.rate_scale(AIScheduler.TREES))
	var dt := now - _last_think if _last_think > 0.0 else 1.0 / THINK_HZ
	_last_think = now
	brain.update(dt)


func can_see(h: Pawn) -> bool:
	var e := eye()
	var at := h.chest()
	if e.distance_to(at) > SIGHT_RANGE:
		return false
	var look := -Basis(Vector3.UP, mech.motor.torso_yaw).z
	var to := at - e
	to.y = 0.0
	if to.length() > 6.0 and rad_to_deg(look.angle_to(to.normalized())) > SIGHT_CONE_DEG:
		return false
	var ex: Array[RID] = [mech.body.get_rid(), h.body.get_rid()]
	for p in [at, h.eye.global_position]:
		var q := PhysicsRayQueryParameters3D.create(e, p, Layers.HITSCAN_MASK, ex)
		if services.world3d.direct_space_state.intersect_ray(q).is_empty() \
				and not services.ai_world.smoke_blocks(e, p):
			return true
	return false


## The hostile to shoot now: seen by this mech, a clear line from the muzzle.
func _pick_target() -> Pawn:
	var best: Pawn = null
	var best_d := INF
	var from := mech.muzzle.global_position
	var k := knowledge()
	for h in services.hostiles_of(team):
		var c := k.of(h)
		if c == null or not c.seen_by.has(get_instance_id()):
			continue
		if services.ai_world.bricks_between(from, h.chest()) > 0:
			continue
		var d := from.distance_to(h.chest())
		if d < best_d:
			best_d = d
			best = h
	return best


func _fire(_now: float) -> void:
	var it := mech.intents
	_target = _pick_target()
	var aim_at := Vector3.INF
	if _target != null:
		aim_at = _target.chest()
	elif breach_point != Vector3.INF:
		aim_at = breach_point
	if aim_at == Vector3.INF:
		mech.aim_point = Vector3.INF
		mech.gun.set_trigger(false)
		if launcher != null:
			launcher.set_trigger(false)
		return
	mech.aim_point = aim_at
	var to := aim_at - eye()
	it.aim_yaw = atan2(-to.x, -to.z)
	it.aim_pitch = atan2(to.y, Vector2(to.x, to.z).length())
	# Only when the arm is on it.
	var fwd := -mech.muzzle.global_transform.basis.z
	var want := (aim_at - mech.muzzle.global_position).normalized()
	var on := rad_to_deg(fwd.angle_to(want)) <= FIRE_CONE_DEG
	var from := mech.muzzle.global_position
	var friend := _friend_in_line(from, aim_at)
	if _target != null:
		mech.gun.set_trigger(on and not friend and services.ai_world.bricks_between(from, aim_at) == 0)
		if launcher != null:
			launcher.set_trigger(false)
	else:
		mech.gun.set_trigger(false)
		if launcher != null:
			launcher.set_trigger(on and not friend)


func _friend_in_line(from: Vector3, at: Vector3) -> bool:
	var d := from.distance_to(at)
	for p in services.pawns:
		if not is_instance_valid(p) or p.team != team or p.health == null or p.health.is_dead():
			continue
		var ch := p.chest()
		if from.distance_to(ch) > d + 2.0:
			continue
		if ch.distance_to(Geometry3D.get_closest_point_to_segment(ch, from, at)) < 1.5:
			return true
	return false


func _on_fired(_info: Dictionary) -> void:
	shots += 1
	if _target != null and is_instance_valid(_target) \
			and services.ai_world.bricks_between(mech.muzzle.global_position, _target.chest()) > 0:
		blocked_shots += 1


# --- moving, on the mech map ----------------------------------------------------------

## Walk to `goal`. 1 arrived, 0 on the way (or waiting for a path), -1 no way.
func move_to(goal: Vector3, run := false) -> int:
	var now := services.now()
	if _goal == Vector3.INF or goal.distance_to(_goal) > 1.5:
		_goal = goal
		if _path_id >= 0:
			nav.release(_path_id)
		_path_id = nav.request_path(mech.feet(), goal, importance, 30000)
		_path = PackedVector3Array()
		_wp = 0
		_stuck_from = mech.feet()
		_stuck_at = now
	if _path.is_empty():
		var st := nav.get_status(_path_id)
		if st == AINav.PENDING:
			_want_dir = Vector3.ZERO
			return 0
		if st != AINav.DONE:
			_want_dir = Vector3.ZERO
			return -1
		_path = nav.get_path(_path_id)
		_wp = 1 if _path.size() > 1 else 0
	var feet := mech.feet()
	while _wp < _path.size():
		var w: Vector3 = _path[_wp]
		if Vector2(w.x - feet.x, w.z - feet.z).length() > WAYPOINT_REACHED:
			break
		_wp += 1
	if _wp >= _path.size():
		_want_dir = Vector3.ZERO
		return 1
	var next: Vector3 = _path[_wp]
	var dir := Vector3(next.x - feet.x, 0.0, next.z - feet.z)
	_want_dir = dir.normalized() if dir.length() > 0.01 else Vector3.ZERO
	mech.intents.sprint = run
	if feet.distance_to(_stuck_from) > 0.6:
		_stuck_from = feet
		_stuck_at = now
	elif now - _stuck_at > STUCK_SECONDS:
		_goal = Vector3.INF
	return 0


func stop() -> void:
	_want_dir = Vector3.ZERO
	mech.intents.sprint = false


## Face `p` with the torso when there is nothing to shoot.
func face(p: Vector3) -> void:
	if _target != null or breach_point != Vector3.INF:
		return
	var to := p - mech.feet()
	if Vector2(to.x, to.z).length() > 0.5:
		mech.intents.aim_yaw = atan2(-to.x, -to.z)


## The wanted world direction, as the motor wants it: torso-local, every tick, as
## the torso turns under it.
func _steer() -> void:
	var it := mech.intents
	if _want_dir == Vector3.ZERO:
		it.move_dir = Vector2.ZERO
		return
	var b := Basis(Vector3.UP, mech.motor.torso_yaw)
	it.move_dir = Vector2(_want_dir.dot(b.x), -_want_dir.dot(b.z))
	# Nothing to shoot: face where it is going.
	if _target == null and breach_point == Vector3.INF:
		it.aim_yaw = atan2(-_want_dir.x, -_want_dir.z)
