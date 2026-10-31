extends SceneTree
## The set-by-shell generator (Docs/RoomModules.md 4, stage 6), with the test
## modules of tools/room_module_kit.gd (no workshop).
##
##     godot --headless --path . --script res://tools/room_shell_probe.gd
##
##   pitch     the storey height the room modules have (14 plates: floor, 12, ceiling)
##   grow      8 seeds, 44 x 28, 4 storeys: every one a tower, modules on every
##             storey, no cell laid twice, no module in another's columns
##   doors     each module's corridor door open onto the corridor; its other
##             doors walled up
##   stairs    each storey's flight two plates a step, its top step level with the
##             floor above, the slab over it cut; the top one through the roof
##   rooms     the filler rooms each with a doorway off the corridor; windows in
##             the outer wall (glazed in a glass tower)
##   reach     every room of the tower -- the shell's and the modules' -- reached
##             through the air inside from the way in, and the roof
##   bare      no module: each side split into rooms room_max long, all reached
##   seed      the same seed the same tower; another, another
##   small     a shell too small for its hall and corridor says so

const Kit := preload("res://tools/room_module_kit.gd")

var _pass := 0
var _fail := 0


func _init() -> void:
	print("room shell probe: set by shell")
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


func _cells(r: BuildRecipe) -> Dictionary:
	var out := {}
	for i in r.size():
		var c := r.cell_of(i)
		var s := BuildRecipe.part_size(r.part_of(i))
		for y in s.y:
			for z in s.z:
				for x in s.x:
					var v := c + Vector3i(x, y, z)
					out[v] = int(out.get(v, 0)) + 1
	return out


func _run() -> void:
	var lib := RoomModules.from_recipes(Kit.modules())
	var pitch := RoomShell.pitch_of(lib)
	_ok("the storey height the room modules have: 14 plates", pitch == 14, str(pitch))

	var made := []
	var ms := 0
	for s in range(1, 9):
		var t0 := Time.get_ticks_msec()
		made.append(RoomShell.generate(lib, {"seed": s, "width": 44, "depth": 28, "storeys": 4}))
		ms += Time.get_ticks_msec() - t0
	var oks := made.filter(func(m) -> bool: return bool(m.ok))
	var twice := 0
	var empty_storeys := 0
	var crowd := 0
	var mods := []
	for m in oks:
		var cells := _cells(m.recipe)
		twice += cells.values().filter(func(v) -> bool: return int(v) > 1).size()
		var per := {}
		var owner := {}
		for i in m.plan.placed.size():
			var pl: Dictionary = m.plan.placed[i]
			per[int(pl.storey)] = int(per.get(int(pl.storey), 0)) + 1
			for c: Vector2i in lib[pl.m].turns[pl.t].cols:
				var k := Vector3i(c.x + pl.off.x, int(pl.storey), c.y + pl.off.z)
				if owner.has(k):
					crowd += 1
				owner[k] = i
		empty_storeys += 4 - per.size()
		mods.append(m.plan.placed.size())
	_ok("8 seeds, 44 x 28 x 4 storeys: every one a tower, modules on every storey, no cell twice, none crowded",
			oks.size() == 8 and twice == 0 and empty_storeys == 0 and crowd == 0,
			"%d ok, modules %s, %d cell(s) twice, %d storey(s) with none, %d crowded, %.1f ms a tower" % [
				oks.size(), str(mods), twice, empty_storeys, crowd, ms / 8.0])
	if oks.is_empty():
		return

	# Doors: the corridor one open, the rest walled up.
	var door_bad := []
	var capped := 0
	for m in oks:
		var cells := _cells(m.recipe)
		for i in m.plan.placed.size():
			var pl: Dictionary = m.plan.placed[i]
			var td: Dictionary = lib[pl.m].turns[pl.t]
			for ci in td.conns.size():
				var c: Dictionary = td.conns[ci]
				if String(c.kind) != "door":
					continue
				var fd: Vector2i = StructureSpaces.FACINGS[int(c.facing)]
				var at: Vector3i = (c.at as Vector3i) + (pl.off as Vector3i) + Vector3i(1, 0, 1)
				var hole := at - Vector3i(fd.x, 0, fd.y) + Vector3i(0, 2, 0)
				if ci == int(pl.door):
					if cells.has(hole) or cells.has(at + Vector3i(0, 2, 0)) or not cells.has(at + Vector3i(0, -1, 0)) \
							and int(pl.storey) > 0:
						door_bad.append("seed %d module %d: corridor door shut" % [m.plan.seed, i])
				elif not cells.has(hole):
					door_bad.append("seed %d module %d: a door left open" % [m.plan.seed, i])
				else:
					capped += 1
	_ok("each module's corridor door open onto the corridor, every other door walled up",
			door_bad.is_empty() and capped > 0, "%d capped %s" % [capped, str(door_bad.slice(0, 3))])

	# Stairs: two plates a step, level with the floor above, the slab cut.
	var m0: Dictionary = oks[0]
	var cells0 := _cells(m0.recipe)
	var stair_bad := []
	var zc: int = (28 - 4) / 2
	var steps := ceili(pitch / 2.0)
	for s in 4:
		var lane := zc if s % 2 == 0 else zc + 2
		var top_x := steps if s % 2 == 0 else 1
		var next_x := top_x - 1 if s % 2 == 0 else top_x + 1
		var top := _top(cells0, Vector2i(top_x + 1, lane + 1), s * pitch)
		var below := _top(cells0, Vector2i(next_x + 1, lane + 1), s * pitch)
		if top != (s + 1) * pitch or below != top - 2 or cells0.has(Vector3i(top_x + 1, top + 1, lane + 1)):
			stair_bad.append("storey %d: top %d, below %d" % [s, top, below])
	_ok("each storey's flight two plates a step up to the floor above, the slab over it cut, the last through the roof",
			stair_bad.is_empty(), str(stair_bad))

	# Filler rooms' doorways, windows.
	var room_bad := []
	var fillers := 0
	var windows := 0
	var glass := false
	for m in oks:
		var cells := _cells(m.recipe)
		for sp in m.recipe.meta.structure.spaces:
			if String(sp.kind) == "office" and not _from_module(m, sp):
				fillers += 1
		for y in range(1, 4 * pitch):
			if not cells.has(Vector3i(1, y, 1 + 14)):
				windows += 1
		if m.window_style == "glass":
			for i in m.recipe.size():
				if BrickWorld.is_material_translucent(m.recipe.material_of(i)):
					glass = true
	_ok("filler rooms where no module fits; windows in the outer wall, glazed in a glass tower",
			fillers > 0 and windows > 0 and (glass or oks.all(func(m) -> bool: return m.window_style == "open")),
			"%d filler room(s), %d window cell(s) on one line, glass %s" % [fillers, windows, str(glass)])

	# Reach: the air inside the footprint from the way in.
	var reach_bad := []
	for m in oks:
		var cells := _cells(m.recipe)
		var seen := _flood(cells, Vector3i(6, 2, 2), 44, 28, 4 * pitch + 1)
		var lost := 0
		for sp in m.recipe.meta.structure.spaces:
			if not seen.has(Vector3i(int(sp.seed[0]), int(sp.seed[1]), int(sp.seed[2]))):
				lost += 1
		var roof := false
		for c: Vector3i in seen:
			if c.y == 4 * pitch + 1:
				roof = true
				break
		if lost > 0 or not roof:
			reach_bad.append("seed %d: %d room(s) not reached, roof %s" % [m.plan.seed, lost, str(roof)])
	_ok("every room reached through the air inside from the way in, and the roof",
			reach_bad.is_empty(), str(reach_bad.slice(0, 3)))

	var again := RoomShell.generate(lib, {"seed": 3, "width": 44, "depth": 28, "storeys": 4})
	_ok("the same seed the same tower; another seed another",
			str(again.plan.placed) == str(made[2].plan.placed) and str(made[2].plan.placed) != str(made[3].plan.placed)
			and again.recipe.size() == made[2].recipe.size())

	# No modules at all: each side split into rooms of room_max, each reached.
	var bare := RoomShell.generate(lib, {"seed": 2, "width": 44, "depth": 28, "storeys": 4, "fill": 0.0})
	var bare_cells := _cells(bare.recipe)
	var bare_seen := _flood(bare_cells, Vector3i(6, 2, 2), 44, 28, 4 * pitch + 1)
	var offices := 0
	var bare_lost := 0
	for sp in bare.recipe.meta.structure.spaces:
		if String(sp.kind) == "office":
			offices += 1
		if not bare_seen.has(Vector3i(int(sp.seed[0]), int(sp.seed[1]), int(sp.seed[2]))):
			bare_lost += 1
	_ok("no module fits: each side split into rooms (3 a side here), each with its doorway, all reached",
			bare.ok and bare.plan.placed.is_empty() and offices == 4 * 2 * 3 and bare_lost == 0,
			"%d room(s), %d not reached" % [offices, bare_lost])

	var small := RoomShell.generate(lib, {"seed": 1, "width": 16, "depth": 12, "storeys": 2})
	_ok("a shell too small says so", not bool(small.ok) and String(small.why) != "", String(small.why))


## The highest solid row of a column from `y0` up through what is solid.
func _top(cells: Dictionary, c: Vector2i, y0: int) -> int:
	var y := y0
	while cells.has(Vector3i(c.x, y + 1, c.y)):
		y += 1
	return y


func _from_module(m: Dictionary, sp: Dictionary) -> bool:
	return int(sp.id) < m.recipe.meta.structure.spaces.size() - m.stats.rooms


## Air inside the footprint (inside the outer walls) reached from `start`, and
## the row over the roof.
func _flood(cells: Dictionary, start: Vector3i, w: int, d: int, top: int) -> Dictionary:
	var seen := {start: true}
	var todo: Array[Vector3i] = [start]
	var dirs := [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 1, 0), Vector3i(0, -1, 0),
			Vector3i(0, 0, 1), Vector3i(0, 0, -1)]
	while not todo.is_empty():
		var c: Vector3i = todo.pop_back()
		for dv in dirs:
			var n: Vector3i = c + dv
			if n.x < 2 or n.z < 2 or n.x > w - 1 or n.z > d - 1 or n.y < 1 or n.y > top:
				continue
			if seen.has(n) or cells.has(n):
				continue
			seen[n] = true
			todo.append(n)
	return seen
