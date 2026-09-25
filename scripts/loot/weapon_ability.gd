class_name WeaponAbility
extends Resource
## An equipped ability that grants a gun effect to EVERY gun the player holds.
##
## Distinct from MANUFACTURER_SPEC §8 `PowerUp`, which explicitly "amplifies effects the
## gun already carries; it does not grant new effects". A WeaponAbility does both:
##
##   gun does NOT have the effect  ->  it is GRANTED at base strength
##   gun ALREADY has the effect    ->  it is UPGRADED (the gun's own copy gets stronger)
##
## That second branch is the whole point. It means an ability is never wasted on a gun
## that happens to share its effect — the overlap is the reward, not a dead slot.

@export var id: StringName
@export var display_name: String = ""
## The effect this grants, drawn from the MANUFACTURER_SPEC §2 catalog so an ability and
## a gun part are the same currency. A gun cannot tell where its effect came from.
@export var effect_id: StringName = &""
## Which brand owns the effect, for brand-match magnitude (MANUFACTURER §3.5).
@export var brand: StringName = &""
@export var description: String = ""


## The suffix marking an upgraded effect. Kept as an id convention rather than a flag so
## the effect list stays a flat PackedStringArray that serialises and syncs unchanged.
const UPGRADE_SUFFIX := "_up"


static func upgraded_id(effect: StringName) -> StringName:
	return StringName(String(effect) + UPGRADE_SUFFIX)


static func is_upgraded(effect: StringName) -> bool:
	return String(effect).ends_with(UPGRADE_SUFFIX)


## Strip the suffix, so a handler can dispatch on the base effect and read the upgrade
## as a magnitude rather than needing a second code path per effect.
static func base_id(effect: StringName) -> StringName:
	var s := String(effect)
	return StringName(s.trim_suffix(UPGRADE_SUFFIX)) if s.ends_with(UPGRADE_SUFFIX) else effect
