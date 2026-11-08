class_name WkMoveTool
extends WkTool

## Move: press on something, drag it across the plane facing the camera (the one of the three
## axis planes most square to the view), let go to put it there. What is grabbed and how far
## it may go are the editor's (WkContext: `move_grab`, `move_to`, `move_drop`); the tool only
## follows the cursor on the plane and hands over how far it has come, in world units.

## The point grabbed (null: nothing in hand), and the plane it is dragged on.
var from: Variant = null
var normal := Vector3.UP
## How far the cursor has come on the plane since the press.
var by := Vector3.ZERO


func _init() -> void:
	id = &"move"
	label = "Move"


## Something is in hand.
func dragging() -> bool:
	return from != null


func deactivate() -> void:
	cancel()
	super.deactivate()


func input(e: InputEvent) -> bool:
	if ctx == null:
		return false
	if e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT:
		if e.pressed:
			grab()
		else:
			drop()
		return true
	if e is InputEventMouseMotion and dragging():
		follow(ctx.camera_ray())
		return true
	return false


## Press: take what is under the cursor, if the editor gives anything.
func grab() -> void:
	cancel()
	var p = ctx.move_grab()
	if p == null:
		return
	from = p
	by = Vector3.ZERO
	var cam := ctx.camera()
	normal = axis_facing(-cam.global_transform.basis.z) if cam != null else Vector3.UP


## The cursor moved: where the ray `[from, dir]` meets the plane is how far it has come.
func follow(ray: Array) -> void:
	if not dragging() or ray.size() < 2:
		return
	var at = Plane(normal, from).intersects_ray(ray[0], ray[1])
	if at != null:
		by = at - from
		ctx.move_to(by)


## Let go: put it where it was dragged.
func drop() -> void:
	if not dragging():
		return
	var d := by
	from = null
	by = Vector3.ZERO
	ctx.move_drop(d)


## Give up the drag without moving anything.
func cancel() -> void:
	if dragging() and ctx != null:
		ctx.move_to(Vector3.ZERO)
	from = null
	by = Vector3.ZERO


## The axis (with its sign) nearest `dir`: the normal of the axis plane most square to it.
static func axis_facing(dir: Vector3) -> Vector3:
	var a := dir.abs()
	if a.x >= a.y and a.x >= a.z:
		return Vector3(signf(dir.x), 0, 0)
	if a.y >= a.z:
		return Vector3(0, signf(dir.y), 0)
	return Vector3(0, 0, signf(dir.z))


func hint() -> String:
	return "Drag a part across the view; let go to put it there." if not dragging() else "Let go to put it here."
