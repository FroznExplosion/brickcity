@tool
class_name BTInDanger
extends BTCondition
## Something big is falling nearby (AIWorld danger boxes).

@export var within := 2.0


func _tick(_delta: float) -> Status:
	var so := SoldierTree.soldier_of(agent)
	if so == null or so.is_dead():
		return FAILURE
	return SUCCESS if so.services.ai_world.danger_distance(so.pawn.feet()) < within else FAILURE
