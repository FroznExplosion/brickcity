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
## Keys, the way FPS players expect them: WASD, SHIFT sprint (forward only, and
## not while firing or aiming -- the gun comes up first), SPACE jump (at a ledge
## it climbs), C or CTRL crouch (at a run: slide), Q grapple (hold), RMB aim,
## LMB fire, R reload.

var pawn: Pawn
var camera: Camera3D
## Act on the keyboard without the mouse captured. For scripted gates, which
## synthesise keys and must not steal the cursor.
var drive_uncaptured := false
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
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_SPACE:
				pawn.intents.jump = true
			KEY_R:
				pawn.intents.reload = true


func _process(delta: float) -> void:
	if not is_possessing():
		return
	var it := pawn.intents
	_sync_look()
	if _active():
		var basis := Basis(Vector3.UP, it.look_yaw)
		var wish := Vector3.ZERO
		if Input.is_key_pressed(KEY_W): wish -= basis.z
		if Input.is_key_pressed(KEY_S): wish += basis.z
		if Input.is_key_pressed(KEY_A): wish -= basis.x
		if Input.is_key_pressed(KEY_D): wish += basis.x
		it.move = wish.normalized() if wish != Vector3.ZERO else Vector3.ZERO
		var trigger := Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
		it.aim = Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT)
		# A sprint is forwards, and the trigger or the sights end it.
		it.run = Input.is_key_pressed(KEY_SHIFT) and Input.is_key_pressed(KEY_W) \
				and not trigger and not it.aim
		it.crouch = Input.is_key_pressed(KEY_CTRL) or Input.is_key_pressed(KEY_C)
		it.grapple = Input.is_key_pressed(KEY_Q)
		it.jump_held = Input.is_key_pressed(KEY_SPACE)
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
