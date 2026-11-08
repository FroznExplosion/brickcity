class_name WkFillTool
extends WkTool

## Fill (the wand): a click fills the patch under the cursor -- what a patch is (a photo's
## colour, a region of like cells) and what it is filled with are the editor's
## (WkContext: `fill_at_cursor`). One click is one edit, the editor's to record.

## How wide the fill is, in cells (the editor reads it; 0: as the editor likes).
var width := 3:
	set(v):
		width = maxi(v, 0)


func _init() -> void:
	id = &"fill"
	label = "Fill"


func input(e: InputEvent) -> bool:
	if ctx == null or not (e is InputEventMouseButton):
		return false
	var b: InputEventMouseButton = e
	if b.button_index != MOUSE_BUTTON_LEFT:
		return false
	if b.pressed:
		ctx.fill_at_cursor(width)
	return true


func hint() -> String:
	return "Click a patch to fill it."
