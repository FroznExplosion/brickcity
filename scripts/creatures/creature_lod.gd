class_name CreatureLOD
extends Node
## Animation LOD tiers (distance to current camera, checked at 4 Hz):
##  LOD0  < 25 m  full: 60 Hz gait, IK, springs, head look
##  LOD1  < 60 m  gait at ~15 Hz, IK on, springs/look off
##  LOD2  < 120 m canned FK sine gait at ~10 Hz, all modifiers off
##  LOD3  beyond  frozen pose, zero per-frame cost
## force_lod >= 0 pins a tier (debug/testing).

const D0 := 25.0
const D1 := 60.0
const D2 := 120.0
const HYST := 0.12

var creature: Node3D
var rig: Dictionary
var gait: GaitController
var canned: CannedGait
var force_lod: int = -1
var current: int = -1

var _accum := 0.0

func setup(p_creature: Node3D, p_rig: Dictionary, p_gait: GaitController, p_canned: CannedGait) -> void:
	creature = p_creature
	rig = p_rig
	gait = p_gait
	canned = p_canned
	_apply(0)
	set_process(true)

func _process(delta: float) -> void:
	_accum += delta
	if _accum < 0.25:
		return
	_accum = 0.0
	var tier := force_lod
	if tier < 0:
		var cam := creature.get_viewport().get_camera_3d() if creature.is_inside_tree() else null
		if cam == null:
			tier = 0
		else:
			var d := cam.global_position.distance_to(creature.global_position)
			# hysteresis: harder to leave the current tier than to enter it
			var m := 1.0 + (HYST if current >= 0 else 0.0)
			if d < D0 * (m if current == 0 else 1.0): tier = 0
			elif d < D1 * (m if current == 1 else 1.0): tier = 1
			elif d < D2 * (m if current == 2 else 1.0): tier = 2
			else: tier = 3
	if tier != current:
		_apply(tier)

## Set and apply a tier right now (no wait for the 4 Hz poll). -1 = auto.
func force_now(tier: int) -> void:
	force_lod = tier
	if tier >= 0:
		_apply(tier)

func _apply(tier: int) -> void:
	current = tier
	var ik: TwoBoneIK3D = rig.ik
	var look: LookAtModifier3D = rig.look
	var spring: SpringBoneSimulator3D = rig.spring
	match tier:
		0:
			gait.tick_divisor = 1
			gait.set_physics_process(true)
			canned.set_physics_process(false)
			ik.active = true
			look.active = true
			if spring: spring.active = true
		1:
			gait.tick_divisor = 4
			gait.set_physics_process(true)
			canned.set_physics_process(false)
			ik.active = true
			look.active = false
			if spring: spring.active = false
		2:
			gait.set_physics_process(false)
			canned.tick_divisor = 6
			canned.set_physics_process(true)
			ik.active = false
			look.active = false
			if spring: spring.active = false
		3:
			gait.set_physics_process(false)
			canned.set_physics_process(false)
			ik.active = false
			look.active = false
			if spring: spring.active = false
