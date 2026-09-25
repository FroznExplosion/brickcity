class_name GunReceiverDef
extends GunPartDef
## BODY/receiver part. The receiver owns reload behavior: its GLB carries an
## AnimationPlayer (Blender actions export straight into it), and this def
## names which clip is the reload.

## Animation name inside the receiver GLB's AnimationPlayer.
@export var reload_animation: StringName = &"reload"

## Optional extra clips the receiver provides (equip, inspect, jam...).
## Keyed by logical name -> clip name, so game code never hardcodes clip names.
@export var extra_animations: Dictionary[StringName, StringName] = {}


func _init() -> void:
	slot = Slot.BODY
