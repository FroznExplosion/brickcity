class_name RecipeBook
extends RefCounted
## Crafting recipes (Docs/Inventory.md 12), Terraria's: a recipe is what it
## takes and where it is made, no shapes. Tables in packs,
## `content/<pack>/data/recipes/*.json`, read through ContentPacks, so a mod
## adds recipes by shipping a file:
##
##   {"recipes": [{"name": "Chest", "inputs": {"#stone": 48},
##       "station": "workbench", "output": "chest", "count": 1}]}
##
## `inputs`: an item id, or `#tag` for any items with that tag, and how many
## (materials count plate cells: a 2x2 brick is 12). `station`: the station
## item that must stand within reach ("" or none: by hand). `keep_contents`:
## the output (a backpack) keeps the contents of the input backpack.
## `category`: the recipe book's tab (Docs/Inventory.md 14), else the
## output item's (`category_of_item`).
## A recipe is a Dictionary: {name, inputs: [{id, tag, count}], station,
## output, count, keep_contents, category}.

## The recipe book's tabs, Bedrock's.
const CATEGORIES := ["construction", "equipment", "items", "nature"]

static var _recipes: Array = []
static var _loaded := false


static func load_all(force := false) -> void:
	if _loaded and not force:
		return
	_loaded = true
	_recipes.clear()
	ItemCatalog.load_all()
	for path in ContentPacks.files("data/recipes"):
		var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
		if not (parsed is Dictionary) or not (parsed.get("recipes") is Array):
			push_warning("[recipes] %s: no \"recipes\" list" % path)
			continue
		for raw in parsed.recipes:
			var r := parse(raw)
			if r.is_empty():
				push_warning("[recipes] %s: a recipe not understood: %s" % [path, raw])
			else:
				_recipes.append(r)


static func all() -> Array:
	load_all()
	return _recipes


## One table entry as a recipe, or {} if it is not one (an unknown item or
## station, no inputs).
static func parse(raw) -> Dictionary:
	if not (raw is Dictionary) or not (raw.get("inputs") is Dictionary):
		return {}
	var out := StringName(str(raw.get("output", "")))
	if not ItemCatalog.has(out):
		return {}
	var station := StringName(str(raw.get("station", "")))
	if station != &"" and not ItemCatalog.has(station):
		return {}
	var inputs := []
	for k in raw.inputs:
		var name := str(k)
		var n := maxi(int(raw.inputs[k]), 1)
		if name.begins_with("#"):
			inputs.append({"id": &"", "tag": name.substr(1), "count": n})
		elif ItemCatalog.has(StringName(name)):
			inputs.append({"id": StringName(name), "tag": "", "count": n})
		else:
			return {}
	if inputs.is_empty():
		return {}
	return {"name": str(raw.get("name", ItemCatalog.get_def(out).get("name", out))), "inputs": inputs,
			"station": station, "output": out, "count": maxi(int(raw.get("count", 1)), 1),
			"keep_contents": bool(raw.get("keep_contents", false)),
			"category": str(raw.get("category", category_of_item(out)))}


## The recipe book tab an item's recipes go under: the item's `category`, or
## by its kind -- blocks are construction; tools, weapons, buckets and
## backpacks equipment; seeds, crops and fluids nature; the rest items.
static func category_of_item(id: StringName) -> String:
	var d := ItemCatalog.get_def(id)
	if CATEGORIES.has(str(d.get("category", ""))):
		return str(d.category)
	match str(d.get("kind", "")):
		"block":
			return "construction"
		"tool", "hoe", "scythe", "can", "bucket", "source_bucket", "grenade", "gun", "backpack":
			return "equipment"
		"seed", "fluid":
			return "nature"
		"misc":
			return "nature" if str(d.get("model", "")) == "produce" else "items"
	return "items"


## Does stack `s` count for input `inp`?
static func takes(inp: Dictionary, s: ItemStack) -> bool:
	if s == null or s.is_empty():
		return false
	if inp.tag != "":
		return PackedStringArray(ItemCatalog.get_def(s.id).get("tags", [])).has(inp.tag)
	return s.id == inp.id


## An input in words: "48 Stone", "12 any ore".
static func input_name(inp: Dictionary) -> String:
	var what: String = ("any " + inp.tag) if inp.tag != "" else str(ItemCatalog.get_def(inp.id).get("name", inp.id))
	return "%d %s" % [int(inp.count), what]


static func station_name(r: Dictionary) -> String:
	if r.station == &"":
		return "by hand"
	return "at a " + str(ItemCatalog.get_def(r.station).get("name", r.station)).to_lower()
