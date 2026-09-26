@tool
class_name BTSearch
extends BTAction
## Lost it: go to where it was last seen or heard, and look round. Nothing there,
## and the contact is marked searched.

const LOOK := 4.0

var _arrived_at := -1.0


func _enter() -> void:
	_arrived_at = -1.0


func _tick(_delta: float) -> Status:
	var so := SoldierTree.soldier_of(agent)
	var c := so.contact()
	if c == null:
		return FAILURE
	so.fire_ok = false
	so.state = "search"
	var now := so.services.now()
	if _arrived_at < 0.0:
		so.look_at_point(c.pos + Vector3.UP * 1.2)
		var r := so.move_to(c.pos)
		if r == 1 or so.pawn.feet().distance_to(c.pos) < 1.2:
			_arrived_at = now
		elif r == -1:
			_arrived_at = now   # cannot get there: look from here
		return RUNNING
	# There: sweep the head round.
	so.pawn.intents.look_yaw += 2.2 / Soldier.THINK_HZ
	so.stop()
	if now - _arrived_at > LOOK:
		c.searched = true
		return SUCCESS
	return RUNNING

