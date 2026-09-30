@tool
class_name BTMechHoldRange
extends BTAction
## In sight: the brain is already shooting. Close to FAR if further, back off to
## NEAR if closer -- a mech fights at range, and a figure under its feet is one it
## cannot see.

const NEAR := 12.0
const FAR := 45.0


func _tick(_delta: float) -> Status:
	var br := MechTree.brain_of(agent)
	br.breach_point = Vector3.INF
	var target: Vector3 = blackboard.get_var(&"target", br.mech.feet(), false)
	var d := br.mech.feet().distance_to(target)
	br.state = "engage"
	if d > FAR:
		br.move_to(target.lerp(br.mech.feet(), 0.3), true)
	elif d < NEAR:
		var away := br.mech.feet() - target
		away.y = 0.0
		br.move_to(br.mech.feet() + away.normalized() * 6.0)
	else:
		br.stop()
	return RUNNING


func _exit() -> void:
	var br := MechTree.brain_of(agent)
	if br != null:
		br.stop()
