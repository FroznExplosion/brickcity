class_name CreatureRagdoll
extends Node
## Gait ⇄ Physics MERGE — procedural creatures that walk any morphology AND react to forces.
## ============================================================================================
## DRAFT reference artifact — NOT YET RUN. Concrete embodiment of
## sta_active_ragdoll/INTEGRATION_WITH_PROCGEN.md and physics_animation/spec.md (§5 rig,
## §6 drive, §9 hits, §10 LOD). GDScript on purpose: portable, no C++ rebuild — the velocity
## drive is cheap enough for the handful of LOD0 creatures that ever run physics at once.
##
## Contract (physics_animation/spec.md §7 PoseProvider): you give it two skeletons of the SAME
## rig —
##   TARGET  = kinematic, posed every physics frame by the procedural GaitController + TwoBoneIK3D
##             ("what the body wants to do"). This node never touches it.
##   PUPPET  = the visible skinned skeleton; this node builds a PhysicalBoneSimulator3D on it and
##             velocity-drives its bones toward the Target ("what the body physically does").
## How you produce the split is the builder's job (two-skeleton option, INTEGRATION §3.2). The
## merge test builds a ProcCreature as the Target and duplicates its skeleton as the Puppet.
##
## Morphology-agnostic: the physical rig is generated from the creature's `rig` dict + `dna`
## (spine chain, per-leg upper/lower, body, head) — no hardcoded humanoid bone names.

# --- drive tuning (physics_animation/spec.md §8) ---
@export var track_position := 1.0
@export var track_rotation := 1.0
@export var max_lin_speed := 12.0
@export var max_ang_speed := 50.0
@export var snap_distance := 1.0

# --- rig sizing ---
@export var limb_radius_f := 0.4     # capsule radius as fraction of the segment's DNA thickness
@export var mass_body := 6.0
@export var mass_limb := 3.0

const RAGDOLL_LAYER := 4             # bit 3 — hits World only, not the creature or each other
const WORLD_MASK := 1

var puppet: Skeleton3D               # visible, physical
var target: Skeleton3D               # kinematic, gait-posed
var dna                              # CreatureDNA
var rig: Dictionary                  # CreatureBuilder.build(...) result

var _sim: PhysicalBoneSimulator3D
var _bones: Array[Dictionary] = []   # { body:PhysicalBone3D, idx:int, is_root:bool }
var _simulating := false
var _lod := 0
var _last_root := Vector3.ZERO
var _root_vel := Vector3.ZERO

# hit / authority-drop state
var _stagger_t := 0.0
var _stagger_dur := 0.0
var _base_track_rot := 1.0
var _base_track_pos := 1.0


func setup(p_puppet: Skeleton3D, p_target: Skeleton3D, p_dna, p_rig: Dictionary) -> void:
	puppet = p_puppet
	target = p_target
	dna = p_dna
	rig = p_rig
	_base_track_rot = track_rotation
	_base_track_pos = track_position
	_build_physical_rig()
	set_physics_process(true)


## One-call setup: split a built ProcCreature into Target/Puppet (CreatureSplit) and attach a
## driven CreatureRagdoll. Returns the ragdoll, physics ON at LOD0.
static func attach_to(creature) -> CreatureRagdoll:
	var sp := CreatureSplit.make(creature)
	var rag := CreatureRagdoll.new()
	creature.add_child(rag)
	rag.setup(sp.puppet, sp.target, creature.dna, creature.rig)
	rag.set_lod(0)
	return rag


# ── rig build (physics_animation/spec.md §5 — bone-spec list from the creature, not hardcoded) ──
func _build_physical_rig() -> void:
	_sim = PhysicalBoneSimulator3D.new()
	puppet.add_child(_sim)
	_sim.process_mode = Node.PROCESS_MODE_DISABLED   # enabled on set_simulating(true)

	# Blender cm→m scale guard (physics_animation/spec.md §4.4). Free even at scale 1.
	var comp := 1.0
	var s := puppet.global_transform.basis.get_scale().x
	if absf(s) > 1e-6:
		comp = 1.0 / s

	# root = body; then spine chain; then each leg's upper + lower. Head optional.
	_add_phys_bone(rig.body, mass_body, true, comp, dna.body_r * 0.9, rig.stand_h * 0.25)
	for i in rig.spine.size():
		var r: float = dna.body_r * (dna.belly[i] if i < dna.belly.size() else 1.0) * limb_radius_f
		_add_phys_bone(rig.spine[i], mass_body * 0.7, false, comp, r, _child_len(rig.spine[i]))
	for leg in rig.legs:
		var lp = dna.leg_pairs[leg.pair]
		var lr: float = dna.body_r * limb_radius_f
		_add_phys_bone(leg.upper, mass_limb, false, comp, lr, float(lp.upper))
		_add_phys_bone(leg.lower, mass_limb * 0.8, false, comp, lr * 0.85, float(lp.lower))
	if rig.has("head") and rig.head >= 0:
		_add_phys_bone(rig.head, mass_limb, false, comp, dna.head_r, dna.head_r * 1.2)


func _add_phys_bone(idx: int, mass: float, is_root: bool, comp: float, radius: float, height: float) -> void:
	if idx < 0 or idx >= puppet.get_bone_count():
		return
	var pb := PhysicalBone3D.new()
	pb.name = puppet.get_bone_name(idx)
	pb.set("bone_name", pb.name)
	pb.mass = mass
	pb.linear_damp = 1.5
	pb.angular_damp = 2.0
	pb.collision_layer = RAGDOLL_LAYER
	pb.collision_mask = WORLD_MASK
	if not is_equal_approx(comp, 1.0):
		var off := Transform3D()
		off.basis = off.basis.scaled(Vector3(comp, comp, comp))
		pb.set("body_offset", off)
	# root = free anchor (driven), rest = cone-twist so the chain holds together.
	pb.joint_type = PhysicalBone3D.JOINT_TYPE_NONE if is_root else PhysicalBone3D.JOINT_TYPE_CONE
	if not is_root:
		pb.set("joint/cone_twist/swing_span_1", deg_to_rad(45.0))
		pb.set("joint/cone_twist/swing_span_2", deg_to_rad(45.0))
		pb.set("joint/cone_twist/twist_span", deg_to_rad(25.0))
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = maxf(0.02, radius)
	cap.height = maxf(cap.radius * 2.0 + 0.02, height)
	cs.shape = cap
	pb.add_child(cs)
	_sim.add_child(pb)
	_bones.append({ "body": pb, "idx": idx, "is_root": is_root })


## Distance from a bone's rest origin to its first child's — a decent capsule length.
func _child_len(idx: int) -> float:
	var here := puppet.get_bone_global_rest(idx).origin
	for c in puppet.get_bone_count():
		if puppet.get_bone_parent(c) == idx:
			return maxf(0.05, here.distance_to(puppet.get_bone_global_rest(c).origin))
	return 0.12


# ── control ──────────────────────────────────────────────────────────────────
func set_simulating(on: bool) -> void:
	if on == _simulating or _sim == null:
		return
	if on:
		_sim.process_mode = Node.PROCESS_MODE_INHERIT
		_sim.physical_bones_start_simulation()
	else:
		_sim.physical_bones_stop_simulation()
		_sim.process_mode = Node.PROCESS_MODE_DISABLED
	_simulating = on


## LOD gate (physics_animation/spec.md §10): physics only at tier 0; else kinematic copy.
func set_lod(tier: int) -> void:
	_lod = tier
	set_simulating(tier == 0)


## Hit reaction (physics_animation/spec.md §9): impulse a bone + briefly drop authority so
## physics wins → stumble → drive ramps back. `bone_idx` is a SKELETON bone index.
func hit(bone_idx: int, world_impulse: Vector3, stagger := 0.5) -> void:
	for b in _bones:
		if b.idx == bone_idx and b.body != null:
			PhysicsServer3D.body_apply_impulse(b.body.get_rid(), world_impulse)
			break
	track_rotation = _base_track_rot * 0.15
	track_position = _base_track_pos * 0.4
	_stagger_dur = stagger
	_stagger_t = stagger


func knockdown(world_impulse: Vector3) -> void:
	# Deeper, longer drop than a stumble.
	if _bones.size() > 0:
		PhysicsServer3D.body_apply_impulse(_bones[0].body.get_rid(), world_impulse)
	track_rotation = 0.0
	track_position = 0.0
	_stagger_dur = 1.2
	_stagger_t = 1.2


# ── per-frame ────────────────────────────────────────────────────────────────
func _physics_process(delta: float) -> void:
	if puppet == null or target == null:
		return
	# root velocity feed-forward: the whole creature translates with the gait.
	var root := target.global_transform.origin
	_root_vel = (root - _last_root) / maxf(delta, 1e-5)
	_last_root = root

	# ease authority back after a hit
	if _stagger_t > 0.0:
		_stagger_t = maxf(_stagger_t - delta, 0.0)
		var k := 1.0 - (_stagger_t / maxf(_stagger_dur, 1e-5))   # 0→1 as it recovers
		track_rotation = lerpf(track_rotation, _base_track_rot, k)
		track_position = lerpf(track_position, _base_track_pos, k)

	if _simulating and _lod == 0:
		_drive_step(delta)
	else:
		_copy_target_to_puppet()


## Velocity drive / soft keying (physics_animation/spec.md §6). Morphology-blind: loops bones.
func _drive_step(delta: float) -> void:
	var tgt_world := target.global_transform
	for b in _bones:
		var pb: PhysicalBone3D = b.body
		if pb == null:
			continue
		var rid := pb.get_rid()
		var tgt := tgt_world * target.get_bone_global_pose(b.idx)
		var cur := pb.global_transform

		var pos_err := tgt.origin - cur.origin
		if pos_err.length() > snap_distance:                       # blow-up guard (§4.6)
			pb.global_transform = Transform3D(Basis(tgt.basis.get_rotation_quaternion()), tgt.origin)
			PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, _root_vel)
			PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY, Vector3.ZERO)
			continue

		var corr := pos_err / delta * track_position
		if corr.length() > max_lin_speed:
			corr = corr.normalized() * max_lin_speed
		var want_lin := _root_vel + corr                           # feed-forward base motion (§4.7)

		var q_cur := cur.basis.get_rotation_quaternion().normalized()
		var q_tgt := tgt.basis.get_rotation_quaternion().normalized()
		var q_err := q_tgt * q_cur.inverse()
		if q_err.w < 0.0:
			q_err = Quaternion(-q_err.x, -q_err.y, -q_err.z, -q_err.w)  # shortest arc
		var want_ang := Vector3.ZERO
		var ang := q_err.get_angle()
		if ang > 1e-5:
			want_ang = q_err.get_axis() * ang / delta * track_rotation
			if want_ang.length() > max_ang_speed:
				want_ang = want_ang.normalized() * max_ang_speed

		PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, want_lin)
		PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY, want_ang)


## Drive OFF / far LOD: puppet just mirrors the gait pose (identical to plain kinematic creature).
func _copy_target_to_puppet() -> void:
	var n: int = min(puppet.get_bone_count(), target.get_bone_count())
	for i in n:
		puppet.set_bone_pose_rotation(i, target.get_bone_pose_rotation(i))
	if rig.has("body"):
		puppet.set_bone_pose_position(rig.body, target.get_bone_pose_position(rig.body))


# ── measurement hooks (mirror ActiveRagdoll's; used by the merge smoke test) ──
func get_physical_bone_count() -> int:
	return _bones.size()

func get_mean_tracking_error() -> float:
	if _bones.is_empty():
		return 0.0
	var tgt_world := target.global_transform
	var sum := 0.0
	for b in _bones:
		var tp: Vector3 = (tgt_world * target.get_bone_global_pose(b.idx)).origin
		sum += b.body.global_transform.origin.distance_to(tp)
	return sum / _bones.size()
