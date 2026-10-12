@tool
class_name BTPlayFallBack
extends BTAction
## Morale broken (Docs/AI.md 6.3): back to rally cover away from the enemy, then
## hold there, facing it, until the squad has rallied (Squad.RALLY) -- the tree's
## condition above this then fails and the squad takes up its order again.

const BACK := 12.0
const FALL_TIME := 10.0

var _started := 0.0

var _spots: Array[Vector3] = []
var _holding := false
## Members sent to their plain rally spot while cover near it is looked for:
## index -> {member, want, threat, center} (_take_cover).
var _upgrade := {}

## This play's generation (Squad.begin_play).
var _gen := 0


func _enter() -> void:
	_gen = (agent as Squad).begin_play()
	var q := agent as Squad
	var s := q.services
	var now := s.now()
	_started = now
	_holding = false
	_spots.clear()
	var c := q.contact()
	var center := q.center()
	var threat := c.pos if c != null else (q.order.point if q.order != null else center - Vector3.FORWARD)
	var away := center - threat
	away.y = 0.0
	away = away.normalized() if away.length() > 0.1 else Vector3.BACK
	var side := away.cross(Vector3.UP)
	var base := center + away * BACK
	var alive := q.alive()
	_upgrade.clear()
	for i in alive.size():
		var want := base + side * (i - (alive.size() - 1) * 0.5) * 2.0
		var eye := threat + Vector3.UP * CoverSearch.STAND_EYE
		# Off to the rally spot at once; cover near it, when the search is in.
		_upgrade[i] = {"member": alive[i], "want": want, "threat": threat, "center": center}
		var cov = CoverSearch.find_queued(alive[i], &"rally", want, eye, false, CoverSearch.POINT_MOVE)
		var spot := _rally_spot(i, cov, s.ai_nav.snap(want))
		_spots.append(spot)
		q.assign(alive[i], _rally_move(spot))
	q.events["fell_back"] = now
	q.say(alive[0] if not alive.is_empty() else null, "fallback", "Fall back! Fall back!", true)


func _rally_move(spot: Vector3) -> SquadMsg.Assignment:
	var a := SquadMsg.Assignment.make(SquadMsg.Task.MOVE, spot)
	a.run = true
	a.crouch = true
	a.role = "fall back"
	return a


## Cover `cov` (null while looked for) for member `i` if it is well back from
## the threat; else `plain`.
func _rally_spot(i: int, cov, plain: Vector3) -> Vector3:
	if cov == null:
		return plain
	var u: Dictionary = _upgrade.get(i, {})
	_upgrade.erase(i)
	var c: Dictionary = cov
	if not c.is_empty() and not u.is_empty() and (c.cover as Vector3).distance_to(u.threat) \
			> (u.center as Vector3).distance_to(u.threat) + 4.0:
		return c.cover
	return plain


## Cover found for members already on their way back: sent on to it.
func _take_cover(q: Squad) -> void:
	for i in _upgrade.keys():
		var u: Dictionary = _upgrade[i]
		var m: Soldier = u.member
		if not is_instance_valid(m) or m.is_dead():
			_upgrade.erase(i)
			continue
		var cov = CoverSearch.find_queued(m, &"rally", u.want,
				(u.threat as Vector3) + Vector3.UP * CoverSearch.STAND_EYE, false, CoverSearch.POINT_MOVE)
		if cov == null:
			continue
		var spot := _rally_spot(i, cov, Vector3.INF)
		if spot != Vector3.INF:
			if i < _spots.size():
				_spots[i] = spot
			q.assign(m, _rally_move(spot))


func _tick(_delta: float) -> Status:
	var q := agent as Squad
	if not _holding:
		_take_cover(q)
	q.play = "fall back"
	blackboard.set_var(&"play", q.play)
	# There, or as far as it could get (BLOCKED): either way it holds now. A
	# member that cannot reach its spot held the whole squad on the move.
	# And a fall back is a run, not a march: FALL_TIME on, whoever is not there
	# holds where it has got to.
	var settled := q.services.now() - _started > FALL_TIME or q.alive().all(func(m: Soldier) -> bool:
		return q.replied(m, SquadMsg.StatusKind.REACHED) or q.replied(m, SquadMsg.StatusKind.BLOCKED))
	if not _holding and settled:
		_holding = true
		var c := q.contact()
		var alive := q.alive()
		for i in alive.size():
			var a := SquadMsg.Assignment.make(SquadMsg.Task.HOLD, alive[i].pawn.feet())
			if c != null:
				var to := c.pos - alive[i].pawn.feet()
				a.yaw = atan2(-to.x, -to.z)
			a.crouch = true
			a.role = "hold"
			q.assign(alive[i], a)
	return RUNNING


func _exit() -> void:
	var q := agent as Squad
	if q != null:
		q.clear_assignments(_gen)
