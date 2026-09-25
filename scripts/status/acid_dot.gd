## acid_dot.gd
## Acid damage-over-time. Bypasses to the &"health" layer, melting it directly
## even while a shield/armor bar still stands above it. This is the canonical
## proof of the "status leaks to its tuned layer" rule.
##
## Set tuned_layer_type = &"health" and stack_policy = REFRESH in the .tscn/.tres.
class_name AcidDoT
extends StatusEffect


func _on_tick() -> void:
	_deal_dot(damage_per_tick)
