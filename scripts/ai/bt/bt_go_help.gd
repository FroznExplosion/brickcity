@tool
class_name BTGoHelp
extends BTAction
## A buddy called for help (Soldier.call_for_help): go to it. FAILURE with no
## call standing; done when there, when there is no way, or when the call runs
## out. Below a fight in the tree -- seeing the enemy on the way wins.

const THERE := 3.0


func _tick(_delta: float) -> Status:
	var so := SoldierTree.soldier_of(agent)
	var s := so.services
	var now := s.now()
	if so.help_point == Vector3.INF or now > so.help_until:
		so.help_point = Vector3.INF
		return FAILURE
	so.state = "going to help"
	so.fire_ok = false
	so.look_at_point(so.help_point + Vector3.UP * 1.2)
	var r := so.move_to(so.help_point, true)
	if r != 0 or so.pawn.feet().distance_to(so.help_point) < THERE \
			or so.stuck >= Soldier.MAX_STUCK:
		if r == 1 or so.pawn.feet().distance_to(so.help_point) < THERE:
			s.say(so.pawn, "help_here", ["I'm here, move!", "Got you, go!", "On your six!"][
					s.rng.randi() % 3])
		so.stuck = 0
		so.help_point = Vector3.INF
		so.stop()
		return SUCCESS
	return RUNNING
