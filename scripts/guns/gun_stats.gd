class_name GunStats
extends RefCounted
## Resolves final gun stats (GUN_SCALING_SPEC §2/§3, WEAPONS_SPEC, SPEC Amendment A).
##
##   final_damage = class_base × dps_window(quality) × rarity_mult × Tier.power_mult(tier)
##
## Two independent axes never compounded: rarity and tier are SEPARATE multipliers,
## and ONLY damage takes them. Other stats vary by roll + parts only (a tier-10 gun
## reloads exactly as fast as a tier-1 gun). Rolls are coherent (§3.1): the damage
## quality sets the band every other stat rolls in, so guns are internally consistent.
##
## Deterministic: stats derive from `stat_seed` (the gun seed), independent of the
## part-picking RNG stream, so generate() and deserialize() produce identical numbers.

## ---------------------------------------------------------------- spread budget
## EVERYTHING that multiplies into DPS shares one budget (QUALITY_NAMING §4.3):
##     TOTAL = dps_window * fire_bonus_window * part_swing = 1.28 * 1.06 * 1.06 = 1.438
## The law: smallest_1_step (1.231, uncommon->rare) < TOTAL < smallest_2_step (1.60,
## common->rare). Above the 1-step, a god-roll of one rarity beats a floor-roll of the
## next, so low-rarity guns are never auto-trash. Below the 2-step, colour still predicts
## power across any gap of two. Exactly one rarity of overlap, never two.
##
## Do NOT widen any of these three in isolation. The previous FIRE_RATE_HI of 1.5 gave
## a real spread of 1.3 * 1.5 = 1.95 — wider than the Rare step — which meant a god-roll
## Common out-DPSed every Rare in the game.
const DPS_WINDOW_LO := 1.0
const DPS_WINDOW_HI := 1.28
const FIRE_BONUS_HI := 1.06
const PART_SWING := 0.03

## Fire rate is split in two. `fire_base` is DPS-NEUTRAL — it trades against damage at
## constant product, so it is pure feel (slow hard-hitter vs fast light gun) and costs
## nothing from the budget. Only `fire_bonus` above counts as power.
const FIRE_BASE_LO := 0.80
const FIRE_BASE_HI := 1.25

## Secondary windows. These do NOT multiply into DPS, so they stay wide.
const RELOAD_BEST := 0.5           ## lower is better → down to 50% of base time
const ACC_LO := 0.94
const ACC_HI := 1.06

## fire_rate floors at 1.0: no gun in the game fires slower than one shot per second
## (QUALITY_NAMING §4.4). Class base rates are chosen so this clamp never actually
## fires — clamping a rolled value upward would raise that gun's DPS above its roll.
const STAT_FLOORS: Dictionary[StringName, float] = {
	&"damage": 1.0, &"fire_rate": 1.0, &"mag_size": 1.0, &"reload_time": 0.3,
	&"accuracy": 0.05, &"crit_mult": 1.0, &"element_ratio": 0.0,
}

## NOTE: ScalingCurve is deliberately NOT used here. Power comes from Tier.power_mult(),
## a plain geometric step per tier. Sampling a 100-level curve at 10 anchor points to
## recover a geometric series was indirection with no payoff, and it was the source of a
## real bug: a tier index passed where a level was expected sampled the curve 10x too
## high and inflated every score by ~4.7x. ScalingCurve remains available for any system
## that genuinely needs per-level granularity.


## Coherent band the non-damage stats roll in, from the damage quality (§3.1).
static func _other_band(damage_quality: float) -> Vector2:
	if damage_quality >= 0.67:
		return Vector2(0.5, 1.0)      # damage best → others at least middle
	if damage_quality >= 0.34:
		return Vector2(0.0, 1.0)      # middle → wild card
	return Vector2(0.0, 0.5)          # damage worst → worst..middle


## `tier` is the PROGRESSION TIER (1..10). There is no player level and no per-kill gun
## level anywhere in this system (PROGRESSION_SPEC §0.2) — a gun's power is its tier and
## its rarity, full stop.
static func compute(recipe: Dictionary, rarity: int, weapon_class: WeaponClass,
		tier: int, stat_seed: int, ascension_offset: int = 0) -> Dictionary[StringName, float]:
	var wc := weapon_class if weapon_class != null else WeaponClass.builtin(&"pistol")
	var rng := RandomNumberGenerator.new()
	rng.seed = stat_seed

	var dq := rng.randf()                              # DPS quality (headline luck)
	var band := _other_band(dq)

	# One power roll, then feel as a TRADE against it, then a small independent
	# fire-rate quality. Product of damage x fire_rate is dps_mult * fire_bonus.
	var dps_mult := lerpf(DPS_WINDOW_LO, DPS_WINDOW_HI, dq)
	var fire_base := lerpf(FIRE_BASE_LO, FIRE_BASE_HI, rng.randf())
	var fire_bonus := lerpf(1.0, FIRE_BONUS_HI, rng.randf())

	var stats: Dictionary[StringName, float] = {}
	stats[&"damage"] = wc.base_damage * (dps_mult / fire_base)
	stats[&"fire_rate"] = wc.base_fire_rate * fire_base * fire_bonus
	stats[&"reload_time"] = wc.base_reload * lerpf(1.0, RELOAD_BEST, _roll(rng, band))
	stats[&"accuracy"] = wc.base_accuracy * lerpf(ACC_LO, ACC_HI, _roll(rng, band))
	stats[&"mag_size"] = lerpf(wc.mag_min, wc.mag_max, _roll(rng, band))
	stats[&"crit_mult"] = wc.crit_mult
	if wc.is_ordnance:
		# Cooldown is the inverse of the rolled fire rate, so a good fire-rate roll on
		# ordnance reads as a SHORTER cooldown — the stat the player actually watches.
		stats[&"cooldown"] = 1.0 / maxf(stats[&"fire_rate"], 0.01)
		stats[&"blast_radius"] = wc.blast_radius
	# Barrel drives the kinetic/elemental split (WEAPONS §3, SPEC Amendment A.1).
	var barrel: Variant = recipe.get(GunPartDef.Slot.BARREL)
	stats[&"element_ratio"] = (barrel as GunBarrelDef).element_ratio if barrel is GunBarrelDef else 0.0

	# Part payload pass (imported carrier kept): additive then multiplicative.
	for def: Variant in recipe.values():
		if def is GunPartDef:
			for key: StringName in (def as GunPartDef).stat_add:
				stats[key] = stats.get(key, 0.0) + (def as GunPartDef).stat_add[key]
	for def: Variant in recipe.values():
		if def is GunPartDef:
			for key: StringName in (def as GunPartDef).stat_mult:
				stats[key] = stats.get(key, 0.0) * (def as GunPartDef).stat_mult[key]

	# Part-rarity swing, capped at +/-3% (§4.3). Any wider and a well-parted Common
	# beats a Rare, at which point colour stops predicting power.
	var q := GunQuality.raw_q(recipe, rarity)
	stats[&"damage"] *= 1.0 + PART_SWING * clampf(q, -1.0, 1.0)

	# Damage-only scaling: rarity x tier. The two independent axes, never compounded.
	stats[&"damage"] *= Rarity.damage_mult(rarity) * Tier.power_mult(tier, ascension_offset)

	for key: StringName in STAT_FLOORS:
		if stats.has(key):
			# Ordnance is cooldown-gated and is MEANT to be slow; the 1.0/s floor exists
			# to stop a GUN feeling sluggish. Clamping ordnance up here would also raise
			# its DPS above its roll and hole the §4.3 spread budget for that class.
			if key == &"fire_rate" and wc.is_ordnance:
				continue
			stats[key] = maxf(stats[key], STAT_FLOORS[key])
	stats[&"mag_size"] = maxf(1.0, floorf(stats[&"mag_size"]))
	# Accuracy is a fraction, so the +6% roll window can push a high-base class (sniper
	# 0.98) past 1.0 and the card prints "102%". Ceiling it here rather than in the UI:
	# anything reading stats directly would otherwise see an impossible value too.
	stats[&"accuracy"] = minf(stats[&"accuracy"], 1.0)
	return stats


static func _roll(rng: RandomNumberGenerator, band: Vector2) -> float:
	return rng.randf_range(band.x, band.y)
