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
## What the casebook's mech section has it doing (BookCombatPolicy.decide_mech;
## Docs/AIRoster.md 4.3): FIRE is the tree's own way; the rest take over the legs.
## BAIL is the pilot getting out (AIRoster.md 4.3): the mech fights on, on auto.
## SMOKE, SCRAPE and CRUSH answer a rider (Rodeo; the casebook's "A rider on us").
enum Stance { FIRE, CLOSE, PUNCH, BACKOFF, GUARD, BAIL, SMOKE, SCRAPE, CRUSH }
## With a rider on, the casebook is asked this often.
const RIDDEN_EVERY := [0.8, 1.4]
## A smoke spent: someone on foot this near -- the last rider -- is watched for,
## felt if not seen, and counts as this much nearer.
const WATCH_BACK := 16.0
const PREFER_BACK := 0.25
## Where to look for something to scrape a rider off under, or a wall to back
## into: rings out to this far.
const SCRAPE_SEARCH := [8.0, 16.0, 24.0, 32.0]
const CRUSH_SEARCH := 14.0
## The casebook is asked again after this long, drawn in this range.
const DECIDE_EVERY := [2.5, 4.0]
const CLOSE_TO := 14.0
const BACKOFF_TO := 42.0
## Choosing whom to shoot: another mech counts as this much nearer than it is to
## a mech (G2), a doomed one nearer still (G7), the side's focus a little (aggro);
## and it changes target only for one this much better (G3).
const PREFER_MECH := 0.35
const PREFER_DOOMED := 0.3
const PREFER_FOCUS := 0.6
const SWITCH_AT := 0.6

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

var stance := Stance.FIRE
## The casebook's plan behind the stance, when the book decides.
var book := {}
var _decide_at := 0.0
## What a mech backing off or guarding is getting away from, and when it last
## had it in sight: remembered this long.
const REMEMBER := 12.0
var _ridden_at := 0.0
## Where it is going to scrape the rider off, and the wall it is backing into,
## or INF.
var scrape_spot := Vector3.INF
var crush_point := Vector3.INF
var _stance_target: Pawn
var _stance_seen := -INF
var _was_doomed := false
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
	# Seen, shot at and given a row in the other side's attention, as a person is.
	s.add_pawn(m.make_target())
	# Its blast (MechLayers) catches whoever the services know is there.
	if m.layers != null:
		m.layers.services = s
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
	# A mech's launcher is a mech's weapon to another mech, not a pilot's rocket.
	launcher.damage_scale = &"mech"
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
	if not _stance(now):
		brain.update(dt)


## The casebook's say, for a mech with no order of a player's: decide now and
## then, and carry out a stance that takes the legs. True if it did -- the tree
## is then left out this think.
func _stance(now: float) -> bool:
	# A rider is answered whatever its orders: the player's mech too, out of
	# the cockpit, keeps its hatch.
	if mech.rodeo != null and mech.rodeo.rider != null and mech.rodeo.is_noticed \
			and services.policy.has_method(&"decide_ridden"):
		return _ridden(now)
	if order != Order.NONE or not services.policy.has_method(&"decide_mech"):
		return false
	if stance == Stance.SCRAPE or stance == Stance.CRUSH or stance == Stance.SMOKE:
		stance = Stance.FIRE
		scrape_spot = Vector3.INF
		crush_point = Vector3.INF
	var c := contact()
	var t: Pawn = _target if _target != null and is_instance_valid(_target) else null
	if t == null and c != null and c.age(now) <= 6.0:
		t = c.pawn
	# Backing off or guarding it has its back or its side to the enemy and may
	# not see it: it remembers what it is getting away from, for a while.
	if t != null and is_instance_valid(t):
		_stance_target = t
		_stance_seen = now
	elif (stance == Stance.GUARD or stance == Stance.BACKOFF) and now - _stance_seen < REMEMBER:
		t = _stance_target
	if t == null or not is_instance_valid(t):
		stance = Stance.FIRE
		return false
	# A target just doomed is a new question: ask at once.
	var their := MechLayers.of(t.body)
	var doomed := their != null and their.doomed
	if doomed and not _was_doomed:
		_decide_at = 0.0
	_was_doomed = doomed
	if now >= _decide_at:
		_decide_at = now + services.rng.randf_range(DECIDE_EVERY[0], DECIDE_EVERY[1])
		stance = services.policy.call(&"decide_mech", self, t, services.rng)
	var feet := mech.feet()
	var at := t.feet()
	var away := Vector3(feet.x - at.x, 0.0, feet.z - at.z)
	var d := away.length()
	var other := MechLayers.of(t.body)
	match stance:
		Stance.BAIL:
			stance = Stance.FIRE
			if mech.layers != null and mech.layers.piloted and not mech.layers.dead:
				var p := mech.dismount()
				state = "bailed out"
				services.say(p if p != null else mech.pawn, "bail_out",
						["I'm out!", "Bailing out!", "Ejecting!"][services.rng.randi() % 3], AIServices.SHOUT)
			return false
		Stance.CLOSE:
			state = "close in"
			if d > CLOSE_TO:
				move_to(nav.snap(at + away / maxf(d, 0.01) * (CLOSE_TO - 2.0)), true)
			else:
				stop()
			return true
		Stance.PUNCH:
			state = "punch"
			if other == null:
				return false
			if d <= Mech.MELEE_REACH * 0.9:
				stop()
				mech.melee(other.mech)
			else:
				move_to(nav.snap(at + away / maxf(d, 0.01) * (Mech.MELEE_REACH * 0.7)), true)
			return true
		Stance.BACKOFF, Stance.GUARD:
			state = "back off" if stance == Stance.BACKOFF else "guard"
			if d < BACKOFF_TO:
				move_to(nav.snap(feet + away / maxf(d, 0.01) * 8.0), true)
			else:
				stop()
			return true
	return false


## A rider on it, noticed: the casebook's "A rider on us" (smoke, scrape, crush,
## or fight on and let the escort shoot it). True if it took the legs.
func _ridden(now: float) -> bool:
	if now >= _ridden_at:
		_ridden_at = now + services.rng.randf_range(RIDDEN_EVERY[0], RIDDEN_EVERY[1])
		stance = services.policy.call(&"decide_ridden", self, services.rng)
	match stance:
		Stance.SMOKE:
			state = "smoke"
			mech.rodeo.smoke()
			stance = Stance.FIRE
			return false
		Stance.SCRAPE:
			state = "scrape"
			if scrape_spot == Vector3.INF:
				scrape_spot = find_low_spot()
			if scrape_spot == Vector3.INF or move_to(scrape_spot, true) == -1:
				scrape_spot = Vector3.INF
				stance = Stance.FIRE
				return false
			return true
		Stance.CRUSH:
			state = "crush"
			if crush_point == Vector3.INF:
				var d := wall_behind()
				if d < 0.0:
					stance = Stance.FIRE
					return false
				crush_point = mech.feet() + Basis(Vector3.UP, mech.motor.torso_yaw).z * d
			# Straight at the wall, back first and hard (_fire keeps the torso
			# turned away from it).
			var to := crush_point - mech.feet()
			to.y = 0.0
			_goal = Vector3.INF
			_want_dir = to.normalized() if to.length() > 0.1 else Vector3.ZERO
			mech.intents.sprint = true
			return true
	state = "ridden"
	return false


## The nearest place it can walk to with bricks overhead just low enough to take
## a rider off -- over the mech's head, under the rider's. INF for none near.
func find_low_spot() -> Vector3:
	var w := services.ai_world
	var feet := mech.feet()
	var best := Vector3.INF
	var best_d := INF
	for p in [feet] + _ring_points(feet):
		var at: Vector3 = nav.snap(p)
		if Vector2(at.x - p.x, at.z - p.z).length() > 2.0:
			continue
		if _low_over(w, at):
			var d := feet.distance_to(at)
			if d < best_d:
				best_d = d
				best = at
	return best


func _ring_points(feet: Vector3) -> Array:
	var out: Array = []
	for r in SCRAPE_SEARCH:
		for k in 12:
			var a := TAU * k / 12.0
			out.append(feet + Vector3(cos(a), 0.0, sin(a)) * float(r))
	return out


static func _low_over(w: AIWorld, at: Vector3) -> bool:
	for up in [Rodeo.SEAT_UP + Pawn.BODY_HEIGHT * 0.7, Rodeo.SEAT_UP + Pawn.BODY_HEIGHT * 0.95]:
		if w.solid_at(at + Vector3.UP * up):
			return true
	return false


## How far behind its back a wall stands at the rider's height, with a clear run
## back to it; -1 for none within CRUSH_SEARCH.
func wall_behind() -> float:
	var w := services.ai_world
	var back := Basis(Vector3.UP, mech.motor.torso_yaw).z
	var feet := mech.feet()
	var seat := Vector3.UP * (Rodeo.SEAT_UP + Pawn.BODY_HEIGHT * 0.5)
	var d := Mech.RADIUS
	while d <= CRUSH_SEARCH:
		if w.solid_at(feet + back * d + seat):
			# The run back there must be open below the rider, or it stops short.
			if d <= Mech.RADIUS + 0.6 or w.line_clear(feet + Vector3.UP * 1.5, feet + back * (d - Mech.RADIUS) + Vector3.UP * 1.5):
				return d
			return -1.0
		d += 0.5
	return -1.0


func can_see(h: Pawn) -> bool:
	# Not its own back: a rider is felt (Rodeo), not seen.
	if mech.rodeo != null and h == mech.rodeo.rider:
		return false
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
	var held_d := INF
	var from := mech.muzzle.global_position
	var k := knowledge()
	var focus := services.aggro_of(team).focus() if team != AIServices.PLAYER_SIDE else null
	for h in services.hostiles_of(team):
		var c := k.of(h)
		if (c == null or not c.seen_by.has(get_instance_id())) and not _felt(h):
			continue
		# Never its own rider: the arm cannot reach its own back (the casebook's
		# "A rider on us" answers it).
		if mech.rodeo != null and h == mech.rodeo.rider:
			continue
		# Its smoke spent, it minds its back: the last rider near is felt even
		# unseen, and comes first.
		var back := mech.rodeo != null and mech.rodeo.smoke_spent() and h == mech.rodeo.last_rider \
				and h.feet().distance_to(mech.feet()) < WATCH_BACK and not h.has_meta(&"riding")
		if services.ai_world.bricks_between(from, h.chest()) > 0:
			continue
		# How near it counts as: a mech to a mech, a doomed mech, the one the side
		# is watching.
		var d := from.distance_to(h.chest())
		var ml := MechLayers.of(h.body)
		if ml != null:
			d *= PREFER_DOOMED if ml.doomed else PREFER_MECH
		if h == focus:
			d *= PREFER_FOCUS
		if back:
			d *= PREFER_BACK
		if h == _target:
			held_d = d
		if d < best_d:
			best_d = d
			best = h
	# The one it is on is kept unless another is much the better.
	if _target != null and is_instance_valid(_target) and held_d < INF and best != _target and best_d > held_d * SWITCH_AT:
		return _target
	return best


## A rider just off its back, while its smoke is down: it knows where they are.
func _felt(h: Pawn) -> bool:
	return mech.rodeo != null and mech.rodeo.smoke_spent() and h == mech.rodeo.last_rider \
			and h.feet().distance_to(mech.feet()) < WATCH_BACK


func _fire(_now: float) -> void:
	var it := mech.intents
	_target = _pick_target()
	var aim_at := Vector3.INF
	if _target != null:
		# A mech with a door off on this side: the pilot, or the cell, behind it.
		aim_at = MechLayers.aim_point(_target, mech.muzzle.global_position)
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
	# Backing into a wall to crush a rider: its back stays to the wall.
	if stance == Stance.CRUSH and crush_point != Vector3.INF:
		var away := mech.feet() - crush_point
		it.aim_yaw = atan2(-away.x, -away.z)
	# Guarding: the torso turns so the open side is away from what it faces. A
	# hatch at the back means facing it; a hatch in front means showing its back.
	if stance == Stance.GUARD and mech.layers != null and order == Order.NONE:
		var open_front := (mech.layers.hatch_off and mech.layers.hatch_side == "front") \
				or (mech.layers.cell_door_off and mech.layers.hatch_side == "back")
		if open_front:
			it.aim_yaw = wrapf(it.aim_yaw + PI, -PI, PI)
	# Only when the arm is on it.
	var fwd := -mech.muzzle.global_transform.basis.z
	var want := (aim_at - mech.muzzle.global_position).normalized()
	var on := rad_to_deg(fwd.angle_to(want)) <= FIRE_CONE_DEG
	var from := mech.muzzle.global_position
	var friend := _friend_in_line(from, aim_at)
	if _target != null:
		# A doomed Nuker is not shot dead -- that is what sets it off. It is
		# punched (the finisher), or left alone.
		var theirs := MechLayers.of(_target.body)
		var hold := theirs != null and theirs.doomed and theirs.nuker and order == Order.NONE
		mech.gun.set_trigger(on and not friend and not hold and services.ai_world.bricks_between(from, aim_at) == 0)
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
		if p == mech.pawn:
			continue   # its own body is not in its own way
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
	# Nothing to shoot: face where it is going -- unless it is backing into a
	# wall on purpose (CRUSH).
	if _target == null and breach_point == Vector3.INF and stance != Stance.CRUSH:
		it.aim_yaw = atan2(-_want_dir.x, -_want_dir.z)
