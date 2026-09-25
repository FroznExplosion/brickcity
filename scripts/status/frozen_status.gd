## frozen_status.gd  (TWO-MESH version)
## Freeze effect wired to the consolidated FreezeVisual (which now owns both the
## ice-shell look AND the limb-shatter on frozen death).
##
## Behavior:
##  - On apply: trigger FreezeVisual.freeze() (mesh swap + pose snapshot + shells),
##              halt AI/nav, record airborne state for fall damage.
##  - While active: damage_taken_factor() multiplies incoming damage (stacks w/ slag).
##                  DoTs KEEP ticking under the ice (per spec decision).
##  - On host death while frozen: FreezeVisual.shatter() — limbs+shells fly off.
##  - On expire (thaw, no death): FreezeVisual.thaw(); restore AI; apply fall damage
##    if it had been frozen mid-air.
##
## Host enemy optional methods (checked via has_method, so plain enemies still work):
##   set_ai_frozen(bool), is_airborne() -> bool, get_velocity() -> Vector3,
##   apply_fall_damage(float)
## Plus a child node named "FreezeVisual".
class_name FrozenStatus
extends StatusEffect

## Incoming damage is multiplied by this while frozen. Stacks with slag, etc.
@export var damage_taken_factor_value: float = 3.0

## Fall-damage scaling applied on thaw if the enemy was frozen mid-air.
@export var airborne_fall_damage_per_unit: float = 8.0

var _was_airborne: bool = false
var _freeze_height: float = 0.0
var _visual: FreezeVisual
var _connected_death: bool = false


func _on_apply() -> void:
	# `_host` (nearest Node3D ancestor) is resolved by StatusEffect.bind() before this runs.
	if _host == null:
		return

	if _host.has_method("is_airborne"):
		_was_airborne = bool(_host.call("is_airborne"))
		_freeze_height = _host.global_position.y

	if _host.has_method("set_ai_frozen"):
		_host.call("set_ai_frozen", true)

	_visual = _host.find_child("FreezeVisual", true, false) as FreezeVisual
	if _visual != null:
		_visual.freeze()

	# Route a frozen death into the shatter instead of the normal death path.
	if _pool != null and not _connected_death:
		_pool.died.connect(_on_host_died)
		_connected_death = true


## Read by StatusManager.damage_taken_multiplier().
func damage_taken_factor() -> float:
	return damage_taken_factor_value


func _on_host_died() -> void:
	if _visual == null:
		return
	var vel: Vector3 = Vector3.ZERO
	if _host != null and _host.has_method("get_velocity"):
		vel = _host.call("get_velocity")
	_visual.shatter(vel)


func _on_expire() -> void:
	if _pool != null and _connected_death and _pool.died.is_connected(_on_host_died):
		_pool.died.disconnect(_on_host_died)
		_connected_death = false

	if _visual != null:
		_visual.thaw()

	if _host == null:
		return

	if _host.has_method("set_ai_frozen"):
		_host.call("set_ai_frozen", false)

	if _was_airborne and _host.has_method("apply_fall_damage"):
		var fell: float = maxf(0.0, _freeze_height - _host.global_position.y)
		if fell > 0.0:
			_host.call("apply_fall_damage", fell * airborne_fall_damage_per_unit)
