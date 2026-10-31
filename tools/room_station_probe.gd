extends SceneTree
## The station grower (Docs/RoomModules.md 7.2, stage 9), with the test modules
## of tools/station_module_kit.gd (no workshop).
##
##     godot --headless --path . --script res://tools/room_station_probe.gd
##
##   grow      10 seeds: every one a station, one core, two docks, no module in
##             another's columns, every module joined to the core
##   bridges   tubes across gaps: modules reached two ways (loops) in most
##   docks     each dock's outer port left open with a door, the rest capped
##   wings     solar wings and radiators out from their spots, clear of modules
##   stands    laid with its lowest row at 1, nothing under it
##   sections  under a small budget, sections with the core's the root
##   seed      the same seed the same station; another, another
##   none      a library with no core says so

const Kit := preload("res://tools/station_module_kit.gd")

var _pass := 0
var _fail := 0


func _init() -> void:
	print("room station probe")
	_run()
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _ok(what: String, cond: bool, detail := "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _run() -> void:
	var lib := RoomModules.from_recipes(Kit.modules())
	var made := []
	var bad := []
	var t0 := Time.get_ticks_usec()
	for sd in range(1, 11):
		var m := RoomStation.generate(lib, {"seed": sd, "modules": 18})
		made.append(m)
		if not m.ok:
			bad.append("seed %d: %s" % [sd, m.why])
			continue
		var plan: Dictionary = m.plan
		var cores: int = plan.placed.filter(func(pl) -> bool: return String(lib[pl.m].rules.role) == "core").size()
		if cores != 1:
			bad.append("seed %d: %d cores" % [sd, cores])
		if int(m.stats.docks) < 2:
			bad.append("seed %d: %d docks" % [sd, m.stats.docks])
		var over := _overlaps(lib, plan)
		if over > 0:
			bad.append("seed %d: %d column(s) of one module in another" % [sd, over])
		var lost := _unjoined(plan)
		if lost > 0:
			bad.append("seed %d: %d module(s) not joined to the core" % [sd, lost])
	var ms := (Time.get_ticks_usec() - t0) / 1000.0 / 10.0
	_ok("10 seeds: each a station, one core, two docks, no module in another, all joined to the core",
			bad.is_empty(), "%s, modules %s, %.1f ms a station" % [str(bad.slice(0, 4)),
				str(made.map(func(m) -> int: return int(m.stats.modules) if m.ok else 0)), ms])
	var ok_made := made.filter(func(m) -> bool: return m.ok)
	if ok_made.is_empty():
		return

	var loops: int = ok_made.filter(func(m) -> bool: return int(m.stats.loops) + int(m.stats.bridges) > 0).size()
	_ok("tubes across gaps: modules reached two ways in most stations", loops * 2 >= ok_made.size() and _bridged(lib, ok_made),
			"%d of %d with a loop, bridges %s" % [loops, ok_made.size(),
				str(ok_made.map(func(m) -> int: return int(m.stats.bridges)))])

	# Docks: each dock's finish port open with a door, every other open port capped.
	var dock_bad := 0
	for m: Dictionary in ok_made:
		var r: BuildRecipe = m.recipe
		var at: Vector3i = m.plan.at
		var holes := {}
		for dr in r.meta.get("doors", []):
			holes[BuildRecipe.cell_from(dr.lo)] = true
		var n := 0
		for i in m.plan.placed.size():
			var pl: Dictionary = m.plan.placed[i]
			if String(lib[pl.m].rules.role) != "dock":
				continue
			for c: Dictionary in lib[pl.m].turns[pl.t].conns:
				if String(c.link) == "finish":
					var cell: Vector3i = (c.at as Vector3i) + (pl.off as Vector3i) + at
					var fd: Vector2i = StructureSpaces.FACINGS[int(c.facing)]
					# The door's box starts in the wall behind the outer face.
					if not holes.has(cell - Vector3i(fd.x, 0, fd.y)) and not holes.has(cell):
						n += 1
		dock_bad += n
	_ok("each dock's outer port left open with a door", dock_bad == 0, "%d without" % dock_bad)

	# Wings and radiators.
	var wings := 0
	var rads := 0
	var in_mod := 0
	for m: Dictionary in ok_made:
		wings += int(m.stats.wings)
		rads += int(m.stats.radiators)
		var cols := {}
		for pl: Dictionary in m.plan.placed:
			var td: Dictionary = lib[pl.m].turns[pl.t]
			for c: Vector2i in td.cols:
				var s: Vector2i = td.cols[c]
				cols[Vector2i(c.x + pl.off.x, c.y + pl.off.z)] = [s.x + pl.off.y, s.y + pl.off.y]
		for a in m.plan.adds:
			if String(a[0]) != "plate_2x2":
				continue
			var c: Vector3i = a[1]
			for dz in 2:
				for dx in 2:
					var s = cols.get(Vector2i(c.x + dx, c.z + dz))
					if s != null and c.y >= int(s[0]) and c.y < int(s[1]):
						in_mod += 1
	_ok("solar wings and radiators out from their spots, clear of every module",
			wings > 0 and rads > 0 and in_mod == 0, "%d wing(s), %d radiator(s), %d cell(s) in a module" % [
				wings, rads, in_mod])

	var low := 1 << 30
	var r0: BuildRecipe = ok_made[0].recipe
	for i in r0.size():
		low = mini(low, r0.cell_of(i).y)
	_ok("laid with its lowest row at 1 (a station has no ground row)", low == 1, "lowest %d" % low)

	var big := RoomStation.generate(lib, {"seed": 3, "modules": 30, "section_bricks": 3000})
	var secs: Array = big.recipe.meta.sections.sections if big.ok else []
	_ok("under a 3000-brick budget: several sections, the core's the root",
			secs.size() > 1 and bool(secs[0].root) and _core_in_root(lib, big),
			str(secs.map(func(s) -> int: return int(s.bricks))))

	var again := RoomStation.generate(lib, {"seed": 1, "modules": 18})
	_ok("the same seed the same station; another, another",
			_bag(again.recipe) == _bag(ok_made[0].recipe) and _bag(ok_made[0].recipe) != _bag(ok_made[1].recipe))

	var none := RoomStation.generate(RoomModules.from_recipes(Kit.modules().slice(1)), {"seed": 1})
	_ok("a library with no core says so", not bool(none.ok) and String(none.why) != "", String(none.why))


## Every bridging tube's join between two ports facing across a gap, the gap
## open through the doorway (no brick in it), walled round.
func _bridged(lib: Array, ok_made: Array) -> bool:
	for m: Dictionary in ok_made:
		var cells := {}
		var r: BuildRecipe = m.recipe
		for i in r.size():
			cells[r.cell_of(i)] = true
		for j: Dictionary in m.plan.joins:
			if not bool(j.loop):
				continue
			var a: Vector3i = (j.a.at as Vector3i) + (m.plan.at as Vector3i)
			var b: Vector3i = (j.b.at as Vector3i) + (m.plan.at as Vector3i)
			var fd: Vector2i = StructureSpaces.FACINGS[int(j.a.facing)]
			var d := Vector3i(fd.x, 0, fd.y)
			var along := (b - a).x * d.x + (b - a).z * d.z
			if along < -1 or along > 40:
				print("    no gap ", a, " ", b)
				return false
			# Each doorway's low column: through its own wall and across the gap.
			for k in range(-1, along + 1):
				for c: Vector3i in [a + d * k, b - d * k]:
					if cells.has(c):
						print("    blocked at ", c)
						return false
	return true


## Columns of one module inside another's rows.
func _overlaps(lib: Array, plan: Dictionary) -> int:
	var occ := {}
	var n := 0
	for i in plan.placed.size():
		var pl: Dictionary = plan.placed[i]
		var td: Dictionary = lib[pl.m].turns[pl.t]
		for c: Vector2i in td.cols:
			var w := Vector2i(c.x + pl.off.x, c.y + pl.off.z)
			var s: Vector2i = td.cols[c]
			var y0: int = s.x + pl.off.y
			var y1: int = s.y + pl.off.y
			for o in occ.get(w, []):
				if y0 < int(o[1]) and int(o[0]) < y1:
					n += 1
			if not occ.has(w):
				occ[w] = []
			(occ[w] as Array).append([y0, y1])
	return n


## Placements the joins do not reach from the core (the path's first).
func _unjoined(plan: Dictionary) -> int:
	var adj := {}
	for j: Dictionary in plan.joins:
		var a := int(j.a.p)
		var b := int(j.b.p)
		if not adj.has(a):
			adj[a] = []
		if not adj.has(b):
			adj[b] = []
		adj[a].append(b)
		adj[b].append(a)
	var root := int(plan.path[0])
	var seen := {root: true}
	var todo := [root]
	while not todo.is_empty():
		var x: int = todo.pop_back()
		for y in adj.get(x, []):
			if not seen.has(y):
				seen[y] = true
				todo.append(y)
	return plan.placed.size() - seen.size()


func _core_in_root(lib: Array, made: Dictionary) -> bool:
	var of := BuildSections.of_build(made.recipe)
	var cells := BuildSections._cells(made.recipe, of)
	var pl: Dictionary = made.plan.placed[int(made.plan.path[0])]
	var tr: BuildRecipe = lib[pl.m].turns[pl.t].recipe
	var at: Vector3i = made.plan.at
	for k in tr.size():
		var c: Vector3i = tr.cell_of(k) + (pl.off as Vector3i) + at
		if cells.has(c) and int(cells[c]) != 0:
			return false
	return String(lib[pl.m].rules.role) == "core"


func _bag(r: BuildRecipe) -> String:
	var out := PackedStringArray()
	for i in r.size():
		out.append("%s %s %d" % [r.part_of(i), str(r.cell_of(i)), r.colour_of(i)])
	return ",".join(out)
