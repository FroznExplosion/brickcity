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
##
## In a SQUAD (P6) it also carries the squad's Assignment and answers it with
## Status; a MASKED move is held, every physics tick, whenever Masking says the
## enemy could see it go; a SUPPRESS point is fired at when there is nothing to
## aim at; and it fires at a target only while it holds one of the target's
## attack tokens, never with a squadmate in the line.

const SENSE_HZ := 5.0
const THINK_HZ := 10.0
const SIGHT_RANGE := 60.0
const SIGHT_CONE_DEG := 70.0
## Close enough to feel someone behind you.
const NEAR_SENSE := 4.0
const WAYPOINT_REACHED := 0.35
## How far above or below a waypoint still counts as at it: more than a step
## up (0.42 m), less than any drop that matters.
const WAYPOINT_LEVEL := 1.0
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
## Times it was pinned for good and put on the nearest free spot (_unstick).
var unsticks := 0

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
## Cover given up on -- no way there, or shot through -- as [spot, until]: not
## to be taken again for BAD_COVER_SECONDS (CoverSearch.find_for).
var bad_cover: Array = []
const BAD_COVER_SECONDS := 10.0
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
## No way anywhere, several times running: cut off (see _path_failed).
var trapped := false
const TRAP_FAILS := 3
const TRAP_WINDOW := 10.0
const TRAP_RETRY := 5.0
var _fails: Array[float] = []
var _trap_retry_at := 0.0
var _trapped_since := 0.0
var _duck_until := 0.0
var _ducking := false
## Its squad (P6), when it has one, and what the squad has told it to do.
var squad: Squad
var assignment: SquadMsg.Assignment
## Set by the assignment task: the current move goes only while masked.
var masked_move := false
## Fire at this when there is no target in sight (suppression). INF: none.
var suppress_point := Vector3.INF
## Why the last masked-move check let it go, "" if it did not (Masking).
var mask_state := ""
## For gates: ticks a masked move was held, metres moved while it should have
## been, metres moved while masked.
var held_ticks := 0
var unmasked_moved := 0.0
var masked_moved := 0.0
var friendly_holds := 0
var _want_move := Vector3.ZERO
var _was_held := false
## Ticks in a row it has been held: the first is the tick the hold was decided,
## and the body's step for it was already under way (_measure_masked).
var _held_ticks_run := 0
var _was_masked_moving := false
var _last_feet := Vector3.INF
var _replied := {}

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
	# Nobody crouches (A21), whatever a task, a play or a duck asks for.
	p.no_crouch = true
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
	g.reload_started.connect(so._on_reload)
	so.brain = BTPlayer.new()
	so.brain.name = "Brain"
	so.brain.update_mode = BTPlayer.MANUAL
	so.brain.behavior_tree = SoldierTree.build()
	so.brain.set_scene_root_hint(p.body)
	p.body.add_child(so.brain)
	s.add_pawn(p)
	s.ai_nav.nav_changed.connect(so._on_nav_changed)
	p.health.died.connect(so._on_died)
	return so


func is_dead() -> bool:
	return _dead


func knowledge() -> FactionKnowledge:
	return services.knowledge_of(team)


func contact() -> FactionKnowledge.Contact:
	return knowledge().best(services.now())


## This soldier has `c` in its own sight (not only somebody on its side).
func sees(c: FactionKnowledge.Contact) -> bool:
	return c != null and c.visible and c.seen_by.has(get_instance_id())


## The squad's order for this soldier, or null to fight on its own.
func set_assignment(a: SquadMsg.Assignment) -> void:
	assignment = a
	if a == null:
		masked_move = false
		suppress_point = Vector3.INF


## Reply to the current assignment -- once per kind.
func report(kind: int) -> void:
	if assignment == null or squad == null:
		return
	var key := assignment.id * 8 + kind
	if _replied.has(key):
		return
	_replied[key] = true
	squad.on_status(self, assignment.id, kind)


func eye_pos() -> Vector3:
	return pawn.eye.global_position


# --- the tick -------------------------------------------------------------------

func _physics_process(_delta: float) -> void:
	if _dead or pawn == null:
		return
	var now := services.now()
	# Ducking (duck()): low, whatever the task wants, until it is over.
	if now < _duck_until:
		# The one crouch let through (A21 says nobody crouches): a duck from a
		# lightning stroke (Docs/Collapse.md), the disasters area's -- a rule
		# for the two to settle, not one to break silently.
		pawn.no_crouch = false
		pawn.intents.crouch = true
	elif _ducking:
		_ducking = false
		pawn.intents.crouch = false
		pawn.no_crouch = true
	if now >= _next_sense and not _sense_queued:
		_sense_queued = true
		services.sched.submit(AIScheduler.PERCEPTION, importance, _sense)
	if now >= _next_think and not _think_queued:
		_think_queued = true
		services.sched.submit(AIScheduler.TREES, importance, _think)
	_measure_masked()
	_gate_masked()
	_aim_and_fire(now)


func _sense() -> void:
	_sense_queued = false
	var now := services.now()
	_next_sense = now + 1.0 / (SENSE_HZ * services.sched.rate_scale(AIScheduler.PERCEPTION))
	var k := knowledge()
	for h in services.hostiles_of(team):
		if can_see(h):
			var before := k.of(h)
			var known := before != null and (before.visible or now - before.seen_at < 6.0)
			k.saw(h, h.feet(), now, self)
			if not known and squad != null:
				squad.say(self, "contact", "Contact!")
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
	if d > SIGHT_RANGE * services.sight_mul:
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
	var eye := eye_pos()
	# Only so many shoot one target at once (AI.md 5.1): a token is asked for only
	# when it would fire, and without one it aims and waits -- or, told to
	# suppress, suppresses.
	# The line has to be clear THIS tick -- sensing is 5 Hz, and a target that
	# stepped behind a wall 150 ms ago is behind a wall. And a soldier that cannot
	# shoot does not take a token another could use.
	var seen := c != null and c.visible and c.pawn != null and is_instance_valid(c.pawn)
	var at := c.pawn.chest() if seen else Vector3.ZERO
	# And from where the eye will be when the gun steps: on the move, the
	# round leaves a tick later from a hand's breadth on -- past a wall's edge.
	var next_eye := eye + pawn.body.velocity / float(Engine.physics_ticks_per_second)
	var clear := seen and services.ai_world.bricks_between(eye, at) == 0 \
			and services.ai_world.bricks_between(next_eye, at) == 0 \
			and not services.ai_world.smoke_blocks(eye, at)
	var mine := clear and fire_ok and services.token(c.pawn, self)
	if seen and (mine or suppress_point == Vector3.INF):
		_aim_target = c.pawn
		aim.track(c.pawn, now)
		aim.weather = services.aim_mul
		var ang := aim.aim(eye, at, now)
		it.look_yaw = ang.x
		it.look_pitch = ang.y
		it.fire = fire_ok and clear and mine and aim.ready_to_fire(now) and _burst(now) \
				and not _friend_in_line(eye, at)
	elif suppress_point != Vector3.INF:
		# Suppression: rounds into where the enemy is, not at a body -- over its
		# cover, round its head. Still never through bricks, nor through a friend.
		_aim_target = null
		aim.track(null, now)
		var ang := aim.aim(eye, suppress_point, now)
		it.look_yaw = ang.x
		it.look_pitch = ang.y
		it.fire = fire_ok and services.ai_world.bricks_between(eye, suppress_point) == 0 \
				and _burst(now) and not _friend_in_line(eye, suppress_point)
	else:
		_aim_target = null
		aim.track(null, now)
		it.fire = false


## A squadmate (or anyone on the side) close to the line of fire, nearer than
## what is aimed at.
func _friend_in_line(eye: Vector3, at: Vector3) -> bool:
	var d := eye.distance_to(at)
	for p in services.pawns:
		if p == pawn or not is_instance_valid(p) or p.team != team or p.health == null \
				or p.health.is_dead():
			continue
		var ch := p.chest()
		if eye.distance_to(ch) > d:
			continue
		var q := Geometry3D.get_closest_point_to_segment(ch, eye, at)
		if Vector2(q.x - ch.x, q.z - ch.z).length() < 0.6 and absf(q.y - ch.y) < 0.9:
			friendly_holds += 1
			return true
	return false


func _burst(now: float) -> bool:
	var cycle := BURST_ON + BURST_OFF
	return fmod(now - _burst_from, cycle) < BURST_ON


func _on_fired(info: Dictionary) -> void:
	shots += 1
	last_shot_at = services.now()
	if not info.is_empty() and info.get("result") != null:
		dealt += (info.result as DamageSystem.DamageResult).dealt
	# The gate's check, from the gun's side: was the line to what it was aimed
	# at clear when the round left? (The noise, the suppression and the aggro a
	# round makes are AIServices', for every gun alike.)
	if _aim_target != null and is_instance_valid(_aim_target):
		if services.ai_world.bricks_between(eye_pos(), _aim_target.chest()) > 0:
			blocked_shots += 1


func _on_reload(_seconds: float) -> void:
	if squad != null:
		squad.say(self, "reload", "Reloading!")


# --- masked moves --------------------------------------------------------------

## A masked move goes only while Masking says so; otherwise the soldier stops
## where it is, down. Checked here every physics tick and in move_to, so it holds
## whichever runs first.
func _gate_masked() -> void:
	if not masked_move or _dead:
		mask_state = ""
		_was_held = false
		_held_ticks_run = 0
		_was_masked_moving = false
		return
	var why := Masking.why(services, pawn, contact())
	mask_state = why
	if why == Masking.NONE:
		pawn.intents.move = Vector3.ZERO
		pawn.intents.run = false
		pawn.intents.crouch = true
		held_ticks += 1
		_was_held = true
		_held_ticks_run += 1
		_was_masked_moving = false
	else:
		pawn.intents.move = _want_move
		pawn.intents.crouch = false
		_was_held = false
		_held_ticks_run = 0
		_was_masked_moving = _want_move != Vector3.ZERO


## How far it went last tick, and whether it was meant to be held then.
func _measure_masked() -> void:
	var f := pawn.feet()
	if _last_feet != Vector3.INF:
		var d := Vector2(f.x - _last_feet.x, f.z - _last_feet.z).length()
		# From the second held tick on: on the first, the hold was decided with
		# the body already stepping -- a tick of reaction, not a move it made
		# while it knew to stay (0.19 m at a run, once per unmasking).
		if _was_held and _held_ticks_run >= 2:
			unmasked_moved += d
		elif _was_masked_moving:
			masked_moved += d
	_last_feet = f


# --- moving, for the tasks --------------------------------------------------------

## Walk to `goal`. 1 arrived, 0 on the way (or waiting for a path), -1 no way.
func move_to(goal: Vector3, run := false) -> int:
	var now := services.now()
	var nav := services.ai_nav
	# Trapped (no way anywhere, several times running): stop asking until it is
	# time to look again -- rubble may have made a way down since.
	if trapped:
		if now < _trap_retry_at:
			pawn.intents.move = Vector3.ZERO
			return -1
		# Time to look again: one fresh request. Failing, it traps again.
		trapped = false
		_repath = true
	if _goal == Vector3.INF or goal.distance_to(_goal) > 0.5 or _repath:
		_repath = false
		_goal = goal
		if _path_id >= 0:
			nav.release(_path_id)
		# What it may cost, by how far: a spot eight metres off does not get
		# twenty thousand nodes to prove it cannot be reached.
		var budget := clampi(int(pawn.feet().distance_to(goal) * 500.0), 3000, 20000)
		_path_id = nav.request_path(pawn.feet(), goal, importance, budget)
		_path = PackedVector3Array()
		_wp = 0
		# Not a reset of the stuck clock: a body pinned in place that keeps
		# picking new places to go (a strafe every second or two) is still
		# pinned, and resetting here meant it was never counted stuck at all.
	if _path.is_empty():
		var st := nav.get_status(_path_id)
		if st == AINav.PENDING:
			pawn.intents.move = Vector3.ZERO
			# Waiting for a path is not being stuck.
			_stuck_from = pawn.feet()
			_stuck_at = now
			return 0
		if st != AINav.DONE:
			pawn.intents.move = Vector3.ZERO
			_path_failed(now)
			return -1
		_path = nav.get_path(_path_id)
		if not _fails.is_empty() and _fails.size() >= TRAP_FAILS:
			print("[soldier] a way out after %.0f s trapped" % (now - _trapped_since))
		_fails.clear()
		_wp = 1 if _path.size() > 1 else 0
	var feet := pawn.feet()
	while _wp < _path.size():
		var w: Vector3 = _path[_wp]
		# Level with it too: the far side of a drop is a step away across and a
		# storey down, and counting it reached from the top sent a soldier on
		# to "arrive" a floor above its goal (Docs/Collapse.md 4.3).
		if Vector2(w.x - feet.x, w.z - feet.z).length() > WAYPOINT_REACHED \
				or absf(w.y - feet.y) > WAYPOINT_LEVEL:
			break
		_wp += 1
	if _wp >= _path.size():
		pawn.intents.move = Vector3.ZERO
		stuck = 0
		_stuck_from = feet
		_stuck_at = now
		_want_move = Vector3.ZERO
		return 1
	var next: Vector3 = _path[_wp]
	var dir := Vector3(next.x - feet.x, 0.0, next.z - feet.z)
	# The foot of a drop is often a step across from its top, and a body walked
	# to it stops with its centre over the point and its rim still on the ledge
	# -- stood there for good. Keep walking the way it came until it falls.
	if next.y < feet.y - WAYPOINT_LEVEL:
		var from: Vector3 = _path[_wp - 1] if _wp > 0 else feet
		var way := Vector3(next.x - from.x, 0.0, next.z - from.z)
		if way.length() < 0.01:
			way = dir
		if way.length() > 0.01:
			dir = way
	pawn.intents.move = dir.normalized() if dir.length() > 0.01 else Vector3.ZERO
	pawn.intents.run = run
	_want_move = pawn.intents.move
	if masked_move:
		_gate_masked()
		if mask_state == Masking.NONE:
			# Held is not stuck.
			_stuck_from = feet
			_stuck_at = now
			return 0
	# Going nowhere: something is in the way that was not when the path was made.
	if feet.distance_to(_stuck_from) > 0.4:
		_stuck_from = feet
		_stuck_at = now
		stuck = 0
	elif now - _stuck_at > STUCK_SECONDS:
		_repath = true
		stuck += 1
		_stuck_at = now
		if stuck >= MAX_STUCK:
			call_for_help()
		if stuck > MAX_STUCK:
			_unstick(next)
	return 0


## Pinned for good -- a corner the path swears it can pass, a collider that
## does not match the bricks: put the body on the nearest spot it fits, toward
## where it was going first. The last resort, and what every shooter does.
func _unstick(toward: Vector3) -> void:
	var feet := pawn.feet()
	var ahead := Vector3(toward.x - feet.x, 0.0, toward.z - feet.z)
	var a0 := atan2(ahead.z, ahead.x) if ahead.length() > 0.01 else 0.0
	for r in [0.35, 0.6, 0.9, 1.3]:
		for k in 8:
			# Toward the goal first, then fanning out either side.
			@warning_ignore("integer_division")
			var turn := (k + 1) / 2 * (PI / 4.0) * (1.0 if k % 2 == 0 else -1.0)
			var a: float = a0 + turn
			var p := services.ai_nav.snap(feet + Vector3(cos(a), 0.0, sin(a)) * r)
			if absf(p.y - feet.y) > 0.5 or not services.ai_nav.can_stand(p):
				continue
			if not body_fits(services.world3d, p, pawn.body.get_rid()):
				continue
			pawn.place(p)
			unsticks += 1
			stuck = 0
			_stuck_from = p
			_stuck_at = services.now()
			_repath = true
			return


## Does a standing body fit with its feet at `feet`, as physics sees it -- the
## capsule itself, against everything a pawn collides with? The bricks can say
## a spot is clear while a building's collision says it is not.
static func body_fits(space_world: World3D, feet: Vector3, skip: RID = RID()) -> bool:
	if space_world == null:
		return true
	var cap := CapsuleShape3D.new()
	cap.radius = Pawn.BODY_RADIUS
	cap.height = Pawn.BODY_HEIGHT
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = cap
	# A hair above the floor, and a hair thinner: touching is not overlapping.
	q.transform = Transform3D(Basis(), feet + Vector3.UP * (Pawn.BODY_HEIGHT * 0.5 + 0.04))
	q.margin = -0.02
	q.collision_mask = Layers.PAWN_MASK
	if skip.is_valid():
		q.exclude = [skip] as Array[RID]
	return space_world.direct_space_state.intersect_shape(q, 1).is_empty()


## Stuck: shout for help (AI.md 6.5), and the side's soldiers in earshot who
## are not in a fight of their own come to it.
func call_for_help() -> void:
	var now := services.now()
	# A helper stuck on its way gives the errand up rather than calling in
	# turn: two stuck soldiers sending each other to help went nowhere at all.
	if help_point != Vector3.INF:
		help_point = Vector3.INF
		return
	if now - _called_help_at < HELP_EVERY:
		return
	_called_help_at = now
	services.say(pawn, "stuck", HELP_LINES[services.rng.randi() % HELP_LINES.size()],
			AIServices.SHOUT)
	for ally in allies():
		# Not one that needs help itself: stuck and calling, or cut off.
		if ally.trapped or now - ally._called_help_at < HELP_EVERY * 2.0:
			continue
		if ally.pawn.feet().distance_to(pawn.feet()) <= HELP_RANGE and ally.state in ["idle", "search"]:
			ally.help_point = pawn.feet()
			ally.help_until = now + 20.0


## A cover spot failed. Two strikes and it is out: one failure is often
## passing -- rubble underfoot that the next path gets over -- and a spot that
## was the only cover there is gets its second try.
func mark_bad_cover(p: Vector3) -> void:
	var now := services.now()
	for e in bad_cover:
		if (e[0] as Vector3).distance_to(p) < 1.0 and now <= float(e[1]):
			e[1] = now + BAD_COVER_SECONDS
			e[2] = int(e[2]) + 1
			return
	bad_cover.append([p, now + BAD_COVER_SECONDS, 1])


func is_bad_cover(p: Vector3) -> bool:
	var now := services.now()
	for i in range(bad_cover.size() - 1, -1, -1):
		if now > float(bad_cover[i][1]):
			bad_cover.remove_at(i)
		elif (bad_cover[i][0] as Vector3).distance_to(p) < 1.0 and int(bad_cover[i][2]) >= 2:
			return true
	return false


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


## A path request came back with no way. TRAP_FAILS of them inside TRAP_WINDOW
## and the soldier is TRAPPED (Docs/Collapse.md 4.3-4.4): cut off -- its stairs
## shot out, the only drop too far -- and it stops wandering. It holds where it
## is and fights from there (the tasks treat -1 as "stay"), and asks for a way
## out again every TRAP_RETRY seconds.
func _path_failed(now: float) -> void:
	_fails.append(now)
	while not _fails.is_empty() and now - _fails[0] > TRAP_WINDOW:
		_fails.remove_at(0)
	if _fails.size() >= TRAP_FAILS:
		if not trapped:
			_trapped_since = now
			# Cut off: say so, and whoever is near and free comes.
			call_for_help()
		trapped = true
		_trap_retry_at = now + TRAP_RETRY
		state = "trapped"


## Get low for `seconds`: the ground is about to be struck nearby (a lightning
## stroke's leader, Docs/Collapse.md 4.4).
func duck(seconds: float) -> void:
	_duck_until = maxf(_duck_until, services.now() + seconds)
	_ducking = true


func stop() -> void:
	pawn.intents.move = Vector3.ZERO
	pawn.intents.run = false
	# Standing still on purpose is not being stuck. The count only ever reset
	# on moving again, so a soldier that stopped to hide stayed "stuck" as
	# long as it hid, and the judge said so.
	stuck = 0
	_stuck_from = pawn.feet()
	_stuck_at = services.now()
	_want_move = Vector3.ZERO


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
	masked_move = false
	suppress_point = Vector3.INF
	pawn.intents.clear()
	pawn.intents.fire = false
	state = "dead"
	knowledge().forget_seer(self)


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
