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
## - lava meeting water makes obsidian or stone (4.6);
## - a calm world has nothing awake (a still world costs nothing);
## - the generated sea is ocean source at the sea course, and a tile of only
##   sea draws no top (the wave tiers draw it);
## - a big still spill's tick cost, as a number.

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
	var mats := {}
	for i in range(0, terr.size(), 4):
		mats[terr[i + 3]] = true
	_ok("lava and water make rock", terr.size() > 0, "%d cells" % (terr.size() / 4))

	# 8. Calm costs nothing.
	_sec("8")
	_settle(2000)
	_ok("a calm world has nothing awake", BrickFluid.active_count() == 0,
			str(BrickFluid.active_count()))

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
	BrickTerrain.set_generator(0)
	BrickTerrain.reset_gen_params()
	BrickFluid.reset(20.0, false)
	BrickTerrain.clear_terrain_edits()

	print("[fluid_probe] %d passed, %d failed" % [_passed, _failed])
	quit(1 if _failed > 0 else 0)
