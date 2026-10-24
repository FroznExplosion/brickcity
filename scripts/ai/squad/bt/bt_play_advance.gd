@tool
class_name BTPlayAdvance
extends BTAction
## Advance on a contact by bounding overwatch (Docs/AI.md 6.1, 6.3; F.E.A.R.'s
## core squad move): half the squad moves to the next cover nearer the enemy
## while the other half suppresses it, then they swap. A mover goes only while
## its move is MASKED (Masking) -- the enemy suppressed, looking elsewhere, or
## blind to it behind bricks or smoke -- and holds, down and still, whenever it is
## not. Done when the squad is within STOP of the enemy; the members then fight
## on their own trees.
##
## An order with `to_point` bounds to its point instead -- the same bounds and
## the same suppression on the enemy -- and is done when the whole squad is
## there: its furthest member within ARRIVE_ALL of it, so the covering half is
## not left behind.

## How far each bound tries to gain.
const BOUND := 6.0
const STOP := 12.0
const ARRIVE := 3.0
const ARRIVE_ALL := 6.0
const BOUND_TIMEOUT := 12.0
## Contact older than this: the advance has nothing to advance on.
const LOST := 8.0

var _movers: Array[Soldier] = []
var _cover: Array[Soldier] = []
var _bound_at := 0.0
var _suppress_at := Vector3.INF
var _first := true
## Movers of this bound whose cover is still being looked for
## (CoverSearch.find_queued): mover -> {ahead, feet, goal, threat}. Each goes
## when its answer is in (_send_movers) -- a tick or a few, at most COVER_WAIT.
## Sent at once and redirected when cover came in, the squad re-pathed mid-run
## and took longer to get there.
var _waiting := {}
const COVER_WAIT := 0.5
var bounds := 0

## This play's generation (Squad.begin_play).
var _gen := 0


func _enter() -> void:
	_gen = (agent as Squad).begin_play()
	_movers.clear()
	_cover.clear()
	_first = true


func _tick(_delta: float) -> Status:
	var q := agent as Squad
	var s := q.services
	var now := s.now()
	var c := q.contact()
	q.play = "advance"
	blackboard.set_var(&"play", q.play)
	if c == null or c.age(now) > LOST:
		q.finish(SquadMsg.ReportKind.FAILED, "lost contact")
		return FAILURE
	var target := c.pos
	blackboard.set_var(&"target", target)
	_send_movers(q, now)
	var nearest := INF
	var furthest := 0.0
	var goal := _goal(q, c)
	for m in q.alive():
		nearest = minf(nearest, m.pawn.feet().distance_to(goal))
		furthest = maxf(furthest, m.pawn.feet().distance_to(goal))
	if (furthest <= ARRIVE_ALL) if goal != c.pos else (nearest <= STOP):
		q.events["arrived"] = now
		q.finish(SquadMsg.ReportKind.DONE)
		return SUCCESS
	# A mover that died and was cleared away since the bound was given.
	_movers = _movers.filter(func(m) -> bool: return is_instance_valid(m))
	var moved := true
	for m in _movers:
		if _waiting.has(m) or not (q.replied(m, SquadMsg.StatusKind.REACHED)
				or q.replied(m, SquadMsg.StatusKind.BLOCKED)):
			moved = false
	if _movers.is_empty() or moved or now - _bound_at > BOUND_TIMEOUT:
		_next_bound(q, c, now)
	# Keep the suppression on where the enemy is now.
	var sp := target + Gravity.up_at(target) * 1.5
	if _suppress_at == Vector3.INF or sp.distance_to(_suppress_at) > 1.0:
		_suppress(q, sp)
	return RUNNING


## Where the bounds go: the enemy, or the order's own point (`to_point`).
func _goal(q: Squad, c: FactionKnowledge.Contact) -> Vector3:
	if q.order != null and q.order.to_point:
		return q.order.point
	return c.pos


func _bound_move(spot: Vector3) -> SquadMsg.Assignment:
	var a := SquadMsg.Assignment.make(SquadMsg.Task.MOVE, spot)
	a.run = true
	a.masked = true
	a.crouch = true
	a.role = "bound"
	return a


## Movers whose cover answer is in go to it if it gets them nearer the goal,
## else to their spot; past COVER_WAIT, to their spot whatever.
func _send_movers(q: Squad, now: float) -> void:
	for m in _waiting.keys():
		if not is_instance_valid(m) or not _movers.has(m):
			_waiting.erase(m)
			continue
		var u: Dictionary = _waiting[m]
		var cov = CoverSearch.find_queued(m, &"bound", u.ahead, u.threat, false, CoverSearch.POINT_MOVE)
		if cov == null and now - _bound_at < COVER_WAIT:
			continue
		_waiting.erase(m)
		var spot: Vector3 = q.services.ai_nav.snap(u.ahead)
		if cov != null and not (cov as Dictionary).is_empty() 				and (cov.cover as Vector3).distance_to(u.goal) < (u.feet as Vector3).distance_to(u.goal) - 2.0:
			spot = cov.cover
		q.assign(m, _bound_move(spot))


func _next_bound(q: Squad, c: FactionKnowledge.Contact, now: float) -> void:
	_waiting.clear()
	var s := q.services
	var alive := q.alive()
	var a_half: Array[Soldier] = []
	var b_half: Array[Soldier] = []
	for i in alive.size():
		(a_half if i % 2 == 0 else b_half).append(alive[i])
	if _first or _movers.is_empty() or alive.size() < 2:
		_movers = a_half
		_cover = b_half
	else:
		var was_a := _movers.has(alive[0])
		_movers = b_half if was_a else a_half
		_cover = a_half if was_a else b_half
	if _cover.is_empty():
		_cover = []
	_first = false
	_bound_at = now
	bounds += 1
	q.events["bounds"] = bounds
	var threat_eye := c.pos + Gravity.up_at(c.pos) * CoverSearch.STAND_EYE
	var goal := _goal(q, c)
	var stop := ARRIVE if goal != c.pos else STOP
	var k := 0
	for m in _movers:
		var feet := m.pawn.feet()
		var up := Gravity.up_at(feet)
		var to := Gravity.flat(goal - feet, up)
		var dir := to.normalized()
		var side := dir.cross(up) * (k - (_movers.size() - 1) * 0.5) * 3.0
		var ahead := feet + dir * minf(BOUND, maxf(to.length() - stop + 1.0, 1.0)) + side
		_waiting[m] = {"ahead": ahead, "feet": feet, "goal": goal, "threat": threat_eye}
		k += 1
	# Those whose cover is already in go now; the rest as theirs comes in.
	_send_movers(q, now)
	_suppress(q, c.pos + Gravity.up_at(c.pos) * 1.5)
	if not _movers.is_empty():
		q.say(_movers[0], "moving", "Moving!")
	if not _cover.is_empty():
		q.say(_cover[0], "covering", "Covering -- go!")


func _suppress(q: Squad, at: Vector3) -> void:
	_suppress_at = at
	# A coverer that died and was cleared away since the bound was given: handing
	# it an assignment was an error on a freed object.
	_cover = _cover.filter(func(m) -> bool: return is_instance_valid(m))
	for m in _cover:
		var a := SquadMsg.Assignment.make(SquadMsg.Task.SUPPRESS, at)
		a.role = "suppress"
		q.assign(m, a)


func _exit() -> void:
	var q := agent as Squad
	if q != null:
		q.clear_assignments(_gen)
