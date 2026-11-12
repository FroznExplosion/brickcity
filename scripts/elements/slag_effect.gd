# slag_effect.gd — SLAG: corrosive's purple twin. Same coat pipeline, stronger
# shimmer, NO puddle. The gameplay half -- slag doubling damage taken -- is
# StatusManager.damage_taken_multiplier(), read by DamageSystem.
class_name SlagEffect

static func on_applied(t: ElementalTarget) -> void:
	t.set_overlay(ElementalManager.ELEMENT_COLOR[ElementalManager.Element.SLAG],
		1.0, 0.0, 0.0, 5.0)   # coat + fast iridescent pulse = reads as "marked"

static func on_removed(t: ElementalTarget) -> void:
	t.set_overlay_param("coat_amount", 0.0)
	t.set_overlay_param("pulse_speed", 0.0)
	t.clear_overlay_if_unused()
