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
	# Arrived and still in it -- a big or moving danger (a disaster's funnel,
	# a burning floor) -- then look again from here.
	if _to != Vector3.INF and Vector2(feet.x - _to.x, feet.z - _to.z).length() < 1.0:
		_to = Vector3.INF
	if _to == Vector3.INF:
		var best := -1.0
		# Two rings: 6 m gets out from under a falling piece, 14 m out of
		# something the size of a room.
		for ring in [6.0, 14.0]:
			for k in 8:
				var a := TAU * k / 8.0
				var p := so.services.ai_nav.snap(feet + Vector3(cos(a), 0.3, sin(a)) * ring)
				var d := w.danger_distance(p)
				if d > best:
					best = d
					_to = p
	var r := so.move_to(_to, true)
	if r == -1:
		_to = Vector3.INF
	return RUNNING
