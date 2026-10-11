class_name CharacterSave
extends RefCounted
## What a player keeps between encounters (Docs/AI.md A14, 9, 12.3; AIPlan P9):
## Borderlands' save -- the character, their mech, their guns, their missions --
## and the THREAT PROFILE, so the next encounter's commander starts from how this
## player fights (and, decaying, follows them if they change).
##
## Plain JSON, versioned: a field added later reads as its default from an older
## file, and a file from a newer game than this is refused rather than half-read.
## A gun is kept as what made it -- class, seed, tier, rarity -- and made again
## the same by GunGenerator, not as its stats.

const VERSION := 1
const PATH := "user://character.json"

var character := {"name": "Pilot", "level": 1, "max_health": 100.0, "xp": 0, "skills": {},
		"scrap": 0, "story_tier": 1}
var mech := {"gun": {"class": "lmg", "seed": 1, "tier": 1, "rarity": -1}}
var guns: Array = []
## The player's kit (PlayerArsenal), as `loadout_dict` keeps it: the four slots, the
## ordnance and the backpack, each gun a `gun_entry`. Empty: no kit yet, the starting one.
var loadout := {}
## Mission id -> {"state": "open" | "done" | "failed", "progress": ...}.
var missions := {}
## ThreatProfile.to_dict().
var threat_profile := {}
## Who the enemy's attention went to, on average, last time: pilot and mech
## shares of the side's aggro (AI.md 8: the commander reads its history).
var aggro := {"pilot": 0.5, "mech": 0.5}


func to_dict() -> Dictionary:
	return {"version": VERSION, "character": character, "mech": mech, "guns": guns, "loadout": loadout,
			"missions": missions, "threat_profile": threat_profile, "aggro": aggro}


static func from_dict(d: Dictionary) -> CharacterSave:
	var s := CharacterSave.new()
	if int(d.get("version", 0)) > VERSION:
		push_warning("CharacterSave: version %d is newer than this game's %d -- not read"
				% [int(d.get("version", 0)), VERSION])
		return s
	s.character.merge(d.get("character", {}), true)
	s.mech.merge(d.get("mech", {}), true)
	s.guns = (d.get("guns", []) as Array).duplicate(true)
	s.loadout = (d.get("loadout", {}) as Dictionary).duplicate(true)
	s.missions = (d.get("missions", {}) as Dictionary).duplicate(true)
	s.threat_profile = (d.get("threat_profile", {}) as Dictionary).duplicate(true)
	s.aggro.merge(d.get("aggro", {}), true)
	return s


func save(path := PATH) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("CharacterSave: cannot write %s" % path)
		return false
	f.store_string(JSON.stringify(to_dict(), "\t"))
	return true


## The save at `path`, or a new character if there is none (or it is unreadable).
static func load_from(path := PATH) -> CharacterSave:
	if not FileAccess.file_exists(path):
		return CharacterSave.new()
	var text := FileAccess.get_file_as_string(path)
	var d = JSON.parse_string(text)
	if not d is Dictionary:
		push_warning("CharacterSave: %s is not a save -- a new character" % path)
		return CharacterSave.new()
	return from_dict(d)


## The player's level, XP and skill tree, as saved (PlayerLevel.to_dict's shape).
func progress_dict() -> Dictionary:
	return {"level": character.get("level", 1), "xp": character.get("xp", 0),
			"skills": character.get("skills", {}), "scrap": character.get("scrap", 0),
			"story_tier": character.get("story_tier", 1)}


## Keep `p`'s level, XP and skills.
func take_progress(p: PlayerLevel) -> void:
	var d := p.to_dict()
	character["level"] = d.level
	character["xp"] = d.xp
	character["skills"] = d.skills
	character["scrap"] = d.scrap
	character["story_tier"] = d.story_tier


## The profile the next encounter's commander starts from.
func profile() -> ThreatProfile:
	return ThreatProfile.from_dict(threat_profile)


## An encounter is over: keep how the player fought, and who the enemy went for.
func take_encounter(commander: Commander, table: AggroTable, player := 0) -> void:
	threat_profile = commander.profile.to_dict()
	if table == null:
		return
	var pilot := 0.0
	var mech_share := 0.0
	for id in table.entries:
		var e: AggroTable.Entry = table.entries[id]
		if e.player != player or not is_instance_valid(e.who):
			continue
		if e.kind == "mech":
			mech_share += table.share(e.who)
		else:
			pilot += table.share(e.who)
	var total := pilot + mech_share
	if total > 0.0:
		aggro = {"pilot": pilot / total, "mech": mech_share / total}


## A gun, kept as what makes it: class, seed, tier, the rarity it was FORCED to when it
## was made (-1: rolled from its seed, as most loot is -- forcing it on the way back would
## roll a different gun), the luck its parts rolled with, and the legendary it is, if one.
## Its parts' ids ride along as a check: if the part library has changed under the save,
## `make_gun` builds those parts instead of what the seed now rolls. Infused, its tier is
## the tier it was lifted to (Infusion): made again there, it is the same gun.
static func gun_entry(g: GunInstance, forced_rarity := -1) -> Dictionary:
	var res := g.result
	var e := {"class": String(g.weapon_class.id) if g.weapon_class != null else "pistol",
			"seed": g.gun_seed, "tier": g.tier,
			"rarity": res.forced_rarity if res != null and res.forced_rarity > 0 else forced_rarity}
	if res != null:
		e["luck"] = res.luck
		if res.legendary_id != &"":
			e["legendary"] = String(res.legendary_id)
		var parts := {}
		for slot: int in res.recipe:
			parts[str(slot)] = String((res.recipe[slot] as GunPartDef).id)
		e["parts"] = parts
	return e


## The same gun, made again.
static func make_gun(entry: Dictionary, lib: GunPartLibrary) -> GunInstance:
	return GunInstance.from_result(make_result(entry, lib))


static func make_result(entry: Dictionary, lib: GunPartLibrary) -> GunGenerator.Result:
	var gen_seed := int(entry.get("seed", 1))
	var tier := clampi(int(entry.get("tier", 1)), 1, Tier.COUNT)
	var luck := float(entry.get("luck", 1.0))
	var leg := LegendaryTable.get_def(StringName(entry.get("legendary", "")))
	var res: GunGenerator.Result
	if leg != null:
		res = GunGenerator.generate_legendary(lib, gen_seed, leg, tier, luck)
	else:
		res = GunGenerator.generate(lib, gen_seed,
				WeaponClass.builtin(StringName(entry.get("class", "pistol"))), tier,
				int(entry.get("rarity", -1)), luck)
	var parts: Dictionary = entry.get("parts", {})
	if parts.is_empty() or leg != null:
		return res
	for slot: int in res.recipe:
		if String(parts.get(str(slot), "")) != String((res.recipe[slot] as GunPartDef).id):
			return _from_parts(entry, lib, res)
	if parts.size() != res.recipe.size():
		return _from_parts(entry, lib, res)
	return res


## The seed no longer rolls the saved parts (the library changed): the saved parts, put
## together again (GunGenerator.deserialize), at the rarity the seed made.
static func _from_parts(entry: Dictionary, lib: GunPartLibrary,
		rolled: GunGenerator.Result) -> GunGenerator.Result:
	var ids := {}
	for k in (entry.get("parts", {}) as Dictionary):
		ids[int(k)] = StringName(entry.parts[k])
	var data := {"seed": rolled.seed, "rarity": rolled.rarity, "tier": rolled.tier,
			"class": rolled.weapon_class.id, "parts": ids, "luck": rolled.luck}
	var res := GunGenerator.deserialize(lib, data)
	if not res.recipe.has(GunPartDef.Slot.BODY):
		return rolled
	res.forced_rarity = rolled.forced_rarity
	return res


## A Loadout of GunInstances, as a save keeps it.
static func loadout_dict(lo: Loadout) -> Dictionary:
	var slots := []
	for g in lo.slots:
		slots.append(gun_entry(g) if g != null else null)
	var pack := []
	for g in lo.backpack:
		pack.append(gun_entry(g))
	return {"slots": slots, "ordnance": gun_entry(lo.ordnance) if lo.ordnance != null else null,
			"backpack": pack, "backpack_size": lo.backpack_size, "group": lo.group,
			"hand": lo.hand.duplicate()}


## The kit `d` into the empty Loadout `lo`, every gun made again. A tried floor gun was
## never the player's, so it is not kept.
static func fill_loadout(lo: Loadout, d: Dictionary, lib: GunPartLibrary) -> void:
	var slots: Array = d.get("slots", [])
	for i in mini(slots.size(), Loadout.SLOTS):
		if slots[i] is Dictionary:
			lo.slots[i] = make_gun(slots[i], lib)
	if d.get("ordnance") is Dictionary:
		lo.ordnance = make_gun(d.ordnance, lib)
	lo.backpack_size = maxi(int(d.get("backpack_size", Loadout.BACKPACK_START)), Loadout.BACKPACK_START)
	for e in d.get("backpack", []):
		if e is Dictionary and lo.backpack.size() < lo.backpack_size:
			lo.backpack.append(make_gun(e, lib))
	var hand: Array = d.get("hand", [0, 0])
	if hand.size() == 2:
		lo.hand = [clampi(int(hand[0]), 0, 1), clampi(int(hand[1]), 0, 1)]
	lo.group = clampi(int(d.get("group", 0)), 0, 1)
	lo._settle()
