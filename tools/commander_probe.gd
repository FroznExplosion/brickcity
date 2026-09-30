extends SceneTree

## The commander (Docs/AI.md 9, AIPlan P9; Commander, Doctrine, ThreatProfile):
##
##     godot --headless --path . --script res://tools/commander_probe.gd
##
## First on paper: each player style gets its answer, clamped; rosters are only
## built units and never over budget; two styles give measurably different
## rosters (P9's gate). Then in an arena: the commander fields a squad through
## its host, sends it in file to where the enemy was last heard, orders an
## advance once the enemy is in sight, grows desperate as it loses men, and
## fields more when it is short and can pay.

const Arena := preload("res://tools/ai_arena.gd")
const LIMIT := 30 * 100

var _pass := 0
var _fail := 0
var a: Arena
var cm: Commander
var player: Pawn
var _tick := 0
var _stage := "paper"
var _t := 0.0
var _log := {}
var _spawn_at := Vector3(0.0, 0.0, 0.0)


func _init() -> void:
	print("commander probe")
	_paper()
	a = Arena.new(self, 31)
	physics_frame.connect(_on_tick)


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


# --- on paper -----------------------------------------------------------------

func _profile(kind: String) -> ThreatProfile:
	var p := ThreatProfile.new()
	p.evidence = 6.0
	match kind:
		"sniper":
			p.range_m = 45.0
			p.closeness = 0.05
		"rusher":
			p.range_m = 6.0
			p.closeness = 0.8
		"demolisher":
			p.destructiveness = 600.0
			p.range_m = 20.0
			p.closeness = 0.3
	return p


func _paper() -> void:
	print("\non paper")
	for kind in ["sniper", "rusher", "demolisher"]:
		_ok("a %s is read as one" % kind, _profile(kind).style() == kind, _profile(kind).style())
	_ok("with too little seen, the player is unknown", ThreatProfile.new().style() == "unknown")
	var d := Doctrine.new()
	d.update(_profile("sniper"), 0.0, 0.6)
	var sniper_roster := d.roster.duplicate()
	var sniper_aggr := d.aggression
	d.update(_profile("rusher"), 0.0, 0.6)
	var rusher_roster := d.roster.duplicate()
	var rusher_aggr := d.aggression
	d.update(_profile("demolisher"), 0.0, 0.6)
	var demo_inside := d.inside_share
	_ok("against a sniper: more close-range troops and bolder",
			float(sniper_roster[&"assault"]) > float(Doctrine.BASE[&"assault"])
			and sniper_aggr > rusher_aggr, "assault %.1f, aggression %.2f vs %.2f" % [
			float(sniper_roster[&"assault"]), sniper_aggr, rusher_aggr])
	_ok("against a rusher: breachers and veterans, and it holds more",
			float(rusher_roster[&"breacher"]) > float(Doctrine.BASE[&"breacher"])
			and float(rusher_roster[&"veteran"]) > float(Doctrine.BASE[&"veteran"]))
	_ok("against a demolisher: fewer put inside buildings", demo_inside < 0.4, "%.2f" % demo_inside)
	var clamped := true
	for r in [sniper_roster, rusher_roster]:
		for id in Doctrine.BASE:
			var k := float(r[id]) / float(Doctrine.BASE[id])
			if k < 0.5 - 1e-4 or k > 2.0 + 1e-4:
				clamped = false
	_ok("no counter is a hard counter: every weight within x0.5..x2 of its base", clamped)
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	var only_built := true
	var in_budget := true
	var counts := {"sniper": {}, "rusher": {}}
	for style in counts:
		d.update(_profile(style), 0.0, 0.6)
		for i in 300:
			var budget := rng.randf_range(3.0, 20.0)
			var kinds := d.draw(4, budget, rng)
			var cost := 0.0
			for k in kinds:
				cost += UnitCatalog.points(k)
				if not bool(UnitCatalog.get_unit(k).built):
					only_built = false
				counts[style][k] = int(counts[style].get(k, 0)) + 1
			if cost > budget + 1e-4:
				in_budget = false
	_ok("rosters are only units the game has", only_built)
	_ok("and never cost more than the budget", in_budget)
	var close_s := int(counts.sniper.get(&"assault", 0)) + int(counts.sniper.get(&"breacher", 0))
	var close_r := int(counts.rusher.get(&"assault", 0)) + int(counts.rusher.get(&"breacher", 0))
	var vet_s := int(counts.sniper.get(&"veteran", 0))
	var vet_r := int(counts.rusher.get(&"veteran", 0))
	_ok("two styles, two measurably different rosters (AIPlan P9)",
			abs(vet_r - vet_s) > 20 or abs(close_s - close_r) > 20,
			"sniper %s | rusher %s" % [counts.sniper, counts.rusher])
	# The map.
	var g := SectorGrid.new()
	var hot := Vector3(10.0, 0.0, 10.0)
	var cold := Vector3(200.0, 0.0, 200.0)
	g.note_loss(hot, 3.0)
	g.note_threat(hot + Vector3(40.0, 0.0, 0.0), 2.0)
	_ok("where men died is dangerous, and so is next door", g.danger(hot) > 5.0
			and g.danger(hot + Vector3(33.0, 0.0, 0.0)) > 0.0 and g.danger(cold) == 0.0,
			"%.1f there, %.1f next door, %.1f far off" % [g.danger(hot),
			g.danger(hot + Vector3(33.0, 0.0, 0.0)), g.danger(cold)])
	_ok("of the spots offered, it picks the safe one", g.safest([hot, cold]) == cold)
	var d0 := g.danger(hot)
	g.decay(PointsBattle.QUICK * 2.0)
	_ok("and it forgets, slowly", g.danger(hot) < d0 and g.danger(hot) > 0.0,
			"%.1f -> %.1f in %.0f s" % [d0, g.danger(hot), PointsBattle.QUICK * 2.0])
	# Fights nobody watches (Red Dawn's table).
	var r := PointsBattle.resolve(20.0, 8.0)
	_ok("20 points on 8: a decisive attacker win", r.outcome == PointsBattle.Outcome.DECISIVE_ATTACKER
			and is_equal_approx(float(r.defender_left), 8.0 * 0.2), "%s" % [r])
	r = PointsBattle.resolve(10.0, 10.0, true)
	_ok("even, against a building: the defender holds", r.outcome == PointsBattle.Outcome.STALEMATE
			or r.outcome == PointsBattle.Outcome.DEFENDER, "%s" % r.name)
	var even := PointsBattle.resolve(10.0, 10.0)
	var lop := PointsBattle.resolve(40.0, 5.0)
	_ok("an even fight takes longer than a one-sided one", float(even.seconds) > float(lop.seconds),
			"%.0f s vs %.0f s" % [float(even.seconds), float(lop.seconds)])
	var f := PointsBattle.Front.new()
	f.where = Vector3.ZERO
	f.attacker = 20.0
	f.defender = 8.0
	_ok("a front with a player near does not resolve on paper",
			not f.step(1000.0, [Vector3(30.0, 0.0, 0.0)]) and f.result.is_empty())
	_ok("and with nobody near, it does", f.step(1000.0, [Vector3(500.0, 0.0, 0.0)])
			and f.result.name == "decisive attacker win")
	_ok("vehicles and mechs are catalogued and costed, not yet fielded",
			UnitCatalog.UNITS.has(&"tank") and UnitCatalog.points(&"tank") > 10.0
			and not bool(UnitCatalog.get_unit(&"tank").built) and not (&"mech" in UnitCatalog.built()))


# --- in an arena -----------------------------------------------------------------

func _build() -> void:
	print("\nin an arena")
	# A wall between the spawn and where the player will be, so the first
	# squad has somewhere to travel before it sees anyone.
	a.bricks(Vector3i(-40, 0, int(-14.0 / Arena.STUD)), Vector3i(80, 6, 1))
	player = a.player(Vector3(0.0, 0.0, -60.0))
	cm = Commander.new()
	cm.name = "Commander"
	root.add_child(cm)
	cm.setup(a.s, 1)
	cm.alive_cap = 8
	cm.spawner = _spawn


## The host's side of it: four at the spawn point, a squad, back to the commander.
func _spawn(kinds: Array[StringName]) -> bool:
	var members: Array[Soldier] = []
	for i in kinds.size():
		var so := a.soldier(a.s.ai_nav.snap(_spawn_at + Vector3(-1.5 + i, 0.0, 0.0)), 1, 60 + i,
				float(UnitCatalog.get_unit(kinds[i]).hp))
		so.set_meta(&"unit", kinds[i])
		so.pawn.intents.look_yaw = 0.0
		members.append(so)
	var q := Squad.make(a.s, root, members, 1)
	cm.adopt(q)
	_log["spawned"] = int(_log.get("spawned", 0)) + 1
	return true


func _on_tick() -> void:
	_tick += 1
	if _tick == 1:
		_build()
	a.tick()
	var now := a.s.now()
	match _stage:
		"paper":
			if _tick >= 5:
				# The enemy was heard over there, a while back: the side knows
				# roughly where, not who is looking.
				a.s.knowledge_of(1).heard(player, Vector3(0.0, 0.0, -45.0), now - 10.0)
				cm.force_reinforce()
				_stage = "travel"
				_t = now
		"travel":
			Arena.look(player, Vector3(0.0, 1.0, 0.0))
			if cm.orders_given.has("MOVE") and not _log.has("move_at"):
				_log["move_at"] = now - _t
			if cm.orders_given.has("ADVANCE") and not _log.has("advance_at"):
				_log["advance_at"] = now - _t
			if _log.has("advance_at") or now - _t > 50.0:
				_log["squads"] = cm.squads.size()
				# Drop three of them: the side bleeds, and wants more.
				var d0 := cm.desperation
				var q: Squad = cm.squads[0]
				var alive := q.alive()
				for k in mini(3, alive.size()):
					alive[k].pawn.health.apply_impact(1e9, &"")
				_log["desp0"] = d0
				_stage = "losses"
				_t = now
		"losses":
			if now - _t > 2.0 and not _log.has("desp1"):
				_log["desp1"] = cm.desperation
				_log["spawned_before"] = int(_log.get("spawned", 0))
				cm.budget = 20.0
			if _log.has("desp1") and (int(_log.get("spawned", 0)) > int(_log.spawned_before)
					or now - _t > 20.0):
				_log["reinforced"] = int(_log.get("spawned", 0)) > int(_log.spawned_before)
				_stage = "done"
	if _tick >= LIMIT or _stage == "done":
		_finish()


func _finish() -> void:
	physics_frame.disconnect(_on_tick)
	_ok("it fields a squad through its host", int(_log.get("spawned", 0)) >= 1 and int(_log.get("squads", 0)) >= 1)
	_ok("with the enemy heard far off, it sends the squad there in file (MOVE)",
			_log.has("move_at"), "at %.1f s" % float(_log.get("move_at", -1.0)))
	_ok("and with the enemy in sight, it orders an advance on it",
			_log.has("advance_at"), "at %.1f s; orders %s" % [float(_log.get("advance_at", -1.0)), cm.orders_given])
	_ok("losing men makes it desperate", float(_log.get("desp1", 0.0)) > float(_log.get("desp0", 1.0)),
			"%.2f -> %.2f" % [float(_log.get("desp0", -1.0)), float(_log.get("desp1", -1.0))])
	_ok("short of strength and able to pay, it fields more", bool(_log.get("reinforced", false)))
	_ok("where its men fell is marked dangerous on its map", cm.sectors.danger(_spawn_at) > 0.0,
			"%.1f at the spawn" % cm.sectors.danger(_spawn_at))
	# The HQ: radio down, nobody called; officer dead, nothing decided.
	cm.budget = 30.0
	cm.radio_destroyed()
	_ok("radio down: no reinforcement, even pressed", not cm.force_reinforce())
	var f := cm.open_front(Vector3(900.0, 0.0, 900.0), 10.0, 10.0, false, false)
	cm.commander_killed()
	cm.think(1.0)
	_ok("commander and radio both gone: its side fights leaderless (x%.1f)" % Commander.LEADERLESS,
			is_equal_approx(f.defender, 10.0 * Commander.LEADERLESS), "%.1f" % f.defender)
	print("  log:")
	for l in cm.log:
		print("    " + l)
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
