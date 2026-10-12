extends SceneTree

## The light and heavy kinds of every gun class (Docs/Weapons/COMBAT_DESIGN.md 7.8).
##
##     godot --headless --path . --script res://tools/gun_kind_probe.gd
##
##   the kinds      a heavy spends two rounds a shot, hits harder a shot than the light
##                  and fires slower (each kind's numbers come from its own shots to kill,
##                  combat_numbers_probe); a light shotgun is a pump or the faster,
##                  lighter auto; ordnance has no kinds
##   the roll       off the seed, the same every time, and never moving the parts or
##                  stats the seed rolls for a light gun; heavies rarer than lights, and
##                  commoner up the colours; only a legendary or mythic is ever crossed
##   the look       a heavy is built of the heavy parts, a light never is
##   the trade      crossed: a heavy at the light's fire rate, a light at the heavy's damage
##   the magazine   counted in shots: a heavy's twelve rounds are six; a shot spends one
##   kept           a save and a serialized gun come back the same kind

const CLASSES: Array[StringName] = [&"pistol", &"revolver", &"smg", &"rifle", &"lmg", &"dmr",
		&"sniper", &"shotgun"]

var _pass := 0
var _fail := 0
var _lib: GunPartLibrary


func _init() -> void:
	print("gun kind probe")
	_run.call_deferred()


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _run() -> void:
	_lib = GunPlaceholderParts.build_library()
	_kinds()
	_roll()
	_look()
	_crossed()
	await _magazine()
	_kept()
	print("gun kind probe: %d ok, %d FAIL" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _kinds() -> void:
	var shot_ok := true
	var floor_ok := true
	var two := true
	var worst := ""
	for id in CLASSES:
		var light := WeaponClass.builtin(id).with_kind(&"light")
		var heavy := WeaponClass.builtin(id).with_kind(&"heavy")
		two = two and heavy.rounds_per_shot == 2 and light.rounds_per_shot == 1
		if heavy.base_damage <= light.base_damage or heavy.base_fire_rate >= light.base_fire_rate:
			shot_ok = false
			worst += " %s" % id
		if heavy.base_fire_rate * GunStats.FIRE_BASE_LO < GunStats.STAT_FLOORS[&"fire_rate"]:
			floor_ok = false
			worst += " %s fr %.2f" % [id, heavy.base_fire_rate * GunStats.FIRE_BASE_LO]
	_ok("a heavy spends two rounds a shot, a light one", two)
	_ok("a heavy hits harder a shot than its light, and fires slower", shot_ok, worst)
	_ok("no worst roll is clamped by the fire-rate floor", floor_ok, worst)
	var pump := WeaponClass.builtin(&"shotgun").with_kind(&"light")
	var auto := WeaponClass.builtin(&"shotgun").with_kind(&"auto")
	_ok("a light shotgun is a pump, or the auto: faster, lighter", pump.kind_name() == "Pump Shotgun"
			and auto.kind_name() == "Auto Shotgun" and auto.base_fire_rate > pump.base_fire_rate * 1.5
			and auto.base_damage < pump.base_damage and auto.rounds_per_shot == 1)
	var pumps := 0
	var autos := 0
	for i in 400:
		var k := WeaponClass.rolled(&"shotgun", 5000 + i, 2).archetype
		if k == &"light":
			pumps += 1
		elif k == &"auto":
			autos += 1
	_ok("light shotguns roll pump and auto about evenly", pumps > 100 and autos > 100,
			"%d pumps, %d autos" % [pumps, autos])
	_ok("a heavy pistol is a magnum", WeaponClass.builtin(&"pistol").with_kind(&"heavy").kind_name()
			== "Magnum")
	var rl := WeaponClass.builtin(&"rocket_launcher").with_kind(&"heavy")
	_ok("ordnance has no kinds", rl.archetype == &"" and rl.rounds_per_shot == 1)


func _roll() -> void:
	var same := true
	var unmoved := true
	var heavy := [0, 0]
	for i in 600:
		var s := 9000 + i * 13
		var a := WeaponClass.rolled(&"rifle", s, 1)
		var b := WeaponClass.rolled(&"rifle", s, 1)
		same = same and a.archetype == b.archetype and a.crossed == b.crossed
		if a.archetype == &"heavy":
			heavy[0] += 1
		if WeaponClass.rolled(&"rifle", s, 6).archetype == &"heavy":
			heavy[1] += 1
		if a.archetype == &"light" and i < 120:
			# A light gun rolls the parts and stats it rolled before there were kinds.
			var old := GunGenerator.generate(_lib, s, WeaponClass.builtin(&"rifle"), 1, 1)
			var now := GunGenerator.generate(_lib, s, a, 1, 1)
			for slot in old.recipe:
				if not now.recipe.has(slot) or now.recipe[slot] != old.recipe[slot]:
					unmoved = false
			if not is_equal_approx(old.stats[&"damage"], now.stats[&"damage"]) \
					or old.gun_name != now.gun_name:
				unmoved = false
	_ok("the kind is off the seed, the same every time", same)
	_ok("a light gun's parts, stats and name are what the seed always rolled", unmoved)
	_ok("heavies are rarer than lights, commoner up the colours",
			heavy[0] > 40 and heavy[0] < 150 and heavy[1] > heavy[0],
			"%d / 600 common, %d / 600 mythic" % [heavy[0], heavy[1]])
	var crossed_low := false
	var crossed_high := 0
	for i in 400:
		if WeaponClass.rolled(&"smg", 300 + i, 4).crossed:
			crossed_low = true
		if WeaponClass.rolled(&"smg", 300 + i, 5).crossed:
			crossed_high += 1
	_ok("only a legendary or mythic is ever crossed", not crossed_low and crossed_high > 60,
			"%d / 400 legendaries" % crossed_high)


func _look() -> void:
	var heavy_parts := true
	var light_clean := true
	for i in 40:
		var h := GunGenerator.generate(_lib, 500 + i, WeaponClass.builtin(&"pistol").with_kind(&"heavy"), 1)
		var l := GunGenerator.generate(_lib, 500 + i, WeaponClass.builtin(&"pistol").with_kind(&"light"), 1)
		# (Now and then a gun of either kind rolls no barrel at all: the brand filter.)
		for slot in [GunPartDef.Slot.BODY, GunPartDef.Slot.BARREL]:
			if h.recipe.has(slot) and (h.recipe[slot] as GunPartDef).kind != &"heavy":
				heavy_parts = false
		for d in l.recipe.values():
			if (d as GunPartDef).kind != &"":
				light_clean = false
	_ok("a heavy is built of the heavy receiver and barrel", heavy_parts)
	_ok("a light never takes a heavy part", light_clean)


func _crossed() -> void:
	var light := WeaponClass.builtin(&"pistol").with_kind(&"light")
	var heavy := WeaponClass.builtin(&"pistol").with_kind(&"heavy")
	var fast := WeaponClass.builtin(&"pistol").with_kind(&"heavy", true)
	var hard := WeaponClass.builtin(&"pistol").with_kind(&"light", true)
	_ok("a crossed heavy fires at the light's rate, with the heavy's damage",
			is_equal_approx(fast.base_fire_rate, light.base_fire_rate)
			and is_equal_approx(fast.base_damage, heavy.base_damage) and fast.rounds_per_shot == 2)
	_ok("a crossed light hits with the heavy's damage, at one round",
			is_equal_approx(hard.base_damage, heavy.base_damage)
			and is_equal_approx(hard.base_fire_rate, light.base_fire_rate) and hard.rounds_per_shot == 1)


func _magazine() -> void:
	var aim := Node3D.new()
	root.add_child(aim)
	var gc := GunController.new()
	gc.rng = RandomNumberGenerator.new()
	gc.rng.seed = 3
	gc.aim = aim
	root.add_child(gc)
	var res := GunGenerator.generate(_lib, 77, WeaponClass.builtin(&"pistol").with_kind(&"heavy"), 1)
	var gi := GunInstance.from_result(res)
	gi.stats[&"mag_size"] = 12.0
	gi.stats[&"fire_rate"] = 20.0
	root.add_child(gi)
	gc.equip(gi)
	_ok("a heavy's twelve rounds are six shots", gc.mag_size() == 6 and gc.ammo == 6,
			"%d / %d" % [gc.ammo, gc.mag_size()])
	gc.set_trigger(true)
	for i in 30:
		await physics_frame
		if gc.ammo < 6:
			break
	gc.set_trigger(false)
	for i in 4:
		await physics_frame
	_ok("and a shot spends one of them", gc.ammo == 5, "%d" % gc.ammo)
	_ok("which is two rounds", gc.rounds_per_shot() == 2)
	gc.queue_free()
	gi.queue_free()
	aim.queue_free()


func _kept() -> void:
	var wc := WeaponClass.rolled(&"shotgun", 4242, 5)
	var res := GunGenerator.generate(_lib, 4242, wc, 3, 5)
	var gi := GunInstance.from_result(res)
	var back := CharacterSave.make_gun(CharacterSave.gun_entry(gi), _lib)
	_ok("a saved gun comes back the same kind", back.archetype == gi.archetype
			and back.weapon_class.crossed == gi.weapon_class.crossed
			and back.gun_name == gi.gun_name, "%s -> %s" % [gi.archetype, back.archetype])
	var heavy := GunGenerator.generate(_lib, 31, WeaponClass.builtin(&"rifle").with_kind(&"heavy"), 2)
	var again := GunGenerator.deserialize(_lib, heavy.serialize())
	_ok("and so does a serialized one", again.weapon_class.archetype == &"heavy"
			and is_equal_approx(again.stats[&"damage"], heavy.stats[&"damage"]))
	gi.free()
	back.free()
