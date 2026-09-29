@tool
class_name BTMechBreach
extends BTAction
## Infantry it knows are in there, behind bricks (Docs/AI.md 6.4): a mech cannot
## follow them in, so it takes the building away. Within RANGE of them, the
## launcher goes into the first brick on the line from the cockpit to where they
## were last known, until that line is open and the brain sees them. Further off,
## it walks nearer on the mech map first.

const RANGE := 35.0


func _tick(_delta: float) -> Status:
	var br := MechTree.brain_of(agent)
	var target: Vector3 = blackboard.get_var(&"target", br.mech.feet(), false)
	var chest := target + Vector3.UP * 1.1
	var feet := br.mech.feet()
	var d := feet.distance_to(target)
	if d > RANGE or br.launcher == null:
		br.breach_point = Vector3.INF
		br.state = "close in"
		var r := br.move_to(target.lerp(feet, (RANGE * 0.7) / maxf(d, 0.01)), true)
		return FAILURE if r == -1 else RUNNING
	br.stop()
	var hit: Dictionary = br.services.ai_world.trace(br.eye(), chest)
	if not bool(hit.get("hit", false)):
		br.breach_point = Vector3.INF
		br.state = "line open"
		br.face(target)
		return RUNNING
	br.breach_point = hit.point
	br.state = "breach"
	return RUNNING


func _exit() -> void:
	var br := MechTree.brain_of(agent)
	if br != null:
		br.breach_point = Vector3.INF
