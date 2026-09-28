@tool
class_name BTManoeuvre
extends BTAction
## PUSH and FLANK (CombatPolicy): move on the enemy, firing whenever it is in
## sight. A push closes straight in to PUSH_TO metres; a flank goes round to
## the enemy's side -- a point a quarter turn round it, at much the range it is
## at now -- picking the side it can reach. Done when there, when there is no
## way, or after GIVE_UP seconds; the tactic is then decided again.

const PUSH_TO := 8.0
const FLANK_RANGE := [9.0, 18.0]
const GIVE_UP := 7.0

var _to := Vector3.INF
var _began := 0.0


func _enter() -> void:
	_to = Vector3.INF
	_began = SoldierTree.soldier_of(agent).services.now()


func _tick(_delta: float) -> Status:
	var so := SoldierTree.soldier_of(agent)
	var s := so.services
	var c := so.contact()
	if c == null:
		return FAILURE
	var feet := so.pawn.feet()
	var push := so.tactic == CombatPolicy.Tactic.PUSH
	so.state = "push" if push else "flank"
	so.fire_ok = c.visible
	so.look_at_point(c.pos + Vector3.UP * 1.2)
	if _to == Vector3.INF:
		_to = _push_point(so, feet, c.pos) if push else _flank_point(so, feet, c.pos)
		if _to == Vector3.INF:
			so.tactic_done = true
			return FAILURE
	var r := so.move_to(_to, not c.visible)
	if r != 0 or so.stuck >= Soldier.MAX_STUCK or s.now() - _began > GIVE_UP:
		so.stuck = 0
		so.stop()
		so.tactic_done = true
		return SUCCESS
	return RUNNING


func _push_point(so: Soldier, feet: Vector3, enemy: Vector3) -> Vector3:
	var to := Vector3(enemy.x - feet.x, 0.0, enemy.z - feet.z)
	var d := to.length()
	if d <= PUSH_TO + 1.0:
		return Vector3.INF
	var p := so.services.ai_nav.snap(feet + to / d * (d - PUSH_TO))
	return p if so.services.ai_nav.can_stand(p) else Vector3.INF


func _flank_point(so: Soldier, feet: Vector3, enemy: Vector3) -> Vector3:
	var s := so.services
	var from := Vector3(feet.x - enemy.x, 0.0, feet.z - enemy.z)
	var d := clampf(from.length(), FLANK_RANGE[0], FLANK_RANGE[1])
	var a0 := atan2(from.z, from.x)
	# Either side, the nearer-to-free one first: fewer friends already there.
	var sides := [1.0, -1.0] if s.rng.randf() < 0.5 else [-1.0, 1.0]
	for side in sides:
		for turn in [PI * 0.5, PI * 0.35]:
			var a: float = a0 + side * turn
			var want := Vector3(enemy.x + cos(a) * d, feet.y, enemy.z + sin(a) * d)
			var p := s.ai_nav.snap(want)
			if s.ai_nav.can_stand(p) and Vector2(p.x - want.x, p.z - want.z).length() < 2.5 \
					and not s.ai_world.in_danger(p + Vector3.UP * 0.9):
				return p
	return Vector3.INF


func _exit() -> void:
	var so := SoldierTree.soldier_of(agent)
	if so != null:
		so.fire_ok = false
