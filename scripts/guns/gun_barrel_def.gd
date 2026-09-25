class_name GunBarrelDef
extends GunPartDef
## BARREL part. The barrel owns shot presentation: sound, muzzle flash, trail.
## The weapon controller never touches these directly — it calls the hooks on
## GunInstance, which reads them from here.

@export_group("Shot Presentation")
@export var shoot_sound: AudioStream
## Random pitch range applied per shot to avoid machine-gun monotony.
@export var pitch_range := Vector2(0.95, 1.05)

## One-shot scene spawned at the muzzle point per shot. Convention: the scene
## cleans itself up (GPUParticles3D one_shot + a self-freeing script), OR
## exposes a `flash()` method, OR is a bare GPUParticles3D (we restart it).
@export var muzzle_flash_scene: PackedScene

## Scene spawned per shot for the tracer. Convention: root exposes
## `setup(from: Vector3, to: Vector3)`; otherwise it's placed at the muzzle
## and left to its own logic.
@export var bullet_trail_scene: PackedScene

@export_group("Barrel / Element")
## Projectile family (WEAPONS_SPEC §3): kinetic / hybrid / blaster / beam.
## Metadata for effect/merge handlers and FX; element_ratio carries the numbers.
@export var barrel_family: StringName = &"kinetic"
## Fraction of each hit routed as ELEMENTAL damage (SPEC Amendment A.1). The rest
## is kinetic. 0 = pure kinetic; ~0.3–0.5 hybrid; ~0.5–0.75 laser (blaster/beam).
@export_range(0.0, 1.0) var element_ratio: float = 0.0


func _init() -> void:
	slot = Slot.BARREL
