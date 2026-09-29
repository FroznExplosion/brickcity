@tool
class_name BTHasAssignment
extends BTCondition
## The soldier's squad has given it something to do (a live Assignment). An
## order outranks the soldier's own fight: the squad's plan is the plan.


func _tick(_delta: float) -> Status:
	var so := SoldierTree.soldier_of(agent)
	if so == null or so.is_dead() or so.assignment == null:
		return FAILURE
	if so.services.now() > so.assignment.until:
		so.report(SquadMsg.StatusKind.BLOCKED)
		so.set_assignment(null)
		return FAILURE
	return SUCCESS
