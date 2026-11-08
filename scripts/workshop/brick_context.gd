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


# Paint: the workshop paints its own bricks, in both workshops.

func paint_begin() -> void:
	ws.wk_paint_begin()


func paint_at(radius: int) -> bool:
	return ws.wk_paint_at(radius)


func paint_end() -> void:
	ws.wk_paint_end()


func paint_hover(radius: int) -> void:
	ws.wk_paint_hover(radius)


func paint_pick() -> void:
	ws.wk_paint_pick()


func paint_step(step: int) -> void:
	ws.wk_paint_step(step)


func paint_radius_changed(radius: int) -> void:
	ws.wk_paint_radius_changed(radius)


# Camera: the workshop's own camera (a DebugCamera, which flies), in both workshops.

func camera() -> Camera3D:
	return ws.wk_camera()


func camera_ray() -> Array:
	return ws.wk_camera_ray()


func camera_hit(from: Vector3, dir: Vector3) -> Variant:
	return ws.wk_camera_hit(from, dir)


func camera_captured() -> bool:
	return ws.wk_camera_captured()


func camera_set_captured(on: bool) -> void:
	ws.wk_camera_set_captured(on)


func camera_drive_keys(on: bool) -> void:
	ws.wk_camera_drive_keys(on)


func camera_busy() -> bool:
	return ws.wk_camera_busy()


func camera_rmb_free() -> bool:
	return ws.wk_camera_rmb_free()


func camera_wheel_free() -> bool:
	return ws.wk_camera_wheel_free()


func camera_click(button: int) -> void:
	ws.wk_camera_click(button)


func camera_replay(events: Array) -> void:
	ws.wk_camera_replay(events)


func camera_wheel_shift(step: int) -> void:
	ws.wk_camera_wheel_shift(step)


func camera_flat(on: bool) -> void:
	ws.wk_camera_flat(on)


# Look: the game's UI kit (ui/core/GameUI.gd, on menu/'s MenuTheme), text scale and all.

func style_ui(root: Control) -> void:
	GameUI.style(root)


func panel_box() -> StyleBox:
	return GameUI.panel_box(0.96)


# Place: the workshop's own hand (a brick where the ghost is, a run, RMB takes one away).

func place_begin() -> void:
	ws.wk_place_begin()


func place_end() -> void:
	ws.wk_place_end()


func place_running() -> bool:
	return ws.wk_place_running()


func place_hover() -> void:
	ws.wk_place_hover()


func place_drag() -> void:
	ws.wk_place_drag()


func erase_at_cursor() -> void:
	ws.wk_erase_at_cursor()


# Measure, fill (the wand), move: the asset workshop's.

func measure_point() -> Variant:
	return ws.wk_measure_point()


func measure_show(points: Array[Vector3]) -> void:
	ws.wk_measure_show(points)


func fill_at_cursor(width: int) -> int:
	return ws.wk_fill_at_cursor(width)


func move_grab() -> Variant:
	return ws.wk_move_grab()


func move_to(by: Vector3) -> void:
	ws.wk_move_to(by)


func move_drop(by: Vector3) -> void:
	ws.wk_move_drop(by)
