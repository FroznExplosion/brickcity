class_name WorkshopView
extends RefCounted

## The building workshop's two cameras (Docs/BuildTools.md section 10).
##
##   orbit   the cursor is free and tools work where it points, as Godot's viewport: MMB
##           drag orbits round what is under the cursor, Shift + MMB pans, the wheel zooms
##           toward the cursor (Shift + wheel: the toolbar), RMB held and moved looks round.
##           WASD flies. A plain RMB or MMB click does what it always did.
##   fps     the mouse looks, tools work at the dot. Hold Alt for the cursor, to reach the
##           rail; a click in the scene then does nothing, and letting go is FPS again.
##
## Y (or the rail's FPS button) swaps them. The mouse is taken and given back here and
## nowhere else: the camera's click-to-capture is off, so a click only ever does what the
## tool does.

const CLICK_PX := 6.0
const ORBIT_RAD_PER_PX := 0.006

var ws    ## the workshop
var mode := "orbit"
## Replaying a plain RMB click to the workshop: not this file's.
var replaying := false

var _cam
var _mmb := false
var _rmb := false
var _looking := false
var _moved := 0.0
var _pivot := Vector3.ZERO
var _rmb_press: InputEventMouseButton


func setup(workshop) -> void:
	ws = workshop
	_cam = ws._camera
	_cam.click_captures = false
	_cam.ctrl_descends = false
	sync()


func set_mode(m: String) -> void:
	mode = m
	_mmb = false
	_rmb = false
	_looking = false
	sync()


func toggle() -> void:
	set_mode("orbit" if mode == "fps" else "fps")


## True while the cursor should be free.
func wants_cursor() -> bool:
	if mode == "orbit":
		return not _looking
	return Input.is_key_pressed(KEY_ALT) or ws._hotbar.is_browsing() or ws._menu.is_modal()


## Keep the mouse as the mode says. Each frame, and on any change.
func sync() -> void:
	var free := wants_cursor()
	if bool(_cam._captured) == free:
		_cam._set_captured(not free)
	# In orbit the keys fly with the cursor free -- but not into a number being typed.
	_cam.drive_uncaptured = mode == "orbit" and not _busy()


func _busy() -> bool:
	if ws._hotbar.is_browsing() or ws._menu.is_modal():
		return true
	var vp: Viewport = ws.get_viewport()
	return vp != null and vp.gui_get_focus_owner() is LineEdit


## A mouse button or a key, from the workshop's `_unhandled_input`. True when it was the
## camera's.
func input(e: InputEvent) -> bool:
	if replaying:
		return false
	if e is InputEventKey and e.pressed and not e.echo and e.keycode == KEY_Y and not e.alt_pressed:
		toggle()
		return true
	if not (e is InputEventMouseButton):
		return false
	if mode == "fps":
		# Cursor out for the rail: the scene takes no clicks.
		return not _cam._captured
	var b: InputEventMouseButton = e
	match b.button_index:
		MOUSE_BUTTON_MIDDLE:
			if b.pressed:
				_mmb = true
				_moved = 0.0
				_pivot = _under_cursor()
				ws.get_viewport().gui_release_focus()
			else:
				_mmb = false
				if _moved < CLICK_PX:
					ws._pick_block()
			return true
		MOUSE_BUTTON_RIGHT:
			if ws._tools.dragging() or ws._stamp != null or (ws._furnish != null and ws._furnish.is_open()):
				return false
			if b.pressed:
				_rmb = true
				_moved = 0.0
				_rmb_press = b.duplicate()
				return true
			if not _rmb:
				return false
			_rmb = false
			if _looking:
				_looking = false
				sync()
				return true
			# A plain click: it was the tool's all along.
			replaying = true
			ws._unhandled_input(_rmb_press)
			ws._unhandled_input(b)
			replaying = false
			return true
		MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN:
			if ws._spaces != null and ws._spaces.active:
				return false
			if b.pressed:
				var d := 1 if b.button_index == MOUSE_BUTTON_WHEEL_UP else -1
				if b.shift_pressed:
					ws._hotbar.step(-d)
				else:
					zoom(d)
			return true
	return false


## Mouse motion, from the workshop's `_input` (ahead of the GUI, so a drag over a panel
## goes on). True when it was the camera's.
func input_motion(e: InputEvent) -> bool:
	if mode != "orbit" or not (e is InputEventMouseMotion):
		return false
	var m: InputEventMouseMotion = e
	if _rmb and not _looking:
		_moved += m.relative.length()
		if _moved >= CLICK_PX:
			_looking = true
			sync()
	if not _mmb:
		return false
	_moved += m.relative.length()
	if _moved < CLICK_PX:
		return true
	if Input.is_key_pressed(KEY_SHIFT):
		pan(m.relative)
	else:
		orbit(m.relative)
	return true


## Turn the view round the point the drag began on: it stays where it is on the screen.
func orbit(px: Vector2) -> void:
	var xf: Transform3D = _cam.global_transform
	var right: Vector3 = xf.basis.x.normalized()
	var turn := Basis(Vector3.UP, -px.x * ORBIT_RAD_PER_PX)
	# Not over the top: the pitch stops short of straight up or down.
	var fwd: Vector3 = -xf.basis.z
	var pitch := -px.y * ORBIT_RAD_PER_PX
	var now := asin(clampf(fwd.y, -1.0, 1.0))
	pitch = clampf(now + pitch, -1.45, 1.45) - now
	var r := turn * Basis(right, pitch)
	_cam.global_transform = Transform3D(r * xf.basis, _pivot + r * (xf.origin - _pivot))


func pan(px: Vector2) -> void:
	var xf: Transform3D = _cam.global_transform
	var k := maxf(1.0, xf.origin.distance_to(_pivot)) * 0.0016
	_cam.global_position = xf.origin - xf.basis.x * px.x * k + xf.basis.y * px.y * k


## In (`d` 1) or out along the ray under the cursor, by a share of the way to what is there.
func zoom(d: int) -> void:
	var ray: Array = ws._mouse_ray()
	var at := _under_cursor()
	var far: float = (ray[0] as Vector3).distance_to(at)
	_cam.global_position = _cam.global_position + (ray[1] as Vector3) * d * clampf(far * 0.14, 0.25, 60.0)


## What the cursor is on: the build, else the floor, else ten metres out.
func _under_cursor() -> Vector3:
	var ray: Array = ws._mouse_ray()
	var from: Vector3 = ray[0]
	var dir: Vector3 = ray[1]
	var hit: Dictionary = ws._first_hit(from, dir)
	if not hit.is_empty():
		return hit.point
	if dir.y < -0.01:
		return from + dir * (-from.y / dir.y)
	return from + dir * 10.0
