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
	for i in alive.size():
		var want := base + side * (i - (alive.size() - 1) * 0.5) * 2.0
		var cov := CoverSearch.find(s, want, threat + Vector3.UP * CoverSearch.STAND_EYE)
		var spot: Vector3 = cov.cover if not cov.is_empty() \
				and (cov.cover as Vector3).distance_to(threat) > center.distance_to(threat) + 4.0 \
				else s.ai_nav.snap(want)
		_spots.append(spot)
		var a := SquadMsg.Assignment.make(SquadMsg.Task.MOVE, spot)
		a.run = true
		a.crouch = true
		a.role = "fall back"
		q.assign(alive[i], a)
	q.events["fell_back"] = now
	q.say(alive[0] if not alive.is_empty() else null, "fallback", "Fall back! Fall back!", true)


func _tick(_delta: float) -> Status:
	var q := agent as Squad
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
