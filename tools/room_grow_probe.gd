extends SceneTree
## The module library and the grow generator (Docs/RoomModules.md 3-5), with
## modules made here as recipes (no workshop).
##
##     godot --headless --path . --script res://tools/room_grow_probe.gd
##
## Seven modules, walls of 1x1 plates, rooms 12 plates high with a floor and a
## ceiling of their own, every doorway 2 x 9:
##   hall     the start: a way in (-X, start), doors on its three other sides
##   cross    doors on all four sides, a window: rooms that can close a loop
##   corridor 16 x 4, a door at each end
##   vault    the finish: a door in (-X), the way out (+X, finish)
##   stairs   a door, a stair link up; loft: a stair link down, upper storeys only
##   tower    a door, a hang spot and a balcony spot
##
##   library   every module, every turn: each door connector's outer face is past
##             the wall, the cell behind it the hole, a jamb beside it solid
##   grow      20 seeds grow, none with a cell of one module in another's bricks
##             or rooms
##   path      start first, the finish last, each step joined to the next; the way
##             in and the way out open
##   doors     every door of every module is joined, capped, the way in or the way out
##   seed      the same seed grows the same building; another, another
##   loops     rooms joined at more than one place somewhere in the 20
##   rules     the hall (max 1) once; the loft never on the ground
##   stairs    a loft over a stairs somewhere, its steps laid up to its floor
##   hang      a room hung off the tower somewhere, its doorway cut
##   lay       one building laid: no cell twice, the caps in, the way in open
##   facade    balconies laid, windows glazed somewhere
##   baseplate a module built on the workshop's baseplate (no floor of its own)
##             gets one, and its room and doors are found

var _pass := 0
var _fail := 0
var _glass := -1
const Kit := preload("res://tools/room_module_kit.gd")
const DOOR := Kit.DOOR


func _init() -> void:
	print("room grow probe: the module library and the grow generator")
	for m in BrickWorld.get_material_count():
		if BrickWorld.is_material_translucent(m):
			_glass = m
			break
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
	var t0 := Time.get_ticks_msec()
	var lib := RoomModules.from_recipes(Kit.modules())
	var lib_ms := Time.get_ticks_msec() - t0
	var names := lib.map(func(m) -> String: return String(m.name))
	var bad := []
	var doors := 0
	for m in lib:
		for t in 4:
			var td: Dictionary = m.turns[t]
			for c in td.conns:
				if String(c.kind) != "door":
					continue
				doors += 1
				var fd: Vector2i = StructureSpaces.FACINGS[int(c.facing)]
				var dv := Vector3i(fd.x, 0, fd.y)
				var across := Vector3i(absi(fd.y), 0, absi(fd.x))
				var at: Vector3i = c.at
				var ok: bool = not td.solid.has(at) and not td.solid.has(at - dv) \
						and (td.solid.has(at - dv - across) or td.solid.has(at - dv + across * (c.size as Vector2i).x)) \
						and c.size == DOOR and int(c.depth) == 1
				if not ok:
					bad.append("%s t%d %s" % [m.name, t, str(c)])
	_ok("library: 7 modules, every door of every turn on the outer face, the hole behind, a jamb beside",
			lib.size() == 7 and bad.is_empty() and doors == 4 * 15,
			"%s, %d door(s) in all turns, %d ms%s" % [str(names), doors, lib_ms,
				("  BAD " + str(bad.slice(0, 3))) if not bad.is_empty() else ""])

	var plans := []
	var ms := 0
	var why := ""
	for s in range(1, 21):
		var a := Time.get_ticks_msec()
		var plan := RoomGrow.grow(lib, {"seed": s, "rooms": 12, "path": 3})
		ms += Time.get_ticks_msec() - a
		if not plan.ok and why == "":
			why = "seed %d: %s" % [s, plan.why]
		plans.append(plan)
	var oks := plans.filter(func(pl) -> bool: return pl.ok)
	var overlaps := 0
	for pl in oks:
		overlaps += _overlaps(lib, pl)
	var sizes := oks.map(func(pl) -> int: return int(pl.stats.modules))
	_ok("20 seeds grow, none with a cell of one module in another's bricks or rooms",
			oks.size() == 20 and overlaps == 0,
			"%d ok, %d overlap(s), modules %s, %.1f ms a building %s" % [oks.size(), overlaps, str(sizes),
				ms / 20.0, why])

	var path_bad := []
	var door_bad := []
	for pl in oks:
		var path: Array = pl.path
		var first := String(lib[pl.placed[path[0]].m].name)
		var last := String(lib[pl.placed[path[-1]].m].name)
		var steps := true
		for i in path.size() - 1:
			if not _joined(pl, int(path[i]), int(path[i + 1])):
				steps = false
		if first != "hall" or last != "vault" or not steps or pl.entrance.is_empty() or pl.exit.is_empty() \
				or String(pl.entrance.link) != "start" or String(pl.exit.link) != "finish":
			path_bad.append("seed %d: %s..%s steps %s" % [pl.seed, first, last, str(steps)])
		# Every door: joined, capped, the way in, or the way out -- exactly once.
		var seen := {}
		for j in pl.joins:
			for e in [j.a, j.b]:
				if String(e.kind) == "door":
					_count(seen, e)
		for e in pl.caps:
			_count(seen, e)
		_count(seen, pl.entrance)
		_count(seen, pl.exit)
		var n := 0
		for pi in pl.placed.size():
			for c in lib[pl.placed[pi].m].turns[pl.placed[pi].t].conns:
				if String(c.kind) == "door":
					n += 1
		var twice := seen.values().filter(func(v) -> bool: return int(v) != 1).size()
		if seen.size() != n or twice > 0:
			door_bad.append("seed %d: %d doors, %d accounted, %d twice" % [pl.seed, n, seen.size(), twice])
	_ok("the path: the hall first, the vault last, each step joined to the next, the way in and out open",
			path_bad.is_empty(), str(path_bad.slice(0, 3)))
	_ok("every door of every module is joined, capped, the way in or the way out, once",
			door_bad.is_empty(), str(door_bad.slice(0, 3)))

	var again := RoomGrow.grow(lib, {"seed": 5, "rooms": 12, "path": 3})
	_ok("the same seed grows the same building; another seed another",
			str(again.placed) == str(plans[4].placed) and str(plans[4].placed) != str(plans[5].placed))

	var loops := 0
	var stairs := 0
	var hangs := 0
	var balconies := 0
	var glazed := 0
	var rule_bad := []
	for pl in oks:
		loops += int(pl.stats.loops)
		balconies += int(pl.stats.balconies)
		if pl.window_style == "glass":
			glazed += 1
		var halls := 0
		var ground := int(lib[pl.placed[0].m].turns[pl.placed[0].t].min_y)
		for q in pl.placed:
			var nm := String(lib[q.m].name)
			if nm == "hall":
				halls += 1
			if nm == "loft" and int(lib[q.m].turns[q.t].min_y) + int(q.off.y) <= ground:
				rule_bad.append("seed %d: loft on the ground" % pl.seed)
		if halls != 1:
			rule_bad.append("seed %d: %d halls" % [pl.seed, halls])
		for j in pl.joins:
			if String(j.a.kind) == "stair_up" or String(j.a.kind) == "stair_down":
				stairs += 1
			if String(j.a.kind) == "hang":
				hangs += 1
	_ok("rooms joined at more than one place (loops) somewhere in the 20", loops > 0, "%d loop(s)" % loops)
	_ok("the rules: one hall (max 1), the loft never on the ground", rule_bad.is_empty(), str(rule_bad.slice(0, 3)))

	# A stair, laid: steps up to the loft's floor.
	var sp: Dictionary = {}
	for pl in oks:
		for j in pl.joins:
			if String(j.a.kind).begins_with("stair") and sp.is_empty():
				sp = pl
	var stair_ok := false
	var stair_detail := "no stair in 20 seeds"
	if not sp.is_empty():
		var out := RoomGrow.lay(lib, sp)
		var cells := _cells(out)
		for j in sp.joins:
			if not String(j.a.kind).begins_with("stair"):
				continue
			var low: Dictionary = j.a if String(j.a.kind) == "stair_up" else j.b
			var at: Vector3i = low.at
			# The top step: solid from the lower floor up to the upper floor's row,
			# and air over it where the slab was cut.
			var lp: Dictionary = sp.placed[int(low.p)]
			var floor_lo := int(lp.off.y)
			var top := floor_lo
			while cells.has(Vector3i(at.x, top + 1, at.z)):
				top += 1
			var upper: Dictionary = j.b if low == j.a else j.a
			var uplace: Dictionary = sp.placed[int(upper.p)]
			stair_ok = top == int(uplace.off.y) and not cells.has(Vector3i(at.x, top + 1, at.z))
			stair_detail = "seed %d: top step's top row %d, the loft's floor row %d" % [sp.seed, top, int(uplace.off.y)]
			break
	_ok("a loft over a stairs somewhere, its steps laid up to its floor and the slab over them cut",
			stairs > 0 and stair_ok, "%d stair join(s); %s" % [stairs, stair_detail])

	var hp: Dictionary = {}
	for pl in oks:
		for j in pl.joins:
			if String(j.a.kind) == "hang" and hp.is_empty():
				hp = pl
	var hang_ok := false
	if not hp.is_empty():
		var out := RoomGrow.lay(lib, hp)
		var cells := _cells(out)
		for j in hp.joins:
			if String(j.a.kind) == "hang":
				var fd: Vector2i = StructureSpaces.FACINGS[int(j.a.facing)]
				var wall: Vector3i = (j.a.at as Vector3i) - Vector3i(fd.x, 0, fd.y)
				hang_ok = not cells.has(wall) and not cells.has(wall + Vector3i(0, 5, 0))
	_ok("a room hung off the tower somewhere, a doorway cut through its wall", hangs > 0 and hang_ok,
			"%d hang join(s)" % hangs)

	var pl3: Dictionary = oks[2]
	t0 = Time.get_ticks_msec()
	var out3 := RoomGrow.lay(lib, pl3)
	var lay_ms := Time.get_ticks_msec() - t0
	var twice := 0
	var cells3 := {}
	for i in out3.size():
		var c := out3.cell_of(i)
		var s := BuildRecipe.part_size(out3.part_of(i))
		for y in s.y:
			for z in s.z:
				for x in s.x:
					var v := c + Vector3i(x, y, z)
					if cells3.has(v):
						twice += 1
					cells3[v] = true
	var caps_in := true
	for e in pl3.caps:
		var fd: Vector2i = StructureSpaces.FACINGS[int(e.facing)]
		if not cells3.has((e.at as Vector3i) - Vector3i(fd.x, 0, fd.y) + Vector3i(0, 2, 0)):
			caps_in = false
	var ef: Vector2i = StructureSpaces.FACINGS[int(pl3.entrance.facing)]
	var way_in := not cells3.has((pl3.entrance.at as Vector3i) - Vector3i(ef.x, 0, ef.y) + Vector3i(0, 2, 0))
	_ok("one building laid: no cell twice, every cap in its doorway, the way in open",
			out3.size() > 0 and twice == 0 and caps_in and way_in,
			"%d bricks, %d cell(s) twice, %d cap(s), caps in %s, way in open %s, %d ms" % [out3.size(), twice,
				pl3.caps.size(), str(caps_in), str(way_in), lay_ms])

	var glass_laid := false
	for pl in oks:
		if pl.window_style == "glass":
			var out := RoomGrow.lay(lib, pl)
			for i in out.size():
				if out.material_of(i) == _glass and _glass >= 0:
					glass_laid = true
			break
	_baseplate_check()
	_ok("balconies laid, and windows glazed in a building of the glass style",
			balconies > 0 and glazed > 0 and glass_laid,
			"%d balcony(ies), %d glazed building(s)" % [balconies, glazed])


func _count(seen: Dictionary, e: Dictionary) -> void:
	if e.is_empty():
		return
	var k := "%d %s" % [int(e.p), str(e.at)]
	seen[k] = int(seen.get(k, 0)) + 1


func _joined(pl: Dictionary, a: int, b: int) -> bool:
	for j in pl.joins:
		if (int(j.a.p) == a and int(j.b.p) == b) or (int(j.a.p) == b and int(j.b.p) == a):
			return true
	return false


func _cells(r: BuildRecipe) -> Dictionary:
	var out := {}
	for i in r.size():
		var c := r.cell_of(i)
		var s := BuildRecipe.part_size(r.part_of(i))
		for y in s.y:
			for z in s.z:
				for x in s.x:
					out[c + Vector3i(x, y, z)] = true
	return out


## Cells of one placement in another's bricks or rooms, worked out afresh.
func _overlaps(lib: Array, pl: Dictionary) -> int:
	var owner := {}
	var n := 0
	for i in pl.placed.size():
		var q: Dictionary = pl.placed[i]
		var td: Dictionary = lib[q.m].turns[q.t]
		var off: Vector3i = q.off
		var mine := {}
		for c: Vector3i in td.solid:
			mine[c + off] = true
		for sp in td.spaces.values():
			for col: Vector2i in sp.cols:
				for y in range(int(sp.floor_y) + 1, int(sp.ceil_y)):
					mine[Vector3i(col.x + off.x, y + off.y, col.y + off.z)] = true
		for c in mine:
			if owner.has(c) and int(owner[c]) != i:
				n += 1
			owner[c] = i
	return n


func _baseplate_check() -> void:
	var r: BuildRecipe = Kit.box("on plate", 10, 10, {"role": "room"}, [[2, 4, "auto"], [0, 4, "auto"]])
	var bare := BuildRecipe.new()
	bare.name = r.name
	bare.meta = r.meta.duplicate(true)
	for i in r.size():
		if r.cell_of(i).y > 0:
			bare.add(r.part_of(i), r.cell_of(i), r.colour_of(i))
	var m := RoomModules.make(bare)
	var floor_n := 0
	var td: Dictionary = m.turns[0] if not m.is_empty() else {}
	if not td.is_empty():
		for x in range(1, 11):
			for z in range(1, 11):
				if td.solid.has(Vector3i(x, 0, z)):
					floor_n += 1
	var doors: int = td.conns.size() if not td.is_empty() else 0
	_ok("a module built on the baseplate gets a floor of its own; its room and both doors are found",
			not m.is_empty() and floor_n == 100 and doors == 2,
			"%d of 100 floor cells, %d door(s)" % [floor_n, doors])
