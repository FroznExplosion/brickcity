class_name WkSelectTool
extends WkTool

## Select: pick what to work on. Two ways (`mode`):
##
##   CLICK   a click picks what is under the cursor (the editor may start a drag of it --
##           a push-pull -- on another tool, as the building workshop's Shapes does).
##   BOX     press, drag, let go: everything in the box.
##
## What can be picked and what a box takes are the editor's (WkContext: `select_at_cursor`,
## `select_box_begin`, `select_box_drag`, `select_box_end`).

enum Mode { CLICK, BOX }

var mode: Mode = Mode.CLICK

var _boxing := false


func _init() -> void:
	id = &"select"
	label = "Select"


## A box is being dragged.
func boxing() -> bool:
	return _boxing


func deactivate() -> void:
	cancel()
	super.deactivate()


## Drop a box being dragged, picking nothing.
func cancel() -> void:
	_boxing = false


func input(e: InputEvent) -> bool:
	if ctx == null or not (e is InputEventMouseButton):
		return false
	var b: InputEventMouseButton = e
	if b.button_index != MOUSE_BUTTON_LEFT:
		return false
	if mode == Mode.CLICK:
		if b.pressed:
			ctx.select_at_cursor()
		return true
	if b.pressed:
		_boxing = ctx.select_box_begin()
	elif _boxing:
		_boxing = false
		ctx.select_box_end()
	return true


## Each frame while a box is dragged: its far corner follows the cursor.
func process(_delta: float) -> void:
	if ctx != null and _boxing:
		ctx.select_box_drag()


func hint() -> String:
	return "Click what to pick." if mode == Mode.CLICK else "Drag a box round what to pick."
