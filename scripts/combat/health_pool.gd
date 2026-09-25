## health_pool.gd
## Holds an enemy's ordered defense layers (index 0 = outermost / top bar).
## Two damage paths:
##   apply_impact()         -> hits the topmost living layer (bullets).
##   apply_to_layer_type()  -> hits a specific layer directly (DoT bypass).
class_name HealthPool
extends Node

signal layer_depleted(layer_type: StringName)
signal died()

## Ordered top -> bottom. Outermost defense first (e.g. [shield, armor, health]).
@export var layer_configs: Array[DefenseLayer] = []

## Shared matrix used to scale damage by element vs layer type.
@export var matrix: EffectivenessMatrix

## If true, impact overkill spills into the next layer. Default false (BL-like).
@export var impact_carries_over: bool = false

## Draining THIS layer kills the enemy even if barrier layers above it still stand
## (SPEC Amendment A.3 — matched-element bypass can core-kill through shields/armor).
## -1 = the bottom-most (last) layer, the usual vital/health bar.
@export var vital_layer_index: int = -1

# Runtime parallel arrays to layer_configs.
var _current: Array[float] = []
var _regen_timer: Array[float] = []
var _is_dead: bool = false


func _ready() -> void:
	_rebuild_state()


func _rebuild_state() -> void:
	_current.clear()
	_regen_timer.clear()
	for cfg in layer_configs:
		_current.append(cfg.max_value)
		_regen_timer.append(0.0)
	_is_dead = false


func _physics_process(delta: float) -> void:
	if _is_dead:
		return
	for i in range(layer_configs.size()):
		var cfg: DefenseLayer = layer_configs[i]
		if cfg.regen_rate <= 0.0:
			continue
		if _regen_timer[i] > 0.0:
			_regen_timer[i] -= delta
			continue
		if _current[i] < cfg.max_value:
			_current[i] = minf(cfg.max_value, _current[i] + cfg.regen_rate * delta)


## Index of the topmost layer with value remaining, or -1 if all depleted.
func _topmost_living_index() -> int:
	for i in range(_current.size()):
		if _current[i] > 0.0:
			return i
	return -1


## Index of the first living layer matching layer_type, or -1 if none.
func _index_of_living_type(layer_type: StringName) -> int:
	for i in range(layer_configs.size()):
		if layer_configs[i].layer_type == layer_type and _current[i] > 0.0:
			return i
	return -1


func _multiplier_for(element_id: StringName, layer_index: int) -> float:
	if matrix == null:
		return 1.0
	return matrix.get_multiplier(element_id, layer_configs[layer_index].layer_type)


## Apply post-multiplier external scaling (slag, frozen, crit) here once.
## extra_multiplier lets DamageSystem compose those before subtraction.
## NOTE on carry-over: "remaining" is tracked in raw (pre-element-multiplier)
## terms so each new layer applies its own multiplier fairly. The amount a layer
## absorbs is converted back to raw before subtracting from remaining.
func apply_impact(amount: float, element_id: StringName, extra_multiplier: float = 1.0) -> void:
	if _is_dead:
		return
	var raw_remaining: float = amount * extra_multiplier
	while raw_remaining > 0.0:
		var idx: int = _topmost_living_index()
		if idx == -1:
			break
		var mult: float = _multiplier_for(element_id, idx)
		var scaled_incoming: float = raw_remaining * mult
		var available: float = _current[idx]
		var scaled_absorbed: float = minf(scaled_incoming, available)
		var landed: float = _damage_index(idx, scaled_absorbed, element_id)
		if not impact_carries_over:
			break
		# A layer that absorbed NOTHING cannot absorb any more of this, and it is still the
		# topmost living one — so without this the loop re-picks it forever. That is exactly what
		# a `damage_filter` holding a floor does: the layer never depletes, and a large enough
		# hit grinds through billions of iterations before `raw_remaining` runs out.
		if landed <= 0.0:
			break
		# Convert what this layer soaked up back into raw terms and continue.
		if mult <= 0.0:
			break
		raw_remaining -= landed / mult
	_check_death()


## DoT bypass: damage a specific layer type directly, ignoring layers above it.
## Falls back to the topmost living layer if that type is absent/depleted.
func apply_to_layer_type(amount: float, layer_type: StringName, element_id: StringName) -> void:
	if _is_dead:
		return
	var idx: int = _index_of_living_type(layer_type)
	if idx == -1:
		idx = _topmost_living_index()
	if idx == -1:
		return
	var dmg: float = amount * _multiplier_for(element_id, idx)
	_damage_index(idx, dmg, element_id)
	_check_death()


## Optional. `func(amount: float, layer_index: int, element_id: StringName) -> float` returning
## how much of that damage is actually allowed to land.
##
## The element is carried through because the two things that need this hook both key off it: a
## floor that differs by what is doing the damage, and knowing what finally broke a layer.
##
## The ONE place to make a "this thing cannot be reduced past here" rule an invariant rather than
## a convention. Every path into this pool — impacts, layer-targeted DoTs, splash, a weapon nobody
## has written yet — funnels through `_damage_index`, so a floor enforced here cannot be breached
## by a caller that forgot to ask. Enforcing it caller-side instead means the rule holds only for
## the damage sources that remembered, which is exactly as strong as not having the rule.
var damage_filter: Callable


## Returns how much actually landed, which is NOT always what was asked for once a
## [member damage_filter] is installed. Callers that loop over layers must use the return value:
## a layer that absorbed nothing is still the topmost living one, so treating the request as
## absorbed re-picks it forever.
func _damage_index(idx: int, dmg: float, element_id: StringName = &"") -> float:
	if damage_filter.is_valid():
		dmg = maxf(float(damage_filter.call(dmg, idx, element_id)), 0.0)
	if dmg <= 0.0:
		return 0.0
	var before: float = _current[idx]
	_current[idx] = maxf(0.0, _current[idx] - dmg)
	_regen_timer[idx] = layer_configs[idx].regen_delay
	if _current[idx] <= 0.0:
		layer_depleted.emit(layer_configs[idx].layer_type)
	return before - _current[idx]


## Resolved vital layer index (-1 export → bottom-most live layer).
func _vital_index() -> int:
	if vital_layer_index >= 0 and vital_layer_index < _current.size():
		return vital_layer_index
	return _current.size() - 1


## Death (Amendment A.3): the enemy dies the instant its VITAL layer hits 0 — even if
## barrier layers above it remain — OR when every layer is depleted (kinetic top-down).
func _check_death() -> void:
	if _is_dead:
		return
	var vital := _vital_index()
	var vital_dead := vital >= 0 and vital < _current.size() and _current[vital] <= 0.0
	if vital_dead or _topmost_living_index() == -1:
		_is_dead = true
		died.emit()


# --- Queries for HUD / status logic ---

func is_dead() -> bool:
	return _is_dead

func get_layer_value(idx: int) -> float:
	if idx < 0 or idx >= _current.size():
		return 0.0
	return _current[idx]

func get_layer_fraction(idx: int) -> float:
	if idx < 0 or idx >= _current.size():
		return 0.0
	return _current[idx] / layer_configs[idx].max_value


## Sum of all live layer values (used to measure how much damage a hit actually dealt).
func total_current() -> float:
	var t := 0.0
	for v in _current:
		t += v
	return t


func layer_count() -> int:
	return _current.size()


func layer_type_at(idx: int) -> StringName:
	if idx < 0 or idx >= layer_configs.size():
		return &""
	return layer_configs[idx].layer_type


## Refill every layer to max and clear death (test dummies / respawns).
func reset() -> void:
	_rebuild_state()
