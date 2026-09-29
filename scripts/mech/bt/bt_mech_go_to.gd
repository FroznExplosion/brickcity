@tool
class_name BTMechGoTo
extends BTAction
## ATTACK_AREA (AI.md 2.1): to the point the pilot aimed at, and stay, engaging
## anything in the area -- the brain shoots whatever it sees.

const ARRIVED := 3.0


func _tick(_delta: float) -> Status:
	var br := MechTree.brain_of(agent)
	var feet := br.mech.feet()
	if Vector2(feet.x - br.order_point.x, feet.z - br.order_point.z).length() > ARRIVED:
		br.state = "to area"
		br.move_to(br.order_point, true)
	else:
		br.state = "in area"
		br.stop()
	return RUNNING
