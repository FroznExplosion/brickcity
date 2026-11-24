extends SceneTree

## Water and lava on the brick grid (BrickFluid, Docs/MineWater.md 4).
##
##     godot --headless --path . --script res://tools/probes/fluid_probe.gd
##
## - spreading water's new tops pop in at their height, level, and hold it;
##   poured water's tops ease down as they give water, and keep easing when
##   meshed again mid-way (no rise, no snap, no tilted corners);
## Every test stands on a flat stone floor laid by terrain edits high above
## the generated world (course FLOOR), so the ground under it is known
## exactly. What each check is for:
## Amounts are UNITS, half tiles, six to a brick (2026-11-23).
## - a source on flat ground reaches 5 studs and stops; levels 6 (the
##   source, a brick), then half a tile less a stud, 5 to 1;
## - deeper water flows over a tile and not over a brick (R3); water no
##   deeper than a tile stops at one;
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
##   fall into a pit never fills it and, cut off, is gone; a river over a
##   pond leaves its volume as it was (R6, MineWaterNext.md); a source in a
##   brim-full pond makes it a lake that heals, a half-full one does not
##   turn (R9); lakes over the sea; cave
##   pools with no water beside cave air; a mirror rebuilds an authority's
##   water from its change log (multiplayer groundwork); a source on the open
##   sea runs out 2 studs and its water goes back to the sea once it is gone;
## - W3: a written section far away is parked (its changed cells only),
##   reads and saves the same, and is whole again when the player is back.

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
	return int(c.units) if int(c.fluid) != 0 else 0


func _info(x: int, b: int, z: int) -> Dictionary:
	return BrickFluid.cell_info(Vector3i(x, b, z))


## Tick and mesh tile (-250, 0) `ticks` times, at once (no time passes):
## its tops' easing offsets (CUSTOM0.x) at the last mesh -- eased (any),
## falling (above their level), the worst rise, tilted tops.
func _ease_run(ticks: int) -> Dictionary:
	var r := { "tops": 0, "moved": 0, "falling": 0, "worst_up": 0.0, "tilted": 0 }
	for t in ticks:
		BrickFluid.tick_now(1)
		var em: Dictionary = BrickFluid.build_tile_mesh(-250, 0)
		var arr: Array = em.water
		if arr.is_empty():
			continue
		var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var n: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
		var c: PackedFloat32Array = arr[Mesh.ARRAY_CUSTOM0]
		r.falling = 0
		for q in range(0, v.size(), 4):
			if n[q].y < 0.9:
				continue
			r.tops += 1
			if absf(c[q * 4]) > 0.001:
				r.moved += 1
			if c[q * 4] > 0.01:
				r.falling += 1
			r.worst_up = maxf(r.worst_up, -c[q * 4])
			var s0 := v[q].y + c[q * 4]
			for k in range(1, 4):
				if absf(v[q + k].y + c[(q + k) * 4] - s0) > 0.001:
					r.tilted += 1
					break
	return r


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

	# 0. Spreading water pops each new top in at its own height, level, and
	# holds it: it eases only when its level changes (rising from its floor,
	# a cell that took water rose and at once fell as it passed water on --
	# choppy, the user, 2026-11-24; before that the easing was keyed by the
	# grid corner two cells share and a new cell flashed up to a brick).
	_sec("0")
	# (Wide enough that it settles on it: a calm world is checked later.)
	BrickTerrain.fill_box(Vector3i(-8010, FLOOR * 3, -6), Vector3i(-7960, FLOOR * 3 + 2, 36), 4, false)
	BrickFluid.terrain_changed(Vector3i(-8010, FLOOR * 3, -6), Vector3i(-7960, FLOOR * 3 + 2, 36))
	BrickFluid.place(Vector3i(-7995, W, 15), 1, BrickFluid.SOURCE, 3)
	var e0 := _ease_run(10)
	_ok("a source's new tops pop in at their height, level", e0.tops > 50 and e0.moved == 0 and e0.tilted == 0,
			"%d tops, %d eased, %d tilted" % [e0.tops, e0.moved, e0.tilted])
	# Poured water spreading: its cells give water away, so they ease DOWN,
	# and meshed again and again within milliseconds they are still on their
	# way: each mesh eases on from where the last was DRAWN (a remesh snapped
	# a moving top to its end -- the user, 2026-11-23, "jumps").
	BrickFluid.place(Vector3i(-7975, W, 15), 1, BrickFluid.STILL, 3)
	var e1 := _ease_run(3)
	# (A cell may take a second half tile as the water moves on -- a real
	# rise, eased; never a rise from its floor.)
	_ok("poured water's tops ease down as they give water", e1.falling >= 1 and e1.worst_up < 0.071 and e1.tilted == 0,
			"%d still falling, worst rise %.3f m, %d tilted" % [e1.falling, e1.worst_up, e1.tilted])
	# Its water away again: later sections clear the terrain's edits, and a
	# source without its floor would pour onto the generated world below.
	for x in range(-8010, -7959):
		for z in range(-6, 37):
			if _amt(x, W, z) > 0:
				BrickFluid.remove(Vector3i(x, W, z), -1)
	_settle(50)

	# 1. A source on flat ground.
	_sec("1")
	_floor(-40, -40, 40, 40)
	BrickFluid.place(Vector3i(0, W, 0), 1, BrickFluid.SOURCE, 3)
	var t := _settle(400)
	_ok("source settles", BrickFluid.active_count() == 0, "%d ticks" % t)
	_ok("source cell is a brick of water", _amt(0, W, 0) == 6)
	_ok("half a tile less a stud: 5 at 1, 3 at 3, 1 at 5",
			_amt(1, W, 0) == 5 and _amt(3, W, 0) == 3 and _amt(5, W, 0) == 1,
			"%d %d %d" % [_amt(1, W, 0), _amt(3, W, 0), _amt(5, W, 0)])
	_ok("distance 6 is dry", _amt(6, W, 0) == 0 and _amt(0, W, 6) == 0)
	_ok("diagonal reach is by path", _amt(2, W, 2) == 2 and _amt(3, W, 3) == 0,
			"%d %d" % [_amt(2, W, 2), _amt(3, W, 3)])
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
	# (Distance 3 holds 3 units: it runs over the tile at 203, 1 deep on it.)
	_ok("deeper water flows over a tile", _amt(203, W, 0) >= 1 and _amt(204, W, 0) >= 1,
			"%d %d" % [_amt(203, W, 0), _amt(204, W, 0)])
	_ok("water does not pass a brick", _amt(207, W, 0) == 0)
	# Water no deeper than a tile meets a tile: it stops (never above what
	# feeds it). Distance 4 holds 2 units, a tile: the tile at 195 holds it.
	BrickTerrain.fill_box(Vector3i(195, W * 3, -20), Vector3i(195, W * 3, 20), 4, false)
	BrickFluid.terrain_changed(Vector3i(195, W * 3, -20), Vector3i(195, W * 3, 20))
	_settle(400)
	_ok("water a tile deep stops at a tile", _amt(196, W, 0) >= 1 and _amt(195, W, 0) == 0,
			"%d %d" % [_amt(196, W, 0), _amt(195, W, 0)])

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
	_ok("poured water is 9 tiles (18 units)", poured == 18, str(poured))
	_ok("spreading keeps every unit", held == 18, str(held))
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
	_ok("a pond in a pit keeps its tiles", _region_units(2172, 2173, 17, 18, W) == 18,
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

	# 4e. A fall into a pit never fills it (R6, Docs/MineWaterNext.md: water
	# running from a source adds water nowhere; the pit rule 4.5 went
	# 2026-11-24): its floor is covered as a stream, no still water, nothing
	# over the rim; cut off, it is gone.
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
				if int(pc.fluid) == 1 and int(pc.kind) == BrickFluid.STILL and int(pc.units) == 6:
					pit_full += 1
	# (Over the floor only the fall itself: still water at no course.)
	var pit_still := 0
	for b in range(W, W + 3):
		for x in range(2921, 2930):
			for z in range(-4, 5):
				var sc: Dictionary = _info(x, b, z)
				if int(sc.fluid) == 1 and int(sc.kind) == BrickFluid.STILL:
					pit_still += 1
	var outside := _region_units(2900, 2918, -20, 20, W)
	_ok("a fall into a pit never fills it", pit_full == 0 and pit_still == 0 and _region_units(2921, 2929, -4, 4, W) > 0
			and outside == 0, "%d full, %d still, %d outside" % [pit_full, pit_still, outside])
	BrickFluid.remove(Vector3i(2925, W + 5, 0), -1)
	_settle(200)
	_ok("cut off, the fall's water is gone", _region_units(2921, 2929, -4, 4, W) == 0,
			"%d units left" % _region_units(2921, 2929, -4, 4, W))
	# 4f. A river over a pond leaves the pond's volume as it was (R6): a
	# walled 3 x 3 pond a tile deep, a source set in it runs over the rest;
	# the source gone, the pond is back -- no more water, no less.
	_floor(3000, -10, 3020, 10)
	for wall in [[3008, -2, 3012, -2], [3008, 2, 3012, 2], [3008, -2, 3008, 2], [3012, -2, 3012, 2]]:
		BrickTerrain.fill_box(Vector3i(wall[0], W * 3, wall[1]), Vector3i(wall[2], W * 3 + 2, wall[3]), 4, false)
	BrickFluid.terrain_changed(Vector3i(3008, W * 3, -2), Vector3i(3012, W * 3 + 2, 2))
	for x in range(3009, 3012):
		for z in range(-1, 2):
			BrickFluid.place(Vector3i(x, W, z), 1, BrickFluid.STILL, 1)
	_settle(50)
	var pond0 := _region_units(3009, 3011, -1, 1, W)
	BrickFluid.place(Vector3i(3009, W, -1), 1, BrickFluid.SOURCE, 3)
	BrickFluid.tick_now(20)
	var ran := _info(3010, W, -1)
	BrickFluid.remove(Vector3i(3009, W, -1), -1)
	_settle(200)
	# (The source's own cell had 2 units of the pond; the source took them.)
	_ok("a river over a pond leaves its volume as it was", int(ran.kind) == BrickFluid.FLOW
			and _region_units(3009, 3011, -1, 1, W) == pond0 - 2,
			"pond %d, ran over %s, after %d (want %d)" % [pond0, int(ran.kind) == BrickFluid.FLOW, _region_units(3009, 3011, -1, 1, W), pond0 - 2])
	# 4g. A source in a brim-full pond makes it a lake (R9, decision B: the
	# whole connected full body turns); a hole dug in it heals. A half-full
	# pond does not turn: it drains into the source (4.2.4).
	_floor(3100, -12, 3140, 12)
	for wall in [[3104, -3, 3110, -3], [3104, 3, 3110, 3], [3104, -3, 3104, 3], [3110, -3, 3110, 3],
			[3124, -2, 3128, -2], [3124, 2, 3128, 2], [3124, -2, 3124, 2], [3128, -2, 3128, 2]]:
		BrickTerrain.fill_box(Vector3i(wall[0], W * 3, wall[1]), Vector3i(wall[2], W * 3 + 2, wall[3]), 4, false)
	BrickFluid.terrain_changed(Vector3i(3104, W * 3, -3), Vector3i(3128, W * 3 + 2, 3))
	for x in range(3105, 3110):
		for z in range(-2, 3):
			BrickFluid.place(Vector3i(x, W, z), 1, BrickFluid.STILL, 3)
	for x in range(3125, 3128):
		for z in range(-1, 2):
			BrickFluid.place(Vector3i(x, W, z), 1, BrickFluid.STILL, 1)
	_settle(50)
	BrickFluid.place(Vector3i(3105, W, -2), 1, BrickFluid.SOURCE, 3)
	BrickFluid.place(Vector3i(3125, W, -1), 1, BrickFluid.SOURCE, 3)
	BrickFluid.tick_now(30)
	var lake_src := 0
	for x in range(3105, 3110):
		for z in range(-2, 3):
			if int(_info(x, W, z).kind) == BrickFluid.SOURCE:
				lake_src += 1
	_ok("a source in a brim-full pond makes it a lake", lake_src == 25, "%d of 25 cells source" % lake_src)
	BrickFluid.remove(Vector3i(3107, W, 0), -1)
	BrickFluid.tick_now(5)
	_ok("a hole dug in the lake heals", int(_info(3107, W, 0).kind) == BrickFluid.SOURCE)
	var turned := 0
	for x in range(3125, 3128):
		for z in range(-1, 2):
			var hc: Dictionary = _info(x, W, z)
			if int(hc.kind) == BrickFluid.SOURCE and not (x == 3125 and z == -1):
				turned += 1
	_ok("a half-full pond does not turn", turned == 0, "%d turned" % turned)
	BrickFluid.remove(Vector3i(3105, W, -2), -1)
	BrickFluid.remove(Vector3i(3125, W, -1), -1)

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
				beside += int(c.units)
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
	# Lava alone first.
	BrickFluid.place(Vector3i(1200, W, 0), 2, BrickFluid.SOURCE, 3)
	BrickFluid.tick_now(120)
	_ok("lava's reach is 6", int(_info(1194, W, 0).fluid) == 2 and int(_info(1193, W, 0).fluid) == 0,
			"%d %d" % [int(_info(1194, W, 0).fluid), int(_info(1193, W, 0).fluid)])
	BrickFluid.take()
	# Water reaches 5: one source into running lava beside the lava source
	# (obsidian, and stone beyond), one that runs to the lava's thin end.
	BrickFluid.place(Vector3i(1199, W, 0), 1, BrickFluid.SOURCE, 3)
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
	_ok("and runs on when the player comes back", _amt(2404, W, 0) == 2 and BrickFluid.active_count() == 0,
			"%d" % _amt(2404, W, 0))
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
		# 11.9: still water laid on the open sea joins it.
		BrickFluid.place(Vector3i(found.x + 3, top + 1, found.y), 1, BrickFluid.STILL, 3)
		BrickFluid.tick_now(6)
		# (It goes in the tick that places it: nothing to see before.)
		_ok("still water on the open sea joins it", _amt(found.x + 3, top + 1, found.y) == 0
				and _region_units(found.x - 6, found.x + 12, found.y - 9, found.y + 9, top + 1) == 0
				and int(_info(found.x + 3, top, found.y).kind) == BrickFluid.SOURCE,
				"%d left" % _region_units(found.x - 6, found.x + 12, found.y - 9, found.y + 9, top + 1))
		# A source brick on the open sea runs out only SEA_REACH (2) studs:
		# the sea takes the rest in (the user, 2026-11-23: it spread 14).
		var sx := found.x + 3
		BrickFluid.place(Vector3i(sx, top + 1, found.y), 1, BrickFluid.SOURCE, 3)
		BrickFluid.tick_now(40)
		var reach := 0
		for d in range(1, 16):
			if _amt(sx + d, top + 1, found.y) > 0:
				reach = d
		_ok("a source on the sea runs out 2 studs", reach == 2, "%d studs" % reach)
		BrickFluid.remove(Vector3i(sx, top + 1, found.y), -1)
		BrickFluid.tick_now(40)
		_ok("and the sea takes it back", _region_units(sx - 4, sx + 4, found.y - 4, found.y + 4, top + 1) == 0,
				"%d left" % _region_units(sx - 4, sx + 4, found.y - 4, found.y + 4, top + 1))
		# 11.9: a brick set in the open sea gets a band of real sea round it,
		# six studs; the wave tiers' mask hides those studs and no others.
		BrickFluid.set_real_sea(true)
		BrickFluid.set_centre(Vector3(found.x * 0.35, sea, found.y * 0.35), 100000.0)
		var plo := Vector3i(found.x, 0, found.y)
		var phi := Vector3i(found.x, top * 3 + 8, found.y)
		BrickTerrain.fill_box(plo, phi, 4, false)
		BrickFluid.terrain_changed(plo, phi)
		BrickFluid.tick_now(4)
		var bm: Dictionary = BrickFluid.build_tile_mesh(floori(found.x / 32.0), floori(found.y / 32.0))
		var mk := BrickFluid.sea_mask(found.x - 10, found.y - 10, 21)
		var near_hidden := mk[(10 * 21 + 10 + 3) * 2] == 255 and mk[(10 * 21 + 10 + 6) * 2] == 255
		var far_shown := mk[(10 * 21 + 10 + 8) * 2] == 0
		_ok("a brick in the sea gets a band of real sea", (bm.water as Array).size() > 0 and near_hidden and far_shown,
				"near hidden %s, 8 studs out shown %s" % [near_hidden, far_shown])
		BrickFluid.set_real_sea(false)
		BrickFluid.tick_now(1)
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

	# 13. Water far away is parked (W3, Docs/MineWaterNext.md 6): a written
	# section past twice the sim radius keeps only its changed cells; it
	# still reads and saves the same, and comes back whole when the player
	# does. (Memory grew for good with distance travelled: 122 MB after a
	# 480 m flight over sea, the terrain chat, 2026-11-24.)
	_sec("13")
	BrickFluid.set_centre(Vector3(0, 0, 0), 100000.0)
	_floor(6000, -10, 6020, 10)
	for wall in [[6008, -2, 6012, -2], [6008, 2, 6012, 2], [6008, -2, 6008, 2], [6012, -2, 6012, 2]]:
		BrickTerrain.fill_box(Vector3i(wall[0], W * 3, wall[1]), Vector3i(wall[2], W * 3 + 2, wall[3]), 4, false)
	BrickFluid.terrain_changed(Vector3i(6008, W * 3, -2), Vector3i(6012, W * 3 + 2, 2))
	for x in range(6009, 6012):
		for z in range(-1, 2):
			BrickFluid.place(Vector3i(x, W, z), 1, BrickFluid.STILL, 3)
	_settle(50)
	var pond_near := _region_units(6009, 6011, -1, 1, W)
	var save_near := BrickFluid.get_save().size()
	var mem0: Dictionary = BrickFluid.memory_stats()
	# The player 2 km away, a small sim radius: past it, the pond parks.
	BrickFluid.set_centre(Vector3(-2000, 0, 0), 60.0)
	BrickFluid.tick_now(60)
	var mem1: Dictionary = BrickFluid.memory_stats()
	_ok("a written section far away is parked", int(mem1.parked) >= 1 and int(mem1.sections) < int(mem0.sections),
			"sections %d -> %d, parked %d (%d bytes)" % [int(mem0.sections), int(mem1.sections), int(mem1.parked), int(mem1.parked_bytes)])
	_ok("parked, it reads and saves the same", _region_units(6009, 6011, -1, 1, W) == pond_near
			and BrickFluid.get_save().size() == save_near,
			"%d units (want %d), save %d bytes (want %d)" % [_region_units(6009, 6011, -1, 1, W), pond_near,
			BrickFluid.get_save().size(), save_near])
	BrickFluid.set_centre(Vector3(0, 0, 0), 100000.0)
	BrickFluid.place(Vector3i(6010, W, 0), 1, BrickFluid.STILL, 0)
	BrickFluid.tick_now(5)
	var mem2: Dictionary = BrickFluid.memory_stats()
	_ok("back, it is whole again", _region_units(6009, 6011, -1, 1, W) == pond_near and int(mem2.parked) < int(mem1.parked)
			and BrickFluid.active_count() == 0,
			"%d units (want %d), parked %d, %d awake" % [_region_units(6009, 6011, -1, 1, W), pond_near, int(mem2.parked),
			BrickFluid.active_count()])
	BrickFluid.reset(20.0, false)
	BrickTerrain.clear_terrain_edits()

	print("[fluid_probe] %d passed, %d failed" % [_passed, _failed])
	quit(1 if _failed > 0 else 0)
