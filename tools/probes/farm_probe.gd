extends SceneTree

## Farming in the mine world (Docs/MineFarming.md): the growth rules, headless.
##
##     godot --headless --path . --script res://tools/probes/farm_probe.gd
##
## What each group is for:
##   wiring    the farmland materials exist where the shader and the save
##             expect them (appended, 39 and 40), take no studs, are no item
##             and give soil back; the clock's day is the mine world's.
##   crops     every crop in the base pack loads, and its seed and produce
##             are items (a seed item names its crop).
##   exact     THE promise of section 5: a plot settled once after a long
##             gap is the same plant as one settled every few seconds, and
##             one saved and loaded half way. This is what makes "grows while
##             its ground is unloaded" true: nothing is ticked.
##   light     a day's growth is the same whatever day it is; night is slow,
##             not stopped; a plot with no light does not grow.
##   factors   wet beats dry, rich soil beats poor, a liked biome beats a
##             disliked one, rotation helps; the spread is per plant and
##             stays within 0.85-1.15.
##   harvest   only ripe crops are picked; the yield is in range; stars
##             follow stress; a perennial regrows, an annual leaves bare soil;
##             fertility goes down by the drain (beans: up), and comes back
##             fallow.
##   save      FarmStore writes changed regions and reads them back the same.
##   guide     the guide has a line for every crop.

var _pass := 0
var _fail := 0


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s" % what)
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _init() -> void:
	print("farm probe")
	_wiring()
	_crops()
	_exact()
	_light()
	_factors()
	_harvest()
	_save()
	_guide()
	print("farm probe: %d ok, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _plot(crop: StringName, wet := true, fert := 70.0, sky := 1.0, t0 := 360.0) -> Dictionary:
	var p := FarmPlant.new_plot(Vector3i(3, 41, -7), t0, fert, -1)
	p.wet = wet
	p.sky = sky
	FarmPlant.plant(p, crop, t0)
	return p


func _wiring() -> void:
	print("wiring")
	var names := Array(BrickTerrain.material_names())
	_ok("farmland is material 39, wet farmland 40", BrickTerrain.MAT_FARMLAND == 39
			and BrickTerrain.MAT_WET_FARMLAND == 40 and names[39] == "farmland" and names[40] == "wet farmland",
			"%d %d" % [BrickTerrain.MAT_FARMLAND, BrickTerrain.MAT_WET_FARMLAND])
	var sh := FileAccess.get_file_as_string("res://shaders/terrain.gdshader")
	_ok("the terrain shader furrows the same numbers", sh.contains("TERRAIN_FARMLAND = %d" % BrickTerrain.MAT_FARMLAND)
			and sh.contains("TERRAIN_WET_FARMLAND = %d" % BrickTerrain.MAT_WET_FARMLAND))
	_ok("tilled soil is smooth (no studs)", not BrickTerrain.material_takes_studs(BrickTerrain.MAT_FARMLAND)
			and not BrickTerrain.material_takes_studs(BrickTerrain.MAT_WET_FARMLAND)
			and BrickTerrain.material_takes_studs(BrickTerrain.MAT_DIRT))
	_ok("farmland is not an item; breaking it gives soil", not ItemCatalog.has(&"farmland")
			and not ItemCatalog.has(&"wet_farmland") and ItemCatalog.block_item(BrickTerrain.MAT_FARMLAND) == &"soil"
			and ItemCatalog.block_item(BrickTerrain.MAT_WET_FARMLAND) == &"soil")
	# Read from the text: the mine world's script needs the menu autoload to load.
	var re := RegEx.create_from_string("const DAY_SECONDS := ([0-9.]+)")
	var m := re.search(FileAccess.get_file_as_string("res://scripts/terrain/mine_world.gd"))
	_ok("the crops' day is the mine world's", m != null and is_equal_approx(FarmPlant.DAY, float(m.get_string(1))))
	_ok("the hoe is an item of its own kind", ItemCatalog.kind(&"hoe") == "hoe")


func _crops() -> void:
	print("crops")
	var ids := FarmCrops.ids()
	_ok("six crops in the base pack", ids.size() >= 6, str(ids))
	for id in ids:
		var c := FarmCrops.get_crop(id)
		var seed_ok := ItemCatalog.kind(c.seed) == "seed" and StringName(str(ItemCatalog.get_def(c.seed).get("crop", ""))) == id
		_ok("%s: seed %s plants it, produce %s is an item" % [id, c.seed, c.produce],
				seed_ok and ItemCatalog.has(c.produce) and FarmCrops.crop_of_seed(c.seed) == id)


func _exact() -> void:
	print("exact")
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for id in FarmCrops.ids():
		for horizon in [FarmPlant.DAY * 0.3, FarmPlant.DAY * 1.7, FarmPlant.DAY * 5.0]:
			var once := _plot(id)
			var often := once.duplicate()
			var halfway := once.duplicate()
			var t0 := float(once.t)
			var t_end: float = t0 + horizon
			FarmPlant.settle(once, t_end)
			var t := t0
			while t < t_end:
				t = minf(t_end, t + rng.randf_range(0.5, 40.0))
				FarmPlant.settle(often, t)
			# Settled half way, saved and loaded, then left.
			FarmPlant.settle(halfway, t0 + horizon * 0.5)
			var back := FarmPlant.from_row(FarmPlant.to_row(halfway))
			FarmPlant.settle(back, t_end)
			var same := int(once.stage) == int(often.stage) and absf(float(once.p) - float(often.p)) < 1e-6 \
					and int(once.stress) == int(often.stress)
			var same2 := int(once.stage) == int(back.stage) and absf(float(once.p) - float(back.p)) < 1e-6
			_ok("%s over %.1f days: once == every few seconds == saved half way (stage %d, %.4f)" % [
					id, horizon / FarmPlant.DAY, once.stage, once.p], same and same2,
					"often %d %.6f, saved %d %.6f" % [often.stage, often.p, back.stage, back.p])


func _light() -> void:
	print("light")
	var d := FarmPlant.DAY
	var a := FarmPlant.sun_integral(d * 3.2) - FarmPlant.sun_integral(d * 2.2)
	var b := FarmPlant.sun_integral(d * 10.2) - FarmPlant.sun_integral(d * 9.2)
	_ok("a day's light is the same any day", absf(a - b) < 1e-6, "%f %f" % [a, b])
	var night := FarmPlant.sun_integral(d * 0.05) - FarmPlant.sun_integral(0.0)
	var noon := FarmPlant.sun_integral(d * 0.55) - FarmPlant.sun_integral(d * 0.5)
	_ok("night grows slowly, not never: %.0f%% of noon" % (night / noon * 100.0), night > 0.0 and night < noon * 0.3)
	var dark := _plot(&"wheat", true, 70.0, 0.0)
	FarmPlant.settle(dark, float(dark.t) + d * 4.0)
	_ok("no sky, no lamp: no growth", int(dark.stage) == 0 and float(dark.p) == 0.0)
	_ok("its time to ripe is never", FarmPlant.eta(dark, float(dark.t)) == INF)
	var lamp := _plot(&"wheat", true, 70.0, 0.0)
	lamp.lamp = 1.0
	FarmPlant.settle(lamp, float(lamp.t) + d * 4.0)
	_ok("a lamp-lit cave plot grows", int(lamp.stage) > 0)


## Seconds to ripe for a plot, by settling in steps until it is.
func _time_to_ripe(p: Dictionary) -> float:
	var t0 := float(p.t)
	var t := t0
	while not FarmPlant.is_ripe(p) and t < t0 + FarmPlant.DAY * 60.0:
		t += 10.0
		FarmPlant.settle(p, t)
	return t - t0


func _factors() -> void:
	print("factors")
	var wet := _time_to_ripe(_plot(&"wheat", true))
	var dry := _time_to_ripe(_plot(&"wheat", false))
	_ok("wet wheat ripens before dry (%.1f vs %.1f days)" % [wet / FarmPlant.DAY, dry / FarmPlant.DAY], wet < dry * 0.6)
	var rich := _time_to_ripe(_plot(&"carrot", true, 100.0))
	var poor := _time_to_ripe(_plot(&"carrot", true, 10.0))
	_ok("rich soil beats poor", rich < poor)
	var names: PackedStringArray = BrickTerrain.biome_names()
	var liked := _plot(&"wheat")
	liked.biome = Array(names).find("Plains")
	var disliked := _plot(&"wheat")
	disliked.biome = Array(names).find("Desert")
	_ok("liked biome beats disliked (Plains vs Desert)", liked.biome >= 0 and disliked.biome >= 0
			and _time_to_ripe(liked) < _time_to_ripe(disliked))
	var rot := _plot(&"beans")
	rot.fam = "root"
	var same := _plot(&"beans")
	same.fam = "legume"
	_ok("rotation: beans after roots beat beans after beans", _time_to_ripe(rot) < _time_to_ripe(same))
	# The spread: twenty plots planted together, same everything but the place.
	var times: Array = []
	for i in 20:
		var p := FarmPlant.new_plot(Vector3i(i, 41, 0), 360.0, 70.0, -1)
		p.wet = true
		FarmPlant.plant(p, &"wheat", 360.0)
		times.append(_time_to_ripe(p))
	times.sort()
	_ok("a row ripens over a spread (%.2f-%.2f days)" % [times[0] / FarmPlant.DAY, times[-1] / FarmPlant.DAY],
			times[-1] - times[0] > 60.0 and times[-1] < times[0] * 1.6)
	var j_ok := true
	for i in 200:
		var p := _plot(&"wheat")
		p.seed = FarmPlant.mix32(i * 977)
		p.stage = i % 4
		var j := FarmPlant.jitter(p)
		j_ok = j_ok and j >= 0.85 and j <= 1.15
	_ok("the spread stays within 0.85-1.15", j_ok)


func _harvest() -> void:
	print("harvest")
	var p := _plot(&"wheat")
	_ok("a growing crop is not picked", FarmPlant.harvest(p, float(p.t) + 10.0).is_empty())
	_time_to_ripe(p)
	var fert0 := float(p.fert)
	var got := FarmPlant.harvest(p, float(p.t))
	var c := FarmCrops.get_crop(&"wheat")
	_ok("ripe wheat gives wheat and seeds", got.get("produce") == &"wheat" and int(got.count) >= 1
			and int(got.seeds) >= c.seeds_back.x, str(got))
	_ok("an annual leaves bare soil, fertility down by its drain", p.crop == &""
			and is_equal_approx(float(p.fert), fert0 - float(c.drain)) and p.fam == "grain")
	var t := float(p.t)
	FarmPlant.settle(p, t + FarmPlant.DAY * 2.0)
	_ok("bare soil gets fertility back (+%.0f in 2 days)" % (float(p.fert) - (fert0 - float(c.drain))),
			is_equal_approx(float(p.fert), minf(100.0, fert0 - float(c.drain) + 2.0 * FarmPlant.FALLOW_PER_DAY)))
	var bush := _plot(&"berry_bush")
	_time_to_ripe(bush)
	var bc := FarmCrops.get_crop(&"berry_bush")
	FarmPlant.harvest(bush, float(bush.t))
	_ok("a berry bush regrows from stage %d" % (int(bc.regrow_to) + 1), bush.crop == &"berry_bush"
			and int(bush.stage) == int(bc.regrow_to) and int(bush.picks) == 1)
	var beans := _plot(&"beans", true, 50.0)
	_time_to_ripe(beans)
	FarmPlant.harvest(beans, float(beans.t))
	_ok("beans give fertility back", float(beans.fert) > 50.0)
	var kept := _plot(&"wheat", true, 90.0)
	_time_to_ripe(kept)
	var starved := _plot(&"wheat", false, 5.0, 0.4)
	_time_to_ripe(starved)
	_ok("a kept crop gets 3 stars, a starved one 1 (%d, %d)" % [FarmPlant.stars(kept), FarmPlant.stars(starved)],
			FarmPlant.stars(kept) == 3 and FarmPlant.stars(starved) == 1)
	var n3 := 0
	var n1 := 0
	for i in 30:
		var a := _plot(&"potato", true, 90.0)
		a.seed = FarmPlant.mix32(i + 11)
		_time_to_ripe(a)
		n3 += int(FarmPlant.harvest(a, float(a.t)).count)
		var b := _plot(&"potato", false, 5.0, 0.2)
		b.seed = FarmPlant.mix32(i + 11)
		_time_to_ripe(b)
		n1 += int(FarmPlant.harvest(b, float(b.t)).count)
	_ok("3 stars yield more than 1 star (%d vs %d potatoes over 30)" % [n3, n1], n3 > n1)


func _save() -> void:
	print("save")
	var dir := UserPaths.DEV + "farm_probe"
	FarmStore.remove_dir_files(dir)
	var s := FarmStore.new()
	for i in 40:
		var p := FarmPlant.new_plot(Vector3i(i * 37 - 600, 41, i * 11 - 90), 360.0, 70.0, -1)
		if i % 3 != 0:
			FarmPlant.plant(p, FarmCrops.ids()[i % FarmCrops.ids().size()], 360.0)
			FarmPlant.settle(p, 360.0 + i * 50.0)
		s.put(p)
	var regions := s.take_dirty()
	FarmStore.write_regions(dir, regions)
	_ok("changed regions written (%d)" % regions.size(), regions.size() > 1 and not s.has_dirty())
	var back := FarmStore.new()
	var n := back.load_dir(dir)
	var same := n == 40
	for b in s.plots:
		same = same and back.plots.has(b) and str(FarmPlant.to_row(back.plots[b])) == str(FarmPlant.to_row(s.plots[b]))
	_ok("40 plots read back the same", same, "%d read" % n)
	# A region emptied is removed, not left behind.
	var gone: Vector3i = s.plots.keys()[0]
	var r := FarmStore.region_of(gone)
	var others := 0
	for b in s.plots:
		if FarmStore.region_of(b) == r:
			others += 1
	for b in s.plots.keys():
		if FarmStore.region_of(b) == r:
			s.remove(b)
	FarmStore.write_regions(dir, s.take_dirty())
	_ok("an emptied region's file goes (%d plots in it)" % others,
			not FileAccess.file_exists(dir.path_join("r_%d_%d.farm" % [r.x, r.y])))
	FarmStore.remove_dir_files(dir)


func _guide() -> void:
	print("guide")
	var ok := true
	for id in FarmCrops.ids():
		var c := FarmCrops.get_crop(id)
		var txt := FarmGuide.crop_text(c)
		ok = ok and txt.contains(c.name) and txt.contains("Ripe in") and txt.contains("Wants")
	_ok("a guide entry for every crop", ok)
	var w := FarmCrops.get_crop(&"wheat")
	_ok("the guide's times: wet sooner than dry", FarmGuide.ripe_seconds(w, true) < FarmGuide.ripe_seconds(w, false))
	print(FarmGuide.crop_text(w))
