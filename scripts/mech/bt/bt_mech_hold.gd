@tool
class_name BTMechHold
extends BTAction
## HOLD (AI.md 2.1): the spot it was told, and it stays there. It still fights.


func _tick(_delta: float) -> Status:
	var br := MechTree.brain_of(agent)
	br.state = "hold"
	var feet := br.mech.feet()
	if Vector2(feet.x - br.order_point.x, feet.z - br.order_point.z).length() > 2.0:
		br.move_to(br.order_point)
	else:
		br.stop()
	return RUNNING
