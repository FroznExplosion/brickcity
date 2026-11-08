class_name WkPlaceTool
extends WkTool

## Place: the hand. LMB puts the piece in hand where the preview is; held and moved, it lays a
## run wherever the preview goes; RMB takes away what is under the cursor. Each frame it has the
## editor aim the preview. What a piece is, where it fits and what a run is are the editor's
## (WkContext: `place_begin`, `place_end`, `place_running`, `place_hover`, `place_drag`,
## `erase_at_cursor`).
##
## The editor's default tool: in hand whenever no other is (WkToolbox `default_id`), and the
## hand under another tool for a click that tool does not take.

## RMB takes away what is under the cursor.
var rmb_erases := true


func _init() -> void:
	id = &"place"
	label = "Place"


func input(e: InputEvent) -> bool:
	if ctx == null or not (e is InputEventMouseButton):
		return false
	var b: InputEventMouseButton = e
	if b.button_index == MOUSE_BUTTON_LEFT:
		if b.pressed:
			ctx.place_begin()
		else:
			ctx.place_end()
		return true
	if b.button_index == MOUSE_BUTTON_RIGHT and rmb_erases:
		if b.pressed:
			ctx.erase_at_cursor()
		return true
	return false


## Each frame: aim the preview, and lay the run on while LMB is held (it ends when it is not).
func process(_delta: float) -> void:
	if ctx == null:
		return
	ctx.place_hover()
	if ctx.place_running() and not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		ctx.place_end()
	ctx.place_drag()


func hint() -> String:
	return "Click to place; hold and move to lay a run; RMB takes one away."
