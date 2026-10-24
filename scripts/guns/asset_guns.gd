class_name AssetGuns
extends RefCounted
## Guns made in the asset workshop (Docs/AssetWorkshop.md, "Into the game";
## Docs/ModularParts.md section 7). Two forms:
##
##   parts    the workshop's Save writes every part on its own, a part.json and part.scn
##            in its folder (PartCatalog: res://parts/ shipped, user://parts/custom/ the
##            player's). Parts saved from one build share its name (`from`): a design.
##   folders  older: Export to game wrote a folder of part scenes and a gun.json, in
##            res://guns/<id>/ or user://guns/<id>/. Still read; a design saved as parts
##            wins over a folder of the same name.
##
## Their parts join the game's part library (GunPlaceholderParts.build_library), each kept
## to its own design with `exclusive_to` -- the same fence that keeps a legendary's barrel
## out of world drops -- so no random gun ever takes one, no roll of any other gun moves,
## and a saved gun of theirs loads back by its part ids. A gun of one is made with
## `generate`: its own parts, if they fit (GunPartDef.takes), everything else (modifiers,
## alt fire, stats, quality) rolled from the seed as for any gun.

const DIRS := ["res://guns/", "user://guns/"]
## The brand on their parts: no skin is set for it, so they keep their bricks' colours.
const BRAND := &"workshop"
## The class a design fires as when its gun.json does not say.
const DEFAULT_CLASS := &"smg"
## A saved part's game scene, beside its part.json.
const PART_SCENE := "part.scn"


## Every exported gun folder: id -> {dir, manifest}. The player's copy wins over a shipped one.
static func all() -> Dictionary:
	var out := {}
	for base: String in DIRS:
		if not DirAccess.dir_exists_absolute(base):
			continue
		for d in DirAccess.get_directories_at(base):
			var path := base + d + "/gun.json"
			if not FileAccess.file_exists(path):
				continue
			var m = JSON.parse_string(FileAccess.get_file_as_string(path))
			if typeof(m) != TYPE_DICTIONARY:
				continue
			out[StringName(d)] = {"dir": base + d + "/", "manifest": m}
	return out


## Every design saved as parts: id -> {name, class, parts: {slot name: PartRecord}}. Held
## guns only (a mech's gun is not a player's); a part needs its scene beside it.
static func designs(cat: PartCatalog = null, scale: String = "held") -> Dictionary:
	if cat == null:
		cat = PartCatalog.load_all()
	var out := {}
	for r in cat.filter({"family": ["gun"], "scale": [scale]}):
		var from := String(r.extra.get("from", ""))
		if from == "" or not GunPartDef.SLOT_BY_SUFFIX.has(r.slot) \
				or not FileAccess.file_exists(r.dir + PART_SCENE):
			continue
		var id := StringName(slug(from))
		var d: Dictionary = out.get_or_add(id, {"name": from, "class": DEFAULT_CLASS, "parts": {}})
		d.parts[r.slot] = r
		if r.slot == "body" and r.weapon_class != "":
			d["class"] = StringName(r.weapon_class)
	return out


## A file name from a build's name, as the workshop makes one (Workshop.slug).
static func slug(n: String) -> String:
	var s := n.strip_edges().to_lower().replace(" ", "_").validate_filename()
	return s if s != "" else "build"


static func ids() -> Array[StringName]:
	var seen := {}
	for id in all():
		seen[id] = true
	for id in designs():
		seen[id] = true
	var out: Array[StringName] = []
	for id in seen:
		out.append(id)
	out.sort()
	return out


## What keeps a design's parts to itself.
static func fence(id: StringName, scale: String = "held") -> StringName:
	return StringName("asset_%s" % id) if scale == "held" else StringName("asset_mech_%s" % id)


## The parts of every design, as part defs. `cat`: the catalogue to read designs from
## (default: every part folder).
static func parts(cat: PartCatalog = null, scale: String = "held") -> Array[GunPartDef]:
	var out: Array[GunPartDef] = []
	var saved := designs(cat, scale)
	for id: StringName in saved:
		for slot_name: String in saved[id].parts:
			var r: PartRecord = saved[id].parts[slot_name]
			var scene := load(r.dir + PART_SCENE) as PackedScene
			if scene == null:
				continue
			var def := _def(GunPartDef.SLOT_BY_SUFFIX[slot_name])
			def.id = StringName(r.id)
			def.display_name = r.display_name
			def.scene = scene
			def.exclusive_to = fence(id, scale)
			def.tags = r.tags
			def.mount_interface = StringName(r.interface())
			for s: Dictionary in r.sockets:
				var acc := PackedStringArray(s.get("accepts", []))
				if not acc.is_empty():
					def.socket_accepts[String(s.name)] = acc
			if slot_name == "body":
				def.name_fragment = r.name_fragment if r.name_fragment != "" else String(saved[id].name)
			out.append(def)
	if scale != "held":
		return out   # the old folders are all players' guns
	var guns := all()
	for id: StringName in guns:
		if saved.has(id):
			continue   # saved as parts since: those win
		var dir: String = guns[id].dir
		var m: Dictionary = guns[id].manifest
		for slot_name: String in (m.get("parts", {}) as Dictionary):
			if not GunPartDef.SLOT_BY_SUFFIX.has(slot_name):
				continue
			# Beside gun.json, wherever the folder now is (the manifest's paths are where
			# it was written).
			var scene := load(dir + slot_name + ".scn") as PackedScene
			if scene == null:
				continue
			var slot: GunPartDef.Slot = GunPartDef.SLOT_BY_SUFFIX[slot_name]
			var def := _def(slot)
			def.id = StringName("asset_%s_%s" % [id, slot_name])
			def.display_name = "%s %s" % [m.get("name", String(id)), slot_name]
			def.scene = scene
			def.exclusive_to = fence(id)
			var tags := PackedStringArray(["asset"])
			if slot == GunPartDef.Slot.MAGAZINE:
				tags.append("detaches")   # PlayerView takes it out with the hand on a reload
			def.tags = tags
			if slot == GunPartDef.Slot.BODY:
				def.name_fragment = String(m.get("name", id))
			out.append(def)
	return out


## A blank def of the right kind for a slot, with what every workshop part shares.
static func _def(slot: GunPartDef.Slot) -> GunPartDef:
	var def: GunPartDef
	match slot:
		GunPartDef.Slot.BODY:
			def = GunReceiverDef.new()
		GunPartDef.Slot.BARREL:
			var barrel := GunBarrelDef.new()
			barrel.element_ratio = 0.0
			barrel.barrel_family = &"kinetic"
			def = barrel
		_:
			def = GunPartDef.new()
	def.slot = slot
	def.manufacturer = BRAND
	def.min_rarity = 1
	def.max_rarity = 6
	def.native_rarity = 2
	return def


## Put every design's parts on the end of `lib` (once): at the end, so every existing
## part keeps its place and every seed rolls what it did.
static func add_to(lib: GunPartLibrary, cat: PartCatalog = null, scale: String = "held") -> void:
	var have := {}
	for def in lib.parts:
		if def != null:
			have[def.id] = true
	var added := false
	for def in parts(cat, scale):
		if not have.has(def.id):
			lib.parts.append(def)
			added = true
	if added:
		lib._indexed = false


## Why design `id`'s parts in `lib` do not make a gun ("" when they do): no body, or a
## part that does not fit what it hangs from.
static func why_not(lib: GunPartLibrary, id: StringName, scale: String = "held") -> String:
	var recipe := _recipe(lib, id, scale)
	if not recipe.has(GunPartDef.Slot.BODY):
		return "no body"
	for slot: GunPartDef.Slot in recipe:
		if slot != GunPartDef.Slot.BODY and not GunPartDef.fits_recipe(recipe[slot], recipe):
			return "%s does not fit" % (recipe[slot] as GunPartDef).id
	return ""


static func _recipe(lib: GunPartLibrary, id: StringName, scale: String = "held") -> Dictionary:
	var recipe := {}
	for def in lib.parts:
		if def != null and def.exclusive_to == fence(id, scale):
			recipe[def.slot] = def
	return recipe


## A gun of design `id` from `lib` (which add_to fills), or null if there is no such
## design or its parts do not make a gun (why_not says why).
static func generate(lib: GunPartLibrary, id: StringName, gen_seed: int, tier: int = 1,
		rarity: int = 3, cat: PartCatalog = null, scale: String = "held") -> GunGenerator.Result:
	if cat == null:
		cat = PartCatalog.load_all()
	add_to(lib, cat, scale)
	var why := why_not(lib, id, scale)
	if why != "":
		print("[asset guns] '%s' makes no gun: %s" % [id, why])
		return null
	var saved := designs(cat, scale)
	var wc_id: StringName = DEFAULT_CLASS
	var display := String(id)
	if saved.has(id):
		wc_id = saved[id]["class"]
		display = saved[id].name
	else:
		var guns := all()
		if not guns.has(id):
			return null
		var m: Dictionary = guns[id].manifest
		wc_id = StringName(m.get("class", DEFAULT_CLASS))
		display = String(m.get("name", id))
	return GunGenerator.generate_fixed(_recipe(lib, id, scale), gen_seed, WeaponClass.builtin(wc_id),
			tier, rarity, display)
