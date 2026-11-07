class_name WkCamera
extends RefCounted

## The editor camera (workshop_kit): two ways to look, and flat views.
##
##   orbit   the cursor is free and tools work where it points, as Godot's viewport: MMB drag
##           orbits round what is under the cursor, Shift + MMB pans, the wheel zooms toward
##           the cursor (Shift + wheel: the editor's, `camera_wheel_shift`), RMB held and moved
##           looks round. A plain RMB or MMB click is the editor's (`camera_replay`,
##           `camera_click`).
##   fps     the mouse looks; hold Alt for the cursor. The flying itself (WASD ...) is the
##           editor's own camera; this only says when the mouse is taken (`camera_set_captured`)
##           and when keys fly with the cursor free (`camera_drive_keys`).
##   flat    `flat("side" | "top" | "front", centre)`: an orthographic view straight at a
##           point, zoomed at the cursor (`zoom_at`); `perspective()` goes back.
##
## Everything it needs from the editor is asked of the context (WkContext `camera_*`).

const CLICK_PX := 6.0
const ORBIT_RAD_PER_PX := 0.006

var ctx: WkContext
## "orbit" or "fps".
var mode := "orbit"
## The key that swaps the two.
var toggle_key := KEY_Y
## Replaying a plain RMB click to the editor: not this camera's.
var replaying := false
## The flat view in use ("side", "top", "front"), or "" for perspective.
var flat_view := ""
## A flat view's height in metres (orthographic size).
var ortho_size := 8.0
var ortho_min := 0.5
var ortho_max := 80.0

var _mmb := false
var _rmb := false
var _looking := false
var _moved := 0.0
var _pivot := Vector3.ZERO
var _rmb_press: InputEventMouseButton
var _persp_xf := Transform3D()


func setup(p_ctx: WkContext) -> void:
	ctx = p_ctx
	sync()


func cam() -> Camera3D:
	return ctx.camera() if ctx != null else null


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
	return Input.is_key_pressed(KEY_ALT) or ctx.camera_busy()


## Keep the mouse as the mode says. Each frame, and on any change.
func sync() -> void:
	if ctx == null:
		return
	var free := wants_cursor()
	if ctx.camera_captured() == free:
		ctx.camera_set_captured(not free)
	# In orbit the keys fly with the cursor free -- but not into a number being typed.
	ctx.camera_drive_keys(mode == "orbit" and not _busy())


func _busy() -> bool:
	if ctx.camera_busy():
		return true
	var c := cam()
	var vp: Viewport = c.get_viewport() if c != null else null
	return vp != null and vp.gui_get_focus_owner() is LineEdit


## A mouse button or a key, from the editor's `_unhandled_input`. True when it was the camera's.
func input(e: InputEvent) -> bool:
	if replaying or ctx == null:
		return false
	if e is InputEventKey and e.pressed and not e.echo and e.keycode == toggle_key and not e.alt_pressed:
		toggle()
		return true
	if not (e is InputEventMouseButton):
		return false
	if mode == "fps":
		# Cursor out for the editor's panels: the scene takes no clicks.
		return not ctx.camera_captured()
	var b: InputEventMouseButton = e
	match b.button_index:
		MOUSE_BUTTON_MIDDLE:
			if b.pressed:
				_mmb = true
				_moved = 0.0
				_pivot = under_cursor()
				var c := cam()
				if c != null and c.get_viewport() != null:
					c.get_viewport().gui_release_focus()
			else:
				_mmb = false
				if _moved < CLICK_PX:
					ctx.camera_click(MOUSE_BUTTON_MIDDLE)
			return true
		MOUSE_BUTTON_RIGHT:
			if not ctx.camera_rmb_free():
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
			# A plain click: it was the editor's all along.
			replaying = true
			ctx.camera_replay([_rmb_press, b])
			replaying = false
			return true
		MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN:
			if not ctx.camera_wheel_free():
				return false
			if b.pressed:
				var d := 1 if b.button_index == MOUSE_BUTTON_WHEEL_UP else -1
				if b.shift_pressed:
					ctx.camera_wheel_shift(d)
				else:
					zoom(d)
			return true
	return false


## Mouse motion, from the editor's `_input` (ahead of the GUI, so a drag over a panel goes on).
## True when it was the camera's.
func input_motion(e: InputEvent) -> bool:
	if mode != "orbit" or not (e is InputEventMouseMotion) or ctx == null:
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
	var c := cam()
	var xf: Transform3D = c.global_transform
	var right: Vector3 = xf.basis.x.normalized()
	var turn := Basis(Vector3.UP, -px.x * ORBIT_RAD_PER_PX)
	# Not over the top: the pitch stops short of straight up or down.
	var fwd: Vector3 = -xf.basis.z
	var pitch := -px.y * ORBIT_RAD_PER_PX
	var now := asin(clampf(fwd.y, -1.0, 1.0))
	pitch = clampf(now + pitch, -1.45, 1.45) - now
	var r := turn * Basis(right, pitch)
	c.global_transform = Transform3D(r * xf.basis, _pivot + r * (xf.origin - _pivot))


func pan(px: Vector2) -> void:
	var c := cam()
	var xf: Transform3D = c.global_transform
	var k := maxf(1.0, xf.origin.distance_to(_pivot)) * 0.0016
	c.global_position = xf.origin - xf.basis.x * px.x * k + xf.basis.y * px.y * k


## In (`d` 1) or out along the ray under the cursor, by a share of the way to what is there.
func zoom(d: int) -> void:
	var ray: Array = ctx.camera_ray()
	if ray.size() < 2:
		return
	var at := under_cursor()
	var far: float = (ray[0] as Vector3).distance_to(at)
	var c := cam()
	c.global_position = c.global_position + (ray[1] as Vector3) * d * clampf(far * 0.14, 0.25, 60.0)


## What the cursor is on: what the editor hits, else the ground (y = 0), else ten metres out.
func under_cursor() -> Vector3:
	var ray: Array = ctx.camera_ray()
	if ray.size() < 2:
		return Vector3.ZERO
	var from: Vector3 = ray[0]
	var dir: Vector3 = ray[1]
	var hit = ctx.camera_hit(from, dir)
	if hit != null:
		return hit
	if dir.y < -0.01:
		return from + dir * (-from.y / dir.y)
	return from + dir * 10.0


# ---------------------------------------------------------------------------
# Flat views
# ---------------------------------------------------------------------------

## Look straight at `centre` from the side (+Z looking -Z), the top or the front (+X), in an
## orthographic view `ortho_size` high. The perspective view is kept for `perspective`.
func flat(view: String, centre: Vector3, distance := 60.0) -> void:
	var c := cam()
	if flat_view == "":
		_persp_xf = c.global_transform
	flat_view = view
	ctx.camera_flat(true)
	c.projection = Camera3D.PROJECTION_ORTHOGONAL
	c.size = ortho_size
	match view:
		"top":
			c.global_position = centre + Vector3.UP * distance
			c.look_at(centre, Vector3.FORWARD)
		"front":
			c.global_position = centre + Vector3.RIGHT * distance
			c.look_at(centre, Vector3.UP)
		_:
			c.global_position = centre + Vector3.BACK * distance
			c.look_at(centre, Vector3.UP)


## Back to the perspective view as it was before the first flat one.
func perspective() -> void:
	var c := cam()
	if flat_view != "":
		c.global_transform = _persp_xf
	flat_view = ""
	c.projection = Camera3D.PROJECTION_PERSPECTIVE
	ctx.camera_flat(false)


## A flat view's size times `by` (held between `ortho_min` and `ortho_max`).
func zoom_flat(by: float) -> void:
	ortho_size = clampf(ortho_size * by, ortho_min, ortho_max)
	if flat_view != "":
		cam().size = ortho_size


## Zoom a flat view by `by`, keeping the point `under` (on the camera's own plane) where it is
## on the screen.
func zoom_at(under: Vector3, by: float) -> void:
	var c := cam()
	var n := -c.global_transform.basis.z
	var p := c.global_position
	var d := p - under
	var across := d - n * d.dot(n)
	zoom_flat(by)
	c.global_position = under + across * by + n * d.dot(n)
