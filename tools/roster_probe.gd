extends SceneTree

## Probe for the roster of types (Roster, data/ai/roster.json; Docs/AIRoster.md RO1).
##
##     godot --headless --path . --script tools/roster_probe.gd
##
## RO1 changes nothing in the game: types are DESCRIBED as recipes, and today's
## units still come from UnitCatalog. So the check is that the two agree --
## 1. Every unit the game fields has a recipe, and that recipe gives the unit's
##    own health layers (EnemyProfiles) at levels 1, 5 and 10, its weapon and
##    its points.
## 2. No recipe marked built has an error; the planned ones read as designed
##    (a "Heavy Gunner Nuker", a brute that turns to melee when its armour goes,
##    a flying bomber on the cheapest brain).
## 3. Mechs come out in layers: light has the most shield and its hatch at the
##    back, heavy the most armour and its hatch in front.

var _pass := 0
var _fail := 0


func _init() -> void:
	print("roster probe")
	var r := Roster.load_roster()
	if r == null:
		_ok("the roster loads", false)
		quit(1)
		return
	_ok("the roster loads", r.recipes.size() >= 7, "%d recipe(s)" % r.recipes.size())
	_units(r)
	_planned(r)
	_mechs(r)
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _units(r: Roster) -> void:
	var missing := []
	var layers_off := []
	var other_off := []
	var n := 0
	for unit in UnitCatalog.UNITS:
		var u: Dictionary = UnitCatalog.UNITS[unit]
		if not u.has("profile"):
			continue   # vehicles and mechs: no infantry profile to compare
		var id := r.for_unit(unit)
		if id == "":
			if bool(u.get("built", false)):
				missing.append(unit)
			continue
		n += 1
		for level in [1, 5, 10]:
			var want := EnemyProfiles.layers(u.profile, level)
			var got := r.layers(id, level)
			var same := want.size() == got.size()
			if same:
				for i in want.size():
					if want[i].layer_type != got[i].layer_type or not is_equal_approx(want[i].max_value, got[i].max_value) \
							or not is_equal_approx(want[i].regen_rate, got[i].regen_rate):
						same = false
			if not same:
				layers_off.append("%s L%d" % [unit, level])
		if str(r.derived(id).weapon) != str(u.weapon) or not is_equal_approx(r.points(id), float(u.points)) \
				or bool(r.recipe(id).built) != bool(u.get("built", false)):
			other_off.append("%s: %s/%s pts %s/%s" % [unit, r.derived(id).weapon, u.weapon, r.points(id), u.points])
	_ok("every infantry unit the game fields has a recipe", missing.is_empty(), "%d compared; missing %s" % [n, missing])
	_ok("and the recipe gives that unit's own health layers at levels 1, 5 and 10", layers_off.is_empty() and n >= 5, str(layers_off))
	_ok("and its weapon, its points, and whether it is built", other_off.is_empty(), str(other_off))


func _planned(r: Roster) -> void:
	var broken := []
	for id in r.ids():
		if bool(r.recipe(id).built) and not r.fit(id):
			broken.append(id)
	_ok("no recipe marked built has an error", broken.is_empty(), str(broken))
	var gnat := r.derived("gnat")
	_ok("the flying bomber: fodder on the cheapest brain, with the facts the casebook needs",
			str(gnat.get("tier", "")) == "swarm" and (gnat.get("facts", []) as Array).has("we_flyer")
			and (gnat.facts as Array).has("we_bomber") and (gnat.facts as Array).has("we_fodder"),
			"%s: %s, %s" % [gnat.get("tag"), gnat.get("tier"), gnat.get("facts")])
	var brute := r.derived("brute")
	var ph: Array = brute.get("phases", [])
	_ok("the brute: seven melees, and melee itself once its armour is gone",
			int(brute.get("melees", 0)) == 7 and ph.size() == 1 and str(ph[0].when) == "armour_gone"
			and (ph[0].facts as Array).has("we_melee") and str(ph[0].weapon) == "melee",
			"%s -> %s" % [brute.get("tag"), ph[0].tag if ph.size() > 0 else "-"])


func _mechs(r: Roster) -> void:
	_ok("the name over a mech's head says what it is",
			r.tag("heavy_gunner_nuker") == "Heavy Gunner Nuker" and r.tag("light_melee_nuker") == "Light Melee Nuker",
			"%s; %s" % [r.tag("heavy_gunner_nuker"), r.tag("light_melee_nuker")])
	var heavy: Dictionary = r.derived("heavy_gunner_nuker").get("mech", {})
	var light: Dictionary = r.derived("light_melee_nuker").get("mech", {})
	_ok("light: most shield, hatch at the back; heavy: most armour, hatch in front",
			not heavy.is_empty() and not light.is_empty()
			and float(light.shield) > float(heavy.shield) and float(heavy.armor) > float(light.armor)
			and float(light.shield) > float(light.armor) and float(heavy.armor) > float(heavy.shield)
			and str(light.hatch_side) == "back" and str(heavy.hatch_side) == "front",
			"light %s/%s/%s, heavy %s/%s/%s (shield/armour/health)" % [light.get("shield"), light.get("armor"),
			light.get("health"), heavy.get("shield"), heavy.get("armor"), heavy.get("health")])
