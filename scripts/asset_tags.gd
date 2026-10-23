class_name AssetTags
extends RefCounted

## The tags furniture and items carry, and the filter that picks them.
## Docs/AssetWorkshop.md, "Furniture and items".
##
## The levels come from `data/asset_tags.json` (planet, then type, then room
## today), so a new level or value is a line there: the save dialog, the
## catalogue and the generator read them from here.
##
## An asset's tags live in its recipe, `meta.tags`: level id -> [value ids].
## Every level is a list, single-choice ones too, so a level can turn
## multi-choice without touching a file. An empty list on a level that has an
## `any` label means every value (a chair for any room, a crate for every
## planet).

const FILE := "res://data/asset_tags.json"

## The types (level "type"). Furniture is Role.INTERIOR: seen from far, through
## windows. An item is Role.DETAIL: seen only up close.
const FURNITURE := "furniture"
const ITEM := "item"

static var _levels: Array = []


## The levels, in filter order: [{"id", "label", "multi", "any", "values":
## [{"id", "label"}]}]. "any" is "" where a level has to be chosen.
static func levels() -> Array:
	if _levels.is_empty():
		_load()
	return _levels


static func level(id: String) -> Dictionary:
	for l: Dictionary in levels():
		if l.id == id:
			return l
	return {}


static func _load() -> void:
	var data = JSON.parse_string(FileAccess.get_file_as_string(FILE))
	if not data is Dictionary:
		push_error("AssetTags: cannot read %s" % FILE)
		return
	for raw: Dictionary in (data.get("levels", []) as Array):
		var values := []
		if str(raw.get("values_from", "")) == "room_kinds":
			for k in Room.KINDS:
				if k != "empty":
					values.append({"id": k, "label": k.capitalize()})
		for v: Dictionary in (raw.get("values", []) as Array):
			values.append({"id": str(v.id), "label": str(v.get("label", v.id))})
		_levels.append({"id": str(raw.id), "label": str(raw.get("label", raw.id)),
				"multi": bool(raw.get("multi", false)), "any": str(raw.get("any", "")),
				"values": values})


## A recipe's tags, every level present. A file saved before tags had a
## room_kind or room_kinds, and no type: its room comes from those and its
## type from its bricks (all Detail is an item).
static func tags_of(r: BuildRecipe) -> Dictionary:
	var saved: Dictionary = r.meta.get("tags", {})
	var out := {}
	for l: Dictionary in levels():
		out[l.id] = (saved.get(l.id, []) as Array).duplicate()
	if not r.meta.has("tags"):
		if r.meta.has("room_kinds"):
			out["room"] = (r.meta.room_kinds as Array).duplicate()
		elif r.meta.has("room_kind"):
			out["room"] = [str(r.meta.room_kind)]
	if (out.get("type", []) as Array).is_empty():
		out["type"] = [type_from_bricks(r)]
	return out


## Furniture unless every brick is Detail.
static func type_from_bricks(r: BuildRecipe) -> String:
	for i in r.size():
		if r.role_of(i) != BuildRecipe.Role.DETAIL:
			return FURNITURE
	return ITEM if r.size() > 0 else FURNITURE


static func type_of(tags: Dictionary) -> String:
	var t: Array = tags.get("type", [])
	return str(t[0]) if not t.is_empty() else FURNITURE


## Whether an asset with these tags passes a filter (level id -> [value ids]).
## Levels AND, values within a level OR; a level the filter leaves empty passes
## everything, and so does a level the asset leaves empty if that level has an
## `any`.
static func matches(tags: Dictionary, filter: Dictionary) -> bool:
	for id in filter:
		var want: Array = filter[id]
		if want.is_empty():
			continue
		var has: Array = tags.get(id, [])
		if has.is_empty():
			if str(level(id).get("any", "")) != "":
				continue
			return false
		var hit := false
		for v in want:
			if has.has(v):
				hit = true
				break
		if not hit:
			return false
	return true


## Clean tags for saving: only known levels and values, single-choice levels
## cut to one, and a type always set.
static func clean(tags: Dictionary) -> Dictionary:
	var out := {}
	for l: Dictionary in levels():
		var known := []
		for v: Dictionary in (l.values as Array):
			known.append(v.id)
		var keep := []
		for v in (tags.get(l.id, []) as Array):
			if known.has(str(v)) and not keep.has(str(v)):
				keep.append(str(v))
		if not l.multi and keep.size() > 1:
			keep = [keep[0]]
		out[l.id] = keep
	if (out.get("type", []) as Array).is_empty():
		out["type"] = [FURNITURE]
	return out
