extends SceneTree
## The station grower (Docs/RoomModules.md 7.2, stage 9), with the test modules
## of tools/station_module_kit.gd (no workshop).
##
##     godot --headless --path . --script res://tools/room_station_probe.gd
##
##   grow      10 seeds: every one a station, one core, two docks, no module in
##             another's columns, every module joined to the core
##   bridges   tubes across gaps: modules reached two ways (loops) in most
##   levels    a second level (7.2): a stair node's stair up to the deck on it,
##             and a tube between two levels (rare: seeds 11-40 searched for
##             one), each walked by a figure the pawn's height, a step at most a
##             brick up
##   docks     each dock's outer port left open with a door, the rest capped
##   wings     solar wings and radiators out from their spots, clear of modules
##   stands    laid with its lowest row at 1, nothing under it
##   sections  under a small budget, sections with the core's the root
##   seed      the same seed the same station; another, another
##   holds     laid in a brick world with its keel the only thing on the
##             foundation row, nothing comes loose: every module, tie, tube and
##             wing held to the core by its studs
##   cut       a hit taking every brick where a leaf section meets the rest: that
##             section comes away whole (Docs/RoomModules.md 7.3)
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

	var walked := {"stair": 0, "tube": 0, "ladder": 0, "tube_ladder": 0}
	var stair_bad := []
	for m: Dictionary in ok_made:
		stair_bad.append_array(_levels_walked(lib, m, walked))
	# A tube between two levels takes two ports facing across a long enough gap
	# at two heights: one station in thirty or forty; one with a ladder (a gap too
	# short for a stair), rarer.
	for sd in range(11, 81):
		if int(walked.tube) > 0 and int(walked.tube_ladder) > 0:
			break
		var m := RoomStation.generate(lib, {"seed": sd, "modules": 18})
		if m.ok and int(m.stats.stairs) > 0:
			stair_bad.append_array(_levels_walked(lib, m, walked))
	_ok("levels: a stair node's stair up to its deck, tubes between two levels, each walked a step at most a brick up or climbed by its ladder",
			int(walked.stair) > 0 and int(walked.tube) > 0 and int(walked.ladder) > 0 and int(walked.tube_ladder) > 0
			and stair_bad.is_empty(),
			"%d stair join(s), %d tube(s) between levels walked; %d by a ladder, %d of them in a tube %s" % [
				int(walked.stair), int(walked.tube), int(walked.ladder), int(walked.tube_ladder), str(stair_bad.slice(0, 3))])

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
				var w := Vector2i(c.x + pl.off.x, c.y + pl.off.z)
				if not cols.has(w):
					cols[w] = []
				(cols[w] as Array).append([s.x + pl.off.y, s.y + pl.off.y])
		# A ladder's rungs (RoomGrow.ladder_adds) stand in its module: not a wing.
		var rungs := {}
		for ld: Dictionary in m.plan.get("ladders", []):
			var fd: Vector2i = StructureSpaces.FACINGS[int(ld.facing)]
			var across := Vector2i(absi(fd.y), absi(fd.x))
			var foot := BuildRecipe.cell_from(ld.at)
			for x in int(ld.w):
				for k in [0, -1]:
					rungs[Vector2i(foot.x, foot.z) + across * x + fd * k] = true
		for a in m.plan.adds:
			if String(a[0]) != "plate_2x2":
				continue
			var c: Vector3i = a[1]
			if rungs.has(Vector2i(c.x, c.z)):
				continue
			for dz in 2:
				for dx in 2:
					for s in cols.get(Vector2i(c.x + dx, c.z + dz), []):
						if c.y >= int(s[0]) and c.y < int(s[1]):
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

	# Holds: built into a brick world, the keel's row the foundation.
	var held_bad := []
	var cut_ok := 0
	var cut_tried := 0
	for m: Dictionary in ok_made.slice(0, 5):
		var r: BuildRecipe = m.recipe
		var w := BrickWorld.new()
		var pal := TowerRecipe.bake_palette(w)
		var c := w.create_chunk(Vector3i.ZERO, r.chunk_dims())
		var laid := r.build(w, c, pal)
		var org := r.origin()
		var on_floor := 0
		for i in r.size():
			if r.cell_of(i).y == org.y:
				on_floor += 1
		var loose: Array = w.find_detached_groups(c)
		var n_loose := 0
		for g in loose:
			n_loose += (g as PackedInt32Array).size()
		if laid != r.size() or n_loose > 0:
			held_bad.append("seed %d: %d of %d laid, %d loose in %d group(s), %d on the keel row" % [
					int(m.plan.seed), laid, r.size(), n_loose, loose.size(), on_floor])
		# Cut a leaf section off: every brick at its one joint.
		var cut := BuildSections.of_plan(lib, m.plan, r, m.plan.at, 2500)
		var touch := {}
		for j: Dictionary in cut.joints:
			touch[int(j.a)] = int(touch.get(int(j.a), 0)) + 1
			touch[int(j.b)] = int(touch.get(int(j.b), 0)) + 1
		var leaf := -1
		for k in touch:
			if int(k) != 0 and int(touch[k]) == 1:
				leaf = int(k)
				break
		if leaf < 0:
			continue
		cut_tried += 1
		for j: Dictionary in cut.joints:
			if int(j.a) == leaf or int(j.b) == leaf:
				for cell: Vector3i in j.cells:
					var b := w.block_at(c, cell - org)
					if b >= 0:
						w.kill_block(c, cell - org)
		var size_leaf := 0
		for k in (cut.of as PackedInt32Array).size():
			if int(cut.of[k]) == leaf:
				size_leaf += 1
		var away: Array = w.find_detached_groups(c)
		var biggest: int = (away[0] as PackedInt32Array).size() if not away.is_empty() else 0
		if biggest >= size_leaf * 0.6:
			cut_ok += 1
		else:
			held_bad.append("seed %d: section %d (%d bricks) cut off, biggest loose group %d" % [
					int(m.plan.seed), leaf, size_leaf, biggest])
	_ok("laid with only its keel on the foundation row, nothing loose: all held to the core by studs",
			held_bad.filter(func(x) -> bool: return String(x).contains("loose")).is_empty(), str(held_bad.slice(0, 3)))
	_ok("every brick where a leaf section meets the rest gone: the section comes away whole",
			cut_tried > 0 and cut_ok == cut_tried, "%d of %d %s" % [cut_ok, cut_tried, str(held_bad.slice(0, 3))])

	var none := RoomStation.generate(RoomModules.from_recipes(Kit.modules().slice(1)), {"seed": 1})
	_ok("a library with no core says so", not bool(none.ok) and String(none.why) != "", String(none.why))


## Each way between two levels -- a stair join (the lower module's floor to the
## upper's) and a bridging tube between two levels (a's doorway to b's): a figure
## PAWN plates tall, stepping at most CLIMB plates up (the pawn's step, a brick)
## and any way down, walks it -- and climbs a ladder (Docs/RoomModules.md 7.13):
## from its climb room's foot, the room clear all the way up for the figure, to
## where its top lands, its rails standing behind it. The ones it does not;
## `walked` counts the rest, and the ladders taken.
const PAWN := 12
const CLIMB := 3
func _levels_walked(lib: Array, m: Dictionary, walked: Dictionary) -> Array:
	var out := []
	var cells := {}
	var r: BuildRecipe = m.recipe
	for i in r.size():
		var c := r.cell_of(i)
		var s := BuildRecipe.part_size(r.part_of(i))
		for y in s.y:
			for z in s.z:
				for x in s.x:
					cells[c + Vector3i(x, y, z)] = true
	var stands := func(c: Vector3i) -> bool:
		if not cells.has(c - Vector3i(0, 1, 0)):
			return false
		for y in PAWN:
			if cells.has(c + Vector3i(0, y, 0)):
				return false
		return true
	var at: Vector3i = m.plan.at
	# Each ladder: its foot's climb-room cells -> where its top lands.
	var climbs := {}
	for ld: Dictionary in m.plan.get("ladders", []):
		var fd: Vector2i = StructureSpaces.FACINGS[int(ld.facing)]
		var lo_out := Vector3i(fd.x, 0, fd.y)
		var across := Vector3i(absi(fd.y), 0, absi(fd.x))
		var foot := BuildRecipe.cell_from(ld.at) + at
		var h := int(ld.h)
		var ok := true
		var rail := 0
		for x in int(ld.w):
			for y in h:
				rail += 1 if cells.has(foot - lo_out + across * x + Vector3i(0, y, 0)) else 0
			for k in range(1, RoomGrow.LADDER_ROOM + 1):
				for y in h + PAWN:
					ok = ok and not cells.has(foot + lo_out * k + across * x + Vector3i(0, y, 0))
		if not ok or rail * 2 < h * int(ld.w):
			continue
		for x in int(ld.w):
			for k in range(1, RoomGrow.LADDER_ROOM + 1):
				climbs[foot + lo_out * k + across * x] = foot - lo_out * 2 + across * x + Vector3i(0, h, 0)
	var floor_of := func(pi: int) -> Vector3i:
		var pl: Dictionary = m.plan.placed[pi]
		var sp: Dictionary = lib[pl.m].turns[pl.t].spaces.values()[0]
		return Vector3i(int(sp.seed.x), int(sp.floor_y) + 1, int(sp.seed.z)) + (pl.off as Vector3i) + at
	for j: Dictionary in m.plan.joins:
		var a: Vector3i
		var b: Vector3i
		var kind := "tube"
		if String(j.a.kind) == "stair_up" or String(j.a.kind) == "stair_down":
			a = floor_of.call(int(j.a.p))
			b = floor_of.call(int(j.b.p))
			kind = "stair"
		elif bool(j.loop) and (j.a.at as Vector3i).y != (j.b.at as Vector3i).y:
			a = (j.a.at as Vector3i) + at
			b = (j.b.at as Vector3i) + at
		else:
			continue
		if a.y > b.y:
			# Up from the lower, which only a stair or a ladder does.
			var t := a
			a = b
			b = t
		var lo := a.min(b) - Vector3i(14, 4, 14)
		var hi := a.max(b) + Vector3i(14, 4, 14)
		var seen := {a: true}
		var todo := [a]
		var got := false
		var laddered := false
		while not todo.is_empty() and not got:
			var c: Vector3i = todo.pop_back()
			if climbs.has(c):
				var v: Vector3i = climbs[c]
				if not seen.has(v) and stands.call(v):
					seen[v] = true
					todo.append(v)
					laddered = true
					if absi(v.x - b.x) + absi(v.z - b.z) <= 1 and absi(v.y - b.y) <= 1:
						got = true
			for n: Vector3i in [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]:
				for dy in range(CLIMB, -PAWN, -1):
					var v := c + n + Vector3i(0, dy, 0)
					if v.x < lo.x or v.z < lo.z or v.x > hi.x or v.z > hi.z or v.y < lo.y or v.y > hi.y:
						continue
					if seen.has(v) or not stands.call(v):
						continue
					# Up: room over its head where it stands to step up.
					var clear := true
					for y in range(PAWN, PAWN + maxi(dy, 0)):
						clear = clear and not cells.has(c + Vector3i(0, y, 0))
					if not clear:
						continue
					seen[v] = true
					todo.append(v)
					if absi(v.x - b.x) + absi(v.z - b.z) <= 1 and absi(v.y - b.y) <= 1:
						got = true
					break
		if not got:
			out.append("seed %d: %s %s to %s" % [int(m.recipe.meta.generated.seed), kind, str(a), str(b)])
		else:
			walked[kind] = int(walked[kind]) + 1
			walked.ladder = int(walked.ladder) + (1 if laddered else 0)
			if kind == "tube" and laddered:
				walked.tube_ladder = int(walked.tube_ladder) + 1
	return out


## Every bridging tube's join between two ports facing across a gap, the gap
## open through the doorway (no brick in it but a sill's tile), walled round.
func _bridged(lib: Array, ok_made: Array) -> bool:
	for m: Dictionary in ok_made:
		var cells := {}
		var r: BuildRecipe = m.recipe
		for i in r.size():
			# A sill's tile (a seam tied over a module below, 7.2) is a plate's step.
			if not r.part_of(i).begins_with("tile_"):
				cells[r.cell_of(i)] = true
		for j: Dictionary in m.plan.joins:
			if not bool(j.loop):
				continue
			var a: Vector3i = (j.a.at as Vector3i) + (m.plan.at as Vector3i)
			var b: Vector3i = (j.b.at as Vector3i) + (m.plan.at as Vector3i)
			var fd: Vector2i = StructureSpaces.FACINGS[int(j.a.facing)]
			var d := Vector3i(fd.x, 0, fd.y)
			var along := (b - a).x * d.x + (b - a).z * d.z
			if a.y != b.y:
				continue    # a stair: walked by _stairs_walked
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
