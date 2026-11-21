class_name RecipeBook
extends RefCounted
## Crafting recipes (Docs/Inventory.md 9), zylanntest's RecipeBook made a
## pack table: `content/<pack>/data/recipes/*.json`, read through
## ContentPacks, so a mod adds recipes by shipping a file.
##
##   {"recipes": [{"name": "Sandstone", "pattern": ["ss", "ss"],
##       "key": {"s": "sand"}, "output": "sandstone", "count": 1}]}
##
## `pattern` rows are cells, `.` or a space empty; `key` names an item id, or
## `#tag` for any item with that tag, or {"item": .., "count": n} for more
## than one in a cell. `keep_contents`: the output (a backpack) keeps the
## contents of the first ingredient that has some.
##
## Matching is zylanntest's: the pattern is trimmed to what it fills and
## matched wherever it sits in the grid, a cell may hold more than it needs;
## the mirror image matches too (Minecraft's). A recipe is a Dictionary:
## {name, w, h, cells: [{id, tag, count} or null], output, count, keep_contents}.

const GRID := 2

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


## One table entry as a recipe, or {} if it is not one (an unknown item, a
## pattern bigger than the grid).
static func parse(raw) -> Dictionary:
	if not (raw is Dictionary) or not (raw.get("pattern") is Array):
		return {}
	var rows: Array = raw.pattern
	var key: Dictionary = raw.get("key", {})
	var out := StringName(str(raw.get("output", "")))
	if not ItemCatalog.has(out) or rows.is_empty() or rows.size() > GRID:
		return {}
	var w := 0
	for row in rows:
		w = maxi(w, str(row).length())
	if w == 0 or w > GRID:
		return {}
	var cells := []
	for row in rows:
		var s := str(row)
		for c in w:
			var ch := s[c] if c < s.length() else "."
			if ch == "." or ch == " ":
				cells.append(null)
				continue
			var spec = key.get(ch)
			var cell := {"id": &"", "tag": "", "count": 1}
			if spec is Dictionary:
				cell.count = maxi(int(spec.get("count", 1)), 1)
				spec = spec.get("item", "")
			var name := str(spec)
			if name.begins_with("#"):
				cell.tag = name.substr(1)
			elif ItemCatalog.has(StringName(name)):
				cell.id = StringName(name)
			else:
				return {}
			cells.append(cell)
	var r := {"name": str(raw.get("name", ItemCatalog.get_def(out).get("name", out))),
			"w": w, "h": rows.size(), "cells": cells, "output": out,
			"count": maxi(int(raw.get("count", 1)), 1), "keep_contents": bool(raw.get("keep_contents", false))}
	return _trim(r)


## The pattern without empty rows and columns round it.
static func _trim(r: Dictionary) -> Dictionary:
	var lo := Vector2i(r.w, r.h)
	var hi := Vector2i(-1, -1)
	for y in r.h:
		for x in r.w:
			if r.cells[y * r.w + x] != null:
				lo = Vector2i(mini(lo.x, x), mini(lo.y, y))
				hi = Vector2i(maxi(hi.x, x), maxi(hi.y, y))
	if hi.x < 0:
		return {}
	var cells := []
	for y in range(lo.y, hi.y + 1):
		for x in range(lo.x, hi.x + 1):
			cells.append(r.cells[y * r.w + x])
	r.w = hi.x - lo.x + 1
	r.h = hi.y - lo.y + 1
	r.cells = cells
	return r


static func cell_takes(cell: Dictionary, s: ItemStack) -> bool:
	if s == null or s.is_empty() or s.count < int(cell.count):
		return false
	if cell.tag != "":
		return PackedStringArray(ItemCatalog.get_def(s.id).get("tags", [])).has(cell.tag)
	return s.id == cell.id


## The recipe the grid (row-major, GRID x GRID, stacks or null) makes, and
## where its pattern sits: {recipe, at: Vector2i, mirror: bool}; {} if none.
static func find_match(grid: Array) -> Dictionary:
	load_all()
	var lo := Vector2i(GRID, GRID)
	var hi := Vector2i(-1, -1)
	for y in GRID:
		for x in GRID:
			var s = grid[y * GRID + x]
			if s != null and not (s as ItemStack).is_empty():
				lo = Vector2i(mini(lo.x, x), mini(lo.y, y))
				hi = Vector2i(maxi(hi.x, x), maxi(hi.y, y))
	if hi.x < 0:
		return {}
	var w := hi.x - lo.x + 1
	var h := hi.y - lo.y + 1
	for r in _recipes:
		if r.w != w or r.h != h:
			continue
		for mirror in [false, true]:
			if _fits(r, grid, lo, mirror):
				return {"recipe": r, "at": lo, "mirror": mirror}
	return {}


static func _fits(r: Dictionary, grid: Array, at: Vector2i, mirror: bool) -> bool:
	for y in r.h:
		for x in r.w:
			var cell = r.cells[y * r.w + (r.w - 1 - x if mirror else x)]
			var s = grid[(at.y + y) * GRID + at.x + x]
			var empty: bool = s == null or (s as ItemStack).is_empty()
			if cell == null:
				if not empty:
					return false
			elif empty or not cell_takes(cell, s):
				return false
	return true


## The grid index each cell of a match uses, with how many it takes:
## [[index, count], ...] (the cells the pattern fills).
static func uses(m: Dictionary) -> Array:
	var r: Dictionary = m.recipe
	var out := []
	for y in r.h:
		for x in r.w:
			var cell = r.cells[y * r.w + (r.w - 1 - x if m.mirror else x)]
			if cell != null:
				out.append([(m.at.y + y) * GRID + m.at.x + x, int(cell.count)])
	return out


## What a recipe asks for, in words, for the Recipes list: "4 Sand".
static func describe(r: Dictionary) -> String:
	var counts := {}
	var order := []
	for cell in r.cells:
		if cell == null:
			continue
		var k: String = ("any " + cell.tag) if cell.tag != "" else str(ItemCatalog.get_def(cell.id).get("name", cell.id))
		if not counts.has(k):
			order.append(k)
			counts[k] = 0
		counts[k] += int(cell.count)
	var parts := []
	for k in order:
		parts.append("%d %s" % [counts[k], k])
	return " + ".join(parts)
