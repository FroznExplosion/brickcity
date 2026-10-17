extends SceneTree
## The workshop's spaces tool (O; WorkshopSpaces, Docs/Structures.md 3.2), driven
## with exact rays as place_probe drives placing.
##
##     godot --headless --path . --script res://tools/workshop_spaces_probe.gd
##
## A room on the baseplate, of 1x1 plates: walls nine plates high, a ceiling, a
## doorway out, a window, a pane of glass, and a desk in the middle laid on the
## interior layer.
##
##   room       a click on the floor finds it: 10 x 8 studs, the desk not a wall
##   openings   the doorway, the window and the glass, each its kind
##   by hand    a click on the window turns its kind, and K the room's
##   edit       a brick taken out of a wall is a new opening once the bricks are still,
##              and the kind set by hand is kept
##   points     P puts a point and takes it away again
##   saved      the record rides in the recipe and loads back

var _ws
var _frames := 0
var _pass := 0
var _fail := 0


func _init() -> void:
	process_frame.connect(_tick)


func _ok(what: String, cond: bool, detail := "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _tick() -> void:
	_frames += 1
	if _frames == 2:
		_ws = load("res://scenes/workshop.tscn").instantiate()
		root.add_child(_ws)
		return
	if _frames != 4:
		return
	_ws.set_process(false)
	print("workshop spaces probe: rooms and openings in a build")
	_run()
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


## The centre of a cell of the upright grid, in the world.
func _at(x: float, y: float, z: float) -> Vector3:
	var xf: Transform3D = _ws.world.get_chunk_transform(_ws.asm.frames[0])
	return xf * Vector3(x * BrickPalette.STUD_M, y * BrickPalette.PLATE_M, z * BrickPalette.STUD_M)


func _kinds(rec: Dictionary) -> Dictionary:
	var out := {}
	for o in rec.openings:
		out[o.kind] = int(out.get(o.kind, 0)) + 1
	return out


func _run() -> void:
	var glass := -1
	for m in BrickWorld.get_material_count():
		if BrickWorld.is_material_translucent(m):
			glass = m
			break
	var r := BuildRecipe.new()
	r.name = "spaces probe"
	var put := func(x: int, y: int, z: int, role := BuildRecipe.Role.STRUCTURE, mat := 0) -> void:
		r.add("plate_1x1", Vector3i(x, y, z), 0, 0, role, mat)
	# Walls x 10 and 21, z 10 and 19; inside x 11-20, z 11-18; the baseplate is
	# the floor (y 0), the ceiling y 10.
	var hole := {}
	for z in [14, 15]:
		for y in range(1, 7):
			hole[Vector3i(21, y, z)] = true      # the doorway out
	for x in [14, 15]:
		for y in range(4, 7):
			hole[Vector3i(x, y, 10)] = true      # the window
	var pane := {}
	for z in [13, 14]:
		for y in range(3, 7):
			pane[Vector3i(10, y, z)] = true      # the glass
	for x in range(10, 22):
		for z in range(10, 20):
			put.call(x, 10, z)
			if x == 10 or x == 21 or z == 10 or z == 19:
				for y in range(1, 10):
					var c := Vector3i(x, y, z)
					if hole.has(c):
						continue
					put.call(x, y, z, BuildRecipe.Role.STRUCTURE, glass if pane.has(c) else 0)
	# The desk: interior, not a wall.
	for x in [15, 16]:
		for y in range(1, 4):
			put.call(x, y, 15, BuildRecipe.Role.INTERIOR)
	_ws._load_recipe(r)
	var sp = _ws._spaces
	sp.toggle()
	_ok("O puts the tool out", sp.active)

	# A click on the floor, from inside the room, straight down.
	sp.click(_at(13.5, 5.5, 13.5), Vector3.DOWN)
	var rec: Dictionary = sp.record()
	var s: Dictionary = rec.spaces[0] if not (rec.spaces as Array).is_empty() else {}
	_ok("a click on the floor finds the room: 10 x 8 studs, the desk not a wall",
			not s.is_empty() and (s.columns as Array).size() == 80 and int(s.floor_y) == 0
			and int(s.ceil_y) == 10,
			"%s" % (("%d columns, floor %d, ceiling %d" % [(s.columns as Array).size(), s.floor_y, s.ceil_y])
				if not s.is_empty() else sp.message))
	var k := _kinds(rec)
	_ok("its openings: the doorway, the window and the glass",
			(rec.openings as Array).size() == 3 and k.get("doorway", 0) == 1
			and k.get("window", 0) == 1 and k.get("glass", 0) == 1, str(k))

	# A click on the window, from inside, looking at it.
	sp.click(_at(15.0, 5.5, 13.5), Vector3(0, 0, -1))
	k = _kinds(rec)
	var by_hand := false
	for o in rec.openings:
		if bool(o.get("set", false)):
			by_hand = true
	_ok("a click on the window turns its kind (window -> glass), set by hand",
			k.get("window", 0) == 0 and k.get("glass", 0) == 2 and by_hand, str(k))
	sp.click(_at(13.5, 5.5, 13.5), Vector3.DOWN)
	sp.cycle_kind(1)
	_ok("a click in the room selects it, and K turns its kind",
			sp.selected == 0 and String(rec.spaces[0].kind) == "corridor", String(rec.spaces[0].kind))

	# A brick out of the far wall: a new opening once the bricks are still.
	var gone: bool = _ws._delete_ray(_at(20.5, 5.5, 12.5), Vector3(1, 0, 0))
	sp._edited_ms -= 1000
	sp.process()
	rec = sp.record()
	k = _kinds(rec)
	by_hand = false
	for o in rec.openings:
		if bool(o.get("set", false)) and String(o.kind) == "glass":
			by_hand = true
	_ok("a brick taken out of a wall is a new opening once the bricks are still; the kind set by hand stays",
			gone and (rec.openings as Array).size() == 4 and k.get("window", 0) == 1 and by_hand,
			"deleted %s, %s" % [str(gone), str(k)])

	sp.toggle_point(_at(17.5, 5.5, 17.5), Vector3.DOWN)
	var put_one: bool = (rec.points as Array).size() == 1
	sp.toggle_point(_at(17.5, 5.5, 17.5), Vector3.DOWN)
	_ok("P puts a point and takes it away again", put_one and (rec.points as Array).is_empty())

	var path := "user://_probe_spaces.json"
	_ws.recipe.save_to(path)
	var back := BuildRecipe.load_from(path)
	var srec: Dictionary = back.meta.get("structure", {})
	var kept := false
	for o in srec.get("openings", []):
		if bool(o.get("set", false)):
			kept = true
	_ok("the record rides in the recipe and loads back",
			(srec.get("spaces", []) as Array).size() == 1 and (srec.get("openings", []) as Array).size() == 4
			and kept and String(srec.spaces[0].kind) == "corridor")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
