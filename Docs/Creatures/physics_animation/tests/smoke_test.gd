extends SceneTree
## Physics Animation — headless smoke test  ·  DRAFT, NOT YET EXECUTED
## =====================================================================
## Reference embodiment of physics_animation/VERIFICATION.md (invariants V1–V10).
## Design artifact: this has NOT been run. Numbers in VERIFICATION.md are targets.
##
## Run (WHEN READY — see VERIFICATION.md §7):
##   scons -C native                                  # build the ActiveRagdoll extension
##   godot --headless --path . --import               # load the extension
##   godot --headless --path . --script res://physics_animation/tests/smoke_test.gd
##   exit 0 = all pass, 1 = a failure
##
## Asset-free: builds a synthetic humanoid Skeleton3D in code (the reference bone names),
## so the physics CORE is testable without shipping a .glb. Uses ActiveRagdoll's measurement
## hooks (get_physical_bone_count / get_mean_tracking_error / …, added 2026-07-17) when present,
## and falls back to PhysicalBoneSimulator3D tree-discovery for older DLLs — see VERIFICATION.md §4.

const FRAMES_SETTLE := 20
const FRAMES_DRIVE := 120

# thresholds (fractions/absolutes from VERIFICATION.md §5)
const PARITY_DEG := 0.5          # V5/V9 pose-copy tolerance
const TRACK_MEAN := 0.03         # V6 mean position error (m)
const TRACK_WORST := 0.10        # V6 worst position error (m)
const SNAP_FRAMES := 3           # V7 frames to reconverge

const RIG_NAMES := [
	"Hips", "Spine_01", "Spine_02", "Spine_03",
	"UpperLeg_L", "LowerLeg_L", "Ankle_L", "UpperLeg_R", "LowerLeg_R", "Ankle_R",
	"Shoulder_L", "Elbow_L", "Hand_L", "Shoulder_R", "Elbow_R", "Hand_R",
]  # 16 = the reference physical rig (VERIFICATION.md V2)

var _fail := 0
var _char: CharacterBody3D
var _ragdoll: Node
var _skel: Skeleton3D          # puppet (visible)
var _target: Skeleton3D        # hidden anim target


func _check(cond: bool, msg: String) -> void:
	if cond:
		print("  PASS  ", msg)
	else:
		_fail += 1
		printerr("  FAIL  ", msg)


func _init() -> void:
	await physics_frame
	print("=== physics animation smoke test (Godot %s) ===" % Engine.get_version_info().string)

	# ---- V1: class present -------------------------------------------------
	if not ClassDB.class_exists("ActiveRagdoll"):
		print("  SKIP  ActiveRagdoll not loaded — build sta_native + import first. (V1)")
		quit(0)
		return
	_check(true, "V1 ActiveRagdoll class loaded")

	# ---- harness (VERIFICATION.md §3) --------------------------------------
	var world := Node3D.new()
	root.add_child(world)
	world.add_child(_static_box(Vector3(0, -0.5, 0), Vector3(50, 1, 50)))  # ground, World layer

	_char = _make_test_character()
	world.add_child(_char)
	_char.global_position = Vector3(0, 1.0, 0)

	_ragdoll = ClassDB.instantiate("ActiveRagdoll")
	_ragdoll.name = "ActiveRagdoll"
	_char.add_child(_ragdoll)   # builds rig + target in _ready

	# isolate the drive: hold a static rest target, no walk, no foot IK (V5–V8)
	_ragdoll.set("use_procedural_walk", false)
	_ragdoll.set("foot_ik_enabled", false)

	await physics_frame
	await physics_frame

	_target = _ragdoll.get_anim_target_skeleton()
	_check(_target != null, "anim target skeleton exists")

	var sim := _find_sim(_skel)
	_check(sim != null, "PhysicalBoneSimulator3D built under puppet skeleton")
	var pbs := _phys_bones(sim)

	# ---- V2/V3: rig + mask -------------------------------------------------
	# Prefer the measurement hook (VERIFICATION.md §4); fall back to tree discovery.
	var bone_count: int = _ragdoll.get_physical_bone_count() \
		if _ragdoll.has_method("get_physical_bone_count") else pbs.size()
	_check(bone_count == RIG_NAMES.size(),
		"V2 physical bone count %d == %d" % [bone_count, RIG_NAMES.size()])
	var mask_ok := true
	for pb in pbs:
		var idx := _skel.find_bone(pb.get("bone_name"))
		if idx < 0: mask_ok = false
	_check(mask_ok, "V3 every physical bone maps to a real skeleton bone")

	for f in FRAMES_SETTLE:
		await physics_frame

	# ---- V5: drive OFF = pose parity ---------------------------------------
	_ragdoll.set_simulating(false)
	await physics_frame
	var worst_parity := _worst_bone_angle_deg(_skel, _target)
	_check(worst_parity < PARITY_DEG,
		"V5 drive-off parity worst %.3f deg < %.2f" % [worst_parity, PARITY_DEG])

	# ---- V6: drive ON = tracking -------------------------------------------
	_ragdoll.set_simulating(true)
	_ragdoll.set("track_position", 1.0)
	_ragdoll.set("track_rotation", 1.0)
	for f in FRAMES_DRIVE:
		await physics_frame
	var stats := _tracking_error(pbs)   # [mean, worst] metres (worst still needs per-bone)
	var mean_err: float = _ragdoll.get_mean_tracking_error() \
		if _ragdoll.has_method("get_mean_tracking_error") else stats[0]
	_check(mean_err < TRACK_MEAN, "V6 tracking mean %.4f m < %.3f" % [mean_err, TRACK_MEAN])
	_check(stats[1] < TRACK_WORST, "V6 tracking worst %.4f m < %.3f" % [stats[1], TRACK_WORST])

	# ---- V7: snap guard (teleport → reconverge, never NaN) -----------------
	_char.global_position += Vector3(25, 0, 0)   # >> snap_distance in one frame
	var reconverged := -1
	for f in SNAP_FRAMES + 2:
		await physics_frame
		if not _all_finite(pbs):
			break
		if _tracking_error(pbs)[1] < TRACK_WORST and reconverged < 0:
			reconverged = f
	_check(_all_finite(pbs), "V7 no NaN/blow-up after teleport")
	_check(reconverged >= 0 and reconverged < SNAP_FRAMES,
		"V7 reconverged in %d frames (< %d)" % [reconverged, SNAP_FRAMES])

	# ---- V8: hit → spike → recover -----------------------------------------
	var hand := _find_bone_node(pbs, "Hand_R")
	if hand != null:
		var err_before: float = _tracking_error(pbs)[1]
		# game-side reaction (spec §9): impulse + brief authority drop
		PhysicsServer3D.body_apply_impulse(hand.get_rid(), Vector3(0, 0, 6.0))
		_ragdoll.set("track_rotation", 0.15)
		await physics_frame
		await physics_frame
		var err_spike: float = _tracking_error(pbs)[1]
		_ragdoll.set("track_rotation", 1.0)             # authority ramps back
		for f in 40: await physics_frame
		var err_after: float = _tracking_error(pbs)[1]
		_check(err_spike > err_before + 0.05, "V8 hit produced a stumble (spike %.3f m)" % err_spike)
		_check(err_after < TRACK_WORST, "V8 recovered to %.4f m" % err_after)
	else:
		print("  SKIP  V8 — Hand_R physical bone not found")

	# ---- V9: unsimulated bone follows target while simulating --------------
	# Head has no physical body → must copy the target pose (spec §3).
	var hi := _skel.find_bone("Head")
	var ht := _target.find_bone("Head")
	if hi >= 0 and ht >= 0:
		var d := rad_to_deg(_skel.get_bone_pose_rotation(hi).angle_to(_target.get_bone_pose_rotation(ht)))
		_check(d < PARITY_DEG, "V9 unsimulated Head follows target (%.3f deg)" % d)
	else:
		print("  SKIP  V9 — no Head bone in synthetic rig")

	# ---- V10: start/stop clean ---------------------------------------------
	_ragdoll.set_simulating(false)
	await physics_frame
	_check(_ragdoll.get_simulating() == false, "V10 stopped")
	_ragdoll.set_simulating(true)
	await physics_frame
	_check(_ragdoll.get_simulating() == true, "V10 restarted")
	_check(_phys_bones(_find_sim(_skel)).size() == RIG_NAMES.size(),
		"V10 no bodies leaked on stop/start")

	print("\n=== %s — %d failure(s) ===" % ["OK" if _fail == 0 else "FAILED", _fail])
	quit(1 if _fail > 0 else 0)


# ── harness helpers ──────────────────────────────────────────────────────────

func _make_test_character() -> CharacterBody3D:
	var body := CharacterBody3D.new()
	body.name = "TestChar"
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.3; cap.height = 1.6
	cs.shape = cap
	body.add_child(cs)
	var mesh_root := Node3D.new()
	mesh_root.name = "CharacterMesh"      # ActiveRagdoll duplicates this for the Target
	body.add_child(mesh_root)
	_skel = _make_humanoid_skeleton()
	mesh_root.add_child(_skel)
	return body


## Minimal humanoid: the reference bone names in a plausible hierarchy. Rests are simplified
## (identity basis, real positions) — enough for V1–V10 with foot-IK/walk disabled. A full
## +Y-along-bone rig is only needed once foot IK / procedural walk are under test.
func _make_humanoid_skeleton() -> Skeleton3D:
	var s := Skeleton3D.new()
	s.name = "Skeleton3D"
	var g: Array[Transform3D] = []
	var add := func(bname: String, parent: int, pos: Vector3) -> int:
		var idx := s.get_bone_count()
		s.add_bone(bname)
		var gx := Transform3D(Basis(), pos)
		if parent >= 0:
			s.set_bone_parent(idx, parent)
			s.set_bone_rest(idx, g[parent].affine_inverse() * gx)
		else:
			s.set_bone_rest(idx, gx)
		g.append(gx)
		return idx
	var root := add.call("Root", -1, Vector3(0, 0, 0))
	var hips := add.call("Hips", root, Vector3(0, 0.95, 0))
	var sp1 := add.call("Spine_01", hips, Vector3(0, 1.05, 0))
	var sp2 := add.call("Spine_02", sp1, Vector3(0, 1.20, 0))
	var sp3 := add.call("Spine_03", sp2, Vector3(0, 1.35, 0))
	var neck := add.call("Neck", sp3, Vector3(0, 1.50, 0))
	add.call("Head", neck, Vector3(0, 1.62, 0))
	for side in [["_L", -1.0], ["_R", 1.0]]:
		var sfx: String = side[0]
		var x: float = 0.18 * float(side[1])
		var sh := add.call("Shoulder" + sfx, sp3, Vector3(x, 1.45, 0))
		var el := add.call("Elbow" + sfx, sh, Vector3(x + 0.25 * side[1], 1.30, 0))
		add.call("Hand" + sfx, el, Vector3(x + 0.5 * side[1], 1.15, 0))
		var ul := add.call("UpperLeg" + sfx, hips, Vector3(x * 0.6, 0.90, 0))
		var ll := add.call("LowerLeg" + sfx, ul, Vector3(x * 0.6, 0.50, 0))
		add.call("Ankle" + sfx, ll, Vector3(x * 0.6, 0.10, 0))
	s.reset_bone_poses()
	return s


func _find_sim(skel: Skeleton3D) -> Node:
	if skel == null: return null
	var found := skel.find_children("*", "PhysicalBoneSimulator3D", true, false)
	return found[0] if not found.is_empty() else null


func _phys_bones(sim: Node) -> Array:
	if sim == null: return []
	var out := []
	for n in sim.find_children("*", "PhysicalBone3D", true, false):
		out.append(n)
	return out


func _find_bone_node(pbs: Array, bname: String):
	for pb in pbs:
		if String(pb.get("bone_name")) == bname:
			return pb
	return null


## Worst per-bone rotation delta (deg) between two identical-rig skeletons.
func _worst_bone_angle_deg(a: Skeleton3D, b: Skeleton3D) -> float:
	var n: int = min(a.get_bone_count(), b.get_bone_count())
	var worst := 0.0
	for i in n:
		var d := rad_to_deg(a.get_bone_pose_rotation(i).angle_to(b.get_bone_pose_rotation(i)))
		worst = max(worst, d)
	return worst


## [mean, worst] world-space position error of each physical bone vs its target global pose.
func _tracking_error(pbs: Array) -> Array:
	var txf := _target.get_global_transform()
	var mean := 0.0
	var worst := 0.0
	var cnt := 0
	for pb in pbs:
		var idx := _target.find_bone(pb.get("bone_name"))
		if idx < 0: continue
		var tgt: Vector3 = (txf * _target.get_bone_global_pose(idx)).origin
		var err: float = pb.global_transform.origin.distance_to(tgt)
		mean += err; worst = max(worst, err); cnt += 1
	if cnt > 0: mean /= cnt
	return [mean, worst]


func _all_finite(pbs: Array) -> bool:
	for pb in pbs:
		var o: Vector3 = pb.global_transform.origin
		if not (is_finite(o.x) and is_finite(o.y) and is_finite(o.z)):
			return false
	return true


func _static_box(pos: Vector3, size: Vector3) -> StaticBody3D:
	var b := StaticBody3D.new()
	b.position = pos
	b.collision_layer = 1   # World — ragdoll bones mask this
	var cs := CollisionShape3D.new()
	var bx := BoxShape3D.new()
	bx.size = size
	cs.shape = bx
	b.add_child(cs)
	return b
