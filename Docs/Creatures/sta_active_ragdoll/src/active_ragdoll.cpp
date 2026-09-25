#include "active_ragdoll.h"

#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/physics_server3d.hpp>
#include <godot_cpp/classes/physical_bone_simulator3d.hpp>
#include <godot_cpp/classes/physical_bone3d.hpp>
#include <godot_cpp/classes/collision_shape3d.hpp>
#include <godot_cpp/classes/capsule_shape3d.hpp>
#include <godot_cpp/classes/character_body3d.hpp>
#include <godot_cpp/classes/mesh_instance3d.hpp>
#include <godot_cpp/classes/world3d.hpp>
#include <godot_cpp/classes/physics_direct_space_state3d.hpp>
#include <godot_cpp/classes/physics_ray_query_parameters3d.hpp>
#include <godot_cpp/core/math.hpp>
#include <godot_cpp/variant/typed_array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

using namespace godot;

void ActiveRagdoll::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_simulating", "on"), &ActiveRagdoll::set_simulating);
	ClassDB::bind_method(D_METHOD("get_simulating"), &ActiveRagdoll::get_simulating);
	ClassDB::bind_method(D_METHOD("set_pd_enabled", "on"), &ActiveRagdoll::set_pd_enabled);
	ClassDB::bind_method(D_METHOD("get_pd_enabled"), &ActiveRagdoll::get_pd_enabled);
	ClassDB::bind_method(D_METHOD("set_head_hidden", "hidden"), &ActiveRagdoll::set_head_hidden);
	ClassDB::bind_method(D_METHOD("set_use_procedural_walk", "on"), &ActiveRagdoll::set_use_procedural_walk);
	ClassDB::bind_method(D_METHOD("get_use_procedural_walk"), &ActiveRagdoll::get_use_procedural_walk);
	ClassDB::bind_method(D_METHOD("set_foot_ik_enabled", "on"), &ActiveRagdoll::set_foot_ik_enabled);
	ClassDB::bind_method(D_METHOD("get_foot_ik_enabled"), &ActiveRagdoll::get_foot_ik_enabled);
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "foot_ik_enabled"), "set_foot_ik_enabled", "get_foot_ik_enabled");
	ClassDB::bind_method(D_METHOD("get_anim_target_skeleton"), &ActiveRagdoll::get_anim_target_skeleton);
	ClassDB::bind_method(D_METHOD("set_target_skeleton", "skel"), &ActiveRagdoll::set_target_skeleton);
	// Test / measurement hooks (headless verification).
	ClassDB::bind_method(D_METHOD("get_physical_bone_count"), &ActiveRagdoll::get_physical_bone_count);
	ClassDB::bind_method(D_METHOD("get_bone_index_for", "i"), &ActiveRagdoll::get_bone_index_for);
	ClassDB::bind_method(D_METHOD("get_physical_bone_rid", "i"), &ActiveRagdoll::get_physical_bone_rid);
	ClassDB::bind_method(D_METHOD("get_physical_bone_node", "i"), &ActiveRagdoll::get_physical_bone_node);
	ClassDB::bind_method(D_METHOD("get_mean_tracking_error"), &ActiveRagdoll::get_mean_tracking_error);
	// Rig source (custom bone-spec list — any morphology).
	ClassDB::bind_method(D_METHOD("set_custom_bone_specs", "specs"), &ActiveRagdoll::set_custom_bone_specs);
	ClassDB::bind_method(D_METHOD("get_custom_bone_specs"), &ActiveRagdoll::get_custom_bone_specs);
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "custom_bone_specs"), "set_custom_bone_specs", "get_custom_bone_specs");
	ClassDB::bind_method(D_METHOD("set_base_velocity", "v"), &ActiveRagdoll::set_base_velocity);
	ClassDB::bind_method(D_METHOD("get_base_velocity"), &ActiveRagdoll::get_base_velocity);
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "use_procedural_walk"), "set_use_procedural_walk", "get_use_procedural_walk");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "simulating"), "set_simulating", "get_simulating");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "pd_enabled"), "set_pd_enabled", "get_pd_enabled");

#define RAGDOLL_GAIN(name)                                                               \
	ClassDB::bind_method(D_METHOD("set_" #name, "v"), &ActiveRagdoll::set_##name);       \
	ClassDB::bind_method(D_METHOD("get_" #name), &ActiveRagdoll::get_##name);            \
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, #name), "set_" #name, "get_" #name);
	ClassDB::bind_method(D_METHOD("set_use_velocity_drive", "on"), &ActiveRagdoll::set_use_velocity_drive);
	ClassDB::bind_method(D_METHOD("get_use_velocity_drive"), &ActiveRagdoll::get_use_velocity_drive);
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "use_velocity_drive"), "set_use_velocity_drive", "get_use_velocity_drive");
	RAGDOLL_GAIN(track_position) RAGDOLL_GAIN(track_rotation)
	RAGDOLL_GAIN(max_lin_speed) RAGDOLL_GAIN(max_ang_speed) RAGDOLL_GAIN(snap_distance)
	RAGDOLL_GAIN(anim_authority)
	RAGDOLL_GAIN(limb_pos_kp) RAGDOLL_GAIN(limb_pos_kd)
	RAGDOLL_GAIN(limb_rot_kp) RAGDOLL_GAIN(limb_rot_kd)
	RAGDOLL_GAIN(root_pos_kp) RAGDOLL_GAIN(root_pos_kd)
	RAGDOLL_GAIN(root_rot_kp) RAGDOLL_GAIN(root_rot_kd)
	RAGDOLL_GAIN(stride_length) RAGDOLL_GAIN(leg_swing) RAGDOLL_GAIN(knee_bend) RAGDOLL_GAIN(stance_width)
	RAGDOLL_GAIN(arm_pitch) RAGDOLL_GAIN(arm_yaw) RAGDOLL_GAIN(arm_roll)
	RAGDOLL_GAIN(arm_bob) RAGDOLL_GAIN(elbow_bend)
#undef RAGDOLL_GAIN
}

ActiveRagdoll::ActiveRagdoll() {}

void ActiveRagdoll::_ready() {
	if (Engine::get_singleton()->is_editor_hint()) return;
	player_body = Object::cast_to<CharacterBody3D>(get_parent());
	_build_rig();
	_build_target();
	set_physics_process(true);
}

void ActiveRagdoll::_build_rig() {
	Node *root = get_parent();
	if (!root) return;
	TypedArray<Node> found = root->find_children("*", "Skeleton3D", true, false);
	if (found.is_empty()) {
		UtilityFunctions::push_warning("[ActiveRagdoll] no Skeleton3D found under parent");
		return;
	}
	skeleton = Object::cast_to<Skeleton3D>(found[0]);
	if (!skeleton) return;

	// Cache the bones the walk cycle drives (same indices serve target + puppet — identical rig).
	idx_hips    = skeleton->find_bone("Hips");
	idx_spine   = skeleton->find_bone("Spine_01");
	idx_upleg_l = skeleton->find_bone("UpperLeg_L");
	idx_upleg_r = skeleton->find_bone("UpperLeg_R");
	idx_loleg_l = skeleton->find_bone("LowerLeg_L");
	idx_loleg_r = skeleton->find_bone("LowerLeg_R");
	idx_sh_l    = skeleton->find_bone("Shoulder_L");
	idx_sh_r    = skeleton->find_bone("Shoulder_R");
	idx_elbow_l = skeleton->find_bone("Elbow_L");
	idx_elbow_r = skeleton->find_bone("Elbow_R");
	idx_head    = skeleton->find_bone("Head");
	idx_root    = skeleton->find_bone("Root");
	idx_ankle_l = skeleton->find_bone("Ankle_L");
	idx_ankle_r = skeleton->find_bone("Ankle_R");

	sim = memnew(PhysicalBoneSimulator3D);
	skeleton->add_child(sim);
	sim->set_process_mode(Node::PROCESS_MODE_DISABLED); // enabled on set_simulating(true)

	// Blender cm->m scale compensation (ported verbatim from nut-up SwarmEnemy).
	float skeleton_inherited_scale = 1.0f;
	{
		Node *n = skeleton->get_parent();
		while (n && n != (Node *)root) {
			Node3D *n3d = Object::cast_to<Node3D>(n);
			if (n3d) {
				Vector3 s = n3d->get_scale();
				if (Math::abs(s.x) > 1e-6f) skeleton_inherited_scale *= s.x;
			}
			n = n->get_parent();
		}
		Vector3 ks = skeleton->get_scale();
		if (Math::abs(ks.x) > 1e-6f) skeleton_inherited_scale *= ks.x;
	}
	float ragdoll_comp = (Math::abs(skeleton_inherited_scale) > 1e-6f)
			? 1.0f / skeleton_inherited_scale : 1.0f;

	auto add_phys_bone = [&](const String &bone_name, float radius, float height,
			PhysicalBone3D::JointType joint_type, float swing_deg, float twist_deg,
			float mass, bool is_root) {
		int idx = skeleton->find_bone(bone_name);
		if (idx < 0) return;

		PhysicalBone3D *pb = memnew(PhysicalBone3D);
		pb->set_name(bone_name);
		pb->set("bone_name", bone_name);
		pb->set_mass(mass);
		pb->set_friction(0.8f);
		pb->set_bounce(0.05f);
		pb->set_linear_damp(1.5f);
		pb->set_angular_damp(2.0f);
		pb->set_collision_layer(4); // layer 3: hits World (1) only, not player capsule (2) or each other
		pb->set_collision_mask(1);

		if (!Math::is_equal_approx(ragdoll_comp, 1.0f)) {
			Transform3D body_off;
			body_off.basis = body_off.basis.scaled(Vector3(ragdoll_comp, ragdoll_comp, ragdoll_comp));
			pb->set_body_offset(body_off);
		}

		pb->set_joint_type(joint_type);
		if (joint_type == PhysicalBone3D::JOINT_TYPE_CONE) {
			pb->set("joint/cone_twist/swing_span_1", Math::deg_to_rad(swing_deg));
			pb->set("joint/cone_twist/swing_span_2", Math::deg_to_rad(swing_deg));
			pb->set("joint/cone_twist/twist_span", Math::deg_to_rad(twist_deg));
		}

		CollisionShape3D *cs = memnew(CollisionShape3D);
		Ref<CapsuleShape3D> cap;
		cap.instantiate();
		cap->set_radius(radius);
		cap->set_height(height);
		cs->set_shape(cap);
		pb->add_child(cs);

		sim->add_child(pb);

		BoneEntry e;
		e.body = pb;
		e.bone_idx = idx;
		e.is_root = is_root;
		bones.push_back(e);
	};

	// Rig source: an externally-supplied spec list (any morphology — generated creatures) or,
	// if none was set, the built-in Synty humanoid default. See physics_animation/spec.md §5.
	if (!custom_bone_specs.is_empty()) {
		for (int i = 0; i < custom_bone_specs.size(); i++) {
			Dictionary d = custom_bone_specs[i];
			String nm = d.get("bone_name", "");
			if (nm.is_empty()) continue;
			bool is_root = (bool)d.get("is_root", false);
			int jt = is_root ? (int)PhysicalBone3D::JOINT_TYPE_NONE
							 : (int)d.get("joint_type", (int)PhysicalBone3D::JOINT_TYPE_CONE);
			add_phys_bone(nm, (float)d.get("radius", 0.06), (float)d.get("height", 0.15),
					(PhysicalBone3D::JointType)jt, (float)d.get("swing_deg", 40.0),
					(float)d.get("twist_deg", 20.0), (float)d.get("mass", 3.0), is_root);
		}
	} else {
		// Fuller rig so the ragdoll reproduces the clip instead of a stiff-hip noodle:
		// spine chain (torso follows), elbows/hands (arms bend, no T-pose sticks), ankles (feet).
		// (name, radius, height, joint, swing°, twist°, mass, is_root)
		add_phys_bone("Hips",       0.12f, 0.22f, PhysicalBone3D::JOINT_TYPE_NONE, 0,     0,     6.0f, true);
		add_phys_bone("Spine_01",   0.10f, 0.20f, PhysicalBone3D::JOINT_TYPE_CONE, 30.0f, 20.0f, 5.0f, false);
		add_phys_bone("Spine_02",   0.10f, 0.18f, PhysicalBone3D::JOINT_TYPE_CONE, 25.0f, 15.0f, 4.0f, false);
		add_phys_bone("Spine_03",   0.09f, 0.14f, PhysicalBone3D::JOINT_TYPE_CONE, 20.0f, 15.0f, 3.0f, false);
		add_phys_bone("UpperLeg_L", 0.07f, 0.32f, PhysicalBone3D::JOINT_TYPE_CONE, 50.0f, 30.0f, 5.0f, false);
		add_phys_bone("UpperLeg_R", 0.07f, 0.32f, PhysicalBone3D::JOINT_TYPE_CONE, 50.0f, 30.0f, 5.0f, false);
		add_phys_bone("LowerLeg_L", 0.05f, 0.28f, PhysicalBone3D::JOINT_TYPE_CONE, 25.0f, 10.0f, 4.0f, false);
		add_phys_bone("LowerLeg_R", 0.05f, 0.28f, PhysicalBone3D::JOINT_TYPE_CONE, 25.0f, 10.0f, 4.0f, false);
		add_phys_bone("Ankle_L",    0.05f, 0.14f, PhysicalBone3D::JOINT_TYPE_CONE, 30.0f, 20.0f, 2.0f, false);
		add_phys_bone("Ankle_R",    0.05f, 0.14f, PhysicalBone3D::JOINT_TYPE_CONE, 30.0f, 20.0f, 2.0f, false);
		add_phys_bone("Shoulder_L", 0.05f, 0.28f, PhysicalBone3D::JOINT_TYPE_CONE, 60.0f, 40.0f, 3.0f, false);
		add_phys_bone("Shoulder_R", 0.05f, 0.28f, PhysicalBone3D::JOINT_TYPE_CONE, 60.0f, 40.0f, 3.0f, false);
		add_phys_bone("Elbow_L",    0.05f, 0.24f, PhysicalBone3D::JOINT_TYPE_CONE, 40.0f, 20.0f, 2.0f, false);
		add_phys_bone("Elbow_R",    0.05f, 0.24f, PhysicalBone3D::JOINT_TYPE_CONE, 40.0f, 20.0f, 2.0f, false);
		add_phys_bone("Hand_L",     0.04f, 0.10f, PhysicalBone3D::JOINT_TYPE_CONE, 30.0f, 30.0f, 1.0f, false);
		add_phys_bone("Hand_R",     0.04f, 0.10f, PhysicalBone3D::JOINT_TYPE_CONE, 30.0f, 30.0f, 1.0f, false);
	}

	// Mask of which skeleton bones have a physical body — everything else (Head, Neck,
	// fingers, toes) keeps following the clip directly while the ragdoll simulates.
	simulated_bone.assign(skeleton->get_bone_count(), false);
	for (const BoneEntry &e : bones) {
		if (e.bone_idx >= 0 && e.bone_idx < (int)simulated_bone.size()) simulated_bone[e.bone_idx] = true;
	}
}

void ActiveRagdoll::_build_target() {
	// Externally provided (e.g. a procedural creature's gait skeleton, via set_target_skeleton) —
	// skip the built-in "CharacterMesh" duplication and chase the given skeleton.
	if (target_skel) return;
	// Hidden duplicate of the visible mesh — same transform (incl. the 180° facing), so its
	// world bone poses line up with the puppet. Mesh hidden; only the skeleton matters.
	Node *root = get_parent();
	if (!root) return;
	Node *vis = root->get_node_or_null("CharacterMesh");
	if (!vis) {
		UtilityFunctions::push_warning("[ActiveRagdoll] CharacterMesh not found — no anim target");
		return;
	}
	Node *dup = Object::cast_to<Node>(vis)->duplicate();
	if (!dup) return;
	dup->set_name("AnimTarget");
	root->add_child(dup);
	target_root = dup;

	TypedArray<Node> meshes = dup->find_children("*", "MeshInstance3D", true, false);
	for (int i = 0; i < meshes.size(); i++) {
		MeshInstance3D *mi = Object::cast_to<MeshInstance3D>(meshes[i]);
		if (mi) mi->set_visible(false);
	}
	TypedArray<Node> tskel = dup->find_children("*", "Skeleton3D", true, false);
	if (!tskel.is_empty()) target_skel = Object::cast_to<Skeleton3D>(tskel[0]);
}

void ActiveRagdoll::set_simulating(bool p_on) {
	if (p_on == simulating) return;
	if (!sim || !skeleton) { simulating = false; return; }

	if (p_on) {
		skeleton->set_process_mode(Node::PROCESS_MODE_INHERIT);
		sim->set_process_mode(Node::PROCESS_MODE_INHERIT);
		sim->physical_bones_start_simulation();
		simulating = true;
	} else {
		sim->physical_bones_stop_simulation();
		sim->set_process_mode(Node::PROCESS_MODE_DISABLED);
		simulating = false;
	}
}

void ActiveRagdoll::_physics_process(double delta) {
	if (!skeleton) return;

	// Target pose source: built-in sine walk, OR (Slice 1) an external AnimationTree that a
	// GDScript driver runs on the target skeleton. Either way a pose is ready each frame.
	if (use_procedural_walk) _drive_walk(delta);

	// Clip Hips/Root POSITION tracks are wrong-scale for this rig — pin them to rest every
	// frame (rotations only from the clips). Foot IK then applies its pelvis drop ON TOP,
	// which is why the pin must happen here, before _foot_ik, not inside _pd_step.
	if (!use_procedural_walk && target_skel) {
		if (idx_root >= 0) target_skel->set_bone_pose_position(idx_root, target_skel->get_bone_rest(idx_root).origin);
		if (idx_hips >= 0) target_skel->set_bone_pose_position(idx_hips, target_skel->get_bone_rest(idx_hips).origin);
	}
	if (foot_ik_enabled) _foot_ik(delta);

	if (simulating) {
		if (pd_enabled) _pd_step(delta);
		// Head/neck/fingers/toes have no physical bones — without this they freeze at rest
		// while the spine sways, which reads as the head wobbling side to side when running.
		_copy_unsimulated_to_puppet();
	} else {
		_copy_target_to_puppet();
	}
}

void ActiveRagdoll::_copy_unsimulated_to_puppet() {
	if (!target_skel || !skeleton) return;
	int n = skeleton->get_bone_count();
	if (target_skel->get_bone_count() < n) n = target_skel->get_bone_count();
	if ((int)simulated_bone.size() < n) return;
	for (int i = 0; i < n; i++) {
		if (simulated_bone[i]) continue;
		skeleton->set_bone_pose_rotation(i, target_skel->get_bone_pose_rotation(i));
	}
}

// Compose a delta rotation onto the bone's rest orientation (never replace, or the bone
// snaps to T-pose). Writes to the TARGET skeleton.
static inline void anim_bone(Skeleton3D *sk, int idx, const Quaternion &delta) {
	if (idx < 0) return;
	Quaternion rest_q = sk->get_bone_rest(idx).basis.get_rotation_quaternion();
	sk->set_bone_pose_rotation(idx, rest_q * delta);
}

void ActiveRagdoll::_drive_walk(double delta) {
	if (!target_skel) return;

	// Tangential speed: strip the radial (gravity-up) component so the cadence works on the
	// sphere. Player body basis Y is the rebased local up (Docs/05).
	float spd = 0.0f;
	if (player_body) {
		Vector3 vel = player_body->get_velocity();
		Vector3 up = player_body->get_global_transform().basis.get_column(1).normalized();
		spd = (vel - up * vel.dot(up)).length();
	}

	float amp_target = Math::clamp(spd * 0.6f, 0.0f, 1.0f);
	anim_amp = Math::lerp(anim_amp, amp_target, (float)delta * 8.0f);
	float a = anim_amp;

	// Advance phase by GROUND DISTANCE, not time: one full stride per `stride_length` metres.
	// The foot's backswing speed then matches ground speed -> no sliding.
	const float TAU = 6.28318530718f;
	const float PI_F = 3.14159265358979f;
	if (stride_length > 0.01f) anim_phase += (spd * (float)delta / stride_length) * TAU;

	float sw  = Math::sin(anim_phase) * a;
	float sw2 = Math::sin(anim_phase + PI_F) * a;

	const Vector3 X(1, 0, 0), Y(0, 1, 0), Z(0, 0, 1);

	anim_bone(target_skel, idx_hips,  Quaternion(Z, sw * 0.06f));
	// Spine: compose Z counter-tilt + Y twist in ONE write (two writes would overwrite).
	anim_bone(target_skel, idx_spine, Quaternion(Z, -sw * 0.04f) * Quaternion(Y, sw2 * 0.05f));

	// Legs: fwd/back swing (X) + constant outward splay (Z, mirrored) for a wider stance.
	// Splay eased by amp so a standing player returns to the neutral rest pose.
	anim_bone(target_skel, idx_upleg_l, Quaternion(X, sw  * leg_swing) * Quaternion(Z,  stance_width * a));
	anim_bone(target_skel, idx_upleg_r, Quaternion(X, sw2 * leg_swing) * Quaternion(Z, -stance_width * a));
	float knee_l = (-sw  > 0.0f) ? -sw  * knee_bend : 0.0f;
	float knee_r = (-sw2 > 0.0f) ? -sw2 * knee_bend : 0.0f;
	anim_bone(target_skel, idx_loleg_l, Quaternion(X, knee_l));
	anim_bone(target_skel, idx_loleg_r, Quaternion(X, knee_r));

	// Arms: FPS-hands hold. Shoulder = upper arm; Z = up/down (arm_roll<0 = down at sides),
	// Y = fwd/back (mirrored per side). Constant part UN-eased; only the bob is speed-gated.
	Quaternion sh_l = Quaternion(Z, arm_roll) * Quaternion(Y,  arm_yaw) * Quaternion(X, arm_pitch);
	Quaternion sh_r = Quaternion(Z, arm_roll) * Quaternion(Y, -arm_yaw) * Quaternion(X, arm_pitch);
	anim_bone(target_skel, idx_sh_l, sh_l * Quaternion(Z, sw  * arm_bob));
	anim_bone(target_skel, idx_sh_r, sh_r * Quaternion(Z, sw2 * arm_bob));
	// Elbows: flex forearms up/forward (mirrored). Flip elbow_bend sign if they fold backward.
	anim_bone(target_skel, idx_elbow_l, Quaternion(X,  elbow_bend));
	anim_bone(target_skel, idx_elbow_r, Quaternion(X, -elbow_bend));
}

void ActiveRagdoll::set_head_hidden(bool hidden) {
	if (!skeleton || idx_head < 0) return;
	// Collapse the Head bone to ~0 so its skinned verts vanish (no separate head mesh to toggle).
	skeleton->set_bone_pose_scale(idx_head, hidden ? Vector3(0.001f, 0.001f, 0.001f) : Vector3(1, 1, 1));
}

void ActiveRagdoll::_copy_target_to_puppet() {
	if (!target_skel || !skeleton) return;
	// Full-body copy (target and puppet are the same Enemy1 rig -> indices match). Rotation
	// only, so the FPS head-hide scale set on the puppet survives. Covers every animated bone
	// (spine chain, ankles, fingers) that the clip drives, not just the 10 the sine walk used.
	int n = skeleton->get_bone_count();
	if (target_skel->get_bone_count() < n) n = target_skel->get_bone_count();
	for (int i = 0; i < n; i++) {
		skeleton->set_bone_pose_rotation(i, target_skel->get_bone_pose_rotation(i));
	}
	// Hips position too — carries the foot-IK pelvis drop to the visible mesh.
	if (idx_hips >= 0) skeleton->set_bone_pose_position(idx_hips, target_skel->get_bone_pose_position(idx_hips));
}

// ── Foot IK ──────────────────────────────────────────────────────────────────
// Per foot: ray the ground at the animated ankle's XZ, weight by stance phase (a foot high
// in its swing is left alone), drop the pelvis so the downhill leg can reach, then a 2-pass
// analytic 2-bone solve. Runs on the TARGET skeleton, so ragdoll-on (PD chase) and
// ragdoll-off (pose copy) both inherit planted feet.
void ActiveRagdoll::_foot_ik(double delta) {
	if (!target_skel || !player_body || !player_body->is_inside_tree()) return;

	float w_target = player_body->is_on_floor() ? 1.0f : 0.0f;
	foot_ik_w = Math::lerp(foot_ik_w, w_target, Math::min((float)delta * 10.0f, 1.0f));
	if (foot_ik_w < 0.02f) return;
	if (idx_ankle_l < 0 || idx_ankle_r < 0 || idx_hips < 0) return;

	Ref<World3D> w3d = player_body->get_world_3d();
	if (w3d.is_null()) return;
	PhysicsDirectSpaceState3D *space = w3d->get_direct_space_state();
	if (!space) return;

	const Transform3D pxf = player_body->get_global_transform();
	const Vector3 up = pxf.basis.get_column(1).normalized();
	const Vector3 org = pxf.origin;   // capsule bottom = clip ground plane
	const Transform3D skel_xf = target_skel->get_global_transform();

	const float MAX_LIFT = 0.5f, MAX_DROP = 0.45f;
	const float PLANT_H = 0.12f, SWING_H = 0.25f;   // stance weight ramp (ankle height)

	struct LegDef { int up_b, lo_b, an_b; };
	LegDef legs[2] = { { idx_upleg_l, idx_loleg_l, idx_ankle_l },
					   { idx_upleg_r, idx_loleg_r, idx_ankle_r } };
	float h_off[2] = { 0.0f, 0.0f };
	float foot_w[2] = { 0.0f, 0.0f };
	Vector3 anim_ankle[2];

	for (int i = 0; i < 2; i++) {
		anim_ankle[i] = skel_xf.xform(target_skel->get_bone_global_pose(legs[i].an_b).origin);
		float anim_h = (anim_ankle[i] - org).dot(up);
		foot_w[i] = Math::clamp(1.0f - (anim_h - PLANT_H) / SWING_H, 0.0f, 1.0f);
		if (foot_w[i] <= 0.0f) continue;
		// Ray from knee height above the clip ground plane at the foot's lateral position.
		Vector3 foot_flat = anim_ankle[i] - up * anim_h;
		// Mask = World (1) + Goo (128, GooSim.GOO_COLLISION_LAYER) so feet plant on goo piles too.
		Ref<PhysicsRayQueryParameters3D> q =
				PhysicsRayQueryParameters3D::create(foot_flat + up * 0.6f, foot_flat - up * 1.2f, 1 | 128);
		Dictionary hit = space->intersect_ray(q);
		if (hit.is_empty()) {
			foot_w[i] = 0.0f;
			continue;
		}
		h_off[i] = Math::clamp((float)((Vector3(hit["position"]) - org).dot(up)), -MAX_DROP, MAX_LIFT);
	}

	// Pelvis drops by the most negative needed offset so that leg can reach; the other leg
	// bends to stay planted. (Pin already reset hips to rest this frame.)
	float pelvis = Math::min(Math::min(h_off[0] * foot_w[0], h_off[1] * foot_w[1]), 0.0f) * foot_ik_w;
	if (pelvis < -0.005f) {
		Vector3 drop_skel = skel_xf.basis.inverse().xform(up * pelvis);   // handles armature scale
		target_skel->set_bone_pose_position(idx_hips,
				target_skel->get_bone_rest(idx_hips).origin + drop_skel);
	}

	for (int i = 0; i < 2; i++) {
		float corr = h_off[i] * foot_w[i] * foot_ik_w;
		if (Math::abs(corr) < 0.005f) continue;
		_solve_leg_ik(legs[i].up_b, legs[i].lo_b, legs[i].an_b, anim_ankle[i] + up * corr);
	}
}

void ActiveRagdoll::_solve_leg_ik(int up_b, int lo_b, int an_b, const Vector3 &desired) {
	const Transform3D skel_xf = target_skel->get_global_transform();
	auto gworld = [&](int b) -> Transform3D {
		Transform3D g = target_skel->get_bone_global_pose(b);
		return Transform3D(skel_xf.basis * g.basis, skel_xf.xform(g.origin));
	};

	// Preserve the clip's foot orientation through the parent-chain rotations.
	const Basis ankle_world = gworld(an_b).basis;

	for (int pass = 0; pass < 2; pass++) {
		Vector3 hip = gworld(up_b).origin;
		Vector3 knee = gworld(lo_b).origin;
		Vector3 ank = gworld(an_b).origin;
		float l1 = hip.distance_to(knee);
		float l2 = knee.distance_to(ank);
		if (l1 < 1e-4f || l2 < 1e-4f) return;

		Vector3 v_cur = ank - hip;
		Vector3 v_des = desired - hip;
		if (v_cur.length() < 1e-4f || v_des.length() < 1e-4f) return;
		float d = Math::clamp(v_des.length(), Math::abs(l1 - l2) + 0.01f, l1 + l2 - 0.01f);

		// 1) swing the upper leg so the chain aims at the target
		Quaternion arc = Quaternion(v_cur.normalized(), v_des.normalized());
		_set_bone_world_rot(up_b, Basis(arc) * gworld(up_b).basis);

		// 2) open/close the knee so the hip->ankle distance matches d
		hip = gworld(up_b).origin;
		knee = gworld(lo_b).origin;
		ank = gworld(an_b).origin;
		Vector3 a = hip - knee;
		Vector3 b = ank - knee;
		Vector3 hinge = a.cross(b);
		if (hinge.length() < 1e-5f) return;   // degenerate (dead-straight leg)
		float cur_ang = a.angle_to(b);
		float need = Math::acos(Math::clamp((l1 * l1 + l2 * l2 - d * d) / (2.0f * l1 * l2), -1.0f, 1.0f));
		_set_bone_world_rot(lo_b, Basis(Quaternion(hinge.normalized(), need - cur_ang)) * gworld(lo_b).basis);
	}

	_set_bone_world_rot(an_b, ankle_world);
}

void ActiveRagdoll::_set_bone_world_rot(int bone, const Basis &world_basis) {
	const Basis skel_inv = target_skel->get_global_transform().basis.inverse();
	const Basis in_skel = skel_inv * world_basis;
	const int parent = target_skel->get_bone_parent(bone);
	const Basis parent_skel = (parent >= 0) ? target_skel->get_bone_global_pose(parent).basis : Basis();
	const Basis local = parent_skel.inverse() * in_skel;
	target_skel->set_bone_pose_rotation(bone, local.get_rotation_quaternion().normalized());
}

void ActiveRagdoll::_pd_step(double delta) {
	if (!target_skel) return;
	// (Root/hips position pin happens in _physics_process, before foot IK.)
	PhysicsServer3D *ps = PhysicsServer3D::get_singleton();
	const Transform3D tgt_world = target_skel->get_global_transform();

	for (const BoneEntry &b : bones) {
		if (!b.body || b.bone_idx < 0) continue;
		RID rid = b.body->get_rid();

		// Target = the animated pose on the hidden target skeleton, in world space.
		const Transform3D target = tgt_world * target_skel->get_bone_global_pose(b.bone_idx);
		const Transform3D cur = b.body->get_global_transform();

		// ── Velocity drive ("soft keying" — Jolt-author-recommended) ──────────────
		// Set the velocity that reaches the target THIS step. Unconditionally stable:
		// no spring gains, one knob (track). Collisions perturb the body mid-step; next
		// frame re-aims. Clamps keep corrections physical instead of teleport-y.
		if (use_velocity_drive) {
			Quaternion q_cur = cur.basis.get_rotation_quaternion().normalized();
			Quaternion q_tgt = target.basis.get_rotation_quaternion().normalized();

			// Feed-forward the player's own velocity: the target rides the capsule, so when
			// falling/sprinting faster than max_lin_speed the bones must carry that base
			// motion for free. Clamping the TOTAL velocity made bones lag past snap_distance
			// during >12 m/s falls -> snap-teleport loop -> heavy jitter. Clamp only the
			// CORRECTION on top of the base motion.
			Vector3 base_vel = external_base_velocity;   // creature feed (0 unless set)
			if (player_body) base_vel = player_body->get_velocity();

			Vector3 pos_err = target.origin - cur.origin;
			if (pos_err.length() > snap_distance) {
				// Blown past recovery (explosion / respawn): hard-snap to target.
				b.body->set_global_transform(Transform3D(Basis(q_tgt), target.origin));
				ps->body_set_state(rid, PhysicsServer3D::BODY_STATE_LINEAR_VELOCITY, base_vel);
				ps->body_set_state(rid, PhysicsServer3D::BODY_STATE_ANGULAR_VELOCITY, Vector3());
				continue;
			}
			Vector3 corr = pos_err / (float)delta * track_position;
			float ls = corr.length();
			if (ls > max_lin_speed) corr *= max_lin_speed / ls;
			Vector3 want_lin = base_vel + corr;

			Quaternion q_err = (q_tgt * q_cur.inverse()).normalized();
			if (q_err.w < 0.0f) q_err = -q_err;
			Vector3 axis;
			real_t angle;
			q_err.get_axis_angle(axis, angle);
			Vector3 want_ang;
			if (axis.is_finite() && angle > 1e-5f) {
				want_ang = axis * (float)angle / (float)delta * track_rotation;
				float as = want_ang.length();
				if (as > max_ang_speed) want_ang *= max_ang_speed / as;
			}

			ps->body_set_state(rid, PhysicsServer3D::BODY_STATE_LINEAR_VELOCITY, want_lin);
			ps->body_set_state(rid, PhysicsServer3D::BODY_STATE_ANGULAR_VELOCITY, want_ang);
			continue;
		}

		// ── Torque PD fallback (use_velocity_drive = false) ───────────────────────
		const Vector3 lin_vel = ps->body_get_state(rid, PhysicsServer3D::BODY_STATE_LINEAR_VELOCITY);
		const Vector3 ang_vel = ps->body_get_state(rid, PhysicsServer3D::BODY_STATE_ANGULAR_VELOCITY);

		const float auth = anim_authority;
		const float mass = b.body->get_mass();
		const float rkp = (b.is_root ? root_rot_kp : limb_rot_kp) * auth;
		const float rkd = (b.is_root ? root_rot_kd : limb_rot_kd) * auth;

		// Orientation torque for EVERY bone — the pose driver. Mass-scaled so a single
		// stiffness reads the same on a thigh and a finger; the joints keep bones attached.
		Quaternion q_cur = cur.basis.get_rotation_quaternion().normalized();
		Quaternion q_tgt = target.basis.get_rotation_quaternion().normalized();
		Quaternion q_err = (q_tgt * q_cur.inverse()).normalized();
		if (q_err.w < 0.0f) q_err = -q_err;
		Vector3 axis;
		real_t angle;
		q_err.get_axis_angle(axis, angle);
		Vector3 torque;
		if (axis.is_finite() && angle > 1e-5f) torque = axis * (float)angle * rkp;
		torque -= ang_vel * rkd;
		ps->body_apply_torque(rid, torque * mass);

		// Position control ONLY for the root (the marionette handle): holds the whole body up
		// and in place. Limbs deliberately get NO positional force — that fighting the joints
		// was the "fix standing, break walking" problem. Limbs hang from their joints and are
		// posed purely by the torque above, so one stiffness works for every pose.
		if (b.is_root) {
			const Vector3 pos_err = target.origin - cur.origin;
			const Vector3 force = (pos_err * root_pos_kp - lin_vel * root_pos_kd) * auth * mass;
			ps->body_apply_central_force(rid, force);
		}
	}
}

// ── Test / measurement hooks ─────────────────────────────────────────────────
// Side-effect-free getters so a headless smoke test can inspect the built rig and its
// live tracking error. See ProceduralCharacters/physics_animation/VERIFICATION.md §4.

int ActiveRagdoll::get_bone_index_for(int i) const {
	if (i < 0 || i >= (int)bones.size()) return -1;
	return bones[i].bone_idx;
}

RID ActiveRagdoll::get_physical_bone_rid(int i) const {
	if (i < 0 || i >= (int)bones.size() || !bones[i].body) return RID();
	return bones[i].body->get_rid();
}

PhysicalBone3D *ActiveRagdoll::get_physical_bone_node(int i) const {
	if (i < 0 || i >= (int)bones.size()) return nullptr;
	return bones[i].body;
}

float ActiveRagdoll::get_mean_tracking_error() const {
	if (!target_skel || bones.empty()) return 0.0f;
	const Transform3D tgt_world = target_skel->get_global_transform();
	float sum = 0.0f;
	int cnt = 0;
	for (const BoneEntry &b : bones) {
		if (!b.body || b.bone_idx < 0) continue;
		const Vector3 tp = (tgt_world * target_skel->get_bone_global_pose(b.bone_idx)).origin;
		sum += b.body->get_global_transform().origin.distance_to(tp);
		cnt++;
	}
	return cnt > 0 ? sum / (float)cnt : 0.0f;
}
