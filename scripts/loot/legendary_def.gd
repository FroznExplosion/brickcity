class_name LegendaryDef
extends Resource
## One authored legendary weapon (GUN_QUALITY_NAMING_SPEC §4.6).
##
## A legendary overrides WHICH gun drops, never HOW STRONG it is. It goes through the
## identical GunGenerator -> GunStats -> score pipeline as any world drop, so:
##   - it still rolls dq, which is why there is a GOOD one and a BAD one of each, and
##     why farming the same boss twice is worth doing;
##   - its open slots still roll part offsets, so it still earns a grade word;
##   - its score is comparable to every other gun in the game without a special case.
##
## What makes it legendary is the `signature` stat skew plus an exclusive part carrying
## `effect_id` — behaviour, not a bigger number.

@export var id: StringName
@export var display_name: String = ""
## Fixed class. A legendary is always the same kind of gun.
@export var weapon_class_id: StringName = &"pistol"

## The mechanical effect its exclusive part carries. Dispatched by StringName elsewhere.
@export var effect_id: StringName = &""
@export var effect_params: Dictionary = {}

## The "red text" skew, applied AFTER all normal stat resolution. Multiplicative per
## stat key. This is where a legendary earns its identity — a shotgun that fires twice
## as fast for half damage is still on the same DPS budget but plays nothing alike.
##
## NOTE: `damage` and `fire_rate` here DO move the gun's DPS and therefore its score
## (§4.3). Keep the PRODUCT of any damage/fire_rate pair at ~1.0 unless you intend the
## gun to sit off-budget on purpose.
@export var signature: Dictionary[StringName, float] = {}

## Player-facing flavour line. The BL2 "red text" slot.
@export var flavor: String = ""
