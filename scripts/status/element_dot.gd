class_name ElementDoT
extends StatusEffect
## Generic elemental status. Two modes:
##   DoT (is_freeze = false): ticks damage_per_tick to the tuned layer and drives the
##     target's element overlay on `overlay_channel` (coat / burn / pulse).
##   Freeze (is_freeze = true): no DoT; halts the target, drives the freeze overlay
##     (frost → popsicle), applies a damage-taken multiplier, and shatters on death.
## The overlay/flash/shatter calls are has_method-guarded so plain targets still take
## the damage.

@export var glow_color: Color = Color.WHITE
@export var overlay_channel: StringName = &"coat"   ## coat | burn | pulse (DoT mode)
@export var is_freeze: bool = false
@export var frozen_mult: float = 3.0

var _target_node: Node
var _death_bound: bool = false


func _on_apply() -> void:
	_target_node = _manager.get_parent() if _manager != null else null
	if is_freeze:
		_call(&"set_frozen", [true, glow_color])
		if _pool != null and not _death_bound:
			_pool.died.connect(_on_frozen_death)
			_death_bound = true
	else:
		_call(&"set_element", [status_id, glow_color, overlay_channel, true])
		_flash()


func _on_tick() -> void:
	if is_freeze:
		return
	_deal_dot(damage_per_tick)
	_flash()


func _on_expire() -> void:
	if is_freeze:
		_call(&"set_frozen", [false, glow_color])
		if _pool != null and _death_bound and _pool.died.is_connected(_on_frozen_death):
			_pool.died.disconnect(_on_frozen_death)
			_death_bound = false
	else:
		_call(&"set_element", [status_id, glow_color, overlay_channel, false])


## Read by StatusManager.damage_taken_multiplier() — frozen targets take extra damage.
func damage_taken_factor() -> float:
	return frozen_mult if is_freeze else 1.0


func _on_frozen_death() -> void:
	_call(&"shatter", [glow_color])


func _flash() -> void:
	_call(&"pulse", [glow_color, 1.0])


func _call(method: StringName, args: Array) -> void:
	if _target_node != null and _target_node.has_method(method):
		_target_node.callv(method, args)
