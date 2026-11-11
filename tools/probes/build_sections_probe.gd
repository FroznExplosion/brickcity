extends SceneTree
## Sections of a generated build (Docs/RoomModules.md 7.1, stage 8): the parts
## a station or a ship will be made of, with the test modules of
## tools/room_module_kit.gd (no workshop).
##
##     godot --headless --path . --script res://tools/probes/build_sections_probe.gd
##
##   grow      a grown building cut under a small budget: several sections, each
##             under it (or one module alone), the start's in the root
##   whole     no module's bricks in two sections
##   joints    every section but the root touches another; joints a < b
##   split     the sections laid as builds of their own and moved back are the
##             same bricks as the one build; every room and door in one of them
##   tower     a tower cut in bands of whole storeys, the ground's the root; a
##             lift a section that has two of its stops
##   record    each brick's section read back from the build's meta; an edited
##             build's sections are stale (none)
##   default   the default budget: what an ordinary grown building and tower make

const Kit := preload("res://tools/room_module_kit.gd")

var _pass := 0
var _fail := 0


func _init() -> void:
	print("build sections probe")
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
	var plan := RoomGrow.grow(lib, {"seed": 3, "rooms": 14, "path": 4, "section_bricks": 2500})
	if not plan.ok:
		_ok("a building grows", false, String(plan.why))
		return
	var t0 := Time.get_ticks_usec()
	var r := RoomGrow.lay(lib, plan)
	var ms := (Time.get_ticks_usec() - t0) / 1000.0
	var m: Dictionary = r.meta.sections
	var of := BuildSections.of_build(r)
	var cells := BuildSections._cells(r, of)
	var secs: Array = m.sections
	var over := 0
	for s: Dictionary in secs:
		if int(s.bricks) > 2500:
			over += 1
	# The start's module: its bricks in the root.
	var start: Dictionary = plan.placed[int(plan.path[0])]
	var root_ok := true
	var whole := 0
	for i in plan.placed.size():
		var pl: Dictionary = plan.placed[i]
		var tr: BuildRecipe = lib[pl.m].turns[pl.t].recipe
		var in_secs := {}
		for k in tr.size():
			var c: Vector3i = tr.cell_of(k) + (pl.off as Vector3i)
			if cells.has(c):
				in_secs[int(cells[c])] = true
		if in_secs.size() > 1:
			whole += 1
		if pl == start and not (in_secs.size() == 1 and int(in_secs.keys()[0]) == 0 and bool(secs[0].root)):
			root_ok = false
	_ok("a grown building under a 2500-brick budget: several sections, each under it, the start's the root",
			secs.size() > 1 and over == 0 and root_ok,
			"%d modules, %d bricks -> %d section(s) %s, %d over, cut in %.1f ms with the lay" % [
				plan.placed.size(), r.size(), secs.size(), str(secs.map(func(s) -> int: return int(s.bricks))),
				over, ms])
	_ok("no module's bricks in two sections", whole == 0, "%d split" % whole)
	var touched := {0: true}
	var bad_pair := 0
	for j: Dictionary in m.joints:
		if int(j.a) >= int(j.b) or int(j.cells) <= 0:
			bad_pair += 1
		touched[int(j.a)] = true
		touched[int(j.b)] = true
	_ok("every section touches another at a joint", touched.size() == secs.size() and bad_pair == 0,
			"%d joint(s) %s" % [(m.joints as Array).size(), str((m.joints as Array).map(func(j) -> String:
				return "%d-%d:%d" % [j.a, j.b, j.cells]))])

	# Split and put back.
	var parts := BuildSections.split(r)
	var want := _bag(r, Vector3i.ZERO)
	var got := {}
	var rooms := 0
	var doors := 0
	for p: Dictionary in parts:
		var b := _bag(p.recipe, p.offset)
		for k in b:
			got[k] = int(got.get(k, 0)) + int(b[k])
		rooms += (p.recipe.meta.structure.spaces as Array).size()
		doors += (p.recipe.meta.get("doors", []) as Array).size()
	var same := want.size() == got.size()
	for k in want:
		same = same and int(got.get(k, 0)) == int(want[k])
	_ok("the sections as builds of their own, moved back: the same bricks; every room and door in one",
			parts.size() == secs.size() and same and rooms == (r.meta.structure.spaces as Array).size()
			and doors == (r.meta.get("doors", []) as Array).size(),
			"%d part(s), %d brick kind(s) at cells, %d room(s), %d door(s)" % [parts.size(), got.size(), rooms, doors])

	# A tower: bands of storeys.
	var shell := RoomShell.generate(lib, {"seed": 2, "width": 44, "depth": 28, "storeys": 6,
			"section_bricks": 9000})
	var tr2: BuildRecipe = shell.recipe
	var sm: Dictionary = tr2.meta.sections
	var pitch := int(shell.stats.pitch)
	var sof := BuildSections.of_build(tr2)
	var bands := {}
	for i in tr2.size():
		@warning_ignore("integer_division")
		var st := clampi(tr2.cell_of(i).y / pitch, 0, 5)
		var k := int(sof[i])
		if not bands.has(k):
			bands[k] = {}
		bands[k][st] = true
	var bands_ok := String(sm.kind) == "storey" and (sm.sections as Array).size() > 1
	var lo_prev := -1
	for k in range((sm.sections as Array).size()):
		var sts: Array = (bands.get(k, {}) as Dictionary).keys()
		sts.sort()
		bands_ok = bands_ok and not sts.is_empty() and int(sts[0]) == lo_prev + 1 \
				and int(sts[-1]) - int(sts[0]) + 1 == sts.size()
		if not sts.is_empty():
			lo_prev = int(sts[-1])
	var tparts := BuildSections.split(tr2)
	var lifts_ok := true
	for p: Dictionary in tparts:
		for lf in p.recipe.meta.get("lifts", []):
			lifts_ok = lifts_ok and (lf.stops as Array).size() >= 2
	var with_lift := tparts.filter(func(p) -> bool: return not (p.recipe.meta.get("lifts", []) as Array).is_empty()).size()
	_ok("a tower cut in bands of whole storeys from the ground up; a lift in each band with two stops",
			bands_ok and lifts_ok and with_lift == tparts.size(),
			"%d bricks, sections %s, storeys %s, %d with a lift" % [tr2.size(),
				str((sm.sections as Array).map(func(s) -> int: return int(s.bricks))),
				str(bands.values().map(func(d) -> Array: return (d as Dictionary).keys())), with_lift])

	# The record.
	var cut := BuildSections.of_plan(lib, plan, r, Vector3i.ZERO, 2500)
	var back := BuildSections.of_build(r)
	r.add("plate_1x1", Vector3i(0, 40, 0), 1)
	_ok("each brick's section read back from the meta; an edited build's sections stale",
			back == cut.of and BuildSections.of_build(r).is_empty() and BuildSections.split(r).size() == 1,
			"%d run(s) for %d bricks" % [(m.of as Array).size(), back.size()])

	# The default budget.
	var plain := RoomGrow.grow(lib, {"seed": 3, "rooms": 14, "path": 4})
	var pr := RoomGrow.lay(lib, plain)
	var big := RoomShell.generate(lib, {"seed": 2, "width": 44, "depth": 28, "storeys": 12})
	_ok("the default budget (%d): an ordinary building and a 12-storey tower" % BuildSections.BUDGET,
			(pr.meta.sections.sections as Array).size() >= 1 and (big.recipe.meta.sections.sections as Array).size() > 1,
			"grown %d bricks -> %d, tower %d bricks -> %s" % [pr.size(), (pr.meta.sections.sections as Array).size(),
				big.recipe.size(), str((big.recipe.meta.sections.sections as Array).map(func(s) -> int: return int(s.bricks)))])


## A build's bricks as {"part cell colour material": n}, its cells moved by `off`.
func _bag(r: BuildRecipe, off: Vector3i) -> Dictionary:
	var out := {}
	for i in r.size():
		var k := "%s %s %d %d" % [r.part_of(i), str(r.cell_of(i) + off), r.colour_of(i), r.material_of(i)]
		out[k] = int(out.get(k, 0)) + 1
	return out
