@tool
class_name BTMechKnows
extends BTCondition
## The side knows of a hostile no more than `max_age` seconds old -- and, with
## `in_sight`, this mech has it in sight now.

@export var max_age := 20.0
@export var in_sight := false


func _tick(_delta: float) -> Status:
	var br := MechTree.brain_of(agent)
	if br == null or br.is_dead():
		return FAILURE
	var c := br.contact()
	if c == null or c.age(br.services.now()) > max_age:
		return FAILURE
	if in_sight and not c.seen_by.has(br.get_instance_id()):
		return FAILURE
	blackboard.set_var(&"target", c.pos)
	return SUCCESS
