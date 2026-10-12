class_name CombatScale
extends RefCounted
## The one unit fights are sized in: the MELEE (Docs/Weapons/COMBAT_DESIGN.md 4.1).
##
## A melee at level 1 is a light enemy's whole flesh -- which is also what a median
## common pistol kills in 6 body shots (LootRoller.TRASH_BASE_HP, the section 3 anchor),
## so the two scales are one. It grows +25% a level with everything else (Tier), so on
## level every count -- shots and melees -- is the same at every level.
##
## Defences are stated in melees to break (EnemyProfiles), and a layer's health is
## that count times what one melee does to it.

## Melee damage at level 1: a light enemy's flesh.
const MELEE_BASE := LootRoller.TRASH_BASE_HP
## Melee against a shield (section 4.2): a shield of "one melee" holds this much more.
const SHIELD_MELEE := 1.5
## A crit on a shield (section 4.4): the shield takes this share of the crit's EXTRA
## damage -- a 2x crit lands 1.5x on it, a sniper's 3x lands 2x. Armor and flesh take
## crits fully. Every hit carries what is left on into the layer under it.
const SHIELD_CRIT_SHARE := 0.5
## Shields come back: after this long untouched, at this many melees' worth a second.
const SHIELD_REGEN_DELAY := 3.0
const SHIELD_REGEN_SECONDS := 2.0


## What one melee does at `level` (1..10).
static func melee(level: int) -> float:
	return MELEE_BASE * Tier.power_mult(level)


## Health of a layer of `type` that `melees` melees break, at `level` (the AI roster's
## layers are stated this way: a shield of one melee holds SHIELD_MELEE melees' damage).
static func layer_hp(type: StringName, melees: float, level: int) -> float:
	var hp := melees * melee(level)
	return hp * SHIELD_MELEE if type == &"shield" else hp


## Health of a layer `units` deep at `level`: a unit is a medium enemy's health, which is
## also one melee's damage (EnemyProfiles, the Armory Ledger's Time to kill tab).
static func units_hp(units: float, level: int) -> float:
	return units * melee(level)

## The crit multiplier a layer of `type` takes from a crit of `crit` (1 = no crit).
static func layer_crit(type: StringName, crit: float) -> float:
	if crit <= 1.0:
		return 1.0
	return 1.0 + SHIELD_CRIT_SHARE * (crit - 1.0) if type == &"shield" else crit
