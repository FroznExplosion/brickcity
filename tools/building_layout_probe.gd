extends SceneTree

## BuildingLayout (Docs/AI.md 3.6.1): a tower's room graph from its recipe
## alone, checked against the tower's own bricks -- a doorway the graph walks
## through has to be air in the wall, and the rooms and doorways have to be the
## ones the spaces finder sees in the bricks. A graph that disagrees with the
## building sends a squad at a wall.
##
##     godot --headless --path . --script tools/building_layout_probe.gd

var failures := 0


func _ok(label: String, cond: bool, detail := "") -> void:
	print("  %s  %s  %s" % ["ok  " if cond else "FAIL", label, detail])
	if not cond:
		failures += 1


func _init() -> void:
	for shape in [Vector3i(30, 30, 12), Vector3i(40, 30, 24), Vector3i(40, 40, 60)]:
		_check_tower(shape.x, shape.y, shape.z)
	_check_record()
	print("[probe] %s" % ("PASS" if failures == 0 else "FAIL — %d" % failures))
	quit(1 if failures > 0 else 0)


func _check_tower(fx: int, fz: int, courses: int) -> void:
	print("tower %d x %d, %d courses" % [fx, fz, courses])
	var stair := TowerRecipe.stair_rect(fx, fz)
	var keep := [stair] if stair.size != Vector2i.ZERO else []
	var t0 := Time.get_ticks_usec()
	var lay := BuildingLayout.for_tower(fx, fz, courses, keep)
	var made_ms := (Time.get_ticks_usec() - t0) / 1000.0
	var rooms := 0
	var stairs := 0
	for s in lay.spaces:
		if s.kind == "room":
			rooms += 1
		else:
			stairs += 1
	var storeys := RoomManifest.storeys_of(courses).size()
	# The grid walks a node per 2x2 studs per storey: what the graph replaces.
	@warning_ignore("integer_division")
	var grid := (fx / 2) * (fz / 2) * storeys
	_ok("made from the recipe", rooms > 0, "%d rooms, %d stair spaces, %d links, %d windows, %.2f ms (grid: ~%d nodes)"
			% [rooms, stairs, lay.link_count(), lay.portals.size(), made_ms, grid])

	# Every room reachable from the first, up the stairs.
	var first := _middle(lay, 0)
	var cut := 0
	var climbed := false
	for i in lay.spaces.size():
		var r := lay.route(first, _middle(lay, i))
		if r.is_empty():
			cut += 1
		elif lay.spaces[i].storey == storeys - 1 and lay.spaces[i].kind == "room":
			climbed = true
	# Not a check on the graph: a room the recipe gives no doorway is sealed in
	# the bricks too (one doorway per wall LINE, and a line runs past several
	# rooms). Reported for the building side; the AI breaches into those.
	print("  info  %d of %d spaces have no way in from the ground floor (sealed by the recipe)"
			% [cut, lay.spaces.size()])
	if storeys > 1:
		_ok("and the top storey by the stairs", climbed)
	var t1 := Time.get_ticks_usec()
	var far := lay.route(first, _middle(lay, lay.spaces.size() - 1))
	_ok("a route is cheap", far.size() >= 2, "%d points, %d us" % [far.size(), Time.get_ticks_usec() - t1])

	# Against the bricks.
	var w := BrickWorld.new()
	var c := w.create_chunk(Vector3i.ZERO, TowerRecipe.chunk_dims(fx, fz, courses))
	TowerRecipe.build(w, c, TowerRecipe.bake_palette(w), fx, fz, courses, keep)
	var doors := TowerRecipe.doorways(fx, fz, courses, keep)
	var pl := TowerRecipe.plan(fx, fz)
	var blocked := 0
	var walls := 0
	var door_h := (TowerRecipe.COURSES_PER_FLOOR - 1) * TowerRecipe.PLATES_PER_COURSE
	for d in doors:
		# The part the graph walks through (BuildingLayout.clear_span).
		var span := BuildingLayout.clear_span(d, pl)
		for along in range(span.x, span.y):
			for k in int(d.thick):
				for y in range(int(d.floor_y), int(d.floor_y) + door_h):
					var cell := Vector3i(int(d.line) + k, y, along) if d.along_z \
							else Vector3i(along, y, int(d.line) + k)
					if w.is_solid(c, cell):
						blocked += 1
		# ...and wall either side, or the "doorway" is a guess that happens
		# to land in a wider hole.
		var beside := Vector3i(int(d.line), int(d.floor_y) + 1, span.x - 1) if d.along_z \
				else Vector3i(span.x - 1, int(d.floor_y) + 1, int(d.line))
		if w.is_solid(c, beside):
			walls += 1
	_ok("every doorway in the graph is air in the bricks", blocked == 0,
			"%d doorways, %d solid cells in them" % [doors.size(), blocked])
	_ok("with wall beside it", walls == doors.size(), "%d of %d" % [walls, doors.size()])

	# The spaces finder, on the bricks, sees the same rooms and doorways.
	var rec := StructureSpaces.for_tower(w, c, fx, fz, courses, 7, {}, stair)
	var found := BuildingLayout.for_record(rec)
	var door_links := 0
	for i in lay.spaces.size():
		for l in lay.links[i]:
			if l[2] == "doorway":
				door_links += 1
	@warning_ignore("integer_division")
	door_links /= 2
	_ok("the finder sees the same rooms", found.space_count() == rooms,
			"recipe %d, bricks %d" % [rooms, found.space_count()])
	# The finder treats the stairwell as solid, so the stretch of a room wall
	# the stairwell cuts away can read to it as an opening between the rooms
	# either side; the graph has those as ways through the stairwell instead.
	var stair_links := 0
	for i in lay.spaces.size():
		for l in lay.links[i]:
			if l[2] == "stair":
				stair_links += 1
	_ok("and the same doorways (plus any beside the stairwell)",
			found.link_count() >= door_links and found.link_count() <= door_links + stair_links,
			"recipe %d doorways + %d stair ways, bricks %d" % [door_links, stair_links,
				found.link_count()])


## The middle of a space, standing on its floor (building metres).
func _middle(lay: BuildingLayout, i: int) -> Vector3:
	var s: Dictionary = lay.spaces[i]
	var r: Rect2i = s.rect
	return Vector3((r.position.x + r.size.x * 0.5) * BuildingLayout.STUD,
			(int(s.floor_y) + 1) * BuildingLayout.PLATE,
			(r.position.y + r.size.y * 0.5) * BuildingLayout.STUD)


func _check_record() -> void:
	print("a structure record")
	# Two rooms side by side on one floor, a doorway between them, and a
	# door out of the first: what the spaces tool writes for a build.
	var a := []
	var b := []
	for x in range(0, 4):
		for z in range(0, 4):
			a.append([x, z])
			b.append([x + 5, z])
	var hole := [[4, 1, 1], [4, 2, 1], [4, 1, 2], [4, 2, 2]]
	var rec := {"spaces": [
			{"id": 0, "kind": "office", "floor_y": 0, "ceil_y": 13, "columns": a},
			{"id": 1, "kind": "hall", "floor_y": 0, "ceil_y": 13, "columns": b}],
		"openings": [
			{"id": 0, "kind": "doorway", "space": 0, "cells": hole},
			{"id": 1, "kind": "doorway", "space": 1, "cells": hole},
			{"id": 2, "kind": "door", "space": 0, "cells": [[1, 1, -1], [2, 1, -1]]},
			{"id": 3, "kind": "window", "space": 1, "cells": [[9, 5, 2]]}],
		"points": []}
	var lay := BuildingLayout.for_record(rec)
	_ok("two spaces, one way between", lay.space_count() == 2 and lay.link_count() == 1,
			"%d spaces, %d links" % [lay.space_count(), lay.link_count()])
	_ok("a door and a window to the outside", lay.portals.size() == 2, "%d" % lay.portals.size())
	var r := lay.route(Vector3(0.5, 0.2, 0.5) * 0.35, Vector3(7.5 * 0.35, 0.2, 1.5 * 0.35))
	_ok("and a route through the doorway", r.size() == 3, "%d points" % r.size())
