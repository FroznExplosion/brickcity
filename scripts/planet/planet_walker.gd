class_name PlanetWalker
extends CharacterBody3D

## Walking and flying on a planet (Docs/Planets.md 11, step 3): the radial
## controller of test 5 (tools/planet_radial_body.gd, after STA doc 05) with
## input, a fly mode to go to orbit and back, and the VoxelViewer the voxel
## ground streams round. Up comes from Gravity.up_at where it stands; the whole
## basis is rebuilt from it every tick (single-axis alignment drifts a strafe);
## up_direction is set to it so move_and_slide's floor is radial.
##
## Coming into a new down -- off a ship's deck into a planet's air -- the body
## rights itself at Pawn.REORIENT_RATE rather than in a tick; where nothing pulls
## (Gravity.pulls_at) it floats, as the pawn does (Docs/RoomModules.md 7.12).
##
## Stands in for the pawn until the pawn is ported to local down (11.5 step 5).
## Mouse look only when the mouse is captured, never in a scripted pass
## (PlayerCamera.hands_off).

const BRICK_M := 0.42
const WALK_SPEED := BRICK_M * 6.7
const RUN_SPEED := BRICK_M * 13.3
const JUMP_SPEED := 4.2
const GRAVITY := 20.0
const HEIGHT := BRICK_M * 4.0
const RADIUS := 0.35
const EYE := HEIGHT - 0.2

var camera: Camera3D
var viewer: VoxelViewer
var flying := false
var fly_speed := 50.0
## Shift held while flying: this fast, or ten times the wheel's speed if that is more.
const FAST_FLY := 500.0
## Flying between bodies (Planets.md 11.12): the velocity carried besides the
## walker's own -- a frame handoff's kick goes into it -- let go toward
## `match_velocity` (the body it is near, PlanetSystem) over MATCH_TIME, like a
## flight computer; Shift cruises faster the higher it is over the nearest
## ground (`reach`), CRUISE of it a second, so a crossing takes seconds and an
## approach slows itself.
var inertia := Vector3.ZERO
var match_velocity := Vector3.ZERO
## Pushed from outside, m/s^2 -- air rushing out of a hole in a hull (Docs/Hulls.md
## 4): it builds a drift that the floor takes back off fast and the air slowly.
var push := Vector3.ZERO
var _drift := Vector3.ZERO
const DRIFT_FLOOR := 0.25
const DRIFT_AIR := 3.0
var reach := 0.0
const MATCH_TIME := 3.0
const CRUISE := 0.5
const CRUISE_MAX := 300000.0
## Held off the ground until the ground under it has streamed in.
var frozen := true
var pitch := 0.0
## The mouse's yaw since the last physics step, turned there as pitch is: the
## body and its camera are interpolated, and must not move between steps.
var _turn := 0.0
var up := Vector3.UP
## Nothing pulls where it is: it drifts, the move a suit's thrust (PawnMoves FLOAT).
var floating := false
## Scripted input, for passes: x strafe, y forward (-1..1); yaw rad/s; rise
## (-1..1) in fly mode; jump once.
var wish := Vector2.ZERO
var yaw_rate := 0.0
var rise := 0.0
var jump := false
var scripted := false


func _init() -> void:
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = RADIUS
	cap.height = HEIGHT
	cs.shape = cap
	cs.position = Vector3(0.0, HEIGHT * 0.5, 0.0)
	add_child(cs)
	# The ground (layer 1) and the buildings' shells (STRUCTURE).
	collision_mask = 1 | Layers.STRUCTURE
	floor_max_angle = deg_to_rad(50.0)
	floor_snap_length = 0.3
	camera = Camera3D.new()
	camera.position = Vector3(0.0, EYE, 0.0)
	camera.fov = 75.0
	camera.near = 0.05
	camera.far = 200000.0
	add_child(camera)
	viewer = VoxelViewer.new()
	viewer.view_distance = 2048
	add_child(viewer)


## Stand at `feet` (world) facing `forward` (made tangent).
func place(feet: Vector3, forward: Vector3) -> void:
	up = Gravity.up_at(feet)
	var f := (forward - up * forward.dot(up)).normalized()
	global_transform = Transform3D(Basis(f.cross(up), up, -f), feet)
	velocity = Vector3.ZERO
	reset_physics_interpolation()


func _unhandled_input(event: InputEvent) -> void:
	if scripted:
		return
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT and not PlayerCamera.hands_off:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
			fly_speed = minf(fly_speed * 1.25, 4000.0)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			fly_speed = maxf(fly_speed / 1.25, 2.0)
	elif event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_turn -= event.relative.x * 0.003
		pitch = clampf(pitch - event.relative.y * 0.003, -1.5, 1.5)
	elif event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		elif event.keycode == KEY_F:
			flying = not flying
			velocity = Vector3.ZERO


func _physics_process(delta: float) -> void:
	floating = not flying and not Gravity.pulls_at(global_position)
	# The body's own up: turned toward the down here, a tick's worth at most --
	# at once flying -- and kept where nothing pulls.
	var body_up := global_transform.basis.y.normalized()
	if floating:
		up = body_up
	else:
		up = Gravity.up_at(global_position)
		var rate := INF if flying or frozen else Pawn.REORIENT_RATE * delta
		body_up = Gravity.carry_toward(global_transform.basis.orthonormalized(), up, rate).y.normalized()
	var f := -global_transform.basis.z
	f = f - body_up * f.dot(body_up)
	if f.length_squared() < 1e-8:
		f = global_transform.basis.y
	f = f.normalized()
	var turn := _turn + yaw_rate * delta
	_turn = 0.0
	if turn != 0.0:
		f = f.rotated(body_up, turn)
	var r := f.cross(body_up)
	global_transform.basis = Basis(r, body_up, -f).orthonormalized()
	camera.rotation = Vector3(pitch, 0.0, 0.0)
	if frozen:
		velocity = Vector3.ZERO
		_drift = Vector3.ZERO
		return
	_drift += push * delta
	_drift *= exp(-delta / (DRIFT_FLOOR if is_on_floor() and not flying else DRIFT_AIR))
	var w := wish
	var run := false
	var rise_in := rise
	if not scripted:
		w = Vector2(float(Input.is_key_pressed(KEY_D)) - float(Input.is_key_pressed(KEY_A)),
				float(Input.is_key_pressed(KEY_W)) - float(Input.is_key_pressed(KEY_S)))
		run = Input.is_key_pressed(KEY_SHIFT)
		rise_in = float(Input.is_key_pressed(KEY_SPACE)) - float(Input.is_key_pressed(KEY_CTRL))
		if not flying and Input.is_key_pressed(KEY_SPACE):
			jump = true
	if flying:
		# Along the camera's own axes, the speed on the wheel (Shift: fast).
		var cb := camera.global_transform.basis
		var v := (-cb.z * w.y + cb.x * w.x + up * rise_in)
		if v.length_squared() > 1.0:
			v = v.normalized()
		var fast := maxf(maxf(FAST_FLY, fly_speed * 10.0), minf(reach * CRUISE, CRUISE_MAX))
		inertia = inertia.lerp(match_velocity, 1.0 - exp(-delta / MATCH_TIME))
		velocity = v * (fast if run else fly_speed) + inertia + _drift
		up_direction = up
		move_and_slide()
		return
	if floating:
		var want := r * w.x + f * w.y + up * rise_in
		if want.length_squared() > 1.0:
			want = want.normalized()
		if want == Vector3.ZERO:
			velocity *= exp(-PawnMoves.FLOAT_DAMP * delta)
		else:
			var nv := velocity + want * PawnMoves.FLOAT_ACCEL * delta
			var cap := maxf(velocity.length(), PawnMoves.FLOAT_SPEED)
			velocity = nv.normalized() * cap if nv.length() > cap else nv
		jump = false
		up_direction = up
		move_and_slide()
		return
	var v_up := velocity.dot(up)
	if is_on_floor():
		# Pressed into the floor a little: at exactly zero move_and_slide meets
		# nothing on a convex ground and is_on_floor flickers (test 5).
		v_up = JUMP_SPEED if jump else -1.0
	else:
		v_up -= GRAVITY * delta
	jump = false
	inertia = Vector3.ZERO
	var across := r * w.x + f * w.y
	if across.length_squared() > 1.0:
		across = across.normalized()
	velocity = across * (RUN_SPEED if run else WALK_SPEED) + up * v_up + _drift
	up_direction = up
	move_and_slide()
