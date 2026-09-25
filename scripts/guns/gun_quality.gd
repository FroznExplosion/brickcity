class_name GunQuality
extends RefCounted
## Part-rarity quality, the grade word, and the gun score (GUN_QUALITY_NAMING_SPEC
## §2, §3.1, §4). Pure math + word tables; owns no state and touches no nodes.
##
## The three player-facing reads this file produces, and what each answers:
##   colour (Rarity)  -> what KIND of gun is this
##   score            -> is it STRONGER than what I hold
##   grade word       -> is this a GOOD VERSION of it
## No two encode the same thing, which is the whole point of keeping them separate.

## The score is denominated in TIERS of power, so it reads off Tier.TIER_STEP. There is
## no player level anywhere in this system (PROGRESSION_SPEC §0.2).
const LN_STEP := 0.47000363  # ln(1.6), precomputed: this runs per drop.
## MUST equal ln(Tier.TIER_STEP). If the two ever disagree, every score in the game
## silently rescales without a single damage number changing.

## Score presentation (§4). 100 pts per TIER, so the number reads directly as
## "tiers of power x100". Floor 100 = a tier-1 worst-roll Common, so no gun reads 0.
## Range across the whole game: 100 -> ~1414 (tier-10 god-roll Mythic).
const SCORE_PER_TIER := 100.0
const SCORE_FLOOR := 100.0

# --------------------------------------------------------------- part rarity offsets

## Per-slot rarity offset weights (§2.2). These are SOLVED BACKWARDS from the gun-level
## targets (17.2% of guns carry a higher part, 5.3% a lower one, 1.3% two-or-more
## higher), NOT picked by feel. A gun fills ~6 slots and any one of them trips the
## grade, so the per-slot rate must be ~10x smaller than the rate you actually want.
## An earlier 28%/7% table put a higher part on 92% of guns and made the prefix noise.
const OFFSETS: Array[int] = [-2, -1, 0, 1, 2]
const OFFSET_WEIGHTS: Array[float] = [0.1, 0.8, 96.0, 2.8, 0.3]

## How much each slot's rarity counts toward the gun's quality — a barrel defines the
## gun, a sight decorates it. Sets which SINGLE part can earn a grade on its own.
const SLOT_WEIGHTS: Dictionary[GunPartDef.Slot, float] = {
	GunPartDef.Slot.BODY: 2.0,
	GunPartDef.Slot.BARREL: 2.0,
	GunPartDef.Slot.GRIP: 1.0,
	GunPartDef.Slot.MAGAZINE: 1.0,
	GunPartDef.Slot.STOCK: 1.0,
	GunPartDef.Slot.SIGHT: 0.5,
	GunPartDef.Slot.MUZZLE: 0.5,
	GunPartDef.Slot.UNDERBARREL: 0.5,
}

## How hard the damage roll nudges the grade (§2.3). Bounded at +/-0.20 — under the
## tier-1 threshold — so a god roll can never CREATE a grade and a floor roll can never
## fully cancel a +2 body. Without this term a gun reads "Outstanding" while scoring
## badly, which is exactly the confusion the grade exists to remove.
const DQ_NUDGE := 0.4

## Smallest magnitude a graded gun can report. Sits just inside the tier-1 band, so a
## gun whose parts differ from its tier ALWAYS carries a word even on the worst roll.
const MIN_GRADED := 0.01

## Derived from OFFSET_WEIGHTS, never typed in. Currently ~+0.024 (invisible), but the
## term stays: it is what stops a future table retune from silently making every gun
## read "Fine".
static var _mean_offset: float = NAN


static func mean_offset() -> float:
	if is_nan(_mean_offset):
		var total := 0.0
		var acc := 0.0
		for i in OFFSET_WEIGHTS.size():
			total += OFFSET_WEIGHTS[i]
			acc += OFFSET_WEIGHTS[i] * float(OFFSETS[i])
		_mean_offset = acc / total if total > 0.0 else 0.0
	return _mean_offset


## One slot's rarity offset. `luck` (>= 1.0) scales the upside and softens the downside,
## so high-level drops carry better parts AND insult the player less (§4.5.2).
static func roll_offset(rng: RandomNumberGenerator, luck: float = 1.0) -> int:
	var w: Array[float] = []
	var total := 0.0
	for i in OFFSETS.size():
		var weight := OFFSET_WEIGHTS[i]
		if OFFSETS[i] > 0:
			weight *= luck
		elif OFFSETS[i] < 0:
			weight /= luck
		w.append(weight)
		total += weight
	var roll := rng.randf() * total
	for i in w.size():
		roll -= w[i]
		if roll <= 0.0:
			return OFFSETS[i]
	return 0


# ------------------------------------------------------------------------ quality Q

## Slot-weighted mean of (part tier - gun rarity), filled slots only, so a 4-part gun
## is judged on its 4 parts. No roll, no centring — this is the pure part signal, and
## GunStats uses it for the part damage swing.
static func raw_q(recipe: Dictionary, base_rarity: int) -> float:
	var weighted := 0.0
	var total_weight := 0.0
	for slot: Variant in recipe:
		var def := recipe[slot] as GunPartDef
		if def == null:
			continue
		var w: float = SLOT_WEIGHTS.get(int(slot), 1.0)
		weighted += w * float(def.tier() - base_rarity)
		total_weight += w
	if total_weight <= 0.0:
		return 0.0
	return weighted / total_weight


## Graded quality: raw part signal, mean-centred, nudged by the damage roll.
##
## Two guards, and the pair of them is the whole rule:
##   **parts decide WHETHER there is a word; the roll only decides WHICH word.**
##
## 1. ZERO GATE — a gun whose parts are all exactly on-tier scores 0 and returns 0, so
##    the roll can never invent a grade. Without it the +/-0.20 nudge lifted 44% of
##    ordinary guns over the Tier-1 floor and the word appeared on 53% of drops.
## 2. SIGN CLAMP — a gun that DOES have an off-tier part always keeps a same-sign word,
##    clamped to MIN_GRADED rather than collapsing to zero. A +1 sight (q = 0.067) on a
##    floor roll would otherwise land at -0.157 and read "Used": a better-than-normal
##    part producing a negative word, inverting the signal. Collapsing it to zero
##    instead was the earlier fix, but that ate ~40% of small-delta grades and dragged
##    the rate down to 10%, well under the ~22% the offset table is tuned for.
static func compute_q(recipe: Dictionary, base_rarity: int, damage_quality: float) -> float:
	var q := raw_q(recipe, base_rarity)
	if is_zero_approx(q):
		return 0.0
	var centred := q - mean_offset()
	var nudged := centred + DQ_NUDGE * (damage_quality - 0.5)
	if signf(nudged) != signf(centred):
		return signf(centred) * MIN_GRADED
	return nudged


# ---------------------------------------------------------------------- grade words

const TIER_3 := ["Immaculate", "Pristine", "Flawless"]
const TIER_2 := ["Outstanding", "Superb", "Exceptional"]
const TIER_1 := ["Fine", "Choice", "Sharp"]
const TIER_N1 := ["Used", "Preowned", "Worn"]
const TIER_N2 := ["Rough", "Dirty", "Salvaged"]
const TIER_N3 := ["Scrapped", "Junker", "Gutter"]

## Legendary/Mythic never take an insult (§5). A sub-par legendary gets FLAVOUR, not a
## verdict — the score still tells the truth, but the gun always looks like a legend on
## the ground. "Rough Unkempt Harold" would undermine the drop it exists to create.
const LEGEND_EPITHETS := ["Fabled", "Storied", "Notorious", "Infamous", "Sovereign"]

## Rarity index at and above which the legend rules apply (5 = legendary, 6 = mythic).
const LEGEND_MIN_RARITY := 5

## Band edges on Q, positive side. Mirrored for the negative side.
const BAND_1 := 0.0
const BAND_2 := 0.20
const BAND_3 := 0.45


## The optional first word of the gun's name. "" for ~78% of guns — which is precisely
## what makes it read as a signal on the other 22%.
static func grade_word(q: float, rarity: int, word_seed: int) -> String:
	var rng := RandomNumberGenerator.new()
	rng.seed = word_seed

	if rarity >= LEGEND_MIN_RARITY:
		# Always prefixed, never negatively. A quality word means a good roll; an
		# epithet means normal-or-below.
		if q >= BAND_3:
			return _pick(TIER_3, rng)
		if q >= BAND_2:
			return _pick(TIER_2, rng)
		return _pick(LEGEND_EPITHETS, rng)

	if q >= BAND_3:
		return _pick(TIER_3, rng)
	if q >= BAND_2:
		return _pick(TIER_2, rng)
	if q > BAND_1:
		return _pick(TIER_1, rng)
	if q >= -BAND_1:
		return ""                      # the ~78% case: no word at all
	if q > -BAND_2:
		return _pick(TIER_N1, rng)
	if q > -BAND_3:
		return _pick(TIER_N2, rng)
	return _pick(TIER_N3, rng)


static func _pick(pool: Array, rng: RandomNumberGenerator) -> String:
	return String(pool[rng.randi_range(0, pool.size() - 1)])


# --------------------------------------------------------------------------- score

## One number, monotone in DPS (§4). DPS and not per-shot damage, or every sniper
## outranks every SMG on a stat that says nothing about which kills faster.
static func score(stats: Dictionary, wc: WeaponClass) -> int:
	if wc == null or wc.base_damage <= 0.0 or wc.base_fire_rate <= 0.0:
		return int(SCORE_FLOOR)
	var base_dps := wc.base_damage * wc.base_fire_rate
	var dps: float = float(stats.get(&"damage", 0.0)) * float(stats.get(&"fire_rate", 0.0))
	if dps <= 0.0:
		return int(SCORE_FLOOR)
	return roundi(SCORE_FLOOR + SCORE_PER_TIER * log(dps / base_dps) / LN_STEP)


## Player-facing damage/HP display: always round UP, never a decimal (§7.2).
## Biases every number up ~0.5, which reads generous, and guarantees a gun that deals
## some damage never displays "0".
static func display(value: float) -> int:
	return ceili(value)
