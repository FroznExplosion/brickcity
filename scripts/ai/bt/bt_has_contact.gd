@tool
class_name BTHasContact
extends BTCondition
## The side knows of an enemy, seen or heard no more than `max_age` seconds ago
## (and, with `unsearched`, not already looked for where it was).

@export var max_age := 2.5
@export var unsearched := false


func _generate_name() -> String:
	return "HasContact %.1fs%s" % [max_age, " unsearched" if unsearched else ""]


func _tick(_delta: float) -> Status:
	var so := SoldierTree.soldier_of(agent)
	if so == null or so.is_dead():
		return FAILURE
	var c := so.contact()
	if c == null or c.age(so.services.now()) > max_age:
		return FAILURE
	if unsearched and c.searched:
		return FAILURE
	# Guarding a way out: cover against the door, guns on it.
	var watch := so.watch_point if so.watch_point != Vector3.INF and so.tactic == CombatPolicy.Tactic.TAKE_COVER \
			else c.pos
	blackboard.set_var(&"threat_eye", watch + Gravity.up_at(watch) * CoverSearch.STAND_EYE)
	return SUCCESS
