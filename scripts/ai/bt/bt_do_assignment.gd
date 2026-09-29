@tool
class_name BTDoAssignment
extends BTAction
## Carry out the squad's Assignment (Docs/AI.md 2) and reply with Status. Whatever
## the task, a soldier shoots what shows itself (fire_ok when a contact is in
## sight; attack tokens and the clear-line rule still apply in Soldier).
##
##   MOVE     go there (only while masked, if told), reply REACHED, then hold,
##            down if told, facing the given way
##   HOLD     stay there, facing the given way
##   SUPPRESS fire at the given point from where it stands
##   SWEEP    through `via` if given, to the corner, reply REACHED; sweep the
##            sector for SWEEP_TIME, reply DONE, and keep watching it
##   FLASH    face the point, throw, reply DONE (the squad times the bang)
##   BREACH   go to the wall, set the charge, reply DONE
##   FOLLOW   keep to the point the squad keeps moving (a place in its file,
##            BTPlayTravel); no reply -- the squad knows where the file is

const SWEEP_HALF := 0.75
const SWEEP_TIME := 1.8
const THROW := 0.4
const PLACE := 0.8
const ARRIVED := 0.45
## Stuck this near its point, a member is there as far as the squad cares.
const NEAR_ENOUGH := 2.5
## A follower this close to its place in the file stands, rather than
## re-pathing to a point that moves a hand's breadth every think.
const FOLLOW_SLACK := 0.9
## A crumb this near is passed; a trail further than FOLLOW_JOIN is rejoined
## by a path first.
const FOLLOW_CRUMB := 0.6
const FOLLOW_JOIN := 2.5

var _crumb := -1
var _off_trail := false

var _id := -1
var _arrived_at := -1.0
var _via_done := true
var _started := 0.0


func _tick(_delta: float) -> Status:
	var so := SoldierTree.soldier_of(agent)
	var a := so.assignment
	if a == null:
		return FAILURE
	var now := so.services.now()
	if a.id != _id:
		_id = a.id
		_crumb = -1
		_off_trail = false
		_arrived_at = -1.0
		_via_done = a.via == Vector3.INF
		_started = now
	var c := so.contact()
	var seen := so.sees(c)
	so.fire_ok = seen
	so.masked_move = false
	so.suppress_point = Vector3.INF
	var it := so.pawn.intents
	if now < a.go_at:
		so.state = "wait " + a.role
		so.stop()
		it.crouch = a.crouch
		_face(so, a.yaw, seen)
		return RUNNING
	match a.task:
		SquadMsg.Task.MOVE, SquadMsg.Task.HOLD:
			if _arrived_at < 0.0 or (a.task == SquadMsg.Task.HOLD and _far(so, a.point, 0.9)):
				_go(so, a, a.point, now)
			else:
				_hold(so, a, seen)
				so.state = a.role if a.role else "hold"
		SquadMsg.Task.SUPPRESS:
			so.stop()
			it.crouch = false
			so.suppress_point = a.point
			so.fire_ok = true
			so.look_at_point(a.point)
			so.state = "suppress"
		SquadMsg.Task.SWEEP:
			if not _via_done:
				so.state = "enter"
				it.crouch = false
				var r := so.move_to(a.via, a.run)
				if r == 1 or not _far(so, a.via, 0.7) or r == -1:
					_via_done = true
				return RUNNING
			if _arrived_at < 0.0:
				_go(so, a, a.point, now)
				so.state = "to corner"
				return RUNNING
			so.stop()
			it.crouch = false
			so.state = "sweep"
			if not seen:
				it.look_yaw = a.yaw + sin((now - _arrived_at) * 2.4) * SWEEP_HALF
				it.look_pitch = 0.0
			if now - _arrived_at >= SWEEP_TIME and not seen:
				so.report(SquadMsg.StatusKind.DONE)
		SquadMsg.Task.FOLLOW:
			so.masked_move = false
			_follow(so, a, seen)
		SquadMsg.Task.FLASH:
			so.stop()
			so.look_at_point(a.point)
			so.state = "flash"
			if now - _started >= THROW:
				so.report(SquadMsg.StatusKind.DONE)
		SquadMsg.Task.BREACH:
			if _arrived_at < 0.0:
				_go(so, a, a.point, now)
				so.state = "to wall"
			else:
				so.stop()
				it.crouch = true
				so.state = "set charge"
				if now - _arrived_at >= PLACE:
					so.report(SquadMsg.StatusKind.DONE)
	return RUNNING


## Along the leader's trail, crumb by crumb, to this member's place in the file
## -- no path search. Off the trail or stuck on it: a path to the place.
func _follow(so: Soldier, a: SquadMsg.Assignment, seen: bool) -> void:
	var feet := so.pawn.feet()
	if a.trail.is_empty() or a.upto < 0:
		so.stop()
		return
	if _crumb < 0 or _crumb >= a.trail.size():
		# Join the trail at the nearest crumb not past this member's place.
		var best := INF
		for i in mini(a.upto + 1, a.trail.size()):
			var d := feet.distance_to(a.trail[i])
			if d < best:
				best = d
				_crumb = i
		_off_trail = best > FOLLOW_JOIN
	if _off_trail:
		so.state = "rejoin"
		var r := so.move_to(a.trail[_crumb], a.run)
		if r != 0:
			_off_trail = false
		return
	# Up the trail as far as its place; then to the place itself.
	while _crumb < a.upto and feet.distance_to(a.trail[_crumb]) < FOLLOW_CRUMB:
		_crumb += 1
	if _crumb >= a.upto and not _far(so, a.point, FOLLOW_SLACK):
		so.stop()
		so.state = "in file"
		_face(so, a.yaw, seen)
		return
	var to: Vector3 = a.trail[_crumb] if _crumb < a.upto else a.point
	so.state = a.role if a.role else "follow"
	if so.walk_toward(to, a.run) == -1:
		_off_trail = true


func _go(so: Soldier, a: SquadMsg.Assignment, to: Vector3, now: float) -> void:
	so.pawn.intents.crouch = false
	so.masked_move = a.masked
	so.state = "bound" if a.masked else "move"
	var r := so.move_to(to, a.run)
	if r == 1 or not _far(so, to, ARRIVED):
		_arrived_at = now
		so.masked_move = false
		so.stop()
		so.report(SquadMsg.StatusKind.REACHED)
	elif r == -1:
		_arrived_at = now
		so.masked_move = false
		so.stop()
		so.report(SquadMsg.StatusKind.BLOCKED)
	elif so.stuck >= Soldier.MAX_STUCK:
		# Stuck short of it -- a squadmate on the next slot, a corner the body
		# will not take: near enough counts as there, further is blocked. Either
		# way the squad hears back; silence held a stack's barrier for good.
		_arrived_at = now
		so.masked_move = false
		var near := not _far(so, to, NEAR_ENOUGH)
		so.stuck = 0
		so.stop()
		so.report(SquadMsg.StatusKind.REACHED if near else SquadMsg.StatusKind.BLOCKED)


func _hold(so: Soldier, a: SquadMsg.Assignment, seen: bool) -> void:
	so.stop()
	# Down while waiting; up to shoot what shows itself.
	so.pawn.intents.crouch = a.crouch and not seen
	_face(so, a.yaw, seen)


func _face(so: Soldier, yaw: float, seen: bool) -> void:
	if not seen:
		so.pawn.intents.look_yaw = yaw
		so.pawn.intents.look_pitch = 0.0


func _far(so: Soldier, p: Vector3, r: float) -> bool:
	var f := so.pawn.feet()
	return Vector2(f.x - p.x, f.z - p.z).length() > r or absf(f.y - p.y) > 1.2


func _exit() -> void:
	var so := SoldierTree.soldier_of(agent)
	if so != null:
		so.masked_move = false
		so.suppress_point = Vector3.INF
		so.fire_ok = false
		so.pawn.intents.crouch = false
	_id = -1
