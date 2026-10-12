class_name GunRange
## A gun's range, metres: how far it is meant to fight, and how far aim assist helps it
## (AimAssist, Docs/Weapons/AIM_ASSIST.md 4). Not where its rounds stop.
##
##   pellet guns   their pattern's `far` (GunFireMode): past it a blast does its falloff
##   other guns    the class's range, scaled by the accuracy roll against the class's own:
##                 a tighter rifle reaches further, a looser one less -- (acc / base)^2,
##                 held to RANGE_SCALE either way. Accuracy decides how far a gun reaches,
##                 not how well it hits up close: from the hip every gun is tight
##                 (PlayerView's HIP_SPREAD).

const CLASS_RANGE := {
	&"pistol": 35.0, &"revolver": 40.0, &"smg": 28.0, &"rifle": 60.0, &"lmg": 55.0,
	&"dmr": 90.0, &"sniper": 150.0, &"shotgun": 14.0,
	&"rocket_launcher": 60.0, &"grenade_launcher": 40.0, &"arc_caster": 20.0,
}
const DEFAULT_RANGE := 40.0
const RANGE_SCALE := Vector2(0.75, 1.35)


static func of(wc: WeaponClass, stats: Dictionary, fire: Dictionary = {}) -> float:
	if fire.has("pellets") and fire.has("far"):
		return float(fire.far)
	var id := wc.id if wc != null else &""
	var base := float(CLASS_RANGE.get(id, DEFAULT_RANGE))
	if wc == null or wc.base_accuracy <= 0.0 or not stats.has(&"accuracy"):
		return base
	var r := float(stats[&"accuracy"]) / wc.base_accuracy
	return base * clampf(r * r, RANGE_SCALE.x, RANGE_SCALE.y)
