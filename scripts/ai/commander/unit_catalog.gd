class_name UnitCatalog
extends RefCounted
## Everything a commander can field, and what it costs (Docs/AI.md 9;
## Red Dawn's points table, docs/commander_and_points_system.md in that repo).
##
## POINTS are the one currency: a commander's budget is spent in them, a
## force's strength is counted in them, and an off-screen fight is resolved in
## them. Infantry is on Red Dawn's scale (a rifleman is 1); vehicles and mechs
## are listed now so the commander, its doctrine and the save format already
## know them -- `built` says which exist in the game yet. A unit that is not
## built is never picked.
##
## MOBILITY is what navigation it needs (AI.md 3.6: one representation per way
## of moving): foot (AINav today), wheeled and tracked (a vehicle map with
## clearance -- tracked also crushes what wheels cannot cross), hover and air
## (the flyer height field), water (the sea's surface), mech (a mech map with
## clearance and breach links, AIPlan P7).
##
## Health is a PROFILE (EnemyProfiles): the layers an infantryman wears over its
## flesh, counted in melees, at the fight's level (Docs/Weapons/COMBAT_DESIGN.md 4).
## Vehicles carry their own damage zones when built.

const UNITS := {
	# --- infantry: built -------------------------------------------------------
	&"rifleman": {"name": "Rifleman", "points": 1.0, "mobility": &"foot", "role": &"line",
			"weapon": &"rifle", "profile": &"light", "built": true},
	&"assault": {"name": "Assault", "points": 1.0, "mobility": &"foot", "role": &"close",
			"weapon": &"smg", "profile": &"light", "built": true},
	&"breacher": {"name": "Breacher", "points": 1.5, "mobility": &"foot", "role": &"close",
			"weapon": &"shotgun", "profile": &"light_armored", "built": true},
	&"marksman": {"name": "Marksman", "points": 4.0, "mobility": &"foot", "role": &"long",
			"weapon": &"sniper", "profile": &"very_light", "built": true},
	&"veteran": {"name": "Veteran", "points": 2.5, "mobility": &"foot", "role": &"line",
			"weapon": &"rifle", "profile": &"medium", "built": true},
	# --- infantry: not yet -------------------------------------------------------
	&"rocketeer": {"name": "Rocketeer", "points": 5.0, "mobility": &"foot", "role": &"anti_armor",
			"weapon": &"rocket_launcher", "profile": &"light_shielded", "built": false},
	&"officer": {"name": "Officer", "points": 8.0, "mobility": &"foot", "role": &"command",
			"weapon": &"pistol", "profile": &"medium_shielded", "built": false},
	# --- vehicles (Red Dawn's roles) and mechs: planned ---------------------------
	&"jeep": {"name": "Jeep", "points": 3.0, "mobility": &"wheeled", "role": &"transport",
			"seats": 4, "built": false},
	&"truck": {"name": "Truck", "points": 4.0, "mobility": &"wheeled", "role": &"transport",
			"seats": 8, "built": false},
	&"apc": {"name": "APC", "points": 12.0, "mobility": &"wheeled", "role": &"apc",
			"seats": 8, "built": false},
	&"ifv": {"name": "IFV", "points": 15.0, "mobility": &"tracked", "role": &"ifv",
			"seats": 6, "built": false},
	&"tank": {"name": "Tank", "points": 20.0, "mobility": &"tracked", "role": &"heavy_armor",
			"seats": 0, "built": false},
	&"transport_heli": {"name": "Transport helicopter", "points": 10.0, "mobility": &"air",
			"role": &"air_transport", "seats": 8, "built": false},
	&"attack_heli": {"name": "Attack helicopter", "points": 18.0, "mobility": &"air",
			"role": &"air_support", "seats": 0, "built": false},
	&"strike_plane": {"name": "Strike plane", "points": 16.0, "mobility": &"air",
			"role": &"air_strike", "seats": 0, "built": false},
	&"patrol_boat": {"name": "Patrol boat", "points": 6.0, "mobility": &"water",
			"role": &"transport", "seats": 6, "built": false},
	&"gunboat": {"name": "Gunboat", "points": 10.0, "mobility": &"water", "role": &"fire_support",
			"seats": 2, "built": false},
	&"mech": {"name": "Mech", "points": 25.0, "mobility": &"mech", "role": &"heavy_armor",
			"seats": 0, "built": false},
}


static func get_unit(id: StringName) -> Dictionary:
	return UNITS.get(id, UNITS[&"rifleman"])


static func points(id: StringName) -> float:
	return float(get_unit(id).points)


## The units that exist in the game now.
static func built() -> Array[StringName]:
	var out: Array[StringName] = []
	for id in UNITS:
		if bool(UNITS[id].built):
			out.append(id)
	return out
