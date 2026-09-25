## status_effect.gd
## Base class for all timed status effects (DoTs, freeze, slag, etc.).
## Concrete effects override _on_apply / _on_tick / _on_expire.
## DoT subclasses route ticks through health_pool.apply_to_layer_type() so they
## bypass to their tuned layer.
class_name StatusEffect
extends Node

enum StackPolicy { REFRESH, STACK, IGNORE }

@export var status_id: StringName = &""
@export var duration: float = 5.0
@export var tick_interval: float = 0.5

## Which layer this effect's DoT bypasses to. Empty = topmost living layer.
@export var tuned_layer_type: StringName = &""

@export var stack_policy: StackPolicy = StackPolicy.REFRESH

## When false (default) this effect's DoT ticks and its duration burn at the HOST'S
## time rate, not the engine's — so a stasis bubble or freeze-aim (ProceduralCombat §6)
## slows the burn on the enemies it caught without touching anyone else's world. See
## [EntityTime]; entities with no EntityTime node run at 1.0, so this changes nothing
## by default.
##
## Set true for effects that must keep real-time pace regardless — e.g. the "DoTs KEEP
## ticking under the ice" rule ([FrozenStatus] docs) if freeze is ever reimplemented as
## a time-scale source instead of an AI halt.
@export var ignore_time_scale: bool = false

## Damage applied per tick (DoTs). Non-DoT effects ignore this.
@export var damage_per_tick: float = 0.0

## Instant elemental burst dealt the moment this effect is applied (per proc),
## SEPARATE from the lingering DoT. This is the "each proc also does element damage"
## term — it bursts to the tuned layer on apply. Fire-rate scaling lives here:
## bursts happen per successful proc, so fast guns burst more often (balance this
## against element_chance per weapon class). The lingering DoT stays flat (1 stack).
@export var instant_burst_damage: float = 0.0

# Set by DamageSystem when applied so DoTs scale via the matrix correctly.
var source_element_id: StringName = &""

## "Strength" of this DoT for the strongest-applier-wins rule. DamageSystem sets it
## (typically the proc's damage_per_tick or the gun's element power). On refresh, a
## new proc only overwrites the active DoT's damage if it is STRONGER; weaker procs
## just refresh the timer. Prevents a weak gun from downgrading a strong burn.
var dot_strength: float = 0.0

var _elapsed: float = 0.0
var _tick_accum: float = 0.0
var _pool: HealthPool
var _manager: StatusManager
var _expired: bool = false
var _host: Node3D
var _time: EntityTime


## Called by StatusManager right after add_child, before ticking begins.
func bind(manager: StatusManager, pool: HealthPool) -> void:
	_manager = manager
	_pool = pool
	_host = host()
	_time = EntityTime.of(_host)
	# The instant elemental burst fires once, here, when the effect first lands.
	_fire_instant_burst()
	_on_apply()


## The entity this effect is attached to: nearest Node3D ancestor. Cached after bind().
func host() -> Node3D:
	if _host != null and is_instance_valid(_host):
		return _host
	var n: Node = get_parent()
	while n != null:
		if n is Node3D:
			_host = n
			return _host
		n = n.get_parent()
	return null


## Fire the instant elemental burst to the tuned layer (bypasses like the DoT does).
func _fire_instant_burst() -> void:
	if instant_burst_damage <= 0.0:
		return
	if _pool == null:
		return
	_pool.apply_to_layer_type(instant_burst_damage, tuned_layer_type, source_element_id)


## Called on an ALREADY-ACTIVE effect when the same element re-procs (REFRESH path).
## Always refreshes the timer; only upgrades damage if the new proc is stronger
## ("strongest applier wins"). Also fires the incoming proc's instant burst, since
## every proc deals its burst regardless of whether the DoT was already active.
func reapply_from(incoming: StatusEffect) -> void:
	refresh()
	if incoming.dot_strength > dot_strength:
		dot_strength = incoming.dot_strength
		damage_per_tick = incoming.damage_per_tick
		duration = incoming.duration
	# The incoming proc still bursts (per-shot element damage always lands).
	if incoming.instant_burst_damage > 0.0 and _pool != null:
		_pool.apply_to_layer_type(incoming.instant_burst_damage, tuned_layer_type, source_element_id)


## Driven by the global StatusTicker (autoload), NOT the engine _physics_process —
## one loop ticks every active effect (INTEGRATION §1). Guards against being ticked
## after expiry (queue_free is deferred).
##
## The ticker hands out RAW delta; scaling to the host's own clock happens here, so
## there is exactly one place that decides how fast a status burns.
func tick(delta: float) -> void:
	if _expired:
		return
	if not ignore_time_scale:
		delta *= _time.get_scale() if _time != null else EntityTime.world_scale
		# Fully stopped host (stasis / freeze-aim): duration and DoT both hold.
		if delta <= 0.0:
			return
	_elapsed += delta
	_tick_accum += delta
	while _tick_accum >= tick_interval:
		_tick_accum -= tick_interval
		_on_tick()
	if _elapsed >= duration:
		_expire()


func is_expired() -> bool:
	return _expired


## Refresh resets the clock (used by REFRESH stack policy).
func refresh() -> void:
	_elapsed = 0.0


func _expire() -> void:
	if _expired:
		return
	_expired = true
	_on_expire()
	queue_free()


# --- Overridable hooks ---

func _on_apply() -> void:
	pass

func _on_tick() -> void:
	pass

func _on_expire() -> void:
	pass


# --- Helper for DoT subclasses ---

func _deal_dot(amount: float) -> void:
	if _pool == null:
		return
	_pool.apply_to_layer_type(amount, tuned_layer_type, source_element_id)
