class_name PlayerController
extends Node
## A human's hands on a Pawn: keyboard and mouse into PawnIntents, and the camera
## onto the pawn's eye. The brain half of the contract (PawnIntents) -- an AI
## brain is the other kind, and the pawn cannot tell them apart.
##
## Look is the CAMERA's: whoever turns the camera (the debug camera's mouse-look
## today, a proper rig later) is turning the player, and this reads where it
## points. So nothing here fights anything else for the mouse.
##
## Input is gathered every frame and the pawn moves on the physics tick; the
## camera follows the body's INTERPOLATED position, so a 30 Hz body under a
## faster picture still reads as smooth.
##
## Keys are INPUT ACTIONS (project.godot), so the Options menu can rebind them:
## move_forward/back/left/right (WASD), sprint (SHIFT, forward only, and not while
## firing or aiming -- the gun comes up first), jump (SPACE; at a ledge it climbs),
## crouch (C or CTRL; at a run, a slide), grapple (Q, held), aim (RMB), fire (LMB),
## reload (R), melee (E). Sprint, aim and crouch can each be HOLD or TOGGLE (Options).

var pawn: Pawn
var camera: Camera3D
## Act on the keyboard without the mouse captured. For scripted gates, which
## synthesise keys and must not steal the cursor.
var drive_uncaptured := false
## Hold or toggle, from the Options menu (BrickcityMenuHost). Static: one player.
static var toggle_sprint := false
static var toggle_aim := false
static var toggle_crouch := false
var _sprint_on := false
var _aim_on := false
var _crouch_on := false
## The melee button means something else here first: `() -> bool`, true when it was
## used (the scene's rodeo climb onto a mech in reach). Else the press is a melee.
var melee_context := Callable()
## The hands and the camera's feel (PlayerView), when there is one. It says when
## the gun is up enough to fire.
var view: PlayerView
## The eye's height over the feet, eased: a crouch or a slide lowers the view
## over a tenth of a second instead of dropping it a brick in one frame.
var _eye_h := 0.0
const EYE_EASE := 14.0


func possess(p: Pawn, cam: Camera3D) -> void:
	pawn = p
	camera = cam
	pawn.intents.clear()
	_eye_h = pawn.eye_height()
	_sync_look()
	_follow(0.0)


func release() -> void:
	if pawn != null:
		pawn.intents.clear()
	pawn = null
	camera = null


func is_possessing() -> bool:
	return pawn != null and is_instance_valid(pawn) and camera != null


func _active() -> bool:
	return drive_uncaptured or Input.mouse_mode == Input.MOUSE_MODE_CAPTURED


func _unhandled_input(event: InputEvent) -> void:
	if not is_possessing() or not _active():
		return
	if event.is_echo():
		return
	if _pressed(event, &"jump"):
		pawn.intents.jump = true
	if _pressed(event, &"reload"):
		pawn.intents.reload = true
	if _pressed(event, &"melee"):
		if not (melee_context.is_valid() and bool(melee_context.call())):
			pawn.intents.melee = true
	# The toggles flip on the press, whatever was held.
	if _pressed(event, &"sprint"):
		_sprint_on = not _sprint_on
	if _pressed(event, &"aim"):
		_aim_on = not _aim_on
	if _pressed(event, &"crouch"):
		_crouch_on = not _crouch_on


static func _pressed(event: InputEvent, action: StringName) -> bool:
	return InputMap.has_action(action) and event.is_action_pressed(action)


static func _down(action: StringName) -> bool:
	return InputMap.has_action(action) and Input.is_action_pressed(action)


func _process(delta: float) -> void:
	if not is_possessing():
		return
	var it := pawn.intents
	_sync_look()
	if _active():
		var basis := Basis(Vector3.UP, it.look_yaw)
		var wish := Vector3.ZERO
		var forward := _down(&"move_forward")
		if forward: wish -= basis.z
		if _down(&"move_back"): wish += basis.z
		if _down(&"move_left"): wish -= basis.x
		if _down(&"move_right"): wish += basis.x
		it.move = wish.normalized() if wish != Vector3.ZERO else Vector3.ZERO
		var trigger := _down(&"fire")
		it.aim = _aim_on if toggle_aim else _down(&"aim")
		# A sprint is forwards, and the trigger or the sights end it -- a toggled one
		# too, which then has to be switched on again.
		if not forward or trigger or it.aim:
			_sprint_on = false
		it.run = (_sprint_on if toggle_sprint else _down(&"sprint")) and forward \
				and not trigger and not it.aim
		it.crouch = _crouch_on if toggle_crouch else _down(&"crouch")
		it.grapple = _down(&"grapple")
		it.jump_held = _down(&"jump")
		# Held through a sprint, the round waits for the gun to come up.
		it.fire = trigger and (view == null or view.can_fire())
	else:
		it.move = Vector3.ZERO
		it.run = false
		it.crouch = false
		it.fire = false
		it.aim = false
		it.grapple = false
		it.jump_held = false
	_follow(delta)


func _sync_look() -> void:
	var r := camera.global_rotation
	pawn.intents.look_yaw = r.y
	pawn.intents.look_pitch = r.x


func _follow(delta: float) -> void:
	var h := pawn.eye_height()
	_eye_h += pawn.take_eye_snap()
	_eye_h = h if delta <= 0.0 else lerpf(_eye_h, h, 1.0 - exp(-EYE_EASE * delta))
	camera.global_position = pawn.feet_interpolated() + Vector3.UP * _eye_h
