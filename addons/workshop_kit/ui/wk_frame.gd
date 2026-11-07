class_name WkFrame
extends RefCounted

## An editor's frame (workshop_kit): where its pieces of screen go, in one place. From the top:
## the menu bar (WkMenuBar), across the window; a band under it (a tool bar, stage tabs ...),
## across the window less a margin; then the rail (WkRail) down the left; the editor's own
## readouts start right of the rail (`content_left`). Any piece may be missing.
##
##     frame.bar = my_menu_bar
##     frame.band = my_tool_bar
##     frame.rail = my_rail
##     frame.layout(get_viewport().get_visible_rect().size)   # each frame
##
## Each piece is placed, not reparented: the editor keeps them wherever it built them.

var bar: Control = null
var band: Control = null
var rail: Control = null
## A panel down the right (an outliner): its top is kept under the bar.
var side: Control = null
## Space round the pieces, in pixels.
var margin := 8.0
## The rail's distance from the left edge.
var rail_left := 12.0
## Lay the band across the window (else it keeps its own width).
var band_wide := true
## The band's distance from the left edge (< 0: `margin`).
var band_left := -1.0
## The band's distance under the bar (< 0: half the margin).
var band_gap := -1.0
## The room the band takes above the rail (< 0: its own height).
var band_space := -1.0


## The menu bar's height (0 with none).
func bar_height() -> float:
	return bar.size.y if bar != null and bar.visible else 0.0


## The band's height (0 with none), or `band_space` when it is set.
func band_height() -> float:
	if band == null or not band.visible:
		return 0.0
	return band_space if band_space >= 0.0 else band.size.y


## Where the band goes: under the bar.
func band_top() -> float:
	return bar_height() + (band_gap if band_gap >= 0.0 else margin * 0.5)


## Where the rail goes: under the bar, and a margin under the band.
func rail_top() -> float:
	if band != null and band.visible:
		return band_top() + band_height() + margin
	return margin + bar_height()


## Where the editor's own readouts start, across: right of the rail.
func content_left() -> float:
	if rail == null or not rail.visible:
		return rail_left
	return rail.position.x + rail.size.x + margin


## Place every piece for a window of `view` pixels.
func layout(view: Vector2) -> void:
	if band != null:
		band.position = Vector2(band_left if band_left >= 0.0 else margin, band_top())
		if band_wide:
			band.custom_minimum_size.x = view.x - margin * 2.0
			band.size = Vector2(view.x - margin * 2.0, 0.0)
	if rail != null:
		rail.position = Vector2(rail_left, rail_top())
		rail.size = Vector2.ZERO
	if side != null:
		side.offset_top = bar_height() + (band_gap if band_gap >= 0.0 else margin * 0.5)
