class_name FarmGuide
extends RefCounted
## The farming guide (the inventory screen's Farming tab): how farming works,
## then every crop -- what it is planted from, what it gives, how long it
## takes, and what it wants. Written from the crop table (FarmCrops) and the
## growth rules (FarmPlant), so it is never out of step with the game.

const HOW := [
	"1  HOE: right-click the top of grass, dirt or podzol. That 2x2 brick becomes tilled soil: smooth and furrowed.",
	"2  PLANT: seeds in the hand, right-click the tilled soil. Carrots, potatoes, beans and berries are planted as they are.",
	"3  WATER: water within 4 studs (a dug channel, a pond, a bucket poured beside it) makes the soil wet -- it turns dark. Dry soil slows a crop to 25-75% speed.",
	"4  LIGHT: crops grow by daylight (slowly at night). Under a roof or underground they need light (lava light counts for now).",
	"5  SOIL: each harvest uses up fertility; bare tilled soil gets 10 back a day; beans give some back. A crop of another family than the last one there grows 15% faster.",
	"6  HARVEST: right- or left-click a ripe crop. It replants itself from the seeds you carry. Left-click a growing crop to pull it (seed back).",
	"7  QUALITY: every stage spent dry (for thirsty crops), too dark, on poor soil or in a biome it dislikes is a stress point. 0-1 points: 3 stars, 50% more; 4 or more: 1 star, less.",
	"8  CAREFUL: landing on a field from 3 bricks up or more tramples that plot back to dirt (the seed pops out). Walking and jumping on it are fine.",
	"9  TIME: crops grow on the world's clock while you play -- also where you are not, far across the world -- but not while the game is closed. Look at a plot to see its stage, time to ripe and what holds it back.",
]


## Seconds of world time from planting to ripe, without the per-plant spread:
## in full open sky, at fertility `fert`, wet or dry, in a neutral biome.
static func ripe_seconds(crop: Dictionary, wet: bool, fert := 70.0) -> float:
	var plot := FarmPlant.new_plot(Vector3i.ZERO, 0.0, fert, -1)
	plot.wet = wet
	var soil := FarmPlant.soil_factor(plot, crop)
	var water := FarmPlant.water_factor(plot, crop)
	var stages := int(crop.stages) - 1
	return float(crop.stage_hours) * FarmPlant.HOUR * stages / (soil * water * FarmPlant.mean_light(plot))


static func _item_name(id: StringName) -> String:
	return str(ItemCatalog.get_def(id).get("name", String(id)))


static func _range(v: Vector2i) -> String:
	return str(v.x) if v.x == v.y else "%d-%d" % [v.x, v.y]


## The lines for one crop.
static func crop_text(crop: Dictionary) -> String:
	var lines := PackedStringArray()
	var gives := "%s %s" % [_item_name(crop.produce), _range(crop.yield)]
	if crop.seeds_back.y > 0:
		gives += " and %s %s" % [_item_name(crop.seed), _range(crop.seeds_back)]
	lines.append("%s  (%s)   from: %s   gives: %s" % [crop.name, crop.family, _item_name(crop.seed), gives])
	var wet_t := FarmPlant.span_words(ripe_seconds(crop, true))
	var dry_t := FarmPlant.span_words(ripe_seconds(crop, false))
	var grow := "Ripe in ~%s on wet soil in full sun, ~%s dry (%d%% speed)   ·   %d stages" % [
			wet_t, dry_t, roundi(float(crop.dry_rate) * 100.0), int(crop.stages) - 1]
	if int(crop.regrow_to) >= 0:
		grow += "   ·   regrows after picking (back to stage %d)" % (int(crop.regrow_to) + 1)
	lines.append(grow)
	var wants := PackedStringArray()
	wants.append("water: %s" % ("needs it" if float(crop.dry_rate) < 0.35 else
			("wants it" if float(crop.dry_rate) < FarmPlant.THIRSTY else "copes without")))
	var light := float(crop.light)
	wants.append("light: %s" % ("full sun" if light >= 0.75 else ("open sky" if light >= 0.55 else
			("some shade is fine" if light >= 0.35 else "happy in shade"))))
	var soil := "soil: uses %d fertility a harvest" % roundi(float(crop.drain))
	if float(crop.restores) > 0.0:
		soil = "soil: GIVES BACK %d fertility a harvest" % roundi(float(crop.restores) - float(crop.drain))
	wants.append(soil)
	lines.append("Wants   " + "   ·   ".join(wants))
	var biomes := PackedStringArray()
	if not crop.likes.is_empty():
		biomes.append("likes " + ", ".join(crop.likes) + " (+25%)")
	if not crop.dislikes.is_empty():
		biomes.append("dislikes " + ", ".join(crop.dislikes) + " (-30%)")
	if not biomes.is_empty():
		lines.append("Biomes  " + "   ·   ".join(biomes))
	var found := PackedStringArray()
	for f in crop.found:
		if f is Dictionary:
			found.append("%s (%d%%)" % [f.get("material", "?"), roundi(float(f.get("chance", 0.0)) * 100.0)])
	if not found.is_empty():
		lines.append("Find it  breaking by hand in survival: " + ", ".join(found))
	if crop.tips != "":
		lines.append("Tip     " + crop.tips)
	return "\n".join(lines)


## The whole page: the how-to, then a row per crop with its seed and produce
## icons. `make_slot` (id, count) -> a Control showing an item.
static func build(make_slot: Callable) -> VBoxContainer:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	var how := Label.new()
	how.text = "\n".join(HOW)
	MenuFit.fit_label(how, true)
	v.add_child(how)
	v.add_child(HSeparator.new())
	for id in FarmCrops.ids():
		var crop := FarmCrops.get_crop(id)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 12)
		row.add_child(make_slot.call(crop.seed, 1))
		if crop.produce != crop.seed:
			row.add_child(make_slot.call(crop.produce, 1))
		var l := Label.new()
		l.text = crop_text(crop)
		MenuFit.fit_label(l, true)
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(l)
		v.add_child(row)
	return v
