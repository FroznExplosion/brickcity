@tool
class_name BTMechIdle
extends BTAction
## Nothing to do: stand, and look about slowly.


func _tick(_delta: float) -> Status:
	var br := MechTree.brain_of(agent)
	if br == null:
		return FAILURE
	br.state = "idle"
	br.breach_point = Vector3.INF
	br.stop()
	br.mech.intents.aim_yaw += 0.25 / MechBrain.THINK_HZ
	return RUNNING
