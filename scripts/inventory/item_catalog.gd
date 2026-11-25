class_name ItemCatalog
extends RefCounted
## Every item there is (Docs/Inventory.md 3.1). Two sources:
##   - the terrain: each BrickTerrain material but air and bedrock is a block
##     item, id = its name with `_` for spaces ("dark_stone");
##   - packs: `content/<pack>/data/items/*.json` (ContentPacks), so a mod adds
##     items by shipping a table. A table entry with a block's id only changes
##     the fields it names.
##
## An item is a Dictionary with every field filled in (`_complete`):
##   id, name, kind, max_stack, hand, colour, glyph, tags, description,
##   material (block: BrickTerrain material index, else -1),
##   fluid (1 water, 2 lava, 0 none), fluid_kind ("source" / "still").

const KINDS := ["block", "fluid", "bucket", "source_bucket", "chest", "tool", "backpack", "gun", "misc"]
## Which hand an item may be in (zylanntest's HandUse).
const HANDS := ["any", "right", "off", "two"]
const NOT_ITEMS := ["air", "bedrock"]
## A bucket holds this many tiles of water: 3 bricks (Docs/MineWater.md 10).
const BUCKET_TILES := 9

static var _items := {}
static var _order: Array[StringName] = []
static var _by_material := {}


static func load_all(force := false) -> void:
	if not _items.is_empty() and not force:
		return
	_items.clear()
	_order.clear()
	_by_material.clear()
	var names: PackedStringArray = BrickTerrain.material_names()
	for m in names.size():
		if NOT_ITEMS.has(names[m]):
			continue
		var id := block_id_for(names[m])
		_add({"id": id, "name": names[m].capitalize(), "kind": "block", "material": m,
				"hand": "right",
				"colour": BrickWorld.get_filament_colour(BrickTerrain.material_filament_index(m))})
	# A gun item a weapon class (Docs/Inventory.md 10): the stack's data is the
	# gun itself (CharacterSave.gun_entry), so one item covers every roll.
	for cid in WeaponClass.gun_ids():
		_add({"id": gun_id(StringName(cid)), "name": String(cid).capitalize(), "kind": "gun", "max_stack": 1,
				"hand": "right", "colour": Color(0.62, 0.64, 0.7), "glyph": "G",
				"description": "A gun. In the hand: LMB fires, RMB aims, R reloads."})
	for path in ContentPacks.files("data/items"):
		var f := FileAccess.open(path, FileAccess.READ)
		if f == null:
			continue
		var parsed = JSON.parse_string(f.get_as_text())
		if not (parsed is Dictionary) or not (parsed.get("items") is Dictionary):
			push_warning("[items] %s: no \"items\" table" % path)
			continue
		for k in parsed.items:
			var raw = parsed.items[k]
			if raw is Dictionary:
				var e: Dictionary = raw.duplicate(true)
				e["id"] = StringName(k)
				_add(e)


static func gun_id(class_id: StringName) -> StringName:
	return StringName("gun_%s" % class_id)


static func block_id_for(material_name: String) -> StringName:
	return StringName(material_name.to_lower().replace(" ", "_"))


static func _add(raw: Dictionary) -> void:
	var id: StringName = raw.id
	var base: Dictionary = _items.get(id, {})
	var e := base.duplicate(true)
	for k in raw:
		e[k] = raw[k]
	e = _complete(e)
	if not _items.has(id):
		_order.append(id)
	_items[id] = e
	if e.kind == "block" and int(e.material) >= 0:
		_by_material[int(e.material)] = id


static func _complete(e: Dictionary) -> Dictionary:
	var out := {
		"id": e.id,
		"name": str(e.get("name", String(e.id).capitalize())),
		"kind": str(e.get("kind", "misc")),
		"max_stack": maxi(int(e.get("max_stack", 64)), 1),
		"hand": str(e.get("hand", "any")),
		"glyph": str(e.get("glyph", "")),
		"tags": PackedStringArray(e.get("tags", [])),
		"description": str(e.get("description", "")),
		"material": -1,
		"fluid": int(e.get("fluid", 0)),
		"fluid_kind": str(e.get("fluid_kind", "source")),
		## A backpack's storage slots (Docs/Inventory.md 8).
		"slots": int(e.get("slots", 0)),
	}
	if not KINDS.has(out.kind):
		out.kind = "misc"
	if not HANDS.has(out.hand):
		out.hand = "any"
	var c = e.get("colour", Color(0.8, 0.8, 0.8))
	out["colour"] = c if c is Color else Color.html(str(c))
	var m = e.get("material", -1)
	if m is String:
		m = Array(BrickTerrain.material_names()).find(m)
	out["material"] = int(m)
	# A tool's own numbers (the Mega Pickaxe): how much one break clears and
	# how often it repeats while held (MineBuilder._break_cells/_break_repeat).
	for k in ["break_area", "break_repeat"]:
		if e.has(k):
			out[k] = e[k]
	return out


static func has(id: StringName) -> bool:
	load_all()
	return _items.has(id)


## The item, or {} if there is none by that id.
static func get_def(id: StringName) -> Dictionary:
	load_all()
	return _items.get(id, {})


static func ids() -> Array[StringName]:
	load_all()
	return _order


static func max_stack(id: StringName) -> int:
	return int(get_def(id).get("max_stack", 64))


static func kind(id: StringName) -> String:
	return str(get_def(id).get("kind", ""))


## The block item that places terrain material `m`, or &"".
static func block_item(m: int) -> StringName:
	load_all()
	return _by_material.get(m, &"")


## What a stack is called on the HUD: its name, and a bucket what it holds.
static func label(s: ItemStack) -> String:
	if s == null:
		return "empty hand"
	var d := get_def(s.id)
	var n: String = d.get("name", String(s.id))
	match d.get("kind", ""):
		"gun":
			return str(s.data.get("name", n))
		"bucket":
			return "%s %d/%d tiles" % [n, int(s.data.get("tiles", 0)), BUCKET_TILES]
		"source_bucket":
			return "%s (%s)" % [n, ["empty", "water", "lava"][clampi(int(s.data.get("fluid", 0)), 0, 2)]]
	return n
