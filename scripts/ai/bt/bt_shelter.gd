@tool
class_name BTShelter
extends BTAction
## Weather (Docs/Collapse.md 4.4): in a storm, with nothing to fight, get under a
## roof -- off the rooftops and out of the open, where the strokes land. Fails
## outside a storm, and when there is no roof in reach, so the soldier idles.

## How far to look for a roof, and how high one may be over the head.
const REACH := [4.0, 8.0, 13.0, 20.0]
const ROOF_WITHIN := 10.0

var _to := Vector3.INF
var _tried := 0.0


func _enter() -> void:
	_to = Vector3.INF


func _tick(_delta: float) -> Status:
	var so := SoldierTree.soldier_of(agent)
	if so == null or so.is_dead():
		return FAILURE
	var s := so.services
	if not s.storm:
		return FAILURE
	var feet := so.pawn.feet()
	if covered(s, feet):
		so.state = "sheltering"
		so.fire_ok = false
		so.stop()
		return RUNNING
	var now := s.now()
	if _to == Vector3.INF:
		if now < _tried:
			return FAILURE   # looked lately and found nothing
		_to = _find(so, feet)
		if _to == Vector3.INF:
			_tried = now + 5.0
			return FAILURE
	so.state = "to shelter"
	so.fire_ok = false
	var r := so.move_to(_to, true)
	if r == -1 or so.stuck >= Soldier.MAX_STUCK:
		so.stuck = 0
		_to = Vector3.INF
		_tried = now + 2.0
	return RUNNING


## Is there a roof over a body standing here -- anything solid within
## ROOF_WITHIN above its head?
static func covered(s: AIServices, feet: Vector3) -> bool:
	if s.world3d == null:
		return false
	var from := feet + Vector3.UP * (Pawn.BODY_HEIGHT + 0.05)
	var q := PhysicsRayQueryParameters3D.create(from, from + Vector3.UP * ROOF_WITHIN)
	q.collision_mask = Layers.STRUCTURE | Layers.DEBRIS
	return not s.world3d.direct_space_state.intersect_ray(q).is_empty()


## The nearest place in reach with a roof over it: rings of sixteen, nearest
## first, the same order every time.
func _find(so: Soldier, feet: Vector3) -> Vector3:
	var s := so.services
	for r in REACH:
		for k in 16:
			var a := TAU * k / 16.0
			var p := s.ai_nav.snap(feet + Vector3(cos(a), 0.0, sin(a)) * float(r))
			if not s.ai_nav.can_stand(p) or absf(p.y - feet.y) > 3.0:
				continue
			if covered(s, p) and not s.ai_world.in_danger(p + Vector3.UP * 0.9):
				return p
	return Vector3.INF


func _exit() -> void:
	var so := SoldierTree.soldier_of(agent)
	if so != null:
		so.stop()
