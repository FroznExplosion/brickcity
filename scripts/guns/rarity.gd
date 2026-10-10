class_name Rarity
extends Resource
## One rarity tier (Docs/Weapons/COMBAT_DESIGN.md section 2). Six tiers ship. Rarity
## scales damage a little and decides how many modifiers a gun carries and how well they
## roll (GunModifiers). Authorable as .tres later; the static tables below are the
## shipping source of truth used by the generator (1-based index).

@export var id: StringName
@export var display_name: String
@export var color: Color = Color.WHITE
@export var damage_multiplier: float = 1.0
@export var stat_roll_quality: float = 0.0        ## 0..1 floor of a modifier roll (QUALITY)
@export var part_count_bonus: int = 0
@export var weight: float = 1.0

## Shipping tiers, index 0..5 == rarity 1..6 (GUN_SCALING §1).
const IDS: Array[StringName] = [
	&"common", &"uncommon", &"rare", &"unique", &"legendary", &"mythic",
]
const NAMES: Array[String] = [
	"Common", "Uncommon", "Rare", "Unique", "Legendary", "Mythic",
]
## The combat design's table (Docs/Weapons/COMBAT_DESIGN.md section 2, v2). Rarity
## buys MODIFIER SLOTS and modifier quality, and only a small damage step -- felt in the
## hand, but not enough to change a shots-to-kill count on its own (section 3). The whole
## colour range is worth about half a tier (ln 1.12 / ln 1.25 = 0.51); the build is what
## moves a count. Legendary and Mythic share a step: a Mythic's own effect makes it better.
const MULTS: Array[float] = [1.0, 1.03, 1.06, 1.09, 1.12, 1.12]

## Modifier slots by rarity (section 2): a white carries one, a purple and up four.
const SLOTS: Array[int] = [1, 2, 3, 4, 4, 4]

## Modifier quality by rarity (section 2): the floor of a modifier's roll inside its band,
## as a fraction of the band. A white rolls anywhere; a purple never in its bottom 45%.
const QUALITY: Array[float] = [0.0, 0.15, 0.3, 0.45, 0.6, 0.6]


## Damage multiplier for a 1-based rarity index (1 = common .. 6 = mythic).
static func damage_mult(rarity_index: int) -> float:
	return MULTS[clampi(rarity_index - 1, 0, MULTS.size() - 1)]


static func id_of(rarity_index: int) -> StringName:
	return IDS[clampi(rarity_index - 1, 0, IDS.size() - 1)]


## How many modifiers a gun of this rarity carries.
static func modifier_slots(rarity_index: int) -> int:
	return SLOTS[clampi(rarity_index - 1, 0, SLOTS.size() - 1)]


## Where in a modifier's band a roll lands (0 = its low end, 1 = its top), from a 0..1
## draw `u`: a higher rarity lifts the floor.
static func roll_quality(rarity_index: int, u: float) -> float:
	return lerpf(QUALITY[clampi(rarity_index - 1, 0, QUALITY.size() - 1)], 1.0, u)
