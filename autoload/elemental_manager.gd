# elemental_manager.gd — AUTOLOAD (name: ElementalManager)
# The LOOK of elemental statuses: shared overlay / dissolve materials, element
# colours, and how long each element's visuals stay on a target. One node, no
# per-enemy Timers.
#
# FX only. BoomerBorder's copy also ran its own damage sim (DoT ticks, slag
# amplification, a private health on ElementalTarget) that nothing in the real
# pipeline called (its INTEGRATION_SPEC section 1). Stripped on the way into
# brickcity (Docs/Reference/boomer-border.md section 0): damage is DamageSystem ->
# HealthPool, statuses are StatusEffect ticked by StatusTicker, and only the host
# decides either. Drive this from those:
#   ElementalManager.apply(target, ElementalManager.Element.FIRE)
# where `target` is the enemy's ElementalTarget component (or the enemy root,
# we find the component automatically).
extends Node

enum Element { ICE, FIRE, ACID, CORROSIVE, SHOCK, SLAG, RADIATION }

# Shared, created-once ShaderMaterials. Assign in the inspector of the autoload
# scene, or they are built in _ready() from the shaders in fx/shaders/.
@export var overlay_material: ShaderMaterial          # elemental_overlay.gdshader
@export var dissolve_material: ShaderMaterial         # acid_dissolve.gdshader

# Element identity colors (Borderlands-ish).
const ELEMENT_COLOR := {
	Element.ICE:       Color(0.55, 0.85, 1.0),
	Element.FIRE:      Color(1.0, 0.45, 0.1),
	Element.ACID:      Color(0.65, 1.0, 0.2),
	Element.CORROSIVE: Color(0.3, 0.9, 0.25),
	Element.SHOCK:     Color(0.4, 0.7, 1.0),
	Element.SLAG:      Color(0.7, 0.3, 1.0),
	Element.RADIATION: Color(0.75, 1.0, 0.3),
}

# How long each element's visuals stay on a target.
const ELEMENT_PARAMS := {
	Element.ICE:       { "duration": 4.0 },
	Element.FIRE:      { "duration": 5.0 },
	Element.ACID:      { "duration": 6.0 },
	Element.CORROSIVE: { "duration": 7.0 },
	Element.SHOCK:     { "duration": 3.0 },
	Element.SLAG:      { "duration": 8.0 },
	Element.RADIATION: { "duration": 6.0 },
}

# All live statuses, flat array — the hot loop. Each entry is a ElementalStatus.
var _statuses: Array[ElementalStatus] = []

# ---------------------------------------------------------------------------

class ElementalStatus:
	var element: int
	var target: ElementalTarget
	var time_left: float
	var stacks: int = 1
	func _init(p_element: int, p_target: ElementalTarget) -> void:
		element = p_element
		target = p_target

# ---------------------------------------------------------------------------

func _ready() -> void:
	if overlay_material == null:
		overlay_material = ShaderMaterial.new()
		overlay_material.shader = load("res://fx/shaders/elemental_overlay.gdshader")
	if dissolve_material == null:
		dissolve_material = ShaderMaterial.new()
		dissolve_material.shader = load("res://fx/shaders/acid_dissolve.gdshader")

func apply(target_node: Node, element: int) -> void:
	var target := _resolve_target(target_node)
	if target == null or target.is_dead:
		return

	# Refresh instead of stack if the same element is already on the target.
	var existing := _find_status(target, element)
	var params: Dictionary = ELEMENT_PARAMS[element]
	if existing != null:
		existing.time_left = params.duration
		existing.stacks = mini(existing.stacks + 1, 3)
		return

	var s := ElementalStatus.new(element, target)
	s.time_left = params.duration
	_statuses.append(s)
	target.active_elements |= (1 << element)

	# Element-specific "on applied" — each element script is a static toolbox.
	match element:
		Element.ICE:       IceEffect.on_applied(target)
		Element.FIRE:      FireEffect.on_applied(target)
		Element.ACID:      AcidEffect.on_applied(target)
		Element.CORROSIVE: CorrosiveEffect.on_applied(target)
		Element.SHOCK:     ShockEffect.on_applied(target)
		Element.SLAG:      SlagEffect.on_applied(target)
		Element.RADIATION: RadiationEffect.on_applied(target)


# ------------------------------------------------------------------ hot loop
func _physics_process(delta: float) -> void:
	var i := _statuses.size() - 1
	while i >= 0:
		var s := _statuses[i]
		var dead_target: bool = not is_instance_valid(s.target) or s.target.is_dead
		s.time_left -= delta

		if dead_target or s.time_left <= 0.0:
			if not dead_target:
				_expire(s)
			_statuses.remove_at(i)
			i -= 1
			continue

		# Per-frame update (visual ramps, arc orbiting handled in shaders/pool).
		match s.element:
			Element.ICE:  IceEffect.on_update(s, delta)
			Element.ACID: AcidEffect.on_update(s, delta)
			_: pass
		i -= 1

func _expire(s: ElementalStatus) -> void:
	s.target.active_elements &= ~(1 << s.element)
	match s.element:
		Element.ICE:       IceEffect.on_removed(s.target)
		Element.FIRE:      FireEffect.on_removed(s.target)
		Element.ACID:      AcidEffect.on_removed(s.target)
		Element.CORROSIVE: CorrosiveEffect.on_removed(s.target)
		Element.SHOCK:     ShockEffect.on_removed(s.target)
		Element.SLAG:      SlagEffect.on_removed(s.target)
		Element.RADIATION: RadiationEffect.on_removed(s.target)

func remove_element(target: ElementalTarget, element: int) -> void:
	var s := _find_status(target, element)
	if s != null:
		_expire(s)
		_statuses.erase(s)

# ----------------------------------------------------------------- helpers
func _find_status(target: ElementalTarget, element: int) -> ElementalStatus:
	for s in _statuses:
		if s.target == target and s.element == element:
			return s
	return null

func _resolve_target(node: Node) -> ElementalTarget:
	if node is ElementalTarget:
		return node
	if node == null:
		return null
	return node.get_node_or_null("ElementalTarget") as ElementalTarget
