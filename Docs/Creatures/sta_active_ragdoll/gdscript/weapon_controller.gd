# weapon_controller.gd
# Weapon handling for the radial-gravity player (Doc 12 combat layer, Reference §8).
#
# EDITOR-AUTHORED RIG: the gun mesh + grip markers live in WeaponController.tscn as real nodes
# (WeaponRoot/Mesh/GripR/GripL/Sight/MuzzleFlash) so you tune them by DRAGGING in the editor — no
# runtime rebuild. This script only DRIVES those nodes. Open WeaponController.tscn to move the gun
# (pull the Synty mesh back), place the grip points, etc.; changes persist.
#
# Two mounting models (`aim_mounted`):
#  AIM-MOUNTED (default) = gun-authority: WeaponRoot is placed each frame from the EYE/aim so the
#  gun points where you look (straight, stable — not flapping with the arm swing). BOTH hands IK
#  onto the GripR/GripL markers → hands follow the gun. ADS slides the gun so its Sight marker
#  lands on the aim axis (model-independent auto-sight). Immune to ragdoll arm flail.
#  HAND-MOUNTED (fallback) = bolt the gun to Hand_R (rides the loco clip / ragdoll physics layer);
#  only the left hand IKs. Gun points wherever the hand is.
#
# A spring handling layer rides on top (sway/bob/look-lag/tilt/landing/breathing/recoil, ported
# from reddawn). Camera recoil = separate RecoilHolder. 2-bone IK ported from ActiveRagdoll.
class_name WeaponController
extends Node3D

signal fired(from: Vector3, to: Vector3, hit: Dictionary)

# Grip-marker positions, the gun mesh transform, and the muzzle point are AUTHORED IN THE SCENE
# (WeaponController.tscn) — drag them in the editor. The knobs below are behaviour, not geometry.

# --- mounting -----------------------------------------------------------------------------
@export_group("Mounting")
@export var aim_mounted: bool = true

# --- aim mount placement ------------------------------------------------------------------
@export_group("Aim Mount")
## Anchor the hip pose to the mesh SHOULDERS (lag with the body — softer, sits lower) vs the EYE
## (rigid FPS-viewmodel feel, locked to the camera; the reach clamp keeps hands on). Eye = rigid.
@export var anchor_to_body: bool = false
@export var hip_offset: Vector3 = Vector3(0.15, -0.27, -0.35)  # aim-space vs anchor: right, down, fwd
@export var ads_sight_distance: float = 0.25                   # how far ahead of the eye sights sit
@export var mount_speed: float = 50.0                          # follow rate (high = rigid, locked to view)
@export var reach_margin: float = 0.06                         # keep the gun this far inside arm reach
@export var max_pushback: float = 0.12                         # max the gun may retreat from the in-view spot

# --- hand mount seating (fallback only) ---------------------------------------------------
@export_group("Hand Mount")
@export var grip_position: Vector3 = Vector3(0.02, 0.0, -0.03)
@export var grip_rotation_deg: Vector3 = Vector3.ZERO
@export var hand_ads_position: Vector3 = Vector3(0.0, -0.03, 0.06)
@export var hand_ads_rotation_deg: Vector3 = Vector3.ZERO

# --- aim-down-sights (shared) -------------------------------------------------------------
@export_group("ADS")
@export var ads_fov: float = 50.0
@export var ads_speed: float = 12.0

# --- velocity sway -------------------------------------------------------------------------
@export_group("Velocity Sway")
@export var sway_stiffness: float = 14.0
@export var sway_damping: float = 6.0
@export var sway_strength: float = 0.005
@export var ads_sway_mult: float = 0.2

# --- look sway ----------------------------------------------------------------------------
@export_group("Look Sway")
@export var look_sway_enabled: bool = true
@export var look_sway_stiffness: float = 12.0
@export var look_sway_damping: float = 7.0
@export var look_sway_pitch_strength: float = 0.0008
@export var look_sway_roll_strength: float = 0.0016
@export var ads_look_sway_mult: float = 0.2

# --- movement tilt ------------------------------------------------------------------------
@export_group("Movement Tilt")
@export var move_tilt_enabled: bool = true
@export var move_tilt_roll: float = 0.06
@export var move_tilt_pitch: float = 0.03
@export var move_tilt_speed_ref: float = 6.0
@export var ads_move_tilt_mult: float = 0.3

# --- walk bob -----------------------------------------------------------------------------
@export_group("Walk Bob")
@export var bob_enabled: bool = true
@export var bob_frequency: float = 2.4
@export var bob_amplitude: float = 0.014
@export var ads_bob_mult: float = 0.25

# --- landing impact -----------------------------------------------------------------------
@export_group("Landing")
@export var land_stiffness: float = 16.0
@export var land_damping: float = 6.0
@export var land_strength: float = 0.14

# --- idle breathing -----------------------------------------------------------------------
@export_group("Breathing")
@export var breathe_enabled: bool = true
@export var breathe_frequency: float = 0.28
@export var breathe_amplitude: float = 0.006
@export var ads_breathe_mult: float = 0.35

# --- recoil -------------------------------------------------------------------------------
@export_group("Recoil")
@export var recoil_kick: float = 0.05
@export var recoil_rise_deg: float = 2.0
@export var recoil_yaw_deg: float = 1.0
@export var recoil_return: float = 14.0
@export var cam_recoil_pitch_deg: float = 0.8
@export var cam_recoil_yaw_deg: float = 0.4

# --- firing -------------------------------------------------------------------------------
@export_group("Firing")
@export var fire_rate: float = 10.0
@export var full_auto: bool = true
@export var range_m: float = 500.0
@export var hit_mask: int = 1

# --- holster ------------------------------------------------------------------------------
@export_group("Holster")
@export var holster_position: Vector3 = Vector3(0.0, -0.08, 0.0)
@export var holster_rotation_deg: Vector3 = Vector3(60.0, 0.0, 0.0)
@export var holster_speed: float = 10.0

# --- upper-body aim (spine tracks the look; decouples the upper body from loco) -----------
@export_group("Upper Body Aim")
## Override the spine each frame so the chest faces the aim (pitch) and catches up to the body
## yaw (removes mesh lag) — so running/falling stops throwing the hands off the gun and the
## shoulders reach the weapon. This is the upper/lower-body split. Turn off to let loco drive it.
@export var spine_aim_enabled: bool = true
@export var spine_pitch_weight: float = 0.6   # how much the spine bends with look pitch (0..1; negative flips)
@export var spine_yaw_weight: float = 0.7     # how much the spine removes mesh yaw-lag (0..1)
@export var spine_pitch_max_deg: float = 45.0

# --- grip IK ------------------------------------------------------------------------------
@export_group("Grip IK")
@export var grip_ik_enabled: bool = true
@export var align_wrist_to_grip: bool = false
@export var wrist_rotation_deg: Vector3 = Vector3.ZERO
@export var hand_follow_speed: float = 18.0   # how fast a hand slides to a new target (magnetize)

# --- ledge hang pose ----------------------------------------------------------------------
@export_group("Ledge Hang")
@export var ledge_hand_min_sep: float = 0.32   # hands never closer than this on the lip
@export var ledge_hand_max_sep: float = 0.70   # nor farther apart than this
@export var ledge_leg_ik: bool = true          # plant bent legs / feet against the wall
@export var ledge_foot_drop: float = 0.95      # feet this far below the hips
@export var ledge_foot_wall: float = 0.12      # press feet toward the wall from the body
@export var ledge_foot_spread: float = 0.17    # feet apart along the edge

var _player: CharacterBody3D = null
var _camera: Camera3D = null
var _movement: Node = null
var _recoil_holder: Node = null
var _eye: Node3D = null            # CameraPivot — stable aim anchor (FPS & TPS)

var _skel: Skeleton3D = null
var _attach: BoneAttachment3D = null   # hand-mount only
# Authored scene nodes (found in setup).
var _gun: Node3D = null                # WeaponRoot
var _mesh: Node3D = null
var _grip_r: Node3D = null
var _grip_l: Node3D = null
var _sight: Node3D = null
var _muzzle_flash: OmniLight3D = null
# arm chains
var _idx_sh_l := -1
var _idx_el_l := -1
var _idx_ha_l := -1
var _idx_sh_r := -1
var _idx_el_r := -1
var _idx_ha_r := -1
# legs (ledge hang pose)
var _idx_ul_l := -1
var _idx_ll_l := -1
var _idx_an_l := -1
var _idx_ul_r := -1
var _idx_ll_r := -1
var _idx_an_r := -1
var _idx_hips := -1
var _arm_reach := 0.0   # shoulder->elbow->hand length (reach clamp / anchor)
var _spine_idx: Array[int] = []   # Spine_01..03 for the upper-body aim override

# --- per-hand IK targets (PlayerHands API) -----------------------------------------------
# Priority per hand: LEDGE (both) > INTERACT override (one/both) > GUN grip (default).
# Targets are smoothed toward (magnetize), so grabs ease on instead of snapping.
enum Hand { LEFT, RIGHT }
var ledge_active: bool = false            # set by PlayerMovement during a ledge hang
var _ledge_l := Vector3.ZERO
var _ledge_r := Vector3.ZERO
var _ovr_l_active := false
var _ovr_l_pos := Vector3.ZERO
var _ovr_r_active := false
var _ovr_r_pos := Vector3.ZERO
var _hpos_l := Vector3.ZERO                # smoothed IK target (left)
var _hpos_r := Vector3.ZERO
var _hinit_l := false
var _hinit_r := false

## Called by PlayerMovement each frame during a ledge hang — world points on the lip.
func set_ledge_hands(l: Vector3, r: Vector3) -> void:
	_ledge_l = l
	_ledge_r = r

## Interaction override — send one hand to a world point (e.g. a switch), keep the other on the
## gun. weight kept for future partial blends; currently full when active.
func set_hand_target(hand: int, pos: Vector3, _weight: float = 1.0) -> void:
	if hand == Hand.LEFT:
		_ovr_l_active = true; _ovr_l_pos = pos
	else:
		_ovr_r_active = true; _ovr_r_pos = pos

func clear_hand_target(hand: int) -> void:
	if hand == Hand.LEFT:
		_ovr_l_active = false
	else:
		_ovr_r_active = false

## True when both hands are off the gun (ledge) — the gun auto-lowers.
func _hands_busy() -> bool:
	return ledge_active

# handling springs
var _sway_pos := Vector3.ZERO
var _sway_vel := Vector3.ZERO
var _land_pos := Vector3.ZERO
var _land_vel := Vector3.ZERO
var _look_rot := Vector3.ZERO
var _look_rot_vel := Vector3.ZERO
var _mouse_delta := Vector2.ZERO
var _bob_time := 0.0
var _breathe_time := 0.0
var _was_on_floor := true
var _recoil_pos := Vector3.ZERO
var _recoil_rot := Vector3.ZERO
# aim-mount smoothed transform
var _mount_ready := false
var _mount_origin := Vector3.ZERO
var _mount_basis := Basis.IDENTITY
# states
var _ads := 0.0
var _holstered_w := 0.0
var _holstered := false
var _cooldown := 0.0
var _base_fov := 75.0
var _active := false

## Wired by PlayerController after the body/ragdoll/recoil-holder exist. Finds the authored rig
## nodes (this scene's children) and hooks the skeleton — does NOT build geometry.
func setup(player: CharacterBody3D, camera: Camera3D, movement: Node, character_mesh: Node3D, recoil_holder: Node = null) -> void:
	_player = player
	_camera = camera
	_movement = movement
	_recoil_holder = recoil_holder
	if camera != null:
		_base_fov = camera.fov
		_eye = camera.get_parent()   # CameraPivot

	_gun = get_node_or_null("WeaponRoot")
	if _gun == null:
		push_warning("[weapon] WeaponRoot missing from WeaponController.tscn")
		return
	_mesh = _gun.get_node_or_null("Mesh")
	_grip_r = _gun.get_node_or_null("GripR")
	_grip_l = _gun.get_node_or_null("GripL")
	_sight = _gun.get_node_or_null("Sight")
	_muzzle_flash = _gun.get_node_or_null("MuzzleFlash")

	var found := character_mesh.find_children("*", "Skeleton3D", true, false)
	if found.is_empty():
		push_warning("[weapon] no Skeleton3D under CharacterMesh — IK disabled")
	else:
		_skel = found[0]
		_idx_sh_l = _skel.find_bone("Shoulder_L"); _idx_el_l = _skel.find_bone("Elbow_L"); _idx_ha_l = _skel.find_bone("Hand_L")
		_idx_sh_r = _skel.find_bone("Shoulder_R"); _idx_el_r = _skel.find_bone("Elbow_R"); _idx_ha_r = _skel.find_bone("Hand_R")
		if _idx_sh_r >= 0 and _idx_el_r >= 0 and _idx_ha_r >= 0:
			var sp := _skel.get_bone_global_pose(_idx_sh_r).origin
			var ep := _skel.get_bone_global_pose(_idx_el_r).origin
			var hp := _skel.get_bone_global_pose(_idx_ha_r).origin
			_arm_reach = sp.distance_to(ep) + ep.distance_to(hp)
		for nm in ["Spine_01", "Spine_02", "Spine_03"]:
			var bi := _skel.find_bone(nm)
			if bi >= 0:
				_spine_idx.append(bi)
		_idx_ul_l = _skel.find_bone("UpperLeg_L"); _idx_ll_l = _skel.find_bone("LowerLeg_L"); _idx_an_l = _skel.find_bone("Ankle_L")
		_idx_ul_r = _skel.find_bone("UpperLeg_R"); _idx_ll_r = _skel.find_bone("LowerLeg_R"); _idx_an_r = _skel.find_bone("Ankle_R")
		_idx_hips = _skel.find_bone("Hips")

	if not aim_mounted:
		# Bolt the WeaponRoot to Hand_R (rides the animation/physics layer). Left hand IKs only.
		if _skel == null:
			return
		var hand := _skel.find_bone("Hand_R")
		if hand < 0:
			push_warning("[weapon] Hand_R not found — gun not attached")
			return
		_attach = BoneAttachment3D.new()
		_attach.name = "WeaponAttach_HandR"
		_skel.add_child(_attach)
		_attach.bone_name = "Hand_R"
		_gun.reparent(_attach, false)
		_apply_grip()

	_active = true

func _apply_grip() -> void:
	if _gun == null:
		return
	_gun.transform = Transform3D(Basis.from_euler(_deg(grip_rotation_deg)), grip_position)

func _unhandled_input(event: InputEvent) -> void:
	if not _active:
		return
	if event is InputEventMouseMotion:
		_mouse_delta += (event as InputEventMouseMotion).relative
	elif event.is_action_pressed("reload"):
		_start_reload()
	elif event.is_action_pressed("holster"):
		_holstered = not _holstered

func _process(delta: float) -> void:
	if not _active:
		return
	_cooldown = maxf(_cooldown - delta, 0.0)
	if not _holstered and not _hands_busy() and not _in_build_mode():
		var want_fire := Input.is_action_pressed("fire") if full_auto else Input.is_action_just_pressed("fire")
		if want_fire and _cooldown <= 0.0:
			_fire()
			_cooldown = 1.0 / maxf(fire_rate, 0.1)
	_update_handling(delta)

func _in_build_mode() -> bool:
	var bs := _player.get_node_or_null("BuildSystem") if _player != null else null
	return bs != null and bs.get("_active") == true

# --- handling layer (springs, shared) ----------------------------------------------------
func _update_handling(delta: float) -> void:
	var busy := _hands_busy()
	var ads_target := 1.0 if (Input.is_action_pressed("aim") and not _holstered and not busy and not _in_build_mode()) else 0.0
	_ads = lerpf(_ads, ads_target, minf(delta * ads_speed, 1.0))
	# Gun lowers while both hands are busy (ledge) as well as when holstered.
	_holstered_w = lerpf(_holstered_w, 1.0 if (_holstered or busy) else 0.0, minf(delta * holster_speed, 1.0))

	var speed := 0.0
	var on_floor := true
	var local_vel := Vector3.ZERO
	if _player != null:
		var v := _player.get_real_velocity()
		var body := _player.global_transform.basis
		var up := body.y
		var tvel := v - up * v.dot(up)
		speed = tvel.length()
		on_floor = _player.is_on_floor()
		local_vel = body.inverse() * tvel

	if on_floor and not _was_on_floor:
		_land_vel.y -= land_strength
	_was_on_floor = on_floor
	var land_force := (Vector3.ZERO - _land_pos) * land_stiffness - _land_vel * land_damping
	_land_vel += land_force * delta
	_land_pos += _land_vel * delta

	var sway_mult := lerpf(1.0, ads_sway_mult, _ads)
	var sway_target := Vector3(-local_vel.x * sway_strength * sway_mult, 0.0, -local_vel.z * sway_strength * sway_mult * 0.5)
	var sway_force := (sway_target - _sway_pos) * sway_stiffness - _sway_vel * sway_damping
	_sway_vel += sway_force * delta
	_sway_pos += _sway_vel * delta

	var bob := Vector3.ZERO
	if bob_enabled:
		if on_floor and speed > 0.5:
			_bob_time += delta * bob_frequency * speed * 0.5
		var bob_mult := lerpf(1.0, ads_bob_mult, _ads) * clampf(speed / 1.5, 0.0, 1.0)
		bob = Vector3(cos(_bob_time * 2.0) * bob_amplitude, absf(sin(_bob_time)) * bob_amplitude, 0.0) * bob_mult

	var breathe := Vector3.ZERO
	if breathe_enabled:
		_breathe_time += delta * breathe_frequency
		var breathe_mult := lerpf(1.0, ads_breathe_mult, _ads)
		breathe = Vector3(sin(_breathe_time * 0.7) * breathe_amplitude * breathe_mult, sin(_breathe_time) * breathe_amplitude * breathe_mult, 0.0)

	_recoil_pos = _recoil_pos.lerp(Vector3.ZERO, minf(delta * recoil_return, 1.0))
	_recoil_rot = _recoil_rot.lerp(Vector3.ZERO, minf(delta * recoil_return, 1.0))

	if look_sway_enabled:
		var look_mult := lerpf(1.0, ads_look_sway_mult, _ads)
		_look_rot_vel.x += _mouse_delta.y * look_sway_pitch_strength * look_mult
		_look_rot_vel.z -= _mouse_delta.x * look_sway_roll_strength * look_mult
		var look_force := (-_look_rot) * look_sway_stiffness - _look_rot_vel * look_sway_damping
		_look_rot_vel += look_force * delta
		_look_rot += _look_rot_vel * delta
	_mouse_delta = Vector2.ZERO

	var tilt := Vector3.ZERO
	if move_tilt_enabled:
		var tilt_mult := lerpf(1.0, ads_move_tilt_mult, _ads)
		var ref := maxf(move_tilt_speed_ref, 0.1)
		tilt = Vector3(-(local_vel.z / ref) * move_tilt_pitch * tilt_mult, 0.0, (local_vel.x / ref) * move_tilt_roll * tilt_mult)

	var spring_pos := _sway_pos + _land_pos + bob + breathe + _recoil_pos
	var spring_rot := _look_rot + tilt + _recoil_rot

	if aim_mounted:
		_drive_aim_mounted(delta, spring_pos, spring_rot)
	else:
		_drive_hand_mounted(spring_pos, spring_rot)

	if _camera != null:
		_camera.fov = lerpf(_base_fov, ads_fov, _ads)

	# Upper-body aim (spine faces the look) BEFORE arm IK so the shoulders reach the gun, then IK
	# the hands onto their targets (gun grips / ledge / interaction). Run whenever a hand is
	# engaged — including a ledge grab, where the gun is lowered but the hands are on the lip.
	var hands_engaged := ledge_active or _ovr_l_active or _ovr_r_active or _holstered_w < 0.5
	if _skel != null and hands_engaged:
		# Spine tracks the look while aiming; not during a ledge hang (body hangs, doesn't aim).
		if spine_aim_enabled and not ledge_active:
			_aim_spine()
		if grip_ik_enabled:
			_solve_grips(delta)

func _drive_hand_mounted(spring_pos: Vector3, spring_rot: Vector3) -> void:
	if _gun == null:
		return
	var pos := (grip_position + spring_pos).lerp(hand_ads_position, _ads)
	pos = pos.lerp(holster_position, _holstered_w)
	var rot := (_deg(grip_rotation_deg) + spring_rot).lerp(_deg(hand_ads_rotation_deg), _ads)
	rot = rot.lerp(_deg(holster_rotation_deg), _holstered_w)
	_gun.transform = Transform3D(Basis.from_euler(rot), pos)

## AIM-MOUNTED: place WeaponRoot from the eye/aim so it lines up with the FPS camera. Hip = an
## offset in aim-space; ADS = slide the gun so its Sight marker lands on the aim axis.
func _drive_aim_mounted(delta: float, spring_pos: Vector3, spring_rot: Vector3) -> void:
	if _gun == null or _eye == null:
		return
	var eye_xf := _eye.global_transform
	# Orthonormalize: the pivot's basis can carry scale/float drift, and slerp/Quaternion casts
	# below require a strict rotation basis (else "must be normalized" errors).
	var aim := eye_xf.basis.orthonormalized()
	var anchor := eye_xf.origin
	var sight_local: Vector3 = _sight.position if _sight != null else Vector3.ZERO

	# Mesh shoulders midpoint (lags with the body during fast turns) — the reach origin, and the
	# hip anchor when anchor_to_body (keeps the gun reachable + sits it lower). Falls back to eye.
	var shoulders := anchor
	if _skel != null and _idx_sh_l >= 0 and _idx_sh_r >= 0:
		var sx := _skel.global_transform
		var sl := sx * _skel.get_bone_global_pose(_idx_sh_l).origin
		var sr := sx * _skel.get_bone_global_pose(_idx_sh_r).origin
		shoulders = (sl + sr) * 0.5
	var chest := shoulders if anchor_to_body else anchor

	var gun_basis := aim * Basis.from_euler(spring_rot)
	gun_basis = (gun_basis * Basis.from_euler(_deg(holster_rotation_deg) * _holstered_w)).orthonormalized()

	var hip_o := chest + aim * (hip_offset + spring_pos)
	var sight_target := anchor + (-aim.z) * ads_sight_distance
	var ads_o := sight_target - gun_basis * sight_local + aim * spring_pos
	var origin := hip_o.lerp(ads_o, _ads)
	origin += aim * (holster_position * _holstered_w)

	# Reach vs view: if the gun is beyond arm reach, pull it back toward the shoulders — but only
	# up to max_pushback, so it never leaves the camera view by more than that (crosshair/hitscan
	# stay camera-based). With the spine aim tracking the camera, this rarely triggers.
	if _arm_reach > 0.0:
		var lim := maxf(_arm_reach - reach_margin, 0.1)
		var d := origin - shoulders
		if d.length() > lim:
			var reachable := shoulders + d.normalized() * lim
			var pushback := reachable - origin
			if pushback.length() > max_pushback:
				reachable = origin + pushback.normalized() * max_pushback
			origin = reachable

	if not _mount_ready:
		_mount_origin = origin
		_mount_basis = gun_basis
		_mount_ready = true
	else:
		var t := minf(delta * mount_speed, 1.0)
		_mount_origin = _mount_origin.lerp(origin, t)
		_mount_basis = _mount_basis.slerp(gun_basis, t).orthonormalized()
	_gun.global_transform = Transform3D(_mount_basis, _mount_origin)

func _deg(v: Vector3) -> Vector3:
	return Vector3(deg_to_rad(v.x), deg_to_rad(v.y), deg_to_rad(v.z))

# --- firing ------------------------------------------------------------------------------
func _fire() -> void:
	_recoil_pos += Vector3(0.0, 0.0, recoil_kick)
	_recoil_rot += Vector3(deg_to_rad(recoil_rise_deg), deg_to_rad(randf_range(-recoil_yaw_deg, recoil_yaw_deg)), 0.0)
	if _recoil_holder != null and _recoil_holder.has_method("add_recoil"):
		_recoil_holder.add_recoil(Vector3(deg_to_rad(cam_recoil_pitch_deg), deg_to_rad(cam_recoil_yaw_deg), 0.0))

	if _muzzle_flash != null:
		_muzzle_flash.light_energy = 4.0
		var t := get_tree().create_timer(0.04)
		t.timeout.connect(func(): if is_instance_valid(_muzzle_flash): _muzzle_flash.light_energy = 0.0)

	if _camera == null:
		return
	var from := _camera.global_position
	var dir := -_camera.global_transform.basis.z
	var to := from + dir * range_m
	var space := _player.get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(from, to, hit_mask)
	q.exclude = [_player.get_rid()]
	var hit := space.intersect_ray(q)
	if not hit.is_empty():
		to = hit["position"]
	fired.emit(from, to, hit)

func _start_reload() -> void:
	_recoil_rot += Vector3(deg_to_rad(-8.0), 0.0, 0.0)   # placeholder dip until an authored reload

# --- upper-body aim ----------------------------------------------------------------------
# Rotate the spine chain (post-physics) so the chest faces the aim: bend by look pitch + remove
# the mesh yaw-lag (shoulders behind the instantly-yawed body). Axis-agnostic — rotates each
# spine bone's world basis around the body up/right axes, so it needs no per-rig bone-axis info.
# This is the upper/lower-body split: the spine stops following the loco/ragdoll (which was
# throwing the hands off the gun) and tracks the weapon instead. Legs still follow loco.
func _aim_spine() -> void:
	if _spine_idx.is_empty() or _skel == null or _player == null:
		return
	var n := _spine_idx.size()
	var body := _player.global_transform.basis
	var up := body.y
	var right := body.x
	var skb := _skel.global_transform.basis

	# Yaw lag: signed angle from the shoulder line to the body's right axis (both on the tangent
	# plane). Positive = shoulders lag behind the body yaw; rotate the spine to close it.
	var per_yaw := 0.0
	if spine_yaw_weight != 0.0 and _idx_sh_l >= 0 and _idx_sh_r >= 0:
		var sx := _skel.global_transform
		var sl := sx * _skel.get_bone_global_pose(_idx_sh_l).origin
		var sr := sx * _skel.get_bone_global_pose(_idx_sh_r).origin
		var sdir := sr - sl
		sdir -= up * sdir.dot(up)
		var bx := right - up * right.dot(up)
		if sdir.length() > 1e-3 and bx.length() > 1e-3:
			sdir = sdir.normalized()
			bx = bx.normalized()
			var yaw_lag := atan2(sdir.cross(bx).dot(up), sdir.dot(bx))
			per_yaw = clampf(yaw_lag, -1.2, 1.2) * spine_yaw_weight / n

	# Pitch: bend the spine with the look pitch so the chest (and gun) can face up/down.
	var pitch := 0.0
	var p = _movement.get("_pitch") if _movement != null else null
	if p != null:
		pitch = p
	var pmax := deg_to_rad(spine_pitch_max_deg)
	var per_pitch := clampf(pitch, -pmax, pmax) * spine_pitch_weight / n

	for b in _spine_idx:
		var wb := skb * _skel.get_bone_global_pose(b).basis
		wb = Basis(up, per_yaw) * Basis(right, per_pitch) * wb
		_set_bone_world_rot(b, wb.orthonormalized())

# --- grip IK -----------------------------------------------------------------------------
func _solve_grips(delta: float) -> void:
	var pb := _player.global_transform.basis
	var up := pb.y
	var fwd := -pb.z
	var right := pb.x
	var t := minf(delta * hand_follow_speed, 1.0)

	# Resolve each hand's target by priority: ledge (both) > interaction override > gun grip.
	var have_l := _idx_sh_l >= 0 and _idx_el_l >= 0 and _idx_ha_l >= 0
	var have_r := _idx_sh_r >= 0 and _idx_el_r >= 0 and _idx_ha_r >= 0
	var want_l := _grip_l.global_position if _grip_l != null else Vector3.ZERO
	var use_l := have_l and _grip_l != null
	# Right hand only holds the gun via IK in aim-mount (hand-mount uses the bone attachment).
	var want_r := _grip_r.global_position if _grip_r != null else Vector3.ZERO
	var use_r := have_r and _grip_r != null and aim_mounted

	if ledge_active:
		var pts := _ledge_separated(up)   # enforce min/max hand spacing on the lip
		want_l = pts[0]; use_l = have_l
		want_r = pts[1]; use_r = have_r
		if ledge_leg_ik:
			_pose_ledge_legs(up)
	else:
		if _ovr_l_active:
			want_l = _ovr_l_pos; use_l = have_l
		if _ovr_r_active:
			want_r = _ovr_r_pos; use_r = have_r

	if use_l:
		if not _hinit_l:
			_hpos_l = want_l; _hinit_l = true
		_hpos_l = _hpos_l.lerp(want_l, t)
		_solve_arm_ik(_idx_sh_l, _idx_el_l, _idx_ha_l, _hpos_l, (-up - fwd * 0.4 - right * 0.3).normalized())
	else:
		_hinit_l = false
	if use_r:
		if not _hinit_r:
			_hpos_r = want_r; _hinit_r = true
		_hpos_r = _hpos_r.lerp(want_r, t)
		_solve_arm_ik(_idx_sh_r, _idx_el_r, _idx_ha_r, _hpos_r, (-up - fwd * 0.4 + right * 0.3).normalized())
	else:
		_hinit_r = false

# Spread the two ledge hand points to a min/max separation along the lip edge (the movement's
# raycast can collapse them onto the same spot on narrow/uneven lips).
func _ledge_separated(up: Vector3) -> Array:
	var mid := (_ledge_l + _ledge_r) * 0.5
	var axis := _ledge_r - _ledge_l
	axis -= up * axis.dot(up)
	if axis.length() < 1e-3:
		var n = _movement.get("_ledge_normal") if _movement != null else null
		var nrm: Vector3 = n if n is Vector3 else _player.global_transform.basis.x
		axis = nrm.cross(up)
		if axis.length() < 1e-3:
			axis = _player.global_transform.basis.x
	axis = axis.normalized()
	var half := clampf((_ledge_r - _ledge_l).length() * 0.5, ledge_hand_min_sep * 0.5, ledge_hand_max_sep * 0.5)
	return [mid - axis * half, mid + axis * half]

# Plant bent legs with the feet against the wall during a ledge hang (feeds off the movement's
# ledge geometry: outward normal + wall-face contact point). Legs are otherwise untouched by the
# ragdoll here (foot IK is off in the air), so this override owns the leg pose while hanging.
func _pose_ledge_legs(up: Vector3) -> void:
	if _idx_ul_l < 0 or _idx_ll_l < 0 or _idx_an_l < 0 or _idx_ul_r < 0 or _idx_ll_r < 0 or _idx_an_r < 0:
		return
	var nv = _movement.get("_ledge_normal") if _movement != null else null
	var nrm: Vector3 = nv if nv is Vector3 else -_player.global_transform.basis.z
	if nrm.length() < 1e-3:
		nrm = -_player.global_transform.basis.z
	nrm = nrm.normalized()
	var edge := nrm.cross(up).normalized()
	var skx := _skel.global_transform
	var hips := (skx * _skel.get_bone_global_pose(_idx_hips).origin) if _idx_hips >= 0 else _player.global_position
	# Foot height below the hips, projected onto the wall face (ledge_foot_wall = gap from wall).
	var base := hips - up * ledge_foot_drop
	var fv = _movement.get("_ledge_face") if _movement != null else null
	var wall_face: Vector3 = fv if fv is Vector3 else (hips - nrm * 0.5)
	var d := (base - wall_face).dot(nrm)
	base -= nrm * (d - ledge_foot_wall)
	var pole := (nrm - up * 0.5).normalized()   # knees bend outward + down
	_solve_arm_ik(_idx_ul_l, _idx_ll_l, _idx_an_l, base - edge * ledge_foot_spread, pole)
	_solve_arm_ik(_idx_ul_r, _idx_ll_r, _idx_an_r, base + edge * ledge_foot_spread, pole)

# Analytic 2-bone solve ported from ActiveRagdoll::_solve_leg_ik. Rig-agnostic.
func _solve_arm_ik(sh: int, el: int, ha: int, target: Vector3, pole: Vector3) -> void:
	var skel_xf := _skel.global_transform
	var hand_world := (skel_xf.basis * _skel.get_bone_global_pose(ha).basis)
	for _pass in 2:
		var shp := skel_xf * _skel.get_bone_global_pose(sh).origin
		var elp := skel_xf * _skel.get_bone_global_pose(el).origin
		var hap := skel_xf * _skel.get_bone_global_pose(ha).origin
		var l1 := shp.distance_to(elp)
		var l2 := elp.distance_to(hap)
		if l1 < 1e-4 or l2 < 1e-4:
			return
		var v_cur := hap - shp
		var v_des := target - shp
		if v_cur.length() < 1e-4 or v_des.length() < 1e-4:
			return
		var d := clampf(v_des.length(), absf(l1 - l2) + 0.01, l1 + l2 - 0.01)
		var arc := Quaternion(v_cur.normalized(), v_des.normalized())
		_set_bone_world_rot(sh, Basis(arc) * (skel_xf.basis * _skel.get_bone_global_pose(sh).basis))
		shp = skel_xf * _skel.get_bone_global_pose(sh).origin
		elp = skel_xf * _skel.get_bone_global_pose(el).origin
		hap = skel_xf * _skel.get_bone_global_pose(ha).origin
		var a := shp - elp
		var b := hap - elp
		var hinge := a.cross(b)
		if hinge.length() < 1e-5:
			hinge = (target - shp).cross(pole)
			if hinge.length() < 1e-5:
				return
		var cur_ang := a.angle_to(b)
		var need := acos(clampf((l1 * l1 + l2 * l2 - d * d) / (2.0 * l1 * l2), -1.0, 1.0))
		_set_bone_world_rot(el, Basis(Quaternion(hinge.normalized(), need - cur_ang)) * (skel_xf.basis * _skel.get_bone_global_pose(el).basis))

	if align_wrist_to_grip and _gun != null:
		var off := Basis.from_euler(_deg(wrist_rotation_deg))
		_set_bone_world_rot(ha, _gun.global_transform.basis * off)
	else:
		_set_bone_world_rot(ha, hand_world)

func _set_bone_world_rot(bone: int, world_basis: Basis) -> void:
	var skel_inv := _skel.global_transform.basis.inverse()
	var in_skel := skel_inv * world_basis
	var parent := _skel.get_bone_parent(bone)
	var parent_skel := _skel.get_bone_global_pose(parent).basis if parent >= 0 else Basis()
	var local := parent_skel.inverse() * in_skel
	_skel.set_bone_pose_rotation(bone, local.get_rotation_quaternion().normalized())
