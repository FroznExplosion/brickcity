extends SceneTree

## The combat design's numbers (Docs/Weapons/COMBAT_DESIGN.md sections 1-3, v2), checked
## against the guns the generator actually rolls.
##
##     godot --headless --path . --script res://tools/combat_numbers_probe.gd
##
## A gun's per-shot damage trades against its fire rate, so "a Unique rifle" is the MEDIAN
## of many rolls, taken BEFORE modifiers (the build adds to it).
##
##   power curve   +25% a tier, guns and enemies alike
##   the base      every type and kind, at Unique, against the medium enemy (shield 0.6,
##                 armor 1.2, health 1 -- EnemyProfiles), through the real DamageSystem:
##                 its shots to kill the health alone and the whole enemy, body shots and
##                 crits -- the Armory Ledger's Time to kill tab. The same at every tier on
##                 level.
##   the unit      WeaponClass.DMG_UNIT puts a median Unique on its target, just over it
##   the colour    the whole range is about half a tier
##   the roll      the hidden DPS roll inside one colour is narrow (3.1)
##   slots         a gun carries 1 / 2 / 3 / 4 / 4 / 4 modifiers by colour, and a higher
##                 colour's modifiers roll higher
##   score         a tier is 100 points

## [class, kind, health body, health crit, whole body, whole crit] -- the Armory Ledger.
const TARGETS := [
	[&"pistol", &"light", 5, 3, 14, 8], [&"pistol", &"heavy", 2, 1, 6, 3],
	[&"revolver", &"light", 5, 2, 14, 7], [&"revolver", &"heavy", 2, 1, 6, 3],
	[&"smg", &"light", 11, 6, 31, 17], [&"smg", &"heavy", 7, 4, 19, 10],
	[&"rifle", &"light", 9, 5, 24, 13], [&"rifle", &"heavy", 6, 3, 17, 9],
	[&"lmg", &"light", 8, 4, 22, 12], [&"lmg", &"heavy", 7, 4, 18, 10],
	[&"dmr", &"light", 3, 2, 7, 4], [&"dmr", &"heavy", 2, 1, 4, 2],
	[&"sniper", &"light", 1, 1, 3, 2], [&"sniper", &"heavy", 1, 1, 2, 1],
	[&"shotgun", &"light", 1, 1, 3, 2], [&"shotgun", &"auto", 3, 2, 7, 4], [&"shotgun", &"heavy", 1, 1, 2, 2],
]
## Unique: the colour every gun's base is judged at.
const UNIQUE := 4

const SAMPLES := 301

var _pass := 0
var _fail := 0
var _lib: GunPartLibrary


func _init() -> void:
	print("combat numbers probe")
	_lib = GunPlaceholderParts.build_library()
	_run()
	print("combat numbers probe: %d ok, %d FAIL" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _gun(class_id: StringName, rarity: int, tier: int, i: int, kind := &"") -> GunGenerator.Result:
	return GunGenerator.generate(_lib, 1000 + i * 7919, WeaponClass.builtin(class_id).with_kind(kind), tier, rarity)


## Median per-shot damage (before modifiers), DPS and score of `class_id` guns.
func _median(class_id: StringName, rarity: int, tier: int, kind := &"") -> Dictionary:
	var dmg: Array[float] = []
	var dps: Array[float] = []
	var score: Array[float] = []
	var wc := WeaponClass.builtin(class_id).with_kind(kind)
	for i in SAMPLES:
		var res := _gun(class_id, rarity, tier, i, kind)
		var base := GunStats.compute(res.recipe, res.rarity, wc, tier, res.seed)
		dmg.append(float(base[&"damage"]))
		dps.append(float(base[&"damage"]) * float(base[&"fire_rate"]))
		score.append(float(GunQuality.score(base, wc)))
	dmg.sort()
	dps.sort()
	score.sort()
	return {"damage": dmg[SAMPLES / 2], "score": score[SAMPLES / 2],
			"dps_lo": dps[SAMPLES / 20], "dps_hi": dps[SAMPLES - 1 - SAMPLES / 20]}


## Shots of `dmg` (crits of `crit` when `crit` > 1) that kill a fresh `profile` enemy at
## `level`, through the real DamageSystem.
func _kills(profile: StringName, level: int, dmg: float, crit: float) -> int:
	var holder := Node.new()
	root.add_child(holder)
	var pool := HealthPool.new()
	pool.name = "HealthPool"
	holder.add_child(pool)
	EnemyProfiles.apply(pool, profile, level)
	var n := 0
	while not pool.is_dead() and n < 200:
		var pk := DamagePacket.new(dmg, null, null)
		pk.crit = crit > 1.0
		pk.crit_multiplier = crit
		DamageSystem.resolve(pk, holder)
		n += 1
	holder.free()
	return n


func _run() -> void:
	# --- the curve --------------------------------------------------------------
	var step := Tier.power_mult(2) / Tier.power_mult(1)
	var hp_step := LootRoller.enemy_hp(&"trash", 6) / LootRoller.enemy_hp(&"trash", 5)
	_ok("a tier is +25% for guns", is_equal_approx(step, 1.25), "%.3f" % step)
	_ok("and for enemies", is_equal_approx(hp_step, 1.25), "%.3f" % hp_step)
	_ok("a medium enemy's health is one melee, the loot table's light enemy",
			is_equal_approx(CombatScale.melee(1), LootRoller.enemy_hp(&"trash", 1)))

	# --- the base: every type and kind against the medium enemy -----------------------
	var unit_lo := INF
	var unit_hi := 0.0
	for row in TARGETS:
		var cls: StringName = row[0]
		var kind: StringName = row[1]
		var wc := WeaponClass.builtin(cls).with_kind(kind)
		var crit := wc.crit_mult
		var name := "%s (%s)" % [wc.kind_name(), kind]
		var got := []
		var same := true
		for lvl in [1, 5, 10]:
			var d: float = _median(cls, UNIQUE, lvl, kind).damage
			var counts := [_kills(&"light", lvl, d, 1.0), _kills(&"light", lvl, d, crit),
					_kills(&"medium", lvl, d, 1.0), _kills(&"medium", lvl, d, crit)]
			if lvl == 1:
				got = counts
				var u := d / (CombatScale.melee(1) * (wc.base_damage / WeaponClass.DMG_UNIT))
				unit_lo = minf(unit_lo, u)
				unit_hi = maxf(unit_hi, u)
			elif counts != got:
				same = false
		var want := [row[2], row[3], row[4], row[5]]
		_ok("%s: health %d body / %d crit, whole medium %d / %d" % [name, row[2], row[3], row[4], row[5]],
				got == want, "got %s" % [got])
		_ok("  and the same at tiers 5 and 10", same)
	_ok("a median Unique sits on its target, just over it (DMG_UNIT)", unit_lo >= 1.0 and unit_hi <= 1.04,
			"%.3f-%.3f of target" % [unit_lo, unit_hi])

	# --- the colour -----------------------------------------------------------------
	var half := log(Rarity.damage_mult(6)) / log(Tier.TIER_STEP)
	_ok("the whole colour range is about half a tier", absf(half - 0.5) < 0.05, "%.2f" % half)
	_ok("mythic hits as hard as legendary", is_equal_approx(Rarity.damage_mult(6), Rarity.damage_mult(5)))
	var common := _median(&"pistol", 1, 1)

	# --- the roll ---------------------------------------------------------------------
	var spread: float = common.dps_hi / common.dps_lo
	_ok("inside one colour the hidden DPS roll is narrow (5th-95th under 1.3x)", spread < 1.3,
			"%.2fx" % spread)

	# --- slots and quality ------------------------------------------------------------
	var slots_ok := true
	var dmg_mod := {2: [], 4: []}
	for r in range(1, 7):
		for i in 40:
			var res := _gun(&"pistol", r, 1, i)
			if res.modifiers.size() != Rarity.modifier_slots(r):
				slots_ok = false
			for m in res.modifiers:
				if m.id == &"damage" and dmg_mod.has(r):
					dmg_mod[r].append(float(m.value))
	_ok("modifiers by colour: 1 / 2 / 3 / 4 / 4 / 4", slots_ok
			and Array(Rarity.SLOTS) == [1, 2, 3, 4, 4, 4])
	var green := _mean(dmg_mod[2])
	var purp := _mean(dmg_mod[4])
	_ok("a purple's damage modifier rolls higher than a green's", purp > green,
			"+%.1f%% vs +%.1f%%" % [purp * 100.0, green * 100.0])
	var res_a := _gun(&"rifle", 4, 3, 7)
	var res_b := GunGenerator.deserialize(_lib, res_a.serialize())
	_ok("a saved gun rebuilds the same modifiers", res_a.modifiers == res_b.modifiers
			and is_equal_approx(res_a.stats[&"damage"], res_b.stats[&"damage"]))

	# --- score ----------------------------------------------------------------------
	var s1: float = _median(&"pistol", 1, 5).score
	var s2: float = _median(&"pistol", 1, 6).score
	_ok("a tier is 100 score points", absf(s2 - s1 - 100.0) <= 2.0, "%.0f -> %.0f" % [s1, s2])


static func _mean(a: Array) -> float:
	if a.is_empty():
		return 0.0
	var s := 0.0
	for v in a:
		s += float(v)
	return s / float(a.size())
