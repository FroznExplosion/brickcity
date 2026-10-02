@tool
class_name BTMelee
extends BTAction
## MELEE (the casebook's "charge to melee"): run at the enemy and hit it once in
## reach (Soldier.melee), every Soldier.MELEE_GAP seconds while it stays there.
## Holds fire while charging. Fails when there is no way or the enemy is beyond
## GIVE_UP_RANGE (the tree then fights in the open); done after GIVE_UP seconds.

const GIVE_UP := 7.0
const GIVE_UP_RANGE := 25.0

var _began := 0.0


func _enter() -> void:
	_began = SoldierTree.soldier_of(agent).services.now()


func _tick(_delta: float) -> Status:
	var so := SoldierTree.soldier_of(agent)
	var c := so.contact()
	if c == null:
		return FAILURE
	var target: Pawn = c.pawn if c.pawn != null and is_instance_valid(c.pawn) else null
	var at := target.feet() if target != null and c.visible else c.pos
	var feet := so.pawn.feet()
	var d := Vector2(at.x - feet.x, at.z - feet.z).length()
	so.state = "melee"
	so.fire_ok = false
	if d > GIVE_UP_RANGE:
		so.tactic_done = true
		return FAILURE
	so.look_at_point(at + Vector3.UP * 1.2)
	if target != null and d <= Soldier.MELEE_REACH * 0.9:
		so.stop()
		so.melee(target)
		return RUNNING
	var to := so.approach_point(at, Soldier.MELEE_REACH * 0.6)
	if to == Vector3.INF:
		so.tactic_done = true
		return FAILURE
	var r := so.move_to(to, true)
	if r == -1 or so.stuck >= Soldier.MAX_STUCK:
		so.stuck = 0
		so.stop()
		so.tactic_done = true
		return FAILURE
	if so.services.now() - _began > GIVE_UP:
		so.tactic_done = true
		return SUCCESS
	return RUNNING
