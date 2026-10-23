class_name PlanetWalker
extends CharacterBody3D

## Walking and flying on a planet (Docs/Planets.md 11, step 3): the radial
## controller of test 5 (tools/planet_radial_body.gd, after STA doc 05) with
## input, a fly mode to go to orbit and back, and the VoxelViewer the voxel
## ground streams round. Up comes from Gravity.up_at where it stands; the whole
## basis is rebuilt from it every tick (single-axis alignment drifts a strafe);
## up_direction is set to it so move_and_slide's floor is radial.
##
## Stands in for the pawn until the pawn is ported to local down (11.5 step 5).
## Mouse look only when the mouse is captured, never in a scripted pass
## (DebugCamera.hands_off).

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
var fly_speed := 20.0
## Held off the ground until the ground under it has streamed in.
var frozen := true
var pitch := 0.0
var up := Vector3.UP
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
		if event.button_index == MOUSE_BUTTON_LEFT and not DebugCamera.hands_off:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
			fly_speed = minf(fly_speed * 1.25, 4000.0)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			fly_speed = maxf(fly_speed / 1.25, 2.0)
	elif event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_yaw_by(-event.relative.x * 0.003)
		pitch = clampf(pitch - event.relative.y * 0.003, -1.5, 1.5)
	elif event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		elif event.keycode == KEY_F:
			flying = not flying
			velocity = Vector3.ZERO


func _yaw_by(a: float) -> void:
	var b := global_transform.basis
	global_transform.basis = Basis(up, a) * b


func _physics_process(delta: float) -> void:
	up = Gravity.up_at(global_position)
	var f := -global_transform.basis.z
	f = f - up * f.dot(up)
	if f.length_squared() < 1e-8:
		f = global_transform.basis.y
	f = f.normalized()
	if yaw_rate != 0.0:
		f = f.rotated(up, yaw_rate * delta)
	var r := f.cross(up)
	global_transform.basis = Basis(r, up, -f).orthonormalized()
	camera.rotation = Vector3(pitch, 0.0, 0.0)
	if frozen:
		velocity = Vector3.ZERO
		return
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
		# Along the camera's own axes, the speed on the wheel.
		var cb := camera.global_transform.basis
		var v := (-cb.z * w.y + cb.x * w.x + up * rise_in)
		if v.length_squared() > 1.0:
			v = v.normalized()
		velocity = v * fly_speed
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
	var across := r * w.x + f * w.y
	if across.length_squared() > 1.0:
		across = across.normalized()
	velocity = across * (RUN_SPEED if run else WALK_SPEED) + up * v_up
	up_direction = up
	move_and_slide()
