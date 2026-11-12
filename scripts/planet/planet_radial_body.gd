extends CharacterBody3D

## A walker on local down, prototype (Docs/Planets.md 10b, tests 5 and 6): STA
## doc 05's radial controller with our pawn's numbers. Not the game's pawn --
## that is ~185 places of `.y` and Vector3.UP to port -- but the core every
## port needs: up from where it stands, the WHOLE basis rebuilt from it each
## tick (single-axis alignment is what makes strafing drift), `up_direction`
## set to it so move_and_slide's floor and slope tests are radial, gravity and
## jumps along it.
##
## Driven by `wish` (x strafe right, y forward, both -1..1), `yaw_rate`
## (rad/s) and `jump`. The camera hangs at eye height and only pitches.

const BRICK_M := 0.42
const WALK_SPEED := BRICK_M * 6.7
const JUMP_SPEED := 4.2
const GRAVITY := 20.0
const HEIGHT := BRICK_M * 4.0
const RADIUS := 0.35
const EYE := HEIGHT - 0.2

var centre := Vector3.ZERO     ## the planet's centre
var wish := Vector2.ZERO
var yaw_rate := 0.0
var jump := false
var speed := WALK_SPEED
var camera: Camera3D
var pitch := 0.0
var up := Vector3.UP
var on_floor_ticks := 0
var air_ticks := 0


func _init() -> void:
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = RADIUS
	cap.height = HEIGHT
	cs.shape = cap
	cs.position = Vector3(0.0, HEIGHT * 0.5, 0.0)
	add_child(cs)
	floor_max_angle = deg_to_rad(50.0)
	floor_snap_length = 0.3
	camera = Camera3D.new()
	camera.position = Vector3(0.0, EYE, 0.0)
	camera.fov = 75.0
	add_child(camera)


## Stand at `p` (feet) on the sphere, facing `forward` (made tangent).
func place(p: Vector3, forward: Vector3) -> void:
	up = (p - centre).normalized()
	var f := (forward - up * forward.dot(up)).normalized()
	global_transform = Transform3D(Basis(f.cross(up), up, -f), p)
	velocity = Vector3.ZERO


func _physics_process(delta: float) -> void:
	up = (global_position - centre).normalized()
	# The whole basis from the new up and the old forward, then the yaw.
	var f := -global_transform.basis.z
	f = f - up * f.dot(up)
	if f.length_squared() < 1e-8:
		f = global_transform.basis.y   # looking straight along up: fall back
	f = f.normalized()
	if yaw_rate != 0.0:
		f = f.rotated(up, yaw_rate * delta)
	var r := f.cross(up)
	global_transform.basis = Basis(r, up, -f).orthonormalized()
	# Along up: fall, land, jump. Across: walk, at once.
	var v_up := velocity.dot(up)
	if is_on_floor():
		# Pressed into the floor a little, so move_and_slide meets it every
		# tick: at exactly zero it touches nothing, and is_on_floor flickers.
		v_up = JUMP_SPEED if jump else -1.0
	else:
		v_up -= GRAVITY * delta
	jump = false
	var across := (r * wish.x + f * wish.y)
	if across.length_squared() > 1.0:
		across = across.normalized()
	velocity = across * speed + up * v_up
	up_direction = up
	move_and_slide()
	if is_on_floor():
		on_floor_ticks += 1
	else:
		air_ticks += 1
	camera.rotation = Vector3(pitch, 0.0, 0.0)
