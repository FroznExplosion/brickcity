@tool
class_name BTSquadBroken
extends BTCondition
## The squad's morale is broken (Squad.broken).


func _tick(_delta: float) -> Status:
	var q := agent as Squad
	return SUCCESS if q != null and q.broken else FAILURE
