class_name TankBrain
extends Node
## The AI crew of a Tank (Docs/AIVehicles.md 2-4, AIRoster.md RO10): a driver
## and a gunner, each doing its seat's job only while somebody sits in it.
##
## It SEES from the turret (and tells its side, as a mech does), and it is told
## where to go: `goal`, a point in the fight. The driver takes it there along the
## vehicle map's path (VehicleNav: only where the whole tank fits, under nothing
## it would hit, up nothing steeper than a brick course), to the nearest place
## to the goal it can drive to -- turning on the spot into a sharp bend, as
## tracks do. With no road there it tries the walking map, as it used to --
## and stops short when it has the enemy in its own sight within ENGAGE_RANGE
## (or in its side's within HOLD_RANGE): a tank is fire support, not a ram, and
## streets narrow as they near the fight. Stuck MAX_BACKOFFS times on the way
## to one goal, it gives that goal up and fights from where it is. With an `escort` (the squad screening it,
## AIVehicles.md 4) it goes at the squad's pace: it waits when they fall more
## than WAIT_FOR behind it.
##
## The gunner points the turret at the side's best contact and fires the
## cannon when it is on (AIM_TOL), at what it sees -- and at where the enemy
## was last heard or seen, through the wall: the cannon opens walls (AI.md
## 3.8). The machine gun is for bodies in sight within COAX_RANGE. Neither
## fires with a friend near the line of fire.

const SENSE_HZ := 4.0
const SIGHT_RANGE := 120.0
## Stops short of the enemy in sight at this: fire support's range.
const HOLD_RANGE := 30.0
## Stops this far off an enemy it sees itself.
const ENGAGE_RANGE := 60.0
## Backs off what it is stuck on at most this many times for one goal.
const MAX_BACKOFFS := 3
## Shoots the cannon at a contact this old, seen or heard: through its wall.
const BLIND_FIRE_AGE := 6.0
const CANNON_RANGE := 110.0
const COAX_RANGE := 45.0
## On target within this, radians.
const AIM_TOL := deg_to_rad(2.5)
const COAX_TOL := deg_to_rad(6.0)
## A friend this near the line of fire holds it.
const FRIEND_CLEAR := 2.5
## Turns on the spot when the way on is more than this off its nose.
const PIVOT := deg_to_rad(35.0)
## Waits for its escort when the nearest of them is further than this behind.
const WAIT_FOR := 14.0
const STUCK := 3.0
const REVERSE := 1.5

var tank: Tank
var services: AIServices
var enabled := true
## Where it is sent; INF to stay.
var goal := Vector3.INF
## The squad screening it: it keeps their pace.
var escort: Squad
var importance := 7.0
## What it is doing, for logs and probes: idle, drive, pivot, hold, wait, stuck.
var state := "idle"
## Which map its path is on: "vehicle" (VehicleNav), "foot" (none on the vehicle
## map, so the walking one), or "" before it has asked.
var road := ""
## Where on the vehicle map it is driving to: the goal, or the nearest place to
## it a tank fits.
var drive_to := Vector3.INF
var target: Pawn
var blind_shots := 0
## Why the gunner is not firing now, for logs: "" when it is.
var hold_fire := ""

var _path := PackedVector3Array()
var _path_id := -1
var _path_goal := Vector3.INF
## The map the path in hand was asked of.
var _nav: AINav
var _wp := 0
var _next_sense := -INF
var _sense_queued := false
var _from := Vector3.ZERO
var _moved_at := 0.0
var _reverse_until := -INF
var _backoffs := 0
## The hostiles it saw itself at its last look.
var _sees := {}
## Hold-fire reason -> physics ticks, since the last take_hold_counts.
var hold_ticks := {}


static func attach(s: AIServices, t: Tank) -> TankBrain:
	var b := TankBrain.new()
	b.name = "TankBrain"
	b.tank = t
	b.services = s
	t.add_child(b)
	return b


func knowledge() -> FactionKnowledge:
	return services.knowledge_of(tank.team)


func send(to: Vector3) -> void:
	if to != goal:
		_backoffs = 0
	goal = to


## What kept the gunner from firing, ticks per reason, since it was last asked.
func take_hold_counts() -> Dictionary:
	var out := hold_ticks
	hold_ticks = {}
	return out


func _physics_process(_delta: float) -> void:
	if tank.is_wrecked() or not enabled or tank.player_in:
		return
	var now := services.now()
	if now >= _next_sense and not _sense_queued and tank.crew_count() > 0:
		_sense_queued = true
		services.sched.submit(AIScheduler.PERCEPTION, importance, _sense)
	_gunner(now)
	var why := hold_fire if hold_fire != "" else "firing"
	hold_ticks[why] = int(hold_ticks.get(why, 0)) + 1
	_driver(now)


# --- eyes ---------------------------------------------------------------------------

func eye() -> Vector3:
	return tank.global_position + Vector3.UP * (Tank.HEIGHT * 0.5 + 0.6)


func _sense() -> void:
	_sense_queued = false
	var now := services.now()
	_next_sense = now + 1.0 / (SENSE_HZ * services.sched.rate_scale(AIScheduler.PERCEPTION))
	if tank.is_wrecked():
		return
	var k := knowledge()
	for h in services.hostiles_of(tank.team):
		if can_see(h):
			k.saw(h, h.feet(), now, self)
			_sees[h.get_instance_id()] = true
		else:
			k.lost_sight(h, self)
			_sees.erase(h.get_instance_id())


## All round from the cupola, within SIGHT_RANGE, to the chest or the eye.
func can_see(h: Pawn) -> bool:
	if h == null or not is_instance_valid(h) or h.has_meta(&"in_vehicle") or h.has_meta(&"in_mech"):
		return false
	var e := eye()
	var at := h.chest()
	if e.distance_to(at) > SIGHT_RANGE:
		return false
	var ex: Array[RID] = [tank.get_rid(), h.body.get_rid()]
	for p in [at, h.eye.global_position]:
		var q := PhysicsRayQueryParameters3D.create(e, p, Layers.HITSCAN_MASK, ex)
		if tank.get_world_3d().direct_space_state.intersect_ray(q).is_empty() \
				and not services.ai_world.smoke_blocks(e, p):
			return true
	return false


# --- the gunner ---------------------------------------------------------------------

func _gunner(now: float) -> void:
	tank.fire_main = false
	tank.fire_coax = false
	if not tank.gunned():
		hold_fire = "no gunner"
		return
	var c := knowledge().best(now)
	if c == null or c.pawn == null or not is_instance_valid(c.pawn) \
			or (c.pawn.health != null and c.pawn.health.is_dead()):
		target = null
		hold_fire = "no contact"
		return
	var age := now - maxf(c.seen_at, c.heard_at)
	var d := tank.global_position.distance_to(c.pos)
	if age > BLIND_FIRE_AGE or d > CANNON_RANGE:
		target = null
		hold_fire = "contact too old" if age > BLIND_FIRE_AGE else "out of range"
		return
	target = c.pawn
	var at := c.pawn.chest() if c.visible else c.pos + Vector3.UP * 1.0
	tank.aim_point = at
	if _friend_near_line(tank.muzzle.global_position, at):
		hold_fire = "friend in the line"
		return
	var err := tank.aim_error()
	hold_fire = "" if err <= AIM_TOL else "turning"
	if err <= AIM_TOL:
		if not c.visible and tank.main_ready():
			blind_shots += 1
		tank.fire_main = true
	if c.visible and d <= COAX_RANGE and err <= COAX_TOL:
		tank.fire_coax = true


func _friend_near_line(from: Vector3, to: Vector3) -> bool:
	var seg := to - from
	var len2 := seg.length_squared()
	if len2 < 0.01:
		return false
	for p in services.pawns:
		if not is_instance_valid(p) or p.team != tank.team or p == tank.pawn \
				or (p.health != null and p.health.is_dead()):
			continue
		var x := p.chest()
		var t := clampf((x - from).dot(seg) / len2, 0.0, 1.0)
		if t < 0.97 and x.distance_to(from + seg * t) < FRIEND_CLEAR:
			return true
	return false


# --- the driver ---------------------------------------------------------------------

func _driver(now: float) -> void:
	tank.throttle = 0.0
	tank.steer = 0.0
	if not tank.driven():
		state = "idle"
		return
	if now < _reverse_until:
		tank.throttle = -1.0
		state = "stuck"
		_from = tank.global_position
		_moved_at = now
		return
	var c := knowledge().best(now)
	var dc := tank.global_position.distance_to(c.pos) if c != null else INF
	if c != null and c.visible and (dc <= HOLD_RANGE or (dc <= ENGAGE_RANGE and c.pawn != null
			and _sees.has(c.pawn.get_instance_id()))):
		state = "hold"
		_moved_at = now
		return
	if _backoffs >= MAX_BACKOFFS:
		state = "gave up"
		_moved_at = now
		return
	if goal == Vector3.INF or _flat(goal - tank.feet()).length() < 3.0 			or (drive_to != Vector3.INF and _path_goal == goal and _flat(drive_to - tank.feet()).length() < 3.0):
		state = "hold" if goal != Vector3.INF else "idle"
		_moved_at = now
		return
	if escort != null and _escort_behind() > WAIT_FOR:
		state = "wait"
		_moved_at = now
		return
	if _path_goal != goal:
		_ask_path()
	if _path.is_empty():
		if _path_id < 0:
			state = "stuck"
			return
		var st := _nav.get_status(_path_id)
		if st == AINav.PENDING:
			return
		if st != AINav.DONE:
			_nav.release(_path_id)
			_path_id = -1
			# No road on the vehicle map: the walking map's way, which it may
			# not fit along (what it did before there was a vehicle map).
			if road == "vehicle":
				_ask_path(true)
				return
			state = "stuck"
			return
		_path = _nav.get_path(_path_id)
		_wp = 1 if _path.size() > 1 else 0
	var at := tank.global_position
	while _wp < _path.size() and _flat(_path[_wp] - at).length() < 2.5:
		_wp += 1
	var to := ((drive_to if drive_to != Vector3.INF else goal) if _wp >= _path.size() else _path[_wp]) - at
	var off := wrapf(atan2(-to.x, -to.z) - tank.yaw, -PI, PI)
	tank.steer = clampf(off * 2.0, -1.0, 1.0)
	if absf(off) > PIVOT:
		state = "pivot"
		_moved_at = now
		return
	state = "drive"
	tank.throttle = clampf(1.0 - absf(off) / PI, 0.4, 1.0)
	if at.distance_to(_from) > 1.0:
		_from = at
		_moved_at = now
	elif now - _moved_at > STUCK:
		# Back off what it is pressed against, and ask the way again.
		_reverse_until = now + REVERSE
		_path_goal = Vector3.INF
		_backoffs += 1


## A path to the goal: on the vehicle map to the nearest place to it a tank
## fits, or -- with none there, or `on_foot` -- on the walking map.
func _ask_path(on_foot := false) -> void:
	if _path_id >= 0 and _nav != null:
		_nav.release(_path_id)
	_path = PackedVector3Array()
	_path_goal = goal
	_path_id = -1
	var vn := services.vehicle_nav(&"tank") if not on_foot else null
	var to := VehicleNav.reach_point(vn, goal) if vn != null else Vector3.INF
	var from := vn.snap(tank.feet()) if vn != null else Vector3.INF
	if vn != null and to != Vector3.INF and vn.can_stand(from):
		_nav = vn
		road = "vehicle"
		drive_to = to
		_path_id = vn.request_path(from, to, 8.0, 40000)
	else:
		_nav = services.ai_nav
		road = "foot"
		drive_to = goal
		_path_id = _nav.request_path(_nav.snap(tank.feet()), goal, 8.0, 20000)
	_from = tank.global_position
	_moved_at = services.now()


## How far behind the tank its escort's nearest living member is, metres along
## its nose (0 with none living, or one level or ahead).
func _escort_behind() -> float:
	var best := INF
	var fwd := tank.forward()
	for so in escort.alive():
		var behind := -(so.pawn.feet() - tank.feet()).dot(fwd)
		best = minf(best, maxf(behind, 0.0))
	return 0.0 if best == INF else best


static func _flat(v: Vector3) -> Vector2:
	return Vector2(v.x, v.z)


func _exit_tree() -> void:
	if _path_id >= 0 and _nav != null:
		_nav.release(_path_id)
		_path_id = -1
