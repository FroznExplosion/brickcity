class_name BrickWorkshopContext
extends WkContext

## The workshop kit's seam (addons/workshop_kit, WkContext) for the brick workshops: what the
## kit's tools ask, answered from a workshop (Docs/BuildTools.md section 20). Every brick
## specific -- BrickWorld, the recipe, the palette, kept shapes, parts -- stays on this side.
##
## A tool's questions go to the part of the workshop that owns that tool's outcome:
## `ws._sketch_host()` for a sketch (the building workshop's tools make kept shapes of it; the
## asset workshop draws it into a part's sketch).

## The workshop (scripts/workshop.gd, or the asset workshop that extends it).
var ws


func _init(workshop) -> void:
	ws = workshop
	undo_stack = workshop.undo_stack


func sketch_begin(remove: bool) -> Variant:
	return ws._sketch_host().wk_sketch_begin(remove)


func sketch_point(plane: Variant) -> Variant:
	return ws._sketch_host().wk_sketch_point(plane)


func sketch_removes() -> bool:
	return ws._sketch_host().wk_sketch_removes()


func sketch_commit(plane: Variant, pen: WkSketchPen) -> void:
	ws._sketch_host().wk_sketch_commit(plane, pen)


func sketch_cancel() -> void:
	ws._sketch_host().wk_sketch_cancel()
