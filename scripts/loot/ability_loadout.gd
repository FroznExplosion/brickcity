class_name AbilityLoadout
extends RefCounted
## The player's equipped WeaponAbilities, and the one function that matters:
## `apply()`, which rewrites a gun's effect list as if the ability were a part bolted
## onto every gun the player holds.
##
## Abilities are a PLAYER property, not a gun property, so nothing is written back onto
## the gun's recipe. Swapping guns re-applies instantly and swapping abilities never
## edits a stored weapon — which is also why an ability can be re-rolled freely without
## invalidating anything on the floor or in the stash.

## Shipping abilities, drawn from the MANUFACTURER_SPEC §2 catalog so an ability and a
## gun part trade in the same currency. Brand is carried for brand-match magnitude.
const _PRESETS := {
	&"ricochet":  {"name": "Ricochet", "brand": &"cowboy",
		"desc": "Crits fire a bouncing round at the nearest enemy."},
	&"explosive": {"name": "Explosive", "brand": &"boomer",
		"desc": "Rounds deal splash on impact."},
	&"lifesteal": {"name": "Lifesteal", "brand": &"leech",
		"desc": "Hits and kills heal you."},
	&"fire_ramp": {"name": "Fire Ramp", "brand": &"rapid",
		"desc": "Holding the trigger ramps fire rate."},
	&"homing":    {"name": "Homing", "brand": &"seeker",
		"desc": "Rounds curve toward enemies."},
	&"power_shot": {"name": "Power Shot", "brand": &"charge",
		"desc": "Every Nth shot is a charged power shot."},
	&"element":   {"name": "Elemental", "brand": &"elemental",
		"desc": "Applies the gun's element more often."},
	&"extra_round": {"name": "Extra Round", "brand": &"rapid",
		"desc": "Chance to fire a free extra bullet."},
}

## How many abilities can be equipped at once. One to start; the meta loop unlocks more.
const MAX_SLOTS := 3

var slots: Array[WeaponAbility] = []


static func get_ability(id: StringName) -> WeaponAbility:
	if not _PRESETS.has(id):
		return null
	var p: Dictionary = _PRESETS[id]
	var a := WeaponAbility.new()
	a.id = id
	a.effect_id = id                    # ability id IS the effect id; no mapping table
	a.display_name = p["name"]
	a.brand = p["brand"]
	a.description = p["desc"]
	return a


static func all_ids() -> Array:
	return _PRESETS.keys()


func equip(id: StringName) -> bool:
	var a := AbilityLoadout.get_ability(id)
	if a == null or slots.size() >= MAX_SLOTS or has(id):
		return false
	slots.append(a)
	return true


func unequip(id: StringName) -> void:
	for i in range(slots.size() - 1, -1, -1):
		if slots[i].id == id:
			slots.remove_at(i)


func has(id: StringName) -> bool:
	for a in slots:
		if a.id == id:
			return true
	return false


func clear() -> void:
	slots.clear()


## Rewrite `effects` as the gun would carry them with these abilities equipped.
##
## Abilities are just MORE SOURCES: append one per equipped ability, then let
## GunEffects.stack() do the counting. Two sources of an effect upgrade it, and the
## sources are interchangeable — a gun that rolled the effect twice and a gun that
## rolled it once alongside a matching ability land in exactly the same place.
##
## Idempotent, because stack() reads an already-upgraded id as two sources.
func apply(effects: PackedStringArray) -> PackedStringArray:
	var merged := PackedStringArray(effects)
	for a in slots:
		merged.append(String(a.effect_id))
	return GunEffects.stack(merged)


## Which effects end up upgraded once this loadout is applied. Purely for UI — the card
## highlights these so the stacking reward is visible, not silent.
func upgraded_in(effects: PackedStringArray) -> PackedStringArray:
	var out := PackedStringArray()
	for e in apply(effects):
		if WeaponAbility.is_upgraded(StringName(e)):
			out.append(e)
	return out
