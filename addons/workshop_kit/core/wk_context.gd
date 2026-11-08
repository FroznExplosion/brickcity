class_name WkContext
extends RefCounted

## THE SEAM between the kit and an editor, as `MenuHost` is for the menus. Every point where a
## kit tool needs something only the editor knows -- what its cells are, where a stroke lies,
## what a finished stroke becomes -- is a method here with a neutral default, so a tool runs
## (and does nothing harmful) in an editor that has not filled it in.
##
## An editor extends this and overrides what its tools use:
##
##     class_name MyContext
##     extends WkContext
##     func sketch_begin(remove: bool) -> Variant: return "top"
##     func sketch_point(plane: Variant) -> Variant: return my_plane_hit()
##     func sketch_commit(plane: Variant, pen: WkSketchPen) -> void: fill(pen.entry(...))
##
## The kit never names an editor's own classes; the editor's classes appear only in its
## subclass of this.

## The editor's one undo history (WkUndoStack). Tools push their edits here.
var undo_stack: WkUndoStack = null


# ---------------------------------------------------------------------------
# Look (WkRail, the frame)
# ---------------------------------------------------------------------------

## Give a kit panel the editor's look (a Theme, fonts, text scale). Default: its own look.
func style_ui(_root: Control) -> void:
	pass


## The editor's panel box for kit panels, or null to keep theirs.
func panel_box() -> StyleBox:
	return null


# ---------------------------------------------------------------------------
# Sketch (WkSketchTool)
# ---------------------------------------------------------------------------

## A stroke is starting (`remove`: drawn to take away). Return the plane it lies on -- anything
## the editor likes; the tool hands it back to `sketch_point` and `sketch_commit` -- or null to
## refuse it (nothing to draw on here).
func sketch_begin(_remove: bool) -> Variant:
	return null


## Where the cursor is on `plane`, in the plane's own numbers (cells across, cells up), or null
## when it is off the plane.
func sketch_point(_plane: Variant) -> Variant:
	return null


## Whether a stroke started now takes away rather than adds, whichever button drew it (a cut).
func sketch_removes() -> bool:
	return false


## The stroke is finished: make it into whatever it becomes. `pen.points`, `pen.out`, `pen.draw`
## and `pen.entry(...)` describe it; the tool clears the pen after.
func sketch_commit(_plane: Variant, _pen: WkSketchPen) -> void:
	pass


## The stroke under way was given up (RMB, Esc, another tool).
func sketch_cancel() -> void:
	pass


# ---------------------------------------------------------------------------
# Paint (WkPaintTool)
# ---------------------------------------------------------------------------

## A paint stroke starts: everything painted until `paint_end` is one undo step.
func paint_begin() -> void:
	pass


## Paint what is under the cursor, `radius` cells round it (0: the one thing under it), into
## the stroke under way. True if anything changed.
func paint_at(_radius: int) -> bool:
	return false


## The stroke is done: record it (one command on `undo_stack`) if it changed anything.
func paint_end() -> void:
	pass


## Each frame while painting: show what the brush would paint.
func paint_hover(_radius: int) -> void:
	pass


## Take the paint of what is under the cursor into the brush.
func paint_pick() -> void:
	pass


## The next (`step` 1) or the one before (-1) of the editor's paints.
func paint_step(_step: int) -> void:
	pass


## The brush's reach changed (- =): show it.
func paint_radius_changed(_radius: int) -> void:
	pass


# ---------------------------------------------------------------------------
# Place (WkPlaceTool)
# ---------------------------------------------------------------------------

## LMB went down: put the piece in hand where the preview is, and start a run from there.
func place_begin() -> void:
	pass


## LMB is up: the run (if any) is done -- one undo step, the editor's.
func place_end() -> void:
	pass


## A run is under way.
func place_running() -> bool:
	return false


## Each frame: aim the preview at the cursor.
func place_hover() -> void:
	pass


## Each frame: if a run is under way and the preview has moved, lay the piece again there.
func place_drag() -> void:
	pass


## RMB: take away what is under the cursor.
func erase_at_cursor() -> void:
	pass


# ---------------------------------------------------------------------------
# Camera (WkCamera)
# ---------------------------------------------------------------------------

## The editor's camera.
func camera() -> Camera3D:
	return null


## The ray under the mouse: [from, dir], or [] when there is none.
func camera_ray() -> Array:
	return []


## Where a ray first meets what the editor shows (a Vector3), or null.
func camera_hit(_from: Vector3, _dir: Vector3) -> Variant:
	return null


## Whether the mouse is taken (FPS look).
func camera_captured() -> bool:
	return false


func camera_set_captured(_on: bool) -> void:
	pass


## Whether the movement keys fly the camera while the cursor is free.
func camera_drive_keys(_on: bool) -> void:
	pass


## A menu, a browser or a dialog has the cursor: the camera keeps its hands off.
func camera_busy() -> bool:
	return false


## Whether RMB is the camera's to look with now (not while a tool drags with it).
func camera_rmb_free() -> bool:
	return true


## Whether the wheel is the camera's to zoom with now.
func camera_wheel_free() -> bool:
	return true


## A plain click of `button` (MMB) that did not become a drag: the editor's (pick a piece).
func camera_click(_button: int) -> void:
	pass


## A plain RMB click the camera held back while it waited to see if it was a drag: give these
## events (press, release) to the editor's own input.
func camera_replay(_events: Array) -> void:
	pass


## Shift + wheel (`step` 1 up, -1 down): the editor's (a toolbar slot).
func camera_wheel_shift(_step: int) -> void:
	pass


## A flat view starts (true) or ends: the editor's camera should stop (or go back to) taking
## the mouse itself.
func camera_flat(_on: bool) -> void:
	pass


# ---------------------------------------------------------------------------
# Measure (WkMeasureTool)
# ---------------------------------------------------------------------------

## Where a measuring click under the cursor lands (a Vector3), or null on nothing.
func measure_point() -> Variant:
	return null


## Show the points measured (none, one, or two with the distance between them).
func measure_show(_points: Array[Vector3]) -> void:
	pass


# ---------------------------------------------------------------------------
# Fill (WkFillTool)
# ---------------------------------------------------------------------------

## A click: fill the patch under the cursor, `width` cells wide. Returns how much was filled.
func fill_at_cursor(_width: int) -> int:
	return 0


# ---------------------------------------------------------------------------
# Move (WkMoveTool)
# ---------------------------------------------------------------------------

## A press: take what is under the cursor; return the point grabbed (a Vector3), or null.
func move_grab() -> Variant:
	return null


## While dragging: show it moved `by` (world units; Vector3.ZERO: back where it was).
func move_to(_by: Vector3) -> void:
	pass


## Let go: put it `by` from where it was (one edit, the editor's to record).
func move_drop(_by: Vector3) -> void:
	pass


# ---------------------------------------------------------------------------
# Shapes (WkShapeTool)
# ---------------------------------------------------------------------------

## LMB pressed with nothing drawn: start a shape where the cursor is. Return the drag -- the
## editor's record of it (the tool adds "phase": "base" and "button") -- or {} to refuse.
func shape_begin(_button: int) -> Dictionary:
	return {}


## Each frame while the base is drawn: its far corner follows the cursor.
func shape_base(_drag: Dictionary) -> void:
	pass


## OUTLINE_HEIGHT: the base is let go. Go on to the height (set `drag.phase` to "height"), or
## end the drag (clear it) if the base becomes something else.
func shape_base_done(_drag: Dictionary) -> void:
	pass


## Each frame while the height is pulled: the height follows the cursor.
func shape_height(_drag: Dictionary) -> void:
	pass


## A height typed (digits, as typed so far): use it.
func shape_typed(_drag: Dictionary, _typed: String) -> void:
	pass


## Whether letting go of LMB in the height makes the shape (a push-pull dragged), not a click.
func shape_release_commits(_drag: Dictionary) -> bool:
	return false


## Make the shape `drag` describes (the tool has let go of it). Returns what was made.
func shape_commit(_drag: Dictionary) -> Variant:
	return null


## The shape being drawn was given up (RMB, Esc, another tool).
func shape_cancel() -> void:
	pass


# ---------------------------------------------------------------------------
# Select (WkSelectTool)
# ---------------------------------------------------------------------------

## CLICK: pick what is under the cursor.
func select_at_cursor() -> void:
	pass


## BOX: a box starts at the cursor. False: no box here.
func select_box_begin() -> bool:
	return false


## Each frame while the box is dragged: its far corner follows the cursor.
func select_box_drag() -> void:
	pass


## The box is let go: pick what is in it.
func select_box_end() -> void:
	pass
