@tool
class_name BTMechIdle
extends BTAction
## Nothing to do: stand, and look about slowly -- or, with somewhere its
## commander wants it (MechBrain.rally) and further than NEAR from it, walk there.

const NEAR := 12.0


func _tick(_delta: float) -> Status:
	var br := MechTree.brain_of(agent)
	if br == null:
		return FAILURE
	br.breach_point = Vector3.INF
	if br.rally != Vector3.INF:
		var feet := br.mech.feet()
		if Vector2(feet.x - br.rally.x, feet.z - br.rally.z).length() > NEAR:
			br.state = "to the fight"
			br.move_to(br.rally)
			return RUNNING
	br.state = "idle"
	br.stop()
	br.mech.intents.aim_yaw += 0.25 / MechBrain.THINK_HZ
	return RUNNING
