extends SceneTree

## The combat design's numbers (Docs/Weapons/COMBAT_DESIGN.md sections 1-3, v2), checked
## against the guns the generator actually rolls.
##
##     godot --headless --path . --script res://tools/combat_numbers_probe.gd
##
## A gun's per-shot damage trades against its fire rate, so "a common pistol" is the
## MEDIAN of many rolls; every number here is a median, taken BEFORE modifiers (the rows
## of section 3 add them by hand). The light enemy is the `trash` archetype
## (LootRoller.enemy_hp).
##
##   power curve   +25% a tier, guns and enemies alike
##   the anchor    on tier, a common pistol kills a light enemy in 6 body shots, 3
##                 headshots; the same at every tier
##   the colour    alone gets nothing: a legendary without modifiers is still 6 / 3; the
##                 whole range is about half a tier
##   the build     one +20% damage modifier: 5 (white or legendary); two (+40%, a purple
##                 or better has the slots): 4 body, 2 headshots; a tier behind, one more
##   the roll      the hidden DPS roll inside one colour is narrow (3.1)
##   slots         a gun carries 1 / 2 / 3 / 4 / 4 / 4 modifiers by colour, and a higher
##                 colour's modifiers roll higher
##   score         a tier is 100 points
##
## (v1's "a blue is worth a level" rows went with v1's rarity steps: v2 makes the colour
## worth half a tier in all, and the build the rest.)

const SAMPLES := 301
## The crit-spot multiplier: the pistol class's (2x, section 4.3).
var CRIT := WeaponClass.builtin(&"pistol").crit_mult
## A damage modifier at the top of its band, as in section 3's table.
const DAMAGE_MOD := 0.2

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


func _gun(class_id: StringName, rarity: int, tier: int, i: int) -> GunGenerator.Result:
	return GunGenerator.generate(_lib, 1000 + i * 7919, WeaponClass.builtin(class_id), tier, rarity)


## Median per-shot damage (before modifiers), DPS and score of `class_id` guns.
func _median(class_id: StringName, rarity: int, tier: int) -> Dictionary:
	var dmg: Array[float] = []
	var dps: Array[float] = []
	var score: Array[float] = []
	var wc := WeaponClass.builtin(class_id)
	for i in SAMPLES:
		var res := _gun(class_id, rarity, tier, i)
		var base := GunStats.compute(res.recipe, res.rarity, wc, tier, res.seed)
		dmg.append(float(base[&"damage"]))
		dps.append(float(base[&"damage"]) * float(base[&"fire_rate"]))
		score.append(float(GunQuality.score(base, wc)))
	dmg.sort()
	dps.sort()
	score.sort()
	return {"damage": dmg[SAMPLES / 2], "score": score[SAMPLES / 2],
			"dps_lo": dps[SAMPLES / 20], "dps_hi": dps[SAMPLES - 1 - SAMPLES / 20]}


static func _stk(hp: float, dmg: float) -> int:
	return ceili(hp / maxf(dmg, 0.001) - 0.0001)


func _run() -> void:
	# --- the curve --------------------------------------------------------------
	var step := Tier.power_mult(2) / Tier.power_mult(1)
	var hp_step := LootRoller.enemy_hp(&"trash", 6) / LootRoller.enemy_hp(&"trash", 5)
	_ok("a tier is +25% for guns", is_equal_approx(step, 1.25), "%.3f" % step)
	_ok("and for enemies", is_equal_approx(hp_step, 1.25), "%.3f" % hp_step)

	# --- the anchor ---------------------------------------------------------------
	var common := _median(&"pistol", 1, 1)
	var light := LootRoller.enemy_hp(&"trash", 1)
	var c: float = common.damage
	_ok("on tier a common pistol kills a light enemy in 6 body shots", _stk(light, c) == 6,
			"%d (median %.2f a shot vs %.0f hp)" % [_stk(light, c), c, light])
	_ok("and 3 headshots", _stk(light, c * CRIT) == 3, "%d" % _stk(light, c * CRIT))
	var same := true
	for t in range(2, 11):
		for r in [1, 5]:
			if _stk(LootRoller.enemy_hp(&"trash", t), _median(&"pistol", r, t).damage) \
					!= _stk(light, _median(&"pistol", r, 1).damage):
				same = false
	_ok("the same at every tier, on tier", same)

	# --- the colour alone -----------------------------------------------------------
	var leg: float = _median(&"pistol", 5, 1).damage
	_ok("a legendary with no modifiers is still 6 body shots", _stk(light, leg) == 6,
			"%d (%.2f a shot)" % [_stk(light, leg), leg])
	_ok("and 3 headshots", _stk(light, leg * CRIT) == 3, "%d" % _stk(light, leg * CRIT))
	var half := log(Rarity.damage_mult(6)) / log(Tier.TIER_STEP)
	_ok("the whole colour range is about half a tier", absf(half - 0.5) < 0.05, "%.2f" % half)
	_ok("mythic hits as hard as legendary", is_equal_approx(Rarity.damage_mult(6), Rarity.damage_mult(5)))

	# --- the build --------------------------------------------------------------------
	var one := 1.0 + DAMAGE_MOD
	var two := 1.0 + 2.0 * DAMAGE_MOD
	_ok("a common with one damage modifier: 5", _stk(light, c * one) == 5, "%d" % _stk(light, c * one))
	_ok("a legendary with one: 5", _stk(light, leg * one) == 5, "%d" % _stk(light, leg * one))
	var purple: float = _median(&"pistol", 4, 1).damage
	_ok("a purple with two: 4 body shots", _stk(light, purple * two) == 4,
			"%d" % _stk(light, purple * two))
	_ok("and 2 headshots", _stk(light, purple * two * CRIT) == 2,
			"%d" % _stk(light, purple * two * CRIT))
	_ok("a legendary with two: 4 and 2", _stk(light, leg * two) == 4
			and _stk(light, leg * two * CRIT) == 2)
	var behind: float = _median(&"pistol", 5, 4).damage
	var light5 := LootRoller.enemy_hp(&"trash", 5)
	_ok("a tier behind, one more", _stk(light5, behind * two) == 5,
			"%d" % _stk(light5, behind * two))

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
