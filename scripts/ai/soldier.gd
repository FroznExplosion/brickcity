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
## Times it left cover because the cover was being shot away, and how many
## seconds the cover had left when it went.
var relocations := 0
var cover_left_with := -1.0

## Times in a row the current move has stopped getting anywhere and been
## re-pathed. A path the nav believes in and the body cannot follow comes back
## the same every time; a task watching this gives the goal up (MAX_STUCK).
var stuck := 0
const MAX_STUCK := 2

## The engage decision (CombatPolicy): the tactic it is carrying out, when it
## was chosen, and until when it is held unless something happens. `tactic_done`
## is set by a task that finished it or could not do it: decide again.
var tactic := -1
var tactic_at := -INF
var tactic_until := -INF
var tactic_done := false
## Health it has at full, when it was last hurt, and what it had then.
var max_health := 100.0
var hurt_at := -INF
var _hp_seen := -1.0
## When its gun last fired, and the damage its rounds have done in all.
var last_shot_at := -INF
var dealt := 0.0
## A buddy's call for help: where to go, and until when it is worth going.
var help_point := Vector3.INF
var help_until := -INF
var _called_help_at := -INF
## Seconds between calls for help from the same soldier.
const HELP_EVERY := 8.0
## How far a call for help carries to its own side.
const HELP_RANGE := 30.0
const HELP_LINES: Array[String] = ["I'm stuck! Somebody get over here!",
		"Can't get through -- need help!", "I'm pinned in here, cover me!",
		"No way out this side! Help!"]

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
	so.max_health = 100.0
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
			k.saw(h, h.feet(), now, self)
		else:
			k.lost_sight(h, self)


func _think() -> void:
	_think_queued = false
	var now := services.now()
	_next_think = now + 1.0 / (THINK_HZ * services.sched.rate_scale(AIScheduler.TREES))
	var dt := now - _last_think if _last_think > 0.0 else 1.0 / THINK_HZ
	_last_think = now
	var hp := pawn.health.total_current()
	if _hp_seen >= 0.0 and hp < _hp_seen:
		hurt_at = now
	_hp_seen = hp
	brain.update(dt)
	if services.judge != null:
		services.judge.watch(self, dt)


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
	# The ground has colliders only where the terrain's detail tier is; the
	# field is everywhere, so a hill out past the city still hides a body
	# (Docs/Terrain.md §21.7). Free when there is no terrain.
	if services.ai_world.ground_blocks(eye, aim_at):
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
		# And from where the eye will be when the gun steps: on the move, the
		# round leaves a tick later from a hand's breadth on -- past a wall's edge.
		var next_eye := eye + pawn.body.velocity / float(Engine.physics_ticks_per_second)
		var clear := services.ai_world.bricks_between(eye, at) == 0 \
				and services.ai_world.bricks_between(next_eye, at) == 0 \
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
	last_shot_at = services.now()
	if not info.is_empty() and info.get("result") != null:
		dealt += (info.result as DamageSystem.DamageResult).dealt
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
		stuck = 0
	elif now - _stuck_at > STUCK_SECONDS:
		_repath = true
		stuck += 1
		if stuck >= MAX_STUCK:
			call_for_help()
	return 0


## Stuck: shout for help (AI.md 6.5), and the side's soldiers in earshot who
## are not in a fight of their own come to it.
func call_for_help() -> void:
	var now := services.now()
	if now - _called_help_at < HELP_EVERY:
		return
	_called_help_at = now
	services.say(pawn, "stuck", HELP_LINES[services.rng.randi() % HELP_LINES.size()],
			AIServices.SHOUT)
	for ally in allies():
		if ally.pawn.feet().distance_to(pawn.feet()) <= HELP_RANGE and ally.state in ["idle", "search"]:
			ally.help_point = pawn.feet()
			ally.help_until = now + 20.0


## The other living soldiers of its side.
func allies() -> Array[Soldier]:
	var out: Array[Soldier] = []
	for p in services.pawns:
		if not is_instance_valid(p) or p == pawn or p.team != team:
			continue
		var so := p.body.get_node_or_null(^"Soldier") as Soldier
		if so != null and not so.is_dead():
			out.append(so)
	return out


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
	if services.judge != null:
		services.judge.close(self, "died")
	knowledge().forget_seer(self)
	# Somebody near says so.
	for ally in allies():
		if ally.pawn.feet().distance_to(pawn.feet()) < 25.0:
			services.say(ally.pawn, "man_down", ["Man down!", "We lost one!", "Man down, man down!"][
					services.rng.randi() % 3], AIServices.SHOUT)
			break
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
