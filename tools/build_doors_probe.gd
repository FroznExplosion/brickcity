extends SceneTree
## Doors in builds' doorways (scripts/build_doors.gd, Docs/RoomModules.md 3.2),
## in the workshop scene: its build is bricks in a chunk, as a city build is.
##
##     godot --headless --path . --script res://tools/build_doors_probe.gd
##
##   read      a door in meta["doors"] and an opening set to "door" by hand are
##             both doors
##   hung      a leaf in each, standing in its hole, shut
##   opens     a figure (a CharacterBody3D) in the doorway swings it open; gone,
##             it shuts again
##   lintel    the brick over a doorway shot away: that door drops
##   grow      a grown building has a door in every joined doorway (and the way
##             in and out), each hole open under a solid lintel
##   shell     a tower has one at each module's corridor door, each filler room,
##             the lift each storey and the way in, the same
##   lift      the tower's lift (BuildLifts): a platform at the ground stop; stood
##             on, it rides a storey up; waited for on the ground, it comes back

const Kit := preload("res://tools/room_module_kit.gd")

var _ws
var _doors: BuildDoors
var _lifts: BuildLifts
var _frames := 0
var _step := 0
var _pass := 0
var _fail := 0
var _fig: CharacterBody3D
var _wait := 0


func _init() -> void:
	physics_frame.connect(_tick)


func _ok(what: String, cond: bool, detail := "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _done() -> void:
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


## A room 10 x 10 with a doorway each side: -X a door by meta["doors"], +X one
## set to "door" by hand, the other two plain doorways.
func _room() -> BuildRecipe:
	var r: BuildRecipe = Kit.box("doors", 10, 10, {"role": "room"},
			[[2, 4, "auto"], [0, 4, "auto"], [1, 4, "auto"], [3, 4, "auto"]])
	r.meta.erase("module")
	var c: Dictionary = {}
	for k in (r.meta.structure.connectors as Array):
		if int(k.facing) == 2:
			c = k
	var h := BuildDoors.hole(BuildRecipe.cell_from(c.at), 2, Kit.DOOR.x, Kit.DOOR.y, 1)
	r.meta["doors"] = [BuildDoors.record(h[0], h[1])]
	for o in r.meta.structure.openings:
		if int(o.cells[0][0]) == 11:
			o.kind = "door"
	return r


func _leaves() -> Array:
	var out := []
	for key in _doors._builds:
		out.append_array(_doors._builds[key].leaves)
	return out


func _tick() -> void:
	_frames += 1
	if _frames == 2:
		_ws = load("res://scenes/workshop.tscn").instantiate()
		root.add_child(_ws)
		return
	if _frames < 5:
		return
	match _step:
		0:
			_ws.set_process(false)
			print("build doors probe: doors hung in doorways")
			for n in _ws.get_children():
				if n is BuildDoors:
					_doors = n
			var r := _room()
			var read := BuildDoors.of(r)
			_ok("a door in meta[\"doors\"] and an opening set to door by hand are both doors",
					_doors != null and read.size() == 2, str(read))
			_ws._load_recipe(r)
			_doors.resync()
			var leaves := _leaves()
			var inside := 0
			var xf: Transform3D = _ws.world.get_chunk_transform(_ws.asm.frames[0])
			var cell := BrickWorld.get_cell_size()
			for i in leaves.size():
				var lf: Dictionary = leaves[i]
				var d: Dictionary = read[i]
				var mid: Vector3 = (lf.frame as Node3D).global_transform * Vector3(0.3, 0.5, 0)
				var lo := xf * (Vector3(d.lo) * cell)
				var hi := xf * (Vector3(d.lo + d.size) * cell)
				if mid.x >= minf(lo.x, hi.x) and mid.x <= maxf(lo.x, hi.x) and mid.z >= minf(lo.z, hi.z) \
						and mid.z <= maxf(lo.z, hi.z) and mid.y >= lo.y and mid.y <= hi.y:
					inside += 1
			_ok("a leaf hung in each, standing in its hole, shut",
					leaves.size() == 2 and inside == 2 and leaves.all(func(l) -> bool: return float(l.angle) == 0.0),
					"%d leaf(ves), %d in their holes" % [leaves.size(), inside])
			# A figure in the -X doorway.
			_fig = CharacterBody3D.new()
			var cs := CollisionShape3D.new()
			var cap := CapsuleShape3D.new()
			cap.radius = 0.2
			cap.height = 1.2
			cs.shape = cap
			_fig.add_child(cs)
			root.add_child(_fig)
			var d0: Dictionary = read[0]
			_fig.global_position = xf * ((Vector3(d0.lo) + Vector3(-1.5, 4, 1.0)) * cell)
			_step = 1
			_wait = 0
		1:
			_wait += 1
			if _wait == 2:
				_doors.resync()
			if _wait < 40:
				return
			var lf: Dictionary = _leaves()[0]
			_ok("a figure in the doorway swings the door open", is_equal_approx(float(lf.angle), BuildDoors.SWING),
					"angle %.2f" % float(lf.angle))
			_fig.global_position += Vector3(0, 0, 40)
			_step = 2
			_wait = 0
		2:
			_wait += 1
			if _wait == 2:
				_doors.resync()
			if _wait < 40:
				return
			var lf: Dictionary = _leaves()[0]
			_ok("gone, it shuts again", float(lf.angle) == 0.0, "angle %.2f" % float(lf.angle))
			# The lintel over the -X door shot away.
			var chunk: int = _ws.asm.frames[0]
			var killed = _ws.world.kill_block(chunk, lf.lintel)
			_doors.resync()
			_ok("the brick over a doorway shot away: that door drops, the other stays",
					_doors.count() == 1 and not (lf.frame as Node3D).visible,
					"%s, %d standing" % [str(killed), _doors.count()])
			_generated()
			# A tower with a lift, opened in the workshop.
			var lib := RoomModules.from_recipes(Kit.modules())
			var made := RoomShell.generate(lib, {"seed": 1, "width": 44, "depth": 28, "storeys": 3})
			_ws.plate_studs = 48
			_ws._load_recipe(made.recipe)
			for n in _ws.get_children():
				if n is BuildLifts:
					_lifts = n
			_lifts.resync()
			var lift: Dictionary = _lifts.lifts()[0] if _lifts.count() > 0 else {}
			_ok("the tower's lift: a platform in its shaft at the ground stop", not lift.is_empty()
					and float(lift.at) == float(lift.stops[0]), str(made.recipe.meta.get("lifts", [])))
			if lift.is_empty():
				_done()
				return
			# On it.
			_fig.global_position = (lift.body as Node3D).global_transform * Vector3(0.7, 0.8, 0.7)
			_step = 3
			_wait = 0
		3:
			_wait += 1
			var lf: Dictionary = _lifts.lifts()[0]
			if _wait < 150 and float(lf.at) != float(lf.stops[1]):
				# Keep the figure on it as it rides (a real one is carried by the floor).
				_fig.global_position = (lf.body as Node3D).global_transform * Vector3(0.7, 0.8, 0.7)
				return
			_ok("stood on, it rides a storey up", float(lf.at) == float(lf.stops[1]) and int(lf.stop) <= 1,
					"at row %.1f, stops %s, %d ticks" % [float(lf.at), str(lf.stops), _wait])
			# Off it, and waiting by the shaft on the ground.
			var xf: Transform3D = _ws.world.get_chunk_transform(_ws.asm.frames[0])
			var cell := BrickWorld.get_cell_size()
			_fig.global_position = xf * ((lf.base as Vector3) + Vector3(0.7, int(lf.stops[0]) * cell.y + 0.8, -0.3))
			_step = 4
			_wait = 0
		4:
			_wait += 1
			var lf: Dictionary = _lifts.lifts()[0]
			if _wait < 150 and float(lf.at) != float(lf.stops[0]):
				return
			_ok("waited for on another storey, it comes", float(lf.at) == float(lf.stops[0]),
					"at row %.1f, %d ticks" % [float(lf.at), _wait])
			_done()


## The generators' doors: each a hole open under a solid lintel.
func _generated() -> void:
	var lib := RoomModules.from_recipes(Kit.modules())
	var plan := RoomGrow.grow(lib, {"seed": 4, "rooms": 12, "path": 3})
	var r := RoomGrow.lay(lib, plan)
	var bad := _check(r)
	var joined := 0
	for j in plan.joins:
		if String(j.a.kind) == "door" or String(j.a.kind) == "hang":
			joined += 1
	var want := joined + (1 if not plan.entrance.is_empty() else 0) + (1 if not plan.exit.is_empty() else 0)
	_ok("a grown building: a door in every joined doorway and the way in and out, each hole open under a lintel",
			(r.meta.get("doors", []) as Array).size() == want and bad.is_empty(),
			"%d door(s) of %d, %s" % [(r.meta.get("doors", []) as Array).size(), want, str(bad.slice(0, 3))])
	var made := RoomShell.generate(lib, {"seed": 3, "width": 44, "depth": 28, "storeys": 3})
	var sr: BuildRecipe = made.recipe
	var sbad := _check(sr)
	var swant: int = int(made.stats.modules) + 1 + int(made.stats.lifts) * 3
	for sp in sr.meta.structure.spaces:
		if String(sp.kind) == "office" and int(sp.id) >= sr.meta.structure.spaces.size() - int(made.stats.rooms):
			swant += 1
	_ok("a tower: a door at each module's corridor door, each filler room, the lift each storey and the way in",
			(sr.meta.get("doors", []) as Array).size() == swant and sbad.is_empty(),
			"%d door(s) of %d, %s" % [(sr.meta.get("doors", []) as Array).size(), swant, str(sbad.slice(0, 3))])


func _check(r: BuildRecipe) -> Array:
	var cells := {}
	for i in r.size():
		var c := r.cell_of(i)
		var s := BuildRecipe.part_size(r.part_of(i))
		for y in s.y:
			for z in s.z:
				for x in s.x:
					cells[c + Vector3i(x, y, z)] = true
	var bad := []
	for d in BuildDoors.of(r):
		var lo: Vector3i = d.lo
		var size: Vector3i = d.size
		for y in size.y:
			for z in size.z:
				for x in size.x:
					if cells.has(lo + Vector3i(x, y, z)):
						bad.append("%s shut at %s" % [str(lo), str(lo + Vector3i(x, y, z))])
		if not cells.has(lo + Vector3i(0, size.y, 0)):
			bad.append("%s no lintel" % str(lo))
	return bad
