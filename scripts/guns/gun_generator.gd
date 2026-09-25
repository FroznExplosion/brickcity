class_name GunGenerator
extends RefCounted
## Seed -> deterministic gun. Same (library, seed) always yields the same gun,
## so multiplayer/saves only ever move a seed or a small id-based recipe dict.

const Slot := GunPartDef.Slot

## Slots every gun must fill (BODY implied).
const REQUIRED_SLOTS: Array[GunPartDef.Slot] = [
	Slot.BARREL, Slot.GRIP, Slot.MAGAZINE,
]
## Optional slots and their base attach chance; rarity raises the odds.
const OPTIONAL_SLOTS: Dictionary[GunPartDef.Slot, float] = {
	Slot.STOCK: 0.75,
	Slot.SIGHT: 0.35,
	Slot.MUZZLE: 0.30,
	Slot.UNDERBARREL: 0.20,
}

## Drop-table weights: common..mythic (6 tiers). Rarer = smaller weight.
## Damage multipliers live in our GunStats (INTEGRATION §2), NOT here.
const RARITY_WEIGHTS: Array[float] = [55.0, 25.0, 12.0, 5.0, 2.5, 0.5]
const RARITY_NAMES: Array[String] = ["Common", "Uncommon", "Rare", "Unique", "Legendary", "Mythic"]

## Fallback receiver nouns, used ONLY when a BODY def has no name_fragment.
## There is deliberately no adjective list: every word in a gun name is derived
## (QUALITY_NAMING §3). A random adjective sitting next to a real grade word
## ("Outstanding") makes both unreadable — that is why "Rusty"/"Gilded" were cut.
const NAME_NOUNS: Array[String] = [
	"Mongrel", "Sermon", "Postulate", "Vendetta", "Lodestar",
	"Argument", "Hangnail", "Dividend", "Comet", "Warrant",
]


class Result:
	var seed: int
	var rarity: int
	var recipe: Dictionary                       # Slot -> GunPartDef
	var stats: Dictionary[StringName, float]
	var gun_name: String
	## Optional first name word from part-rarity quality (QUALITY_NAMING §3.1).
	## "" for ~78% of guns, which is what makes it read as a signal when present.
	var grade_word: String = ""
	## Optional second name word from the barrel's element. "" when non-elemental.
	var element_word: String = ""
	## Slot-weighted part quality (QUALITY_NAMING §2.3). Drives grade_word.
	var quality: float = 0.0
	## The damage roll (0..1) behind the score. Kept for the comparison UI.
	var damage_quality: float = 0.0
	## One-number power read (QUALITY_NAMING §4). 100 pts per TIER; 100 at tier 1,
	## ~1207 for a tier-10 god-roll Mythic.
	var score: int = 0
	## Part-offset luck this gun was rolled with. Recorded so a save can reproduce it.
	var luck: float = 1.0
	## Set when this is an authored legendary (QUALITY_NAMING §4.6), else &"".
	var legendary_id: StringName = &""
	## The "red text" line. Only authored legendaries have one.
	var flavor: String = ""
	var weapon_class: WeaponClass
	var tier: int = 1
	var active_effects: PackedStringArray = PackedStringArray()   # aggregate, slot-agnostic
	var merges: Array[MergeRule] = []                              # active synergy bonuses

	## Compact, save/network-friendly form.
	func serialize() -> Dictionary:
		var ids: Dictionary[int, StringName] = {}
		for slot: int in recipe:
			ids[slot] = (recipe[slot] as GunPartDef).id
		var class_id: StringName = weapon_class.id if weapon_class != null else &"pistol"
		return { "seed": seed, "rarity": rarity, "class": class_id, "tier": tier, "parts": ids }


## `forced_rarity` (1..6) skips the internal roll — LootRoller owns the drop table, so
## anything spawned by the world passes its rarity in rather than re-rolling here.
## `luck` biases PART rarity offsets only; the gun's own rarity is already decided.
static func generate(library: GunPartLibrary, gen_seed: int = -1,
		weapon_class: WeaponClass = null, tier: int = 1,
		forced_rarity: int = -1, luck: float = 1.0) -> Result:
	var rng := RandomNumberGenerator.new()
	rng.seed = gen_seed if gen_seed != -1 else randi()

	var res := Result.new()
	res.seed = rng.seed
	res.weapon_class = weapon_class if weapon_class != null else WeaponClass.builtin(&"pistol")
	res.tier = tier
	res.rarity = clampi(forced_rarity, 1, 6) if forced_rarity > 0 else _roll_rarity(rng)
	res.luck = luck
	res.recipe = {}

	# Body first: it decides the archetype and biases the manufacturer.
	var body := _pick(library, Slot.BODY, res.rarity, &"", res.recipe, rng, luck)
	if body == null:
		push_error("GunGenerator: library has no BODY parts for rarity %d." % res.rarity)
		return res
	res.recipe[Slot.BODY] = body
	var brand := body.manufacturer

	for slot in REQUIRED_SLOTS:
		# 65% chance to stay on-brand per slot -> coherent but mixable guns.
		var want_brand := brand if rng.randf() < 0.65 else &""
		var def := _pick(library, slot, res.rarity, want_brand, res.recipe, rng, luck)
		if def != null:
			res.recipe[slot] = def

	for slot: GunPartDef.Slot in OPTIONAL_SLOTS:
		var chance: float = OPTIONAL_SLOTS[slot] + 0.08 * float(res.rarity - 1)
		if rng.randf() > chance:
			continue
		var def := _pick(library, slot, res.rarity, &"", res.recipe, rng, luck)
		if def != null:
			res.recipe[slot] = def

	res.active_effects = GunEffects.stack(GunEffects.collect(res.recipe, res.rarity))
	res.merges = MergeRule.detect(res.active_effects)
	res.stats = GunStats.compute(res.recipe, res.rarity, res.weapon_class, res.tier, res.seed)
	_finish(res, rng)
	return res


## Quality, score and name. Shared by generate() and deserialize() so a reassembled gun
## reports the identical grade word and score as the one that dropped.
static func _finish(res: Result, rng: RandomNumberGenerator) -> void:
	# GunStats derives damage quality from the gun seed on its own stream, so re-derive
	# it the same way rather than threading it through — same seed, same number.
	var dq_rng := RandomNumberGenerator.new()
	dq_rng.seed = res.seed
	res.damage_quality = dq_rng.randf()

	res.quality = GunQuality.compute_q(res.recipe, res.rarity, res.damage_quality)
	res.grade_word = GunQuality.grade_word(res.quality, res.rarity, res.seed)
	res.element_word = _element_word(res)
	res.score = GunQuality.score(res.stats, res.weapon_class)
	res.gun_name = _make_name(res, rng)


## Element name slot. Omitted entirely on a non-elemental gun, which is what makes
## "Burning" mean something when it does appear.
static func _element_word(res: Result) -> String:
	var barrel := res.recipe.get(Slot.BARREL) as GunBarrelDef
	if barrel == null or barrel.element_ratio <= 0.01:
		return ""
	match barrel.barrel_family:
		&"blaster", &"beam": return "Searing"
		&"hybrid": return "Burning"
		_: return ""


## An authored legendary (QUALITY_NAMING §4.6). Same pipeline as any world drop — the
## def only overrides WHICH gun: fixed class, one forced exclusive barrel, an authored
## name, and a signature stat skew applied last.
##
## Every OTHER slot still rolls, which is the whole point: the dq roll and the open-slot
## part offsets mean there is a good one and a bad one of each, so farming the same boss
## twice is worth doing. None of that needed a special case.
static func generate_legendary(library: GunPartLibrary, gen_seed: int,
		leg: LegendaryDef, tier: int, luck: float = 1.0) -> Result:
	if leg == null:
		return generate(library, gen_seed, null, tier, 5, luck)

	var wc := WeaponClass.builtin(leg.weapon_class_id)
	var res := generate(library, gen_seed, wc, tier, 5, luck)

	var barrel := _exclusive_barrel(library, leg.id)
	if barrel != null:
		res.recipe[Slot.BARREL] = barrel
		# The recipe changed, so everything downstream of it must be recomputed —
		# effects, merges, stats, quality, name and score all read the recipe.
		res.active_effects = GunEffects.stack(GunEffects.collect(res.recipe, res.rarity))
		res.merges = MergeRule.detect(res.active_effects)
		res.stats = GunStats.compute(res.recipe, res.rarity, wc, tier, res.seed)

	for key: StringName in leg.signature:
		res.stats[key] = res.stats.get(key, 0.0) * leg.signature[key]

	var rng := RandomNumberGenerator.new()
	rng.seed = res.seed
	_finish(res, rng)

	res.legendary_id = leg.id
	res.flavor = leg.flavor
	# Authored name wins outright: no element, barrel or receiver word (§5).
	# The grade word survives, so "Outstanding Sermon" is reachable.
	res.gun_name = ("%s %s" % [res.grade_word, leg.display_name]).strip_edges()
	return res


static func _exclusive_barrel(library: GunPartLibrary, leg_id: StringName) -> GunPartDef:
	for def in library.parts:
		if def != null and def.exclusive_to == leg_id and def.slot == Slot.BARREL:
			return def
	return null


## Rebuild a Result from a serialized dict (see Result.serialize()).
static func deserialize(library: GunPartLibrary, data: Dictionary) -> Result:
	var res := Result.new()
	res.seed = int(data.get("seed", 0))
	res.rarity = int(data.get("rarity", 1))
	res.tier = int(data.get("tier", 1))
	res.weapon_class = WeaponClass.builtin(StringName(data.get("class", &"pistol")))
	res.recipe = {}
	var ids: Dictionary = data.get("parts", {})
	for slot in ids:
		var def := library.get_by_id(ids[slot])
		if def != null:
			res.recipe[int(slot)] = def
	res.active_effects = GunEffects.stack(GunEffects.collect(res.recipe, res.rarity))
	res.merges = MergeRule.detect(res.active_effects)
	res.stats = GunStats.compute(res.recipe, res.rarity, res.weapon_class, res.tier, res.seed)
	res.luck = float(data.get("luck", 1.0))
	# Re-derive name/grade/score rather than trusting the payload: they are functions
	# of the recipe, so a save that predates a word-table change stays correct.
	var name_rng := RandomNumberGenerator.new()
	name_rng.seed = res.seed
	_finish(res, name_rng)
	return res


static func _roll_rarity(rng: RandomNumberGenerator) -> int:
	var total := 0.0
	for w in RARITY_WEIGHTS:
		total += w
	var roll := rng.randf() * total
	for i in RARITY_WEIGHTS.size():
		roll -= RARITY_WEIGHTS[i]
		if roll <= 0.0:
			return i + 1
	return 1


## Weighted pick that (a) aims at a rolled rarity OFFSET from the gun's own rarity
## (QUALITY_NAMING §2.2 — this is what produces the grade word), and (b) skips parts
## whose effect conflicts with already-placed parts (MANUFACTURER §4).
##
## The offset is an AIM, not a guarantee: if no part is authored at the target tier the
## target walks back toward the gun's rarity one step at a time. min/max_rarity remains
## a hard legality gate and always wins.
static func _pick(library: GunPartLibrary, slot: GunPartDef.Slot, rarity: int,
		want_brand: StringName, placed: Dictionary, rng: RandomNumberGenerator,
		luck: float = 1.0) -> GunPartDef:
	var offset := GunQuality.roll_offset(rng, luck)
	var target := clampi(rarity + offset, 1, 6)

	while true:
		var pool := _pool_at(library, slot, rarity, target, want_brand)
		if not pool.is_empty():
			return _filtered_pick(pool, placed, rng)
		if target == rarity:
			break
		target += 1 if target < rarity else -1
	return null


## Candidates legal for this gun that are AUTHORED at `target`. Legality is judged
## against the gun's rarity, not the target, so an offset can never smuggle in a part
## the gun was never allowed to carry.
static func _pool_at(library: GunPartLibrary, slot: GunPartDef.Slot, rarity: int,
		target: int, want_brand: StringName) -> Array[GunPartDef]:
	var out: Array[GunPartDef] = []
	for def in library.candidates(slot, rarity, want_brand):
		if def.exclusive_to == &"" and def.tier() == target:
			out.append(def)
	return out


static func _filtered_pick(pool: Array[GunPartDef], placed: Dictionary,
		rng: RandomNumberGenerator) -> GunPartDef:
	var placed_defs: Array = placed.values()
	var filtered: Array[GunPartDef] = []
	for c in pool:
		if GunEffects.compatible(c, placed_defs):
			filtered.append(c)
	if filtered.is_empty():
		filtered = pool
	return GunPartLibrary.pick_weighted(filtered, rng)


## Name schema (QUALITY_NAMING §3): [Grade] [Element] [Barrel] [Receiver].
## Every slot is DERIVED — grade from part rarity, element from the barrel, and the
## two fragments from the parts themselves. Grade and element are optional and simply
## vanish, which is what makes a grade word mean something when it does appear.
## Authoring contract: BODY fragments are NOUNS, BARREL fragments are ADJECTIVES.
## Manufacturer is deliberately NOT a word here — it rides in the receiver fragment
## and in the UI badge; the name is already 3-4 words.
static func _make_name(res: Result, rng: RandomNumberGenerator) -> String:
	var words: PackedStringArray = []

	if res.grade_word != "":
		words.append(res.grade_word)
	if res.element_word != "":
		words.append(res.element_word)

	var barrel: GunPartDef = res.recipe.get(Slot.BARREL)
	if barrel != null and barrel.name_fragment != "":
		words.append(barrel.name_fragment)

	var body: GunPartDef = res.recipe.get(Slot.BODY)
	if body != null and body.name_fragment != "":
		words.append(body.name_fragment)
	else:
		words.append(NAME_NOUNS[rng.randi_range(0, NAME_NOUNS.size() - 1)])

	return " ".join(words)
