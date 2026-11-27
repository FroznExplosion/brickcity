class_name MineFences
extends RefCounted
## Fences (Docs/MineCreatures.md 5.3): a fence item lays one PANEL, 1 stud
## thick and 3 studs from post to post, in the ground's own bricks -- so it is
## broken, saved and walked into like any other brick, and the creatures' nav
## sees it with nothing added.
##
##   posts    the panel's two ends, the fence's full height
##   rails    one plate thick every 3 plates (plates 2, 5, 8 up), between the
##            posts: see-through, and no gap a body fits through (the widest
##            hole is 2 studs by 2 plates)
##
## A 2-brick fence (6 plates) stops anything that steps up one brick: zombies,
## pigs, the player. A 3-brick fence (9 plates) is for what jumps two bricks
## (deer, later). Panels snap to a 3-stud lattice along their line, so panels
## laid side by side share their posts.

const SPAN := 3


## The boxes ([lo, hi] plate cells, inclusive) of a panel `plates` high whose
## line runs through `at` (stud, plate, stud: the cell over the ground) along
## X (`along_x`) or Z.
static func panel_boxes(at: Vector3i, along_x: bool, plates: int) -> Array:
	var a := at.x if along_x else at.z
	var a0 := floori(float(a) / SPAN) * SPAN
	var out := []
	var y0 := at.y
	var top := y0 + plates - 1
	for post in [a0, a0 + SPAN]:
		out.append([_cell(at, along_x, post, y0), _cell(at, along_x, post, top)])
	for ry in range(y0 + 2, top + 1, 3):
		out.append([_cell(at, along_x, a0 + 1, ry), _cell(at, along_x, a0 + SPAN - 1, ry)])
	return out


static func _cell(at: Vector3i, along_x: bool, a: int, y: int) -> Vector3i:
	return Vector3i(a, y, at.z) if along_x else Vector3i(at.x, y, a)


## Lay a panel in `material` (only into air). Returns the edit results laid
## (each a fill_box answer, for MineWorld.terrain_edited); empty if nothing.
static func place(at: Vector3i, along_x: bool, plates: int, material: int) -> Array:
	var res := []
	for bx in panel_boxes(at, along_x, plates):
		var r: Dictionary = BrickTerrain.fill_box(bx[0], bx[1], material, true)
		if int(r.get("changed", 0)) > 0:
			BrickTerrain.mark_placed(bx[0], bx[1], material)
			res.append(r)
	return res


## Is every cell of the panel solid (a gate's check)?
static func is_laid(at: Vector3i, along_x: bool, plates: int) -> bool:
	for bx in panel_boxes(at, along_x, plates):
		var lo: Vector3i = bx[0]
		var hi: Vector3i = bx[1]
		for x in range(lo.x, hi.x + 1):
			for y in range(lo.y, hi.y + 1):
				for z in range(lo.z, hi.z + 1):
					if BrickTerrain.solid_at(x, y, z) == 0:
						return false
	return true
