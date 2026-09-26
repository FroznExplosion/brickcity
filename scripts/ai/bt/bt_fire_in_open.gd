@tool
class_name BTFireInOpen
extends BTAction
## No cover to be had: stand and shoot while the enemy is in sight.


func _tick(_delta: float) -> Status:
	var so := SoldierTree.soldier_of(agent)
	var c := so.contact()
	if c == null or not c.visible:
		so.fire_ok = false
		return FAILURE
	so.state = "fire in open"
	so.stop()
	so.fire_ok = true
	return RUNNING


func _exit() -> void:
	var so := SoldierTree.soldier_of(agent)
	if so != null:
		so.fire_ok = false
