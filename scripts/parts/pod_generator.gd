class_name PodGenerator
extends RefCounted
## Mech pods, rolled like guns (Docs/ModularParts.md section 4, "Pods"; stage 7): a kind, a
## maker, a rarity and a tier from a seed, power scaled by rarity x tier as a gun's damage is,
## a grade word from the roll, and a name from the pods' own word lists -- never a gun's --
## or from the pod body's name fragment.
##
## Three sorts (PartRecord.pod_kind of a pod body says which it carries; "" carries any):
##   active_animated  its own small arm: a melee strike, a grenade throw
##   active_fixed     aims with the torso: missiles, a laser shot
##   passive          does nothing to use: shield booster, directional shield

const KINDS := {
	&"missiles": {"sort": "active_fixed", "weapon": &"rocket_launcher", "cooldown": 9.0, "shots": 4,
			"name": "Missile Pod", "desc": "Four rockets, one after another, where the torso looks."},
	&"laser": {"sort": "active_fixed", "weapon": &"sniper", "cooldown": 6.0, "shots": 1,
			"name": "Laser", "desc": "One heavy shot, straight where the torso looks."},
	&"grenade_arm": {"sort": "active_animated", "weapon": &"grenade_launcher", "cooldown": 7.0, "shots": 2,
			"name": "Grenade Arm", "desc": "An arm over the shoulder that lobs two grenades."},
	&"melee_arm": {"sort": "active_animated", "damage": 450.0, "reach": 7.0, "cooldown": 5.0,
			"name": "Strike Arm", "desc": "An arm over the shoulder that hammers a mech in reach."},
	&"shield_boost": {"sort": "passive", "shield": 0.30, "name": "Shield Booster",
			"desc": "More shield, all the time."},
	&"directional_shield": {"sort": "passive", "armor": 0.22, "name": "Brace Plate",
			"desc": "More armour, all the time."},
}
const SORTS := ["active_animated", "active_fixed", "passive"]
## The pods' own words: a gun's name never reads like these, nor these like a gun's.
const NOUNS := {
	&"missiles": ["Hive", "Swarm", "Volley", "Rookery"],
	&"laser": ["Lance", "Needle", "Glare", "Spindle"],
	&"grenade_arm": ["Lobber", "Sling", "Mortarhand", "Tosser"],
	&"melee_arm": ["Talon", "Gavel", "Ram", "Knuckle"],
	&"shield_boost": ["Aegis", "Halo", "Mantle", "Veil"],
	&"directional_shield": ["Breastwork", "Pavise", "Rampart", "Bastion"],
}
const ADJS := ["Humming", "Gantry", "Overhead", "Shouldered", "Pylon", "Stacked", "Ridge", "Crowned"]
const MAKERS := ["korr", "vex", "ash", "lumen"]


class Result:
	var seed: int
	var rarity: int
	var tier: int
	var kind: StringName
	var sort: String
	var manufacturer: String
	## The pod body it is rolled onto ("" for none yet).
	var body_id := ""
	var pod_name: String
	var grade_word := ""
	var score := 0
	var description := ""
	## damage / cooldown / shots / reach (actives), shield / armor (fractions, passives)
	var stats: Dictionary = {}

	func serialize() -> Dictionary:
		return {"seed": seed, "rarity": rarity, "tier": tier, "kind": String(kind), "body": body_id}

	func is_active() -> bool:
		return sort != "passive"


static func kinds() -> Array:
	var out := KINDS.keys()
	out.sort()
	return out


## The kinds a pod body carries: its pod_kind's sort, or every kind for a body that says none.
static func kinds_for(body: PartRecord) -> Array:
	var out := []
	for k in kinds():
		if body == null or body.pod_kind == "" or body.pod_kind == String(KINDS[k].sort):
			out.append(k)
	return out


## Roll a pod. `rarity` -1 rolls one as guns do; `kind` &"" rolls one the body carries.
static func generate(gen_seed: int, rarity: int = -1, tier: int = 1, kind: StringName = &"",
		body: PartRecord = null) -> Result:
	var rng := RandomNumberGenerator.new()
	rng.seed = gen_seed
	var res := Result.new()
	res.seed = gen_seed
	# Always rolled, so what follows draws the same numbers whether a rarity is given or
	# not: a pod saved by its seed and rarity comes back as it was.
	var rolled := _roll_rarity(rng)
	res.rarity = clampi(rarity, 1, 6) if rarity > 0 else rolled
	res.tier = maxi(tier, 1)
	var allowed := kinds_for(body)
	var drawn: StringName = allowed[rng.randi_range(0, allowed.size() - 1)]   # drawn either way, as the rarity
	res.kind = kind if KINDS.has(kind) and kind in allowed else drawn
	var k: Dictionary = KINDS[res.kind]
	res.sort = String(k.sort)
	res.description = String(k.desc)
	res.manufacturer = body.manufacturer if body != null else MAKERS[rng.randi_range(0, MAKERS.size() - 1)]
	res.body_id = body.id if body != null else ""
	# One power roll, then a trade of strength against cooldown at a constant product.
	var q := rng.randf()
	var power := lerpf(1.0, 1.28, q) * Rarity.damage_mult(res.rarity) * Tier.power_mult(res.tier)
	var trade := lerpf(0.8, 1.25, rng.randf())
	if res.sort == "passive":
		for stat in ["shield", "armor"]:
			if k.has(stat):
				res.stats[stat] = float(k[stat]) * lerpf(1.0, 1.28, q) * (1.0 + 0.08 * (res.rarity - 1))
	else:
		res.stats["cooldown"] = float(k.cooldown) / trade
		res.stats["power"] = power * trade
		res.stats["shots"] = int(k.get("shots", 1))
		if k.has("damage"):
			res.stats["damage"] = float(k.damage) * power * trade
			res.stats["reach"] = float(k.reach)
	res.grade_word = GunQuality.grade_word((q - 0.5) * 0.9, res.rarity, res.seed)
	res.score = roundi(GunQuality.SCORE_FLOOR + GunQuality.SCORE_PER_TIER * log(power) / GunQuality.LN_STEP)
	res.pod_name = _make_name(res, rng, body)
	return res


static func deserialize(d: Dictionary, cat: PartCatalog = null) -> Result:
	var body: PartRecord = cat.get_part(String(d.get("body", ""))) if cat != null else null
	return generate(int(d.get("seed", 0)), int(d.get("rarity", 1)), int(d.get("tier", 1)),
			StringName(d.get("kind", "")), body)


## Grade, an adjective, a noun: the body's name fragment if it has one, else the kind's.
static func _make_name(res: Result, rng: RandomNumberGenerator, body: PartRecord) -> String:
	var words := PackedStringArray()
	if res.grade_word != "":
		words.append(res.grade_word)
	words.append(ADJS[rng.randi_range(0, ADJS.size() - 1)])
	if body != null and body.name_fragment != "":
		words.append(body.name_fragment)
	else:
		var nouns: Array = NOUNS[res.kind]
		words.append(nouns[rng.randi_range(0, nouns.size() - 1)])
	return " ".join(words)


static func _roll_rarity(rng: RandomNumberGenerator) -> int:
	var total := 0.0
	for w in GunGenerator.RARITY_WEIGHTS:
		total += w
	var r := rng.randf() * total
	for i in GunGenerator.RARITY_WEIGHTS.size():
		r -= GunGenerator.RARITY_WEIGHTS[i]
		if r <= 0.0:
			return i + 1
	return 1
