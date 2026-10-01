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

var character := {"name": "Pilot", "level": 1, "max_health": 100.0}
var mech := {"gun": {"class": "lmg", "seed": 1, "tier": 1, "rarity": -1}}
var guns: Array = []
## Mission id -> {"state": "open" | "done" | "failed", "progress": ...}.
var missions := {}
## ThreatProfile.to_dict().
var threat_profile := {}
## Who the enemy's attention went to, on average, last time: pilot and mech
## shares of the side's aggro (AI.md 8: the commander reads its history).
var aggro := {"pilot": 0.5, "mech": 0.5}


func to_dict() -> Dictionary:
	return {"version": VERSION, "character": character, "mech": mech, "guns": guns,
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


## A gun, kept as what makes it: class, seed, tier, and the rarity it was FORCED
## to when it was made (-1: rolled from its seed, as loot is). Its rarity comes
## out of the seed then -- forcing it on the way back would roll a different gun.
static func gun_entry(g: GunInstance, forced_rarity := -1) -> Dictionary:
	return {"class": String(g.weapon_class.id) if g.weapon_class != null else "pistol",
			"seed": g.gun_seed, "tier": g.tier, "rarity": forced_rarity}


## The same gun, made again.
static func make_gun(entry: Dictionary, lib: GunPartLibrary) -> GunInstance:
	return GunInstance.from_result(GunGenerator.generate(lib, int(entry.get("seed", 1)),
			WeaponClass.builtin(StringName(entry.get("class", "pistol"))), int(entry.get("tier", 1)),
			int(entry.get("rarity", -1))))
