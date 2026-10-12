class_name GunFireMode
extends RefCounted
## How a gun fires (COMBAT_DESIGN 7.9): its trigger, its shotgun pattern, and the shot
## it charges when the trigger is held. Rolled from the gun's seed on a stream of its
## own, so a save or a peer rebuilds it and no other roll moved.
##
##   semi    one round a press, never faster than the fire rate; a press a little early
##           is kept and fired when the gun is ready
##   auto    rounds while the trigger is held, at the fire rate
##   burst   2-5 rounds a press, fast inside the burst, then a gap; held, burst after
##           burst. Over a burst and its gap it fires at the fire rate, so a burst gun is
##           no stronger than an automatic of its numbers -- only shaped differently.
##
## A shotgun of a kind fires PELLETS: a spread of rays that share its damage, each full
## out to `near` metres and down to `falloff` of it by `far`. The light kind's spread is
## wide and its reach short; the heavy's tighter and longer.
##
## A semi or burst gun may CHARGE (rarer up the colours): tap and it fires as it always
## does; hold past CHARGE_START and it stops firing and charges, and let go when full
## for one of
##   overcharge   a single shot at OVERCHARGE_MULT damage, for OVERCHARGE_COST shots
##   hyper        a burst of twice its count, at HYPER_RATE times its burst speed
##   long         a long burst, LONG_BURST rounds
## each with an effect on what it hits: shield break (a shield up is taken whole),
## armor break (armor on top is taken whole), or knockback (a stumble KNOCK_MULT as hard).
## Let go early and nothing extra fires.
##
## A gun no one gave a kind (an enemy's, a vehicle's) has none of this: `roll` returns
## an empty dictionary and it fires as it always has.

const SEMI := &"semi"
const AUTO := &"auto"
const BURST := &"burst"

const OVERCHARGE := &"overcharge"
const HYPER := &"hyper"
const LONG := &"long"
const SHIELD_BREAK := &"shield_break"
const ARMOR_BREAK := &"armor_break"
const KNOCKBACK := &"knockback"

const OVERCHARGE_MULT := 3.0
const OVERCHARGE_COST := 3
const HYPER_RATE := 1.6
const LONG_BURST := 10
const KNOCK_MULT := 3.0
## Held this long, a press becomes a charge.
const CHARGE_START := 0.3
## A press this early is kept until the gun can fire.
const SEMI_BUFFER := 0.15
## Chance a semi or burst gun charges, by colour (white .. mythic).
const CHARGE_CHANCE: Array[float] = [0.0, 0.1, 0.2, 0.35, 0.5, 0.7]

## Trigger weights per class and kind.
const MODES := {
	&"pistol": {&"light": {SEMI: 0.5, AUTO: 0.3, BURST: 0.2}, &"heavy": {SEMI: 1.0}},
	&"revolver": {&"light": {SEMI: 1.0}, &"heavy": {SEMI: 1.0}},
	&"smg": {&"light": {AUTO: 0.7, BURST: 0.3}, &"heavy": {AUTO: 0.5, BURST: 0.5}},
	&"rifle": {&"light": {AUTO: 0.5, BURST: 0.35, SEMI: 0.15}, &"heavy": {SEMI: 0.5, BURST: 0.5}},
	&"lmg": {&"light": {AUTO: 1.0}, &"heavy": {AUTO: 1.0}},
	&"dmr": {&"light": {SEMI: 1.0}, &"heavy": {SEMI: 1.0}},
	&"sniper": {&"light": {SEMI: 1.0}, &"heavy": {SEMI: 1.0}},
	&"shotgun": {&"light": {AUTO: 0.6, BURST: 0.4}, &"heavy": {SEMI: 1.0}},
}
## Burst counts and their weights.
const BURST_COUNTS := {3: 0.5, 2: 0.2, 4: 0.2, 5: 0.1}
## Pellets per kind: [count lo, hi, spread deg lo, hi, near lo, hi, far lo, hi, falloff].
const PELLETS := {
	&"light": [6, 8, 8.0, 12.0, 3.0, 5.0, 10.0, 14.0, 0.15],
	&"heavy": [8, 10, 4.0, 7.0, 6.0, 9.0, 16.0, 22.0, 0.25],
}


static func roll(gun_seed: int, rarity: int, wc: WeaponClass) -> Dictionary:
	if wc == null or wc.is_ordnance or wc.archetype == &"" or not MODES.has(wc.id):
		return {}
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([gun_seed, "fire_mode"])
	var kind := wc.archetype
	var fm := {"mode": _weighted(rng, MODES[wc.id][kind])}
	if fm.mode == BURST:
		fm["burst"] = int(_weighted(rng, BURST_COUNTS))
		# How much faster than the fire rate the rounds come inside a burst.
		fm["burst_speed"] = rng.randf_range(2.0, 3.2)
	if wc.id == &"shotgun":
		var p: Array = PELLETS[kind]
		fm["pellets"] = rng.randi_range(int(p[0]), int(p[1]))
		fm["pellet_spread"] = rng.randf_range(float(p[2]), float(p[3]))
		fm["near"] = rng.randf_range(float(p[4]), float(p[5]))
		fm["far"] = rng.randf_range(float(p[6]), float(p[7]))
		fm["falloff"] = float(p[8])
	if fm.mode != AUTO and rng.randf() < CHARGE_CHANCE[clampi(rarity - 1, 0, 5)]:
		var kinds := [OVERCHARGE, HYPER] if fm.mode == BURST else [OVERCHARGE, LONG]
		fm["charge"] = kinds[rng.randi() % kinds.size()]
		fm["effect"] = [SHIELD_BREAK, ARMOR_BREAK, KNOCKBACK][rng.randi() % 3]
		fm["charge_time"] = rng.randf_range(0.7, 1.1)
	return fm


static func _weighted(rng: RandomNumberGenerator, table: Dictionary) -> Variant:
	var total := 0.0
	for k in table:
		total += float(table[k])
	var r := rng.randf() * total
	for k in table:
		r -= float(table[k])
		if r <= 0.0:
			return k
	return table.keys()[0]


## The seconds from the last round of a burst to the next burst's first, so a burst
## and its gap together run at the fire rate.
static func burst_gap(fm: Dictionary, fire_rate: float) -> float:
	var n := int(fm.get("burst", 3))
	var inside := 1.0 / maxf(fire_rate * float(fm.get("burst_speed", 2.5)), 0.1)
	return maxf(float(n) / maxf(fire_rate, 0.1) - float(n - 1) * inside, 0.12)


## A pellet's share of damage at `dist` metres: full to near, falloff by far.
static func falloff(fm: Dictionary, dist: float) -> float:
	var near := float(fm.get("near", 1e9))
	var far := float(fm.get("far", 1e9))
	var low := float(fm.get("falloff", 1.0))
	return lerpf(1.0, low, clampf((dist - near) / maxf(far - near, 0.01), 0.0, 1.0))


## The card's lines: the trigger, the pattern, the charge.
static func describe(fm: Dictionary, fire_rate: float) -> PackedStringArray:
	var out := PackedStringArray()
	if fm.is_empty():
		return out
	match StringName(fm.mode):
		SEMI:
			out.append("Semi-auto")
		AUTO:
			out.append("Full-auto")
		BURST:
			out.append("Burst of %d (%.0f/s in the burst)" % [int(fm.burst),
					fire_rate * float(fm.burst_speed)])
	if fm.has("pellets"):
		out.append("%d pellets, %.0f° spread; full to %.0f m, %d%% by %.0f m" % [int(fm.pellets),
				float(fm.pellet_spread), float(fm.near), roundi(float(fm.falloff) * 100.0),
				float(fm.far)])
	if fm.has("charge"):
		var what: String = {OVERCHARGE: "one shot at x%d" % roundi(OVERCHARGE_MULT),
				HYPER: "a hyper burst", LONG: "a long burst of %d" % LONG_BURST}[StringName(fm.charge)]
		var eff: String = {SHIELD_BREAK: "breaks a shield", ARMOR_BREAK: "breaks armor",
				KNOCKBACK: "knocks them flying"}[StringName(fm.effect)]
		out.append("» Hold fire — %s that %s" % [what, eff])
	return out
