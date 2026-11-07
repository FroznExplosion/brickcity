class_name WkPaintTool
extends WkTool

## Paint: give what is under the cursor the paint in hand -- held and dragged, everything the
## cursor passes over, as one undo step. What "paint" is (a colour, a material) and what can be
## painted are the editor's (WkContext: `paint_begin`, `paint_at`, `paint_end`, `paint_hover`,
## `paint_pick`, `paint_step`, `paint_radius_changed`).
##
##   LMB press, drag, release   one stroke
##   MMB                        take the paint of what is under the cursor
##   - / =                      the brush's reach (0: the one thing under the cursor)
##   Page Up / Page Down        the next or the one before of the editor's paints

## The brush's reach in cells; 0 is the one thing under the cursor.
var radius := 0:
	set(v):
		radius = clampi(v, 0, radius_max)
var radius_max := 12

var _stroking := false


func _init() -> void:
	id = &"paint"
	label = "Paint"


## A stroke is under way.
func stroking() -> bool:
	return _stroking


func deactivate() -> void:
	end_stroke()
	super.deactivate()


func input(e: InputEvent) -> bool:
	if ctx == null:
		return false
	if e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT:
		if e.pressed:
			begin_stroke()
		else:
			end_stroke()
		return true
	if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_MIDDLE:
		ctx.paint_pick()
		return true
	if e is InputEventKey and e.pressed and not e.echo:
		match e.keycode:
			KEY_MINUS, KEY_EQUAL:
				radius += 1 if e.keycode == KEY_EQUAL else -1
				ctx.paint_radius_changed(radius)
				return true
			KEY_PAGEUP, KEY_PAGEDOWN:
				ctx.paint_step(1 if e.keycode == KEY_PAGEUP else -1)
				return true
	return false


## Each frame: show where the brush would paint, and go on painting while LMB is held.
func process(_delta: float) -> void:
	if ctx == null:
		return
	ctx.paint_hover(radius)
	if _stroking:
		if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
			ctx.paint_at(radius)
		else:
			end_stroke()


## Start a stroke, and paint what is under the cursor.
func begin_stroke() -> void:
	if _stroking:
		end_stroke()
	_stroking = true
	ctx.paint_begin()
	ctx.paint_at(radius)


## The stroke under way is done: one undo step, the editor's.
func end_stroke() -> void:
	if not _stroking:
		return
	_stroking = false
	if ctx != null:
		ctx.paint_end()


func hint() -> String:
	return "Click or drag over what to paint; MMB takes a paint; - = the brush's reach."
