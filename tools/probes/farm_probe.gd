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
##   stage4    a grow mix's boost runs out at a set time and the catch-up is
##             exact across it; boosted grows faster; a plot row keeps its
##             boost and ground; the new crops and the four saplings load, each
##             sapling naming its tree; compost, grow mix and the bin have
##             recipes; every produce is a #crop for compost.
##   can       stage 3: a watering can's water runs out at a set time and the
##             catch-up is still exact across it (once == often == saved half
##             way); watered grows faster than dry and slows again after; the
##             tools are items with recipes.

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
	_exact()            # with TROUBLE on: events must keep it exact too
	# The growth rules alone: no random trouble in these.
	FarmPlant.trouble = false
	_light()
	_factors()
	_harvest()
	_save()
	_guide()
	_can()
	_stage4()
	FarmPlant.trouble = true
	_trouble()
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
	# The water look's one call (Docs/MineFarming.md 19).
	_ok("BrickFluid.any_fluid is there", ClassDB.class_has_method("BrickFluid", "any_fluid"))


func _crops() -> void:
	print("crops")
	var ids := FarmCrops.ids()
	_ok("six crops in the base pack", ids.size() >= 6, str(ids))
	for id in ids:
		var c := FarmCrops.get_crop(id)
		var seed_ok := ItemCatalog.kind(c.seed) == "seed" and StringName(str(ItemCatalog.get_def(c.seed).get("crop", ""))) == id
		var produce_ok: bool = ItemCatalog.has(c.produce) or (int(c.tree) >= 0 and c.produce == &"")
		_ok("%s: seed %s plants it, produce %s is an item" % [id, c.seed, c.produce],
				seed_ok and produce_ok and FarmCrops.crop_of_seed(c.seed) == id)


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
		ok = ok and txt.contains(c.name) and (txt.contains("Ripe in") or txt.contains("Grown in")) and txt.contains("Wants")
	_ok("a guide entry for every crop", ok)
	var w := FarmCrops.get_crop(&"wheat")
	_ok("the guide's times: wet sooner than dry", FarmGuide.ripe_seconds(w, true) < FarmGuide.ripe_seconds(w, false))
	print(FarmGuide.crop_text(w))


func _can() -> void:
	print("can")
	var d := FarmPlant.DAY
	for id in [&"wheat", &"pumpkin"]:
		var once := _plot(id, false)
		once.wet_until = float(once.t) + d * 0.6
		var often := once.duplicate()
		var half := once.duplicate()
		var t_end := float(once.t) + d * 2.3
		FarmPlant.settle(once, t_end)
		var t := float(often.t)
		while t < t_end:
			t = minf(t_end, t + 7.3)
			FarmPlant.settle(often, t)
		FarmPlant.settle(half, float(half.t) + d * 0.6 + 3.0)
		var back := FarmPlant.from_row(FarmPlant.to_row(half))
		FarmPlant.settle(back, t_end)
		_ok("%s watered for 0.6 days: once == often == saved across the water running out (stage %d)" % [id, once.stage],
				int(once.stage) == int(often.stage) and absf(float(once.p) - float(often.p)) < 1e-6
				and int(once.stage) == int(back.stage) and absf(float(once.p) - float(back.p)) < 1e-6
				and is_equal_approx(float(back.wet_until), float(once.wet_until)),
				"often %d %.6f, saved %d %.6f" % [often.stage, often.p, back.stage, back.p])
	var dry := _plot(&"wheat", false)
	var watered := _plot(&"wheat", false)
	watered.wet_until = float(watered.t) + d
	var t1 := float(dry.t) + d
	FarmPlant.settle(dry, t1)
	FarmPlant.settle(watered, t1)
	_ok("a watered day grows more than a dry one", int(watered.stage) * 10.0 + float(watered.p) > int(dry.stage) * 10.0 + float(dry.p))
	_ok("the water runs out: wet before, dry after", FarmPlant.wet_at(watered, t1 - 1.0) and not FarmPlant.wet_at(watered, t1 + 1.0))
	var row := FarmPlant.to_row(_plot(&"wheat"))
	row.resize(17)
	_ok("an old 17-field row loads, never watered", float(FarmPlant.from_row(row).wet_until) == 0.0)
	var names := []
	for r in RecipeBook.all():
		names.append(str(r.output))
	_ok("hoe, scythe and watering can have recipes", names.has("hoe") and names.has("scythe") and names.has("watering_can"))
	_ok("the scythe and can are items of their kinds", ItemCatalog.kind(&"scythe") == "scythe" and ItemCatalog.kind(&"watering_can") == "can")
	var area: Array[Vector2i] = MineFarming.area_blocks(Vector3i(0, 40, 0), Vector3i(100, 40, -100))
	_ok("an area is at most 9 x 9 plots (%d)" % area.size(), area.size() == MineFarming.AREA_MAX * MineFarming.AREA_MAX)


func _stage4() -> void:
	print("stage4")
	var d := FarmPlant.DAY
	for id in [&"corn", &"cabbage"]:
		var once := _plot(id, true)
		once.boost_until = float(once.t) + d * 0.7
		var often := once.duplicate()
		var half := once.duplicate()
		var t_end := float(once.t) + d * 1.9
		FarmPlant.settle(once, t_end)
		var t := float(often.t)
		while t < t_end:
			t = minf(t_end, t + 9.1)
			FarmPlant.settle(often, t)
		FarmPlant.settle(half, float(half.t) + d * 0.7 + 2.0)
		var back := FarmPlant.from_row(FarmPlant.to_row(half))
		FarmPlant.settle(back, t_end)
		_ok("%s with a grow mix for 0.7 days: once == often == saved across its end (stage %d)" % [id, once.stage],
				int(once.stage) == int(often.stage) and absf(float(once.p) - float(often.p)) < 1e-6
				and int(once.stage) == int(back.stage) and absf(float(once.p) - float(back.p)) < 1e-6,
				"often %d %.6f, saved %d %.6f" % [often.stage, often.p, back.stage, back.p])
	var plain := _plot(&"corn", true)
	var mixed := _plot(&"corn", true)
	mixed.boost_until = float(mixed.t) + d * 2.0
	var tm := _time_to_ripe(mixed)
	var tp := _time_to_ripe(plain)
	_ok("a grow mix makes corn ripen sooner (%.2f vs %.2f days)" % [tm / d, tp / d], tm < tp)
	var soil := _plot(&"oak_tree")
	soil.ground = "soil"
	var row := FarmPlant.from_row(FarmPlant.to_row(soil))
	_ok("a row keeps its ground and boost", row.ground == "soil" and float(row.boost_until) == float(soil.boost_until))
	var ok_trees := true
	for v in Trees.VARIANTS:
		var sap := MineFarming.sapling_of(v)
		ok_trees = ok_trees and sap != &"" and int(FarmCrops.get_crop(FarmCrops.crop_of_seed(sap)).tree) == v 				and str(FarmCrops.get_crop(FarmCrops.crop_of_seed(sap)).ground) == "soil"
	_ok("a sapling for every tree kind, planted on plain soil", ok_trees)
	var tree := _plot(&"birch_tree")
	_ok("a sapling grows up in %.1f days" % (_time_to_ripe(tree) / d), FarmPlant.is_ripe(tree))
	var outs := []
	for r in RecipeBook.all():
		outs.append(str(r.output))
	_ok("compost bin, compost and grow mix have recipes", outs.has("compost_bin") and outs.count("compost") == 2
			and outs.has("grow_mix"))
	_ok("compost and grow mix are fertilisers", ItemCatalog.kind(&"compost") == "fertiliser"
			and float(ItemCatalog.get_def(&"grow_mix").get("boost_days", 0)) > 0.0)
	var crops := 0
	for id in FarmCrops.ids():
		var c := FarmCrops.get_crop(id)
		if c.produce != &"" and PackedStringArray(ItemCatalog.get_def(c.produce).get("tags", [])).has("crop"):
			crops += 1
	_ok("every produce composts (%d tagged crop)" % crops, crops == 9)


## Stage 5: random trouble, drawn from each plot's seed.
func _trouble() -> void:
	print("trouble")
	var d := FarmPlant.DAY
	# Exact with every hazard on: once == every few seconds == saved half way.
	var all_same := true
	var any_events := 0
	for i in 12:
		var once := FarmPlant.new_plot(Vector3i(i, 41, 3), 360.0, 70.0, -1)
		once.wet = true
		once.open = true
		once.mono = true
		FarmPlant.plant(once, [&"wheat", &"beans", &"corn"][i % 3], 360.0)
		var often := once.duplicate()
		var half := once.duplicate()
		var t_end := 360.0 + d * 6.0
		FarmPlant.settle(once, t_end)
		var t := 360.0
		while t < t_end:
			t = minf(t_end, t + 23.7)
			FarmPlant.settle(often, t)
		FarmPlant.settle(half, 360.0 + d * 2.9)
		var back := FarmPlant.from_row(FarmPlant.to_row(half))
		FarmPlant.settle(back, t_end)
		for other in [often, back]:
			all_same = all_same and int(other.events) == int(once.events) and other.crop == once.crop \
					and int(other.stage) == int(once.stage) and absf(float(other.p) - float(once.p)) < 1e-6 \
					and bool(other.weeds) == bool(once.weeds) and bool(other.packed) == bool(once.packed)
		any_events += int(once.events)
	_ok("with every trouble on, once == often == saved half way (12 plots, %d events)" % any_events,
			all_same and any_events > 0)
	# Animals only in open fields; mulch keeps weeds off; a scarecrow most birds.
	var open_ev := 0
	var closed_ev := 0
	var weeds_bare := 0
	var weeds_mulch := 0
	var birds_free := 0
	var birds_scared := 0
	for i in 40:
		var a := _ripe_held(i, true, false, false)
		var b := _ripe_held(i, false, false, false)
		open_ev += _count_events(a, "animals")
		closed_ev += _count_events(b, "animals")
		weeds_bare += 1 if bool(b.weeds) else 0
		var m := _ripe_held(i, false, true, false)
		weeds_mulch += 1 if bool(m.weeds) else 0
		birds_free += _count_events(b, "birds")
		birds_scared += _count_events(_ripe_held(i, false, false, true), "birds")
	_ok("animals visit open fields (%d) and never closed ones (%d)" % [open_ev, closed_ev], open_ev > 0 and closed_ev == 0)
	_ok("mulch keeps weeds off (%d of 40 weedy bare, %d mulched)" % [weeds_bare, weeds_mulch], weeds_bare > 0 and weeds_mulch == 0)
	_ok("a scarecrow keeps most birds off (%d visits free, %d scared)" % [birds_free, birds_scared], birds_scared < birds_free)
	var w := _plot(&"wheat")
	var r0 := FarmPlant.rate(w, FarmCrops.get_crop(&"wheat"), true)
	w.weeds = true
	_ok("weeds slow a crop", FarmPlant.rate(w, FarmCrops.get_crop(&"wheat"), true) < r0)
	FarmPlant.trouble = false
	var calm := FarmPlant.new_plot(Vector3i(0, 41, 0), 360.0, 70.0, -1)
	calm.open = true
	calm.mono = true
	FarmPlant.plant(calm, &"wheat", 360.0)
	FarmPlant.settle(calm, 360.0 + d * 10.0)
	_ok("trouble off: no events at all", int(calm.events) == 0)
	FarmPlant.trouble = true
	# Fields: plots that touch, and a one-crop field.
	var s := FarmStore.new()
	for x in 5:
		for z in 5:
			var p := FarmPlant.new_plot(Vector3i(x, 41, z), 0.0, 70.0, -1)
			p.crop = &"wheat"
			s.put(p)
	var lone := FarmPlant.new_plot(Vector3i(20, 41, 20), 0.0, 70.0, -1)
	lone.crop = &"wheat"
	s.put(lone)
	var ff := FarmFields.new()
	ff.regroup(s)
	var sizes := []
	for f in ff.fields:
		sizes.append(f.plots.size())
	sizes.sort()
	_ok("two fields (1 and 25 plots): %s" % str(sizes), sizes == [1, 25])
	var mono_ok := false
	for f in ff.fields:
		if f.plots.size() == 25:
			mono_ok = f.mono == &"wheat"
	_ok("25 plots of wheat is a one-crop field", mono_ok)
	var old := FarmPlant.to_row(_plot(&"wheat"))
	old.resize(20)
	_ok("a 20-field row from stage 4 loads, no trouble flags", not bool(FarmPlant.from_row(old).open)
			and int(FarmPlant.from_row(old).events) == 0)


## A wheat plot held ripe for 3 days (birds come only then), with the flags.
func _ripe_held(i: int, open: bool, mulch: bool, scared: bool) -> Dictionary:
	var p := FarmPlant.new_plot(Vector3i(i, 41, 9), 360.0, 70.0, -1)
	p.wet = true
	p.open = open
	p.mulch = mulch
	p.scared = scared
	FarmPlant.plant(p, &"wheat", 360.0)
	p.stage = 4
	FarmPlant.settle(p, 360.0 + FarmPlant.DAY * 3.0)
	return p


func _count_events(p: Dictionary, what: String) -> int:
	# The last event says what came; a plot that had any shows it in its count.
	return int(p.events) if str(p.last_event).contains(what) else 0
