class_name LegendaryTable
extends RefCounted
## The authored legendaries and which sources drop them (QUALITY_NAMING §4.6).
##
## Static presets are the shipping source of truth, same pattern as WeaponClass._PRESETS.
## Move to .tres when a designer needs to edit them without a rebuild.
##
## Dedicated chances are AUTHORED constants: level luck and the over-level bonus bias the
## WORLD table only (§4.5.2/§4.5.3). A boss's own gun should not get commoner because the
## player out-levelled the boss — that would turn the chase into a farm.

const _PRESETS := {
	&"boilerplate": {
		"name": "Boilerplate", "class": &"lmg", "effect": &"heat_ramp",
		# Slower to start, and the effect is what pays it back. Product 0.80*1.25 = 1.0,
		# so it sits exactly on the DPS budget and its score stays honest.
		"sig": {&"damage": 1.25, &"fire_rate": 0.80, &"mag_size": 1.6},
		"flavor": "Give it a minute.",
	},
	&"sermon": {
		"name": "Sermon", "class": &"sniper", "effect": &"kill_refund",
		"sig": {&"damage": 1.30, &"fire_rate": 0.77, &"mag_size": 0.6, &"crit_mult": 1.25},
		"flavor": "Every word lands twice.",
	},
	&"landlord": {
		"name": "Landlord", "class": &"shotgun", "effect": &"pellet_return",
		"sig": {&"damage": 0.72, &"fire_rate": 1.39, &"accuracy": 0.85},
		"flavor": "It always comes back around.",
	},
	&"hangnail": {
		"name": "Hangnail", "class": &"pistol", "effect": &"crit_bleed",
		"sig": {&"damage": 0.85, &"fire_rate": 1.18, &"crit_mult": 1.4},
		"flavor": "Small. Persistent. Yours now.",
	},
	&"dinner_bell": {
		"name": "Dinner Bell", "class": &"smg", "effect": &"reload_throw",
		"sig": {&"damage": 1.15, &"fire_rate": 0.87, &"reload_time": 1.35},
		"flavor": "Come and get it.",
	},
}

## source_id -> [{legendary id, chance}]. Chances are per-kill and INDEPENDENT of the
## world roll: a boss can drop its dedicated gun AND a world legendary in the same kill,
## which is how BL2 behaves (§4.6).
const SOURCES := {
	&"boss":   [
		{"id": &"boilerplate", "chance": 0.06},
		{"id": &"sermon", "chance": 0.04},
		{"id": &"landlord", "chance": 0.02},
	],
	&"badass": [
		{"id": &"hangnail", "chance": 0.04},
		{"id": &"dinner_bell", "chance": 0.02},
	],
}


static func get_def(id: StringName) -> LegendaryDef:
	if not _PRESETS.has(id):
		return null
	var p: Dictionary = _PRESETS[id]
	var d := LegendaryDef.new()
	d.id = id
	d.display_name = p["name"]
	d.weapon_class_id = p["class"]
	d.effect_id = p["effect"]
	d.flavor = p["flavor"]
	var sig: Dictionary[StringName, float] = {}
	for k: StringName in p["sig"]:
		sig[k] = float(p["sig"][k])
	d.signature = sig
	return d


static func all_ids() -> Array:
	return _PRESETS.keys()


## Every legendary a source can drop, with its authored chance.
static func entries_for(source_id: StringName) -> Array:
	return SOURCES.get(source_id, [])


## Roll the dedicated table for one kill. Each entry rolls independently, so an
## exceptional kill can theoretically pay out twice — rare enough to be a story.
static func roll(source_id: StringName, rng: RandomNumberGenerator) -> Array[StringName]:
	var out: Array[StringName] = []
	for e: Dictionary in entries_for(source_id):
		if rng.randf() < float(e["chance"]):
			out.append(e["id"])
	return out
