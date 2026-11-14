class_name WorkshopBar
extends RefCounted

## The bar across the top of both workshops: its list (Docs/BuildTools.md section 21). What a
## button does is `BrickBench.bar_act` and each owner's own (`WorkshopTools.act`,
## `AssetWorkshopUI.bar_act`). Its own class so that neither of those names the other.

## The bar across the top, the same in both workshops (Docs/BuildTools.md sections 7 and 21):
## [section, [[id, label, key, what it does, toggle?], ...]]. An owner leaves out what it lacks
## (`without`) and answers its own ids before `BrickBench.bar_act`.
const ACTIONS := [
	["Hand", [
		["rotate", "Rotate", "R", "Turn the brick in hand a quarter."],
		["flip", "Flip", "F", "Turn it over: studs down."],
		["turn_last", "Turn last", "T", "Turn the brick just placed a quarter."],
		["lock", "Lock", "E", "Lock height: keep the ghost at the height it is on now (as E held) until this is pressed again.", true],
		["snap", "Side stud", "V", "Snap to side studs.", true],
		["layer", "Structure", "I", "The layer the next brick goes in: structure, interior or detail (press for the next)."],
		["mirror", "Mirror", "", "Lay every brick and shape again across the mirror plane.", true],
		["mirror_axis", "across Z", "", "Which way the mirror plane goes: across Z or across X."],
		["mirror_here", "Set plane", "", "Mirror plane here: through the middle of the ghost."],
		["colour_back", "< Colour", ",", "The colour before, in the slot in hand."],
		["colour_on", "Colour >", ".", "The next colour, in the slot in hand."],
	]],
	["Edit", [
		["undo", "Undo", "Z", "Take back the last edit: a brick, a run, a shape."],
		["redo", "Redo", "Shift Z", "Lay back what Undo took."],
		["cancel", "Cancel", "Esc", "Drop what is being drawn (a drag, a sketch, a wall line, a stair's first click)."],
	]],
	["View", [
		["fps", "FPS", "Y", "Swap the camera: FPS (the mouse looks, tools work at the dot; hold Alt for the cursor), or orbit (the cursor is free: MMB orbits, Shift MMB pans, the wheel zooms, RMB held looks round).", true],
		["grid", "Grid", "G", "Show the grid.", true],
		["stress", "Stress", "H", "Show how hard each brick is working.", true],
		["keys", "Keys", "F1", "Show every key.", true],
		["stats", "Stats", "", "Show the numbers: the brick in hand and its cell in full, the layer, how many bricks; in the asset workshop the ruler, the triangles and the part.", true],
		["guide", "Guide", "U", "Room guide: a room template's size; again for the next."],
	]],
]


## The bar's list less `skip` (ids an owner does not have): a section left empty goes.
static func without(skip: Array = []) -> Array:
	var out := []
	for sec in ACTIONS:
		var rows := (sec[1] as Array).filter(func(r: Array) -> bool: return not skip.has(r[0]))
		if not rows.is_empty():
			out.append([sec[0], rows])
	return out

