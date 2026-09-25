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

var pawn: Pawn
var camera: Camera3D
## Act on the keyboard without the mouse captured. For scripted gates, which
## synthesise keys and must not steal the cursor.
var drive_uncaptured := false


func possess(p: Pawn, cam: Camera3D) -> void:
	pawn = p
	camera = cam
	pawn.intents.clear()
	_sync_look()
	_follow()


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


func _process(_delta: float) -> void:
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
		it.run = Input.is_key_pressed(KEY_SHIFT)
		it.crouch = Input.is_key_pressed(KEY_CTRL) or Input.is_key_pressed(KEY_C)
		it.fire = Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
	else:
		it.move = Vector3.ZERO
		it.run = false
		it.crouch = false
		it.fire = false
	_follow()


func _sync_look() -> void:
	var r := camera.global_rotation
	pawn.intents.look_yaw = r.y
	pawn.intents.look_pitch = r.x


func _follow() -> void:
	camera.global_position = pawn.eye_interpolated()
