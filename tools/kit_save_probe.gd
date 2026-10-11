extends SceneTree

## The player's kit kept between sessions (Docs/Weapons/COMBAT_DESIGN.md 7, CharacterSave).
##
##     godot --headless --path . --script res://tools/kit_save_probe.gd
##
##   gun        a gun saved and made again is the same gun -- name, rarity, parts, stats,
##              modifiers, alt-fire, element -- whether its rarity was rolled from its seed
##              or forced (loot), a legendary, or infused to another tier; through JSON too
##   parts      the part library changed under a save: the saved parts, not a new roll
##   kit        a Loadout through the save: the four slots, the ordnance, the backpack and
##              its size, the group and hand; a tried floor gun is not kept
##   file       CharacterSave keeps the kit; an old save without one reads as no kit
##   arsenal    restore() puts the saved kit in the hands in place of the controller's gun;
##              a changed kit says so (kit_changed); an infusion saves with its scrap

var _pass := 0
var _fail := 0
var _lib: GunPartLibrary


func _init() -> void:
	print("kit save probe")
	_run.call_deferred()


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _run() -> void:
	_lib = GunPlaceholderParts.build_library()
	_guns()
	_parts()
	_kit()
	_file()
	await _arsenal()
	print("kit save probe: %d ok, %d FAIL" % [_pass, _fail])
	for c in root.get_children():
		c.queue_free()
	await _frames(2)
	quit(1 if _fail > 0 else 0)


## "" when `a` and `b` are the same gun, else what differs.
func _diff(a: GunGenerator.Result, b: GunGenerator.Result) -> String:
	var out := []
	for f in ["seed", "rarity", "tier", "gun_name", "element_id", "alt_fire", "legendary_id", "score"]:
		if a.get(f) != b.get(f):
			out.append("%s %s/%s" % [f, a.get(f), b.get(f)])
	if a.weapon_class.id != b.weapon_class.id:
		out.append("class")
	if a.recipe.size() != b.recipe.size():
		out.append("parts")
	for slot in a.recipe:
		if not b.recipe.has(slot) or (a.recipe[slot] as GunPartDef).id != (b.recipe[slot] as GunPartDef).id:
			out.append("part %d" % slot)
	if str(a.modifiers) != str(b.modifiers):
		out.append("modifiers")
	for k in a.stats:
		if not b.stats.has(k) or not is_equal_approx(float(a.stats[k]), float(b.stats[k])):
			out.append("stat %s %s/%s" % [k, a.stats[k], b.stats.get(k)])
	return ", ".join(out)


## `g` through a save and JSON, made again.
func _again(g: GunInstance) -> GunInstance:
	var e := CharacterSave.gun_entry(g)
	var back = JSON.parse_string(JSON.stringify(e))
	return CharacterSave.make_gun(back, _lib)


func _check(what: String, g: GunInstance) -> void:
	var g2 := _again(g)
	var d := _diff(g.result, g2.result)
	_ok(what, d == "", d if d != "" else "%s, %s" % [g.gun_name, GunGenerator.RARITY_NAMES[g.rarity - 1]])
	g.free()
	g2.free()


# --- one gun ------------------------------------------------------------------------------

func _guns() -> void:
	_check("a rolled gun comes back the same", GunInstance.from_result(
			GunGenerator.generate(_lib, 4242, WeaponClass.builtin(&"rifle"), 3)))
	# Forced: the roll it skipped would shift every roll after it; the save must force it too.
	var same := 0
	for s in 12:
		var forced := GunInstance.from_result(GunGenerator.generate(_lib, 900 + s,
				WeaponClass.builtin(&"shotgun"), 2, 4))
		var g2 := _again(forced)
		if _diff(forced.result, g2.result) == "":
			same += 1
		forced.free()
		g2.free()
	_ok("a gun forced to its rarity (loot) comes back the same", same == 12, "%d / 12" % same)
	var leg := LegendaryTable.get_def(&"sermon")
	var lg := GunInstance.from_result(GunGenerator.generate_legendary(_lib, 77, leg, 2))
	var lg2 := _again(lg)
	var d := _diff(lg.result, lg2.result)
	_ok("a legendary comes back the same, its signature and name with it",
			d == "" and lg2.result.legendary_id == &"sermon", d)
	lg.free()
	lg2.free()
	var inf := GunInstance.from_result(GunGenerator.generate(_lib, 5150, WeaponClass.builtin(&"smg"), 1, 3))
	Infusion.infuse(inf, 5)
	var inf2 := _again(inf)
	d = _diff(inf.result, inf2.result)
	_ok("an infused gun comes back at its new tier, the same gun", d == "" and inf2.tier == 5, d)
	inf.free()
	inf2.free()
	var mixed := 0
	for s in 30:
		var cls: StringName = [&"pistol", &"rifle", &"smg", &"sniper", &"shotgun", &"rocket_launcher"][s % 6]
		var g := GunInstance.from_result(GunGenerator.generate(_lib, 31 * s + 7, WeaponClass.builtin(cls),
				1 + s % 7, -1 if s % 2 == 0 else 1 + s % 6))
		var g2 := _again(g)
		if _diff(g.result, g2.result) == "":
			mixed += 1
		g.free()
		g2.free()
	_ok("thirty guns of every class, tier and rarity, rolled and forced, all come back", mixed == 30,
			"%d / 30" % mixed)


# --- the library changed ------------------------------------------------------------------

func _parts() -> void:
	var g := GunInstance.from_result(GunGenerator.generate(_lib, 2024, WeaponClass.builtin(&"rifle"), 2))
	var e := CharacterSave.gun_entry(g)
	# A save from before the library changed: what that seed rolled then is not what it
	# rolls now. Here, the barrel it had is another one of the library's barrels.
	var slot := str(GunPartDef.Slot.BARREL)
	var other := ""
	for def in _lib.parts:
		if def != null and def.slot == GunPartDef.Slot.BARREL and String(def.id) != e.parts[slot] \
				and def.exclusive_to == &"":
			other = String(def.id)
			break
	e.parts[slot] = other
	var g2 := CharacterSave.make_gun(e, _lib)
	_ok("the library changed: the saved parts, not a new roll",
			String((g2.recipe[GunPartDef.Slot.BARREL] as GunPartDef).id) == other
			and g2.gun_seed == g.gun_seed and g2.rarity == g.rarity and g2.tier == 2, other)
	var old := {"class": "rifle", "seed": 2024, "tier": 2, "rarity": -1}
	var g3 := CharacterSave.make_gun(old, _lib)
	_ok("an entry from before parts were kept still makes its gun", _diff(g.result, g3.result) == "")
	g.free()
	g2.free()
	g3.free()


# --- the kit ------------------------------------------------------------------------------

func _gun(s: int, cls: StringName, forced := -1) -> GunInstance:
	return GunInstance.from_result(GunGenerator.generate(_lib, s, WeaponClass.builtin(cls), 2, forced))


func _kit() -> void:
	var lo := Loadout.new()
	lo.set_slot(0, _gun(1, &"rifle"))
	lo.set_slot(1, _gun(2, &"pistol", 3))
	lo.set_slot(3, _gun(3, &"sniper"))
	lo.ordnance = _gun(4, &"rocket_launcher", 2)
	lo.backpack_size = 14
	for i in 3:
		lo.backpack.append(_gun(10 + i, &"smg", 5))
	lo.group = 1
	lo.hand = [1, 1]
	lo.third_hand = _gun(99, &"shotgun")
	var d = JSON.parse_string(JSON.stringify(CharacterSave.loadout_dict(lo)))
	var lo2 := Loadout.new()
	CharacterSave.fill_loadout(lo2, d, _lib)
	var bad := []
	for i in Loadout.SLOTS:
		var a := lo.slots[i] as GunInstance
		var b := lo2.slots[i] as GunInstance
		if (a == null) != (b == null) or (a != null and _diff(a.result, b.result) != ""):
			bad.append("slot %d" % i)
	if _diff((lo.ordnance as GunInstance).result, (lo2.ordnance as GunInstance).result) != "":
		bad.append("ordnance")
	if lo2.backpack.size() != 3:
		bad.append("backpack %d" % lo2.backpack.size())
	else:
		for i in 3:
			if _diff((lo.backpack[i] as GunInstance).result, (lo2.backpack[i] as GunInstance).result) != "":
				bad.append("pack %d" % i)
	_ok("the slots, the ordnance and the backpack come back, gun for gun", bad.is_empty(), ", ".join(bad))
	_ok("and the backpack's size, the group and the hand", lo2.backpack_size == 14 and lo2.group == 1
			and int(lo2.hand[1]) == 1 and lo2.in_hand() != null
			and (lo2.in_hand() as GunInstance).gun_seed == 3)
	_ok("a tried floor gun is not kept", lo2.third_hand == null and lo2.all_guns().size() == 7)
	for g in lo.all_guns() + lo2.all_guns():
		(g as Node).free()


# --- the save file ------------------------------------------------------------------------

func _file() -> void:
	var lo := Loadout.new()
	lo.set_slot(0, _gun(5, &"rifle"))
	var s := CharacterSave.new()
	s.loadout = CharacterSave.loadout_dict(lo)
	var path := "user://kit_save_probe.json"
	s.save(path)
	var back := CharacterSave.load_from(path)
	_ok("the save file keeps the kit", back.loadout.get("slots", []).size() == Loadout.SLOTS
			and back.loadout.slots[0] is Dictionary and int(back.loadout.slots[0].seed) == 5)
	var old := CharacterSave.from_dict({"version": 1, "character": {"level": 3}})
	_ok("an old save without a kit reads as none", old.loadout.is_empty())
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	for g in lo.all_guns():
		(g as Node).free()


# --- the arsenal --------------------------------------------------------------------------

func _arsenal() -> void:
	var world := Node3D.new()
	root.add_child(world)
	var pawn := Pawn.spawn(world, Vector3.ZERO, 0)
	var cam := Camera3D.new()
	world.add_child(cam)
	cam.current = true
	var pc := PlayerController.new()
	pc.drive_uncaptured = true
	world.add_child(pc)
	pc.possess(pawn, cam)
	var gc := GunController.new()
	gc.aim = cam
	gc.rng = RandomNumberGenerator.new()
	world.add_child(gc)
	pawn.gun = gc
	# The gun the scene armed the controller with before the arsenal came.
	var first := _gun(321, &"pistol")
	world.add_child(first)
	gc.equip(first)

	var lo := Loadout.new()
	lo.set_slot(0, _gun(6, &"shotgun", 4))
	lo.set_slot(2, _gun(7, &"sniper"))
	lo.ordnance = _gun(8, &"rocket_launcher")
	lo.backpack.append(_gun(9, &"smg"))
	lo.group = 1
	var saved := CharacterSave.loadout_dict(lo)
	for g in lo.all_guns():
		(g as Node).free()

	var ars := PlayerArsenal.new()
	world.add_child(ars)
	ars.setup(pc, gc, null, null, _lib, world, 1)
	_ok("restore makes the saved kit", ars.restore(saved) and ars.loadout.all_guns().size() == 4)
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	ars.fill_default(rng)
	_ok("and the starting kit does not go over it", ars.loadout.all_guns().size() == 4
			and (ars.loadout.slots[1] == null))
	_ok("the saved gun in hand is in the hands", gc.gun != null and gc.gun.gun_seed == 7
			and gc.gun == ars.loadout.in_hand())
	await _frames(2)
	_ok("the controller's old gun is let go", not is_instance_valid(first))
	_ok("a second restore does nothing", not ars.restore(saved))

	var said := [0]
	ars.kit_changed.connect(func() -> void: said[0] += 1)
	ars.check_kit()
	_ok("an unchanged kit says nothing", said[0] == 0)
	var pack := ars.loadout.backpack[0] as GunInstance
	ars.loadout.drop_from_backpack(0)
	pack.queue_free()
	ars.check_kit()
	_ok("a changed kit says so", said[0] == 1)

	# An infusion: the save that the scrap spent makes (PlayerLevel.changed) holds the
	# infused gun.
	pc.progress.story_tier = 4
	pc.progress.scrap = 5000
	var at_save := [0]
	pc.progress.changed.connect(func() -> void:
		at_save[0] = int(ars.kit_dict().slots[2].tier))
	ars.infuse(gc.gun)
	_ok("an infusion's scrap is spent with the gun already infused", at_save[0] == 4, "tier %d" % at_save[0])
	said[0] = 0
	ars.check_kit()
	_ok("and the kit check does not save it twice", said[0] == 0)
	world.queue_free()
	await _frames(2)
