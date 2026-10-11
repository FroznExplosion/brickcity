extends SceneTree

## Safehouse infusion (Docs/Weapons/COMBAT_DESIGN.md 1.2, Infusion, Workbench).
##
##     godot --headless --path . --script res://tools/infusion_probe.gd
##
##   same gun    one seed at two tiers is the same gun except damage, which moves by the
##               tiers' step -- name, parts, modifiers, alt-fire, element, every other stat
##   retier      a gun infused is the gun that seed makes at the new tier; a forced rarity
##               and a legendary's signature survive it
##   cost        grows with the tiers gained and with rarity; never above the story tier
##   save        a saved gun's infusion is its entry's tier, and it comes back infused
##   bench       looked at and held R, the bench's page opens; Enter infuses the gun in
##               hand for its scrap, and it fires harder; a backpack gun breaks down for
##               scrap, a kit gun does not; not enough scrap is refused
##   scrap       kills drop it; the save keeps it and the story tier, which never falls

var _pass := 0
var _fail := 0
var _lib: GunPartLibrary


func _init() -> void:
	print("infusion probe")
	_run.call_deferred()


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _ticks(n: int) -> void:
	for i in n:
		await physics_frame


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _run() -> void:
	_lib = GunPlaceholderParts.build_library()
	_same_gun()
	_retier()
	_cost()
	_save()
	await _bench()
	await _scrap()
	print("infusion probe: %d ok, %d FAIL" % [_pass, _fail])
	for c in root.get_children():
		c.queue_free()
	await _ticks(2)
	quit(1 if _fail > 0 else 0)


## Every stat of `a` and `b` alike but damage; damage in the ratio `k`.
func _alike(a: GunGenerator.Result, b: GunGenerator.Result, k: float) -> String:
	if a.gun_name != b.gun_name or a.rarity != b.rarity or a.element_id != b.element_id \
			or a.alt_fire != b.alt_fire or str(a.modifiers) != str(b.modifiers):
		return "name/rarity/element/alt/modifiers: %s vs %s" % [a.gun_name, b.gun_name]
	for slot in a.recipe:
		if not b.recipe.has(slot) or a.recipe[slot] != b.recipe[slot]:
			return "part in slot %d" % slot
	for key in a.stats:
		var x := float(a.stats[key])
		var y := float(b.stats.get(key, NAN))
		if key == &"damage":
			if not is_equal_approx(y, x * k):
				return "damage %.3f vs %.3f x %.3f" % [y, x, k]
		elif not is_equal_approx(x, y):
			return "%s %.4f vs %.4f" % [key, x, y]
	return ""


# --- the same gun -----------------------------------------------------------------------

func _same_gun() -> void:
	var bad := []
	var n := 0
	for cls in [&"pistol", &"smg", &"rifle", &"shotgun", &"sniper", &"lmg", &"revolver", &"rocket_launcher"]:
		for s in 6:
			var seed_ := 7000 + s * 131
			var a := GunGenerator.generate(_lib, seed_, WeaponClass.builtin(cls), 2)
			var b := GunGenerator.generate(_lib, seed_, WeaponClass.builtin(cls), 7)
			var why := _alike(a, b, Tier.power_mult(7) / Tier.power_mult(2))
			n += 1
			if why != "":
				bad.append("%s %d: %s" % [cls, seed_, why])
	_ok("one seed at two tiers: the same gun except damage, by the tiers' step", bad.is_empty(),
			"%d guns  %s" % [n, str(bad.slice(0, 3))])


# --- retier -------------------------------------------------------------------------------

func _retier() -> void:
	var bad := []
	for s in 20:
		var cls: StringName = [&"pistol", &"rifle", &"shotgun", &"smg"][s % 4]
		var a := GunGenerator.generate(_lib, 9100 + s, WeaponClass.builtin(cls), 1)
		var fresh := GunGenerator.generate(_lib, 9100 + s, WeaponClass.builtin(cls), 6)
		GunGenerator.retier(a, 6)
		var why := _alike(fresh, a, 1.0)
		if why == "" and (a.tier != 6 or a.score != fresh.score):
			why = "tier %d, score %d vs %d" % [a.tier, a.score, fresh.score]
		if why != "":
			bad.append(why)
	_ok("a gun infused is the gun its seed makes at the new tier, score and all", bad.is_empty(),
			str(bad.slice(0, 3)))

	var forced := GunGenerator.generate(_lib, 4242, WeaponClass.builtin(&"rifle"), 2, 5)
	var forced_before := forced.gun_name
	var forced_dmg := float(forced.stats[&"damage"])
	GunGenerator.retier(forced, 5)
	_ok("a forced rarity stays the gun it is", forced.gun_name == forced_before and forced.rarity == 5
			and is_equal_approx(float(forced.stats[&"damage"]), forced_dmg * Tier.power_mult(5) / Tier.power_mult(2)))

	var ids := LegendaryTable.all_ids()
	if ids.is_empty():
		_ok("a legendary's signature survives (no legendaries to try)", true)
	else:
		var leg := LegendaryTable.get_def(ids[0])
		var low := GunGenerator.generate_legendary(_lib, 555, leg, 2)
		var high := GunGenerator.generate_legendary(_lib, 555, leg, 8)
		GunGenerator.retier(low, 8)
		_ok("a legendary's signature survives it", _alike(high, low, 1.0) == "" and low.legendary_id == leg.id,
				"%s: %s" % [leg.id, _alike(high, low, 1.0)])


# --- cost ---------------------------------------------------------------------------------

func _cost() -> void:
	_ok("a white gun, one tier from 1: COST_BASE", Infusion.cost(1, 1, 2) == int(Infusion.COST_BASE))
	_ok("more tiers cost more, each at its own price", Infusion.cost(1, 1, 4) > Infusion.cost(1, 1, 3) * 1.4
			and Infusion.cost(1, 5, 6) > Infusion.cost(1, 1, 2), "%d / %d / %d" % [Infusion.cost(1, 1, 3),
			Infusion.cost(1, 1, 4), Infusion.cost(1, 5, 6)])
	_ok("an infused legendary costs more than a white", Infusion.cost(5, 2, 5) > Infusion.cost(1, 2, 5) * 2.0,
			"%d against %d" % [Infusion.cost(5, 2, 5), Infusion.cost(1, 2, 5)])
	_ok("nothing gained costs nothing", Infusion.cost(3, 4, 4) == 0 and Infusion.cost(3, 5, 4) == 0)
	var g := GunInstance.from_result(GunGenerator.generate(_lib, 77, WeaponClass.builtin(&"pistol"), 4))
	_ok("never above the story tier, nor down to it",
			Infusion.why_not(g, 4, 99999).begins_with("Already") and Infusion.why_not(g, 3, 99999) != "")
	_ok("not without the scrap", Infusion.why_not(g, 6, 10).begins_with("Needs"))
	g.free()


# --- save ---------------------------------------------------------------------------------

func _save() -> void:
	var g := CharacterSave.make_gun({"class": "smg", "seed": 31337, "tier": 2, "rarity": -1}, _lib)
	var entry := CharacterSave.gun_entry(g)
	var up := Infusion.infuse_entry(entry, 6)
	var back := CharacterSave.from_dict(JSON.parse_string(JSON.stringify(
			{"version": 1, "guns": [up]})))
	var g2 := CharacterSave.make_gun(back.guns[0], _lib)
	_ok("a saved gun's infusion is its entry's tier, and it comes back infused",
			g2.tier == 6 and _alike(g.result, g2.result, Tier.power_mult(6) / Tier.power_mult(2)) == "",
			_alike(g.result, g2.result, Tier.power_mult(6) / Tier.power_mult(2)))
	_ok("and never down", int(Infusion.infuse_entry(up, 3).tier) == 6)
	g.free()
	g2.free()


# --- the bench ----------------------------------------------------------------------------

func _bench() -> void:
	var floor := StaticBody3D.new()
	floor.collision_layer = Layers.WORLD
	var fs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(40.0, 1.0, 40.0)
	fs.shape = box
	floor.add_child(fs)
	root.add_child(floor)
	floor.global_position = Vector3(0.0, -0.5, 0.0)
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
	var ars := PlayerArsenal.new()
	world.add_child(ars)
	# The fight is tier 1; the player has been to tier 4.
	pc.progress.story_tier = 4
	ars.setup(pc, gc, null, null, _lib, world, 1)
	var rng := RandomNumberGenerator.new()
	rng.seed = 9
	ars.fill_default(rng)
	var bench := Workbench.create()
	world.add_child(bench)
	bench.global_position = Vector3(0.0, 0.0, -1.6)
	cam.global_transform = Transform3D(Basis.looking_at(bench.use_point() - Vector3(0, 1.6, 0)),
			Vector3(0, 1.6, 0))
	await _frames(3)
	_ok("looking at the bench, it is the one in reach", ars.target_bench == bench)
	ars.interact()
	_ok("held R opens the bench's page", ars.inventory_open and ars.inventory_page == 2)

	var g := gc.gun
	var dmg0 := float(g.stats[&"damage"])
	var need := Infusion.cost(g.rarity, g.tier, 4)
	pc.progress.scrap = need - 1
	_ok("not enough scrap: refused, nothing spent", not ars.infuse(g) and g.tier == 1
			and pc.progress.scrap == need - 1)
	pc.progress.scrap = need + 5
	ars.bench_index = ars.bench_guns().find(g)
	var key := InputEventKey.new()
	key.pressed = true
	key.keycode = KEY_ENTER
	ars._bench_input(key)
	_ok("Enter infuses the gun in hand to the story tier, for its scrap", g.tier == 4
			and pc.progress.scrap == 5, "tier %d, %d scrap left" % [g.tier, pc.progress.scrap])
	_ok("and the gun in hand fires harder by the tiers' step", is_equal_approx(gc._stat(&"damage", 0.0),
			dmg0 * Tier.power_mult(4)), "%.1f from %.1f" % [gc._stat(&"damage", 0.0), dmg0])

	# A backpack gun breaks down; a kit gun does not.
	var spare := GunInstance.from_result(GunGenerator.generate(_lib, 808, WeaponClass.builtin(&"smg"), 3, 4))
	ars._adopt(spare)
	ars.loadout.backpack.append(spare)
	var worth := Infusion.salvage_value(4, 3)
	ars.bench_index = ars.bench_guns().find(spare)
	key.keycode = KEY_BACKSPACE
	ars._bench_input(key)
	var still := ars.loadout.backpack.has(spare)
	ars._bench_input(key)
	_ok("Backspace twice breaks a backpack gun down for scrap", still and not ars.loadout.backpack.has(spare)
			and pc.progress.scrap == 5 + worth, "+%d" % worth)
	_ok("a kit gun is not broken down", not ars.salvage(g) and ars.loadout.all_guns().has(g))

	# Walked away: the page closes.
	pawn.place(Vector3(8.0, 0.0, 8.0))
	await _frames(3)
	_ok("walking away closes the bench's page", not ars.inventory_open)
	world.queue_free()
	floor.queue_free()
	await _ticks(2)


# --- scrap --------------------------------------------------------------------------------

func _scrap() -> void:
	var world := Node3D.new()
	root.add_child(world)
	var pl := PlayerLevel.new()
	var src := Node.new()
	world.add_child(src)
	src.set_meta(PlayerLevel.SOURCE_META, pl)
	var foe := Pawn.spawn(world, Vector3.ZERO, 1, true, 64.0)
	await _ticks(2)
	DamageSystem.resolve(DamagePacket.new(100.0, null, src), foe.body)
	_ok("a kill drops scrap", pl.scrap == roundi(20 * Infusion.SCRAP_PER_XP), "%d" % pl.scrap)
	pl.reach_tier(5)
	pl.reach_tier(3)
	_ok("the story tier rises, never falls", pl.story_tier == 5)
	var cs := CharacterSave.new()
	cs.take_progress(pl)
	var pl2 := PlayerLevel.new()
	pl2.take(CharacterSave.from_dict(JSON.parse_string(JSON.stringify(cs.to_dict()))).progress_dict())
	_ok("the save keeps the scrap and the story tier", pl2.scrap == pl.scrap and pl2.story_tier == 5)
	world.queue_free()
	await _ticks(2)
