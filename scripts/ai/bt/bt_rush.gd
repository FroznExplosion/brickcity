@tool
class_name BTRush
extends BTAction
## RUSH (the casebook's "rush them"): straight at the enemy at a run, firing
## whenever it is in sight, no stopping for cover. Done within CLOSE metres, when
## there is no way, or after GIVE_UP seconds; the tactic is then decided again.

const CLOSE := 4.0
const GIVE_UP := 6.0

var _began := 0.0


func _enter() -> void:
	_began = SoldierTree.soldier_of(agent).services.now()


func _tick(_delta: float) -> Status:
	var so := SoldierTree.soldier_of(agent)
	var c := so.contact()
	if c == null:
		return FAILURE
	var at := c.pos
	if c.visible and c.pawn != null and is_instance_valid(c.pawn):
		at = c.pawn.feet()
	so.state = "rush"
	so.fire_ok = c.visible
	so.look_at_point(at + Vector3.UP * 1.2)
	var feet := so.pawn.feet()
	if Vector2(at.x - feet.x, at.z - feet.z).length() <= CLOSE:
		so.stop()
		so.tactic_done = true
		return SUCCESS
	var to := so.approach_point(at, CLOSE - 1.0)
	if to == Vector3.INF:
		so.tactic_done = true
		return FAILURE
	var r := so.move_to(to, true)
	if r == -1 or so.stuck >= Soldier.MAX_STUCK or so.services.now() - _began > GIVE_UP:
		so.stuck = 0
		so.stop()
		so.tactic_done = true
		return SUCCESS
	return RUNNING


func _exit() -> void:
	var so := SoldierTree.soldier_of(agent)
	if so != null:
		so.fire_ok = false
