@tool
class_name BTPlayFallBack
extends BTAction
## Morale broken (Docs/AI.md 6.3): back to rally cover away from the enemy, then
## hold there, facing it, until the squad has rallied (Squad.RALLY) -- the tree's
## condition above this then fails and the squad takes up its order again.

const BACK := 12.0

var _spots: Array[Vector3] = []
var _holding := false


func _enter() -> void:
	var q := agent as Squad
	var s := q.services
	var now := s.now()
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
	if not _holding and q.all_replied(SquadMsg.StatusKind.REACHED):
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
		q.clear_assignments()
