class_name ScalingCurve
extends Resource
## The shared level→damage curve (GUN_SCALING_SPEC §2). Sampled at discrete tier
## anchors (PROGRESSION §1), never per player level. Cached cumulative product —
## computed once, indexed by level. Never recompute per shot.
##
## Shipping DECELERATING values reproduce GUN_SCALING §2.3 (base 100):
##   mult(1)=1.0  mult(10)=3.40  mult(50)=296.6  mult(100)=8000.

enum Mode { CONSTANT, DECELERATING }

@export var mode: Mode = Mode.DECELERATING
@export var max_level: int = 100
@export var per_level_rate: float = 0.07          ## CONSTANT mode
@export var start_rate: float = 0.15              ## DECELERATING: early %/level
@export var end_rate: float = 0.039866            ## DECELERATING: near-max %/level

var _cache: PackedFloat64Array = PackedFloat64Array()


func _rate_at(level: int) -> float:
	if mode == Mode.CONSTANT:
		return per_level_rate
	var t := float(level - 2) / float(max_level - 1)
	return lerpf(start_rate, end_rate, clampf(t, 0.0, 1.0))


func _ensure_cache() -> void:
	if _cache.size() == max_level + 1:
		return
	_cache = PackedFloat64Array()
	_cache.resize(max_level + 1)
	_cache[0] = 1.0
	_cache[1] = 1.0
	for level in range(2, max_level + 1):
		_cache[level] = _cache[level - 1] * (1.0 + _rate_at(level))


## Multiplier applied to a class's base damage at a given (hidden) level.
func level_multiplier(level: int) -> float:
	_ensure_cache()
	return _cache[clampi(level, 1, max_level)]
