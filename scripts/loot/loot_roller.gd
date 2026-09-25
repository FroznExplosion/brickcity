class_name LootRoller
extends RefCounted
## Decides WHICH rarity and WHAT TIER a drop is (GUN_QUALITY_NAMING_SPEC §4.5).
## Deliberately separate from GunGenerator: the generator builds a gun of a given
## rarity, this decides what rarity the world hands it. Dedicated drops (§4.6)
## override which gun, never how strong — so they enter the same generator afterwards.

## BL2 world-drop rates (§4.5.1). Legendary at 0.28% is ~9x tighter than the 2.5% the
## project shipped with; that tightness IS the cool factor, so resist raising it.
const RARITY_WEIGHTS: Array[float] = [76.0, 17.0, 5.5, 1.2, 0.28, 0.02]

## Rarity climbs with the drop's TIER (§4.5.2). Applied as a POWER so each step up
## compounds — rarity i weight becomes weight * pow(luck, i). 0.07/tier gives roughly
## the end-of-game lift (Legendary 0.28% -> ~1.4%) the old per-level 0.006 gave across
## 100 levels, now spread over 10 tiers instead.
const TIER_LUCK := 0.07

## Extra luck per TIER the enemy sits above the player's current tier (§4.5.3). A tier
## is a big step, so this is worth far more per unit than the old per-level bonus.
const OVERTIER_LUCK := 0.55
const MAX_OVERTIER := 3

## Per-archetype loot generosity: how many guns, and a flat luck bonus. A boss dropping
## better loot is this table, not a special case anywhere else in the pipeline.
## Dedicated chances live in LegendaryTable.SOURCES, keyed by these same ids — boss
## totals 12% across three guns, badass 6% across two (§4.6).
const ARCHETYPES: Dictionary[StringName, Dictionary] = {
	&"trash":    {"hp_mult": 1.0,  "drops": 1, "luck": 1.00},
	&"standard": {"hp_mult": 2.5,  "drops": 1, "luck": 1.15},
	&"heavy":    {"hp_mult": 7.0,  "drops": 2, "luck": 1.45},
	&"badass":   {"hp_mult": 20.0, "drops": 3, "luck": 2.20},
	&"boss":     {"hp_mult": 70.0, "drops": 4, "luck": 3.50},
}

## Trash HP at TIER 1. Everything else derives: this is the anchor that makes a tier-1
## mid-roll common rifle kill trash in 4-6 shots (§7.2).
const TRASH_BASE_HP := 45.0


static func archetype(id: StringName) -> Dictionary:
	return ARCHETYPES.get(id, ARCHETYPES[&"trash"])


static func archetype_ids() -> Array:
	return ARCHETYPES.keys()


## Enemy max HP for an archetype at a tier. Same Tier.power_mult step as guns, which is
## why shots-to-kill is constant at every tier when gun and enemy match.
static func enemy_hp(id: StringName, tier: int) -> float:
	var mult: float = float(archetype(id).get("hp_mult", 1.0))
	return TRASH_BASE_HP * mult * Tier.power_mult(tier)


## Tier luck only. Separate from the archetype bonus so a designer can read either.
static func tier_luck(tier: int) -> float:
	return 1.0 + TIER_LUCK * float(maxi(tier, 1) - 1)


## The tier a drop rolls at (§4.5.3). An enemy ABOVE the player's tier drops at its own
## tier (the reward for punching up); an enemy at or below drops at the player's tier, so
## a lower-tier zone is never a downgrade machine or a farm.
static func drop_tier(enemy_tier: int, player_tier: int) -> int:
	return maxi(enemy_tier, player_tier)


static func total_luck(enemy_tier: int, player_tier: int, id: StringName) -> float:
	var over := clampi(enemy_tier - player_tier, 0, MAX_OVERTIER)
	var luck := tier_luck(drop_tier(enemy_tier, player_tier))
	luck *= 1.0 + OVERTIER_LUCK * float(over)
	luck *= float(archetype(id).get("luck", 1.0))
	return luck


## Weighted rarity roll with luck folded in. Returns 1..6.
static func roll_rarity(rng: RandomNumberGenerator, luck: float = 1.0) -> int:
	var weights: Array[float] = []
	var total := 0.0
	for i in RARITY_WEIGHTS.size():
		var w: float = RARITY_WEIGHTS[i] * pow(luck, float(i))
		weights.append(w)
		total += w
	if total <= 0.0:
		return 1
	var roll := rng.randf() * total
	for i in weights.size():
		roll -= weights[i]
		if roll <= 0.0:
			return i + 1
	return 1


## Everything one kill produces. `luck` rides along so the generator can bias part
## offsets by the same number that biased the rarity (§4.5.2).
class Drop:
	var rarity: int
	var tier: int
	var luck: float
	var dedicated: bool = false
	## Which authored legendary this is, when dedicated. &"" for a world drop.
	var legendary_id: StringName = &""


## A kill's full loot. World rolls and the dedicated roll are INDEPENDENT (§4.6) —
## a boss can drop its dedicated gun AND a world legendary in the same kill, which is
## how BL2 behaves and why the dedicated roll does not consume a world slot.
static func roll_drops(id: StringName, enemy_tier: int, player_tier: int,
		rng: RandomNumberGenerator) -> Array[Drop]:
	var arch := archetype(id)
	var luck := total_luck(enemy_tier, player_tier, id)
	var t := drop_tier(enemy_tier, player_tier)

	var out: Array[Drop] = []
	for _i in int(arch.get("drops", 1)):
		var d := Drop.new()
		d.rarity = roll_rarity(rng, luck)
		d.tier = t
		d.luck = luck
		out.append(d)

	# The dedicated table rolls SEPARATELY and adds to the pile — it never consumes a
	# world slot. Chances are authored per entry and untouched by luck: a boss's own gun
	# must not get commoner because the player out-levelled it, or the chase becomes
	# a farm.
	for leg_id in LegendaryTable.roll(id, rng):
		var d := Drop.new()
		d.rarity = 5                      # a dedicated is a legendary by definition
		d.tier = t
		d.luck = luck
		d.dedicated = true
		d.legendary_id = leg_id
		out.append(d)
	return out
