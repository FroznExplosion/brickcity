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
