class_name MechCommand
extends RefCounted
## The one button (Docs/AI.md 2.1, A4): the pilot's whole say over their mech
## once out of it.
##
##   TAP                    FOLLOW <-> HOLD (HOLD where the mech stands)
##   HOLD, while aiming     ATTACK_AREA at the point the pilot's aim ray lands on
##                          -- a street, a window, a building
##
## Both fight back whatever the order: the brain shoots what it sees.

## Held this long, it is a hold and not a tap.
const HOLD_SECONDS := 0.35

var brain: MechBrain
var _down_at := -1.0


func _init(p_brain: MechBrain, pilot: Pawn) -> void:
	brain = p_brain
	brain.leader = pilot


func press(now: float) -> void:
	_down_at = now


## Let go at `now`, the pilot aiming at `aim_point` (INF: at nothing). Returns
## the order it gave.
func release(now: float, aim_point: Vector3) -> int:
	if _down_at < 0.0:
		return brain.order
	var held := now - _down_at
	_down_at = -1.0
	if held >= HOLD_SECONDS and aim_point != Vector3.INF:
		brain.order = MechBrain.Order.ATTACK_AREA
		brain.order_point = aim_point
	elif brain.order == MechBrain.Order.FOLLOW:
		brain.order = MechBrain.Order.HOLD
		brain.order_point = brain.mech.feet()
	else:
		brain.order = MechBrain.Order.FOLLOW
	return brain.order


func is_down() -> bool:
	return _down_at >= 0.0
