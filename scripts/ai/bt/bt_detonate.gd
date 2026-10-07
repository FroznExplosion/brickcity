@tool
class_name BTDetonate
extends BTAction
## DETONATE (the casebook's "go off", a bomber's move): run at the enemy, light
## the fuse within Soldier.DETONATE_REACH, and keep coming until it goes
## (Soldier.light_fuse / go_off). Fails when there is no way to the enemy; done
## after GIVE_UP seconds without getting there.

const GIVE_UP := 9.0

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
	so.state = "bomber"
	so.fire_ok = false
	so.look_at_point(at + Vector3.UP * 1.2)
	if Vector2(at.x - feet.x, at.z - feet.z).length() <= Soldier.DETONATE_REACH and absf(at.y - feet.y) < 2.0:
		so.light_fuse()
	var to := so.approach_point(at, 0.8)
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
