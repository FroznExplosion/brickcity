class_name FarmCrops
extends RefCounted
## Every crop there is (Docs/MineFarming.md 6-7): `content/<pack>/data/farming/
## *.json` through ContentPacks, so a mod adds crops by shipping a table. A
## crop is a Dictionary with every field filled in (`_complete`); the fields
## are explained in the base pack's crops.json ("_about").

static var _crops := {}
static var _order: Array[StringName] = []
static var _by_seed := {}


static func load_all(force := false) -> void:
	if not _crops.is_empty() and not force:
		return
	_crops.clear()
	_order.clear()
	_by_seed.clear()
	for path in ContentPacks.files("data/farming"):
		var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
		if not (parsed is Dictionary) or not (parsed.get("crops") is Dictionary):
			push_warning("[farm] %s: no \"crops\" table" % path)
			continue
		for k in parsed.crops:
			if not (parsed.crops[k] is Dictionary):
				continue
			var id := StringName(k)
			var base: Dictionary = _crops.get(id, {})
			var raw: Dictionary = base.duplicate(true)
			raw.merge(parsed.crops[k], true)
			raw["id"] = id
			if not _crops.has(id):
				_order.append(id)
			_crops[id] = _complete(raw)
	for id in _order:
		_by_seed[_crops[id].seed] = id


static func _pair(v, a: int, b: int) -> Vector2i:
	if v is Array and (v as Array).size() >= 2:
		return Vector2i(int(v[0]), maxi(int(v[1]), int(v[0])))
	return Vector2i(a, b)


static func _complete(e: Dictionary) -> Dictionary:
	var look: Dictionary = e.get("look", {})
	return {
		"id": e.id,
		"name": str(e.get("name", String(e.id).capitalize())),
		"family": str(e.get("family", "")),
		"seed": StringName(str(e.get("seed", ""))),
		"produce": StringName(str(e.get("produce", ""))),
		"stages": clampi(int(e.get("stages", 4)), 2, 12),
		"stage_hours": maxf(float(e.get("stage_hours", 6.0)), 0.05),
		"dry_rate": clampf(float(e.get("dry_rate", 0.5)), 0.0, 1.0),
		"light": clampf(float(e.get("light", 0.5)), 0.0, 1.0),
		"drain": float(e.get("drain", 8.0)),
		"restores": float(e.get("restores", 0.0)),
		"likes": PackedStringArray(e.get("likes", [])),
		"dislikes": PackedStringArray(e.get("dislikes", [])),
		"yield": _pair(e.get("yield"), 1, 1),
		"seeds_back": _pair(e.get("seeds_back"), 0, 0),
		"regrow_to": int(e.get("regrow_to", -1)),
		"shape": str(look.get("shape", "grain")),
		"leaf": Color.html(str(look.get("leaf", "#4f9a32"))),
		"ripe": Color.html(str(look.get("ripe", "#d9b648"))),
		"found": e.get("found", []) if e.get("found") is Array else [],
		## A sapling: the tree variant (Trees) it grows into when ripe, -1 for a crop.
		"tree": int(e.get("tree", -1)),
		## A FRUIT tree (HandoffFarming.md 7.1): the stage at which the real tree
		## stands (-1: a timber sapling, the plot goes when it is grown). From
		## it on the plot is kept, the fruit grows in its leaves, and a pick
		## sends it back to `regrow_to`.
		"fruit_at": int(e.get("fruit_at", -1)),
		## In-game hours a stage once the tree stands (the fruit's); default
		## the sapling's stage_hours.
		"fruit_hours": maxf(float(e.get("fruit_hours", e.get("stage_hours", 6.0))), 0.05),
		## Where it is planted: "farm" tilled soil only; "soil" plain soil or tilled.
		"ground": str(e.get("ground", "farm")),
		## Crops it likes next to it (x COMPANION_BONUS), stage 6.
		"companions": PackedStringArray(e.get("companions", [])),
		## Biomes it grows in at all (empty: anywhere); planting is refused elsewhere.
		"only": PackedStringArray(e.get("only", [])),
		## A 2x2 of it, all ripe at 3 stars, may merge into a giant (stage 6).
		"giant": bool(e.get("giant", false)),
		"tips": str(e.get("tips", "")),
	}


## A sapling that grows into a timber tree and is gone as a plot when grown
## (not a fruit tree).
static func is_timber(c: Dictionary) -> bool:
	return not c.is_empty() and int(c.tree) >= 0 and int(c.get("fruit_at", -1)) < 0


## A fruit tree: a tree that stands on its plot and fruits again and again.
static func is_fruit_tree(c: Dictionary) -> bool:
	return not c.is_empty() and int(c.tree) >= 0 and int(c.get("fruit_at", -1)) >= 0


static func has(id: StringName) -> bool:
	load_all()
	return _crops.has(id)


## The crop, or {} if there is none by that id.
static func get_crop(id: StringName) -> Dictionary:
	load_all()
	return _crops.get(id, {})


static func ids() -> Array[StringName]:
	load_all()
	return _order


## The crop seed item `item` plants, or &"".
static func crop_of_seed(item: StringName) -> StringName:
	load_all()
	return _by_seed.get(item, &"")


## Seeds that breaking a block of terrain material `material_name` by hand may
## give: [[seed item, chance], ...].
static func found_in(material_name: String) -> Array:
	load_all()
	var out: Array = []
	for id in _order:
		for f in _crops[id].found:
			if f is Dictionary and str(f.get("material", "")) == material_name:
				out.append([_crops[id].seed, float(f.get("chance", 0.0))])
	return out
