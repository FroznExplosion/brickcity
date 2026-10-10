class_name GunAltFire
extends RefCounted
## A gun's alt-fire (Docs/Weapons/COMBAT_DESIGN.md 7.2): part of its personality, like
## its modifiers. At most one; rolled from the gun's seed on a stream of its own, so a
## save or a peer rebuilds it and no other roll moved. Ordnance never carries one.
##
## The player flips the gun into its alt-fire mode by holding reload; the fire button
## then fires the alt-fire once, and the gun is back on its primary (GunController).
##
##   dart     hold fire to charge, release: a slow heavy dart that marks where it sticks;
##            the primary's rounds near the mark bend onto it, and crit if it is a crit spot
##   charge   hold fire to charge, release: a plasma shot that takes a whole shield, for a
##            bite of the magazine. A shield answer, not a damage answer.
##   arc      press: a shock arc, the struck enemy and up to three near it, each slowed;
##            on a cooldown

const DART := &"dart"
const CHARGE := &"charge"
const ARC := &"arc"

## Chance a gun of each colour carries one (white .. mythic).
const CHANCE: Array[float] = [0.10, 0.20, 0.30, 0.45, 0.70, 1.0]

## id -> the gun classes that can roll it, and its pick weight.
const DEFS := {
	DART: {"classes": [&"pistol", &"smg", &"rifle", &"lmg", &"dmr"], "w": 2.0,
			"name": "Tracking dart"},
	CHARGE: {"classes": [&"pistol", &"smg", &"revolver"], "w": 1.0,
			"name": "Plasma charge"},
	ARC: {"classes": [&"pistol", &"shotgun", &"revolver"], "w": 1.0,
			"name": "Shock arc"},
}


## The alt-fire a gun of this seed, colour and class carries, or &"" for none.
static func roll(gun_seed: int, rarity: int, weapon_class: WeaponClass) -> StringName:
	if weapon_class == null or weapon_class.is_ordnance:
		return &""
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([gun_seed, "alt_fire"])
	if rng.randf() >= CHANCE[clampi(rarity - 1, 0, CHANCE.size() - 1)]:
		return &""
	var ids: Array[StringName] = []
	var total := 0.0
	for id: StringName in DEFS:
		if (DEFS[id].classes as Array).has(weapon_class.id):
			ids.append(id)
			total += float(DEFS[id].w)
	if ids.is_empty():
		return &""
	var r := rng.randf() * total
	for id in ids:
		r -= float(DEFS[id].w)
		if r <= 0.0:
			return id
	return ids[ids.size() - 1]


static func display_name(id: StringName) -> String:
	return String(DEFS[id].name) if DEFS.has(id) else ""


## One line for the card.
static func describe(id: StringName) -> String:
	match id:
		DART:
			return "Tracking dart: charge and fire a dart; rounds near it bend onto the mark"
		CHARGE:
			return "Plasma charge: charge and fire to take a whole shield"
		ARC:
			return "Shock arc: arcs through up to 4 enemies and slows them"
	return ""
