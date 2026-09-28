@tool
class_name BTFireInOpen
extends BTAction
## No cover to be had: shoot while the enemy is in sight -- and keep moving. A
## figure standing still in the open is the easiest thing in the city to hit,
## and standing still is what this did: every soldier the combat arena could
## not find cover for stood on its spawn point until it died. Now it moves on a
## short cycle, firing all the while (aiming does not care about the legs):
## closing in from far off, backing away from close up, and otherwise stepping
## across the enemy's line, first one way and then the other.

## Seconds before picking the next place to step to.
const STEP_EVERY := [1.2, 2.4]
## How far each step goes.
const STRAFE := [2.5, 5.0]
## Beyond this it closes in; inside CLOSE it backs off.
const FAR := 26.0
const CLOSE := 7.0

var _to := Vector3.INF
var _next := 0.0
var _side := 1.0


func _enter() -> void:
	_to = Vector3.INF
	_next = 0.0


func _tick(_delta: float) -> Status:
	var so := SoldierTree.soldier_of(agent)
	var c := so.contact()
	if c == null or not c.visible:
		so.fire_ok = false
		return FAILURE
	so.state = "fire in open"
	so.fire_ok = true
	var s := so.services
	var now := s.now()
	var feet := so.pawn.feet()
	if _to == Vector3.INF or now >= _next:
		_to = _pick(so, feet, c.pos)
		_next = now + s.rng.randf_range(STEP_EVERY[0], STEP_EVERY[1])
	if _to == Vector3.INF:
		so.stop()
		return RUNNING
	var r := so.move_to(_to)
	if r != 0 or so.stuck >= Soldier.MAX_STUCK:
		so.stuck = 0
		# There, or no way there: the next step now.
		_to = Vector3.INF
		so.stop()
	return RUNNING


## The next place to step to: somewhere a body stands, along the chosen line.
func _pick(so: Soldier, feet: Vector3, enemy: Vector3) -> Vector3:
	var s := so.services
	var to := Vector3(enemy.x - feet.x, 0.0, enemy.z - feet.z)
	var d := to.length()
	if d < 0.01:
		return Vector3.INF
	var ahead := to / d
	var across := Vector3(-ahead.z, 0.0, ahead.x)
	_side = -_side
	var step := s.rng.randf_range(STRAFE[0], STRAFE[1])
	var dir := across * _side
	if d > FAR:
		dir = (ahead * 0.8 + across * _side * 0.4).normalized()
	elif d < CLOSE:
		dir = (-ahead * 0.8 + across * _side * 0.4).normalized()
	# Try the chosen way, then the other side.
	for attempt in 2:
		var p := s.ai_nav.snap(feet + dir * step)
		if s.ai_nav.can_stand(p) and Vector2(p.x - feet.x, p.z - feet.z).length() > 1.0 \
				and not s.ai_world.in_danger(p + Vector3.UP * 0.9):
			return p
		dir = Vector3(-dir.x, 0.0, -dir.z) if d >= CLOSE and d <= FAR else dir.rotated(Vector3.UP, PI * 0.5)
	return Vector3.INF


func _exit() -> void:
	var so := SoldierTree.soldier_of(agent)
	if so != null:
		so.fire_ok = false
		so.stop()
