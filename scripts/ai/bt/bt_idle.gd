@tool
class_name BTIdle
extends BTAction
## Nothing known: hold, and look about slowly.


func _tick(_delta: float) -> Status:
	var so := SoldierTree.soldier_of(agent)
	if so == null or so.is_dead():
		return FAILURE
	so.state = "idle"
	so.fire_ok = false
	so.stop()
	so.pawn.intents.look_yaw += 0.35 / Soldier.THINK_HZ
	so.pawn.intents.look_pitch = 0.0
	return RUNNING
