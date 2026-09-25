## defense_layer.gd
## Configuration for a single defense bar (shield / armor / health / custom).
## This is the design-time config; live values are tracked by HealthPool at runtime.
class_name DefenseLayer
extends Resource

## Type used to look up effectiveness, e.g. &"shield", &"armor", &"health".
## Fully extensible — add &"magma_crust", &"plant_flesh", etc. without code changes.
@export var layer_type: StringName = &"health"

@export var max_value: float = 100.0

## Per-second regeneration. 0 means no regen (typical for health/armor).
@export var regen_rate: float = 0.0

## Seconds of "no damage taken" required before regen resumes (shield delay).
@export var regen_delay: float = 0.0

## HUD color for this bar.
@export var display_color: Color = Color.WHITE
