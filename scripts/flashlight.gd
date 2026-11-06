class_name Flashlight
extends SpotLight3D
## The player's flashlight (Docs/Lighting.md 6.4): a spot on the camera, the
## `flashlight` action (L) turns it on and off. Off at the start, so a scripted
## pass's pictures are as they were.
##
## It sits a hand's width right of and below the eye, as a light held or worn
## at the chest would: from the eye itself every shadow it threw would hide
## straight behind what threw it, and the beam would look flat.
##
## One per scene: `mount(camera)` puts it on whichever camera the player looks
## through (the city's, the planet's).

## Metres the beam reaches, its half-angle in degrees, and how bright.
const RANGE := 28.0
const ANGLE := 24.0
const ENERGY := 6.0
## Warm white, a little yellower than daylight.
const COLOUR := Color(1.0, 0.94, 0.82)
## Where it sits on the camera (right, down, back), metres.
const OFFSET := Vector3(0.16, -0.14, 0.0)

## Is a flashlight on? The live one's, for the HUD and the gates.
static var on := false
static var _live: Flashlight


## A flashlight on `cam`, off. Again on the same camera: the one already there.
static func mount(cam: Camera3D) -> Flashlight:
	for c in cam.get_children():
		if c is Flashlight:
			return c
	var f := Flashlight.new()
	f.name = "Flashlight"
	cam.add_child(f)
	return f


func _ready() -> void:
	position = OFFSET
	light_color = COLOUR
	light_energy = ENERGY
	light_specular = 0.6
	spot_range = RANGE
	spot_angle = ANGLE
	spot_angle_attenuation = 0.6
	spot_attenuation = 1.4
	# A soft edge on the cone and real shadows: what makes a torch read as one.
	shadow_enabled = true
	shadow_blur = 1.5
	shadow_bias = 0.04
	shadow_normal_bias = 1.0
	# Rides the camera, which moves in _process: nothing to interpolate.
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_live = self
	set_on(false)


func _exit_tree() -> void:
	if _live == self:
		_live = null
		on = false


func set_on(v: bool) -> void:
	visible = v
	if _live == self:
		on = v


func toggle() -> void:
	set_on(not visible)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_echo() or not InputMap.has_action(&"flashlight"):
		return
	if event.is_action_pressed(&"flashlight"):
		toggle()
		get_viewport().set_input_as_handled()
