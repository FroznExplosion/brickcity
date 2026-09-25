class_name CannedGait
extends Node
## LOD2 fallback animation: pure sine-driven forward-kinematics leg swing plus
## body bob, written straight into bone poses. No raycasts, no IK, no springs.
## Looks worse up close, reads fine at 60m+, costs almost nothing.
## Swing axes are captured in bone-local space at setup so any morphology works.

var creature: Node3D
var rig: Dictionary
var dna: CreatureDNA
var tick_divisor: int = 6

var _tick := 0
var _time := 0.0
var _leg_data: Array[Dictionary] = []
var pose_writes := 0  # telemetry for tests

func setup(p_creature: Node3D, p_rig: Dictionary, p_dna: CreatureDNA) -> void:
	creature = p_creature
	rig = p_rig
	dna = p_dna
	process_physics_priority = -10
	var skel: Skeleton3D = rig.skeleton
	for leg in rig.legs:
		var rest_u: Quaternion = skel.get_bone_rest(leg.upper).basis.get_rotation_quaternion()
		var rest_l: Quaternion = skel.get_bone_rest(leg.lower).basis.get_rotation_quaternion()
		# world +X (sagittal swing axis) expressed in each bone's parent space:
		# parents are near-identity in rotation, so X is a fine approximation for a far LOD.
		_leg_data.append({
			"leg": leg, "rest_u": rest_u, "rest_l": rest_l,
			"phase": PI * float(leg.group),
		})
	set_physics_process(false)

func _physics_process(delta: float) -> void:
	_tick += 1
	if _tick % tick_divisor != 0:
		return
	var dt := delta * float(tick_divisor)
	_time += dt
	var skel: Skeleton3D = rig.skeleton
	var freq: float = TAU * clampf(dna.move_speed / maxf(rig.stand_h, 0.25), 0.8, 4.0) * 0.55
	var amp := 0.45
	for ld in _leg_data:
		var leg: Dictionary = ld.leg
		var sw: float = sin(_time * freq + ld.phase) * amp
		var kn: float = maxf(0.0, cos(_time * freq + ld.phase)) * amp * 1.2
		skel.set_bone_pose_rotation(leg.upper, Quaternion(Vector3.RIGHT, sw) * ld.rest_u)
		skel.set_bone_pose_rotation(leg.lower, Quaternion(Vector3.RIGHT, kn) * ld.rest_l)
	skel.set_bone_pose_position(rig.body, rig.body_rest_pos + Vector3(0, sin(_time * freq * 2.0) * dna.bob_amp, 0))
	pose_writes += 1
	# root still drifts forward so far crowds read as alive
	creature.global_position += -creature.global_transform.basis.z * dna.move_speed * dt
