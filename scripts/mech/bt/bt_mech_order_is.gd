@tool
class_name BTMechOrderIs
extends BTCondition
## The player's mech holds this order.

@export var order := 0


func _tick(_delta: float) -> Status:
	var br := MechTree.brain_of(agent)
	return SUCCESS if br != null and not br.is_dead() and br.order == order else FAILURE
