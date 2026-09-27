class_name Soldier
extends Node
## An infantry agent (Docs/AI.md 5, AIPlan P4): a Pawn with a gun and a brain.
##
## A component under the pawn's body, like Pawn itself. The BRAIN is a LimboAI
## tree (SoldierTree) whose tasks are thin: they read this node and the shared
## services and write the pawn's PawnIntents, never the body -- the same struct
## the player's keys fill. This node carries what every task needs:
##
##   * SENSING, 5 Hz, as a PERCEPTION job on the scheduler: sight of each enemy
##     (range, a cone, a physics ray, then AIWorld's smoke, which physics cannot
##     see) into the side's FactionKnowledge; noises arrive there too;
##   * THINKING, 10 Hz, as a TREES job: one update of the tree;
##   * AIM AND FIRE, every tick and never deferred (AI.md 10.1): the aim model
##     puts the error in where to point, and a round goes only if AIWorld says the
##     line to the target is clear this tick -- no shooting through a wall;
##   * MOVING, for the tasks: a path from AINav, requested through the queue,
##     followed a waypoint at a time, re-requested when the city changes under it
##     or the pawn stops getting anywhere.

const SENSE_HZ := 5.0
const THINK_HZ := 10.0
const SIGHT_RANGE := 60.0
const SIGHT_CONE_DEG := 70.0
## Close enough to feel someone behind you.
const NEAR_SENSE := 4.0
const WAYPOINT_REACHED := 0.35
const STUCK_SECONDS := 1.6
## Bursts: seconds on, seconds off.
const BURST_ON := 0.5
const BURST_OFF := 0.35

var services: AIServices
var pawn: Pawn
var brain: BTPlayer
var aim: AimModel
var team := 1
## Importance (AI.md 10.2), the priority of its jobs.
var importance := 5.0
## What the tree is doing, for overlays and gates.
var state := "idle"
## Set by the tasks: may the soldier fire at what it sees.
var fire_ok := false

## For gates: rounds fired, rounds fired with the line to the target blocked.
var shots := 0
var blocked_shots := 0
var peeks := 0

var _next_sense := -INF
var _next_think := -INF
var _last_think := 0.0
var _sense_queued := false
var _think_queued := false
var _goal := Vector3.INF
var _path_id := -1
var _path := PackedVector3Array()
var _wp := 0
var _repath := false
var _stuck_from := Vector3.ZERO
var _stuck_at := 0.0
var _burst_from := 0.0
var _aim_target: Pawn
var _dead := false


static func spawn(s: AIServices, parent: Node, feet: Vector3, p_team: int,
		gun: GunInstance) -> Soldier:
	var p := Pawn.spawn(parent, feet, p_team, true, 100.0)
	var so := Soldier.new()
	so.name = "Soldier"
	so.services = s
	so.pawn = p
	so.team = p_team
	so.aim = AimModel.new(s.rng)
	# Before the Pawn: intents are written, then the motor reads them.
	so.process_physics_priority = -5
	p.body.add_child(so)
	_greybox(p, p_team)
	var g := GunController.new()
	g.name = "Gun"
	g.aim = p.eye
	g.rng = s.rng
	g.exclude = [p.body.get_rid()] as Array[RID]
	g.on_structure_hit = s.on_structure_hit
	p.body.add_child(g)
	if gun != null:
		gun.visible = false
		p.eye.add_child(gun)
		g.equip(gun)
	p.gun = g
	g.fired.connect(so._on_fired)
	so.brain = BTPlayer.new()
	so.brain.name = "Brain"
	so.brain.update_mode = BTPlayer.MANUAL
	so.brain.behavior_tree = SoldierTree.build()
	so.brain.set_scene_root_hint(p.body)
	p.body.add_child(so.brain)
	s.pawns.append(p)
	s.ai_nav.nav_changed.connect(so._on_nav_changed)
	p.health.died.connect(so._on_died)
	return so


func is_dead() -> bool:
	return _dead


func knowledge() -> FactionKnowledge:
	return services.knowledge_of(team)


func contact() -> FactionKnowledge.Contact:
	return knowledge().best(services.now())


func eye_pos() -> Vector3:
	return pawn.eye.global_position


# --- the tick -------------------------------------------------------------------

func _physics_process(_delta: float) -> void:
	if _dead or pawn == null:
		return
	var now := services.now()
	if now >= _next_sense and not _sense_queued:
		_sense_queued = true
		services.sched.submit(AIScheduler.PERCEPTION, importance, _sense)
	if now >= _next_think and not _think_queued:
		_think_queued = true
		services.sched.submit(AIScheduler.TREES, importance, _think)
	_aim_and_fire(now)


func _sense() -> void:
	_sense_queued = false
	var now := services.now()
	_next_sense = now + 1.0 / (SENSE_HZ * services.sched.rate_scale(AIScheduler.PERCEPTION))
	var k := knowledge()
	for h in services.hostiles_of(team):
		if can_see(h):
			k.saw(h, h.feet(), now)
		else:
			k.lost_sight(h)


func _think() -> void:
	_think_queued = false
	var now := services.now()
	_next_think = now + 1.0 / (THINK_HZ * services.sched.rate_scale(AIScheduler.TREES))
	var dt := now - _last_think if _last_think > 0.0 else 1.0 / THINK_HZ
	_last_think = now
	brain.update(dt)


func can_see(h: Pawn) -> bool:
	var eye := eye_pos()
	var aim_at := h.chest()
	var d := eye.distance_to(aim_at)
	if d > SIGHT_RANGE:
		return false
	if d > NEAR_SENSE:
		var look := -Basis(Vector3.UP, pawn.intents.look_yaw).z
		var to := aim_at - eye
		to.y = 0.0
		if to.length() > 0.01 and rad_to_deg(look.angle_to(to.normalized())) > SIGHT_CONE_DEG:
			return false
	var q := PhysicsRayQueryParameters3D.create(eye, aim_at, Layers.HITSCAN_MASK,
			[pawn.body.get_rid(), h.body.get_rid()] as Array[RID])
	if not services.world3d.direct_space_state.intersect_ray(q).is_empty():
		return false
	# Physics cannot see smoke; AIWorld can.
	return not services.ai_world.smoke_blocks(eye, aim_at)


func _aim_and_fire(now: float) -> void:
	var c := contact()
	var it := pawn.intents
	if c != null and c.visible and c.pawn != null and is_instance_valid(c.pawn):
		_aim_target = c.pawn
		aim.track(c.pawn, now)
		var eye := eye_pos()
		var at := c.pawn.chest()
		var ang := aim.aim(eye, at, now)
		it.look_yaw = ang.x
		it.look_pitch = ang.y
		# The line has to be clear THIS tick -- sensing is 5 Hz, and a target
		# that stepped behind a wall 150 ms ago is behind a wall.
		var clear := services.ai_world.bricks_between(eye, at) == 0 \
				and not services.ai_world.smoke_blocks(eye, at)
		it.fire = fire_ok and clear and aim.ready_to_fire(now) and _burst(now)
	else:
		_aim_target = null
		aim.track(null, now)
		it.fire = false


func _burst(now: float) -> bool:
	var cycle := BURST_ON + BURST_OFF
	return fmod(now - _burst_from, cycle) < BURST_ON


func _on_fired(info: Dictionary) -> void:
	shots += 1
	# The gate's check, from the gun's side: was the line to what it was aimed
	# at clear when the round left?
	if _aim_target != null and is_instance_valid(_aim_target):
		if services.ai_world.bricks_between(eye_pos(), _aim_target.chest()) > 0:
			blocked_shots += 1
	services.noise(eye_pos(), 40.0, pawn)


# --- moving, for the tasks --------------------------------------------------------

## Walk to `goal`. 1 arrived, 0 on the way (or waiting for a path), -1 no way.
func move_to(goal: Vector3, run := false) -> int:
	var now := services.now()
	var nav := services.ai_nav
	if _goal == Vector3.INF or goal.distance_to(_goal) > 0.5 or _repath:
		_repath = false
		_goal = goal
		if _path_id >= 0:
			nav.release(_path_id)
		_path_id = nav.request_path(pawn.feet(), goal, importance, 20000)
		_path = PackedVector3Array()
		_wp = 0
		_stuck_from = pawn.feet()
		_stuck_at = now
	if _path.is_empty():
		var st := nav.get_status(_path_id)
		if st == AINav.PENDING:
			pawn.intents.move = Vector3.ZERO
			return 0
		if st != AINav.DONE:
			pawn.intents.move = Vector3.ZERO
			return -1
		_path = nav.get_path(_path_id)
		_wp = 1 if _path.size() > 1 else 0
	var feet := pawn.feet()
	while _wp < _path.size():
		var w: Vector3 = _path[_wp]
		if Vector2(w.x - feet.x, w.z - feet.z).length() > WAYPOINT_REACHED:
			break
		_wp += 1
	if _wp >= _path.size():
		pawn.intents.move = Vector3.ZERO
		return 1
	var next: Vector3 = _path[_wp]
	var dir := Vector3(next.x - feet.x, 0.0, next.z - feet.z)
	pawn.intents.move = dir.normalized() if dir.length() > 0.01 else Vector3.ZERO
	pawn.intents.run = run
	# Going nowhere: something is in the way that was not when the path was made.
	if feet.distance_to(_stuck_from) > 0.4:
		_stuck_from = feet
		_stuck_at = now
	elif now - _stuck_at > STUCK_SECONDS:
		_repath = true
	return 0


func stop() -> void:
	pawn.intents.move = Vector3.ZERO
	pawn.intents.run = false


## Point the head at something, when there is nothing in sight to aim at.
func look_at_point(p: Vector3) -> void:
	if _aim_target != null:
		return
	var to := p - eye_pos()
	pawn.intents.look_yaw = atan2(-to.x, -to.z)
	pawn.intents.look_pitch = clampf(atan2(to.y, Vector2(to.x, to.z).length()), -0.6, 0.6)


func _on_nav_changed(box: AABB) -> void:
	for i in range(_wp, _path.size()):
		if box.grow(0.5).has_point(_path[i] + Vector3.UP * 0.5):
			_repath = true
			return


func _on_died() -> void:
	_dead = true
	fire_ok = false
	pawn.intents.clear()
	pawn.intents.fire = false
	state = "dead"


static func _greybox(p: Pawn, p_team: int) -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.75, 0.25, 0.2) if p_team != 0 else Color(0.25, 0.45, 0.8)
	var body := MeshInstance3D.new()
	var cap := CapsuleMesh.new()
	cap.radius = Pawn.BODY_RADIUS
	cap.height = Pawn.BODY_HEIGHT
	body.mesh = cap
	body.material_override = mat
	p.body.add_child(body)
