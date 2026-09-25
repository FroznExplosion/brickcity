extends SceneTree
## Slice-1 animation extraction (Docs/12 §8 follow-up).
## Pulls the 4 base-locomotion clips out of their imported Synty FBX scenes and packs
## them into ONE AnimationLibrary saved to res://assets/characters/locomotion_slice1.res.
## All 4 FBX share the same rig hierarchy, so the tracks are valid on any anim-FBX instance.
## Run headless (editor closed):
##   godot --headless --path <proj> --script res://tools/extract_anims.gd

const BASE := "res://ANIMATION_Base_Locomotion_SourceFiles_v3 (1)/SourceFiles/Animations/Polygon/Masculine/"
const NEUT := "res://ANIMATION_Base_Locomotion_SourceFiles_v3 (1)/SourceFiles/Animations/Polygon/Neutral/"
const CLIPS := {
	"idle":        BASE + "Idle/A_Idle_Standing_Masc.fbx",
	"walk":        BASE + "Locomotion/Walk/A_Walk_F_Masc.fbx",
	"run":         BASE + "Locomotion/Run/A_Run_F_Masc.fbx",
	"sprint":      BASE + "Locomotion/Sprint/A_Sprint_F_Masc.fbx",
	# Slice 2: jump/land + crouch-charge
	"crouch_idle": BASE + "Idle/A_Idle_Crouching_Masc.fbx",
	"fall_short":  BASE + "InAir/A_InAir_FallShort_Masc.fbx",
	"fall_large":  BASE + "InAir/A_InAir_FallLarge_Masc.fbx",
	"land_soft":   BASE + "InAir/A_Land_IdleSoft_Masc.fbx",
	"land_medium": BASE + "InAir/A_Land_IdleMedium_Masc.fbx",
	"land_hard":   BASE + "InAir/A_Land_IdleHard_Masc.fbx",
	# Slice 3: 8-way strafes (walk + run rings for the 2D locomotion blendspace)
	"walk_l":  BASE + "Locomotion/Walk/A_Walk_FwdStrafeL_Masc.fbx",
	"walk_r":  BASE + "Locomotion/Walk/A_Walk_FwdStrafeR_Masc.fbx",
	"walk_fl": BASE + "Locomotion/Walk/A_Walk_FwdStrafeFL_Masc.fbx",
	"walk_fr": BASE + "Locomotion/Walk/A_Walk_FwdStrafeFR_Masc.fbx",
	"walk_b":  BASE + "Locomotion/Walk/A_Walk_BckStrafeB_Masc.fbx",
	"walk_bl": BASE + "Locomotion/Walk/A_Walk_BckStrafeBL_Masc.fbx",
	"walk_br": BASE + "Locomotion/Walk/A_Walk_BckStrafeBR_Masc.fbx",
	"run_l":   BASE + "Locomotion/Run/A_Run_FwdStrafeL_Masc.fbx",
	"run_r":   BASE + "Locomotion/Run/A_Run_FwdStrafeR_Masc.fbx",
	"run_fl":  BASE + "Locomotion/Run/A_Run_FwdStrafeFL_Masc.fbx",
	"run_fr":  BASE + "Locomotion/Run/A_Run_FwdStrafeFR_Masc.fbx",
	"run_b":   BASE + "Locomotion/Run/A_Run_BckStrafeB_Masc.fbx",
	"run_bl":  BASE + "Locomotion/Run/A_Run_BckStrafeBL_Masc.fbx",
	"run_br":  BASE + "Locomotion/Run/A_Run_BckStrafeBR_Masc.fbx",
	# Slice 4: moving jumps (one-shots, picked by takeoff speed) + 25° slope cycles
	"jump_idle":   BASE + "InAir/A_Jump_Idle_Masc.fbx",
	"jump_walk":   BASE + "InAir/A_Jump_Walking_Masc.fbx",
	"jump_run":    BASE + "InAir/A_Jump_Running_Masc.fbx",
	"jump_sprint": BASE + "InAir/A_Jump_Sprinting_Masc.fbx",
	"walk_up":     BASE + "Locomotion/Walk/A_Walk_Up25F_Masc.fbx",
	"walk_down":   BASE + "Locomotion/Walk/A_Walk_Down25F_Masc.fbx",
	"run_up":      BASE + "Locomotion/Run/A_Run_Up25F_Masc.fbx",
	"run_down":    BASE + "Locomotion/Run/A_Run_Down25F_Masc.fbx",
	"sprint_up":   BASE + "Locomotion/Sprint/A_Sprint_Up25F_Masc.fbx",
	"sprint_down": BASE + "Locomotion/Sprint/A_Sprint_Down25F_Masc.fbx",
	# Slice 5: start/stop + turn-in-place transitions (all one-shots)
	"start_walk":  BASE + "Transitions/Idle_ToWalk/A_Idle_ToWalkF_Masc.fbx",
	"start_run":   BASE + "Transitions/Idle_ToRun/A_Idle_ToRunF_Masc.fbx",
	"stop_walk_l": BASE + "Transitions/Walk_ToIdle/A_Walk_ToIdleF_LFoot_Masc.fbx",
	"stop_walk_r": BASE + "Transitions/Walk_ToIdle/A_Walk_ToIdleF_RFoot_Masc.fbx",
	"stop_run_l":  BASE + "Transitions/Run_ToIdle/A_Run_ToIdleF_LFoot_Masc.fbx",
	"stop_run_r":  BASE + "Transitions/Run_ToIdle/A_Run_ToIdleF_RFoot_Masc.fbx",
	"turn_90l":    BASE + "Locomotion/Turn/A_Turn_Standing_90L_Masc.fbx",
	"turn_90r":    BASE + "Locomotion/Turn/A_Turn_Standing_90R_Masc.fbx",
	"turn_180l":   BASE + "Locomotion/Turn/A_Turn_Standing_180L_Masc.fbx",
	"turn_180r":   BASE + "Locomotion/Turn/A_Turn_Standing_180R_Masc.fbx",
	# Slice 6: crouch locomotion — 8-way strafe ring + 4-way slow shuffle ring
	"crouch_f":   BASE + "Locomotion/Crouch/A_Crouch_FwdStrafeF_Masc.fbx",
	"crouch_fl":  BASE + "Locomotion/Crouch/A_Crouch_FwdStrafeFL_Masc.fbx",
	"crouch_fr":  BASE + "Locomotion/Crouch/A_Crouch_FwdStrafeFR_Masc.fbx",
	"crouch_l":   BASE + "Locomotion/Crouch/A_Crouch_FwdStrafeL_Masc.fbx",
	"crouch_r":   BASE + "Locomotion/Crouch/A_Crouch_FwdStrafeR_Masc.fbx",
	"crouch_b":   BASE + "Locomotion/Crouch/A_Crouch_BckStrafeB_Masc.fbx",
	"crouch_bl":  BASE + "Locomotion/Crouch/A_Crouch_BckStrafeBL_Masc.fbx",
	"crouch_br":  BASE + "Locomotion/Crouch/A_Crouch_BckStrafeBR_Masc.fbx",
	"cshuffle_f": BASE + "Locomotion/Shuffle/A_Shuffle_Crouching_F_Masc.fbx",
	"cshuffle_b": BASE + "Locomotion/Shuffle/A_Shuffle_Crouching_B_Masc.fbx",
	"cshuffle_l": BASE + "Locomotion/Shuffle/A_Shuffle_Crouching_L_Masc.fbx",
	"cshuffle_r": BASE + "Locomotion/Shuffle/A_Shuffle_Crouching_R_Masc.fbx",
	# Slice 7 (rest of the pack): standing shuffles, crouch<->stand transitions, crouch
	# turns, 90/180 directional starts, Neutral additive lean/look sweeps.
	"shuffle_f": BASE + "Locomotion/Shuffle/A_Shuffle_Standing_F_Masc.fbx",
	"shuffle_b": BASE + "Locomotion/Shuffle/A_Shuffle_Standing_B_Masc.fbx",
	"shuffle_l": BASE + "Locomotion/Shuffle/A_Shuffle_Standing_L_Masc.fbx",
	"shuffle_r": BASE + "Locomotion/Shuffle/A_Shuffle_Standing_R_Masc.fbx",
	"stand_to_crouch":  BASE + "Transitions/Stand_ToCrouch/A_Stand_ToCrouch_Masc.fbx",
	"crouch_to_stand":  BASE + "Transitions/Crouch_ToStand/A_Crouch_ToStand_Masc.fbx",
	"sprint_to_crouch": BASE + "Transitions/Sprint_ToCrouch/A_Sprint_ToCrouch_Masc.fbx",
	"cturn_90l": BASE + "Locomotion/Turn/A_Turn_Crouching_90L_Masc.fbx",
	"cturn_90r": BASE + "Locomotion/Turn/A_Turn_Crouching_90R_Masc.fbx",
	"start_walk_90l":  BASE + "Transitions/Idle_ToWalk/A_Idle_ToWalk90L_Masc.fbx",
	"start_walk_90r":  BASE + "Transitions/Idle_ToWalk/A_Idle_ToWalk90R_Masc.fbx",
	"start_walk_180l": BASE + "Transitions/Idle_ToWalk/A_Idle_ToWalk180L_Masc.fbx",
	"start_walk_180r": BASE + "Transitions/Idle_ToWalk/A_Idle_ToWalk180R_Masc.fbx",
	"start_run_90l":  BASE + "Transitions/Idle_ToRun/A_Idle_ToRun90L_Masc.fbx",
	"start_run_90r":  BASE + "Transitions/Idle_ToRun/A_Idle_ToRun90R_Masc.fbx",
	"start_run_180l": BASE + "Transitions/Idle_ToRun/A_Idle_ToRun180L_Masc.fbx",
	"start_run_180r": BASE + "Transitions/Idle_ToRun/A_Idle_ToRun180R_Masc.fbx",
	"add_lean":     NEUT + "Additive/Lean/A_Lean_Additive_Neut.fbx",
	"add_headlook": NEUT + "Additive/Look/A_HeadLook_Additive_Neut.fbx",
	"add_bodylook": NEUT + "Additive/Look/A_BodyLook_Additive_Neut.fbx",
}
# Land clips are one-shots (played once per landing, restarted by a TimeSeek); the rest cycle.
const NO_LOOP := ["land_soft", "land_medium", "land_hard",
		"jump_idle", "jump_walk", "jump_run", "jump_sprint",
		"start_walk", "start_run", "stop_walk_l", "stop_walk_r", "stop_run_l", "stop_run_r",
		"turn_90l", "turn_90r", "turn_180l", "turn_180r",
		"stand_to_crouch", "crouch_to_stand", "sprint_to_crouch", "cturn_90l", "cturn_90r",
		"start_walk_90l", "start_walk_90r", "start_walk_180l", "start_walk_180r",
		"start_run_90l", "start_run_90r", "start_run_180l", "start_run_180r",
		"add_lean", "add_headlook", "add_bodylook"]
const OUT := "res://assets/characters/locomotion_slice1.res"

# Phase sync: every gait cycle is rotated so the left leg's max forward swing sits at t=0,
# then rescaled to one shared cycle length. Equal length + same start phase + AnimationTree
# sync flags = clips stay in lockstep forever, so blending never mixes opposite foot phases
# (this was the residual start/stop wobble).
const CYCLE_LEN := 0.75


static func _is_cycle(key: String) -> bool:
	if key == "crouch_idle" or key in NO_LOOP:
		return false   # idles / one-shots / additive sweeps are not gait cycles
	return key.begins_with("walk") or key.begins_with("run") or key.begins_with("sprint") \
			or key.begins_with("crouch") or key.begins_with("cshuffle") or key.begins_with("shuffle")


func _initialize() -> void:
	var lib := AnimationLibrary.new()
	for key in CLIPS:
		var ps: PackedScene = load(CLIPS[key])
		if ps == null:
			printerr("MISSING: ", CLIPS[key])
			continue
		var inst: Node = ps.instantiate()
		var ap: AnimationPlayer = _find_ap(inst)
		if ap == null:
			printerr("no AnimationPlayer in ", key)
			inst.free()
			continue
		var names := ap.get_animation_list()
		var anim: Animation = ap.get_animation(names[0])
		anim.loop_mode = Animation.LOOP_NONE if key in NO_LOOP else Animation.LOOP_LINEAR
		if _is_cycle(key):
			_resample_cycle(anim, CYCLE_LEN)
		lib.add_animation(key, anim)
		print("%-7s <- '%s'  tracks=%d  len=%.2fs  first_track='%s'" % [
			key, names[0], anim.get_track_count(), anim.length,
			anim.track_get_path(0) if anim.get_track_count() > 0 else "<none>"])
		inst.free()

	var err := ResourceSaver.save(lib, OUT)
	print("saved '%s' err=%d  anims=%s" % [OUT, err, str(lib.get_animation_list())])
	quit()


## Phase-align + retime a gait cycle by RESAMPLING (not key-shuffling — shifting keys mod
## length corrupted tracks with seam/duplicate/out-of-range keys and made arms snap once per
## cycle). Reads the source at (phase_offset + t) wrapped, bakes uniform keys, so the seam is
## clean by construction. Phase anchor: UpperLeg_L max forward swing → t=0 on every clip.
func _resample_cycle(anim: Animation, target_len: float) -> void:
	if anim.length <= 0.001:
		return
	# 1) find the phase anchor on the ORIGINAL clip
	var ti := anim.find_track("Skeleton3D:UpperLeg_L", Animation.TYPE_ROTATION_3D)
	var offset := 0.0
	if ti >= 0:
		var best := -INF
		var probes := 96
		for i in probes:
			var t: float = anim.length * float(i) / float(probes)
			var q: Quaternion = anim.rotation_track_interpolate(ti, t)
			var swing: float = q.get_euler().x
			if swing > best:
				best = swing
				offset = t
	# 2) rebake every TRS track: uniform samples, source read at wrapped offset time
	var samples := 48
	for tr in anim.get_track_count():
		var type := anim.track_get_type(tr)
		if type != Animation.TYPE_ROTATION_3D and type != Animation.TYPE_POSITION_3D \
				and type != Animation.TYPE_SCALE_3D:
			continue
		var vals := []
		for i in samples + 1:  # +1: end key duplicates the first at target_len = seamless loop
			var phase := float(i % samples) / float(samples)
			var st := fposmod(offset + phase * anim.length, anim.length)
			match type:
				Animation.TYPE_ROTATION_3D:
					vals.append(anim.rotation_track_interpolate(tr, st))
				Animation.TYPE_POSITION_3D:
					vals.append(anim.position_track_interpolate(tr, st))
				Animation.TYPE_SCALE_3D:
					vals.append(anim.scale_track_interpolate(tr, st))
		for k in range(anim.track_get_key_count(tr) - 1, -1, -1):
			anim.track_remove_key(tr, k)
		for i in samples + 1:
			anim.track_insert_key(tr, target_len * float(i) / float(samples), vals[i])
	anim.length = target_len


func _find_ap(n: Node) -> AnimationPlayer:
	if n is AnimationPlayer:
		return n
	for c in n.get_children():
		var r := _find_ap(c)
		if r != null:
			return r
	return null
