## status_manager.gd
## Lives on each enemy. Owns active StatusEffect children, handles stacking,
## and exposes aggregate queries (frozen?, total damage-taken multiplier).
class_name StatusManager
extends Node

## Path to the sibling/owner HealthPool. If empty, searched from the parent.
@export var health_pool_path: NodePath

var _pool: HealthPool


func _ready() -> void:
	if health_pool_path.is_empty():
		# Same cache entry DamageSystem uses, so resolving here warms it for combat.
		_pool = ComponentCache.find(
			get_parent(), &"HealthPool", &"_cc_health_pool") as HealthPool
	else:
		_pool = get_node_or_null(health_pool_path) as HealthPool


## Stacking model (final):
##  - DIFFERENT elements coexist independently (fire + corrosive both burn at once),
##    because effects are matched by status_id — a fire effect and corrosive effect
##    have different ids, so they live side by side.
##  - SAME element = ONE stack. A re-proc does NOT add a second stack; it refreshes
##    the timer and, if stronger, upgrades the damage ("strongest applier wins").
##    No per-player ownership is tracked (deliberately simplest model).
func apply(effect: StatusEffect) -> void:
	if effect == null:
		return
	var existing: StatusEffect = _find_by_id(effect.status_id)
	if existing != null:
		match existing.stack_policy:
			StatusEffect.StackPolicy.IGNORE:
				effect.queue_free()
				return
			StatusEffect.StackPolicy.REFRESH:
				# Strongest-applier-wins + fire the incoming proc's instant burst.
				existing.reapply_from(effect)
				effect.queue_free()
				return
			StatusEffect.StackPolicy.STACK:
				pass  # fall through and add as an independent stack
	add_child(effect)
	effect.bind(self, _pool)
	# The global StatusTicker (autoload) drives per-frame ticking — not each effect's
	# own _physics_process. It auto-prunes freed/expired effects (INTEGRATION §1).
	StatusTicker.register(effect)


## Remove every active status (used on death/respawn so a revived enemy starts clean).
func clear_all() -> void:
	for child in get_children():
		if child is StatusEffect:
			child.queue_free()


func _find_by_id(id: StringName) -> StatusEffect:
	for child in get_children():
		if child is StatusEffect and (child as StatusEffect).status_id == id:
			return child
	return null


# --- Aggregate queries ---

func is_frozen() -> bool:
	for child in get_children():
		if child is FrozenStatus:
			return true
	return false


## Product of every active effect's contribution (slag, frozen, etc.).
## Effects opt in by implementing a damage_taken_factor() method.
func damage_taken_multiplier() -> float:
	var total: float = 1.0
	for child in get_children():
		if child.has_method("damage_taken_factor"):
			total *= float(child.call("damage_taken_factor"))
	return total
