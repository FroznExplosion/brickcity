class_name TankPilot
extends Node
## The player in a Tank (AIRoster.md R14, RO10): driver and gunner at once. The
## camera is the commander's eye on top of the turret and looks where the mouse
## does; the turret follows the look at its own pace (Tank.TURRET_TURN), so the
## gun lands where the crosshair is once it has come round.
##
## W / S drive forward and back, A / D turn the hull (on the spot as well),
## LMB fires the cannon (one round per Tank.MAIN_RELOAD), RMB the machine gun.

## The crosshair's reach, for where the turret should point.
const AIM_RANGE := 400.0

var tank: Tank
var camera: Camera3D
## Act on the keyboard without the mouse captured, for scripted gates.
var drive_uncaptured := false


func board(t: Tank, cam: Camera3D) -> void:
	tank = t
	camera = cam
	_follow()


func leave() -> void:
	if tank != null and is_instance_valid(tank):
		tank.release_player()
	tank = null
	camera = null


func is_driving() -> bool:
	return tank != null and is_instance_valid(tank) and camera != null


func _active() -> bool:
	return drive_uncaptured or Input.mouse_mode == Input.MOUSE_MODE_CAPTURED


func _process(_delta: float) -> void:
	if not is_driving():
		return
	if _active() and not tank.is_wrecked():
		var go := 0.0
		if Input.is_key_pressed(KEY_W): go += 1.0
		if Input.is_key_pressed(KEY_S): go -= 1.0
		var turn := 0.0
		if Input.is_key_pressed(KEY_A): turn += 1.0
		if Input.is_key_pressed(KEY_D): turn -= 1.0
		tank.throttle = go
		tank.steer = turn
		tank.fire_main = Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
		tank.fire_coax = Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT)
	else:
		tank.throttle = 0.0
		tank.steer = 0.0
		tank.fire_main = false
		tank.fire_coax = false
	_follow()


func _physics_process(_delta: float) -> void:
	if not is_driving() or not camera.is_inside_tree():
		return
	# Where the crosshair lands: the turret turns to it.
	var from := camera.global_position
	var to := from - camera.global_transform.basis.z * AIM_RANGE
	var q := PhysicsRayQueryParameters3D.create(from, to, Layers.GUN_MASK,
			[tank.get_rid()] as Array[RID])
	var hit := camera.get_world_3d().direct_space_state.intersect_ray(q)
	tank.aim_point = hit.position if not hit.is_empty() else to


func _follow() -> void:
	camera.global_position = tank.eye_interpolated()
