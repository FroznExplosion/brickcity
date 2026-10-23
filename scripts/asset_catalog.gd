class_name AssetCatalog
extends RefCounted

## Every saved piece of furniture and every item (the `item` library), with
## its tags, for the catalogue panel and the placers.
## Docs/AssetWorkshop.md, "Furniture and items".
##
## An asset's id is its file's name, as `RoomTemplates` registers it
## (`item:<id>`); a player's file of the same name as a shipped one replaces it.

static var _entries: Array = []
static var _by_id := {}
static var _recipes := {}
static var _loaded := false
## Read only this folder instead of the item library: a probe's, so nothing it
## saves goes near the player's own items. Kept on Engine, not in a static:
## loading a scene reloads scripts and resets their statics (Godot 4.6).
const ONLY_DIR_META := "asset_catalog_only_dir"


static func only_dir() -> String:
	return str(Engine.get_meta(ONLY_DIR_META, ""))


## Read only `dir` ("" for the item library again), from now on.
static func use_dir(dir: String) -> void:
	Engine.set_meta(ONLY_DIR_META, dir)
	reload()


## Forget what was read, so a piece saved a moment ago is listed.
static func reload() -> void:
	_loaded = false
	_entries.clear()
	_by_id.clear()
	_recipes.clear()


static func _ensure() -> void:
	if _loaded:
		return
	_loaded = true
	var paths: Array = []
	var dir := only_dir()
	if dir == "":
		paths = Array(BuildRecipe.library("item"))
	else:
		for f in DirAccess.get_files_at(dir):
			if f.ends_with(".json"):
				paths.append(dir + f)
	for path: String in paths:
		var r := BuildRecipe.load_from(path)
		if r.is_empty():
			continue
		var id := path.get_file().get_basename()
		var name := r.name if r.name != "" and r.name != "untitled" else id.capitalize()
		var e := {"id": id, "path": path, "name": name, "tags": AssetTags.tags_of(r),
				"shipped": path.begins_with("res://")}
		if _by_id.has(id):
			_entries.erase(_by_id[id])
		_by_id[id] = e
		_entries.append(e)
		_recipes[id] = r


## Every entry: {"id", "path", "name", "tags", "shipped"}.
static func entries() -> Array:
	_ensure()
	return _entries


static func entry(id: String) -> Dictionary:
	_ensure()
	return _by_id.get(id, {})


## The asset's build, as saved (unturned).
static func recipe(id: String) -> BuildRecipe:
	_ensure()
	return _recipes.get(id, null)


## The entries that pass a filter (AssetTags.matches) and whose name holds
## `search` (any case), in name order.
static func find(filter: Dictionary, search := "") -> Array:
	_ensure()
	var s := search.strip_edges().to_lower()
	var out := []
	for e: Dictionary in _entries:
		if s != "" and not (str(e.name).to_lower().contains(s) or str(e.id).contains(s)):
			continue
		if AssetTags.matches(e.tags, filter):
			out.append(e)
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a.name) < str(b.name))
	return out


## How many a filter would leave with this one value of a level chosen alone
## on that level: the count a chip shows.
static func count_with(filter: Dictionary, level_id: String, value: String, search := "") -> int:
	var f := filter.duplicate()
	f[level_id] = [value]
	return find(f, search).size()
