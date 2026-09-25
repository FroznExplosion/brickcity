# recoil_holder.gd
# Two-phase auto-recovering camera recoil, ported from reddawn
# addons/Weapons/Scripts/Camera/CameraRecoilHolderScript.gd.
#
# Kept OUT of the camera transform chain (an earlier version reparented Camera3D under a holder
# node, which broke the hardcoded `CameraPivot/Camera3D` path solar_system.gd / PlayerMovement
# rely on). Instead this is a plain logic Node that writes the recoil rotation onto the Camera3D's
# OWN x/y each frame, leaving z to the movement roll tween (disjoint components, order-safe).
#
# On fire, add_recoil() bumps `_target`; `_target` decays back to zero (recover_speed) while
# `_current` chases `_target` (snap_speed). The view punches up/aside then smoothly returns to
# the original aim WITHOUT permanently shifting look pitch. Pitch clamped.
class_name RecoilHolder
extends Node

## Rate the recoil target bleeds back to zero (higher = snappier recovery).
@export var recover_speed: float = 8.0
## Rate the current rotation chases the target (higher = sharper kick).
@export var snap_speed: float = 18.0
## Max pitch the recoil can reach (rad) — keeps kick inside the look limits.
@export var max_pitch: float = 0.5

## The Camera3D to punch. Base pitch lives on the CameraPivot, so the camera's own x/y is free
## for recoil; its z is owned by the movement roll tween.
var camera: Node3D = null

var _target: Vector3 = Vector3.ZERO
var _current: Vector3 = Vector3.ZERO

func _process(delta: float) -> void:
	_target = _target.lerp(Vector3.ZERO, minf(recover_speed * delta, 1.0))
	_current = _current.lerp(_target, minf(snap_speed * delta, 1.0))
	_current.x = clampf(_current.x, -max_pitch, max_pitch)
	if camera != null:
		camera.rotation.x = _current.x
		camera.rotation.y = _current.y

## Kick the view. x = pitch up (rad), y = yaw spread (randomised ±y), z = roll spread (±z).
func add_recoil(v: Vector3) -> void:
	_target += Vector3(v.x, randf_range(-v.y, v.y), randf_range(-v.z, v.z))
	_target.x = clampf(_target.x, -max_pitch, max_pitch)
