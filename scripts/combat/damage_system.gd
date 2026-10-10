## damage_system.gd
## The single entry point for ALL damage. Composes every multiplier in one place
## (effectiveness handled inside HealthPool, plus crit / slag / frozen here), then
## applies impact to the top bar and rolls to proc the element's status.
##
## Weapons must route through resolve(); they never touch HealthPool directly.
class_name DamageSystem
extends Object

# Component lookups are cached per entity root (ComponentCache). resolve() used to run
# find_child() twice per hit, which is fine for one gun and not fine for a melee sweep
# hitting a dozen enemies per swing, or a horde eating splash.
const _HEALTH_POOL_META := &"_cc_health_pool"
const _STATUS_MANAGER_META := &"_cc_status_manager"

## Where a hit's rolls come from when its packet brings none. Seeded, never the global
## RNG (Docs/Reference/boomer-border.md section 0, fix 1): the host owns combat, and
## whoever owns combat seeds this -- `DamageSystem.rng.seed = ...` -- the way
## BrickWorld is seeded.
static var rng := _seeded(0x5eed)

## The layers a crit counts on (Docs/Weapons/COMBAT_DESIGN.md 4.2-4.3): flesh, by
## whichever name it carries. A shield or armor over them ABSORBS the crit -- the hit
## lands as a plain one -- so a headshot pays only once the defence is gone.
const CRIT_LAYERS: Array[StringName] = [&"health", &"flesh", &"vegetation"]


static func _seeded(s: int) -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = s
	return r

## Result returned for hit feedback (floating numbers, hit colors, etc.).
class DamageResult extends RefCounted:
	var dealt: float = 0.0            ## ACTUAL damage removed from the target's layers
	var element_color: Color = Color.WHITE
	var was_crit: bool = false
	var crit_absorbed: bool = false   ## a crit-spot hit a shield or armor took as a plain one
	var procced_status: bool = false
	var killed: bool = false          ## this hit dropped the target's vital layer


## target_root must own a HealthPool and may own a StatusManager (looked up by node name/group).
static func resolve(packet: DamagePacket, target_root: Node) -> DamageResult:
	var result := DamageResult.new()
	if packet == null or target_root == null:
		return result

	# A mech is killed in layers, by its own rules (MechLayers): the hit goes there.
	# By meta, not by class: this file does not depend on the mech's scripts.
	if target_root.has_meta(&"mech_layers"):
		var layers: Variant = target_root.get_meta(&"mech_layers")
		if typeof(layers) == TYPE_OBJECT and is_instance_valid(layers):
			return (layers as Object).call(&"take_packet", packet)
	# Anything else with rules of its own for a hit -- a vehicle's armour (Tank).
	if target_root.has_meta(&"takes_packet"):
		var taker: Variant = target_root.get_meta(&"takes_packet")
		if typeof(taker) == TYPE_OBJECT and is_instance_valid(taker):
			return (taker as Object).call(&"take_packet", packet)

	var pool: HealthPool = _find_health_pool(target_root)
	if pool == null or pool.is_dead():
		return result
	var before: float = pool.total_current()

	var status_mgr: StatusManager = _find_status_manager(target_root)

	# Compose external multipliers (crit + slag/frozen). The element-vs-layer matrix is
	# NOT here — HealthPool applies it per layer.
	var extra: float = 1.0
	var crit := packet.crit and pool.top_layer_type() in CRIT_LAYERS
	if crit:
		extra *= maxf(1.0, packet.crit_multiplier)
	if status_mgr != null:
		extra *= status_mgr.damage_taken_multiplier()
	if packet.shield_mult != 1.0 and pool.top_layer_type() == &"shield":
		extra *= packet.shield_mult

	# A melee is its own damage type and one step: it lands on the top layer and stops
	# there, whatever it broke (COMBAT_DESIGN 4.1). Never a crit.
	if packet.melee:
		pool.apply_impact(packet.amount, Elements.MELEE, extra, false, true)
		result.dealt = before - pool.total_current()
		result.killed = pool.is_dead()
		return result

	var has_element: bool = packet.element != null
	if has_element:
		result.element_color = packet.element.color

	# Split-damage routing (SPEC Amendment A.2). No element => fully kinetic.
	var ratio: float = clampf(packet.element_ratio, 0.0, 1.0) if has_element else 0.0
	var kinetic_amount: float = packet.amount * (1.0 - ratio)
	var elemental_amount: float = packet.amount * ratio

	# Both parts land on the TOP living layer -- the defences sit over the flesh
	# (Docs/Weapons/COMBAT_DESIGN.md 4.2) -- the element's part multiplied by the matrix
	# there (Elements), the kinetic part flat. The element goes first, so a plasma round
	# strips the shield and its kinetic part meets what is under it. A crit-spot hit is
	# not gated when it breaks a shield (4.4).
	if has_element and elemental_amount > 0.0:
		pool.apply_impact(elemental_amount, packet.element.id, extra, packet.crit)
	if kinetic_amount > 0.0:
		pool.apply_impact(kinetic_amount, &"", extra, packet.crit)

	result.was_crit = crit
	result.crit_absorbed = packet.crit and not crit

	# Roll the status proc — only when the shot actually carries elemental content
	# (ratio > 0); a pure-kinetic shot never procs, even with an element assigned.
	if has_element and ratio > 0.0 and packet.element.status_scene != null and status_mgr != null:
		var chance: float = packet.element.base_status_chance * packet.element_chance
		var roll: RandomNumberGenerator = packet.rng if packet.rng != null else rng
		if roll.randf() < chance:
			_apply_status(packet, target_root, status_mgr)
			result.procced_status = true

	# Actual damage = how much the layers dropped (impact + any instant burst).
	result.dealt = before - pool.total_current()
	result.killed = pool.is_dead()

	return result


static func _apply_status(packet: DamagePacket, _target_root: Node, status_mgr: StatusManager) -> void:
	var inst: Node = packet.element.status_scene.instantiate()
	if inst is StatusEffect:
		var fx: StatusEffect = inst
		fx.source_element_id = packet.element.id
		# Strength used for the "strongest applier wins" refresh comparison. Default
		# to the effect's own per-tick damage; a weapon may scale this up via the
		# packet (e.g. higher-level/element-power guns produce stronger DoTs).
		if fx.dot_strength <= 0.0:
			fx.dot_strength = fx.damage_per_tick
		status_mgr.apply(fx)
	else:
		inst.queue_free()


static func _find_health_pool(root: Node) -> HealthPool:
	if root is HealthPool:
		return root
	return ComponentCache.find(root, &"HealthPool", _HEALTH_POOL_META) as HealthPool


static func _find_status_manager(root: Node) -> StatusManager:
	if root is StatusManager:
		return root
	return ComponentCache.find(root, &"StatusManager", _STATUS_MANAGER_META) as StatusManager
