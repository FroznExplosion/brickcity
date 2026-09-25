## effectiveness_matrix.gd
## Data-driven table answering "how effective is element X against layer-type Y?".
## Governs BOTH impact scaling on the top bar AND DoT scaling on the tuned layer.
## Unspecified combos default to 1.0 (neutral) so nothing is accidentally immune.
class_name EffectivenessMatrix
extends Resource

## Outer key: element id (StringName). Inner key: layer_type (StringName).
## Value: damage multiplier (float). Edit entirely in the inspector / .tres.
## Example:
## {
##   &"shock":     { &"shield": 2.0, &"armor": 0.5 },
##   &"corrosive": { &"armor": 2.0, &"shield": 0.5 },
##   &"acid":      { &"health": 1.75 },
## }
@export var table: Dictionary = {}

## Returned when a combination is not present. Kept as an export so designers can
## globally bias neutrality without editing code.
@export var default_multiplier: float = 1.0


## Returns the multiplier for an element against a given layer type.
## Falls back to default_multiplier for any missing entry.
func get_multiplier(element_id: StringName, layer_type: StringName) -> float:
	if not table.has(element_id):
		return default_multiplier
	var row: Dictionary = table[element_id]
	if not row.has(layer_type):
		return default_multiplier
	return float(row[layer_type])
