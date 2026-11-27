class_name RecipeBook
extends RefCounted
## Crafting recipes (Docs/Inventory.md 12, 16). Tables in packs,
## `content/<pack>/data/recipes/*.json`, read through ContentPacks, so a mod
## adds recipes by shipping a file. A recipe has a SHAPE (zylanntest's
## recipe builder, Minecraft's grid) or is a plain list (shapeless):
##
##   {"name": "Chest", "station": "workbench", "output": "chest", "count": 1,
##    "pattern": ["WWW", "W W", "WWW"], "key": {"W": {"item": "wood", "count": 12}}}
##   {"name": "Obsidian", "inputs": {"lava_source": 1, "water_source": 1},
##    "output": "obsidian", "count": 12}
##
## `pattern`: rows of key letters, a space an empty cell (trimmed on load);
## `key`: letter -> {"item": id | "tag": tag, "count": n} -- a cell may need
## several of its item (materials count plate cells: a 2x2 brick is 12).
## `inputs` (shapeless): an item id or `#tag` and how many, in any cells.
## `station`: the station item that must stand within reach ("": by hand).
## `keep_contents`: the output (a backpack) keeps the input backpack's contents.
## `category`: the recipe book's tab (Docs/Inventory.md 14), else the output's.
##
## A recipe is a Dictionary: {name, inputs: [{id, tag, count}] (totals, the
## shape's too), station, output, count, keep_contents, category, grid (the
## smallest grid it fits: 2, 3 or 4), shape: {} or {w, h, cells: [cell or
## null], signature}} -- a cell is {id, tag, count}.

## The recipe book's tabs, Bedrock's.
const CATEGORIES := ["construction", "equipment", "items", "nature"]
## Crafting grids: by hand 2x2, a station's `grid` (a crafting table 3x3).
const MAX_GRID := 4
const LETTERS := "ABCDEFGHIJKLMNOPQRSTUVWXYZ"

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
				continue
			r["file"] = path
			# A later pack's recipe of the same name replaces the earlier
			# (the editor saving one over the base's).
			for i in range(_recipes.size() - 1, -1, -1):
				if _recipes[i].name == r.name:
					_recipes.remove_at(i)
			_recipes.append(r)


static func all() -> Array:
	load_all()
	return _recipes


static func by_name(name: String) -> Dictionary:
	for r in all():
		if r.name == name:
			return r
	return {}


## One table entry as a recipe, or {} if it is not one (an unknown item or
## station, no inputs, a pattern bigger than 4x4).
static func parse(raw) -> Dictionary:
	if not (raw is Dictionary):
		return {}
	var out := StringName(str(raw.get("output", "")))
	if not ItemCatalog.has(out):
		return {}
	var station := StringName(str(raw.get("station", "")))
	if station != &"" and not ItemCatalog.has(station):
		return {}
	var inputs := []
	var shape := {}
	if raw.get("pattern") is Array and raw.get("key") is Dictionary:
		shape = _parse_shape(raw.pattern, raw.key)
		if shape.is_empty():
			return {}
		for c in shape.cells:
			if c != null:
				_add_total(inputs, c)
	elif raw.get("inputs") is Dictionary:
		for k in raw.inputs:
			var c := cell_of(str(k), int(raw.inputs[k]))
			if c.is_empty():
				return {}
			_add_total(inputs, c)
	if inputs.is_empty():
		return {}
	var grid := 2
	if not shape.is_empty():
		grid = maxi(2, maxi(int(shape.w), int(shape.h)))
	else:
		grid = maxi(2, ceili(sqrt(float(inputs.size()))))
	return {"name": str(raw.get("name", ItemCatalog.get_def(out).get("name", out))), "inputs": inputs,
			"station": station, "output": out, "count": maxi(int(raw.get("count", 1)), 1),
			"keep_contents": bool(raw.get("keep_contents", false)),
			"category": str(raw.get("category", category_of_item(out))), "grid": grid, "shape": shape}


## "wood" / "#stone" and a count as a cell {id, tag, count}, or {} if unknown.
static func cell_of(name: String, n: int) -> Dictionary:
	n = maxi(n, 1)
	if name.begins_with("#"):
		return {"id": &"", "tag": name.substr(1), "count": n}
	if ItemCatalog.has(StringName(name)):
		return {"id": StringName(name), "tag": "", "count": n}
	return {}


static func _add_total(inputs: Array, c: Dictionary) -> void:
	for t in inputs:
		if t.id == c.id and t.tag == c.tag:
			t.count = int(t.count) + int(c.count)
			return
	inputs.append({"id": c.id, "tag": c.tag, "count": int(c.count)})


static func _parse_shape(rows: Array, key: Dictionary) -> Dictionary:
	var keyed := {}
	for k in key:
		var v = key[k]
		var c := {}
		if v is Dictionary:
			c = cell_of(("#" + str(v.tag)) if v.has("tag") else str(v.get("item", "")), int(v.get("count", 1)))
		else:
			c = cell_of(str(v), 1)
		if c.is_empty():
			return {}
		keyed[str(k)] = c
	var h := rows.size()
	var w := 0
	for r in rows:
		w = maxi(w, str(r).length())
	var cells := []
	for y in h:
		var row := str(rows[y])
		for x in w:
			var ch := row[x] if x < row.length() else " "
			if ch == " " or ch == ".":
				cells.append(null)
			elif keyed.has(ch):
				cells.append((keyed[ch] as Dictionary).duplicate())
			else:
				return {}
	return trim_shape(w, h, cells)


## A shape without its empty outer rows and columns (zylanntest's trim), with
## its signature; {} if it has no cells or is bigger than 4x4.
static func trim_shape(w: int, h: int, cells: Array) -> Dictionary:
	var x0 := w
	var x1 := -1
	var y0 := h
	var y1 := -1
	for y in h:
		for x in w:
			if cells[y * w + x] != null:
				x0 = mini(x0, x)
				x1 = maxi(x1, x)
				y0 = mini(y0, y)
				y1 = maxi(y1, y)
	if x1 < 0:
		return {}
	var tw := x1 - x0 + 1
	var th := y1 - y0 + 1
	if tw > MAX_GRID or th > MAX_GRID:
		return {}
	var out := []
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			out.append(cells[y * w + x])
	var s := {"w": tw, "h": th, "cells": out}
	s["signature"] = signature(s)
	return s


## "2x3:wood*12,_,..." -- two recipes may not share one (the editor checks).
static func signature(s: Dictionary) -> String:
	var parts := PackedStringArray()
	for c in s.cells:
		if c == null:
			parts.append("_")
		else:
			parts.append("%s*%d" % [("#" + str(c.tag)) if str(c.tag) != "" else str(c.id), int(c.count)])
	return "%dx%d:%s" % [int(s.w), int(s.h), ",".join(parts)]


## Does stack `s` count for input or cell `inp`?
static func takes(inp: Dictionary, s: ItemStack) -> bool:
	if s == null or s.is_empty():
		return false
	if str(inp.get("tag", "")) != "":
		return PackedStringArray(ItemCatalog.get_def(s.id).get("tags", [])).has(inp.tag)
	return s.id == inp.id


## The grid a recipe in a crafting grid of `n` matches, Minecraft's way: the
## items' layout (trimmed, mirrored left-right too) is the recipe's shape, or
## the items are exactly a shapeless recipe's inputs. Counts are not part of
## the match (a cell short is made up from what the player carries, 16.1).
## `grid` is n*n stacks or nulls, row by row. Returns {} or {"recipe": r,
## "need": [{"idx": [grid cells], "cell": {id, tag, count}}]} -- for a shape
## one grid cell an entry, for a list every grid cell holding that input.
## `prefer`: a recipe tried first (the one picked in the book).
static func match_grid(grid: Array, n: int, prefer: Dictionary = {}) -> Dictionary:
	var x0 := n
	var x1 := -1
	var y0 := n
	var y1 := -1
	var filled := []
	for y in n:
		for x in n:
			var s: ItemStack = grid[y * n + x]
			if s != null and not s.is_empty():
				x0 = mini(x0, x)
				x1 = maxi(x1, x)
				y0 = mini(y0, y)
				y1 = maxi(y1, y)
				filled.append(y * n + x)
	if filled.is_empty():
		return {}
	var w := x1 - x0 + 1
	var h := y1 - y0 + 1
	# The recipe picked in the book first: two lists of the same items (iron
	# ingots for a can, a sprinkler) are told apart by what was picked.
	var order := all()
	if not prefer.is_empty():
		order = [prefer] + all().filter(func(o: Dictionary) -> bool: return o.name != prefer.name)
	for r in order:
		if int(r.grid) > n:
			continue
		var sh: Dictionary = r.shape
		if not sh.is_empty():
			if int(sh.w) != w or int(sh.h) != h:
				continue
			for mirror in [false, true]:
				var need := []
				var ok := true
				for y in h:
					for x in w:
						var c = sh.cells[y * w + (w - 1 - x if mirror else x)]
						var gi := (y0 + y) * n + x0 + x
						var s: ItemStack = grid[gi]
						var empty := s == null or s.is_empty()
						if (c == null) != empty:
							ok = false
						elif c != null and not takes(c, s):
							ok = false
						elif c != null:
							need.append({"idx": [gi], "cell": c})
						if not ok:
							break
					if not ok:
						break
				if ok:
					return {"recipe": r, "need": need}
			continue
		# Shapeless: every item in the grid is one of the inputs, every input there.
		var need2 := []
		var used := {}
		var ok2 := true
		for inp in r.inputs:
			var idx := []
			for gi in filled:
				if takes(inp, grid[gi]):
					idx.append(gi)
					used[gi] = true
			if idx.is_empty():
				ok2 = false
				break
			need2.append({"idx": idx, "cell": inp})
		if ok2 and used.size() == filled.size():
			return {"recipe": r, "need": need2}
	return {}


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


## An input in words: "48 Stone", "12 any ore".
static func input_name(inp: Dictionary) -> String:
	var what: String = ("any " + inp.tag) if str(inp.tag) != "" else str(ItemCatalog.get_def(inp.id).get("name", inp.id))
	return "%d %s" % [int(inp.count), what]


static func station_name(r: Dictionary) -> String:
	if r.station == &"":
		return "by hand"
	return "at a " + str(ItemCatalog.get_def(r.station).get("name", r.station)).to_lower()


# ---------------------------------------------------------------------------
# The recipe editor's side (Docs/Inventory.md 16.3)

## A recipe as a table entry (what `parse` reads back): the shape as rows and
## letters, one letter per different {item, count}.
static func to_raw(r: Dictionary) -> Dictionary:
	var raw := {"name": r.name, "output": String(r.output), "count": int(r.count)}
	if r.station != &"":
		raw["station"] = String(r.station)
	if r.get("keep_contents", false):
		raw["keep_contents"] = true
	if str(r.get("category", "")) != "" and r.category != category_of_item(r.output):
		raw["category"] = r.category
	var sh: Dictionary = r.get("shape", {})
	if sh.is_empty():
		var inputs := {}
		for inp in r.inputs:
			inputs[("#" + str(inp.tag)) if str(inp.tag) != "" else String(inp.id)] = int(inp.count)
		raw["inputs"] = inputs
		return raw
	var letter_of := {}
	var key := {}
	var rows := []
	for y in int(sh.h):
		var row := ""
		for x in int(sh.w):
			var c = sh.cells[y * int(sh.w) + x]
			if c == null:
				row += " "
				continue
			var k := "%s|%s|%d" % [c.id, c.tag, int(c.count)]
			if not letter_of.has(k):
				var l := LETTERS[letter_of.size() % LETTERS.length()]
				letter_of[k] = l
				key[l] = {"tag": c.tag, "count": int(c.count)} if str(c.tag) != "" \
						else {"item": String(c.id), "count": int(c.count)}
			row += letter_of[k]
		rows.append(row)
	raw["pattern"] = rows
	raw["key"] = key
	return raw


## Where recipes made in game are saved: in the editor build the base pack
## (they ship), in a player build the player's own mod pack (Docs/Content.md).
## A probe's file instead (never the game's tables from a test).
static var custom_path_override := ""


static func custom_path() -> String:
	if not custom_path_override.is_empty():
		return custom_path_override
	if OS.has_feature("editor"):
		return "res://content/base/data/recipes/custom.json"
	return ContentPacks.mods_root().path_join("my_recipes/data/recipes/custom.json")


## Save (or replace, by name) recipe `r` in the custom table; reload. "" or why not.
static func save_custom(r: Dictionary) -> String:
	var sh: Dictionary = r.get("shape", {})
	if not sh.is_empty():
		for o in all():
			if o.name != r.name and not (o.shape as Dictionary).is_empty() and o.shape.signature == sh.signature:
				return "\"%s\" already has that shape" % o.name
	var path := custom_path()
	var table := _read_table(path)
	var list: Array = table.recipes
	list = list.filter(func(e) -> bool: return not (e is Dictionary and str(e.get("name", "")) == r.name))
	list.append(to_raw(r))
	table.recipes = list
	var why := _write_table(path, table)
	if why.is_empty() and custom_path_override.is_empty():
		ContentPacks.reload()
		load_all(true)
	return why


## Delete recipe `name` from the custom table (a recipe in another table is
## not deleted: it is turned off by an entry with "off": true). "" or why not.
static func delete_custom(name: String) -> String:
	var path := custom_path()
	var table := _read_table(path)
	var before: int = (table.recipes as Array).size()
	table.recipes = (table.recipes as Array).filter(func(e) -> bool:
		return not (e is Dictionary and str(e.get("name", "")) == name))
	if (table.recipes as Array).size() == before:
		return "\"%s\" is not one of the recipes made here" % name
	var why := _write_table(path, table)
	if why.is_empty():
		load_all(true)
	return why


static func _read_table(path: String) -> Dictionary:
	if FileAccess.file_exists(path):
		var t = JSON.parse_string(FileAccess.get_file_as_string(path))
		if t is Dictionary and t.get("recipes") is Array:
			return t
	return {"recipes": []}


static func _write_table(path: String, table: Dictionary) -> String:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	if path.begins_with(ContentPacks.mods_root()):
		var manifest := path.get_base_dir().get_base_dir().get_base_dir().path_join(ContentPacks.MANIFEST)
		if not FileAccess.file_exists(manifest):
			var mf := FileAccess.open(manifest, FileAccess.WRITE)
			if mf != null:
				mf.store_string(JSON.stringify({"format": 1, "id": "my_recipes", "name": "My recipes",
						"version": "1.0.0", "description": "Recipes made in the game's recipe editor.",
						"requires": []}, "\t"))
				mf.close()
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return "cannot write %s" % path
	f.store_string(JSON.stringify(table, "\t"))
	f.close()
	return ""
