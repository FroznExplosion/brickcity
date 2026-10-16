class_name AssetGuns
extends RefCounted
## Guns made in the asset workshop (Docs/AssetWorkshop.md, "Into the game"): each one a
## folder of part scenes and a gun.json, in res://guns/<id>/ (shipped) or user://guns/<id>/
## (the player's), written by its Export to game.
##
## Their parts join the game's part library (GunPlaceholderParts.build_library), each kept
## to its own gun with `exclusive_to` -- the same fence that keeps a legendary's barrel out
## of world drops -- so no random gun ever takes one, no roll of any other gun moves, and a
## saved gun of theirs loads back by its part ids. A gun of one is made with `generate`:
## its own parts, everything else (modifiers, alt fire, stats, quality) rolled from the
## seed as for any gun.

const DIRS := ["res://guns/", "user://guns/"]
## The brand on their parts: no skin is set for it, so they keep their bricks' colours.
const BRAND := &"workshop"
## The class a design fires as when its gun.json does not say.
const DEFAULT_CLASS := &"smg"


## Every exported gun: id -> {dir, manifest}. The player's copy wins over a shipped one.
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


static func ids() -> Array[StringName]:
	var out: Array[StringName] = []
	for id in all():
		out.append(id)
	out.sort()
	return out


## What keeps a design's parts to itself.
static func fence(id: StringName) -> StringName:
	return StringName("asset_%s" % id)


## The parts of every exported gun, as part defs.
static func parts() -> Array[GunPartDef]:
	var out: Array[GunPartDef] = []
	var guns := all()
	for id: StringName in guns:
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
			def.id = StringName("asset_%s_%s" % [id, slot_name])
			def.display_name = "%s %s" % [m.get("name", String(id)), slot_name]
			def.slot = slot
			def.scene = scene
			def.manufacturer = BRAND
			def.min_rarity = 1
			def.max_rarity = 6
			def.native_rarity = 2
			def.exclusive_to = fence(id)
			var tags := PackedStringArray(["asset"])
			if slot == GunPartDef.Slot.MAGAZINE:
				tags.append("detaches")   # PlayerView takes it out with the hand on a reload
			def.tags = tags
			if slot == GunPartDef.Slot.BODY:
				def.name_fragment = String(m.get("name", id))
			out.append(def)
	return out


## Put every exported gun's parts on the end of `lib` (once): at the end, so every
## existing part keeps its place and every seed rolls what it did.
static func add_to(lib: GunPartLibrary) -> void:
	var have := {}
	for def in lib.parts:
		if def != null:
			have[def.id] = true
	var added := false
	for def in parts():
		if not have.has(def.id):
			lib.parts.append(def)
			added = true
	if added:
		lib._indexed = false


## A gun of design `id` from `lib` (which add_to has filled), or null if there is no such
## design or it has no body.
static func generate(lib: GunPartLibrary, id: StringName, gen_seed: int, tier: int = 1,
		rarity: int = 3) -> GunGenerator.Result:
	var guns := all()
	if not guns.has(id):
		return null
	add_to(lib)
	var recipe := {}
	for def in lib.parts:
		if def != null and def.exclusive_to == fence(id):
			recipe[def.slot] = def
	if not recipe.has(GunPartDef.Slot.BODY):
		return null
	var m: Dictionary = guns[id].manifest
	var wc := WeaponClass.builtin(StringName(m.get("class", DEFAULT_CLASS)))
	return GunGenerator.generate_fixed(recipe, gen_seed, wc, tier, rarity, String(m.get("name", id)))
