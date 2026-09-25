## element.gd
## Defines one damage element (acid, shock, fire, etc.) as a tunable Resource.
## Color is presentation only; effectiveness lives in EffectivenessMatrix.
class_name Element
extends Resource

## Stable identifier used as the key in the effectiveness matrix. e.g. &"acid"
@export var id: StringName = &""

## Human-readable name for UI / damage numbers.
@export var display_name: String = ""

## Presentation color for bullets, numbers, HUD. Has no gameplay meaning.
@export var color: Color = Color.WHITE

## Status applied on a successful proc. Leave null for a pure-impact element.
@export var status_scene: PackedScene

## Base chance (0..1) to apply the status. Multiplied by the weapon's element_chance.
@export_range(0.0, 1.0, 0.01) var base_status_chance: float = 0.0

## The defense layer this element is tuned against. The elemental PORTION of an impact
## AND its DoT both bypass directly to this layer (SPEC Amendment A.2 / §3). Empty =
## topmost (behaves like kinetic). e.g. acid → &"health", corrosive → &"armor",
## shock → &"shield". If the layer is absent, damage falls back to the top layer.
@export var tuned_layer_type: StringName = &""

## Freeform classification tags, e.g. &"dot", &"freeze", &"amplify".
@export var tags: Array[StringName] = []


func has_tag(tag: StringName) -> bool:
	return tags.has(tag)
