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
## curve: total growth across all 10 tiers is TIER_STEP^9 = 68.7x.
##
## 1.6 is SOLVED, not picked, from two authored calibration points:
##     T1 Legendary == T3 Uncommon   ->  r_leg = r_unc * STEP^2
##     T1 Legendary >= T2 Unique     ->  r_leg >= r_uni * STEP
## With r_unc 1.3 and r_uni 2.0 those give STEP = 1.6 and r_leg = 3.3 (Rarity.MULTS).
##
## The resulting ladder, lifespan_tiers = ln(rarity_mult) / ln(TIER_STEP):
##   uncommon 0.56 | rare 1.00 | unique 1.48 | legendary 2.54 | mythic 3.42
## **Rare is worth exactly one tier** — the anchor to hold when retuning. Rarity now
## spans MULTIPLE tiers, which is what the calibration points require; the previous
## TIER_STEP of 2.0 confined every rarity to under one tier and could not satisfy them.
const TIER_STEP := 1.6

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
