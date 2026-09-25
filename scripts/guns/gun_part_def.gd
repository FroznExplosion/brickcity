class_name GunPartDef
extends Resource
## Metadata for a single gun part. One .tres per part, pointing at its GLB scene.

enum Slot {
	BODY,        ## The receiver. Every gun has exactly one; assembly starts here.
	BARREL,
	STOCK,
	GRIP,
	MAGAZINE,
	SIGHT,
	MUZZLE,      ## Attaches to a socket on the barrel.
	UNDERBARREL, ## Attaches to a socket on the barrel or body.
}

## Maps a socket node name suffix ("socket_barrel" -> "barrel") to a Slot.
const SLOT_BY_SUFFIX: Dictionary[String, Slot] = {
	"body": Slot.BODY,
	"barrel": Slot.BARREL,
	"stock": Slot.STOCK,
	"grip": Slot.GRIP,
	"magazine": Slot.MAGAZINE,
	"sight": Slot.SIGHT,
	"muzzle": Slot.MUZZLE,
	"underbarrel": Slot.UNDERBARREL,
}

@export var id: StringName
@export var display_name: String = ""
@export var slot: Slot = Slot.BODY
@export var scene: PackedScene

@export_group("Selection")
@export var manufacturer: StringName = &"generic"
## Relative pick weight within its slot pool.
@export var weight: float = 1.0
## Inclusive rarity band this part can appear in (1 = common .. 6 = mythic).
## This is the HARD LEGALITY GATE and always wins over the offset roll below.
@export_range(1, 6) var min_rarity: int = 1
@export_range(1, 6) var max_rarity: int = 6

## The tier this part is AUTHORED for — what the generator aims at, as opposed to
## what it is merely allowed to appear in (QUALITY_NAMING §2.1). The gap between a
## part's native_rarity and the gun's rarity is what produces the grade word.
## 0 = unset, which resolves to min_rarity so already-authored .tres keep working.
@export_range(0, 6) var native_rarity: int = 0

## Non-empty => this part belongs to that legendary's fixed recipe ONLY and is
## excluded from every general candidate pool (QUALITY_NAMING §5).
@export var exclusive_to: StringName = &""

@export_group("Stats")
## Additive stat modifiers, e.g. { &"damage": 4.0, &"mag_size": 6.0 }.
@export var stat_add: Dictionary[StringName, float] = {}
## Multiplicative stat modifiers, e.g. { &"fire_rate": 1.15, &"accuracy": 0.9 }.
@export var stat_mult: Dictionary[StringName, float] = {}

@export_group("Effect")
## Mechanical effect this part carries ("" = none). MANUFACTURER_SPEC §2/§3.
## One physical part = model (this def) + effect (this id). Merges read the gun's
## aggregate effect list, slot-agnostic.
@export var effect_id: StringName = &""
@export var effect_params: Dictionary = {}
## Effect-compat tags: the generator won't co-roll a part whose effect conflicts
## with an already-placed effect's tags (MANUFACTURER §4).
@export var effect_tags: PackedStringArray = []
@export var effect_incompatible_tags: PackedStringArray = []
## Effect-only rarity gate (e.g. grenade_drop is legendary+), separate from the
## part's own min_rarity so a common part can still host a gated effect if desired.
@export_range(1, 6) var effect_min_rarity: int = 1

@export_group("Flavor")
## Free-form tags: &"scoped", &"heavy", &"elemental_capable"...
@export var tags: PackedStringArray = []
## Optional name fragment used by the gun name generator ("Ravager", "Longbore").
@export var name_fragment: String = ""


func fits_rarity(rarity: int) -> bool:
	return rarity >= min_rarity and rarity <= max_rarity


## The tier this part counts AS when measuring gun quality. Falls back to min_rarity
## so parts authored before native_rarity existed still report something sane.
func tier() -> int:
	return native_rarity if native_rarity > 0 else min_rarity


func has_effect() -> bool:
	return effect_id != &""
