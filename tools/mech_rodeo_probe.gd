extends SceneTree

## Probe for rodeo (Docs/AIRoster.md 4.5, 5, 6 G5; RO8): the loop of section 5,
## whole, and the mech's answers to a rider.
##
##     godot --headless --path . --script tools/mech_rodeo_probe.gd
##
## A. The loop, on the casebook as it is: the player's mech holds and fights;
##    the enemy mech stays on it. The pilot goes round behind the enemy mech
##    unseen and climbs on. Unnoticed, the rider draws nothing; noticed, a spike.
##    The mech smokes it off -- costing its own shield -- and, its smoke spent,
##    turns to the rider behind it. The rider gets straight back on (the bait),
##    plants the charge, and the hatch is off. Then the enemy has to choose:
##    turn the open side away, back off, bail out, or turn on the rider.
## B. Who may climb: not a mech of your own side, not from far off.
## C. Scrape: told to, the mech walks under bricks low enough to take the rider
##    off -- over its head, under the rider's.
## D. Crush: told to, it backs hard into the wall behind it.
## E. Escort: its soldiers near and told to fight on, they shoot the rider.
## F. The rodeo mod: a Boarder goes round behind the player's mech (the player in
##    it), climbs on, plants, gets off before it goes -- and the hatch is off.
## G. The player's answer: electric smoke throws a Boarder off, and it comes
##    back for another go.

const Arena := preload("res://tools/ai_arena.gd")

var _pass := 0
var _fail := 0
var a: Arena
var mech_nav: AINav
var _tick := 0
var _stage := ""
var _t0 := 0.0
var _log := {}
var pm: MechBrain      # the player's mech
var em: MechBrain      # the enemy's
var pilot: Pawn
var guards: Array = []
var boarder: Soldier


func _init() -> void:
	print("mech rodeo probe")
	a = Arena.new(self, 53)
	physics_frame.connect(_on_tick)


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _bare(feet: Vector3, yaw: float, team: int) -> Mech:
	var m := Mech.spawn(root, feet, yaw, team)
	var g := GunInstance.from_result(GunGenerator.generate(a.lib, 5 + team + _tick, WeaponClass.builtin(&"lmg"), 1))
	g.visible = false
	m.arm.add_child(g)
	m.gun.equip(g)
	m.gun.rng = a.s.rng
	m.gun.on_structure_hit = a.structure_hit
	return m


func _mech(feet: Vector3, yaw: float, team: int, tree: BehaviorTree, type := "medium_gunner") -> MechBrain:
	var br := MechBrain.attach(a.s, _bare(feet, yaw, team), mech_nav, tree, team)
	br.mech.set_type(type, Roster.shared())
	return br


## The enemy's mech with a soldier inside: a heavy, so it lasts the loop against
## the player's medium.
func _crewed(feet: Vector3, yaw: float) -> MechBrain:
	var br := _mech(feet, yaw, 1, MechTree.enemy(), "heavy_gunner")
	var so := a.soldier(feet + Vector3(5.0, 0.0, 5.0), 1, 70 + _tick)
	br.mech.mount(so.pawn, true)
	return br


func _retire(x: Variant) -> void:
	if x is MechBrain:
		var br := x as MechBrain
		br.enabled = false
		br.mech.gun.set_trigger(false)
		if br.mech.rodeo.rider != null:
			br.mech.rodeo.drop("jumped")
		_forget(br.mech.pawn)
	elif x is Soldier:
		(x as Soldier).process_mode = Node.PROCESS_MODE_DISABLED
		(x as Soldier).pawn.body.process_mode = Node.PROCESS_MODE_DISABLED
		_forget((x as Soldier).pawn)
	elif x is Pawn:
		_forget(x)


func _forget(p: Pawn) -> void:
	if p == null or not is_instance_valid(p):
		return
	a.s.pawns.erase(p)
	for team in [0, 1]:
		a.s.knowledge_of(team).contacts.erase(p.get_instance_id())
	a.s.aggro_of(1).entries.erase(p.get_instance_id())


## A book that always answers a rider with `move` (if it can).
func _sure(move: String) -> void:
	var b := TacticsBook.load_book()
	b.moments["mech_ridden"].weights = {move: 100.0, "m_fire": 0.01}
	a.s.policy = BookCombatPolicy.new(b)


func _behind(m: Mech, d: float) -> Vector3:
	return m.feet() + Basis(Vector3.UP, m.motor.torso_yaw).z * d


func _aggro(p: Pawn) -> float:
	return a.s.aggro_of(1).value(p)


func _begin(stage: String) -> void:
	_stage = stage
	_t0 = a.s.now()
	_log.clear()
	match stage:
		"loop":
			pm = _mech(Vector3(0.0, 0.0, 0.0), 0.0, 0, MechTree.companion())
			pm.order = MechBrain.Order.HOLD
			pm.order_point = pm.mech.feet()
			# A light gun, so the enemy mech lasts the loop: this gate is about the
			# rider, not who wins the duel.
			pm.mech.gun.damage_mult = 1.0
			em = _crewed(Vector3(0.0, 0.0, -50.0), PI)
			# The pilot, out of it: behind a wall six metres high, off to the side.
			a.bricks(Vector3i(int(28.0 / Arena.STUD), 0, int(-12.0 / Arena.STUD)), Vector3i(1, 16, int(24.0 / Arena.STUD)))
			mech_nav.clear_cache()
			pilot = a.player(Vector3(32.0, 0.0, 0.0), 1e6, false, 0)
			var r := em.mech.rodeo
			r.climbed.connect(func(_p: Pawn) -> void:
				_log["climbs"] = int(_log.get("climbs", 0)) + 1)
			r.noticed.connect(func(p: Pawn) -> void:
				if not _log.has("noticed_at"):
					_log["noticed_at"] = a.s.now()
					_log["aggro_noticed"] = _aggro(p))
			r.smoked.connect(func() -> void:
				if not _log.has("smoke_at"):
					_log["smoke_at"] = a.s.now()
					_log["shield_after"] = em.mech.layers.value(MechLayers.SHIELD))
			r.dropped.connect(func(_p: Pawn, why: String) -> void:
				if why == "smoke" and not _log.has("dropped_at"):
					_log["dropped_at"] = a.s.now()
					_log["hp_after_smoke"] = pilot.health.total_current())
			r.charge_planted.connect(func() -> void: _log["planted_at"] = a.s.now())
			r.charge_blew.connect(func() -> void: _log["blew_at"] = a.s.now())
		"who":
			_retire(pm)
			_retire(em)
			var friend := _mech(Vector3(150.0, 0.0, 0.0), 0.0, 0, MechTree.companion())
			var foe := _crewed(Vector3(180.0, 0.0, 0.0), 0.0)
			var p := a.player(_behind(friend.mech, 2.5), 1e6, false, 0)
			var own := friend.mech.rodeo.can_climb(p)
			p.place(foe.mech.feet() + Vector3(20.0, 0.0, 0.0))
			var far := foe.mech.rodeo.can_climb(p)
			p.place(_behind(foe.mech, 2.5))
			var near := foe.mech.rodeo.can_climb(p)
			_log["ok"] = not own and not far and near
			_retire(friend)
			_retire(foe)
			_retire(p)
		"scrape":
			_sure("m_scrape")
			em = _crewed(Vector3(-150.0, 0.0, 0.0), 0.0)
			# A slab over the street ahead, 7.1 to 7.6 m up: over a mech's head
			# (6.7 m), under a rider's.
			var lo := Vector3(-150.0 - 6.0, 0.0, -20.0)
			a.bricks(Vector3i(int(lo.x / Arena.STUD), 17 * 3, int(lo.z / Arena.STUD)),
					Vector3i(int(12.0 / Arena.STUD), 1, int(8.0 / Arena.STUD)))
			mech_nav.clear_cache()
			pilot = a.player(_behind(em.mech, 2.5), 1e6, false, 0)
			_log["low"] = em.find_low_spot()
			em.mech.rodeo.climb(pilot)
		"crush":
			_retire(em)
			_retire(pilot)
			_sure("m_crush")
			em = _crewed(Vector3(-150.0, 0.0, 150.0), 0.0)
			# A wall across its back, five metres behind it, three storeys high.
			var z := 150.0 + 5.0
			a.bricks(Vector3i(int((-150.0 - 8.0) / Arena.STUD), 0, int(z / Arena.STUD)),
					Vector3i(int(16.0 / Arena.STUD), 22, 3))
			pilot = a.player(_behind(em.mech, 2.5), 1e6, false, 0)
			_log["wall"] = em.wall_behind()
			em.mech.rodeo.climb(pilot)
		"escort":
			_retire(em)
			_retire(pilot)
			_sure("m_fire")
			em = _crewed(Vector3(150.0, 0.0, 150.0), 0.0)
			pilot = a.player(_behind(em.mech, 2.5), 1e6, false, 0)
			guards = []
			for k in 3:
				var so := a.soldier(em.mech.feet() + Vector3(-12.0 + 12.0 * k, 0.0, -18.0), 1, 80 + k)
				guards.append(so)
			_log["hp0"] = pilot.health.total_current()
			em.mech.rodeo.climb(pilot)
		"mod", "counter":
			_retire(em)
			_retire(pilot)
			for g in guards:
				_retire(g)
			guards = []
			if pm != null:
				_retire(pm)
			a.s.policy = BookCombatPolicy.new()
			var at := Vector3(0.0, 0.0, 200.0) if stage == "mod" else Vector3(0.0, 0.0, -200.0)
			# The player's mech with the player in it: the player drives, not its brain.
			pm = _mech(at, 0.0, 0, MechTree.companion())
			pm.enabled = false
			pm.mech.occupy()
			boarder = a.soldier(at + Vector3(4.0, 0.0, 24.0), 1, 90)
			boarder.max_health = UnitCatalog.apply_health(boarder.pawn.health, &"boarder", 1)
			boarder.set_type("boarder", Roster.shared())
			# The side knows the mech is there.
			a.s.knowledge_of(1).saw(pm.mech.pawn, pm.mech.feet(), a.s.now())
			var r := pm.mech.rodeo
			r.climbed.connect(func(_p: Pawn) -> void:
				_log["climbs"] = int(_log.get("climbs", 0)) + 1
				_log["climb_at"] = a.s.now())
			r.dropped.connect(func(_p: Pawn, why: String) -> void:
				(_log.get_or_add("drops", []) as Array).append(why))


func _check(t: float) -> bool:
	match _stage:
		"loop":
			return _loop(t)
		"who":
			_ok("nobody climbs a mech of their own side, nor from far off; behind an enemy one they can", bool(_log.ok))
			return true
		"scrape":
			var drops: Array[String] = em.mech.rodeo.drops
			if t < 25.0 and drops.is_empty():
				return false
			_ok("scrape: the mech walks under bricks low enough to take the rider off",
					_log.low != Vector3.INF and drops.size() == 1 and drops[0] == "scraped",
					"spot %s; off by %s after %.1f s" % [_log.low, drops, t])
			return true
		"crush":
			var drops: Array[String] = em.mech.rodeo.drops
			if t < 15.0 and drops.is_empty():
				return false
			_ok("crush: it backs hard into the wall behind it, and the rider is crushed",
					float(_log.wall) > 0.0 and drops.size() == 1 and drops[0] == "crushed",
					"wall %.1f m behind; off by %s after %.1f s" % [float(_log.wall), drops, t])
			return true
		"mod":
			if t < 30.0 and not pm.mech.layers.hatch_off:
				return false
			var drops: Array = _log.get("drops", [])
			_ok("the rodeo mod: a Boarder climbs the player's mech from behind, plants, gets off, and the hatch is off",
					boarder.rodeo and pm.mech.layers.hatch_off and int(_log.get("climbs", 0)) >= 1 and drops.has("jumped")
					and not boarder.is_dead(),
					"%s; climbed %d time(s) after %.1f s; off by %s; hatch off at %.1f s" % [boarder.name_tag.text if boarder.name_tag != null else "?",
					int(_log.get("climbs", 0)), float(_log.get("climb_at", 0.0)) - _t0, drops, t])
			return true
		"counter":
			var r := pm.mech.rodeo
			# The player lets off the smoke as soon as it is on.
			if r.rider == boarder.pawn and r.smokes == 0 and a.s.now() - float(_log.get("climb_at", 0.0)) > 0.3:
				r.smoke()
			var drops: Array = _log.get("drops", [])
			if t < 40.0 and int(_log.get("climbs", 0)) < 2:
				return false
			_ok("smoke from the cockpit throws a Boarder off, and it comes back for another go",
					drops.size() >= 1 and drops[0] == "smoke" and int(_log.get("climbs", 0)) >= 2,
					"climbs %d, off by %s" % [int(_log.get("climbs", 0)), drops])
			return true
		"escort":
			if t < 10.0:
				return false
			var shots := 0
			for so in guards:
				shots += (so as Soldier).shots
			var lost := float(_log.hp0) - pilot.health.total_current()
			_ok("escort: its soldiers shoot the rider off their own mech",
					shots > 0 and lost > 0.0 and em.mech.rodeo.smokes == 0,
					"%d shot(s), the rider lost %.0f" % [shots, lost])
			return true
	return true


func _loop(t: float) -> bool:
	var r := em.mech.rodeo
	# 1-3: the player's mech goes in; the pilot goes round, behind the enemy mech.
	if t >= 5.0 and not _log.has("round"):
		_log["round"] = true
		_log["target_8"] = em._target == pm.mech.pawn
		pilot.place(_behind(em.mech, 2.5))
		_log["aggro_before"] = _aggro(pilot)
		_log["climbed_1"] = r.climb(pilot)
		_log["climb_at"] = a.s.now()
	if not _log.has("round"):
		return false
	var now := a.s.now()
	# Unnoticed: nothing gained.
	if not _log.has("aggro_quiet") and now - float(_log.climb_at) >= 0.8:
		_log["aggro_quiet"] = _aggro(pilot)
	# Smoked off: it minds its back (the rider is behind it).
	if _log.has("dropped_at") and not _log.has("watched") and em._target == pilot:
		_log["watched"] = now - float(_log.dropped_at)
	# 4: straight back on while the smoke is down (the bait), and plant.
	if _log.has("dropped_at") and not _log.has("climbed_2") and now - float(_log.dropped_at) >= 2.0:
		pilot.place(_behind(em.mech, 2.5))
		_log["climbed_2"] = r.climb(pilot)
	if r.rider == pilot and _log.has("climbed_2"):
		r.planting = true
	# 5: the hatch is off; the rider jumps down and the enemy chooses.
	if em.mech.layers.hatch_off and not _log.has("off_at"):
		_log["off_at"] = now
		if r.rider != null:
			r.drop("jumped")
	if _log.has("off_at") and not _log.has("choice"):
		var mv := str(em.book.get("move", ""))
		if (em.book.get("moment", "") == "mech_fight" and ["m_guard", "m_backoff", "m_bail"].has(mv)) \
				or em._target == pilot:
			_log["choice"] = "%s, target %s" % [mv, "the rider" if em._target == pilot else "the mech"]
	var done := _log.has("choice") or t > 50.0
	if not done:
		return false
	_ok("the loop, 1-3: the enemy mech is on the player's mech when the pilot goes round",
			bool(_log.target_8))
	_ok("climbed on from behind, unseen: unnoticed the rider draws nothing; noticed, a spike",
			bool(_log.climbed_1) and _log.has("noticed_at") and float(_log.aggro_quiet) <= float(_log.aggro_before) + 0.01
			and float(_log.aggro_noticed) >= AggroTable.RIDER_SPIKE * 0.9,
			"aggro %.1f -> %.1f unnoticed, %.0f noticed after %.1f s" % [float(_log.aggro_before), float(_log.get("aggro_quiet", -1.0)),
			float(_log.get("aggro_noticed", -1.0)), float(_log.get("noticed_at", 0.0)) - float(_log.climb_at)])
	var full := float(Roster.shared().derived("heavy_gunner").mech.shield)
	_ok("noticed, the mech smokes the rider off, hurting it and its own shield",
			_log.has("dropped_at") and float(_log.hp_after_smoke) < 1e6 and float(_log.shield_after) <= full - Rodeo.SMOKE_SHIELD + 0.01,
			"smoke %.1f s after it was noticed; shield %.0f" % [float(_log.get("smoke_at", 0.0)) - float(_log.get("noticed_at", 0.0)),
			float(_log.get("shield_after", -1.0))])
	_ok("its smoke spent, it turns on the rider behind it",
			_log.has("watched") and float(_log.watched) < 4.0, "after %.1f s" % float(_log.get("watched", -1.0)))
	_ok("4: back on while the smoke is down, the charge is planted and the hatch is off",
			bool(_log.get("climbed_2", false)) and _log.has("planted_at") and _log.has("off_at") and r.smokes == 1,
			"planted %.1f s after the second climb, off %.1f s later" % [float(_log.get("planted_at", 0.0)) - float(_log.get("dropped_at", 0.0)) - 2.0,
			float(_log.get("blew_at", 0.0)) - float(_log.get("planted_at", 0.0))])
	_ok("5: the enemy chooses -- turns the open side away, backs off, bails out, or turns on the rider",
			_log.has("choice"), str(_log.get("choice", "nothing in %.0f s" % t)))
	return true


func _on_tick() -> void:
	_tick += 1
	if _tick == 2:
		mech_nav = MechBrain.mech_nav(a.s.ai_world)
		_begin("loop")
		return
	if _tick < 2:
		return
	a.tick()
	mech_nav.service(800)
	if not _check(a.s.now() - _t0):
		return
	var order := ["loop", "who", "scrape", "crush", "escort", "mod", "counter"]
	var i := order.find(_stage)
	if i + 1 < order.size():
		_begin(order[i + 1])
		return
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
