@tool
class_name BTDirectedEngage
extends BTAction
## A directed soldier's fight (Docs/AI.md 10.2): in sight and in range, stand and
## shoot; otherwise walk the side's shared flow field toward where the contact
## was, looking that way, shooting whatever shows. No cover, no tactic.

const RANGE := 30.0
const RUN_BEYOND := 20.0


func _tick(_delta: float) -> Status:
	var so := SoldierTree.soldier_of(agent)
	var c := so.contact()
	if c == null:
		so.field_goal = Vector3.INF
		return FAILURE
	var seen := so.sees(c)
	so.fire_ok = seen
	var d := so.pawn.feet().distance_to(c.pos)
	if seen and d <= RANGE:
		so.state = "directed fire"
		so.field_goal = Vector3.INF
		so.stop()
	else:
		so.state = "directed close"
		so.field_goal = c.pos
		so.pawn.intents.run = d > RUN_BEYOND
		so.look_at_point(c.pos + Vector3.UP * 1.2)
	return RUNNING


func _exit() -> void:
	var so := SoldierTree.soldier_of(agent)
	if so != null:
		so.field_goal = Vector3.INF
		so.fire_ok = false
		so.stop()
