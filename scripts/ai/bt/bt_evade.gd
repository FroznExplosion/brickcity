@tool
class_name BTEvade
extends BTAction
## Get out from under it: to whichever nearby spot is furthest from danger.

var _to := Vector3.INF


func _enter() -> void:
	_to = Vector3.INF


func _tick(_delta: float) -> Status:
	var so := SoldierTree.soldier_of(agent)
	var w := so.services.ai_world
	so.state = "evade"
	so.fire_ok = false
	var feet := so.pawn.feet()
	if w.danger_distance(feet) > 3.0:
		so.stop()
		return SUCCESS
	if _to == Vector3.INF:
		var best := -1.0
		for k in 8:
			var a := TAU * k / 8.0
			var p := so.services.ai_nav.snap(feet + Vector3(cos(a), 0.3, sin(a)) * 6.0)
			var d := w.danger_distance(p)
			if d > best:
				best = d
				_to = p
	var r := so.move_to(_to, true)
	if r == -1:
		_to = Vector3.INF
	return RUNNING
