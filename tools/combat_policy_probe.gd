extends SceneTree
## The engage decision on its own (CombatPolicy, ScriptedCombatPolicy):
##
##   godot --headless --path . --script res://tools/combat_policy_probe.gd
##
## The contract a model must match, and whether the scripted choices -- drawn
## at random -- lean the way the rules say, over many draws of the same
## situation.

var _pass := 0
var _fail := 0


func _init() -> void:
	print("[policy] the engage decision")
	var c := CombatPolicy.CONTRACT.duplicate(true)
	_ok("the scripted policy's own contract is accepted", CombatPolicy.accepts(c))
	var bad := c.duplicate(true)
	bad.version = CombatPolicy.SPEC_VERSION + 1
	_ok("a model of another version is refused", not CombatPolicy.accepts(bad))
	var shuffled := c.duplicate(true)
	var obs: Array = shuffled.observations.duplicate()
	obs.reverse()
	shuffled.observations = obs
	_ok("and one with its observations in another order", not CombatPolicy.accepts(shuffled))
	var stand_in := CombatPolicy.new()
	_ok("create() with a mismatched model hands back the scripted one",
			CombatPolicy.create(stand_in, bad) is ScriptedCombatPolicy)
	_ok("and with a matching one, the model", CombatPolicy.create(stand_in, c) == stand_in)
	_ok("names and enums agree", CombatPolicy.OBS_NAMES.size() == CombatPolicy.Obs.COUNT
			and CombatPolicy.TACTIC_NAMES.size() == CombatPolicy.Tactic.COUNT)

	var p := ScriptedCombatPolicy.new()
	var T := CombatPolicy.Tactic
	# Empty magazine, cover close by, under fire: reload in cover.
	var dry := _obs({"has_cover": 1, "cover_dist": 0.3, "cover_life": 0.8, "ammo": 0.0,
			"health": 0.8, "under_fire": 1, "threat_dist": 0.4, "threat_visible": 1})
	var h := _draw(p, dry)
	_ok("out of ammo with cover near: mostly into cover to reload", _top(h) == T.COVER_RELOAD
			and h[T.COVER_RELOAD] > 0.5, _show(h))
	# Empty magazine and no cover anywhere: reload where it stands.
	var bare := _obs({"has_cover": 0, "ammo": 0.0, "health": 0.8, "threat_dist": 0.4,
			"threat_visible": 1})
	h = _draw(p, bare)
	_ok("out of ammo with no cover: stands and reloads in the open", _top(h) == T.FIGHT_OPEN
			and h[T.COVER_RELOAD] < 0.05 and h[T.TAKE_COVER] < 0.05, _show(h))
	# Full magazine, healthy, three friends shooting, the enemy far off.
	var backed := _obs({"has_cover": 1, "cover_dist": 0.5, "cover_life": 0.5, "ammo": 1.0,
			"health": 1.0, "threat_dist": 0.7, "threat_visible": 1, "friends_shooting": 0.75,
			"friends_seeing": 0.75})
	h = _draw(p, backed)
	_ok("full mag, friends firing, enemy far: pushes or flanks a good share",
			h[T.PUSH] + h[T.FLANK] > 0.35, _show(h))
	# Alone, hurt, nearly dead, enemy close.
	var bad_spot := _obs({"has_cover": 1, "cover_dist": 0.4, "cover_life": 0.6, "ammo": 0.6,
			"health": 0.2, "under_fire": 1, "threat_dist": 0.15, "threat_visible": 1, "alone": 1})
	h = _draw(p, bad_spot)
	_ok("alone, hurt and close: never pushes, mostly cover or falls back",
			h[T.PUSH] < 0.03 and h[T.TAKE_COVER] + h[T.FALL_BACK] + h[T.COVER_RELOAD] > 0.6, _show(h))
	_ok("and it is a draw, not a rule: more than one answer to the same situation",
			h.filter(func(v): return v > 0.02).size() >= 2, _show(h))
	print("[policy] %d ok, %d FAIL" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _obs(vals: Dictionary) -> PackedFloat32Array:
	var o := PackedFloat32Array()
	o.resize(CombatPolicy.Obs.COUNT)
	o[CombatPolicy.Obs.COVER_DIST] = 1.0
	for k in vals:
		o[CombatPolicy.OBS_NAMES.find(k)] = float(vals[k])
	return o


## Share of each tactic over many draws.
func _draw(p: CombatPolicy, o: PackedFloat32Array) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var n := []
	n.resize(CombatPolicy.Tactic.COUNT)
	n.fill(0.0)
	for i in 2000:
		n[p.decide(o, rng)] += 1.0 / 2000.0
	return n


func _top(h: Array) -> int:
	var best := 0
	for i in h.size():
		if h[i] > h[best]:
			best = i
	return best


func _show(h: Array) -> String:
	var parts := []
	for i in h.size():
		parts.append("%s %.0f%%" % [CombatPolicy.TACTIC_NAMES[i], h[i] * 100.0])
	return ", ".join(parts)


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s  %s" % [what, detail])
	else:
		_fail += 1
		print("  FAIL %s -- %s" % [what, detail])
