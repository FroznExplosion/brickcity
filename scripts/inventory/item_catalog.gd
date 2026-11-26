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

const KINDS := ["block", "fluid", "bucket", "source_bucket", "chest", "station", "tool", "backpack", "gun", "grenade",
		"hoe", "seed", "scythe", "can", "fertiliser", "wire", "device", "wrench", "misc"]
## Which hand an item may be in (zylanntest's HandUse).
const HANDS := ["any", "right", "off", "two"]
## The gun classes held in one hand (PlayerView.ONE_HAND draws them so).
const ONE_HANDED_GUNS: Array[StringName] = [&"pistol", &"revolver"]
## Tilled soil is made with a hoe, never laid; breaking it gives soil
## (FARMLAND_GIVES, Docs/MineFarming.md).
const NOT_ITEMS := ["air", "bedrock", "farmland", "wet farmland"]
const FARMLAND_GIVES := &"soil"
## brick_terrain.h MAT_FIL_BASE: the building materials start here.
const BUILDING_MATERIAL_BASE := 64
## A bucket holds this many tiles of water: 3 bricks (Docs/MineWater.md 10).
const BUCKET_TILES := 9

static var _items := {}
static var _order: Array[StringName] = []
static var _by_material := {}
## A block item folded into a material family (Docs/Inventory.md 11):
## old id -> the family's (a save from before is moved onto it).
static var _folded := {}
## A block's count is in plate cells (a 1x1 plate is 1, a 2x4 brick 24):
## what one stack of a material may hold.
const BLOCK_STACK := 999


static func load_all(force := false) -> void:
	if not _items.is_empty() and not force:
		return
	_items.clear()
	_order.clear()
	_by_material.clear()
	_folded.clear()
	var names: PackedStringArray = BrickTerrain.material_names()
	for m in names.size():
		if NOT_ITEMS.has(names[m]):
			continue
		var id := block_id_for(names[m])
		# A block may be laid from the off-hand too (round four).
		_add({"id": id, "name": names[m].capitalize(), "kind": "block", "material": m,
				"hand": "any", "max_stack": BLOCK_STACK,
				"colour": BrickWorld.get_filament_colour(BrickTerrain.material_filament_index(m))})
	# A gun item a weapon class (Docs/Inventory.md 10): the stack's data is the
	# gun itself (CharacterSave.gun_entry), so one item covers every roll.
	# One-handed guns (ONE_HANDED_GUNS) may go in the off-hand; every other
	# class is two-handed and lowers the off-hand while held (round four).
	for cid in WeaponClass.gun_ids():
		var one := ONE_HANDED_GUNS.has(StringName(cid))
		_add({"id": gun_id(StringName(cid)), "name": String(cid).capitalize(), "kind": "gun", "max_stack": 1,
				"hand": "any" if one else "two", "colour": Color(0.62, 0.64, 0.7), "glyph": "G",
				"description": ("A one-handed gun. In the hand: LMB fires, RMB aims, R reloads. In the off-hand, up (C): RMB fires it."
						if one else "A two-handed gun: the off-hand goes down while it is held. LMB fires, RMB aims, R reloads.")})
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
	# PLASTIC BRICKS (Docs/TerrainBuildings.md 4c): one material for every
	# building colour (brick_terrain.h MAT_FIL_BASE + a filament), so a brick
	# mined out of a stamped building is one of these, in its colour, and
	# lays that colour again.
	if not _items.has(&"plastic_bricks"):
		var cols := PackedInt32Array()
		for f in BrickWorld.get_filament_count():
			cols.append(BUILDING_MATERIAL_BASE + f)
		_add({"id": &"plastic_bricks", "name": "Plastic bricks", "kind": "block", "hand": "right",
				"colours": cols, "max_stack": BLOCK_STACK,
				"description": "Bricks out of a building, any colour."})
	_fold_families(names)


## MATERIALS (Docs/Inventory.md 11): a block item with `colours` (a pack's
## table: "soil": {"colours": ["grass", "dirt", ...]}) is a material that
## lays any of those terrain colours. The colours' own block items fold into
## it: breaking any of them gives the material, and a save that held one gets
## the material instead (`folded_into`).
static func _fold_families(names: PackedStringArray) -> void:
	for id in _order.duplicate():
		var e: Dictionary = _items.get(id, {})
		if e.is_empty() or e.kind != "block" or not bool(e.get("family", false)):
			continue
		for m in e.colours:
			_by_material[int(m)] = id
			if int(m) >= names.size():
				continue   # a building colour: no block item of its own
			var other := block_id_for(names[int(m)])
			if other != id and _items.has(other) and not bool(_items[other].get("family", false)):
				_items.erase(other)
				_order.erase(other)
				_folded[other] = id


## The material an old block id was folded into, or &"".
static func folded_into(id: StringName) -> StringName:
	load_all()
	return _folded.get(id, &"")


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
		## A material's terrain colours (indices), the first its own; a family
		## names them (Docs/Inventory.md 11).
		"colours": PackedInt32Array(),
		"family": e.has("colours") or bool(e.get("family", false)),
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
	if out.kind == "block":
		var names := Array(BrickTerrain.material_names())
		var cols := PackedInt32Array()
		var given = e.get("colours", [])
		for c2 in (given if (given is Array or given is PackedStringArray or given is PackedInt32Array) else []):
			var i: int = c2 if (c2 is int) else names.find(str(c2))
			if i > 0 and not cols.has(i):
				cols.append(i)
		if cols.is_empty() and out.material > 0:
			cols.append(out.material)
		out["colours"] = cols
		if out.material <= 0 and not cols.is_empty():
			out.material = cols[0]
		if not e.has("colour") and out.material > 0:
			out["colour"] = BrickWorld.get_filament_colour(BrickTerrain.material_filament_index(out.material))
		if not e.has("max_stack"):
			out.max_stack = BLOCK_STACK
	# A tool's own numbers (the Mega Pickaxe): how much one break clears and
	# how often it repeats while held (MineBuilder._break_cells/_break_repeat).
	# A seed's crop (Docs/MineFarming.md): what it grows into.
	# A fertiliser's fertility and boost (Docs/MineFarming.md 17).
	# A furnace smelts (`smelter`, Docs/Inventory.md 15).
	for k in ["break_area", "break_repeat", "model", "crop", "fertility", "boost_days", "mulch", "smelter"]:
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
	if m == BrickTerrain.MAT_FARMLAND or m == BrickTerrain.MAT_WET_FARMLAND:
		return FARMLAND_GIVES
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
		"can":
			return "%s %d/%d" % [n, int(s.data.get("water", 0)), MineFarming.CAN_WATER]
		"seed":
			# A seed's traits (Docs/MineFarming.md 20): growth, yield, hardiness.
			if s.data.has("g") or s.data.has("y") or s.data.has("h"):
				return "%s (G%d Y%d H%d)" % [n, int(s.data.get("g", 0)), int(s.data.get("y", 0)), int(s.data.get("h", 0))]
	return n
