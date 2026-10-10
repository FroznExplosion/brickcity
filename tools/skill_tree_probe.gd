extends SceneTree

## The player level and the skill tree (Docs/Weapons/COMBAT_DESIGN.md 1.3, SkillTree,
## PlayerLevel, SkillScreen).
##
##     godot --headless --path . --script res://tools/skill_tree_probe.gd
##
##   data      every node sits in the grid, once; its parents are real and below it;
##             the screen's arrows reach every node
##   size      the tree holds more ranks than level 100 gives points: no one fills it
##   health    the health nodes, all bought, are the +30% cap and no more
##   tiers     a tier opens on points spent ANYWHERE: points on one limb open the others;
##             by level 40 every tier, on every limb, can take a point
##   buying    not past a node's ranks, not without a point; a reset gives all back
##   level     XP levels up, a point a level, to 100 and no further
##   save      the level, XP and skills come back from a save; a save that holds more
##             than its level allows is trimmed, not trusted
##   kills     a kill pays the player whose source it was, once; not a kill of their own
##             side, nor a source that is no player's; a burn that kills pays too
##   effects   the skills reach the hands and the body: reload, magazine, alt-fire,
##             grenades, move speed, health and its regen -- and health never compounds

var _pass := 0
var _fail := 0


func _init() -> void:
	print("skill tree probe")
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


func _seconds(s: float) -> void:
	await _ticks(int(ceil(s * Engine.physics_ticks_per_second)))


func _run() -> void:
	_data()
	_tiers()
	_level()
	_save()
	await _kills()
	await _effects()
	print("skill tree probe: %d ok, %d FAIL" % [_pass, _fail])
	for c in root.get_children():
		c.queue_free()
	await _ticks(2)
	quit(1 if _fail > 0 else 0)


# --- data ---------------------------------------------------------------------------

func _data() -> void:
	var seen := {}
	var cells := {}
	var bad := []
	for n in SkillTree.NODES:
		if seen.has(n.id):
			bad.append("%s twice" % n.id)
		seen[n.id] = true
		var cell := Vector2i(int(n.col), int(n.tier))
		if cells.has(cell):
			bad.append("%s on %s's cell" % [n.id, cells[cell]])
		cells[cell] = n.id
		if int(n.col) < 0 or int(n.col) >= SkillTree.COLS or int(n.tier) < 0 or int(n.tier) >= SkillTree.TIERS:
			bad.append("%s off the grid" % n.id)
		if not SkillTree.LIMBS.has(n.limb) or not SkillTree.STATS.has(n.stat):
			bad.append("%s: limb or stat unknown" % n.id)
		for pid in n.parents:
			var p := SkillTree.node(pid)
			if p.is_empty() or int(p.tier) > int(n.tier) or (int(p.tier) == int(n.tier) and pid == n.id):
				bad.append("%s: parent %s" % [n.id, pid])
	_ok("every node in the grid, once, its parents real and not above it", bad.is_empty(), str(bad))
	var tops := 0
	for n in SkillTree.NODES:
		if int(n.tier) == SkillTree.TIERS - 1:
			tops += 1
	_ok("three limbs, each to the top tier", tops == 3, "%d at the top" % tops)

	# The arrows reach every node from the first.
	var reach := {&"vitality": true}
	var todo: Array = [&"vitality"]
	while not todo.is_empty():
		var id: StringName = todo.pop_back()
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var nb := SkillTree.neighbour(id, d)
			if not reach.has(nb):
				reach[nb] = true
				todo.append(nb)
	_ok("the screen's arrows reach every node", reach.size() == SkillTree.NODES.size(),
			"%d of %d" % [reach.size(), SkillTree.NODES.size()])

	_ok("more ranks than level 100 gives points: no one fills the tree",
			SkillTree.capacity() > PlayerLevel.LEVEL_MAX - 1,
			"%d ranks, %d points" % [SkillTree.capacity(), PlayerLevel.LEVEL_MAX - 1])

	var t := SkillTree.new()
	for n in SkillTree.NODES:
		t.ranks[n.id] = int(n.ranks)
	var raw := 0.0
	for n in SkillTree.NODES:
		if n.stat == &"max_health":
			raw += float(n.per) * int(n.ranks)
	_ok("the health nodes, all bought, are the +30% cap", is_equal_approx(raw, SkillTree.HEALTH_CAP)
			and is_equal_approx(t.total(&"max_health"), SkillTree.HEALTH_CAP), "%.2f" % raw)


# --- tiers and buying -----------------------------------------------------------------

func _tiers() -> void:
	var t := SkillTree.new()
	_ok("tier 0 is open from the start, tier 1 is not", t.tier_open(0) and not t.tier_open(1))
	_ok("a node of a shut tier is refused", not t.buy(&"light_step", 10)
			and t.why_not(&"light_step", 10).begins_with("Opens at"))
	for i in 5:
		t.buy(&"quick_hands", 10)
	_ok("not past a node's ranks", not t.buy(&"quick_hands", 10) and t.rank(&"quick_hands") == 5)
	_ok("five points on the left open tier 1 on the right", t.tier_open(1) and t.buy(&"light_step", 10))
	_ok("no point, no buy", not t.buy(&"vitality", 0) and t.why_not(&"vitality", 0) == "No skill points")

	# Level 40: every point down one side of the tree, lowest tiers first, until only
	# one is left -- then every top node, on every limb, can take it.
	var pl := PlayerLevel.new()
	pl.set_level(40)
	var order := SkillTree.NODES.duplicate()
	order.sort_custom(func(a, b): return int(a.tier) < int(b.tier))
	for n in order:
		if n.limb != &"gunner" and n.limb != &"trunk":
			continue
		while pl.points_free() > 1 and pl.tree.rank(n.id) < int(n.ranks) and pl.buy(n.id):
			pass
	var tops := []
	for n in SkillTree.NODES:
		if int(n.tier) == SkillTree.TIERS - 1 and pl.tree.why_not(n.id, pl.points_free()) == "":
			tops.append(n.id)
	_ok("by level 40 the top tier is open on every limb, from points spent on one",
			tops.size() == 3, "%d spent, open: %s" % [pl.tree.spent(), str(tops)])
	var before := pl.tree.open_tier()
	var at36 := PlayerLevel.new()
	at36.set_level(35)
	_ok("and not long before: at level 35 there are not points enough for the top tier",
			at36.points_total() < SkillTree.tier_gate(SkillTree.TIERS - 1), "top tier opens at %d spent"
			% SkillTree.tier_gate(SkillTree.TIERS - 1))
	pl.reset_tree()
	_ok("a reset gives every point back", pl.tree.spent() == 0 and pl.points_free() == 39 and before == 7)

	# The screen spends where its cursor is.
	var scr := SkillScreen.new()
	scr.progress = pl
	scr.cursor = &"vitality"
	var key := InputEventKey.new()
	key.pressed = true
	key.keycode = KEY_ENTER
	scr.handle(key)
	key.keycode = KEY_UP
	scr.handle(key)
	_ok("the screen: Enter spends on the cursor, Up moves it up the tree",
			pl.tree.rank(&"vitality") == 1 and scr.cursor == &"deep_pockets", String(scr.cursor))
	scr.free()


# --- level ----------------------------------------------------------------------------

func _level() -> void:
	var pl := PlayerLevel.new()
	var ups := []
	pl.leveled_up.connect(func(l): ups.append(l))
	_ok("level 1, no points", pl.level == 1 and pl.points_free() == 0)
	pl.add_xp(PlayerLevel.xp_to_next(1) + PlayerLevel.xp_to_next(2) + 5)
	_ok("XP levels up, as far as it reaches, a point a level", pl.level == 3 and pl.xp == 5
			and pl.points_free() == 2 and ups == [3], "level %d, %d xp" % [pl.level, pl.xp])
	_ok("the curve climbs", PlayerLevel.xp_to_next(40) > PlayerLevel.xp_to_next(10) * 2
			and PlayerLevel.xp_to_next(10) > PlayerLevel.xp_to_next(1),
			"%d / %d / %d" % [PlayerLevel.xp_to_next(1), PlayerLevel.xp_to_next(10), PlayerLevel.xp_to_next(40)])
	pl.add_xp(PlayerLevel.xp_to_reach(PlayerLevel.LEVEL_MAX) * 2)
	_ok("to 100 and no further", pl.level == PlayerLevel.LEVEL_MAX and pl.add_xp(1000) == 0
			and pl.points_total() == 99)


# --- save -----------------------------------------------------------------------------

func _save() -> void:
	var pl := PlayerLevel.new()
	pl.set_level(12)
	pl.add_xp(7)
	for i in 5:
		pl.buy(&"vitality")
	pl.buy(&"light_step")
	pl.buy(&"light_step")
	var cs := CharacterSave.new()
	cs.take_progress(pl)
	var back := CharacterSave.from_dict(JSON.parse_string(JSON.stringify(cs.to_dict())))
	var pl2 := PlayerLevel.new()
	pl2.take(back.progress_dict())
	_ok("the level, XP and skills come back from a save", pl2.level == 12 and pl2.xp == 7
			and pl2.tree.rank(&"vitality") == 5 and pl2.tree.rank(&"light_step") == 2
			and pl2.points_free() == 4)
	var old := PlayerLevel.new()
	old.take(CharacterSave.from_dict({"version": 1, "character": {"level": 3}}).progress_dict())
	_ok("an older save, without skills, reads as none", old.level == 3 and old.tree.spent() == 0)
	var cheat := PlayerLevel.from_dict({"level": 4, "xp": 0,
			"skills": {"vitality": 9, "light_step": 2, "gone_node": 3}})
	_ok("a save holding more than its level allows is trimmed", cheat.tree.spent() == 3
			and cheat.tree.rank(&"vitality") == 3 and cheat.tree.rank(&"light_step") == 0,
			str(cheat.tree.to_dict()))


# --- kills ----------------------------------------------------------------------------

func _kills() -> void:
	var world := Node3D.new()
	root.add_child(world)
	var pl := PlayerLevel.new()
	var src := Node.new()
	world.add_child(src)
	src.set_meta(PlayerLevel.SOURCE_META, pl)
	var other := Node.new()
	world.add_child(other)

	var foe := Pawn.spawn(world, Vector3(0, 0, 0), 1, true, 64.0)
	await _ticks(2)
	DamageSystem.resolve(DamagePacket.new(30.0, null, src), foe.body)
	_ok("a hit that does not kill pays nothing", pl.xp == 0 and pl.level == 1)
	DamageSystem.resolve(DamagePacket.new(50.0, null, src), foe.body)
	_ok("a kill pays the player whose source it was", pl.xp == PlayerLevel.kill_xp(foe.body)
			and pl.xp == 20, "%d XP" % pl.xp)
	var had := pl.xp
	DamageSystem.resolve(DamagePacket.new(50.0, null, src), foe.body)
	_ok("once", pl.xp == had)

	var friend := Pawn.spawn(world, Vector3(3, 0, 0), 0, true, 64.0)
	var stranger := Pawn.spawn(world, Vector3(6, 0, 0), 1, true, 64.0)
	await _ticks(2)
	DamageSystem.resolve(DamagePacket.new(100.0, null, src), friend.body)
	DamageSystem.resolve(DamagePacket.new(100.0, null, other), stranger.body)
	_ok("not a kill of the player's own side, nor one by no player's source", pl.xp == had)

	# A burn that kills pays whose fire it was.
	var burnt := Pawn.spawn(world, Vector3(9, 0, 0), 1, true, 64.0)
	await _ticks(2)
	var pk := DamagePacket.new(60.0, Elements.get_def(Elements.FIRE), src)
	pk.element_ratio = 1.0
	DamageSystem.resolve(pk, burnt.body)
	var alive := not burnt.health.is_dead()
	await _seconds(ElementStatus.BURN_SECONDS + 0.5)
	_ok("a burn that kills pays too", alive and burnt.health.is_dead() and pl.xp == had * 2,
			"%d XP" % pl.xp)
	world.queue_free()
	await _ticks(2)


# --- effects --------------------------------------------------------------------------

func _effects() -> void:
	var floor := StaticBody3D.new()
	floor.collision_layer = Layers.WORLD
	var fs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(80.0, 1.0, 80.0)
	fs.shape = box
	floor.add_child(fs)
	root.add_child(floor)
	floor.global_position = Vector3(0.0, -0.5, 0.0)
	var world := Node3D.new()
	root.add_child(world)
	var pawn := Pawn.spawn(world, Vector3.ZERO, 0)
	var cam := Camera3D.new()
	world.add_child(cam)
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
	ars.setup(pc, gc, null, null, GunPlaceholderParts.build_library(), world, 1)
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	ars.fill_default(rng)
	await _ticks(3)
	_ok("the player's pawn and gun carry the player's level", pawn.has_meta(PlayerLevel.SOURCE_META)
			and gc.get_meta(PlayerLevel.SOURCE_META) == pc.progress)

	var mag0 := gc.mag_size()
	var reload0 := _reload_time(gc)
	var hp0 := pawn.health.layer_configs[0].max_value
	var free_walk := await _walk(pawn, 30)
	var pl := pc.progress
	pl.set_level(100)
	for id in [&"quick_hands", &"steady_hands", &"fast_hands", &"big_mags", &"drum_feed",
			&"fleet_foot", &"light_step", &"deep_pockets", &"vitality", &"thick_skin",
			&"second_wind", &"hard_to_kill", &"grenadier", &"sharp_mind"]:
		while pl.tree.rank(id) < int(SkillTree.node(id).ranks) and pl.buy(id):
			pass
	var t := pl.tree
	_ok("reload: faster", _reload_time(gc) < reload0 * 0.9,
			"%.2f s against %.2f s" % [_reload_time(gc), reload0])
	_ok("magazine: bigger", gc.mag_size() > mag0, "%d against %d" % [gc.mag_size(), mag0])
	_ok("alt-fire: charges and recharges faster", is_equal_approx(gc.alt_mult, 1.0 + t.total(&"alt_speed"))
			and gc.alt_mult > 1.0)
	_ok("grenades: more, back sooner", ars.grenades_max == PlayerArsenal.GRENADES_MAX + 2
			and ars.grenade_recharge < PlayerArsenal.GRENADE_RECHARGE)
	var hp1 := pawn.health.layer_configs[0].max_value
	_ok("health: +30%, and had at once", is_equal_approx(hp1, hp0 * 1.3)
			and is_equal_approx(pawn.health.get_layer_value(0), hp1), "%.1f" % hp1)
	ars.apply_skills()
	ars.apply_skills()
	_ok("and it never compounds", is_equal_approx(pawn.health.layer_configs[0].max_value, hp1))
	pawn.health.apply_to_layer_type(50.0, &"health", &"")
	var hurt := pawn.health.get_layer_value(0)
	await _seconds(2.0)
	var early := pawn.health.get_layer_value(0)
	await _seconds(PlayerArsenal.REGEN_DELAY)
	_ok("health regen: after the wait, not before", is_equal_approx(early, hurt)
			and pawn.health.get_layer_value(0) > hurt + 1.0,
			"%.1f, %.1f, %.1f" % [hurt, early, pawn.health.get_layer_value(0)])
	await _seconds(1.0)
	var fast_walk := await _walk(pawn, 30)
	_ok("move speed: farther in the same time", fast_walk > free_walk * 1.1,
			"%.2f m against %.2f m" % [fast_walk, free_walk])
	pl.reset_tree()
	_ok("a reset takes it all back off", gc.mag_size() == mag0 and is_equal_approx(_reload_time(gc), reload0)
			and is_equal_approx(pawn.health.layer_configs[0].max_value, hp0)
			and pawn.health.get_layer_value(0) <= hp0 and is_equal_approx(pawn.move_mult, 1.0))
	world.queue_free()
	floor.queue_free()
	await _ticks(2)


## How long a reload of `gc`'s gun takes now.
func _reload_time(gc: GunController) -> float:
	gc.ammo = 0
	gc.reload()
	var t := gc._reload_total
	gc.cancel_reload()
	gc.ammo = gc.mag_size()
	return t


func _walk(p: Pawn, n: int) -> float:
	var from := p.feet()
	for i in n:
		p.intents.move = Vector3(1.0, 0.0, 0.0)
		await physics_frame
	p.intents.move = Vector3.ZERO
	var to := p.feet()
	for i in 10:
		await physics_frame
	return Vector2(to.x - from.x, to.z - from.z).length()
