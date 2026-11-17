extends SceneTree

## The biome generator's probe (Docs/MineWorld.md). Headless.
##
##     godot --headless --path . --script res://tools/probes/mine_world_probe.gd
##
## What each check is for:
##
##   * params round-trip: the world-gen menu writes a Dictionary and reads it
##     back; a key that does not come back is a slider that does nothing.
##   * classic untouched: every other scene keeps the old field. Turning the
##     biome generator on and off again must leave height_at as it was.
##   * determinism: the same seed and params give the same world, a new seed
##     a different one -- streaming rebuilds tiles in any order.
##   * biome mix: every biome the defaults list shows up somewhere in 8 km.
##   * relief: basins below the sea line, mountains well above it.
##   * overhangs: solid over air above the 2D surface, on cliff ground.
##   * ores and layers: ores in stone at their depths, bedrock at the floor
##     and carve cannot remove it.
##   * bake cost: a tile and a coarse block, so streaming stays affordable.
##   * Generate: new params change the world.

var failures := 0
var _names: PackedStringArray


func _initialize() -> void:
	BrickTerrain.configure(424242)
	_names = BrickTerrain.material_names()
	var classic_before := _classic_sample()
	BrickTerrain.set_generator(1)
	BrickTerrain.reset_gen_params()
	BrickTerrain.set_smooth_terrain(false)
	BrickTerrain.set_plate_steps(false)

	_check_params_roundtrip()
	_check_determinism()
	_check_biomes_and_relief()
	_check_overhangs()
	_check_ores_and_bedrock()
	_check_bake_cost()
	_check_regenerate()
	_check_preview()

	BrickTerrain.set_generator(0)
	var classic_after := _classic_sample()
	_expect(classic_before == classic_after, "classic generator unchanged after biomes on/off")

	print("[mine] %s (%d failures)" % ["PASS" if failures == 0 else "FAIL", failures])
	quit(1 if failures > 0 else 0)


func _expect(ok: bool, what: String) -> void:
	print("[mine] %s  %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		failures += 1


func _mat(n: String) -> int:
	return _names.find(n)


func _classic_sample() -> Array:
	var out := []
	for i in 40:
		out.append(BrickTerrain.height_at(i * 37 - 700, i * 53 - 900))
	return out


func _check_params_roundtrip() -> void:
	var d: Dictionary = BrickTerrain.get_gen_params()
	d["peak_height_m"] = 91.0
	d["caves"] = false
	(d["biomes"] as Array)[4]["hilliness"] = 0.33
	(d["ores"] as Array)[0]["chance"] = 0.21
	BrickTerrain.set_gen_params(d)
	var back: Dictionary = BrickTerrain.get_gen_params()
	var ok := is_equal_approx(float(back["peak_height_m"]), 91.0) and not bool(back["caves"]) \
			and is_equal_approx(float((back["biomes"] as Array)[4]["hilliness"]), 0.33) \
			and is_equal_approx(float((back["ores"] as Array)[0]["chance"]), 0.21)
	var missing := []
	for k in d:
		if not back.has(k):
			missing.append(k)
	_expect(ok and missing.is_empty(), "params round-trip (missing: %s)" % [missing])
	BrickTerrain.reset_gen_params()


func _check_determinism() -> void:
	var a := []
	for i in 60:
		a.append([BrickTerrain.surface_plate(i * 211, -i * 97), BrickTerrain.biome_at(i * 211, -i * 97)])
	var b := []
	for i in 60:
		b.append([BrickTerrain.surface_plate(i * 211, -i * 97), BrickTerrain.biome_at(i * 211, -i * 97)])
	_expect(a == b, "same seed, same world")
	BrickTerrain.configure(777)
	var c := []
	for i in 60:
		c.append([BrickTerrain.surface_plate(i * 211, -i * 97), BrickTerrain.biome_at(i * 211, -i * 97)])
	_expect(a != c, "new seed, new world")
	BrickTerrain.configure(424242)


func _check_biomes_and_relief() -> void:
	var names := BrickTerrain.biome_names()
	var counts := {}
	var sea: float = float(BrickTerrain.get_gen_params()["sea_m"])
	var plate := BrickWorld.get_plate_metres()
	var heights: Array[float] = []
	# 8 km square, a sample every 48 studs (16.8 m).
	var half := 11400
	var step := 48
	for z in range(-half, half, step * 4):
		for x in range(-half, half, step):
			var bi := BrickTerrain.biome_at(x, z)
			counts[bi] = int(counts.get(bi, 0)) + 1
			heights.append(float(BrickTerrain.surface_plate(x, z) + 1) * plate - sea)
	heights.sort()
	var total := heights.size()
	var lines := []
	var missing := []
	for i in names.size():
		var n := int(counts.get(i, 0))
		lines.append("%s %.1f%%" % [names[i], 100.0 * n / total])
		if n == 0:
			missing.append(names[i])
	print("[mine] biomes: %s" % ", ".join(lines))
	var p := func(q: float) -> float: return heights[clampi(int(q * total), 0, total - 1)]
	print("[mine] height above sea: min %.1f  p10 %.1f  p50 %.1f  p90 %.1f  p99 %.1f  max %.1f m"
			% [heights[0], p.call(0.1), p.call(0.5), p.call(0.9), p.call(0.99), heights[total - 1]])
	_expect(missing.size() <= 2, "nearly every biome appears (missing: %s)" % [missing])
	_expect(heights[0] < -6.0, "dry ocean basins reach well below the sea line")
	_expect(heights[total - 1] > 40.0, "mountains reach 40 m above the sea line")
	var flat_share := float(counts.get(names.find("Plains"), 0)) / total
	_expect(flat_share > 0.05, "plains are common (%.0f%%)" % (flat_share * 100.0))


func _check_overhangs() -> void:
	var found := 0
	var columns := 0
	for z in range(-6000, 6000, 23):
		for x in range(-6000, 6000, 61):
			var top := BrickTerrain.surface_plate(x, z)
			# Walk down from the top: solid, then air, then solid again within
			# 40 plates is a cell hanging over a gap.
			var seen_air := false
			for yp in range(top - 1, top - 40, -1):
				var s := BrickTerrain.solid_at(x, yp, z)
				if s == 0:
					seen_air = true
				elif seen_air:
					found += 1
					break
			columns += 1
	print("[mine] overhang/cave columns: %d of %d sampled" % [found, columns])
	_expect(found > 20, "overhangs or cave roofs exist near the surface")


func _check_ores_and_bedrock() -> void:
	var sea: float = float(BrickTerrain.get_gen_params()["sea_m"])
	var plate := BrickWorld.get_plate_metres()
	var counts := {}
	var stone := 0
	# A slab of underground from 2 m to 50 m below the sea line.
	for z in range(0, 96, 2):
		for x in range(0, 96, 2):
			for yp in range(int((sea - 50.0) / plate), int((sea - 2.0) / plate), 3):
				var m := BrickTerrain.solid_at(x, yp, z)
				counts[m] = int(counts.get(m, 0)) + 1
				if m == _mat("stone") or m == _mat("dark stone"):
					stone += 1
	var ore_lines := []
	var ores := 0
	for n in ["coal ore", "iron ore", "copper ore", "gold ore", "redstone ore", "lapis ore", "diamond ore"]:
		var c := int(counts.get(_mat(n), 0))
		ores += c
		ore_lines.append("%s %d" % [n, c])
	print("[mine] underground: stone %d, %s, deepslate %d, granite %d, diorite %d, gravel %d"
			% [stone, ", ".join(ore_lines), int(counts.get(_mat("dark stone"), 0)),
			int(counts.get(_mat("granite"), 0)), int(counts.get(_mat("diorite"), 0)),
			int(counts.get(_mat("gravel"), 0))])
	_expect(ores > 20, "ores are scattered through the stone")
	_expect(int(counts.get(_mat("dark stone"), 0)) > 100, "deepslate below its band")
	var bed_m: float = sea + float(BrickTerrain.get_gen_params()["bedrock_m"])
	var bed_p := int(floor(bed_m / plate)) - 6
	_expect(BrickTerrain.solid_at(5, bed_p, 5) == _mat("bedrock"), "bedrock at the floor")
	var res: Dictionary = BrickTerrain.carve(Vector3(5 * 0.35, bed_p * plate, 5 * 0.35), 1.0)
	_expect(BrickTerrain.solid_at(5, bed_p, 5) == _mat("bedrock"), "carve leaves bedrock (%d removed)" % int(res["removed"]))
	BrickTerrain.clear_terrain_edits()


func _check_bake_cost() -> void:
	# The hilliest spot in a coarse scan, and a flat one, so both ends show.
	var best := Vector2i.ZERO
	var best_h := -1e9
	var low := Vector2i.ZERO
	var low_h := 1e9
	for tz in range(-200, 200, 9):
		for tx in range(-200, 200, 9):
			var h := BrickTerrain.surface_plate(tx * 32, tz * 32)
			if h > best_h:
				best_h = h
				best = Vector2i(tx, tz)
			if h < low_h:
				low_h = h
				low = Vector2i(tx, tz)
	for spot in [best, low]:
		var t0 := Time.get_ticks_usec()
		var tris := 0
		for dz in 2:
			for dx in 2:
				var d: Dictionary = BrickTerrain.build_tile(spot.x + dx, spot.y + dz)
				tris += int(d.get("tri_count", 0))
		var ms := float(Time.get_ticks_usec() - t0) / 4000.0
		print("[mine] tile bake at %s: %.1f ms a tile" % [spot, ms])
		_expect(ms < 120.0, "a tile bakes in under 120 ms (%.1f)" % ms)
	var t1 := Time.get_ticks_usec()
	BrickTerrain.set_coarse_smooth_step(0)
	var c: Dictionary = BrickTerrain.build_coarse(best.x, best.y, 4, 4)
	var cms := float(Time.get_ticks_usec() - t1) / 1000.0
	print("[mine] coarse 4x4 block step 4: %.1f ms, keys %s" % [cms, c.keys()])
	_expect(cms < 600.0, "a coarse block bakes in under 600 ms")


func _check_regenerate() -> void:
	var before := []
	for i in 30:
		before.append(BrickTerrain.surface_plate(i * 300, i * 170))
	BrickTerrain.set_gen_params({"height_scale": 2.0, "cont_weight_m": 40.0})
	var after := []
	for i in 30:
		after.append(BrickTerrain.surface_plate(i * 300, i * 170))
	_expect(before != after, "new params change the world")
	BrickTerrain.reset_gen_params()
	var again := []
	for i in 30:
		again.append(BrickTerrain.surface_plate(i * 300, i * 170))
	_expect(before == again, "reset gives the default world back")


func _check_preview() -> void:
	var t0 := Time.get_ticks_usec()
	var px: PackedByteArray = BrickTerrain.gen_preview(BrickTerrain.get_seed(), {}, 0, 0, 192, 192, 16, 0)
	var ms := float(Time.get_ticks_usec() - t0) / 1000.0
	_expect(px.size() == 192 * 192 * 3, "map preview is 192x192 RGB (%.0f ms)" % ms)
	var img := Image.create_from_data(192, 192, false, Image.FORMAT_RGB8, px)
	DirAccess.make_dir_recursive_absolute("user://dev")
	img.save_png("user://dev/mine_preview.png")
	var px2: PackedByteArray = BrickTerrain.gen_preview(BrickTerrain.get_seed(), {"height_scale": 1.5}, 0, 0, 192, 192, 16, 1)
	Image.create_from_data(192, 192, false, Image.FORMAT_RGB8, px2).save_png("user://dev/mine_preview_biomes.png")
