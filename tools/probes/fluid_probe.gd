extends SceneTree

## Water and lava on the brick grid (BrickFluid, Docs/MineWater.md 4).
##
##     godot --headless --path . --script res://tools/probes/fluid_probe.gd
##
## Every test stands on a flat stone floor laid by terrain edits high above
## the generated world (course FLOOR), so the ground under it is known
## exactly. What each check is for:
## - a source on flat ground reaches 14 studs and stops; levels 3 (the
##   source), 2 (distance 1-7), 1 (8-14): Minecraft's reach, brick to tile;
## - deeper water flows over a tile and not over a brick (R3);
## - still water poured on flat ground keeps every tile while it spreads,
##   stops at a tile deep, and the lone tiles dry later (R5);
## - a stream cut off from its source drains and dries (4.1.6), off a step
##   too (no 2-deep puddles left to keep their edges wet);
## - a gap between two sources fills as a source (4.1.7);
## - water off a ledge falls and spreads again where it lands;
## - still water beside a source drains into it; water at a lava source
##   makes obsidian within a tick; lava beside wood sets it alight;
## - lava meeting water makes obsidian (a source) or stone (running lava),
##   only as thick as the lava was; cut-off lava cools into stone (4.6);
## - a calm world has nothing awake (a still world costs nothing);
## - past the sim ring water waits and runs on when the player is back; a far
##   tile's mesh is a fraction of the full one (stage 5);
## - the generated sea is ocean source at the sea course, and a tile of only
##   sea draws no top (the wave tiers draw it);
## - a big still spill's tick cost, as a number;
## - stage 8: a calm pond's top is one merged quad; generated lava pools in
##   caves under the lava line, drawn once primed and still; springs run; a
##   pit under a fall fills to its rim and spills; lakes over the sea; cave
##   pools with no water beside cave air; a mirror rebuilds an authority's
##   water from its change log (multiplayer groundwork).

const FLOOR := 1000          ## floor course: plates 3000-3002
const W := FLOOR + 1         ## the course water stands in

var _passed := 0
var _failed := 0


func _initialize() -> void:
	_run.call_deferred()


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_passed += 1
	else:
		_failed += 1
	print("  %s %s%s" % ["ok  " if cond else "FAIL", what, ("  (" + detail + ")") if detail != "" else ""])


func _sec(n: String) -> void:
	print("  -- %s at %d ms, %d awake" % [n, Time.get_ticks_msec(), BrickFluid.active_count()])


func _floor(x0: int, z0: int, x1: int, z1: int) -> void:
	var lo := Vector3i(x0, FLOOR * 3, z0)
	var hi := Vector3i(x1, FLOOR * 3 + 2, z1)
	BrickTerrain.fill_box(lo, hi, 4, false)
	BrickFluid.terrain_changed(lo, hi)


func _amt(x: int, b: int, z: int) -> int:
	var c: Dictionary = BrickFluid.cell_info(Vector3i(x, b, z))
	return int(c.amount) if int(c.fluid) != 0 else 0


func _info(x: int, b: int, z: int) -> Dictionary:
	return BrickFluid.cell_info(Vector3i(x, b, z))


func _region_units(x0: int, x1: int, z0: int, z1: int, b: int) -> int:
	var n := 0
	for x in range(x0, x1 + 1):
		for z in range(z0, z1 + 1):
			n += _amt(x, b, z)
	return n


func _settle(max_ticks: int) -> int:
	for i in max_ticks:
		BrickFluid.tick_now(1)
		if BrickFluid.active_count() == 0:
			return i + 1
	return max_ticks


func _run() -> void:
	print("[fluid_probe]")
	BrickTerrain.set_generator(0)
	BrickTerrain.configure(1337)
	BrickTerrain.clear_terrain_edits()
	BrickFluid.reset(20.0, false)
	BrickFluid.set_centre(Vector3(0, 0, 0), 100000.0)

	# 1. A source on flat ground.
	_sec("1")
	_floor(-40, -40, 40, 40)
	BrickFluid.place(Vector3i(0, W, 0), 1, BrickFluid.SOURCE, 3)
	var t := _settle(400)
	_ok("source settles", BrickFluid.active_count() == 0, "%d ticks" % t)
	_ok("source cell is a brick of water", _amt(0, W, 0) == 3)
	_ok("distance 1 and 7 are 2 plates", _amt(1, W, 0) == 2 and _amt(7, W, 0) == 2,
			"%d %d" % [_amt(1, W, 0), _amt(7, W, 0)])
	_ok("distance 8 and 14 are a tile", _amt(8, W, 0) == 1 and _amt(14, W, 0) == 1,
			"%d %d" % [_amt(8, W, 0), _amt(14, W, 0)])
	_ok("distance 15 is dry", _amt(15, W, 0) == 0 and _amt(0, W, 15) == 0)
	_ok("diagonal reach is by path", _amt(7, W, 7) == 1 and _amt(8, W, 8) == 0,
			"%d %d" % [_amt(7, W, 7), _amt(8, W, 8)])
	_ok("flowing kind and distance", int(_info(5, W, 0).kind) == BrickFluid.FLOW
			and int(_info(5, W, 0).dist) == 5)
	var m: Dictionary = BrickFluid.build_tile_mesh(0, 0)
	_ok("its tile has a water mesh", (m.water as Array).size() > 0)

	# 2. Over a tile, not over a brick.
	_sec("2")
	_floor(160, -20, 240, 20)
	BrickTerrain.fill_box(Vector3i(203, W * 3, -20), Vector3i(203, W * 3, 20), 4, false)
	BrickTerrain.fill_box(Vector3i(206, W * 3, -20), Vector3i(206, W * 3 + 2, 20), 4, false)
	BrickFluid.terrain_changed(Vector3i(203, W * 3, -20), Vector3i(206, W * 3 + 2, 20))
	BrickFluid.place(Vector3i(200, W, 0), 1, BrickFluid.SOURCE, 3)
	_settle(400)
	_ok("2-plate water flows over a tile", _amt(203, W, 0) == 1 and _amt(204, W, 0) >= 1,
			"%d %d" % [_amt(203, W, 0), _amt(204, W, 0)])
	_ok("water does not pass a brick", _amt(207, W, 0) == 0)
	# A tile-deep sheet meets a tile: it stops (never above what feeds it).
	BrickTerrain.fill_box(Vector3i(190, W * 3, -20), Vector3i(190, W * 3, 20), 4, false)
	BrickFluid.terrain_changed(Vector3i(190, W * 3, -20), Vector3i(190, W * 3, 20))
	_settle(400)
	_ok("water a tile deep stops at a tile", _amt(191, W, 0) >= 1 and _amt(190, W, 0) == 0,
			"%d %d" % [_amt(191, W, 0), _amt(190, W, 0)])

	# 3. Still water: conserved, stops a tile deep, then dries.
	_sec("3")
	_floor(360, -40, 440, 40)
	BrickFluid.place(Vector3i(400, W, 0), 1, BrickFluid.STILL, 3)
	BrickFluid.place(Vector3i(400, W + 1, 0), 1, BrickFluid.STILL, 3)
	BrickFluid.place(Vector3i(400, W + 2, 0), 1, BrickFluid.STILL, 3)
	BrickFluid.tick_now(1)
	var poured := _region_units(360, 440, -40, 40, W) + _region_units(360, 440, -40, 40, W + 1) 			+ _region_units(360, 440, -40, 40, W + 2)
	_settle(140)
	var held := _region_units(360, 440, -40, 40, W)
	var deepest := 0
	for x in range(380, 421):
		for z in range(-20, 21):
			deepest = maxi(deepest, _amt(x, W, z))
	_ok("poured water is 9 tiles", poured == 9, str(poured))
	_ok("spreading keeps every tile", held == 9, str(held))
	_ok("it stops spreading at a tile deep", deepest <= 2, "deepest %d" % deepest)
	BrickFluid.tick_now(500)
	_ok("lone tiles dry", _region_units(360, 440, -40, 40, W) == 0, str(_region_units(360, 440, -40, 40, W)))

	# 4. A stream cut off from its source drains and dries.
	_sec("4")
	_floor(560, -40, 640, 40)
	BrickFluid.place(Vector3i(600, W, 0), 1, BrickFluid.SOURCE, 3)
	_settle(400)
	var wet_before := _region_units(585, 615, -15, 15, W)
	BrickFluid.remove(Vector3i(600, W, 0), -1)
	BrickFluid.tick_now(80)
	var flowing := 0
	for x in range(585, 616):
		for z in range(-15, 16):
			var c := _info(x, W, z)
			if int(c.fluid) != 0 and int(c.kind) != BrickFluid.STILL:
				flowing += 1
	_ok("no running water once cut off", flowing == 0, "%d" % flowing)
	BrickFluid.tick_now(600)
	_ok("the stream bed dries", _region_units(585, 615, -15, 15, W) == 0,
			"%d of %d" % [_region_units(585, 615, -15, 15, W), wet_before])

	# 4b. Off a step: the cut-off stream leaves no 2-deep puddles to keep
	# its edges wet (decision 13.3: it drains, then dries).
	_floor(1960, -40, 2040, 40)
	BrickTerrain.fill_box(Vector3i(1990, W * 3, -6), Vector3i(1999, W * 3 + 2, 6), 4, false)
	BrickFluid.terrain_changed(Vector3i(1990, W * 3, -6), Vector3i(1999, W * 3 + 2, 6))
	BrickFluid.place(Vector3i(1994, W + 1, 0), 1, BrickFluid.SOURCE, 3)
	_settle(400)
	var step_wet := _region_units(1975, 2015, -25, 25, W) + _region_units(1975, 2015, -25, 25, W + 1)
	BrickFluid.remove(Vector3i(1994, W + 1, 0), -1)
	BrickFluid.tick_now(700)
	var step_left := _region_units(1975, 2015, -25, 25, W) + _region_units(1975, 2015, -25, 25, W + 1)
	_ok("a stream off a step dries", step_left == 0, "%d of %d" % [step_left, step_wet])

	# 4c. A 2-deep core ringed by tile-deep water on flat open ground thins
	# out and dries (4.2); before, the ring never dried beside the core.
	_floor(2160, -30, 2240, 30)
	BrickFluid.place(Vector3i(2200, W, 0), 1, BrickFluid.STILL, 2)
	for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		BrickFluid.place(Vector3i(2200 + d.x, W, d.y), 1, BrickFluid.STILL, 1)
	BrickFluid.tick_now(700)
	_ok("a 2-deep core on flat ground dries", _region_units(2180, 2220, -20, 20, W) == 0,
			str(_region_units(2180, 2220, -20, 20, W)))
	# ... and a pond in a pit keeps every tile.
	# A 2 x 2 pit a brick deep: 9 tiles in 4 cells stand 2 and 3 deep.
	BrickTerrain.fill_box(Vector3i(2171, W * 3, 16), Vector3i(2174, W * 3 + 2, 19), 4, false)
	BrickTerrain.fill_box(Vector3i(2172, W * 3, 17), Vector3i(2173, W * 3 + 2, 18), 0, false)
	BrickFluid.terrain_changed(Vector3i(2171, W * 3, 16), Vector3i(2174, W * 3 + 2, 19))
	BrickFluid.place(Vector3i(2172, W, 17), 1, BrickFluid.STILL, 3)
	BrickFluid.place(Vector3i(2172, W, 18), 1, BrickFluid.STILL, 3)
	BrickFluid.place(Vector3i(2173, W, 18), 1, BrickFluid.STILL, 3)
	BrickFluid.tick_now(700)
	_ok("a pond in a pit keeps its tiles", _region_units(2172, 2173, 17, 18, W) == 9,
			str(_region_units(2172, 2173, 17, 18, W)))

	# 4d. A calm pond's top is merged (stage 8): an 8 x 8 pond two plates
	# deep in walls is one flat quad on top, not 64.
	_floor(2760, -10, 2800, 30)
	for wall in [[2770, 0, 2779, 0], [2770, 9, 2779, 9], [2770, 0, 2770, 9], [2779, 0, 2779, 9]]:
		BrickTerrain.fill_box(Vector3i(wall[0], W * 3, wall[1]), Vector3i(wall[2], W * 3 + 2, wall[3]), 4, false)
	BrickFluid.terrain_changed(Vector3i(2770, W * 3, 0), Vector3i(2779, W * 3 + 2, 9))
	for x in range(2771, 2779):
		for z in range(1, 9):
			BrickFluid.place(Vector3i(x, W, z), 1, BrickFluid.STILL, 2)
	_settle(50)
	var pm: Dictionary = BrickFluid.build_tile_mesh(floori(2771 / 32.0), 0)
	var ups := 0
	var nrm: PackedVector3Array = pm.water[Mesh.ARRAY_NORMAL]
	for n in nrm:
		if n.y > 0.99:
			ups += 1
	_ok("a calm pond's top is one quad", ups == 4, "%d top vertices" % ups)

	# 4e. A pit filling from a river (4.5, stage 8): a fall into a closed pit
	# fills it a course at a time to its rim, then spills over.
	_floor(2900, -20, 2960, 20)
	for wall in [[2920, -5, 2930, -5], [2920, 5, 2930, 5], [2920, -5, 2920, 5], [2930, -5, 2930, 5]]:
		BrickTerrain.fill_box(Vector3i(wall[0], W * 3, wall[1]), Vector3i(wall[2], (W + 2) * 3 + 2, wall[3]), 4, false)
	# A pillar over the pit's middle with a source on it.
	BrickTerrain.fill_box(Vector3i(2925, (W + 4) * 3, 0), Vector3i(2925, (W + 4) * 3 + 2, 0), 4, false)
	BrickFluid.terrain_changed(Vector3i(2920, W * 3, -5), Vector3i(2930, (W + 4) * 3 + 2, 5))
	BrickFluid.place(Vector3i(2925, W + 5, 0), 1, BrickFluid.SOURCE, 3)
	BrickFluid.tick_now(900)
	var pit_full := 0
	for b in range(W, W + 3):
		for x in range(2921, 2930):
			for z in range(-4, 5):
				var pc: Dictionary = _info(x, b, z)
				if int(pc.fluid) == 1 and int(pc.kind) == BrickFluid.STILL and int(pc.amount) == 3:
					pit_full += 1
	var outside := _region_units(2900, 2918, -20, 20, W)
	_ok("a pit under a fall fills to its rim", pit_full >= 9 * 9 * 3 - 3, "%d of %d cells full" % [pit_full, 9 * 9 * 3])
	_ok("and spills over it", outside > 0, "%d tiles outside" % outside)

	# 4f. Still water touching a source drains into it (the user, 2026-11-19:
	# finite water meeting the sea joins the sea).
	_floor(3260, -10, 3300, 10)
	BrickFluid.place(Vector3i(3280, W, 0), 1, BrickFluid.SOURCE, 3)
	BrickFluid.tick_now(2)
	BrickFluid.place(Vector3i(3281, W, 0), 1, BrickFluid.STILL, 3)
	BrickFluid.tick_now(1)
	var beside := 0
	for x in range(3281, 3300):
		for z in range(-9, 10):
			var c: Dictionary = _info(x, W, z)
			if int(c.fluid) == 1 and int(c.kind) == BrickFluid.STILL:
				beside += int(c.amount)
	_ok("still water beside a source drains into it", beside == 0, "%d still tiles left" % beside)

	# 4g. Minecraft's meeting, at once: water reaching a lava SOURCE makes it
	# obsidian within a tick (not on lava's slow tick); lava beside wood sets
	# it alight.
	_floor(3360, -10, 3400, 10)
	BrickTerrain.fill_box(Vector3i(3384, W * 3, 0), Vector3i(3384, W * 3 + 2, 0),
			BrickTerrain.material_names().find("wood"), false)
	BrickFluid.terrain_changed(Vector3i(3384, W * 3, 0), Vector3i(3384, W * 3 + 2, 0))
	BrickFluid.place(Vector3i(3383, W, 0), 2, BrickFluid.SOURCE, 3)
	BrickFluid.tick_now(1)
	BrickFluid.take()
	BrickFluid.tick_now(5)
	var lit: PackedInt32Array = BrickFluid.take().get("fire", PackedInt32Array())
	_ok("lava beside wood sets it alight", lit.size() >= 3 and lit[0] == 3384, str(lit))
	# Water poured onto the lava source from above.
	BrickFluid.place(Vector3i(3383, W + 1, 0), 1, BrickFluid.SOURCE, 3)
	BrickFluid.tick_now(2)
	var rk: PackedInt32Array = BrickFluid.take().terrain
	var obs := false
	for i in range(0, rk.size(), 5):
		if rk[i] == 3383 and rk[i + 4] == BrickTerrain.material_names().find("obsidian"):
			obs = true
	_ok("water at a lava source makes obsidian at once", obs, str(rk))

	# 5. A gap between two sources fills as a source.
	_sec("5")
	_floor(760, -20, 840, 20)
	BrickFluid.place(Vector3i(800, W, 0), 1, BrickFluid.SOURCE, 3)
	BrickFluid.place(Vector3i(802, W, 0), 1, BrickFluid.SOURCE, 3)
	_settle(400)
	_ok("two sources make a third", int(_info(801, W, 0).kind) == BrickFluid.SOURCE)

	# 6. Off a ledge: falls, spreads again where it lands.
	_sec("6")
	_floor(960, -30, 1040, 30)
	BrickTerrain.fill_box(Vector3i(1000, W * 3, 0), Vector3i(1000, (W + 3) * 3 + 2, 0), 4, false)
	BrickFluid.terrain_changed(Vector3i(1000, W * 3, 0), Vector3i(1000, (W + 3) * 3 + 2, 0))
	BrickFluid.place(Vector3i(1000, W + 4, 0), 1, BrickFluid.SOURCE, 3)
	_settle(400)
	_ok("water falls off the pillar", int(_info(1001, W + 2, 0).kind) == BrickFluid.FALL
			or int(_info(1000, W + 2, 1).kind) == BrickFluid.FALL)
	_ok("and spreads where it lands", _amt(1006, W, 0) > 0 and _amt(1000, W, 6) > 0)

	# 7. Lava meets water.
	_sec("7")
	_floor(1160, -20, 1240, 20)
	# Lava alone first: water's reach (14) would cover all of lava's.
	BrickFluid.place(Vector3i(1200, W, 0), 2, BrickFluid.SOURCE, 3)
	BrickFluid.tick_now(120)
	_ok("lava's reach is 6", int(_info(1194, W, 0).fluid) == 2 and int(_info(1193, W, 0).fluid) == 0,
			"%d %d" % [int(_info(1194, W, 0).fluid), int(_info(1193, W, 0).fluid)])
	BrickFluid.take()
	BrickFluid.place(Vector3i(1210, W, 0), 1, BrickFluid.SOURCE, 3)
	BrickFluid.tick_now(120)
	var res: Dictionary = BrickFluid.take()
	var terr: PackedInt32Array = res.terrain
	# (x, z, first plate, last plate, material) a cell.
	var mat_names := BrickTerrain.material_names()
	var obsidian := mat_names.find("obsidian")
	var stone := mat_names.find("stone")
	var mats := {}
	var thin := 0
	for i in range(0, terr.size(), 5):
		mats[terr[i + 4]] = true
		if terr[i + 2] == terr[i + 3]:
			thin += 1
	_ok("lava and water make rock", terr.size() > 0, "%d cells" % (terr.size() / 5))
	_ok("running lava makes stone, a source obsidian", mats.has(stone) and mats.has(obsidian),
			str(mats.keys()))
	_ok("rock is as thick as the lava was (a tile of lava, a tile of rock)", thin > 0,
			"%d one-plate cells" % thin)

	# 7b. Lava cut off from its source comes to rest and cools into stone.
	_floor(2560, -20, 2640, 20)
	BrickFluid.place(Vector3i(2600, W, 0), 2, BrickFluid.SOURCE, 3)
	BrickFluid.tick_now(120)
	BrickFluid.take()
	BrickFluid.remove(Vector3i(2600, W, 0), -1)
	BrickFluid.tick_now(900)
	var cooled := 0
	var t7: PackedInt32Array = BrickFluid.take().terrain
	for i in range(0, t7.size(), 5):
		if t7[i + 4] == stone:
			cooled += 1
	var lava_left := 0
	for x in range(2590, 2611):
		for z in range(-10, 11):
			if int(_info(x, W, z).fluid) == 2:
				lava_left += 1
	_ok("cut-off lava cools into stone", cooled > 0 and lava_left == 0,
			"%d cells cooled, %d lava left" % [cooled, lava_left])

	# 8. Calm costs nothing.
	_sec("8")
	_settle(2000)
	_ok("a calm world has nothing awake", BrickFluid.active_count() == 0,
			str(BrickFluid.active_count()))

	# 8b. The sim ring (stage 5, MineWater.md 6, 8): water out of reach
	# waits, frozen, and runs on when the player comes back; a tile out there
	# shows a far mesh, a quad per 4 x 4 studs.
	_floor(2360, -30, 2440, 30)
	BrickFluid.set_centre(Vector3(0, 0, 0), 100.0)      # 2400 studs = 840 m away
	BrickFluid.place(Vector3i(2400, W, 0), 1, BrickFluid.SOURCE, 3)
	BrickFluid.tick_now(60)
	var frozen := int(BrickFluid.stats().frozen)
	_ok("water past the sim ring waits", _amt(2403, W, 0) == 0 and frozen > 0,
			"%d frozen, %d at 3 studs" % [frozen, _amt(2403, W, 0)])
	BrickFluid.set_centre(Vector3(2400 * 0.35, 0, 0), 100.0)
	_settle(400)
	_ok("and runs on when the player comes back", _amt(2410, W, 0) == 1 and BrickFluid.active_count() == 0,
			"%d" % _amt(2410, W, 0))
	BrickFluid.take()
	var ftx := floori(2400 / 32.0)
	BrickFluid.request_far_mesh(ftx, 0)
	BrickFluid.request_mesh(ftx + 1, 0)
	BrickFluid.tick_now(1)
	var outs: Array = BrickFluid.take().meshes
	var far_v := -1
	var near_v := -1
	for mo in outs:
		var arr: Array = mo.water
		var nv := 0 if arr.is_empty() else (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
		if bool(mo.far) and mo.tile == Vector2i(ftx, 0):
			far_v = nv
		elif not bool(mo.far) and mo.tile == Vector2i(ftx + 1, 0):
			near_v = nv
	var full: Dictionary = BrickFluid.build_tile_mesh(ftx, 0)
	var full_v := (full.water[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	_ok("a far mesh is a fraction of the full one", far_v > 0 and far_v * 4 < full_v,
			"far %d, full %d vertices (neighbour tile %d)" % [far_v, full_v, near_v])
	BrickFluid.set_centre(Vector3(0, 0, 0), 100000.0)

	# 9. Cost: a big spill.
	_sec("9")
	_floor(1500, -60, 1620, 60)
	for x in range(1540, 1580):
		for z in range(-20, 20):
			BrickFluid.place(Vector3i(x, W + 3, z), 1, BrickFluid.STILL, 3)
	BrickFluid.tick_now(1)
	var worst := 0.0
	var evals := 0
	for i in 40:
		BrickFluid.tick_now(1)
		var s: Dictionary = BrickFluid.stats()
		if float(s.tick_ms) > worst:
			worst = float(s.tick_ms)
			evals = int(s.evals)
	print("  [cost] spill of 1600 cells: worst tick %.2f ms, %d cells (%.0f ns a cell)" % [
			worst, evals, worst * 1.0e6 / maxf(evals, 1)])

	# 10. The generated sea.
	_sec("10")
	BrickTerrain.clear_terrain_edits()
	BrickTerrain.set_generator(1)
	BrickTerrain.reset_gen_params()
	var sea := BrickFluid.reset(20.0, true)
	BrickFluid.set_centre(Vector3.ZERO, 100000.0)
	var names := BrickTerrain.biome_names()
	var found := Vector2i(1 << 30, 0)
	for r in range(0, 12000, 128):   # the oceans start some 6000 studs out
		for a in 16:
			var c := Vector2i(int(cos(a * TAU / 16) * r), int(sin(a * TAU / 16) * r))
			if names[BrickTerrain.biome_at(c.x, c.y)] == "Dry Ocean" \
					and BrickTerrain.surface_plate(c.x, c.y) < BrickFluid.get_sea_course() * 3 - 9:
				found = c
				break
		if found.x != 1 << 30:
			break
	_ok("found the sea", found.x != 1 << 30)
	if found.x != 1 << 30:
		var top := BrickFluid.get_sea_course() - 1
		var c := _info(found.x, top, found.y)
		_ok("sea is ocean source at the sea course", int(c.fluid) == 1
				and int(c.kind) == BrickFluid.SOURCE and bool(c.ocean), str(c))
		_ok("sea level is on a course", absf(sea - BrickFluid.get_sea_course() * 0.42) < 0.001)
		var tx := floori(found.x / 32.0)
		var tz := floori(found.y / 32.0)
		BrickFluid.request_mesh(tx, tz)
		BrickFluid.tick_now(1)
		var sm: Dictionary = BrickFluid.build_tile_mesh(tx, tz)
		_ok("a tile of open sea draws no top", (sm.water as Array).is_empty())
		_ok("surface_at in the sea", absf(BrickFluid.surface_at(
				Vector3(found.x * 0.35, sea - 1.0, found.y * 0.35)) - sea) < 0.01)
	# 11. Generated lava pools and springs (stage 8): lava in cave air under
	# the lava line, drawn once its tile is primed; springs out of cliff faces
	# run once primed.
	var gp: Dictionary = BrickTerrain.get_gen_params()
	gp["lava_pools"] = true
	gp["lava_m"] = 6.0
	gp["springs"] = false            # on below, for the springs' own check
	BrickTerrain.set_gen_params(gp)
	BrickFluid.reset(20.0, false)
	BrickFluid.set_centre(Vector3.ZERO, 100000.0)
	var lava_b := floori((20.0 + 6.0) / 0.42)
	var lava_at := Vector2i(1 << 30, 0)
	for r in range(0, 3000, 8):
		for ang in 8:
			var lc := Vector2i(int(cos(ang * TAU / 8) * r), int(sin(ang * TAU / 8) * r))
			if int(_info(lc.x, lava_b - 1, lc.y).fluid) == 2:
				lava_at = lc
				break
		if lava_at.x != 1 << 30:
			break
	_ok("cave air under the lava line is lava", lava_at.x != 1 << 30, str(lava_at))
	if lava_at.x != 1 << 30:
		var ltx := floori(lava_at.x / 32.0)
		var ltz := floori(lava_at.y / 32.0)
		BrickFluid.prime_tile(ltx, ltz)
		BrickFluid.tick_now(1)
		var lm: Array = []
		for mo in BrickFluid.take().meshes:
			if mo.tile == Vector2i(ltx, ltz):
				lm = mo.lava
		_ok("a primed tile draws its lava pool", not lm.is_empty())
		_ok("generated lava stays put (nothing awake)", BrickFluid.active_count() == 0,
				str(BrickFluid.active_count()))
		# A hole dug in solid rock under the lava line is a hole, not lava:
		# only air the world was generated with fills.
		var dug := Vector3i(1 << 30, 0, 0)
		for k in range(1, 400):
			var dx := lava_at.x + (k % 20) - 10
			var dz := lava_at.y + (k / 20) - 10
			var allsolid := true
			for o in [Vector3i(0, 0, 0), Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1), Vector3i(0, 1, 0), Vector3i(0, -1, 0)]:
				if int(_info(dx + o.x, lava_b - 3 + o.y, dz + o.z).capacity) != 0:
					allsolid = false
					break
			if allsolid:
				dug = Vector3i(dx, lava_b - 3, dz)
				break
		if dug.x != 1 << 30:
			var r: Dictionary = BrickTerrain.fill_box(Vector3i(dug.x, dug.y * 3, dug.z), Vector3i(dug.x, dug.y * 3 + 2, dug.z), 0, false)
			BrickFluid.terrain_changed(r.box_lo, r.box_hi)
			BrickFluid.tick_now(10)
			_ok("a hole dug under the lava line stays dry", int(_info(dug.x, dug.y, dug.z).fluid) == 0,
					str(_info(dug.x, dug.y, dug.z)))
	gp["springs"] = true
	gp["spring_chance"] = 0.05
	BrickTerrain.set_gen_params(gp)
	BrickFluid.reset(20.0, false)
	BrickFluid.set_centre(Vector3.ZERO, 100000.0)
	for tz in range(-3, 4):
		for tx in range(-3, 4):
			BrickFluid.prime_tile(tx, tz)
	BrickFluid.tick_now(80)
	var spring_tiles := 0
	for dt in BrickFluid.drawn_tiles():
		var mm: Dictionary = BrickFluid.build_tile_mesh(dt.x, dt.y)
		if not (mm.water as Array).is_empty():
			spring_tiles += 1
	_ok("primed springs run (water in tiles away from the sea)", spring_tiles > 0,
			"%d tiles with water" % spring_tiles)

	# 12. Lakes over the sea and cave pools (stage 8).
	gp = BrickTerrain.get_gen_params()
	gp["springs"] = false
	gp["lava_pools"] = false
	gp["lakes"] = true
	gp["lake_chance"] = 1.0
	gp["cave_pools"] = true
	gp["cave_pool_chance"] = 0.5
	BrickTerrain.set_gen_params(gp)
	BrickFluid.reset(20.0, false)
	BrickFluid.set_centre(Vector3.ZERO, 100000.0)
	var lake := Vector3i(1 << 30, 0, 0)
	for rz in range(-4, 5):
		for rx in range(-4, 5):
			for k in 64:
				var lx := rx * 384 + 64 + (k * 37) % 256
				var lz := rz * 384 + 64 + (k * 53) % 256
				var lt := BrickFluid.lake_top(lx, lz)
				if lt != -2147483648 and int(_info(lx, lt, lz).fluid) == 1:
					lake = Vector3i(lx, lt, lz)
					break
			if lake.x != 1 << 30:
				break
		if lake.x != 1 << 30:
			break
	_ok("a lake over the sea is water to its level", lake.x != 1 << 30, str(lake))
	if lake.x != 1 << 30:
		_ok("and none above it", int(_info(lake.x, lake.y + 1, lake.z).fluid) == 0)
	# Cave pools: the dips of cave floors, each filled to its own lip; never
	# beside cave air at their course. Worked out by the water's thread when a
	# tile is primed (the main thread only reads what it knows).
	gp["cave_pool_chance"] = 1.0
	BrickTerrain.set_gen_params(gp)
	BrickFluid.reset(20.0, false)
	BrickFluid.set_centre(Vector3.ZERO, 100000.0)
	for tz in range(0, 2):
		for tx in range(0, 2):
			BrickFluid.prime_tile(tx, tz, 0, 150)
	BrickFluid.tick_now(1)
	var pools := 0
	var walls := 0
	for px in range(0, 64):
		for pz in range(0, 64):
			var top := floori(BrickTerrain.surface_plate(px, pz) / 3.0)
			for b in range(0, top):
				var pc: Dictionary = _info(px, b, pz)
				if int(pc.fluid) != 1 or int(pc.solid) != 0:
					continue
				pools += 1
				for o in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
					var nc: Dictionary = _info(px + o.x, b, pz + o.y)
					if int(nc.fluid) == 0 and int(nc.capacity) > 0:
						walls += 1
	_ok("cave pools are generated", pools > 0, "%d pool cells found" % pools)
	_ok("no pool water beside cave air (closed pockets only)", walls == 0, "%d sides open" % walls)

	# 13. Multiplayer groundwork (11.5): an authority's changes, read from its
	# change log, rebuild the same water on a mirror that runs no rules.
	BrickTerrain.set_generator(0)
	BrickTerrain.reset_gen_params()
	BrickTerrain.clear_terrain_edits()
	BrickFluid.reset(20.0, false)
	BrickFluid.set_centre(Vector3.ZERO, 100000.0)
	_floor(3060, -20, 3140, 20)
	BrickFluid.set_change_log(true)
	BrickFluid.tick_now(1)
	var v0: int = BrickFluid.get_changes_since(0).version
	BrickFluid.place(Vector3i(3100, W, 0), 1, BrickFluid.SOURCE, 3)
	BrickFluid.place(Vector3i(3110, W, 5), 1, BrickFluid.STILL, 3)
	BrickFluid.tick_now(60)
	var ch: Dictionary = BrickFluid.get_changes_since(v0)
	var host_cells := {}
	for x in range(3080, 3125):
		for z in range(-18, 19):
			var hc: Dictionary = _info(x, W, z)
			if int(hc.fluid) != 0:
				host_cells[Vector2i(x, z)] = [int(hc.fluid), int(hc.kind), int(hc.amount)]
	var d2: Dictionary = BrickFluid.get_changes_since(v0 + 3)
	_ok("a later version sends less", (d2.cells as PackedByteArray).size() <= (ch.cells as PackedByteArray).size()
			and not bool(d2.full))
	# The mirror: the same ground, nothing simulated, the changes applied.
	BrickFluid.reset(20.0, false)
	BrickFluid.set_centre(Vector3.ZERO, 100000.0)
	BrickFluid.set_simulating(false)
	BrickFluid.apply_changes(ch.cells, false)
	BrickFluid.tick_now(3)
	var same := 0
	var differ := 0
	for x in range(3080, 3125):
		for z in range(-18, 19):
			var mc: Dictionary = _info(x, W, z)
			var want = host_cells.get(Vector2i(x, z))
			if want == null:
				if int(mc.fluid) != 0:
					differ += 1
			elif [int(mc.fluid), int(mc.kind), int(mc.amount)] == want:
				same += 1
			else:
				differ += 1
	_ok("a mirror rebuilds the authority's water from its changes", differ == 0 and same == host_cells.size(),
			"%d same, %d differ, %d bytes for %d cells" % [same, differ, (ch.cells as PackedByteArray).size(), host_cells.size()])
	_ok("and runs no rules of its own", BrickFluid.active_count() == 0)
	BrickFluid.set_simulating(true)
	BrickFluid.set_change_log(false)

	BrickTerrain.set_generator(0)
	BrickTerrain.reset_gen_params()
	BrickFluid.reset(20.0, false)
	BrickTerrain.clear_terrain_edits()

	print("[fluid_probe] %d passed, %d failed" % [_passed, _failed])
	quit(1 if _failed > 0 else 0)
