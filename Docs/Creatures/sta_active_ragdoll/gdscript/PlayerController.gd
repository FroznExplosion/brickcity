# PlayerController.gd
# Thin input/body shell for the radial-gravity parkour player (Doc 05 / Doc 10). All
# physics lives in the PlayerMovement child; this node only captures input and forwards
# it, and hands the movement its planet reference. Mirrors ceramicedge's controller/
# movement split, with the combat plumbing removed.
class_name PlayerController
extends CharacterBody3D

@onready var movement: PlayerMovement = $PlayerMovement
@onready var camera: Camera3D = $CameraPivot/Camera3D
@onready var character_mesh: Node3D = $CharacterMesh

## The planet this player walks on — provides the gravity center (global_position).
## Assign in the inspector once a VoxelPlanet exists (Phase 1a). Until then the movement
## degrades to world-up so the scene still loads.
@export var planet: Node3D

## Double-tap Jump within this window toggles walk <-> noclip fly.
const DOUBLE_TAP_WINDOW: float = 0.30
var _last_jump_t: float = -1.0

## Camera mode (toggle_camera / C). FPS = camera at the eye pivot, body hidden so you
## don't see inside the mesh. 3rd-person = camera pulled back, body shown. PlayerMovement
## only drives cam_pivot rotation/y and camera roll (never camera.position), so this offset
## is safe to own here. The CharacterMesh faces -Z (player forward), so +Z puts the camera
## behind its back.
# FPS camera sits slightly forward of (and above) the CameraPivot. Because the pivot is what
# pitches, this forward offset makes the eye arc forward+down as you look down — like a neck
# bending — instead of clipping into the top of the torso. -Z is forward.
const CAM_FPS_OFFSET := Vector3(0.0, 0.02, -0.32)
const CAM_TPS_OFFSET := Vector3(0.0, 0.5, 4.0)
var _third_person: bool = true

## Active-ragdoll driver (sta_native ActiveRagdoll). Created in code so the scene has no
## hard dependency on the class — if the extension isn't built yet it just warns.
## Toggle on/off with toggle_ragdoll (G).
var ragdoll: Node = null

## Slice-1 locomotion: an AnimationTree (idle/walk/run/sprint blend by speed) drives the
## ragdoll's hidden target skeleton; the PD chases it. Built in code from the extracted lib.
const LOCO_LIB := "res://assets/characters/locomotion_slice1.res"
var _anim_tree: AnimationTree = null

func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	movement.planet = planet
	_apply_camera_mode()
	_setup_ragdoll()
	_setup_locomotion()
	_setup_anim_menu()
	_setup_recoil_holder()
	_setup_weapon()

## Recoil holder: a logic node that writes weapon recoil onto the camera's own x/y rotation and
## auto-recovers WITHOUT permanently shifting look pitch. Deliberately NOT in the camera transform
## chain — reparenting Camera3D would break the hardcoded `CameraPivot/Camera3D` path that
## solar_system.gd and PlayerMovement rely on. Camera z stays owned by the movement roll tween.
var recoil_holder: Node = null
func _setup_recoil_holder() -> void:
	var rh_script: GDScript = load("res://scripts/player/recoil_holder.gd")
	if rh_script == null:
		return
	recoil_holder = rh_script.new()
	recoil_holder.name = "RecoilHolder"
	add_child(recoil_holder)
	recoil_holder.camera = camera

## Weapon handling: instance the editor-authored weapon rig (WeaponController.tscn — gun mesh +
## grip markers are draggable nodes there) and wire it to the body/camera/skeleton. The rig drives
## the gun to the aim and IKs the hands onto its grip markers.
var weapon: Node = null
func _setup_weapon() -> void:
	var wc_scene: PackedScene = load("res://scenes/player/WeaponController.tscn")
	if wc_scene == null:
		return
	weapon = wc_scene.instantiate()
	add_child(weapon)
	weapon.setup(self, camera, movement, character_mesh, recoil_holder)
	# Let the movement's ledge system drive the hand IK (ledge_active / set_ledge_hands hook).
	movement._hands = weapon

func _setup_ragdoll() -> void:
	if ClassDB.class_exists("ActiveRagdoll"):
		ragdoll = ClassDB.instantiate("ActiveRagdoll")
		ragdoll.name = "ActiveRagdoll"
		add_child(ragdoll)  # ActiveRagdoll finds the Skeleton3D under this player in _ready
	else:
		push_warning("[player] ActiveRagdoll class not loaded — rebuild sta_native + restart editor")

func _setup_locomotion() -> void:
	if ragdoll == null or not ragdoll.has_method("get_anim_target_skeleton"):
		return
	var tskel: Skeleton3D = ragdoll.get_anim_target_skeleton()
	if tskel == null:
		push_warning("[player] no anim target skeleton — procedural walk stays")
		return
	var lib: AnimationLibrary = load(LOCO_LIB)
	if lib == null:
		push_warning("[player] locomotion lib missing (%s) — procedural walk stays" % LOCO_LIB)
		return
	_loco_lib = lib
	# Clip tracks are pathed "Skeleton3D:Bone" — guarantee that name resolves on the target.
	tskel.name = "Skeleton3D"
	var root := tskel.get_parent()

	var ap := AnimationPlayer.new()
	ap.name = "LocoAP"
	root.add_child(ap)
	ap.root_node = ap.get_path_to(root)   # ".." so "Skeleton3D:Bone" resolves to root/Skeleton3D
	ap.add_animation_library("", lib)

	# 2D locomotion blendspace: X = sideways m/s (right +), Y = forward m/s (+) in BODY space.
	# Idle center, walk ring at 2.5 m/s, run ring at 6, sprint forward-only at 10 — any
	# direction/speed in between interpolates = continuous "infinite direction" strafing.
	var loco := AnimationNodeBlendSpace2D.new()
	loco.sync = true   # keep every gait clip advancing (phase-locked; see extract_anims.gd)
	loco.min_space = Vector2(-7.0, -7.0)
	loco.max_space = Vector2(7.0, 11.0)
	loco.add_blend_point(_clip_node("idle"), Vector2.ZERO)
	var d45 := 0.7071
	for ring in [{"p": "walk_", "f": "walk", "r": 2.5}, {"p": "run_", "f": "run", "r": 6.0}]:
		var r: float = ring["r"]
		var p: String = ring["p"]
		loco.add_blend_point(_clip_node(ring["f"]), Vector2(0, r))            # forward
		loco.add_blend_point(_clip_node(p + "fl"), Vector2(-d45 * r, d45 * r))
		loco.add_blend_point(_clip_node(p + "fr"), Vector2(d45 * r, d45 * r))
		loco.add_blend_point(_clip_node(p + "l"), Vector2(-r, 0))
		loco.add_blend_point(_clip_node(p + "r"), Vector2(r, 0))
		loco.add_blend_point(_clip_node(p + "bl"), Vector2(-d45 * r, -d45 * r))
		loco.add_blend_point(_clip_node(p + "br"), Vector2(d45 * r, -d45 * r))
		loco.add_blend_point(_clip_node(p + "b"), Vector2(0, -r))
	loco.add_blend_point(_clip_node("sprint"), Vector2(0, 10.0))
	# Standing shuffle ring — slow micro-steps between idle and walk (indices 18..21).
	loco.add_blend_point(_clip_node("shuffle_f"), Vector2(0, 0.9))
	loco.add_blend_point(_clip_node("shuffle_r"), Vector2(0.9, 0))
	loco.add_blend_point(_clip_node("shuffle_b"), Vector2(0, -0.9))
	loco.add_blend_point(_clip_node("shuffle_l"), Vector2(-0.9, 0))

	# MANUAL triangulation. Auto-triangulation degenerates on this layout: idle, walk_r and
	# run_r (etc.) are exactly collinear along each axis, so Delaunay produced sliver
	# triangles and pure-side strafing blended the WALK ring at run speed. Explicit
	# concentric bands: idle fan -> shuffle ring -> walk ring -> run ring -> sprint cap.
	loco.auto_triangles = false
	var w := [1, 3, 5, 7, 8, 6, 4, 2]      # walk ring, clockwise from forward
	var rr := [9, 11, 13, 15, 16, 14, 12, 10]  # run ring, same order
	var sh := [18, 19, 20, 21]             # shuffle ring: F, R, B, L
	for q in 4:
		var s_a: int = sh[q]
		var s_b: int = sh[(q + 1) % 4]
		var w_a: int = w[q * 2]
		var w_m: int = w[q * 2 + 1]
		var w_b: int = w[(q * 2 + 2) % 8]
		loco.add_triangle(0, s_a, s_b)          # idle fan
		loco.add_triangle(s_a, w_a, w_m)        # shuffle -> walk band (4-to-8 sectors)
		loco.add_triangle(s_a, w_m, s_b)
		loco.add_triangle(s_b, w_m, w_b)
	for i in 8:
		var j := (i + 1) % 8
		loco.add_triangle(w[i], w[j], rr[i])    # walk -> run band
		loco.add_triangle(w[j], rr[j], rr[i])
	loco.add_triangle(17, 10, 9)                # sprint cap (fl-f)
	loco.add_triangle(17, 9, 11)                # sprint cap (f-fr)

	# In-air pose by fall speed (rising/low fall = short pose, fast fall = big flail).
	var fall := AnimationNodeBlendSpace1D.new()
	fall.min_space = 0.0
	fall.max_space = 1.0
	fall.add_blend_point(_clip_node("fall_short"), 0.0)
	fall.add_blend_point(_clip_node("fall_large"), 1.0)

	# Takeoff pose by ground speed at the moment of the jump (one-shots, restarted via seek).
	var jump_bs := AnimationNodeBlendSpace1D.new()
	jump_bs.min_space = 0.0
	jump_bs.max_space = 10.0
	jump_bs.add_blend_point(_clip_node("jump_idle"), 0.0)
	jump_bs.add_blend_point(_clip_node("jump_walk"), 2.5)
	jump_bs.add_blend_point(_clip_node("jump_run"), 6.0)
	jump_bs.add_blend_point(_clip_node("jump_sprint"), 10.0)

	# 25-degree slope cycles by speed; blended over loco by signed slope (Blend3: -1 = down).
	var slope_up := AnimationNodeBlendSpace1D.new()
	slope_up.min_space = 0.0
	slope_up.max_space = 10.0
	slope_up.add_blend_point(_clip_node("walk_up"), 2.5)
	slope_up.add_blend_point(_clip_node("run_up"), 6.0)
	slope_up.add_blend_point(_clip_node("sprint_up"), 10.0)
	var slope_dn := AnimationNodeBlendSpace1D.new()
	slope_dn.min_space = 0.0
	slope_dn.max_space = 10.0
	slope_dn.add_blend_point(_clip_node("walk_down"), 2.5)
	slope_dn.add_blend_point(_clip_node("run_down"), 6.0)
	slope_dn.add_blend_point(_clip_node("sprint_down"), 10.0)

	# Landing pose by impact strength (0 = soft touch, 1 = hard slam).
	var land_bs := AnimationNodeBlendSpace1D.new()
	land_bs.min_space = 0.0
	land_bs.max_space = 1.0
	land_bs.add_blend_point(_clip_node("land_soft"), 0.0)
	land_bs.add_blend_point(_clip_node("land_medium"), 0.5)
	land_bs.add_blend_point(_clip_node("land_hard"), 1.0)

	# Layered blend tree:  loco ─air(Blend2 w/ fall)─ land(Blend2 w/ land_bs) ─ crouch(Blend2) → out
	# Transition one-shot slot: ONE reusable AnimationNodeAnimation — the runtime swaps its
	# `animation` (start_walk/stop_run_l/turn_90r/...), seeks 0 and runs a weight envelope.
	_trans_clip = _clip_node("start_walk")

	# Crouch locomotion: crouch idle center, 4-way slow shuffle ring (1.2), 8-way crouch
	# strafe ring (3.0). Manual triangles — same collinear-axis Delaunay hazard as loco.
	var crouch_bs := AnimationNodeBlendSpace2D.new()
	crouch_bs.sync = true
	crouch_bs.auto_triangles = false
	crouch_bs.min_space = Vector2(-3.5, -3.5)
	crouch_bs.max_space = Vector2(3.5, 3.5)
	crouch_bs.add_blend_point(_clip_node("crouch_idle"), Vector2.ZERO)        # 0
	crouch_bs.add_blend_point(_clip_node("cshuffle_f"), Vector2(0, 1.2))      # 1
	crouch_bs.add_blend_point(_clip_node("cshuffle_r"), Vector2(1.2, 0))      # 2
	crouch_bs.add_blend_point(_clip_node("cshuffle_b"), Vector2(0, -1.2))     # 3
	crouch_bs.add_blend_point(_clip_node("cshuffle_l"), Vector2(-1.2, 0))     # 4
	var cr := 3.0
	crouch_bs.add_blend_point(_clip_node("crouch_f"), Vector2(0, cr))         # 5
	crouch_bs.add_blend_point(_clip_node("crouch_fl"), Vector2(-d45 * cr, d45 * cr))  # 6
	crouch_bs.add_blend_point(_clip_node("crouch_fr"), Vector2(d45 * cr, d45 * cr))   # 7
	crouch_bs.add_blend_point(_clip_node("crouch_l"), Vector2(-cr, 0))        # 8
	crouch_bs.add_blend_point(_clip_node("crouch_r"), Vector2(cr, 0))         # 9
	crouch_bs.add_blend_point(_clip_node("crouch_bl"), Vector2(-d45 * cr, -d45 * cr)) # 10
	crouch_bs.add_blend_point(_clip_node("crouch_br"), Vector2(d45 * cr, -d45 * cr))  # 11
	crouch_bs.add_blend_point(_clip_node("crouch_b"), Vector2(0, -cr))        # 12
	# Quadrants: [shuffleA, shuffleB, strafe aligned-A, diagonal, aligned-B]
	for q in [[1, 2, 5, 7, 9], [2, 3, 9, 11, 12], [3, 4, 12, 10, 8], [4, 1, 8, 6, 5]]:
		crouch_bs.add_triangle(0, q[0], q[1])          # idle fan
		crouch_bs.add_triangle(q[0], q[2], q[3])       # band
		crouch_bs.add_triangle(q[0], q[3], q[1])
		crouch_bs.add_triangle(q[1], q[3], q[4])

	# sync=true on the blend layers: the loco branch keeps advancing (in phase) even while
	# its weight is 0 (mid-air, during a land pose), so blending back in never pops.
	var slope_blend := AnimationNodeBlend3.new()
	slope_blend.sync = true
	var airpose_blend := AnimationNodeBlend2.new()   # jump one-shot vs falling pose
	airpose_blend.sync = true
	var air_blend := AnimationNodeBlend2.new()
	air_blend.sync = true
	var land_blend := AnimationNodeBlend2.new()
	land_blend.sync = true
	var trans_blend := AnimationNodeBlend2.new()
	trans_blend.sync = true
	var crouch_blend := AnimationNodeBlend2.new()
	crouch_blend.sync = true

	# loco → slope(Blend3 dn/flat/up) → air(Blend2 with jump→fall mix) → land → crouch → out
	var tree := AnimationNodeBlendTree.new()
	tree.add_node("loco", loco, Vector2(0, 0))
	tree.add_node("slope_dn", slope_dn, Vector2(0, -200))
	tree.add_node("slope_up", slope_up, Vector2(0, -400))
	tree.add_node("slope", slope_blend, Vector2(200, 0))
	tree.add_node("fall", fall, Vector2(0, 200))
	tree.add_node("jump_bs", jump_bs, Vector2(0, 400))
	tree.add_node("jump_seek", AnimationNodeTimeSeek.new(), Vector2(150, 400))
	tree.add_node("airpose", airpose_blend, Vector2(300, 300))
	tree.add_node("air", air_blend, Vector2(450, 0))
	tree.add_node("land_bs", land_bs, Vector2(250, 500))
	tree.add_node("land_seek", AnimationNodeTimeSeek.new(), Vector2(400, 500))
	tree.add_node("land", land_blend, Vector2(650, 0))
	tree.add_node("trans_clip", _trans_clip, Vector2(500, 650))
	tree.add_node("trans_seek", AnimationNodeTimeSeek.new(), Vector2(650, 650))
	tree.add_node("trans", trans_blend, Vector2(950, 0))
	tree.add_node("crouch_bs", crouch_bs, Vector2(650, 500))
	tree.add_node("crouch", crouch_blend, Vector2(800, 0))
	# Additive sweeps (Neutral pack): scrubbed by TimeSeek, layered with Add2. Lean by turn
	# rate, head/body look by camera pitch. Mid-frame of each sweep = neutral pose.
	tree.add_node("lean_clip", _clip_node("add_lean"), Vector2(950, 500))
	tree.add_node("lean_seek", AnimationNodeTimeSeek.new(), Vector2(1050, 500))
	tree.add_node("lean", AnimationNodeAdd2.new(), Vector2(1100, 0))
	tree.add_node("hlook_clip", _clip_node("add_headlook"), Vector2(1100, 500))
	tree.add_node("hlook_seek", AnimationNodeTimeSeek.new(), Vector2(1200, 500))
	tree.add_node("hlook", AnimationNodeAdd2.new(), Vector2(1250, 0))
	tree.add_node("blook_clip", _clip_node("add_bodylook"), Vector2(1250, 500))
	tree.add_node("blook_seek", AnimationNodeTimeSeek.new(), Vector2(1350, 500))
	tree.add_node("blook", AnimationNodeAdd2.new(), Vector2(1400, 0))
	tree.connect_node("slope", 0, "slope_dn")   # Blend3: input 0 = "minus" pose (downhill)
	tree.connect_node("slope", 1, "loco")       # base
	tree.connect_node("slope", 2, "slope_up")   # "plus" pose (uphill)
	tree.connect_node("jump_seek", 0, "jump_bs")
	tree.connect_node("airpose", 0, "jump_seek")
	tree.connect_node("airpose", 1, "fall")
	tree.connect_node("air", 0, "slope")
	tree.connect_node("air", 1, "airpose")
	tree.connect_node("land_seek", 0, "land_bs")
	tree.connect_node("land", 0, "air")
	tree.connect_node("land", 1, "land_seek")
	# Crouch UNDER trans: stand<->crouch / crouch-turn one-shots must override the crouch
	# pose (trans over crouch), else they'd be invisible at crouch weight 1.
	tree.connect_node("crouch", 0, "land")
	tree.connect_node("crouch", 1, "crouch_bs")
	tree.connect_node("trans_seek", 0, "trans_clip")
	tree.connect_node("trans", 0, "crouch")
	tree.connect_node("trans", 1, "trans_seek")
	tree.connect_node("lean_seek", 0, "lean_clip")
	tree.connect_node("lean", 0, "trans")
	tree.connect_node("lean", 1, "lean_seek")
	tree.connect_node("hlook_seek", 0, "hlook_clip")
	tree.connect_node("hlook", 0, "lean")
	tree.connect_node("hlook", 1, "hlook_seek")
	tree.connect_node("blook_seek", 0, "blook_clip")
	tree.connect_node("blook", 0, "hlook")
	tree.connect_node("blook", 1, "blook_seek")
	tree.connect_node("output", 0, "blook")

	_anim_tree = AnimationTree.new()
	_anim_tree.name = "LocoTree"
	root.add_child(_anim_tree)
	_anim_tree.anim_player = _anim_tree.get_path_to(ap)
	_anim_tree.tree_root = tree
	_anim_tree.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_PHYSICS
	_anim_tree.active = true
	ragdoll.set("use_procedural_walk", false)  # clips drive the target now, not the sine walk

	# Additive layer strengths (body-look kept subtle under the head-look).
	for k in ["add_lean", "add_headlook", "add_bodylook"]:
		if not lib.has_animation(k):
			push_warning("[player] additive clip missing: " + k)
	_len_lean = lib.get_animation("add_lean").length if lib.has_animation("add_lean") else 0.0
	_len_hlook = lib.get_animation("add_headlook").length if lib.has_animation("add_headlook") else 0.0
	_len_blook = lib.get_animation("add_bodylook").length if lib.has_animation("add_bodylook") else 0.0
	_anim_tree.set("parameters/lean/add_amount", 1.0)
	_anim_tree.set("parameters/hlook/add_amount", 1.0)
	_anim_tree.set("parameters/blook/add_amount", 0.35)

func _clip_node(anim_name: String) -> AnimationNodeAnimation:
	var n := AnimationNodeAnimation.new()
	n.animation = anim_name
	return n

var _anim_menu: CanvasLayer = null

func _setup_anim_menu() -> void:
	if ragdoll == null:
		return
	var menu_script: GDScript = load("res://scenes/player/anim_debug_menu.gd")
	if menu_script == null:
		return
	_anim_menu = menu_script.new()
	add_child(_anim_menu)
	_anim_menu.setup(ragdoll)  # builds sliders/checkboxes; F3 toggles

func _apply_camera_mode() -> void:
	camera.position = CAM_TPS_OFFSET if _third_person else CAM_FPS_OFFSET
	# Mesh stays visible in FPS too — arms are posed in front like FPS hands. Hide the
	# head bone in FPS so the camera (inside the skull) doesn't see inside the head.
	character_mesh.visible = true
	if ragdoll != null and ragdoll.has_method("set_head_hidden"):
		ragdoll.set_head_hidden(not _third_person)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		movement.handle_look((event as InputEventMouseMotion).relative)

	if event.is_action_pressed("jump"):
		var now := Time.get_ticks_msec() / 1000.0
		if now - _last_jump_t <= DOUBLE_TAP_WINDOW:
			_last_jump_t = -1.0
			movement.set_flying(not movement.flying)   # double-tap = toggle fly
		else:
			_last_jump_t = now
			if not movement.flying:
				movement.jump_pressed()
	elif event.is_action_released("jump"):
		if not movement.flying:
			movement.jump_released()
	elif event.is_action_pressed("slide_dash"):
		if not movement.flying:                          # fly: Slide/Dash = descend
			movement.request_slide_or_dash()
	elif event.is_action_pressed("sprint"):
		movement.toggle_sprint()
	elif event.is_action_pressed("toggle_camera"):
		_third_person = not _third_person
		_apply_camera_mode()
	elif event.is_action_pressed("toggle_ragdoll"):
		if ragdoll != null:
			ragdoll.set_simulating(not ragdoll.get_simulating())
	# Esc toggles mouse capture for debugging.
	elif event.is_action_pressed("ui_cancel"):
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		else:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

var _loco_blend: Vector2 = Vector2.ZERO
var _air_w: float = 0.0
var _land_w: float = 0.0
var _crouch_w: float = 0.0
var _peak_fall: float = 0.0
var _was_airborne: bool = false
var _slope_amt: float = 0.0
var _fall_mix: float = 0.0

# Transition one-shot state
var _loco_lib: AnimationLibrary = null
var _trans_clip: AnimationNodeAnimation = null
var _trans_t: float = 999.0
var _trans_len: float = 0.0
var _trans_w: float = 0.0
var _stop_foot_left: bool = false
var _idle_yaw_acc: float = 0.0
var _last_fwd: Vector3 = Vector3.ZERO
var _prev_spd: float = 0.0
var _prev_move_state: int = -1
var _yaw_rate: float = 0.0
var _len_lean: float = 0.0
var _len_hlook: float = 0.0
var _len_blook: float = 0.0

## Game speeds don't match the clip-authored ring speeds: walk_speed 8 was over-blending
## sprint, and 8-10 m/s strafing under-blended the 6 m/s run ring. Piecewise remap:
## game 0..2.5 -> 0..2.5 (walk), 2.5..8 -> walk..run(6), 8..11 -> run..sprint(10).
func _map_speed(s: float) -> float:
	if s <= 2.5:
		return s
	if s <= 8.0:
		return 2.5 + (s - 2.5) / 5.5 * 3.5
	return 6.0 + (s - 8.0) / 3.0 * 4.0

# Impact speed (m/s, radial) that plays the hard-land clip at FULL weight; slower landings
# blend softer clips at proportionally less weight. Fall pose maxes out at FALL_BLEND_MAX.
const LAND_MAX_IMPACT := 14.0
const FALL_BLEND_MAX := 12.0
const LAND_FADE_TIME := 0.8    # seconds for the land pose to release back to locomotion
const CROUCH_MAX := 0.85       # full-charge crouch depth (blend weight)

func _physics_process(delta: float) -> void:
	movement.tick(delta)
	if _anim_tree != null:
		_update_anim_layers(delta)

func _update_anim_layers(delta: float) -> void:
	var v := get_real_velocity()
	var up := global_transform.basis.y
	var radial := v.dot(up)                      # + = rising, - = falling
	var tvel := v - up * radial                  # tangential velocity

	# Locomotion: body-local (side, forward) m/s feeds the 2D blendspace — any strafe angle
	# interpolates. Speed remapped to the clip-authored ring speeds, then smoothed (raw
	# speed sweeps through phase-unsynced clips -> jitter).
	var body_basis := global_transform.basis
	var local := Vector2(tvel.dot(body_basis.x), tvel.dot(-body_basis.z))   # x = right, y = forward
	var lmag := local.length()
	if lmag > 0.01:
		local *= _map_speed(lmag) / lmag
	_loco_blend = _loco_blend.lerp(local, minf(delta * 6.0, 1.0))
	_anim_tree.set("parameters/loco/blend_position", _loco_blend)

	# Slope layer: signed steepness (+ = moving uphill), scaled by how forward the motion is
	# (the slope clips are forward-only) and eased so flat ground returns to plain loco.
	var slope_amt := 0.0
	if is_on_floor() and tvel.length() > 0.5:
		var n := get_floor_normal()
		var downhill := n - up * n.dot(up)   # floor normal leans away from the hill = downhill
		if downhill.length() > 0.02:
			var steep := acos(clampf(n.dot(up), -1.0, 1.0))
			var dirdot := tvel.normalized().dot(downhill.normalized())  # +1 = moving downhill
			slope_amt = clampf(steep / deg_to_rad(25.0), 0.0, 1.0) * -dirdot
			slope_amt *= clampf(tvel.length() / 2.5, 0.0, 1.0)
	_slope_amt = lerpf(_slope_amt, slope_amt, minf(delta * 8.0, 1.0))
	_anim_tree.set("parameters/slope/blend_amount", _slope_amt)
	_anim_tree.set("parameters/slope_up/blend_position", _loco_blend.length())
	_anim_tree.set("parameters/slope_dn/blend_position", _loco_blend.length())

	_update_transitions(delta, tvel, up)

	# Airborne layer + falling pose. Track peak fall speed for the landing impact.
	var airborne: bool = movement.state == PlayerMovement.State.AIRBORNE
	if airborne:
		_peak_fall = maxf(_peak_fall, -radial)
	if airborne and not _was_airborne:
		# Takeoff: pick the jump one-shot by ground speed and restart it.
		_anim_tree.set("parameters/jump_bs/blend_position", _map_speed(tvel.length()))
		_anim_tree.set("parameters/jump_seek/seek_request", 0.0)
		_fall_mix = 0.0
	# Jump pose while rising, falling pose once descending.
	_fall_mix = lerpf(_fall_mix, 1.0 if (airborne and radial < -1.0) else _fall_mix, minf(delta * 5.0, 1.0))
	_anim_tree.set("parameters/airpose/blend_amount", _fall_mix)
	_air_w = lerpf(_air_w, 1.0 if airborne else 0.0, minf(delta * 10.0, 1.0))
	_anim_tree.set("parameters/air/blend_amount", _air_w)
	_anim_tree.set("parameters/fall/blend_position", clampf(_peak_fall / FALL_BLEND_MAX, 0.0, 1.0))

	# Landing: on the airborne->grounded edge, fire the land pose scaled by impact speed —
	# LAND_MAX_IMPACT+ = hard clip at full weight, slower = softer clip at less weight.
	if _was_airborne and not airborne:
		var impact := clampf(_peak_fall / LAND_MAX_IMPACT, 0.0, 1.0)
		_land_w = impact
		_anim_tree.set("parameters/land_bs/blend_position", impact)
		_anim_tree.set("parameters/land_seek/seek_request", 0.0)  # restart the one-shot
		_peak_fall = 0.0
	if not airborne:
		_peak_fall = 0.0
	_was_airborne = airborne
	_land_w = maxf(_land_w - delta / LAND_FADE_TIME, 0.0)
	_anim_tree.set("parameters/land/blend_amount", _land_w)

	# Crouch layer: full weight in the CROUCHING state (blendspace gives idle/shuffle/strafe
	# by velocity); while jump-charging it eases in by charge fraction — a quick tap never
	# accumulates charge -> no crouch, straight jump. Release snaps out fast.
	# Sliding holds the crouch pose too (entered via the sprint_to_crouch one-shot).
	var crouched: bool = movement.state == PlayerMovement.State.CROUCHING \
			or movement.state == PlayerMovement.State.SLIDING
	var charging: bool = movement._jump_charging and is_on_floor()
	var charge_target := 0.0
	if crouched:
		charge_target = 1.0
	elif charging and movement.config != null:
		charge_target = clampf(movement._jump_charge_t / movement.config.jump_charge_time, 0.0, 1.0) * CROUCH_MAX
	var rate := 8.0 if (charging or crouched) else 14.0
	_crouch_w = lerpf(_crouch_w, charge_target, minf(delta * rate, 1.0))
	_anim_tree.set("parameters/crouch/blend_amount", _crouch_w)
	# Crouch blend position: body-local velocity scaled so full crouch speed hits the
	# strafe ring (3.0); slower speeds pass through the shuffle ring on the way.
	var cspd := tvel.length()
	var cpos := Vector2.ZERO
	if cspd > 0.05:
		var cdir := Vector2(tvel.dot(basis.x), tvel.dot(-basis.z)) / cspd
		cpos = cdir * minf(cspd / 4.0, 1.0) * 3.0
	_anim_tree.set("parameters/crouch_bs/blend_position", cpos)

	# Additive sweeps: mid-frame = neutral. Lean scrubbed by smoothed turn rate (scaled by
	# speed so standing mouse-flicks don't tilt); head/body look scrubbed by camera pitch.
	if _len_lean > 0.0:
		var lean := clampf(_yaw_rate * 0.22, -1.0, 1.0) * clampf(tvel.length() / 6.0, 0.0, 1.0)
		_anim_tree.set("parameters/lean_seek/seek_request", (0.5 - lean * 0.5) * _len_lean)
	var pitch01: float = clampf(movement._pitch / 1.2, -1.0, 1.0)
	if _len_hlook > 0.0:
		_anim_tree.set("parameters/hlook_seek/seek_request", (0.5 + pitch01 * 0.5) * _len_hlook)
	if _len_blook > 0.0:
		_anim_tree.set("parameters/blook_seek/seek_request", (0.5 + pitch01 * 0.5) * _len_blook)

## Start / stop / turn-in-place one-shots through the single `trans` slot. Triggers on
## speed edges (start: 0->moving, stop: moving->0) and on accumulated body yaw while idle.
## Weight envelope: 80 ms in, hold, 250 ms out; cancelled by going airborne.
func _fire_transition(anim_name: String) -> void:
	if _loco_lib == null or not _loco_lib.has_animation(anim_name):
		return
	_trans_clip.animation = anim_name
	_trans_len = _loco_lib.get_animation(anim_name).length
	_trans_t = 0.0
	_anim_tree.set("parameters/trans_seek/seek_request", 0.0)

func _update_transitions(delta: float, tvel: Vector3, up: Vector3) -> void:
	var spd := tvel.length()
	var on_floor := is_on_floor()
	var active := _trans_t < _trans_len

	# Cancel mid-air; advance the envelope otherwise.
	if active and not on_floor:
		_trans_t = _trans_len
		active = false
	if active:
		_trans_t += delta
		_trans_w = clampf(minf(_trans_t / 0.08, (_trans_len - _trans_t) / 0.25), 0.0, 1.0)
	else:
		_trans_w = maxf(_trans_w - delta / 0.15, 0.0)
	_anim_tree.set("parameters/trans/blend_amount", _trans_w)

	var crouched: bool = movement.state == PlayerMovement.State.CROUCHING
	var sliding: bool = movement.state == PlayerMovement.State.SLIDING

	# Crouch / slide state edges override whatever is playing.
	var mstate: int = movement.state
	if _prev_move_state != -1 and mstate != _prev_move_state:
		if sliding:
			_fire_transition("sprint_to_crouch")
		elif crouched and _prev_move_state == PlayerMovement.State.GROUNDED:
			_fire_transition("stand_to_crouch")
		elif mstate == PlayerMovement.State.GROUNDED and _prev_move_state == PlayerMovement.State.CROUCHING:
			_fire_transition("crouch_to_stand")
	_prev_move_state = mstate

	# Start/stop triggers — standing gaits only (crouch has its own blendspace + turns).
	if on_floor and not active and not crouched and not sliding:
		if spd > 1.0 and _prev_spd <= 1.0:
			# Start: walk vs run by sprint key; F / 90 L-R / 180 L-R by the angle between
			# body forward and the initial move direction.
			var basis := global_transform.basis
			var ang := rad_to_deg(atan2(tvel.dot(basis.x), tvel.dot(-basis.z)))
			var pre := "start_run" if movement.is_sprinting else "start_walk"
			var a := absf(ang)
			if a >= 135.0:
				pre += "_180r" if ang > 0.0 else "_180l"
			elif a >= 45.0:
				pre += "_90r" if ang > 0.0 else "_90l"
			_fire_transition(pre)
		elif spd < 1.0 and _prev_spd >= 1.0:
			# Stop: walk vs run by the speed we came from; alternate the planted foot.
			var base := "stop_run_" if _prev_spd > 5.0 else "stop_walk_"
			_fire_transition(base + ("l" if _stop_foot_left else "r"))
			_stop_foot_left = not _stop_foot_left

	# Body yaw rate (smoothed) — drives the additive lean; also feeds turn-in-place below.
	var fwd := (-global_transform.basis.z - up * (-global_transform.basis.z).dot(up)).normalized()
	var yaw_step := 0.0
	if _last_fwd != Vector3.ZERO:
		var cross := _last_fwd.cross(fwd)
		yaw_step = atan2(cross.dot(up), _last_fwd.dot(fwd))
	_yaw_rate = lerpf(_yaw_rate, yaw_step / maxf(delta, 0.0001), minf(delta * 8.0, 1.0))

	# Turn-in-place: accumulate signed yaw while standing still (standing or crouched).
	if _last_fwd != Vector3.ZERO and on_floor and spd < 0.5 and not sliding:
		_idle_yaw_acc += yaw_step
		if not active and absf(_idle_yaw_acc) > deg_to_rad(60.0):
			var left := _idle_yaw_acc > 0.0
			if crouched:
				_fire_transition("cturn_90" + ("l" if left else "r"))
			else:
				var big := absf(_idle_yaw_acc) > deg_to_rad(150.0)
				_fire_transition(("turn_180" if big else "turn_90") + ("l" if left else "r"))
			_idle_yaw_acc = 0.0
	else:
		_idle_yaw_acc = 0.0
	_last_fwd = fwd
	_prev_spd = spd
