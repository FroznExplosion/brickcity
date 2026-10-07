@tool
class_name BTDirectedEngage
extends BTAction
## A directed soldier's fight (Docs/AI.md 10.2): in sight and in range, stand and
## shoot; otherwise walk the side's shared flow field toward where the contact
## was, looking that way, shooting whatever shows. No cover, no tactic.
##
## A type with no gun (Roster: melee, bomber) on this cheap tier does the one
## thing it is for: it keeps coming, and in reach it hits, or lights its fuse.

const RANGE := 30.0
const RUN_BEYOND := 20.0


func _tick(_delta: float) -> Status:
	var so := SoldierTree.soldier_of(agent)
	var c := so.contact()
	if c == null:
		so.field_goal = Vector3.INF
		return FAILURE
	var seen := so.sees(c)
	var d := so.pawn.feet().distance_to(c.pos)
	if so.no_gun:
		return _close_in(so, c, d)
	so.fire_ok = seen
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


func _close_in(so: Soldier, c: FactionKnowledge.Contact, d: float) -> Status:
	so.fire_ok = false
	var target: Pawn = c.pawn if c.pawn != null and is_instance_valid(c.pawn) else null
	so.look_at_point(c.pos + Vector3.UP * 1.2)
	if so.attack_kind == "bomber":
		so.state = "directed bomber"
		if d <= Soldier.DETONATE_REACH:
			so.light_fuse()
	elif target != null and d <= so.melee_reach * 0.9:
		so.state = "directed melee"
		so.field_goal = Vector3.INF
		so.stop()
		so.melee(target)
		return RUNNING
	else:
		so.state = "directed charge"
	# Near, a path of its own (the last metres have to arrive); far, the side's
	# shared field, as every directed soldier closes.
	if d <= RANGE:
		so.field_goal = Vector3.INF
		var to := so.approach_point(target.feet() if target != null and so.sees(c) else c.pos, 0.8)
		if to != Vector3.INF:
			so.move_to(to, true)
			return RUNNING
	so.field_goal = c.pos
	so.pawn.intents.run = true
	return RUNNING


func _exit() -> void:
	var so := SoldierTree.soldier_of(agent)
	if so != null:
		so.field_goal = Vector3.INF
		so.fire_ok = false
		so.stop()
