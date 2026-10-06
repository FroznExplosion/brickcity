extends SceneTree

## The combat design's numbers (Docs/Weapons/COMBAT_DESIGN.md sections 1-3), checked
## against the guns the generator actually rolls.
##
##     godot --headless --path . --script res://tools/combat_numbers_probe.gd
##
## A gun's per-shot damage trades against its fire rate, so "a common pistol" is the
## MEDIAN of many rolls; every number here is a median. The light enemy is the `trash`
## archetype (LootRoller.enemy_hp).
##
##   power curve   +25% a level, guns and enemies alike
##   the anchor    on level, a common pistol kills a light enemy in 5-7 body shots (6 the
##                 target), and the same at every level
##   legendary     4 body shots alone; 2 with headshots; 3 with one +20% damage modifier;
##                 5 when it is a level behind
##   worth         a blue ~= a white one level up; a purple one level on ~= a good green;
##                 two levels on a white overtakes it; mythic = legendary
##   score         a level is 100 points

const SAMPLES := 301
## The crit-spot multiplier the design sets (section 4.3).
const CRIT := 2.0
## A damage modifier, as in section 3's table.
const DAMAGE_MOD := 1.2

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


## Median per-shot damage and score of `class_id` guns at this rarity and tier.
func _median(class_id: StringName, rarity: int, tier: int) -> Dictionary:
	var dmg: Array[float] = []
	var score: Array[float] = []
	var wc := WeaponClass.builtin(class_id)
	for i in SAMPLES:
		var res := GunGenerator.generate(_lib, 1000 + i * 7919, wc, tier, rarity)
		dmg.append(float(res.stats[&"damage"]))
		score.append(float(GunQuality.score(res.stats, wc)))
	dmg.sort()
	score.sort()
	return {"damage": dmg[SAMPLES / 2], "score": score[SAMPLES / 2]}


static func _stk(hp: float, dmg: float) -> int:
	return ceili(hp / maxf(dmg, 0.001) - 0.0001)


func _run() -> void:
	# --- the curve --------------------------------------------------------------
	var step := Tier.power_mult(2) / Tier.power_mult(1)
	var hp_step := LootRoller.enemy_hp(&"trash", 6) / LootRoller.enemy_hp(&"trash", 5)
	_ok("a level is +25% for guns", is_equal_approx(step, 1.25), "%.3f" % step)
	_ok("and for enemies", is_equal_approx(hp_step, 1.25), "%.3f" % hp_step)
	_ok("ten levels span 7.45x", absf(Tier.power_mult(10) - 7.45) < 0.01,
			"%.2f" % Tier.power_mult(10))

	# --- the anchor ---------------------------------------------------------------
	var common := _median(&"pistol", 1, 1)
	var light := LootRoller.enemy_hp(&"trash", 1)
	var stk := _stk(light, common.damage)
	_ok("on level a common pistol kills a light enemy in 5-7 body shots", stk >= 5 and stk <= 7,
			"%d (median %.2f a shot vs %.0f hp; 6 is the target)" % [stk, common.damage, light])
	var same := true
	var leg_same := true
	for t in range(2, 11):
		if _stk(LootRoller.enemy_hp(&"trash", t), _median(&"pistol", 1, t).damage) != stk:
			same = false
		if _stk(LootRoller.enemy_hp(&"trash", t), _median(&"pistol", 5, t).damage) \
				!= _stk(light, _median(&"pistol", 5, 1).damage):
			leg_same = false
	_ok("and the same at every level, on level", same and leg_same)

	# --- legendary ------------------------------------------------------------------
	var leg := _median(&"pistol", 5, 1)
	_ok("a legendary takes 4 body shots", _stk(light, leg.damage) == 4,
			"%d" % _stk(light, leg.damage))
	_ok("2 with headshots", _stk(light, leg.damage * CRIT) == 2, "%d" % _stk(light, leg.damage * CRIT))
	_ok("3 with one damage modifier", _stk(light, leg.damage * DAMAGE_MOD) == 3,
			"%d" % _stk(light, leg.damage * DAMAGE_MOD))
	var leg_behind := _median(&"pistol", 5, 4)
	var light5 := LootRoller.enemy_hp(&"trash", 5)
	_ok("5 when it is a level behind", _stk(light5, leg_behind.damage) == 5,
			"%d" % _stk(light5, leg_behind.damage))

	# --- what a colour is worth -------------------------------------------------------
	var t := 4
	var blue: float = _median(&"pistol", 3, t).damage
	var white_up: float = _median(&"pistol", 1, t + 1).damage
	_ok("a blue is worth about a level", absf(blue / white_up - 1.0) < 0.06,
			"blue %.2f vs white a level up %.2f" % [blue, white_up])
	var purple: float = _median(&"pistol", 4, t).damage
	var green_up: float = _median(&"pistol", 2, t + 1).damage
	_ok("a purple a level on is a good green", absf(purple / green_up - 1.0) < 0.06,
			"purple %.2f vs green a level up %.2f" % [purple, green_up])
	var white_2up: float = _median(&"pistol", 1, t + 2).damage
	_ok("two levels on, a white overtakes it", white_2up > purple,
			"white two up %.2f > purple %.2f" % [white_2up, purple])
	_ok("mythic hits as hard as legendary", is_equal_approx(Rarity.damage_mult(6), Rarity.damage_mult(5)))
	_ok("and the purple keeps its name", Rarity.NAMES[3] == "Unique")

	# --- score ----------------------------------------------------------------------
	var s1: float = _median(&"pistol", 1, 5).score
	var s2: float = _median(&"pistol", 1, 6).score
	_ok("a level is 100 score points", absf(s2 - s1 - 100.0) <= 2.0, "%.0f -> %.0f" % [s1, s2])
