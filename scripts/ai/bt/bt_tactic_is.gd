@tool
class_name BTTacticIs
extends BTCondition
## The soldier's chosen tactic (BTChooseTactic) is one of `tactics`.

@export var tactics: Array[int] = []


func _generate_name() -> String:
	return "TacticIs %s" % [tactics.map(func(t): return CombatPolicy.TACTIC_NAMES[t])]


func _tick(_delta: float) -> Status:
	var so := SoldierTree.soldier_of(agent)
	if so == null or so.is_dead():
		return FAILURE
	return SUCCESS if so.tactic in tactics else FAILURE
