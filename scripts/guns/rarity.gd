class_name Rarity
extends Resource
## One rarity tier (GUN_SCALING_SPEC §1). Six tiers ship. The damage multiplier is
## the ONLY thing rarity scales on the stat side; everything else rarity gives is more
## part slots / behavior (MANUFACTURER_SPEC). Authorable as .tres later; the static
## table below is the shipping source of truth used by the generator (1-based index).

@export var id: StringName
@export var display_name: String
@export var color: Color = Color.WHITE
@export var damage_multiplier: float = 1.0
@export var stat_roll_quality: float = 0.0        ## 0..1 bias toward high-end rolls (optional)
@export var part_count_bonus: int = 0
@export var weight: float = 1.0

## Shipping tiers, index 0..5 == rarity 1..6 (GUN_SCALING §1).
const IDS: Array[StringName] = [
	&"common", &"uncommon", &"rare", &"unique", &"legendary", &"mythic",
]
const NAMES: Array[String] = [
	"Common", "Uncommon", "Rare", "Unique", "Legendary", "Mythic",
]
## The combat design's table (Docs/Weapons/COMBAT_DESIGN.md section 2). Rarity
## multiplies damage -- Borderlands scaling, not Halo's fixed shots-to-kill -- but gently:
## the anchor is that on level a common pistol kills a light enemy in ~6 body shots and a
## legendary in 4, reaching 2-3 only with a headshot or a damage modifier. So the colour
## is strong, and the last step is skill or build.
##
## Lifespans in tiers at Tier.TIER_STEP 1.25 (ln(mult)/ln(1.25)):
##     uncommon 0.63 | rare 1.18 | unique 1.67 | legendary 2.51 | mythic 2.51
## RARE IS WORTH ABOUT ONE TIER, and a Unique one tier back is a good Uncommon.
## Legendary and Mythic share a multiplier: a Mythic's own effect is what makes it better.
const MULTS: Array[float] = [1.0, 1.15, 1.3, 1.45, 1.75, 1.75]


## Damage multiplier for a 1-based rarity index (1 = common .. 6 = mythic).
static func damage_mult(rarity_index: int) -> float:
	return MULTS[clampi(rarity_index - 1, 0, MULTS.size() - 1)]


static func id_of(rarity_index: int) -> StringName:
	return IDS[clampi(rarity_index - 1, 0, IDS.size() - 1)]
