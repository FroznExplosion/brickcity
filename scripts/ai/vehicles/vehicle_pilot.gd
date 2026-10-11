class_name VehiclePilot
extends Node
## The player at the wheel of a Tank or a TransportTruck (AIRoster.md R14,
## RO10; Docs/AIVehicles.md 4).
##
## The camera follows behind and above, looking where the mouse does (Halo's
## vehicle camera), pulled in where a wall would come between; the view key
## (`vehicle_view`, C) puts it inside instead -- the tank's cupola, the truck's
## cab -- and back. In a tank the turret follows the look at its own pace
## (Tank.TURRET_TURN), so the gun lands where the crosshair is once it has come
## round: W / S drive, A / D turn the hull (on the spot as well), LMB the
## cannon, RMB the machine gun. A tank has two seats (`vehicle_seat`, Q, moves
## between them): at the wheel the player drives, and has the gun too unless one
## of theirs sits in the gunner's; in the gunner's they aim and shoot while one
## of theirs drives (TankBrain). In a truck W / S are throttle and brake, A / D
## steer -- only while it rolls; an APC drives as a truck and its turret follows
## the look as a tank's, LMB its gun. Those are the defaults: it reads the move, fire,
## aim, vehicle_view and vehicle_seat actions, rebound in Options > Controls.

## The crosshair's reach, for where the turret should point.
const AIM_RANGE := 400.0
## The chase camera: how far behind the look, and how high over the vehicle.
const CHASE_BACK := {"tank": 9.0, "truck": 7.5, "apc": 8.5}
const CHASE_UP := {"tank": 2.6, "truck": 2.4, "apc": 2.8}

var vehicle: CharacterBody3D
var camera: Camera3D
## Behind (Halo) or inside.
var chase := true
## Act on the keyboard without the mouse captured, for scripted gates.
var drive_uncaptured := false


func board(v: CharacterBody3D, cam: Camera3D) -> void:
	vehicle = v
	camera = cam
	_follow()


func leave() -> void:
	if vehicle != null and is_instance_valid(vehicle):
		vehicle.release_player()
	vehicle = null
	camera = null


func is_driving() -> bool:
	return vehicle != null and is_instance_valid(vehicle) and camera != null


func tank() -> Tank:
	return vehicle as Tank if is_driving() else null


func truck() -> TransportTruck:
	return vehicle as TransportTruck if is_driving() else null


func _kind() -> String:
	return "tank" if vehicle is Tank else String((vehicle as TransportTruck).kind)


## The vehicle, if the player has its gun (a tank's seat, an APC); else null.
func _gunned() -> CharacterBody3D:
	return vehicle if is_driving() and vehicle.has_method(&"player_guns") and vehicle.player_guns() else null


func _active() -> bool:
	return drive_uncaptured or Input.mouse_mode == Input.MOUSE_MODE_CAPTURED


func _unhandled_input(event: InputEvent) -> void:
	if not is_driving() or not _active() or event.is_echo():
		return
	if event.is_action_pressed(&"vehicle_view"):
		chase = not chase
	elif event.is_action_pressed(&"vehicle_seat") and tank() != null:
		var t := tank()
		if t.switch_seat():
			print("[city] %s" % seat_line(t))


## What the player's seat in `t` gives them, for the log.
static func seat_line(t: Tank) -> String:
	if t.player_seat == Tank.Seat.GUNNER:
		return "gunner's seat: LMB cannon, RMB machine gun -- %s" % \
				("one of yours drives" if t.ai_drives() else "nobody drives (Q: take the wheel)")
	if t.player_guns():
		return "driver's seat, and the gun: WASD drive, LMB cannon, RMB machine gun (Q: gunner's seat)"
	return "driver's seat: WASD drive -- one of yours has the gun (Q: swap with them)"


func _process(_delta: float) -> void:
	if not is_driving():
		return
	var go := 0.0
	var turn := 0.0
	var t := tank()
	if _active() and not vehicle.is_wrecked():
		if Input.is_action_pressed(&"move_forward"): go += 1.0
		if Input.is_action_pressed(&"move_back"): go -= 1.0
		if Input.is_action_pressed(&"move_left"): turn += 1.0
		if Input.is_action_pressed(&"move_right"): turn -= 1.0
	if t == null or t.player_drives():
		vehicle.throttle = go
		vehicle.steer = turn
	var gv := _gunned()
	if gv != null:
		var on: bool = _active() and not gv.is_wrecked()
		gv.fire_main = on and Input.is_action_pressed(&"fire")
		gv.fire_coax = on and Input.is_action_pressed(&"aim")
	_follow()


func _physics_process(_delta: float) -> void:
	var t := _gunned()
	if t == null or not camera.is_inside_tree():
		return
	# Where the crosshair lands: the turret turns to it.
	var from := camera.global_position
	var to := from - camera.global_transform.basis.z * AIM_RANGE
	var q := PhysicsRayQueryParameters3D.create(from, to, Layers.GUN_MASK, _exclude())
	var hit := camera.get_world_3d().direct_space_state.intersect_ray(q)
	t.aim_point = hit.position if not hit.is_empty() else to


## The vehicle and whoever rides on it: the crosshair looks past them.
func _exclude() -> Array[RID]:
	var ex: Array[RID] = [vehicle.get_rid()]
	var deck: VehicleDeck = vehicle.rodeo
	if deck != null:
		for r in deck.riders:
			if r != null and is_instance_valid(r):
				ex.append((r as Pawn).body.get_rid())
		if deck.rider != null and is_instance_valid(deck.rider):
			ex.append(deck.rider.body.get_rid())
	return ex


func _follow() -> void:
	var inside: Vector3 = vehicle.eye_interpolated()
	if not chase or not camera.is_inside_tree():
		camera.global_position = inside
		return
	var k := _kind()
	var pivot: Vector3 = vehicle.get_global_transform_interpolated().origin \
			+ Vector3.UP * (float(CHASE_UP[k]) - (Tank.HEIGHT * 0.5 if vehicle is Tank else 0.0))
	var back := camera.global_transform.basis.z
	back.y = maxf(back.y, -0.2)
	var want := pivot + back.normalized() * float(CHASE_BACK[k])
	# Pulled in where a wall comes between, as a spring arm does.
	var q := PhysicsRayQueryParameters3D.create(pivot, want, Layers.WORLD | Layers.STRUCTURE, _exclude())
	var hit := camera.get_world_3d().direct_space_state.intersect_ray(q)
	if not hit.is_empty():
		want = (hit.position as Vector3) - back.normalized() * 0.3
	camera.global_position = want
