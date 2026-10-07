extends SceneTree

## Probe for the roster's types fighting (Docs/AIRoster.md RO3, RO4).
##
##     godot --headless --path . --script tools/roster_types_probe.gd
##
## One small fight at a time, 100 m apart, the casebook deciding:
##   A. A melee type (Brawler): no gun, it runs in and hits.
##   B. A bomber (cannon fodder): on the cheap tier, it runs in, lights its fuse
##      and goes off; one shot dead on the way does not go off.
##   C. Cannon fodder is never promoted to the smart tier, however near it is.
##   D. A grenadier carries six grenades and the casebook knows it for one.
##   E. A leader's death breaks its squad, and its soldiers know.
##   F. The brute: a large body on the large map, shooting -- until its armour is
##      gone, when it becomes "Heavy Melee", drops the gun and charges (a phase).

const Arena := preload("res://tools/ai_arena.gd")

var _pass := 0
var _fail := 0
var a: Arena
var r: Roster
var _tick := 0
var _stage := ""
var _t0 := 0.0
var _so: Soldier
var _p: Pawn
var _log := {}
var _old: Array = []


func _init() -> void:
	print("roster types probe")
	a = Arena.new(self, 41)
	r = Roster.shared()
	physics_frame.connect(_on_tick)


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _hp(p: Pawn) -> float:
	return p.health.total_current()


func _retire_all() -> void:
	for x in _old:
		if not is_instance_valid(x):
			continue
		if x is Soldier:
			(x as Soldier).process_mode = Node.PROCESS_MODE_DISABLED
			(x as Soldier).pawn.body.process_mode = Node.PROCESS_MODE_DISABLED
			a.s.pawns.erase((x as Soldier).pawn)
		elif x is Pawn:
			a.s.pawns.erase(x)
			var id := (x as Pawn).get_instance_id()
			a.s.knowledge_of(1).contacts.erase(id)
			a.s.aggro_of(1).entries.erase(id)
			(x as Pawn).body.process_mode = Node.PROCESS_MODE_DISABLED
	_old.clear()


## A soldier of `type` at `x`, dressed as the game dresses it, and a player `off` from it.
func _typed(type: String, x: float, off: Vector3, player_hp: float, seed: int) -> Soldier:
	var so := a.soldier(Vector3(x, 0.0, 0.0), 1, seed)
	so.max_health = UnitCatalog.apply_health(so.pawn.health, StringName(type), 1)
	so.set_type(type, r)
	if off != Vector3.INF:
		_p = a.player(Vector3(x, 0.0, 0.0) + off, player_hp, true, seed)
		Arena.look(so.pawn, _p.eye.global_position)
		_old.append(_p)
	_old.append(so)
	return so


func _begin(stage: String) -> void:
	_retire_all()
	_stage = stage
	_t0 = a.s.now()
	_log.clear()
	match stage:
		"brawler":
			_so = _typed("brawler", -200.0, Vector3(0.0, 0.0, -10.0), 400.0, 61)
			_log["hp0"] = _hp(_p)
		"bomber":
			_so = _typed("bomber", -100.0, Vector3(0.0, 0.0, -12.0), 400.0, 62)
			_log["hp0"] = _hp(_p)
			# And one shot dead before it gets anywhere.
			var dud := _typed("bomber", -60.0, Vector3.INF, 0.0, 63)
			dud.pawn.health.apply_impact(1e9, &"")
			_log["dud"] = dud
		"fodder":
			_p = a.player(Vector3(0.0, 0.0, -6.0), 1e7, true, 5)
			_old.append(_p)
			var fod := _typed("bomber", 0.0, Vector3.INF, 0.0, 64)
			var rifle := _typed("rifleman", 30.0, Vector3.INF, 0.0, 65)
			var budget := ImportanceBudget.new()
			budget.agents = [fod, rifle]
			budget.players = [_p]
			for i in 6:
				budget.tick(a.s.now() + i * 1.0)
			_log["fod"] = fod
			_log["rifle"] = rifle
		"leader":
			_p = a.player(Vector3(100.0, 0.0, -40.0), 1e7, true, 6)
			_old.append(_p)
			var members: Array[Soldier] = [_typed("sergeant", 100.0, Vector3.INF, 0.0, 66),
					_typed("rifleman", 102.0, Vector3.INF, 0.0, 67), _typed("rifleman", 98.0, Vector3.INF, 0.0, 68)]
			var squad := Squad.make(a.s, root, members, 1)
			_log["squad"] = squad
			_log["before"] = squad.leader_lost or squad.broken
			members[0].pawn.health.apply_impact(1e9, &"")
			_so = members[1]
		"brute":
			_so = _typed("brute", 200.0, Vector3(0.0, 0.0, -16.0), 1e7, 69)
			_log["tag0"] = _so.name_tag.text
			_log["tall"] = _so.pawn.stand_height
			_log["nav_large"] = _so.nav == a.s.nav_for("large") and _so.nav != a.s.ai_nav
			_log["layers"] = _so.pawn.health.layer_count()


func _check(t: float) -> bool:
	match _stage:
		"brawler":
			if t < 9.0 and _so.melee_hits < 2:
				return false
			_ok("a melee type: no gun, it runs in and hits", _so.melee_hits >= 1 and _so.shots == 0 and _so.no_gun
					and float(_log.hp0) - _hp(_p) >= Soldier.MELEE_DAMAGE * 0.9 and _so.name_tag.text == "Brawler  ·  Melee",
					"%d blow(s), %d shot(s), \"%s\", %.1f s" % [_so.melee_hits, _so.shots, _so.name_tag.text, t])
			return true
		"bomber":
			if t < 10.0 and not _so.is_dead():
				return false
			var lost := float(_log.hp0) - _hp(_p)
			_ok("a bomber: on the cheap tier it runs in and goes off", _so.is_dead() and _so.tier == AgentTier.DIRECTED
					and lost > 20.0 and not _so.blast_hits.is_empty() and _so.shots == 0,
					"player lost %.0f hp after %.1f s; tier %s; \"%s\"" % [lost, t, "directed" if _so.tier == AgentTier.DIRECTED else "smart", _so.name_tag.text])
			var dud: Soldier = _log.dud
			_ok("one shot dead on the way does not go off", dud.is_dead() and dud.blast_hits.is_empty())
			return true
		"fodder":
			var fod: Soldier = _log.fod
			var rifle: Soldier = _log.rifle
			_ok("cannon fodder is never promoted, however near; the rifleman behind it is smart",
					fod.tier == AgentTier.DIRECTED and rifle.tier == AgentTier.SMART and fod.tier_cap == AgentTier.DIRECTED)
			var g := _typed("grenadier", 20.0, Vector3.INF, 0.0, 70)
			_ok("a grenadier carries six grenades, and the casebook knows it for one",
					g.grenades == 6 and g.type_facts.has("we_grenadier") and g.attack_kind == "grenadier" and not g.no_gun,
					"%d grenade(s), %s" % [g.grenades, g.type_facts])
			return true
		"leader":
			if t < 0.5:
				return false
			var squad: Squad = _log.squad
			var k := _so.knowledge()
			k.saw(_p, _p.feet(), a.s.now(), _so)
			var sense := TacticsSense.read(_so, k.of(_p), {})
			_ok("a leader's death breaks its squad, and its soldiers know",
					not bool(_log.before) and squad.leader_lost and squad.broken and sense.facts.has("leader_dead"),
					"morale %.2f, facts %s" % [squad.morale, sense.facts])
			return true
		"brute":
			if not _log.has("shot") and t >= 5.0:
				_log["shot"] = _so.shots
				_log["dist0"] = _so.pawn.feet().distance_to(_p.feet())
				# Strip its shield and its armour: the phase's moment.
				var h := _so.pawn.health
				var strip := 0.0
				for i in h.layer_count():
					if h.layer_type_at(i) != EnemyProfiles.FLESH:
						strip += h.get_layer_value(i)
				h.impact_carries_over = false
				for i in 4:
					h.apply_impact(strip, &"")
					if _so._layer_gone(EnemyProfiles.ARMOR):
						break
				h.impact_carries_over = true
				_log["t_strip"] = t
			if not _log.has("shot"):
				return false
			if t < float(_log.t_strip) + 12.0 and _so.melee_hits < 1:
				return false
			_ok("the brute: a large body on the large map, in layers, shooting",
					is_equal_approx(float(_log.tall), 2.6) and bool(_log.nav_large) and int(_log.layers) == 3
					and int(_log.shot) > 0 and str(_log.tag0) == "Brute  ·  Heavy Gunner",
					"%.1f m tall, %d layers, %d shot(s) in 5 s, \"%s\"" % [float(_log.tall), int(_log.layers), int(_log.shot), _log.tag0])
			_ok("its armour gone, it becomes Heavy Melee: drops the gun, shouts, and charges",
					_so.phase_changes == 1 and _so.attack_kind == "melee" and _so.no_gun and _so.name_tag.text == "Heavy Melee"
					and _so.type_facts.has("we_melee") and _so.melee_hits >= 1 and not _so.is_dead(),
					"phase %d, \"%s\", %d blow(s) %.1f s after the armour went" % [_so.phase_changes, _so.name_tag.text,
					_so.melee_hits, t - float(_log.t_strip)])
			return true
	return true


func _on_tick() -> void:
	_tick += 1
	if _tick == 2:
		_ok("the roster loads", r != null)
		_begin("brawler")
		return
	if _tick < 2:
		return
	a.tick()
	if _p != null and is_instance_valid(_p) and _so != null and is_instance_valid(_so):
		Arena.look(_p, _so.pawn.feet() + Vector3.UP * 1.4)
	if not _check(a.s.now() - _t0):
		return
	var order := ["brawler", "bomber", "fodder", "leader", "brute"]
	var i := order.find(_stage)
	if i + 1 < order.size():
		_begin(order[i + 1])
		return
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
