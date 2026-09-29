@tool
class_name BTSquadLostContact
extends BTCondition
## The side had a contact and has lost it: not seen for a few seconds, not so long
## ago that it is cold, and not yet searched for.

@export var min_age := 2.5
@export var max_age := 25.0


func _tick(_delta: float) -> Status:
	var q := agent as Squad
	var c := q.contact()
	if c == null or c.visible or c.searched:
		return FAILURE
	var age := c.age(q.services.now())
	return SUCCESS if age >= min_age and age <= max_age else FAILURE
