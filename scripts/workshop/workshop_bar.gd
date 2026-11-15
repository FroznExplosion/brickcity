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
		["free", "Free", "Alt F", "Free placement: bricks go on the working plane where the cursor is, not only on studs.", true],
		["plane_back", "Plane back", "PgDn", "Move the working plane back a step."],
		["plane_on", "Plane forward", "PgUp", "Move the working plane forward a step."],
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
		["view_3d", "3D view", "Alt 0", "The 3D view.", true],
		["view_side", "Side view", "Alt 1", "Look flat at the side.", true],
		["view_top", "Top view", "Alt 2", "Look flat down from the top (a building's plan).", true],
		["view_front", "Front view", "Alt 3", "Look flat at the front.", true],
		["section", "Section", "", "In a flat view, cut away what is in front of the working plane.", true],
		["outlines", "Outlines", "", "Outline the bricks by part: off, outlines, outlines and colours (press for the next).", true],
		["game_look", "Game look", "Alt C", "See it as the game will: its lights, at its size.", true],
		["stats", "Stats", "", "Show the numbers: the brick in hand and its cell in full, the layer, how many bricks; in the asset workshop the ruler, the triangles and the part.", true],
		["guide", "Guide", "U", "Room guide: a room template's size; again for the next."],
	]],
]


## A row's name in a menu (`WorkshopMenu.add_bar`) where the button's own is too short.
const MENU := {
	"rotate": "Turn the brick in hand",
	"flip": "Flip it (studs down)",
	"turn_last": "Turn the last one placed",
	"lock": "Lock the height",
	"snap": "Snap to side studs",
	"layer": "Next layer (structure, interior, detail)",
	"mirror": "Mirror",
	"mirror_axis": "Mirror across Z or X",
	"mirror_here": "Mirror plane where the ghost is",
	"colour_back": "Previous colour",
	"colour_on": "Next colour",
	"free": "Free placement on the working plane",
	"plane_back": "Working plane back",
	"plane_on": "Working plane forward",
	"cancel": "Cancel what is being drawn",
	"fps": "FPS or orbit camera",
	"grid": "Grid",
	"stress": "Stress",
	"keys": "Every key",
	"section": "Section: hide what is past the plane",
	"outlines": "Outlines: none / all parts / this part",
	"game_look": "Game look",
	"stats": "Stats",
	"guide": "Room guide (the next size)",
}


## The asset workshop's own buttons: the building workshop leaves them out (it has no working
## plane, section, part outlines or game look).
const ASSET_ONLY := ["free", "plane_back", "plane_on", "section", "outlines", "game_look"]


## The bar's list less `skip` (ids an owner does not have): a section left empty goes.
static func without(skip: Array = []) -> Array:
	var out := []
	for sec in ACTIONS:
		var rows := (sec[1] as Array).filter(func(r: Array) -> bool: return not skip.has(r[0]))
		if not rows.is_empty():
			out.append([sec[0], rows])
	return out

