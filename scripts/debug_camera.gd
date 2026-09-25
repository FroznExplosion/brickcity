extends Camera3D
class_name DebugCamera

## Free-fly camera for M0, with a walking mode bolted on. Not a gameplay camera
## and never will be — the real rig is owned by a player slot
## (Reference/mvs-c.md section 2), not parented into anything. This exists so a
## human can look at a tower, and now so a human can stand next to one.

const SPEED := 6.0
const SPEED_FAST := 30.0
const SPEED_SLOW := 1.5
const LOOK_SENSITIVITY := 0.0022

## Walking. Metres and seconds, and every length here is derived from the grid
## rather than from a human: a stud is 0.35 m and a plate 0.14 m, so a brick
## course is 0.42 m and the figure that walks around this city is measured in
## bricks like everything else it walks on.
const PLATE_M := 0.14
const BRICK_M := PLATE_M * 3.0
## Four bricks: 38.4 mm in print, 1.68 m here. The height real brick buildings
## are designed around, so what is built here fits what is built for them
## (Docs/Parts/README.md section 5). The SIZE only -- the figure's shape is our
## own: a bigger head and a slimmer body than the trademarked one.
const BODY_HEIGHT := BRICK_M * 4.0
## The head is a big part of that: a brick and a quarter of it, where the
## trademarked figure's is under one. Eyes at its middle.
const HEAD_HEIGHT := BRICK_M * 1.25
## Crouched: a whole brick shorter, which is exactly the clearance the floor
## under you costs.
##
## A room is a fixed number of courses tall, so what you are standing ON decides
## whether you fit: a tile floor is one plate, a brick is three, and the two
## plates between them are the difference between walking under a beam and being
## stopped dead by it. A brick of crouch covers that with a plate to spare, and
## it covers a doorway one course too low as well.
const CROUCH_HEIGHT := BODY_HEIGHT - BRICK_M
## Slimmer than a two-stud figure: a stud and a half across (0.525 m), where
## a figure-sized one is nearly two.
const BODY_RADIUS := 0.35 * 0.75
const EYE_HEIGHT := BODY_HEIGHT - HEAD_HEIGHT * 0.5
## Speeds scale with the body. Kept in bricks per second so they stay honest if
## the figure is ever resized again: 10, 20 and 4.3 courses a second.
const WALK_SPEED := BRICK_M * 6.7
const RUN_SPEED := BRICK_M * 13.3
const CROUCH_SPEED := BRICK_M * 2.9
## Clears one course and no more, at this gravity.
const JUMP_SPEED := 4.2
const GRAVITY := 20.0
## Exactly one brick course, plus a hair. A city full of rubble is a city full
## of kerbs, and a body that stops dead on any of them cannot cross its own
## debris -- so a step up to one course is walked over rather than jumped.
const STEP_HEIGHT := BRICK_M + 0.03
const DOUBLE_TAP_MS := 300

## Off for automated screenshot runs, which must not steal the mouse.
var capture_mouse := true
## Whether SPACE-SPACE may drop the camera into a body. Off by default: the
## workshop is a place you fly around a baseplate, not one you walk on.
var allow_walk := false
## Run movement and the SPACE handling without owning the mouse. A scripted pass
## drives this camera with synthesised keys and must not steal the cursor to do
## it -- the `--walk` gate is the only caller.
var drive_uncaptured := false
## Whether E climbs as well as SPACE. The workshop turns it off: there, holding E
## locks the build plane, and a camera drifting upward while you do it would move
## the very thing you are aiming at.
var e_climbs := true

## Emitted when the mode changes, so a HUD can say which one it is in.
signal mode_changed(walking: bool)

var _yaw := 0.0
var _pitch := 0.0
var _captured := false

var _walking := false
var _body: CharacterBody3D = null
var _last_space_ms := 0
var _capsule: CapsuleShape3D = null
var _height := BODY_HEIGHT
## True while the body is crouched because it had to be, rather than because
## anyone asked. Read by the HUD, and by the gate.
var _auto_crouched := false


func _ready() -> void:
	# This camera is driven by input in _process, not by physics. With
	# physics_interpolation on, Godot warns that an interpolated Camera3D is
	# being moved from outside the physics step -- correctly, because there is
	# nothing between ticks to interpolate. Opting out silences it and is what
	# any input-driven camera wants.
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_yaw = rotation.y
	_pitch = rotation.x
	if capture_mouse:
		_set_captured(true)


func is_walking() -> bool:
	return _walking


func is_crouched() -> bool:
	return _height < BODY_HEIGHT


## Crouching nobody asked for: the ceiling did it.
func is_auto_crouched() -> bool:
	return _auto_crouched


## The body, once walking has created one. Null while the camera has only ever
## flown.
func body() -> CharacterBody3D:
	return _body


## Is this camera listening at all? Mouse capture is the normal answer; a
## scripted pass is the other one.
func _active() -> bool:
	return _captured or drive_uncaptured


func _set_captured(on: bool) -> void:
	_captured = on
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if on else Input.MOUSE_MODE_VISIBLE


## Mouse-look in `_input`, ahead of the GUI. With the mouse captured its
## position is pinned to the middle of the window, and any Control that
## happens to sit there -- a HUD panel, at some window size -- would otherwise
## take every motion event first, and looking around simply stopped.
func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and _captured:
		_yaw -= event.relative.x * LOOK_SENSITIVITY
		_pitch = clampf(_pitch - event.relative.y * LOOK_SENSITIVITY, -1.5, 1.5)
		rotation = Vector3(_pitch, _yaw, 0.0)


func _unhandled_input(event: InputEvent) -> void:
	# A CLICK takes the mouse, not the wheel: scrolling a menu past its end
	# used to fall through to here, capture the mouse and hide the cursor with
	# the menu still open.
	if event is InputEventMouseButton and event.pressed and not _captured \
			and event.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
		_set_captured(true)
	elif event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			_set_captured(not _captured)
		elif event.keycode == KEY_SPACE and _active():
			_space_pressed()


## SPACE is climb (fly) or jump (walk); SPACE twice quickly swaps the two.
##
## The first tap of a double tap still jumps. That is deliberate: making a tap
## wait 300 ms to find out whether it was half of a double would put that delay
## on every jump, and a jump nobody asked for costs nothing.
func _space_pressed() -> void:
	var now := Time.get_ticks_msec()
	if allow_walk and now - _last_space_ms <= DOUBLE_TAP_MS:
		_last_space_ms = 0
		set_walking(not _walking)
		return
	_last_space_ms = now
	if _walking and _body != null and _body.is_on_floor():
		_body.velocity.y = JUMP_SPEED


func set_walking(on: bool) -> void:
	if on == _walking:
		return
	_walking = on
	if on:
		_ensure_body()
		_body.global_position = global_position - Vector3.UP * _eye_offset()
		_body.velocity = Vector3.ZERO
		_body.process_mode = Node.PROCESS_MODE_INHERIT
	elif _body != null:
		# There is nothing to collide with while flying, and a body left in the
		# space still takes contacts from everything that lands on it.
		_body.process_mode = Node.PROCESS_MODE_DISABLED
		_body.global_position = Vector3(0.0, -10000.0, 0.0)
	mode_changed.emit(_walking)


## Distance from the body's centre -- a capsule's origin -- up to the eye. The
## eye sits a plate below the top of the head, whatever height the body is.
func _eye_offset() -> float:
	return _height * 0.5 - PLATE_M


## Resize the capsule with the FEET planted. A capsule grows about its centre,
## so changing the height alone would sink the body into the floor or lift it
## off -- the origin has to move by half the difference.
func _set_height(h: float) -> void:
	if is_equal_approx(h, _height) or _capsule == null:
		return
	var delta := h - _height
	_height = h
	_capsule.height = h
	if _body != null:
		_body.global_position.y += delta * 0.5


## Would the body fit at `h` if it moved by `motion` from where it is?
##
## The capsule has to be the size being asked about for the test to mean
## anything, so it is resized, tested and put back. Two shape casts a frame in
## the worst case, and only while walking.
func _fits(h: float, motion: Vector3) -> bool:
	if _body == null:
		return true
	var was := _height
	var xf := _body.global_transform
	xf.origin.y += (h - was) * 0.5
	_capsule.height = h
	var blocked := _body.test_move(xf, motion)
	_capsule.height = was
	return not blocked


func _ensure_body() -> void:
	if _body != null:
		return
	_body = CharacterBody3D.new()
	_body.name = "PlayerBody"
	# Driven from _process at render rate like the rest of this camera, so it
	# must not be interpolated on top of that.
	_body.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_body.collision_layer = Layers.PAWN
	_body.collision_mask = Layers.PAWN_MASK
	_body.floor_max_angle = deg_to_rad(50.0)
	_body.floor_snap_length = STEP_HEIGHT
	_body.slide_on_ceiling = true
	var shape := CollisionShape3D.new()
	_capsule = CapsuleShape3D.new()
	_capsule.height = BODY_HEIGHT
	_capsule.radius = BODY_RADIUS
	_height = BODY_HEIGHT
	shape.shape = _capsule
	_body.add_child(shape)
	get_parent().add_child(_body)


func _process(delta: float) -> void:
	if not _active():
		return
	if _walking:
		_walk(delta)
	else:
		_fly(delta)


func _fly(delta: float) -> void:
	var dir := Vector3.ZERO
	if Input.is_key_pressed(KEY_W): dir -= basis.z
	if Input.is_key_pressed(KEY_S): dir += basis.z
	if Input.is_key_pressed(KEY_A): dir -= basis.x
	if Input.is_key_pressed(KEY_D): dir += basis.x
	if (e_climbs and Input.is_key_pressed(KEY_E)) or Input.is_key_pressed(KEY_SPACE): dir += Vector3.UP
	if Input.is_key_pressed(KEY_Q) or Input.is_key_pressed(KEY_CTRL): dir -= Vector3.UP

	var speed := SPEED
	if Input.is_key_pressed(KEY_SHIFT):
		speed = SPEED_FAST
	elif Input.is_key_pressed(KEY_ALT):
		speed = SPEED_SLOW

	if dir != Vector3.ZERO:
		position += dir.normalized() * speed * delta


## Walking runs at RENDER rate, not at the 30 Hz physics tick.
##
## `move_and_slide` takes its delta from whichever frame it is called in, so
## this is legal -- and it is what keeps a walking camera smooth. Driving the
## body from `_physics_process` instead would move the eye thirty times a second
## under a sixty frame picture, and the camera cannot be interpolated out of
## that because it is the thing mouse-look writes to every frame.
func _walk(delta: float) -> void:
	if _body == null:
		return
	var wish := Vector3.ZERO
	if Input.is_key_pressed(KEY_W): wish -= basis.z
	if Input.is_key_pressed(KEY_S): wish += basis.z
	if Input.is_key_pressed(KEY_A): wish -= basis.x
	if Input.is_key_pressed(KEY_D): wish += basis.x
	wish.y = 0.0
	if wish != Vector3.ZERO:
		wish = wish.normalized()

	# Stand if there is room to, crouch if there is not, and let CTRL ask for it
	# either way. The test is along the motion rather than in place, so walking
	# at a beam ducks under it instead of stopping dead in front of it -- which
	# is the whole bug: a figure that fits on a tile floor does not fit standing
	# on a brick, and had no way to say so.
	var wants_crouch := Input.is_key_pressed(KEY_CTRL) or Input.is_key_pressed(KEY_ALT)
	var step := wish * WALK_SPEED * delta
	_auto_crouched = false
	if wants_crouch:
		_set_height(CROUCH_HEIGHT)
	elif _fits(BODY_HEIGHT, step):
		_set_height(BODY_HEIGHT)
	elif _fits(CROUCH_HEIGHT, step):
		_set_height(CROUCH_HEIGHT)
		_auto_crouched = true

	var speed := WALK_SPEED
	if is_crouched():
		speed = CROUCH_SPEED
	elif Input.is_key_pressed(KEY_SHIFT):
		speed = RUN_SPEED

	var before := _body.global_position
	_body.velocity.x = wish.x * speed
	_body.velocity.z = wish.z * speed
	if _body.is_on_floor():
		_body.velocity.y = minf(_body.velocity.y, 0.0)
	else:
		_body.velocity.y -= GRAVITY * delta
	_body.move_and_slide()

	# Stopped dead by something low -- a kerb of rubble, a course of brick, the
	# lip of a floor slab. Step over it rather than making the player jump.
	if wish != Vector3.ZERO and _body.is_on_wall():
		var wanted := Vector3(wish.x, 0.0, wish.z) * speed * delta
		var moved := _body.global_position - before
		if Vector2(moved.x, moved.z).length() < Vector2(wanted.x, wanted.z).length() * 0.5:
			_step_over(wanted)

	global_position = _body.global_position + Vector3.UP * _eye_offset()


## Raise, move, settle. Keeps the result only if the body actually came down on
## something -- otherwise that was a ledge to walk off, not a step to climb.
func _step_over(motion: Vector3) -> bool:
	var start := _body.global_transform
	if _body.test_move(start, Vector3.UP * STEP_HEIGHT):
		# No headroom to rise into. Crouching is what makes a step up onto a
		# brick possible under a low ceiling, so try it before giving up.
		if _height <= CROUCH_HEIGHT or not _fits(CROUCH_HEIGHT, Vector3.UP * STEP_HEIGHT):
			return false
		_set_height(CROUCH_HEIGHT)
		_auto_crouched = true
		start = _body.global_transform
		if _body.test_move(start, Vector3.UP * STEP_HEIGHT):
			return false
	var lifted := start.translated(Vector3.UP * STEP_HEIGHT)
	if _body.test_move(lifted, motion):
		return false
	_body.global_transform = lifted.translated(motion)
	_body.move_and_collide(Vector3.DOWN * (STEP_HEIGHT + 0.02))
	if _body.global_position.y > start.origin.y + STEP_HEIGHT * 0.9:
		_body.global_transform = start
		return false
	return true
