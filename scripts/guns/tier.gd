class_name Tier
extends Resource
## One weapon-power tier / difficulty plateau (PROGRESSION_SPEC §1). 10 tiers ship;
## each samples the shared ScalingCurve at anchor_level = tier_index × 10. Authorable
## as .tres later; the static helper is the shipping source of truth.

@export var tier_id: StringName
@export var display_name: String
@export var anchor_level: int = 10
@export var enemy_hp_scale: float = 1.0

const COUNT: int = 10

## Power multiplier per tier step. THE single number that sets the whole game's power
## curve: total growth across all 10 tiers is TIER_STEP^9 = 7.45x.
##
## 1.25 is the combat design's choice (Docs/Weapons/COMBAT_DESIGN.md section 1): a level
## takes a while to reach, so a good gun has to stay worth carrying across one. Read with
## Rarity.MULTS, lifespan_tiers = ln(rarity_mult) / ln(TIER_STEP):
##   uncommon 0.63 | rare 1.18 | unique 1.67 | legendary / mythic 2.51
## The rules those numbers hold (tools/combat_numbers_probe.gd checks each one):
##   * a blue is worth about one level: a level N+1 white ~= a level N blue;
##   * a purple stays viable two levels: one level on it is a good uncommon, two on a
##     common overtakes it.
## Enemy health steps by the same factor (LootRoller.enemy_hp), so ON LEVEL every
## shots-to-kill number is the same at every tier.
const TIER_STEP := 1.25

## There is NO player level and no per-kill gun level (PROGRESSION_SPEC §0.2). A gun's
## power comes from its tier and nothing else, so this is a plain geometric step rather
## than a 100-level curve sampled at 10 points — the sampling was indirection with no
## payoff once the curve became constant-rate.
static func power_mult(tier_index: int, ascension_offset: int = 0) -> float:
	var t := clampi(tier_index + ascension_offset, 1, COUNT + ascension_offset)
	return pow(TIER_STEP, float(maxi(t, 1) - 1))


## Anchor (hidden) level a tier samples the curve at. tier_index is 1-based (1..10).
## Retained for PROGRESSION_SPEC's zone tables; NOT used by gun scaling any more.
static func anchor_for(tier_index: int) -> int:
	return clampi(tier_index, 1, COUNT) * 10


## Effective hidden level = tier anchor + per-run ascension offset (PROGRESSION §1).
static func effective_level(tier_index: int, ascension_offset: int = 0) -> int:
	return anchor_for(tier_index) + ascension_offset
