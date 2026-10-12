@tool
class_name BTMechBreach
extends BTAction
## Infantry it knows are in there, behind bricks (Docs/AI.md 6.4): a mech cannot
## follow them in, so it takes the building away. Within RANGE of them, the
## launcher goes into the first brick on the line from the cockpit to where they
## were last known, until that line is open and the brain sees them. Further off,
## it walks nearer on the mech map first.
##
## Asked by its squad for a way in (TacticsSense.ask_way, the casebook's
## heavy_way): the doorway they asked for instead, at their height, until it is
## open (TacticsSense.way_open).

const RANGE := 35.0
## An asked doorway: the first brick on its line this near it, or it goes round,
## to stand this far out in front of it.
const WAY_NEAR := 2.5
const WAY_STAND := 9.0


func _tick(_delta: float) -> Status:
	var br := MechTree.brain_of(agent)
	var target: Vector3 = blackboard.get_var(&"target", br.mech.feet(), false)
	var chest := target + Vector3.UP * 1.1
	var feet := br.mech.feet()
	var way := TacticsSense.way_asked(br.mech, br.services.now())
	var into := Vector3.ZERO
	if way != Vector3.INF:
		into = Vector3(target.x - way.x, 0.0, target.z - way.z)
		into = into.normalized() if into.length() > 0.1 else Vector3(way.x - feet.x, 0.0, way.z - feet.z).normalized()
		if TacticsSense.way_open(br.services, way - into * 3.0, way):
			TacticsSense.way_done(br.mech)
			br.made_ways += 1
			way = Vector3.INF
		else:
			# Into the wall, at the knee: the hole a soldier walks through.
			target = way + into * 0.6
			chest = target + Vector3.UP * 0.9
	var d := feet.distance_to(target)
	if d > RANGE or br.launcher == null:
		br.breach_point = Vector3.INF
		br.state = "close in"
		var r := br.move_to(target.lerp(feet, (RANGE * 0.7) / maxf(d, 0.01)), true)
		return FAILURE if r == -1 else RUNNING
	var hit: Dictionary = br.services.ai_world.trace(br.eye(), chest)
	# Another wall first: round to the side the squad asked for, out in front
	# of the doorway.
	if way != Vector3.INF and bool(hit.get("hit", false)) and (hit.point as Vector3).distance_to(target) > WAY_NEAR:
		br.breach_point = Vector3.INF
		br.state = "to the way"
		var r := br.move_to(way - into * WAY_STAND, true)
		return FAILURE if r == -1 else RUNNING
	br.stop()
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
