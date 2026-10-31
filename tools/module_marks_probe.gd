extends SceneTree
## The room-module markers in the workshop's spaces tool (Docs/RoomModules.md 2),
## driven with exact rays as workshop_spaces_probe drives the tool.
##
##     godot --headless --path . --script res://tools/module_marks_probe.gd
##
## The same room as workshop_spaces_probe: walls of 1x1 plates nine high, a
## ceiling, a doorway out (+X), a window, a pane of glass.
##
##   connector  the doorway is one connector: facing +X, 2 x 6, on the outer face
##              past the one-stud wall; the window and the glass are none
##   link       a click in link mode turns the doorway off, then start; the
##              link set by hand stays when the room is found again after an edit
##   stairs     a stair link down on the floor and up under the ceiling are
##              connectors, at the floor's and the ceiling's rows; a second
##              click takes one away
##   facade     a facade spot on the wall clicked, facing out through it
##   inside     a second room through the doorway makes it a hole between two
##              rooms of the module: no connector, unless set start by hand
##   rules      the module's rules, the marks and the links save and load back
##   generate   Generate on the rail grows a building from the modules (the test
##              kit's, room_module_kit.gd), asks first over unsaved work, and opens
##              it with its rooms found again from their seeds
##   tower      Generate tower sets a tower by its shell (stage 6), the volume over
##              the plate grown for its height

const Kit := preload("res://tools/room_module_kit.gd")

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
	print("module marks probe: connectors, links, stair links, facade spots, rules")
	_run()
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


## The centre of a cell of the upright grid, in the world.
func _at(x: float, y: float, z: float) -> Vector3:
	var xf: Transform3D = _ws.world.get_chunk_transform(_ws.asm.frames[0])
	return xf * Vector3(x * BrickPalette.STUD_M, y * BrickPalette.PLATE_M, z * BrickPalette.STUD_M)


func _of(rec: Dictionary, kind: String) -> Array:
	return (rec.get("connectors", []) as Array).filter(func(c) -> bool: return String(c.kind) == kind)


## The room of workshop_spaces_probe; with `second`, a room beyond its doorway
## (walls x 21 shared, 30; z 10, 19) with no other way out.
func _room(second: bool) -> BuildRecipe:
	var glass := -1
	for m in BrickWorld.get_material_count():
		if BrickWorld.is_material_translucent(m):
			glass = m
			break
	var r := BuildRecipe.new()
	r.name = "module marks probe"
	var put := func(x: int, y: int, z: int, mat := 0) -> void:
		r.add("plate_1x1", Vector3i(x, y, z), 0, 0, BuildRecipe.Role.STRUCTURE, mat)
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
	var x1 := 30 if second else 21
	for x in range(10, x1 + 1):
		for z in range(10, 20):
			put.call(x, 10, z)
			if x == 10 or x == 21 or x == x1 or z == 10 or z == 19:
				for y in range(1, 10):
					var c := Vector3i(x, y, z)
					if hole.has(c):
						continue
					put.call(x, y, z, glass if pane.has(c) else 0)
	return r


func _run() -> void:
	_ws._load_recipe(_room(false))
	var sp = _ws._spaces
	sp.toggle()
	sp.click(_at(13.5, 5.5, 13.5), Vector3.DOWN)
	var rec: Dictionary = sp.record()
	var doors := _of(rec, "door")
	var c: Dictionary = doors[0] if doors.size() == 1 else {}
	_ok("the doorway is the one connector: facing +X, 2 x 6, past the one-stud wall at x 22",
			not c.is_empty() and int(c.facing) == 0 and (c.size as Array) == [2, 6]
			and (c.at as Array) == [22, 1, 14] and String(c.link) == "auto",
			str(rec.get("connectors", [])))

	sp.mark = "link"
	sp.click(_at(18.5, 3.5, 14.5), Vector3(1, 0, 0))
	var off := _of(rec, "door").is_empty()
	sp.click(_at(18.5, 3.5, 14.5), Vector3(1, 0, 0))
	doors = _of(rec, "door")
	_ok("link mode: a click turns the doorway off (no connector), the next start",
			off and doors.size() == 1 and String(doors[0].link) == "start", sp.message)

	# An edit: a brick out of the far wall; the rooms found again keep the link.
	var gone: bool = _ws._delete_ray(_at(12.5, 5.5, 17.5), Vector3(0, 0, 1))
	sp._edited_ms -= 1000
	sp.process()
	rec = sp.record()
	doors = _of(rec, "door")
	_ok("after an edit the room is found again and the doorway is still start",
			gone and doors.size() == 1 and String(doors[0].link) == "start", str(doors))

	sp.mark = "stair_down"
	sp.click(_at(17.5, 5.5, 17.5), Vector3.DOWN)
	sp.mark = "stair_up"
	sp.click(_at(12.5, 5.5, 12.5), Vector3.UP)
	var down := _of(rec, "stair_down")
	var up := _of(rec, "stair_up")
	_ok("a stair link down on the floor (row 1) and up under the ceiling (row 9) are connectors",
			down.size() == 1 and up.size() == 1 and (down[0].at as Array) == [17, 1, 17]
			and (up[0].at as Array) == [12, 9, 12], "%s %s" % [str(down), str(up)])
	sp.click(_at(12.5, 5.5, 12.5), Vector3.UP)
	_ok("a second click takes the stair link away", _of(rec, "stair_up").is_empty()
			and (rec.marks as Array).size() == 1, sp.message)

	sp.mark = "balcony"
	sp.click(_at(17.5, 5.5, 15.5), Vector3(0, 0, 1))
	var spot: Dictionary = {}
	for m in rec.marks:
		if String(m.kind) == "balcony":
			spot = m
	_ok("a facade spot on the wall clicked, facing out through it (+Z)",
			not spot.is_empty() and int(spot.facing) == 1 and (spot.at as Array) == [17, 5, 19], str(spot))

	sp.set_rule("on", true)
	sp.set_rule("role", "start")
	sp.set_rule("max", 1)
	var path := "user://_probe_module_marks.json"
	_ws.recipe.save_to(path)
	var back := BuildRecipe.load_from(path)
	var srec: Dictionary = back.meta.get("structure", {})
	var mod: Dictionary = back.meta.get("module", {})
	var bdoor := (srec.get("connectors", []) as Array).filter(func(x) -> bool: return String(x.kind) == "door")
	_ok("the rules, the marks and the links save and load back",
			bool(mod.get("on", false)) and String(mod.get("role", "")) == "start" and int(mod.get("max", 0)) == 1
			and (srec.get("marks", []) as Array).size() == 2 and bdoor.size() == 1
			and String(bdoor[0].link) == "start", "%s %s" % [str(mod), str(srec.get("marks", []))])
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

	# Two rooms through the doorway: a hole inside the module.
	_ws._load_recipe(_room(true))
	sp = _ws._spaces
	if not sp.active:
		sp.toggle()
	sp.mark = "rooms"
	sp.click(_at(13.5, 5.5, 13.5), Vector3.DOWN)
	sp.click(_at(25.5, 5.5, 13.5), Vector3.DOWN)
	rec = sp.record()
	_ok("two rooms through the doorway: it is inside the module, no connector",
			(rec.spaces as Array).size() == 2 and _of(rec, "door").is_empty(), str(rec.get("connectors", [])))
	sp.mark = "link"
	sp.click(_at(18.5, 3.5, 14.5), Vector3(1, 0, 0))   # auto -> off
	sp.click(_at(18.5, 3.5, 14.5), Vector3(1, 0, 0))   # off -> start
	_ok("set start by hand, the hole inside is a connector all the same",
			_of(rec, "door").size() >= 1 and String(_of(rec, "door")[0].link) == "start",
			str(rec.get("connectors", [])))

	# Generate (Docs/RoomModules.md stage 4).
	RoomModules.use_recipes(Kit.modules())
	_ws._dirty = true
	var asked: Dictionary = sp.generate({"seed": 3, "rooms": 8, "path": 2})
	var plan: Dictionary = sp.generate({"seed": 3, "rooms": 8, "path": 2})
	# A building bigger than the baseplate: the plate grows to hold it all.
	_ws._dirty = false
	var big: Dictionary = sp.generate({"seed": 11, "rooms": 30, "path": 4})
	var laid := 0
	for at in _ws._placed_at:
		if int(at[1]) >= 0:
			laid += 1
	var bb: Array = _ws.recipe.bounds()
	_ok("a building bigger than the baseplate: the plate grows, every brick laid",
			bool(big.get("ok", false)) and laid == _ws.recipe.size() and int(_ws.plate_studs) >= maxi(bb[1].x, bb[1].z),
			"%d of %d bricks, %s studs, plate %d" % [laid, _ws.recipe.size(), str(bb[1]), _ws.plate_studs])
	_ws._dirty = false
	plan = sp.generate({"seed": 3, "rooms": 8, "path": 2})
	# Generate tower: a tall one grows the volume over the plate too.
	_ws._dirty = false
	var tower: Dictionary = sp.generate({"generator": "shell", "seed": 2, "width": 44, "depth": 28, "storeys": 12})
	var tb: Array = _ws.recipe.bounds()
	var tlaid := 0
	for at in _ws._placed_at:
		if int(at[1]) >= 0:
			tlaid += 1
	_ok("Generate tower opens a tower of 12 storeys, the volume grown for its height, every brick laid",
			bool(tower.get("ok", false)) and String(_ws.recipe.meta.generated.generator) == "shell"
			and int(_ws.height_plates) >= (tb[0] as Vector3i).y + (tb[1] as Vector3i).y and tlaid == _ws.recipe.size(),
			"%s; %d of %d bricks, height %d plates" % [sp.message, tlaid, _ws.recipe.size(), _ws.height_plates])
	_ws._dirty = false
	plan = sp.generate({"seed": 3, "rooms": 8, "path": 2})
	RoomModules.use_recipes([])
	sp._edited_ms -= 1000
	sp.process()
	rec = sp.record()
	var lost := (rec.spaces as Array).filter(func(x) -> bool: return x.has("lost")).size()
	_ok("Generate asks first over unsaved work, then grows a building and opens it, every room found again",
			asked.is_empty() and bool(plan.get("ok", false)) and _ws.recipe.size() > 0
			and _ws.recipe.meta.has("generated") and (rec.spaces as Array).size() == int(plan.stats.modules)
			and lost == 0,
			"%s; %d bricks, %d room(s), %d lost %s %s" % [sp.message, _ws.recipe.size(), (rec.spaces as Array).size(), lost, str((rec.spaces as Array).filter(func(x) -> bool: return x.has("lost")).map(func(x): return [x.lost, x.seed, x.kind])), str(_ws.recipe.meta.generated.modules)])
