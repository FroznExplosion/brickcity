#pragma once
// ActiveRagdoll — PrimalCore-style "active ragdoll" driver for the player body.
// (Docs/12 §8, memory nut-up-character-ragdoll-source.)
//
// Builds a PhysicalBoneSimulator3D ragdoll on a sibling Skeleton3D (ported from
// nut-up SwarmEnemy, including the Blender cm->m scale fix), then — while simulating —
// runs a Proportional-Derivative controller every physics frame so the physical bones
// CHASE a kinematic target pose. v1 target = the skeleton's rest pose (so the body
// stands/holds against gravity and follows the moving player). Later the target becomes
// a live animation pose.
//
// Marionette anchoring: the Hips bone gets a very stiff PD (acts as a near-pinned root
// that tracks the player), limbs get a softer PD (goofy, tunable). Toggle from
// PlayerController (toggle_ragdoll / G). Default OFF — the kinematic mesh plays normally.
#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/classes/skeleton3d.hpp>
#include <godot_cpp/variant/transform3d.hpp>
#include <godot_cpp/variant/rid.hpp>
#include <godot_cpp/variant/array.hpp>
#include <vector>

namespace godot {

class PhysicalBoneSimulator3D;
class PhysicalBone3D;
class CharacterBody3D;

class ActiveRagdoll : public Node {
	GDCLASS(ActiveRagdoll, Node)

	// PD gains. Force/torque are scaled so these read as ~accelerations (mass-independent
	// for position). Tune in the inspector. Root (Hips) is much stiffer = anchor.
	// Drive method. Velocity drive ("soft keying", recommended by Jolt's author for active
	// ragdolls) sets each bone's velocity to reach its target this step: stable, one knob,
	// no spring gains to fight. Torque PD kept as a fallback (use_velocity_drive = false).
	bool use_velocity_drive = true;
	float track_position = 1.0f;   // 0..1 — how hard bones chase target positions (1 = clip-exact)
	float track_rotation = 1.0f;   // 0..1 — how hard bones chase target orientations
	float max_lin_speed = 12.0f;   // m/s clamp on corrective velocity (keeps it physical)
	float max_ang_speed = 50.0f;   // rad/s clamp
	float snap_distance = 1.0f;    // bone farther than this from target = teleport back (blow-up guard)

	// Global stiffness multiplier on every gain below. 1 = base (already stiff, hugs the clip);
	// raise toward clip-exact, lower to let physics take over. The in-game menu drives this.
	float anim_authority = 1.0f;
	// Marionette gains. Torque is mass-scaled in _pd_step, so these are tuned for that.
	// limb_pos_* are unused now (limbs get no positional force) — kept for compatibility.
	float limb_pos_kp = 0.0f;
	float limb_pos_kd = 0.0f;
	float limb_rot_kp = 150.0f;   // pose stiffness for all limbs
	float limb_rot_kd = 18.0f;    // limb damping
	float root_pos_kp = 9000.0f;  // holds the hips at the right place/height
	float root_pos_kd = 230.0f;
	float root_rot_kp = 500.0f;   // holds the hips upright/facing
	float root_rot_kd = 40.0f;

	// Walk shaping (inspector-tunable; placeholder cycle, expect to dial these in).
	float stride_length = 1.6f;  // ground metres per full stride — bigger = longer/slower steps
	float leg_swing = 1.0f;      // upper-leg fwd/back swing amplitude (rad) — bigger = longer steps
	float knee_bend = 1.3f;      // lower-leg flex on the trailing leg (rad)
	float stance_width = 0.16f;  // constant outward leg splay so feet aren't pinched (rad)
	// Arm hold (Shoulder = upper arm). Euler compose Z*Y*X. From T-pose: Z = up/down
	// (+ = overhead, - = down at sides), Y = fwd/back swing. Default = arms DOWN + elbows bent
	// forward = hands in front (low-ready). Tune live; flip elbow sign if forearms fold back.
	float arm_pitch = 0.0f;      // X: twist along the arm
	float arm_yaw = 0.0f;        // Y: swing fwd/back (mirrored per side)
	float arm_roll = -1.5f;      // Z: raise/lower (- = arms down at sides)
	float arm_bob = 0.10f;       // small arm sway while walking (rad)
	float elbow_bend = 1.3f;     // Elbow flex so forearms come up in front (rad)

	bool pd_enabled = true;
	bool simulating = false;
	// When true, the built-in sine walk drives the target. Set false once a GDScript
	// AnimationTree is driving the target skeleton with real clips (Slice 1).
	bool use_procedural_walk = true;

	// Optional custom physical-bone spec list (Array of Dictionaries; keys per
	// physics_animation/spec.md §5: bone_name, radius, height, joint_type, swing_deg,
	// twist_deg, mass, is_root). Empty = the built-in 16-bone Synty humanoid rig. Set from
	// GDScript BEFORE add_child() so _ready()'s _build_rig() sees it — lets ONE C++ drive serve
	// generated creatures (any morphology) as well as the humanoid player.
	Array custom_bone_specs;

	// Puppet = the visible skeleton, driven by physics while simulating.
	Skeleton3D *skeleton = nullptr;
	PhysicalBoneSimulator3D *sim = nullptr;

	// Target = a hidden duplicate skeleton that runs the procedural walk. The PD chases
	// ITS bone poses. Separate skeleton because the simulator overwrites the puppet's
	// poses while simulating, so the animation must live somewhere the physics can't clobber.
	Skeleton3D *target_skel = nullptr;
	Node *target_root = nullptr;
	CharacterBody3D *player_body = nullptr;

	// Base velocity for the drive's feed-forward when there is NO CharacterBody3D parent
	// (e.g. a procedural creature moved by its gait). Set each physics frame from GDScript.
	// A present player_body always wins over this. See physics_animation/spec.md §5.
	Vector3 external_base_velocity;

	// Procedural walk state (Docs/12 §2, ported from SwarmEnemy). anim_amp eases 0->1 with
	// tangential speed so a standing player settles to the rest pose instead of freezing mid-stride.
	float anim_phase = 0.0f;
	float anim_amp = 0.0f;
	int idx_hips = -1, idx_spine = -1;
	int idx_upleg_l = -1, idx_upleg_r = -1;
	int idx_loleg_l = -1, idx_loleg_r = -1;
	int idx_sh_l = -1, idx_sh_r = -1;
	int idx_elbow_l = -1, idx_elbow_r = -1;
	int idx_head = -1;
	int idx_root = -1;
	int idx_ankle_l = -1, idx_ankle_r = -1;

	// Foot IK (runs on the TARGET skeleton before the PD/copy, so planted feet show in both
	// ragdoll-on and ragdoll-off modes). Raycast ground per foot, stance-weighted, pelvis
	// drop, analytic 2-bone solve.
	bool foot_ik_enabled = true;
	float foot_ik_w = 0.0f;   // eased master weight (0 in air)

	struct BoneEntry {
		PhysicalBone3D *body = nullptr;
		int bone_idx = -1;
		bool is_root = false;
	};
	std::vector<BoneEntry> bones;
	std::vector<bool> simulated_bone;   // per skeleton bone index: has a PhysicalBone3D

	void _build_rig();
	void _build_target();
	void _drive_walk(double delta);       // writes the walk pose to the target skeleton
	void _copy_target_to_puppet();        // mirrors target pose onto the visible mesh (ragdoll off)
	void _copy_unsimulated_to_puppet();   // ragdoll ON: head/neck/fingers etc. still follow the clip
	void _pd_step(double delta);          // drives puppet physics toward the target pose (ragdoll on)
	void _foot_ik(double delta);          // plant feet on terrain (target skeleton, pre-PD)
	void _solve_leg_ik(int up_b, int lo_b, int an_b, const Vector3 &desired_world);
	void _set_bone_world_rot(int bone, const Basis &world_basis);

protected:
	static void _bind_methods();

public:
	ActiveRagdoll();

	void _ready() override;
	void _physics_process(double delta) override;

	// Start/stop the physics simulation. While stopped, the kinematic skeleton pose shows.
	void set_simulating(bool p_on);
	bool get_simulating() const { return simulating; }

	void set_pd_enabled(bool p_on) { pd_enabled = p_on; }
	bool get_pd_enabled() const { return pd_enabled; }

	// --- tuning (bound as properties) ---
	void set_limb_pos_kp(float v) { limb_pos_kp = v; }  float get_limb_pos_kp() const { return limb_pos_kp; }
	void set_limb_pos_kd(float v) { limb_pos_kd = v; }  float get_limb_pos_kd() const { return limb_pos_kd; }
	void set_limb_rot_kp(float v) { limb_rot_kp = v; }  float get_limb_rot_kp() const { return limb_rot_kp; }
	void set_limb_rot_kd(float v) { limb_rot_kd = v; }  float get_limb_rot_kd() const { return limb_rot_kd; }
	void set_root_pos_kp(float v) { root_pos_kp = v; }  float get_root_pos_kp() const { return root_pos_kp; }
	void set_root_pos_kd(float v) { root_pos_kd = v; }  float get_root_pos_kd() const { return root_pos_kd; }
	void set_root_rot_kp(float v) { root_rot_kp = v; }  float get_root_rot_kp() const { return root_rot_kp; }
	void set_root_rot_kd(float v) { root_rot_kd = v; }  float get_root_rot_kd() const { return root_rot_kd; }
	void set_anim_authority(float v) { anim_authority = v; } float get_anim_authority() const { return anim_authority; }

	void set_use_velocity_drive(bool v) { use_velocity_drive = v; } bool get_use_velocity_drive() const { return use_velocity_drive; }
	void set_track_position(float v) { track_position = v; }  float get_track_position() const { return track_position; }
	void set_track_rotation(float v) { track_rotation = v; }  float get_track_rotation() const { return track_rotation; }
	void set_max_lin_speed(float v) { max_lin_speed = v; }    float get_max_lin_speed() const { return max_lin_speed; }
	void set_max_ang_speed(float v) { max_ang_speed = v; }    float get_max_ang_speed() const { return max_ang_speed; }
	void set_snap_distance(float v) { snap_distance = v; }    float get_snap_distance() const { return snap_distance; }

	void set_stride_length(float v) { stride_length = v; } float get_stride_length() const { return stride_length; }
	void set_leg_swing(float v) { leg_swing = v; }         float get_leg_swing() const { return leg_swing; }
	void set_knee_bend(float v) { knee_bend = v; }         float get_knee_bend() const { return knee_bend; }
	void set_stance_width(float v) { stance_width = v; }    float get_stance_width() const { return stance_width; }
	void set_arm_pitch(float v) { arm_pitch = v; }         float get_arm_pitch() const { return arm_pitch; }
	void set_arm_yaw(float v) { arm_yaw = v; }             float get_arm_yaw() const { return arm_yaw; }
	void set_arm_roll(float v) { arm_roll = v; }           float get_arm_roll() const { return arm_roll; }
	void set_arm_bob(float v) { arm_bob = v; }             float get_arm_bob() const { return arm_bob; }
	void set_elbow_bend(float v) { elbow_bend = v; }       float get_elbow_bend() const { return elbow_bend; }

	// FPS: collapse the Head bone so the player doesn't see inside their own skull.
	void set_head_hidden(bool hidden);

	void set_use_procedural_walk(bool v) { use_procedural_walk = v; }
	bool get_use_procedural_walk() const { return use_procedural_walk; }

	void set_foot_ik_enabled(bool v) { foot_ik_enabled = v; }
	bool get_foot_ik_enabled() const { return foot_ik_enabled; }

	// The hidden target skeleton (Enemy1 duplicate). GDScript attaches an AnimationTree
	// here to drive it with real clips; the PD then chases it.
	Skeleton3D *get_anim_target_skeleton() const { return target_skel; }

	// Inject an external Target skeleton (e.g. a procedural creature's gait-posed skeleton) BEFORE
	// add_child(). Then _build_target() skips its built-in "CharacterMesh" duplication and the drive
	// chases the provided skeleton instead. Set use_procedural_walk=false so the gait (not the sine
	// walk) drives it. This is what lets the one C++ drive serve creatures, not just the humanoid.
	void set_target_skeleton(Skeleton3D *p_skel) { target_skel = p_skel; }

	// --- test / measurement hooks (headless verification; side-effect-free getters) ---
	// See ProceduralCharacters/physics_animation/VERIFICATION.md §4. Let a smoke test read
	// the built rig and its live tracking error without walking the node tree.
	int get_physical_bone_count() const { return (int)bones.size(); }
	int get_bone_index_for(int i) const;                 // skeleton bone index of physical bone i
	RID get_physical_bone_rid(int i) const;              // for impulse / body_get_state
	PhysicalBone3D *get_physical_bone_node(int i) const; // the PhysicalBone3D itself
	float get_mean_tracking_error() const;               // mean |bone - target| in world metres

	// Rig source (physics_animation/spec.md §5). Set before add_child() to build a custom rig.
	void set_custom_bone_specs(const Array &specs) { custom_bone_specs = specs; }
	Array get_custom_bone_specs() const { return custom_bone_specs; }

	// Base-velocity feed-forward for creatures with no CharacterBody3D parent (set per frame).
	void set_base_velocity(const Vector3 &v) { external_base_velocity = v; }
	Vector3 get_base_velocity() const { return external_base_velocity; }
};

} // namespace godot
