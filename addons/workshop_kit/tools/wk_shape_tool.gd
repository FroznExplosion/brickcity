class_name WkShapeTool
extends WkTool

## Shapes: draw a shape on the grid and make it. One tool, two gestures (`mode`):
##
##   DRAG_SOLID       press, drag, let go: the shape is made (a box, a ball, a wedge, filled).
##   OUTLINE_HEIGHT   press, drag the base, let go; move for the height (or type it); click to
##                    make it. Right-click or Esc gives it up. A drag the editor began already
##                    in its height (a push-pull) can be made by letting go.
##
## What the shape is, where it lies, what its height is in and what it becomes (a solid, walls,
## a cut) are the editor's (WkContext: `shape_begin`, `shape_base`, `shape_base_done`,
## `shape_height`, `shape_typed`, `shape_release_commits`, `shape_commit`, `shape_cancel`). The
## tool keeps the gesture: `drag`, a Dictionary the editor fills in and reads -- the tool only
## reads its "phase" ("base", "height") and "button" -- and the height typed.

enum Mode { DRAG_SOLID, OUTLINE_HEIGHT }

var mode: Mode = Mode.DRAG_SOLID
## The shape being drawn ({} when none): the editor's record of it, with "phase" and "button".
var drag: Dictionary = {}
## Digits typed for the height while it is pulled ("" when none).
var typed := ""


func _init() -> void:
	id = &"shape"
	label = "Shapes"


## A shape is being drawn (its base or its height).
func dragging() -> bool:
	return not drag.is_empty()


func phase() -> String:
	return String(drag.get("phase", ""))


func deactivate() -> void:
	if dragging():
		cancel()
	super.deactivate()


func input(e: InputEvent) -> bool:
	if ctx == null:
		return false
	if e is InputEventKey:
		return _key(e)
	if not (e is InputEventMouseButton):
		return false
	var b: InputEventMouseButton = e
	if b.button_index not in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
		return false
	if phase() == "height":
		if not b.pressed and b.button_index == MOUSE_BUTTON_LEFT and ctx.shape_release_commits(drag):
			commit()
		elif b.pressed:
			if b.button_index == MOUSE_BUTTON_LEFT:
				commit()
			else:
				cancel()
		return true
	if b.pressed:
		if dragging():
			return true
		# RMB outside a drawing is not the tool's (the editor's hand takes a piece away).
		if b.button_index != MOUSE_BUTTON_LEFT:
			return false
		begin(b.button_index)
		return true
	if not dragging() or b.button_index != int(drag.get("button", -1)):
		return true
	if mode == Mode.DRAG_SOLID:
		commit()
	else:
		ctx.shape_base_done(drag)
	return true


## Start a shape where the cursor is; the editor fills `drag` in, or leaves it empty (refused).
func begin(button: int = MOUSE_BUTTON_LEFT) -> void:
	typed = ""
	drag = ctx.shape_begin(button)
	if not drag.is_empty():
		if not drag.has("phase"):
			drag["phase"] = "base"
		if not drag.has("button"):
			drag["button"] = button


func _key(e: InputEventKey) -> bool:
	if not e.pressed or e.echo or e.ctrl_pressed or not dragging():
		return false
	if e.keycode == KEY_ESCAPE:
		cancel()
		return true
	if phase() != "height":
		return false
	if e.keycode in [KEY_ENTER, KEY_KP_ENTER]:
		commit()
		return true
	var d := -1
	if e.keycode >= KEY_0 and e.keycode <= KEY_9:
		d = e.keycode - KEY_0
	elif e.keycode >= KEY_KP_0 and e.keycode <= KEY_KP_9:
		d = e.keycode - KEY_KP_0
	if d >= 0:
		typed += str(d)
	elif e.keycode == KEY_BACKSPACE and typed != "":
		typed = typed.substr(0, typed.length() - 1)
	else:
		return false
	ctx.shape_typed(drag, typed)
	return true


## Each frame while drawing: the base follows the cursor, or the height does.
func process(_delta: float) -> void:
	if ctx == null or not dragging():
		return
	if phase() == "height":
		ctx.shape_height(drag)
	else:
		ctx.shape_base(drag)


## Make the shape drawn (from its base, if it has no height yet). Returns what the editor
## says it made.
func commit() -> Variant:
	if not dragging():
		return null
	var d := drag
	drag = {}
	typed = ""
	return ctx.shape_commit(d)


## Give the shape up.
func cancel() -> void:
	drag = {}
	typed = ""
	if ctx != null:
		ctx.shape_cancel()


func hint() -> String:
	if phase() == "height":
		return "Move for the height (or type it); click to make it. Right-click or Esc cancels."
	if dragging():
		return "Drag it, then let go."
	return "Press and drag a shape." if mode == Mode.DRAG_SOLID else "Press and drag the base, then pull its height."
