class_name AimModel
extends RefCounted
## Where an agent's error lives (Docs/AI.md 5.1): it fires the same gun through
## the same calls as the player, and misses because its AIM is off, not because
## its bullets are nerfed. A reaction time before the first round; a cone that
## starts wide and tightens the longer it tracks the same target; losing the
## target resets it. Difficulty is these numbers.

## Seconds from first sight to first round.
var reaction := 0.35
## The error cone, degrees: where it starts, where it settles, how long to settle.
var cone_start := 7.0
var cone_min := 1.2
var settle := 1.6
## How often the error point wanders, seconds.
var wander := 0.25

var rng: RandomNumberGenerator
var _tracking: Pawn
var _since := -INF
var _offset := Vector2.ZERO
var _next_wander := -INF


func _init(p_rng: RandomNumberGenerator) -> void:
	rng = p_rng


## Track `target` (or nothing). Call every tick it is visible.
func track(target: Pawn, now: float) -> void:
	if target != _tracking:
		_tracking = target
		_since = now if target != null else -INF


func cone_deg(now: float) -> float:
	var t := clampf((now - _since) / settle, 0.0, 1.0)
	return lerpf(cone_start, cone_min, t)


func ready_to_fire(now: float) -> bool:
	return _tracking != null and now - _since >= reaction


## Where to point, as [yaw, pitch], looking from `eye` at `point` with the
## current error applied.
func aim(eye: Vector3, point: Vector3, now: float) -> Vector2:
	if now >= _next_wander:
		_next_wander = now + wander
		var r := sqrt(rng.randf())
		var a := rng.randf() * TAU
		_offset = Vector2(cos(a), sin(a)) * r
	var to := point - eye
	var yaw := atan2(-to.x, -to.z)
	var pitch := atan2(to.y, Vector2(to.x, to.z).length())
	var err := deg_to_rad(cone_deg(now))
	return Vector2(yaw + _offset.x * err, pitch + _offset.y * err)
