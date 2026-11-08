class_name WkSketchTool
extends WkTool

## Sketch: draw an outline on a plane with the pen (WkSketchPen) -- freehand, brush, rectangle,
## ellipse, or a polygon clicked corner by corner -- and hand it to the editor when it is done.
## Where the stroke lies and what it becomes are the editor's (WkContext: `sketch_begin`,
## `sketch_point`, `sketch_commit`, `sketch_cancel`, `sketch_removes`).
##
##   LMB press, drag, release   a stroke (polygon: click each corner; on the first corner, a
##                              double click or Enter closes it; Backspace takes one back)
##   RMB                        the same, taking away -- or, with `rmb_cancels`, gives up the
##                              stroke under way (and outside one is not the tool's)

var pen := WkSketchPen.new()
## The plane `ctx.sketch_begin` gave for the stroke under way, or null between strokes.
var plane: Variant = null
## RMB gives up a stroke rather than drawing one that takes away.
var rmb_cancels := false
## A brush's reach, in cells, and whether it is square.
var brush_size := 1
var brush_square := false


func _init() -> void:
	id = &"sketch"
	label = "Sketch"


## A stroke is under way.
func drawing() -> bool:
	return plane != null


func deactivate() -> void:
	if plane != null:
		cancel()
	super.deactivate()


func input(e: InputEvent) -> bool:
	if ctx == null:
		return false
	if e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_RIGHT and rmb_cancels:
		if plane == null:
			return false
		if e.pressed:
			cancel()
		return true
	if e is InputEventMouseButton and e.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
		var remove: bool = e.button_index == MOUSE_BUTTON_RIGHT or ctx.sketch_removes()
		if e.pressed:
			if plane == null:
				plane = ctx.sketch_begin(remove)
				if plane == null:
					return true
			var q = ctx.sketch_point(plane)
			if q == null:
				return true
			if pen.draw == "polygon":
				if pen.polygon_click(q, remove, e.double_click):
					commit()
			else:
				pen.press(q, remove)
		elif pen.draw != "polygon" and plane != null:
			commit()
		return true
	if e is InputEventMouseMotion and plane != null and pen.draw != "polygon" and not pen.points.is_empty() \
			and (Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) or Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT)):
		var q = ctx.sketch_point(plane)
		if q != null:
			pen.move(q, brush_size)
		return true
	if e is InputEventKey and pen.draw == "polygon" and plane != null:
		match pen.polygon_key(e):
			"commit":
				commit()
				return true
			"back":
				return true
	return false


## The stroke under way, finished: the editor makes it into what it becomes.
func commit() -> void:
	var p = plane
	plane = null
	if p != null and ctx != null:
		ctx.sketch_commit(p, pen)
	pen.points.clear()


## Give up the stroke under way.
func cancel() -> void:
	plane = null
	pen.points.clear()
	if ctx != null:
		ctx.sketch_cancel()


func hint() -> String:
	if pen.draw == "polygon":
		return "Click each corner; click the first, double click or Enter to close it."
	return "Press and drag to draw; let go to finish."
