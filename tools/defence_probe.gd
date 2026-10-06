extends SceneTree

## Enemy defences and elements (Docs/Weapons/COMBAT_DESIGN.md 4-5).
##
##     godot --headless --path . --script res://tools/defence_probe.gd
##
##   melees       every profile's layers are its melee counts times one melee, at any
##                level (a shield's melee is worth 1.5); flesh is one melee up to medium
##   the anchor   a light enemy is the loot table's light enemy (6 median pistol shots)
##   elements     plasma 2x shield, corrosive 2x armor, acid 1.5x flesh, fire 2x
##                vegetation, ice neutral -- and nothing is ever below 1x
##   top layer    an element's damage lands on the top layer, never past the shield
##   gating       a body shot breaking a shield carries half its leftover on; a
##                crit-spot hit carries all of it
##   regen        a shield comes back after its pause; armor and flesh do not
##   guns         an elemental barrel's gun carries an element, a kinetic one none, and
##                a seed rolls the same gun it always did

var _pass := 0
var _fail := 0


func _init() -> void:
	print("defence probe")
	_run.call_deferred()


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _pool(profile: StringName, level := 1) -> HealthPool:
	var holder := Node.new()
	root.add_child(holder)
	var p := HealthPool.new()
	p.name = "HealthPool"
	holder.add_child(p)
	EnemyProfiles.apply(p, profile, level)
	return p


func _hit(pool: HealthPool, amount: float, element := &"", ratio := 1.0, crit := false) -> float:
	var pk := DamagePacket.new(amount, Elements.get_def(element), null)
	pk.element_ratio = ratio if element != &"" else 0.0
	pk.crit = crit
	pk.crit_multiplier = 1.0   # gating, not the multiplier, is under test
	return DamageSystem.resolve(pk, pool.get_parent()).dealt


func _run() -> void:
	# --- melees ---------------------------------------------------------------------
	var all_ok := true
	var detail := ""
	for id in EnemyProfiles.PROFILES:
		for lvl in [1, 6]:
			var layers := EnemyProfiles.layers(id, lvl)
			var counts := EnemyProfiles.melee_counts(id)
			for i in layers.size():
				var want := counts[i] * CombatScale.melee(lvl) \
						* (CombatScale.SHIELD_MELEE if layers[i].layer_type == &"shield" else 1.0)
				if absf(layers[i].max_value - want) > 0.01:
					all_ok = false
					detail = "%s L%d layer %d: %.1f vs %.1f" % [id, lvl, i, layers[i].max_value, want]
	_ok("every layer is its melee count times one melee, at every level", all_ok, detail)
	var flesh_one := true
	for id in [&"very_light", &"light", &"light_shielded", &"light_armored", &"medium",
			&"medium_shielded"]:
		var c := EnemyProfiles.melee_counts(id)
		if c[c.size() - 1] > 1.0:
			flesh_one = false
	_ok("flesh is one melee for every enemy up to medium", flesh_one)
	_ok("a medium enemy's armor is three melees", EnemyProfiles.melee_counts(&"medium")[0] == 3.0)
	_ok("a light enemy is the loot table's light enemy",
			is_equal_approx(EnemyProfiles.layers(&"light", 4)[0].max_value,
					LootRoller.enemy_hp(&"trash", 4)))

	# --- elements -------------------------------------------------------------------
	var m := Elements.matrix()
	_ok("plasma is 2x on shields", m.get_multiplier(Elements.PLASMA, &"shield") == 2.0)
	_ok("corrosive is 2x on armor", m.get_multiplier(Elements.CORROSIVE, &"armor") == 2.0)
	_ok("acid is 1.5x on flesh", m.get_multiplier(Elements.ACID, &"health") == 1.5)
	_ok("fire is 2x on vegetation", m.get_multiplier(Elements.FIRE, &"vegetation") == 2.0)
	var floor_ok := true
	for e in Elements.GUN_ELEMENTS:
		for t in [&"shield", &"armor", &"health", &"vegetation"]:
			if m.get_multiplier(e, t) < 1.0:
				floor_ok = false
		if e == Elements.ICE:
			for t in [&"shield", &"armor", &"health", &"vegetation"]:
				if m.get_multiplier(e, t) != 1.0:
					floor_ok = false
	_ok("ice is neutral, and nothing is weak against an element", floor_ok)

	# Damage through the pool: the element's bonus where it fits.
	var sh := _pool(&"light_shielded")
	var dealt := _hit(sh, 10.0, Elements.PLASMA)
	_ok("a plasma round does double to a shield", is_equal_approx(dealt, 20.0), "%.1f" % dealt)
	var veg := _pool(&"plant")
	dealt = _hit(veg, 10.0, Elements.FIRE)
	_ok("a fire round does double to a plant", is_equal_approx(dealt, 20.0), "%.1f" % dealt)

	# --- the top layer ---------------------------------------------------------------
	var acid_on_shield := _pool(&"light_shielded")
	var flesh0 := acid_on_shield.get_layer_value(1)
	_hit(acid_on_shield, 20.0, Elements.ACID)
	_ok("an acid round on a shielded enemy hits the shield, not the flesh under it",
			is_equal_approx(acid_on_shield.get_layer_value(1), flesh0)
			and acid_on_shield.get_layer_value(0) < acid_on_shield.layer_configs[0].max_value)

	# --- gating ---------------------------------------------------------------------
	var g := _pool(&"light_shielded")
	var shield_hp := g.get_layer_value(0)
	var over := 40.0
	_hit(g, shield_hp + over)
	var took := g.layer_configs[1].max_value - g.get_layer_value(1)
	_ok("a body shot breaking a shield carries half its leftover on",
			is_equal_approx(took, over * CombatScale.SHIELD_GATE), "%.1f of %.1f" % [took, over])
	var g2 := _pool(&"light_shielded")
	_hit(g2, shield_hp + over, &"", 1.0, true)
	took = g2.layer_configs[1].max_value - g2.get_layer_value(1)
	_ok("a crit-spot hit carries all of it", is_equal_approx(took, over), "%.1f of %.1f" % [took, over])
	var ar := _pool(&"light_armored")
	var armor_hp := ar.get_layer_value(0)
	_hit(ar, armor_hp + over)
	took = ar.layer_configs[1].max_value - ar.get_layer_value(1)
	_ok("armor does not gate", is_equal_approx(took, over), "%.1f of %.1f" % [took, over])

	# --- regen ----------------------------------------------------------------------
	var r := _pool(&"heavy")
	_hit(r, r.get_layer_value(0) * 0.5)
	var armor_before := r.get_layer_value(1)
	_hit(r, 0.0)
	var low := r.get_layer_value(0)
	for i in int((CombatScale.SHIELD_REGEN_DELAY + CombatScale.SHIELD_REGEN_SECONDS + 0.5) * 30.0):
		await physics_frame
	_ok("a shield comes back after its pause", r.get_layer_value(0) > low
			and is_equal_approx(r.get_layer_value(0), r.layer_configs[0].max_value),
			"%.1f -> %.1f" % [low, r.get_layer_value(0)])
	var a2 := _pool(&"light_armored")
	_hit(a2, 10.0)
	var a_low := a2.get_layer_value(0)
	for i in 30 * 6:
		await physics_frame
	_ok("armor does not", is_equal_approx(a2.get_layer_value(0), a_low) and armor_before > 0.0)

	# --- guns carry an element ------------------------------------------------------
	var lib := GunPlaceholderParts.build_library()
	var elemental := 0
	var consistent := true
	var same_seed := true
	for i in 200:
		var res := GunGenerator.generate(lib, 500 + i * 31, WeaponClass.builtin(&"rifle"), 6)
		var barrel := res.recipe.get(GunPartDef.Slot.BARREL) as GunBarrelDef
		var is_elem := barrel != null and barrel.element_ratio > 0.01
		if is_elem != (res.element_id != &""):
			consistent = false
		if is_elem:
			elemental += 1
		var again := GunGenerator.generate(lib, 500 + i * 31, WeaponClass.builtin(&"rifle"), 6)
		if again.element_id != res.element_id or again.gun_name != res.gun_name \
				or not is_equal_approx(float(again.stats[&"damage"]), float(res.stats[&"damage"])):
			same_seed = false
	_ok("an elemental barrel's gun carries an element, a kinetic one none", consistent and elemental > 0,
			"%d of 200 elemental at level 6" % elemental)
	_ok("and a seed rolls the same gun every time", same_seed)

	print("defence probe: %d ok, %d FAIL" % [_pass, _fail])
	for c in root.get_children():
		c.queue_free()
	await physics_frame
	quit(1 if _fail > 0 else 0)
