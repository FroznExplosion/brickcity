class_name ShieldGenerator
extends RefCounted
## Procedural shields — the third loot category, on the identical rarity / tier / roll /
## score pipeline as guns (QUALITY_NAMING §1, §4).
##
## A shield has no fire rate, so it cannot reuse GunStats. What it DOES reuse is the
## thing that matters: **capacity is its power axis**, scaled by `rarity x tier` exactly
## as gun damage is, and scored with the same `100 points per tier` formula. That makes a
## shield's score directly comparable to a gun's — both read as "tiers of power x100".
##
## Shields feed HealthPool as a `shield` DefenseLayer, which already exists and already
## sits above `health` in the layer order.

## Base capacity for the reference class, chosen against the §7.2 HP anchor: a tier-1
## standard enemy has 113 HP, so a ~90-capacity shield is a little under one mook's worth
## of damage absorbed. Big enough to matter, small enough that it is not a second life.
const BASE_CAPACITY := 90.0

## Same spread budget shape as guns (§4.3): one power roll, then a DPS-neutral trade.
## `cap_mult` is the power roll; `recharge` trades against capacity at constant product,
## so a fast-recharge shield is not strictly better than a big one.
const CAP_WINDOW_LO := 1.0
const CAP_WINDOW_HI := 1.28
const TRADE_LO := 0.70
const TRADE_HI := 1.40

const _PRESETS := {
	&"standard": {"name": "Standard", "cap": 1.00, "delay": 3.0, "rate": 0.30,
		"desc": "No tricks. Recharges after a short pause."},
	&"brick":    {"name": "Brick", "cap": 1.75, "delay": 6.0, "rate": 0.14,
		"desc": "Huge pool, slow to come back."},
	&"sprint":   {"name": "Sprint", "cap": 0.55, "delay": 1.2, "rate": 0.75,
		"desc": "Small pool, back almost immediately."},
	&"turtle":   {"name": "Turtle", "cap": 2.40, "delay": 11.0, "rate": 0.10,
		"desc": "Enormous pool. Once it is gone, it is gone for a while."},
	&"spike":    {"name": "Spike", "cap": 0.80, "delay": 3.5, "rate": 0.28,
		"desc": "Returns a share of melee damage to the attacker."},
}


class Result:
	var seed: int
	var rarity: int
	var tier: int
	var shield_class: StringName
	var class_name_text: String
	var shield_name: String
	var grade_word: String = ""
	var score: int = 0
	var description: String = ""
	## capacity / recharge_delay / recharge_rate (fraction of capacity per second)
	var stats: Dictionary[StringName, float] = {}

	func serialize() -> Dictionary:
		return {"seed": seed, "rarity": rarity, "tier": tier, "class": shield_class}


static func class_ids() -> Array:
	return _PRESETS.keys()


static func generate(gen_seed: int, rarity: int, tier: int,
		class_id: StringName = &"", luck: float = 1.0) -> Result:
	var rng := RandomNumberGenerator.new()
	rng.seed = gen_seed if gen_seed != -1 else randi()

	var res := Result.new()
	res.seed = rng.seed
	res.rarity = clampi(rarity, 1, 6)
	res.tier = maxi(tier, 1)

	var ids := class_ids()
	res.shield_class = class_id if _PRESETS.has(class_id) else ids[rng.randi_range(0, ids.size() - 1)]
	var p: Dictionary = _PRESETS[res.shield_class]
	res.class_name_text = p["name"]
	res.description = p["desc"]

	# Power roll, then the capacity/recharge trade at constant product.
	var cq := rng.randf()
	var cap_mult := lerpf(CAP_WINDOW_LO, CAP_WINDOW_HI, cq)
	var trade := lerpf(TRADE_LO, TRADE_HI, rng.randf())

	var capacity := BASE_CAPACITY * float(p["cap"]) * cap_mult / trade
	capacity *= Rarity.damage_mult(res.rarity) * Tier.power_mult(res.tier)

	res.stats = {
		&"capacity": capacity,
		# Lower is better, so the trade inverts: a shield that gave up capacity gets its
		# delay cut by the same factor.
		&"recharge_delay": float(p["delay"]) / trade,
		&"recharge_rate": float(p["rate"]) * trade,
	}

	# Shields have no parts yet, so quality comes from the roll alone. When shield parts
	# land, swap this for GunQuality.compute_q over the shield recipe and the grade word
	# starts meaning the same thing it does on a gun.
	var q := (cq - 0.5) * 0.9
	res.grade_word = GunQuality.grade_word(q, res.rarity, res.seed)
	res.score = score_of(capacity, res.shield_class)
	res.shield_name = ("%s %s Shield" % [res.grade_word, res.class_name_text]).strip_edges()
	return res


## Same 100-points-per-tier scale as guns, so the two categories compare directly.
static func score_of(capacity: float, class_id: StringName) -> int:
	var p: Dictionary = _PRESETS.get(class_id, _PRESETS[&"standard"])
	var base: float = BASE_CAPACITY * float(p["cap"])
	if base <= 0.0 or capacity <= 0.0:
		return int(GunQuality.SCORE_FLOOR)
	return roundi(GunQuality.SCORE_FLOOR
		+ GunQuality.SCORE_PER_TIER * log(capacity / base) / GunQuality.LN_STEP)


## The DefenseLayer this shield contributes to a HealthPool. Sits above `health`.
static func to_layer(res: Result) -> DefenseLayer:
	var l := DefenseLayer.new()
	l.layer_type = &"shield"
	l.max_value = res.stats.get(&"capacity", 0.0)
	l.display_color = Color(0.4, 0.7, 1.0)
	return l
