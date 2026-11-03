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
##   bare      no module: the storeys split into rooms room_max long at most, all reached
##   L         a drawn footprint (an L): nothing laid outside it, every room reached
##   setback   3 studs in every 2 storeys, a rail round each terrace, every room reached
##   lift      a shaft beside the hall, a stop a storey, open ground to top
##   sides     a setback on the north side only: the other walls straight up
##   stacked   modules with a stair link up get one with a link down over them
##             on the next storey, the room below open to the room above
##   facade    a module's window spots on the outer wall cut (or glazed), its
##             balcony spots built out past the tower
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
		# Inside: the footprint's box, and any room hung off its wall (past it).
		var box := _inside_box(44, 28, 4 * pitch + 1)
		var hung_cols := {}
		var at0: Vector3i = m.plan.at
		for hp: Dictionary in m.plan.placed:
			if hp.has("from"):
				for c: Vector2i in lib[hp.m].turns[hp.t].cols:
					hung_cols[Vector2i(c.x + hp.off.x + at0.x, c.y + hp.off.z + at0.z)] = true
		var inside := func(c: Vector3i) -> bool:
			return box.call(c) or (c.y > 0 and c.y <= 4 * pitch + 1 and (hung_cols.has(Vector2i(c.x, c.z))
					or hung_cols.has(Vector2i(c.x + 1, c.z)) or hung_cols.has(Vector2i(c.x - 1, c.z))
					or hung_cols.has(Vector2i(c.x, c.z + 1)) or hung_cols.has(Vector2i(c.x, c.z - 1))))
		var seen := _flood(cells, Vector3i(10, 2, 14), inside)
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

	# No modules at all: the storey split into rooms no longer than room_max
	# (and the wall) either way, each reached.
	# The shell's own doorways (the hall's, the lift's) as tall as the storey lets,
	# up to `doorway` (14: the pawn is 12): 11 in these 14-plate storeys; 14 asked
	# of 19-plate ones.
	var tallest := func(m: Dictionary) -> int:
		var t := 0
		for d: Array in m.plan.doors:
			t = maxi(t, (d[1] as Vector3i).y)
		return t
	var tall_lib := RoomModules.from_recipes(ShipBuild.modules())
	var tall := RoomShell.generate(tall_lib, {"seed": 3, "width": 44, "depth": 28, "storeys": 2, "pitch": ShipBuild.PITCH})
	_ok("its doorways as tall as the storey lets, up to 14 plates (the pawn walks through)",
			int(tallest.call(again)) == pitch - 3 and bool(tall.ok) and int(tallest.call(tall)) == 14,
			"%d in %d-plate storeys, %d in %d-plate ones" % [tallest.call(again), pitch,
				tallest.call(tall) if tall.ok else -1, ShipBuild.PITCH])
	var bare := RoomShell.generate(lib, {"seed": 2, "width": 44, "depth": 28, "storeys": 4, "fill": 0.0})
	var bare_seen := _flood(_cells(bare.recipe), Vector3i(10, 2, 14), _inside_box(44, 28, 4 * pitch + 1))
	var offices := 0
	var bare_lost := 0
	var too_long := 0
	for sp in bare.recipe.meta.structure.spaces:
		if String(sp.kind) == "office":
			offices += 1
			var lo := Vector2i(1 << 30, 1 << 30)
			var hi := -lo
			for c in sp.columns:
				lo = Vector2i(mini(lo.x, int(c[0])), mini(lo.y, int(c[1])))
				hi = Vector2i(maxi(hi.x, int(c[0])), maxi(hi.y, int(c[1])))
			if hi.x - lo.x + 1 > 14 or hi.y - lo.y + 1 > 14:
				too_long += 1
		if not bare_seen.has(Vector3i(int(sp.seed[0]), int(sp.seed[1]), int(sp.seed[2]))):
			bare_lost += 1
	_ok("no module fits: the storeys split into rooms no longer than room_max either way, all reached",
			bare.ok and bare.plan.placed.is_empty() and offices >= 4 * 6 and too_long == 0 and bare_lost == 0,
			"%d room(s), %d too long, %d not reached" % [offices, too_long, bare_lost])

	# A drawn footprint: an L (the box with its north-east quarter gone).
	var ell := []
	for z in 28:
		for x in 44:
			if not (x >= 26 and z >= 16):
				ell.append(Vector2i(x, z))
	# Nothing hung off it: a hung room stands past the footprint by design.
	var el := RoomShell.generate(lib, {"seed": 5, "footprint": ell, "storeys": 3, "hang": 0.0})
	var el_bad := []
	var el_lost := 0
	if el.ok:
		var cells := _cells(el.recipe)
		var foot := {}
		for c: Vector2i in ell:
			foot[c + Vector2i(1, 1)] = true
		for c: Vector3i in cells:
			if not foot.has(Vector2i(c.x, c.z)):
				el_bad.append(c)
		var inside := func(c: Vector3i) -> bool:
			var f := Vector2i(c.x, c.z) - Vector2i(1, 1)
			if c.y < 1 or c.y > 3 * pitch + 1:
				return false
			for dz in [-1, 0, 1]:
				for dx in [-1, 0, 1]:
					if not (ell.has(f + Vector2i(dx, dz))):
						return false
			return true
		var seen := _flood(cells, Vector3i(10, 2, 14), inside)
		for sp in el.recipe.meta.structure.spaces:
			if not seen.has(Vector3i(int(sp.seed[0]), int(sp.seed[1]), int(sp.seed[2]))):
				el_lost += 1
	_ok("a drawn L footprint: a tower with nothing outside it, every room reached inside it",
			bool(el.ok) and el_bad.is_empty() and el_lost == 0 and int(el.stats.modules) > 0,
			"%s, %d brick cell(s) outside, %d room(s) not reached" % [
				str(el.get("stats", el.get("why", ""))), el_bad.size(), el_lost])

	# Setbacks: 3 studs in every 2 storeys; a rail round each terrace.
	var sb := RoomShell.generate(lib, {"seed": 4, "width": 44, "depth": 36, "storeys": 6, "setback": 3,
			"setback_every": 2})
	var sb_bad := []
	if sb.ok:
		var cells := _cells(sb.recipe)
		for s in 6:
			@warning_ignore("integer_division")
			var k := 3 * (s / 2)
			var y := s * pitch + 5
			# Its west wall at x = k (laid k + 1), nothing west of it.
			if not cells.has(Vector3i(k + 1, y, 18)) or cells.has(Vector3i(k, y, 18)) and k > 0:
				sb_bad.append("storey %d: west wall not at %d" % [s, k])
		for s in [2, 4]:
			@warning_ignore("integer_division")
			var k: int = 3 * ((int(s) - 1) / 2)
			if not cells.has(Vector3i(k + 1, s * pitch + 1, 18)):
				sb_bad.append("no rail round the terrace at storey %d" % s)
		var inside := func(c: Vector3i) -> bool:
			if c.y < 1 or c.y > 6 * pitch + 1:
				return false
			@warning_ignore("integer_division")
			var k := 3 * (mini(c.y / pitch, 5) / 2)
			if c.y % pitch == 0 and c.y > 0:
				@warning_ignore("integer_division")
				k = maxi(k, 3 * (mini(c.y / pitch - 1, 5) / 2))
			return c.x >= k + 2 and c.x <= 44 - k - 1 and c.z >= k + 2 and c.z <= 36 - k - 1
		var seen := _flood(cells, Vector3i(10 + 6, 2, 18), inside)
		for sp in sb.recipe.meta.structure.spaces:
			if not seen.has(Vector3i(int(sp.seed[0]), int(sp.seed[1]), int(sp.seed[2]))):
				sb_bad.append("room %s not reached" % str(sp.seed))
	_ok("setbacks: each pair of storeys 3 studs in, a rail round each terrace, every room reached",
			bool(sb.ok) and sb_bad.is_empty(), str(sb.get("why", "")) + str(sb_bad.slice(0, 4)))

	# The lift: a shaft beside the hall, open from the ground to the top storey.
	var lifts: Array = made[0].recipe.meta.get("lifts", [])
	var shaft_bad := 0
	if lifts.size() == 1:
		var cells := _cells(made[0].recipe)
		var lo := BuildRecipe.cell_from(lifts[0].lo)
		for y in range(1, 3 * pitch + 1):
			for z in 4:
				for x in 4:
					if cells.has(Vector3i(lo.x + x, y, lo.z + z)):
						shaft_bad += 1
	_ok("a lift shaft beside the hall, a stop each storey, open from the ground to the top storey",
			lifts.size() == 1 and (lifts[0].stops as Array).size() == 4 and shaft_bad == 0,
			"%s, %d cell(s) in the shaft" % [str(lifts), shaft_bad])

	# A setback on one side: north (+Z) 4 studs every 2 storeys, the rest straight.
	var ns := RoomShell.generate(lib, {"seed": 3, "width": 44, "depth": 36, "storeys": 4, "setback": 4,
			"setback_every": 2, "setback_sides": "n"})
	var ns_bad := []
	if ns.ok:
		var cells := _cells(ns.recipe)
		for st in 4:
			var y := st * pitch + 2
			var north := 36 - (4 if st >= 2 else 0)
			if not cells.has(Vector3i(1, y, 20)):
				ns_bad.append("storey %d: no west wall at 1" % st)
			if not cells.has(Vector3i(44, y, 20)):
				ns_bad.append("storey %d: no east wall at 44" % st)
			if not cells.has(Vector3i(30, y, 1)):
				ns_bad.append("storey %d: no south wall at 1" % st)
			if not cells.has(Vector3i(30, y, north)) or cells.has(Vector3i(30, y, north + 1)):
				ns_bad.append("storey %d: north wall not at %d" % [st, north])
	_ok("a setback on the north side only: that wall steps in, the others go straight up",
			bool(ns.ok) and ns_bad.is_empty(), str(ns.get("why", "")) + str(ns_bad))

	# Stair links and facade spots: modules made for them, weighted up.
	var recs := Kit.modules()
	recs.append(Kit.box("stair_lo", 10, 10, {"role": "room", "weight": 4.0}, [[1, 4, "auto"], [3, 4, "auto"]],
			[], [["stair_up", [8, Kit.H, 5], -1]]))
	recs.append(Kit.box("stair_hi", 10, 10, {"role": "room", "storeys": "upper", "weight": 4.0},
			[[1, 4, "auto"], [3, 4, "auto"]], [], [["stair_down", [8, 1, 5], -1]]))
	recs.append(Kit.box("bay", 10, 10, {"role": "room", "weight": 3.0}, [[1, 4, "auto"], [3, 4, "auto"]],
			[], [["window", [7, 4, 0], 3], ["balcony", [1, 5, 0], 3]]))
	recs.append(Kit.box("perch", 10, 10, {"role": "room", "weight": 3.0}, [[1, 4, "auto"], [3, 4, "auto"]],
			[], [["hang", [7, 5, 0], 3]]))
	# A window spot on a door's cells: on the outer wall the door is walled up, and the window cut through the cap.
	recs.append(Kit.box("hatch", 10, 10, {"role": "room", "weight": 3.0}, [[1, 4, "auto"], [3, 4, "auto"]],
			[], [["window", [4, 4, 0], 3]]))
	var slib := RoomModules.from_recipes(recs)
	var hung := 0
	var hang_bad := []
	var stacked := 0
	var stack_bad := []
	var balconies := 0
	var facade_n := 0
	var shut := 0
	var glass_m := RoomGrow._glass()
	for sd in range(1, 7):
		var t := RoomShell.generate(slib, {"seed": sd, "width": 44, "depth": 28, "storeys": 4, "balcony": 1.0, "hang": 1.0})
		if not t.ok:
			stack_bad.append("seed %d: %s" % [sd, t.why])
			continue
		stacked += int(t.stats.stairs)
		balconies += int(t.stats.balconies)
		facade_n += int(t.stats.windows)
		var cells := _cells(t.recipe)
		var at: Vector3i = t.plan.at
		# Rooms hung at hang spots: clear of every other module, open to the room they hang from.
		for hi in (t.plan.placed as Array).size():
			var hp: Dictionary = t.plan.placed[hi]
			if not hp.has("from"):
				continue
			hung += 1
			var htd: Dictionary = slib[hp.m].turns[hp.t]
			for oi in (t.plan.placed as Array).size():
				var op: Dictionary = t.plan.placed[oi]
				if oi == hi:
					continue
				var otd: Dictionary = slib[op.m].turns[op.t]
				for c: Vector2i in htd.cols:
					var w := Vector2i(c.x + hp.off.x, c.y + hp.off.z)
					var oc := w - Vector2i(op.off.x, op.off.z)
					if otd.cols.has(oc):
						var a: Vector2i = htd.cols[c]
						var b: Vector2i = otd.cols[oc]
						if a.x + hp.off.y < b.y + op.off.y and b.x + op.off.y < a.y + hp.off.y:
							hang_bad.append("seed %d: hung room %d in module %d" % [sd, hi, oi])
							break
			var fp: Dictionary = t.plan.placed[int(hp.from)]
			var fs: Dictionary = slib[fp.m].turns[fp.t].spaces.values()[0]
			var hs: Dictionary = htd.spaces.values()[0]
			var f_off: Vector3i = (fp.off as Vector3i) + at
			var h_off: Vector3i = (hp.off as Vector3i) + at
			var two := {}
			for c: Vector2i in fs.cols:
				two[Vector2i(c.x + f_off.x, c.y + f_off.z)] = true
			for c: Vector2i in hs.cols:
				two[Vector2i(c.x + h_off.x, c.y + h_off.z)] = true
			# The doorway between them: the wall cells the hole goes through.
			var y_lo := mini(int(fs.floor_y) + f_off.y, int(hs.floor_y) + h_off.y)
			var y_hi := maxi(int(fs.ceil_y) + f_off.y, int(hs.ceil_y) + h_off.y)
			var near := func(c: Vector3i) -> bool:
				if c.y <= y_lo or c.y >= y_hi:
					return false
				var v := Vector2i(c.x, c.z)
				if two.has(v):
					return true
				for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
					# The tower's wall and the hung room's own: two cells thick.
					if two.has(v + d) and (two.has(v - d) or two.has(v - d * 2)):
						return true
				return false
			var start := Vector3i(int(fs.seed.x) + f_off.x, int(fs.floor_y) + f_off.y + 1, int(fs.seed.z) + f_off.z)
			var goal := Vector3i(int(hs.seed.x) + h_off.x, int(hs.floor_y) + h_off.y + 1, int(hs.seed.z) + h_off.z)
			if not _flood(cells, start, near).has(goal):
				hang_bad.append("seed %d: hung room %d not open to its room" % [sd, hi])
		var stair_cols := {}
		for st: Array in t.plan.stacks:
			var lo: Dictionary = t.plan.placed[int(st[0].p)]
			var hi: Dictionary = t.plan.placed[int(st[1].p)]
			var ls: Dictionary = slib[lo.m].turns[lo.t].spaces[int(st[0].space)]
			var us: Dictionary = slib[hi.m].turns[hi.t].spaces[int(st[1].space)]
			var lo_off: Vector3i = (lo.off as Vector3i) + at
			var hi_off: Vector3i = (hi.off as Vector3i) + at
			var cols := {}
			for c: Vector2i in ls.cols:
				cols[Vector2i(c.x + lo_off.x, c.y + lo_off.z)] = true
				stair_cols[Vector2i(c.x + lo_off.x, c.y + lo_off.z)] = true
			for c: Vector2i in us.cols:
				cols[Vector2i(c.x + hi_off.x, c.y + hi_off.z)] = true
			var y0 := int(ls.floor_y) + lo_off.y
			var y1 := int(us.ceil_y) + hi_off.y
			var inside := func(c: Vector3i) -> bool:
				return c.y > y0 and c.y < y1 and cols.has(Vector2i(c.x, c.z))
			var start := Vector3i(int(ls.seed.x) + lo_off.x, y0 + 1, int(ls.seed.z) + lo_off.z)
			var goal := Vector3i(int(us.seed.x) + hi_off.x, int(us.floor_y) + hi_off.y + 1, int(us.seed.z) + hi_off.z)
			# Only through the two rooms' own columns: up the stair's hole.
			if not _flood(cells, start, inside).has(goal):
				stack_bad.append("seed %d: room over %s not open to the one under it" % [sd, str(st[0].at)])
		# Facade windows: cut cells hold glass or nothing (stair steps apart).
		var solid := {}
		for i in t.recipe.size():
			if t.recipe.material_of(i) == glass_m and glass_m >= 0:
				continue
			var c: Vector3i = t.recipe.cell_of(i)
			var sz: Vector3i = BuildRecipe.part_size(t.recipe.part_of(i))
			for y in sz.y:
				for z in sz.z:
					for x in sz.x:
						solid[c + Vector3i(x, y, z)] = true
		for c: Vector3i in t.plan.cuts:
			var w := c + at
			if solid.has(w) and not stair_cols.has(Vector2i(w.x, w.z)):
				shut += 1
	_ok("stair links stacked: a module with a link down over each one with a link up it could, the room below open to the room above",
			stacked > 0 and stack_bad.is_empty(), "%d stair(s) in 6 towers %s" % [stacked, str(stack_bad.slice(0, 3))])
	_ok("hang spots on the outer wall: a room hung there, clear of every module, open to its room",
			hung > 0 and hang_bad.is_empty(), "%d hung in 6 towers %s" % [hung, str(hang_bad.slice(0, 3))])
	_ok("module facade spots on the outer wall: windows cut (or glazed), balconies built out",
			facade_n > 0 and balconies > 0 and shut == 0,
			"%d window(s), %d balcony(ies), %d cut cell(s) still solid" % [facade_n, balconies, shut])

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


func _inside_box(w: int, d: int, top: int) -> Callable:
	return func(c: Vector3i) -> bool:
		return c.x >= 2 and c.z >= 2 and c.x <= w - 1 and c.z <= d - 1 and c.y >= 1 and c.y <= top


## Air inside the footprint (inside the outer walls, `inside` says) reached
## from `start`, and the row over the roof.
func _flood(cells: Dictionary, start: Vector3i, inside: Callable) -> Dictionary:
	var seen := {start: true}
	var todo: Array[Vector3i] = [start]
	var dirs := [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 1, 0), Vector3i(0, -1, 0),
			Vector3i(0, 0, 1), Vector3i(0, 0, -1)]
	while not todo.is_empty():
		var c: Vector3i = todo.pop_back()
		for dv in dirs:
			var n: Vector3i = c + dv
			if seen.has(n) or cells.has(n) or not inside.call(n):
				continue
			seen[n] = true
			todo.append(n)
	return seen
