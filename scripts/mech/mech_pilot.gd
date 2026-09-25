class_name MechPilot
extends Node
## A player in a mech's cockpit: keys and mouse into TitanIntents, the camera at the
## cockpit, and the arm pointed where the crosshair lands. The pilot brain of the
## titan's contract (BoomerBorder's TitanPlayerBrain, rewritten without its
## PlayerRig: here the camera IS the pilot's look, as it is for PlayerController).
##
## WASD drives relative to the TORSO, not the look -- the Titanfall feel the motor
## exists to keep: turn your head and the chassis follows at its own pace.
## SHIFT sprints, Q dashes, LMB fires the arm, R reloads.

## The crosshair's reach, for converging the arm on what it points at.
const AIM_RANGE := 400.0

var mech: Mech
var camera: Camera3D
## Act on the keyboard without the mouse captured, for scripted gates.
var drive_uncaptured := false


func board(m: Mech, cam: Camera3D) -> void:
	mech = m
	camera = cam
	_follow()


func leave() -> void:
	if mech != null and is_instance_valid(mech):
		mech.intents.clear(mech.motor.torso_yaw)
		mech.aim_point = Vector3.INF
		mech.gun.set_trigger(false)
	mech = null
	camera = null


func is_piloting() -> bool:
	return mech != null and is_instance_valid(mech) and camera != null


func _active() -> bool:
	return drive_uncaptured or Input.mouse_mode == Input.MOUSE_MODE_CAPTURED


func _unhandled_input(event: InputEvent) -> void:
	if is_piloting() and _active() and event is InputEventKey and event.pressed \
			and not event.echo and event.keycode == KEY_R:
		mech.gun.reload()


func _process(_delta: float) -> void:
	if not is_piloting():
		return
	var it := mech.intents
	var r := camera.global_rotation
	it.aim_yaw = r.y
	it.aim_pitch = r.x
	if _active():
		var md := Vector2.ZERO
		if Input.is_key_pressed(KEY_W): md.y += 1.0
		if Input.is_key_pressed(KEY_S): md.y -= 1.0
		if Input.is_key_pressed(KEY_D): md.x += 1.0
		if Input.is_key_pressed(KEY_A): md.x -= 1.0
		it.move_dir = md.normalized() if md != Vector2.ZERO else Vector2.ZERO
		it.sprint = Input.is_key_pressed(KEY_SHIFT)
		it.dash = Input.is_key_pressed(KEY_Q)
		mech.gun.set_trigger(Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT))
	else:
		it.move_dir = Vector2.ZERO
		it.sprint = false
		it.dash = false
		mech.gun.set_trigger(false)
	_follow()


func _physics_process(_delta: float) -> void:
	if not is_piloting() or not camera.is_inside_tree():
		return
	# Where the crosshair lands: the arm converges on it.
	var from := camera.global_position
	var to := from - camera.global_transform.basis.z * AIM_RANGE
	var q := PhysicsRayQueryParameters3D.create(from, to, Layers.GUN_MASK,
			[mech.body.get_rid()] as Array[RID])
	var hit := camera.get_world_3d().direct_space_state.intersect_ray(q)
	mech.aim_point = hit.position if not hit.is_empty() else to


func _follow() -> void:
	camera.global_position = mech.cockpit_interpolated()
