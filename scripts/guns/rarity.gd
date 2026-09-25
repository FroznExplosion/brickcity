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
## DERIVED from two authored calibration points, not chosen (QUALITY_NAMING §1):
##     T1 Legendary == T3 Uncommon      ->  3.3 ~= 1.3 * 1.6^2 = 3.328
##     T1 Legendary >= T2 Unique        ->  3.3 >= 2.0 * 1.6   = 3.2
## Everything else fills in between. Lifespans in tiers (ln(mult)/ln(1.6)):
##     uncommon 0.56 | rare 1.00 | unique 1.48 | legendary 2.54 | mythic 3.42
##
## RARE IS WORTH EXACTLY ONE TIER. That is the anchor to hold when retuning: it means a
## fresh Rare exactly matches a fresh Common one tier up, and every other rarity reads
## as a fraction or multiple of that.
##
## Unique sits at 1.48 tiers and Legendary at 2.54, so Legendary is a full tier clear of
## Unique rather than tying it — the old 2.00/2.00 pair made orange 4x rarer than purple
## for zero visible gain on the score.
const MULTS: Array[float] = [1.0, 1.3, 1.6, 2.0, 3.3, 5.0]


## Damage multiplier for a 1-based rarity index (1 = common .. 6 = mythic).
static func damage_mult(rarity_index: int) -> float:
	return MULTS[clampi(rarity_index - 1, 0, MULTS.size() - 1)]


static func id_of(rarity_index: int) -> StringName:
	return IDS[clampi(rarity_index - 1, 0, IDS.size() - 1)]
