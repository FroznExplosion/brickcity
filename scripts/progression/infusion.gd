class_name Infusion
extends RefCounted
## Safehouse infusion (Docs/Weapons/COMBAT_DESIGN.md 1.2, PROGRESSION_SPEC 1.1): at a
## workbench the player spends SCRAP to raise a gun to their current story tier. Its
## parts, rolls, modifiers, alt-fire, element and name stay; only its damage moves
## (GunGenerator.retier). Never above the story tier, never down.
##
## Scrap is the one material, for now (COMBAT_DESIGN 13 asked what they are): kills
## drop it (PlayerLevel.credit_kill, beside the XP) and a gun broken down at the bench
## gives it back (`salvage_value`). Both, and the cost, grow 1.25x a tier -- the tier's
## own step -- so an infusion costs about as many kills in every zone. Placeholder numbers.

## Scrap to lift a white gun one tier, from tier 1 to 2; ×Tier.TIER_STEP a tier above.
const COST_BASE := 100.0
## The cost by rarity, white to mythic: an infused legendary costs more than a white.
const RARITY_COST: Array[float] = [1.0, 1.25, 1.6, 2.0, 2.5, 3.0]
## A gun broken down: this many scrap a rarity step at its tier, ×Tier.TIER_STEP a tier.
const SALVAGE_BASE := 20.0
## A kill's scrap, of its XP.
const SCRAP_PER_XP := 0.25


static func _rarity_cost(rarity: int) -> float:
	return RARITY_COST[clampi(rarity - 1, 0, RARITY_COST.size() - 1)]


static func _tier_scale(tier: int) -> float:
	return pow(Tier.TIER_STEP, maxi(tier - 1, 0))


## Scrap to lift a gun of `rarity` from `from_tier` to `to_tier`: each tier gained at
## its own price. 0 for no gain.
static func cost(rarity: int, from_tier: int, to_tier: int) -> int:
	var c := 0.0
	for t in range(from_tier + 1, to_tier + 1):
		c += COST_BASE * _tier_scale(t - 1)
	return roundi(c * _rarity_cost(rarity))


## Scrap a gun of `rarity` and `tier` breaks down to.
static func salvage_value(rarity: int, tier: int) -> int:
	return roundi(SALVAGE_BASE * _rarity_cost(rarity) * clampi(rarity, 1, 6) * _tier_scale(tier))


## Why `g` cannot be infused to `story_tier` with `scrap` ("" if it can).
static func why_not(g: GunInstance, story_tier: int, scrap: int) -> String:
	if g == null or g.result == null:
		return "No gun"
	if g.tier >= story_tier:
		return "Already at tier %d" % g.tier
	var c := cost(g.rarity, g.tier, story_tier)
	if scrap < c:
		return "Needs %d scrap (have %d)" % [c, scrap]
	return ""


## `g` to `to_tier`, in place: the gun in hand keeps firing, at its new damage.
static func infuse(g: GunInstance, to_tier: int) -> void:
	if g == null or g.result == null or to_tier <= g.tier:
		return
	GunGenerator.retier(g.result, to_tier)
	g.tier = g.result.tier
	g.stats = g.result.stats


## A saved gun (CharacterSave.gun_entry) to `to_tier`: the tier in the entry, which
## is all a saved gun's tier is.
static func infuse_entry(entry: Dictionary, to_tier: int) -> Dictionary:
	var e := entry.duplicate()
	e["tier"] = maxi(int(e.get("tier", 1)), to_tier)
	return e
