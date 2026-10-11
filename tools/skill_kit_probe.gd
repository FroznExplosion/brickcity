extends SceneTree

## The skill tree's real kit (Docs/Weapons/COMBAT_DESIGN.md 1.3, 4.2): the player's
## shield, the Overshield in the ability slot, and the Vanguard Brawler's melee nodes.
##
##     godot --headless --path . --script res://tools/skill_kit_probe.gd
##
##   tree       three limbs; the Brawler holds 4.2's four nodes; more ranks than points;
##              the shield capped like the health
##   shield     the player's pawn has a shield over its health: it takes a hit first, a
##              body shot that breaks it lets half the rest through, it recharges after
##              its wait and not before; the tree grows it and shortens the wait
##   ability    the slot holds the grapple until an ability is bought and put in it; the
##              Overshield doubles the shield and fills it, recharges, and runs out; a
##              reset puts the grapple back; the slot is saved
##   brawler    Kinetic Lunge reaches farther and carries the pawn in; Backstab is 2.5x from
##              behind only; Shockwave strips nearby shields, not far ones or the struck
##              one's twice; Vampiric Impact gives shield back and refills the gun on a
##              melee kill; the melee and the grapple recharge faster

var _pass := 0
var _fail := 0


func _init() -> void:
	print("skill kit probe")
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
	_tree()
	await _play()
	print("skill kit probe: %d ok, %d FAIL" % [_pass, _fail])
	for c in root.get_children():
		c.queue_free()
	await _ticks(2)
	quit(1 if _fail > 0 else 0)


# --- the tree -----------------------------------------------------------------------------

func _tree() -> void:
	var limbs := {}
	for n in SkillTree.NODES:
		limbs[n.limb] = true
	_ok("three limbs and the trunk", limbs.keys().size() == 4 and limbs.has(&"brawler")
			and limbs.has(&"survivor") and limbs.has(&"gunner"))
	var brawler := []
	for id in [&"kinetic_lunge", &"shockwave", &"backstab", &"vampiric_impact"]:
		if SkillTree.node(id).get("limb") == &"brawler":
			brawler.append(id)
	_ok("the Brawler holds the four nodes of 4.2", brawler.size() == 4)
	_ok("more ranks than a player ever has points", SkillTree.capacity() > PlayerLevel.LEVEL_MAX - 1,
			"%d ranks" % SkillTree.capacity())
	var t := SkillTree.new()
	for n in SkillTree.NODES:
		t.ranks[n.id] = int(n.ranks)
	_ok("the shield bought out is capped like the health",
			is_equal_approx(t.total(&"max_shield"), SkillTree.SHIELD_CAP)
			and is_equal_approx(t.total(&"max_health"), SkillTree.HEALTH_CAP))
	_ok("a flag node reads as what it does", t.describe(&"backstab").contains("2.5x")
			and not t.describe(&"backstab").contains("%"))


# --- in play ------------------------------------------------------------------------------

var _world: Node3D


func _enemy(at: Vector3, flesh: float, shield := 0.0, yaw := 0.0) -> Pawn:
	var e := Pawn.spawn(_world, at, 1, true, flesh)
	if shield > 0.0:
		var c := DefenseLayer.new()
		c.layer_type = &"shield"
		c.max_value = shield
		e.health.layer_configs.insert(0, c)
		e.health.impact_carries_over = true
		e.health.reset()
	e.intents.look_yaw = yaw
	return e


func _play() -> void:
	var floor := StaticBody3D.new()
	floor.collision_layer = Layers.WORLD
	var fs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(60.0, 1.0, 60.0)
	fs.shape = box
	floor.add_child(fs)
	root.add_child(floor)
	floor.global_position = Vector3(0.0, -0.5, 0.0)
	_world = Node3D.new()
	root.add_child(_world)
	var pawn := Pawn.spawn(_world, Vector3.ZERO, 0)
	pawn.moves = PawnMoves.new(pawn)
	var cam := Camera3D.new()
	_world.add_child(cam)
	cam.current = true
	var pc := PlayerController.new()
	pc.drive_uncaptured = true
	_world.add_child(pc)
	pc.possess(pawn, cam)
	var gc := GunController.new()
	gc.aim = cam
	gc.rng = RandomNumberGenerator.new()
	_world.add_child(gc)
	pawn.gun = gc
	var ars := PlayerArsenal.new()
	_world.add_child(ars)
	ars.setup(pc, gc, null, null, GunPlaceholderParts.build_library(), _world, 1)
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	ars.fill_default(rng)
	await _ticks(3)
	var pl := pc.progress
	var pool := pawn.health

	# --- the shield ---
	_ok("the player has a shield over the health", pool.layer_count() == 2
			and pool.layer_type_at(0) == &"shield" and pool.layer_type_at(1) == &"health"
			and is_equal_approx(pool.get_layer_value(0), PlayerArsenal.PLAYER_SHIELD))
	ars.apply_skills()
	_ok("and setting the skills again adds no second one", pool.layer_count() == 2)
	pool.apply_impact(80.0, &"")
	var through := (80.0 - PlayerArsenal.PLAYER_SHIELD) * CombatScale.SHIELD_GATE
	_ok("a body shot takes the shield first, and half the rest gets through",
			is_equal_approx(pool.get_layer_value(0), 0.0)
			and is_equal_approx(pool.get_layer_value(1), 100.0 - through),
			"%.1f / %.1f" % [pool.get_layer_value(0), pool.get_layer_value(1)])
	await _seconds(PlayerArsenal.SHIELD_DELAY - 1.0)
	var early := pool.get_layer_value(0)
	await _seconds(1.0 + PlayerArsenal.PLAYER_SHIELD / PlayerArsenal.SHIELD_RATE + 0.5)
	_ok("it recharges after its wait, not before", is_equal_approx(early, 0.0)
			and is_equal_approx(pool.get_layer_value(0), PlayerArsenal.PLAYER_SHIELD),
			"%.1f then %.1f" % [early, pool.get_layer_value(0)])
	_ok("and the health does not", is_equal_approx(pool.get_layer_value(1), 100.0 - through))

	pl.set_level(100)
	for id in [&"vitality", &"quick_hands", &"fleet_foot", &"deep_pockets", &"thick_skin",
			&"shield_cells", &"second_wind", &"fast_charge", &"layered_cells", &"flash_charge"]:
		while pl.tree.rank(id) < int(SkillTree.node(id).ranks) and pl.buy(id):
			pass
	var sc := pool.layer_configs[0]
	_ok("the tree grows the shield (had at once) and shortens its wait",
			is_equal_approx(sc.max_value, PlayerArsenal.PLAYER_SHIELD * (1.0 + SkillTree.SHIELD_CAP))
			and is_equal_approx(pool.get_layer_value(0), sc.max_value)
			and sc.regen_delay < PlayerArsenal.SHIELD_DELAY and sc.regen_rate > PlayerArsenal.SHIELD_RATE,
			"%.0f, wait %.1f s, %.0f/s" % [sc.max_value, sc.regen_delay, sc.regen_rate])
	_ok("the health's skill never compounds with the shield over it",
			is_equal_approx(pool.layer_configs[1].max_value, 100.0 * (1.0 + pl.tree.total(&"max_health"))))

	# --- the ability slot ---
	_ok("the slot holds the grapple to start", pl.ability() == &"grapple"
			and not pl.set_tactical(&"overshield") and not ars.use_ability())
	pl.buy(&"overshield")
	_ok("bought, the Overshield goes in the slot", pl.set_tactical(&"overshield")
			and pl.ability() == &"overshield")
	var normal := sc.max_value
	pool.apply_to_layer_type(30.0, &"shield", &"")
	_ok("Q: the shield doubled and full", ars.use_ability()
			and is_equal_approx(sc.max_value, normal * PlayerArsenal.OVERSHIELD_MULT)
			and is_equal_approx(pool.get_layer_value(0), sc.max_value), "%.0f" % pool.get_layer_value(0))
	_ok("and not again until it recharges", not ars.use_ability() and ars.ability_cool > 0.0)
	pl.add_xp(0)
	ars.apply_skills()
	_ok("a skill change while it holds keeps it", is_equal_approx(sc.max_value, normal * PlayerArsenal.OVERSHIELD_MULT))
	ars.overshield_left = 0.05
	# The arsenal counts it in process time.
	await create_timer(0.3).timeout
	_ok("it runs out: the shield back to its size, no more than that", is_equal_approx(sc.max_value, normal)
			and pool.get_layer_value(0) <= normal + 0.01,
			"%.0f of %.0f, %.2f s left" % [pool.get_layer_value(0), sc.max_value, ars.overshield_left])
	var saved := pl.to_dict()
	var back := PlayerLevel.from_dict(saved)
	_ok("the slot is saved", back.ability() == &"overshield")
	var cs := CharacterSave.new()
	cs.take_progress(pl)
	_ok("and in the character save", PlayerLevel.from_dict(cs.progress_dict()).ability() == &"overshield")
	pl.reset_tree()
	_ok("a reset puts the grapple back", pl.ability() == &"grapple")

	# --- the Brawler ---
	pl.set_level(100)
	pawn.place(Vector3.ZERO)
	pawn.intents.look_yaw = 0.0
	pawn.intents.look_pitch = 0.0
	await _ticks(3)
	var far := _enemy(Vector3(0.0, 0.0, -2.5), 1000.0)
	await _ticks(3)
	_ok("past the plain reach, a blow whiffs", pawn.melee().is_empty())
	_buy(pl, [&"heavy_hands", &"light_step", &"sprinter", &"vitality", &"quick_hands", &"fleet_foot",
			&"deep_pockets", &"thick_skin", &"kinetic_lunge"])
	_ok("Kinetic Lunge: reach", pawn.melee_lunge and pawn.melee_reach > 1.0)
	var feet0 := pawn.feet()
	var info := pawn.melee()
	await _ticks(6)
	_ok("Kinetic Lunge: the blow lands, and carries the pawn in", not info.is_empty()
			and info.get("lunged", false) and feet0.distance_to(pawn.feet()) > 0.3,
			"moved %.2f m" % feet0.distance_to(pawn.feet()))
	far.body.queue_free()
	pawn.place(Vector3.ZERO)
	await _ticks(3)

	var facing_away := _enemy(Vector3(0.0, 0.0, -1.2), 5000.0, 0.0, 0.0)
	await _ticks(3)
	var plain := (pawn.melee().result as DamageSystem.DamageResult).dealt
	_buy(pl, [&"brutal_rhythm", &"hook_shot", &"backstab"])
	var back_hit := (pawn.melee().result as DamageSystem.DamageResult).dealt
	facing_away.intents.look_yaw = PI
	await _ticks(2)
	var front_hit := (pawn.melee().result as DamageSystem.DamageResult).dealt
	_ok("Backstab: 2.5x from behind, nothing more from the front",
			is_equal_approx(back_hit, plain * PlayerArsenal.BACKSTAB_MULT) and is_equal_approx(front_hit, plain),
			"%.0f / %.0f / %.0f" % [plain, back_hit, front_hit])
	facing_away.body.queue_free()
	await _ticks(2)

	var blow := CombatScale.melee(1) * 1.5
	var struck := _enemy(Vector3(0.0, 0.0, -1.2), 500.0, blow * 0.9)
	var near := _enemy(Vector3(2.0, 0.0, -2.0), 500.0, 100.0)
	var away := _enemy(Vector3(-6.0, 0.0, -1.2), 500.0, 100.0)
	await _ticks(3)
	pawn.melee()
	_ok("without Shockwave a broken shield is only the one", is_equal_approx(near.health.get_layer_value(0), 100.0)
			and not struck.is_held() and not near.is_held())
	struck.health.reset()
	_buy(pl, [&"shockwave"])
	await _ticks(2)
	pawn.melee()
	_ok("Shockwave: a shield broken strips a quarter of the near ones", is_equal_approx(near.health.get_layer_value(0), 75.0)
			and is_equal_approx(away.health.get_layer_value(0), 100.0)
			and is_equal_approx(struck.health.get_layer_value(0), 0.0),
			"near %.0f, away %.0f" % [near.health.get_layer_value(0), away.health.get_layer_value(0)])
	_ok("Shockwave: the struck and the near are staggered, the far not", struck.is_held() and near.is_held()
			and not away.is_held() and struck.stagger_left > 0.5)
	var near_at := near.feet()
	await _ticks(6)
	_ok("and knocked away from the blow", near.feet().distance_to(pawn.feet()) > near_at.distance_to(pawn.feet()) + 0.1,
			"%.2f m" % (near.feet().distance_to(pawn.feet()) - near_at.distance_to(pawn.feet())))
	await _seconds(PlayerArsenal.SHOCKWAVE_STAGGER)
	_ok("for a moment only", not struck.is_held() and not near.is_held())
	for e in [struck, near, away]:
		e.body.queue_free()
	await _ticks(2)

	var weak := _enemy(Vector3(0.0, 0.0, -1.2), 10.0)
	await _ticks(3)
	_buy(pl, [&"iron_knuckles", &"quick_recovery", &"vampiric_impact"])
	pool.apply_to_layer_type(40.0, &"shield", &"")
	var low := pool.get_layer_value(0)
	gc.ammo = 0
	var kill := pawn.melee()
	_ok("Vampiric Impact: a melee kill gives half the shield back and refills the gun",
			not kill.is_empty() and (kill.result as DamageSystem.DamageResult).killed
			and is_equal_approx(pool.get_layer_value(0), minf(low + sc.max_value * PlayerArsenal.VAMPIRIC_SHIELD, sc.max_value))
			and gc.ammo == gc.mag_size(), "%.0f -> %.0f, ammo %d" % [low, pool.get_layer_value(0), gc.ammo])
	weak.body.queue_free()

	_ok("melee speed: the recovery is shorter", pawn.melee_speed > 1.0
			and pawn._melee_cool < MeleeStrike.RECOVERY, "%.2f s" % pawn._melee_cool)
	_ok("the grapple recharges faster", is_equal_approx(pawn.moves.cooldown_speed, 1.0 + pl.tree.total(&"ability_cooldown"))
			and pawn.moves.cooldown_speed > 1.0)
	_world.queue_free()
	floor.queue_free()
	await _ticks(2)


func _buy(pl: PlayerLevel, ids: Array) -> void:
	for id in ids:
		while pl.tree.rank(id) < int(SkillTree.node(id).ranks) and pl.buy(id):
			pass
