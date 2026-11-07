extends Camera3D
class_name PlayerCamera

## The player's eye: mouse-look, the frame it is measured in, the aim assist
## that slows it over a target, and who owns the mouse. What a pawn, a mech's
## cockpit or a vehicle seat drives (PlayerController, PlayerView, MechPilot,
## CockpitView, VehiclePilot) -- and all they need: no flying, no walking body.
##
## The free camera and its debug walker are DebugCamera, which extends this. A
## scene with no free camera (the planet) makes a PlayerCamera; one that has
## both (the city) makes a DebugCamera, and the player code sees a PlayerCamera
## either way.

const LOOK_SENSITIVITY := 0.0022

## Off for automated screenshot runs, which must not steal the mouse.
var capture_mouse := true
## A click takes the mouse. The building workshop says no: its camera (the editor kit's
## WkCamera) takes and gives
## the mouse, so a click only ever does what the tool in hand does.
var click_captures := true

var _yaw := 0.0
var _pitch := 0.0
## Mouse-look speed, multiplied in: a player aiming down the sights turns slower
## (PlayerView). 1 is the tuned default.
var look_scale := 1.0
## The player's own sensitivity and pitch inversion (the Options menu, through
## BrickcityMenuHost). Static: one player, every camera.
static var look_mult := 1.0
## The player's aim assist (AimAssist), when on foot: it slows the look over a target.
var assist: AimAssist
static var invert_y := false
## Lean, radians: the tilt of a wall-run. Kept through mouse-look, which would
## otherwise level it on the next motion event.
var roll := 0.0
var _captured := false


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


## Never take the real mouse, whatever asks. Set for a window nobody is at: a
## test window (TestWindow) or a scripted pass (CityScene). The camera still
## counts itself captured -- a pass's synthetic click turns its look and its
## keys on as a real one would -- but the cursor stays the user's, free and
## where they left it. This is the only place in the game that captures it.
static var hands_off := false


func _set_captured(on: bool) -> void:
	_captured = on
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if on and not hands_off \
			else Input.MOUSE_MODE_VISIBLE


## Mouse-look in `_input`, ahead of the GUI. With the mouse captured its
## position is pinned to the middle of the window, and any Control that
## happens to sit there -- a HUD panel, at some window size -- would otherwise
## take every motion event first, and looking around simply stopped.
func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and _captured:
		var k := LOOK_SENSITIVITY * look_scale * look_mult
		var d := Vector2(-event.relative.x * k, -event.relative.y * k * (-1.0 if invert_y else 1.0))
		if assist != null and is_instance_valid(assist):
			d = assist.filter_look(d)
		add_look(d.x, d.y)


## The frame the look is measured in (Docs/Planets.md 11.7): the identity in
## the flat game, where the look is the camera's own rotation exactly as
## before; on a planet the possessed pawn's carried basis, so yaw turns about
## the local up and pitch is from the local horizon.
var frame := Basis.IDENTITY


## The look as (pitch, yaw, roll) in `frame`.
func look_angles() -> Vector3:
	if frame == Basis.IDENTITY:
		return rotation
	return (frame.inverse() * global_transform.basis.orthonormalized()).get_euler()


## Measure the look in a new frame, keeping the angles: the camera turns with it.
func set_frame(f: Basis) -> void:
	if f == frame:
		return
	var e := look_angles()
	frame = f
	if frame == Basis.IDENTITY:
		rotation = e
	else:
		global_transform.basis = frame * Basis.from_euler(e)


## Turn by `yaw` and `pitch` radians -- the mouse, or a gun's recoil. From where
## the camera points NOW, so a scripted look_at in between is kept, not undone.
func add_look(yaw: float, pitch: float) -> void:
	if frame != Basis.IDENTITY:
		var e := look_angles()
		_yaw = e.y + yaw
		_pitch = clampf(e.x + pitch, -1.5, 1.5)
		global_transform.basis = frame * Basis.from_euler(Vector3(_pitch, _yaw, roll))
		return
	_yaw = rotation.y + yaw
	_pitch = clampf(rotation.x + pitch, -1.5, 1.5)
	rotation = Vector3(_pitch, _yaw, roll)


func set_roll(r: float) -> void:
	roll = r
	if frame != Basis.IDENTITY:
		var e := look_angles()
		global_transform.basis = frame * Basis.from_euler(Vector3(e.x, e.y, r))
		return
	rotation.z = r


func _unhandled_input(event: InputEvent) -> void:
	# A CLICK takes the mouse, not the wheel: scrolling a menu past its end
	# used to fall through to here, capture the mouse and hide the cursor with
	# the menu still open.
	if event is InputEventMouseButton and event.pressed and not _captured and click_captures \
			and event.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
		_set_captured(true)
	elif event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
		# Where the pause menu opens, Escape is its key (MenuManager frees the
		# mouse and gives it back); elsewhere it still frees and takes the mouse.
		var mm := get_node_or_null(^"/root/MenuManager")
		if mm == null or not mm.can_pause():
			_set_captured(not _captured)
