extends SceneTree
## Ship interiors (Docs/RoomModules.md 7.4, stage 11): rooms packed into a hull,
## with the test modules of tools/room_module_kit.gd and ship modules made here
## (bridge, engine room, reactor, quarters, cargo), in a test hull built here
## (no workshop).
##
##     godot --headless --path . --script res://tools/room_pack_probe.gd
##
##   decks     a 96 x 28 hull 43 plates high, narrowing fore: three decks, each
##             inside the hull at every row
##   inside    no brick of the rooms outside the hull
##   zones     the bridge fore, the engine room aft, the reactor at the core, each
##             placed once (their `min`)
##   fill      most of the inside is rooms (the spine, modules, filler, nooks), some
##             module walls standing in the hull's
##   reach     every room but the closed nooks reached through the air from the well
##   bulkheads a bulkhead every 32 studs, a door in it at the spine on every
##             deck, no module across one; each stretch a section, the bridge's
##             the root
##   passes    more passes keep the best fill; the same seed the same ship
##   turned    a hull long along Z is turned to run along X
##   none      no hull says so

const Kit := preload("res://tools/room_module_kit.gd")
const LEN := 96
const WIDE := 28
const PITCH := 14
const DECKS := 3

var _pass := 0
var _fail := 0


func _init() -> void:
	print("room pack probe: ship interiors")
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


## The test hull: plates a stud thick, floor at row 1, roof at 1 + DECKS * PITCH,
## its half-width falling from 13 to 6 over the fore quarter (+X).
static func hull(long_z := false) -> BuildRecipe:
	var r := BuildRecipe.new()
	r.name = "test hull"
	var top := 1 + DECKS * PITCH
	for x in LEN:
		var half := 13
		if x > LEN * 3 / 4:
			half = 13 - int(round(7.0 * (x - LEN * 3 / 4) / (LEN / 4)))
		var cz := 14
		for z in range(cz - half, cz + half + 1):
			for y in range(1, top + 1):
				var wall := absi(z - cz) == half or x == 0 or x == LEN - 1 or y == 1 or y == top
				if wall:
					r.add("plate_1x1", Vector3i(z, y, x) if long_z else Vector3i(x, y, z), 9, 0)
	return r


func _modules() -> Array:
	var recs := Kit.modules()
	var two := [[1, 3, "auto"], [3, 3, "auto"]]
	recs.append(Kit.box("bridge", 8, 8, {"role": "room", "zone": "fore", "min": 1, "max": 1}, two))
	recs.append(Kit.box("engine room", 12, 8, {"role": "room", "zone": "aft", "min": 1, "max": 1}, two))
	recs.append(Kit.box("reactor", 6, 6, {"role": "room", "zone": "core", "min": 1, "max": 1}, two))
	recs.append(Kit.box("quarters", 6, 6, {"role": "room", "weight": 3.0}, two))
	recs.append(Kit.box("cargo", 12, 8, {"role": "room", "zone": "hull"}, two))
	# A cabin as deep as the band south of the spine with the hull for its back wall.
	recs.append(Kit.box("cabin", 6, 9, {"role": "room", "weight": 4.0}, two))
	return recs


func _run() -> void:
	var lib := RoomModules.from_recipes(_modules())
	var h := hull()
	var t0 := Time.get_ticks_usec()
	var made := RoomPack.generate(lib, {"seed": 3, "hull": h})
	var ms := (Time.get_ticks_usec() - t0) / 1000.0
	if not made.ok:
		_ok("a hull filled", false, String(made.why))
		return
	var st: Dictionary = made.stats
	var r: BuildRecipe = made.recipe
	print("    %s, %.0f ms for %d passes" % [str(st), ms, int(st.passes)])

	var hull_cells := _cells(h)
	var out_rows := {}
	var deck_bad := 0
	_ok("a 96 x 28 hull 43 plates high: three decks", int(st.decks) == DECKS, "%d deck(s)" % int(st.decks))

	# Nothing of the rooms outside the hull.
	var outside := 0
	var cells := _cells(r)
	for c: Vector3i in cells:
		if hull_cells.has(c):
			continue
		if not out_rows.has(c.y):
			out_rows[c.y] = _outside(hull_cells, c.y)
		if (out_rows[c.y] as Dictionary).has(Vector2i(c.x, c.z)):
			outside += 1
	_ok("no brick of the rooms outside the hull, the hull whole", outside == 0 and _all_kept(h, cells),
			"%d outside" % outside)

	# Zones.
	var where := {}
	for pl: Dictionary in made.plan.placed:
		var nm := String(lib[pl.m].name)
		var td: Dictionary = lib[pl.m].turns[pl.t]
		var lo := 1 << 30
		var hi := -(1 << 30)
		for c: Vector2i in td.cols:
			lo = mini(lo, c.x + pl.off.x)
			hi = maxi(hi, c.x + pl.off.x)
		if not where.has(nm):
			where[nm] = []
		where[nm].append((lo + hi) * 0.5 / float(LEN - 1))
	var zone_ok: bool = where.has("bridge") and where.bridge.size() == 1 and float(where.bridge[0]) >= 2.0 / 3.0 \
			and where.has("engine room") and where["engine room"].size() == 1 and float(where["engine room"][0]) < 1.0 / 3.0 \
			and where.has("reactor") and where.reactor.size() == 1 and float(where.reactor[0]) >= 1.0 / 3.0 \
			and float(where.reactor[0]) < 2.0 / 3.0 and String(st.fore) == "+x"
	_ok("the bridge fore, the engine room aft, the reactor at the core, once each; fore the narrow end",
			zone_ok and int(st.short) == 0, "fore %s, %s" % [st.fore, str(where)])

	_ok("most of the inside is rooms: the spine, modules, filler rooms, nooks",
			float(st.fill) >= 0.75 and int(st.in_hull) > 0,
			"fill %.1f%% (%d of %d columns), %d nook(s), %d module(s), %d wall column(s) in the hull's" % [
				float(st.fill) * 100.0, int(st.used), int(st.inside), int(st.nooks), int(st.modules), int(st.in_hull)])

	# Reach: from the well through the air, every room but the closed nooks.
	var spaces: Array = r.meta.structure.spaces
	var start := Vector3i(-1, -1, -1)
	for sp in spaces:
		if String(sp.kind) == "corridor":
			start = Vector3i(int(sp.seed[0]), int(sp.seed[1]), int(sp.seed[2]))
			break
	var seen := _flood(cells, start, h.bounds())
	var lost := []
	for sp in spaces:
		if String(sp.kind) == "storage":
			continue
		var sd := Vector3i(int(sp.seed[0]), int(sp.seed[1]), int(sp.seed[2]))
		if not seen.has(sd):
			lost.append("%s %s" % [sp.kind, str(sd)])
	_ok("every room but the closed nooks reached through the air from the well",
			start.x >= 0 and lost.is_empty(), "%d room(s), lost %s" % [spaces.size(), str(lost.slice(0, 4))])

	# Bulkheads and sections.
	var segs: Array = made.plan.segments
	var across := 0
	for pl: Dictionary in made.plan.placed:
		for c: Vector2i in lib[pl.m].turns[pl.t].cols:
			if segs.has(c.x + pl.off.x):
				across += 1
	var door_at := 0
	for dr in r.meta.get("doors", []):
		if segs.has(int(dr.lo[0])) and int(dr.size[0]) == 1:
			door_at += 1
	var secs: Array = r.meta.sections.sections
	var root_has_bridge := false
	var of := BuildSections.of_build(r)
	var bcells := BuildSections._cells(r, of)
	for pl: Dictionary in made.plan.placed:
		if String(lib[pl.m].name) == "bridge":
			var tr: BuildRecipe = lib[pl.m].turns[pl.t].recipe
			root_has_bridge = true
			for k in tr.size():
				var c: Vector3i = tr.cell_of(k) + (pl.off as Vector3i)
				if bcells.has(c) and int(bcells[c]) != 0:
					root_has_bridge = false
	_ok("a bulkhead every 32 studs, a door at the spine on every deck, no module across one; a section each stretch, the bridge's the root",
			segs.size() == 2 and across == 0 and door_at == segs.size() * DECKS and secs.size() == segs.size() + 1
			and root_has_bridge, "bulkheads %s, %d door(s) in them, %d module column(s) across, sections %s" % [
				str(segs), door_at, across, str(secs.map(func(s) -> int: return int(s.bricks)))])

	var one := RoomPack.generate(lib, {"seed": 3, "hull": h, "passes": 1})
	var again := RoomPack.generate(lib, {"seed": 3, "hull": h})
	_ok("more passes keep the best fill; the same seed the same ship",
			float(st.fill) >= float(one.stats.fill) and _bag(again.recipe) == _bag(r),
			"1 pass %.1f%%, %d passes %.1f%%" % [float(one.stats.fill) * 100.0, int(st.passes), float(st.fill) * 100.0])

	var tz := RoomPack.generate(lib, {"seed": 3, "hull": hull(true), "passes": 1})
	_ok("a hull long along Z turned to run along X", bool(tz.ok) and int(tz.stats.turned) == 1
			and int(tz.stats.decks) == DECKS, str(tz.get("stats", tz.get("why", ""))))

	var none := RoomPack.generate(lib, {"seed": 1})
	_ok("no hull says so", not bool(none.ok) and String(none.why) != "", String(none.why))


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


func _all_kept(h: BuildRecipe, cells: Dictionary) -> bool:
	for c in _cells(h):
		if not cells.has(c):
			return false
	return true


## The columns of row y reached from outside the hull's bounds.
func _outside(hull_cells: Dictionary, y: int) -> Dictionary:
	var seen := {}
	var todo: Array[Vector2i] = [Vector2i(-2, -2)]
	seen[todo[0]] = true
	while not todo.is_empty():
		var c: Vector2i = todo.pop_back()
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var n: Vector2i = c + d
			if seen.has(n) or n.x < -2 or n.y < -2 or n.x > LEN + 2 or n.y > LEN + 2:
				continue
			if hull_cells.has(Vector3i(n.x, y, n.y)):
				continue
			seen[n] = true
			todo.append(n)
	return seen


func _flood(cells: Dictionary, start: Vector3i, b: Array) -> Dictionary:
	var lo: Vector3i = b[0]
	var hi: Vector3i = (b[0] as Vector3i) + (b[1] as Vector3i)
	var seen := {start: true}
	var todo: Array[Vector3i] = [start]
	var dirs := [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 1, 0), Vector3i(0, -1, 0),
			Vector3i(0, 0, 1), Vector3i(0, 0, -1)]
	while not todo.is_empty():
		var c: Vector3i = todo.pop_back()
		for d in dirs:
			var n: Vector3i = c + d
			if seen.has(n) or cells.has(n) or n.x < lo.x or n.y < lo.y or n.z < lo.z or n.x >= hi.x \
					or n.y >= hi.y or n.z >= hi.z:
				continue
			seen[n] = true
			todo.append(n)
	return seen


func _bag(r: BuildRecipe) -> String:
	var out := PackedStringArray()
	for i in r.size():
		out.append("%s %s %d" % [r.part_of(i), str(r.cell_of(i)), r.colour_of(i)])
	return ",".join(out)
