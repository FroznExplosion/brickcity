class_name WkMeasureTool
extends WkTool

## Measure: two clicks, the distance between them. A third click starts again from it. Where a
## click lands (a surface, a plane) and how a distance is read out (units, a label) are the
## editor's (WkContext: `measure_point`, `measure_show`).

## The points clicked: none, one, or the two measured between.
var points: Array[Vector3] = []


func _init() -> void:
	id = &"measure"
	label = "Measure"


func deactivate() -> void:
	clear()
	super.deactivate()


## Forget the points (and show none).
func clear() -> void:
	points.clear()
	if ctx != null:
		ctx.measure_show(points)


func input(e: InputEvent) -> bool:
	if ctx == null or not (e is InputEventMouseButton):
		return false
	var b: InputEventMouseButton = e
	if b.button_index != MOUSE_BUTTON_LEFT or not b.pressed:
		return false
	click(ctx.measure_point())
	return true


## A click at `p` (a Vector3, or null: it landed on nothing, and changes nothing).
func click(p: Variant) -> void:
	if p == null:
		return
	if points.size() >= 2:
		points.clear()
	points.append(p)
	ctx.measure_show(points)


## The distance measured, or -1 with fewer than two points.
func distance() -> float:
	return points[0].distance_to(points[1]) if points.size() == 2 else -1.0


func hint() -> String:
	return "Click two points: the distance between them." if points.size() != 1 else "Click the second point."
