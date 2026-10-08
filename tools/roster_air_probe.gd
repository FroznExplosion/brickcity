extends SceneTree

## Probe for the roster's other bodies (Docs/AIRoster.md RO5): a type is the same
## recipe whatever it walks or flies on.
##
##     godot --headless --path . --script tools/roster_air_probe.gd
##
##   A. The flying bomber ("Weak Bomber Flyer"): on the cheap tier, no gun; it
##      dives at the player, comes down under the flyers' clearance, and goes
##      off. One shot dead in the air does not go off.
##   B. A drone ("Rifleman Flyer"): the casebook decides what it does -- its plan
##      is on it, its mode is the one the plan's move maps to -- it shoots, and
##      it keeps over the height field.
##   C. A hound: a small body on the small map, on the cheap tier; it runs in
##      and bites.

const Arena := preload("res://tools/ai_arena.gd")

var _pass := 0
var _fail := 0
var a: Arena
var r: Roster
var _tick := 0
var _stage := ""
var _t0 := 0.0
var _p: Pawn
var _f: Flyer
var _so: Soldier
var _log := {}
var _old: Array = []


func _init() -> void:
	print("roster air probe")
	a = Arena.new(self, 53)
	r = Roster.shared()
	physics_frame.connect(_on_tick)


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _retire_all() -> void:
	for x in _old:
		if not is_instance_valid(x):
			continue
		if x is Flyer:
			(x as Flyer).body.queue_free()
		elif x is Soldier:
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


func _flyer(type: String, at: Vector3, seed: int) -> Flyer:
	var f := Flyer.spawn(a.s, root, at, 1, a.rifle(seed))
	UnitCatalog.apply_health(f.health, StringName(type), 1)
	f.set_type(type, r)
	_old.append(f)
	return f


func _begin(stage: String) -> void:
	_retire_all()
	_stage = stage
	_t0 = a.s.now()
	_log.clear()
	match stage:
		"gnat":
			_p = a.player(Vector3(-200.0, 0.0, 0.0), 400.0, true, 1)
			_old.append(_p)
			_f = _flyer("gnat", Vector3(-200.0, 18.0, 30.0), 71)
			_log["hp0"] = _p.health.total_current()
			_log["tag"] = _f.name_tag.text
			_log["tier"] = _f.tier
			_log["no_gun"] = _f.no_gun
			_log["facts"] = _f.type_facts.duplicate()
			var dud := _flyer("gnat", Vector3(-200.0, 18.0, 200.0), 72)
			dud.health.apply_impact(1e9, &"")
			_log["dud"] = dud
		"drone":
			_p = a.player(Vector3(0.0, 0.0, 0.0), 1e7, true, 2)
			_old.append(_p)
			_f = _flyer("drone", Vector3(0.0, 16.0, 28.0), 73)
		"hound":
			_p = a.player(Vector3(200.0, 0.0, -10.0), 400.0, true, 3)
			_old.append(_p)
			_so = a.soldier(Vector3(200.0, 0.0, 0.0), 1, 74)
			_so.max_health = UnitCatalog.apply_health(_so.pawn.health, &"hound", 1)
			_so.set_type("hound", r)
			Arena.look(_so.pawn, _p.eye.global_position)
			_old.append(_so)
			_log["hp0"] = _p.health.total_current()


func _check(t: float) -> bool:
	match _stage:
		"gnat":
			if is_instance_valid(_f):
				_log["low"] = minf(float(_log.get("low", INF)), _f.body.global_position.y)
				_log["shots"] = _f.shots
				if t < 14.0:
					return false
			var lost := float(_log.hp0) - _p.health.total_current()
			_ok("the flying bomber is the bomber's recipe on a flyer: its name, the cheap tier, no gun",
					str(_log.tag) == "Weak Bomber Flyer" and int(_log.tier) == AgentTier.DIRECTED and bool(_log.no_gun)
					and (_log.facts as Array).has("we_bomber") and (_log.facts as Array).has("we_flyer"),
					"\"%s\", %s" % [_log.tag, _log.facts])
			_ok("it dives under the flyers' clearance, and goes off on the player",
					not is_instance_valid(_f) and lost > 20.0 and float(_log.get("low", INF)) < Flyer.CLEARANCE
					and int(_log.get("shots", 0)) == 0,
					"player lost %.0f hp after %.1f s; it came down to %.1f m" % [lost, t, float(_log.get("low", INF))])
			var dud: Flyer = _log.dud
			_ok("one shot dead in the air does not go off", is_instance_valid(dud) and dud.is_dead() and dud.blast_hits.is_empty())
			return true
		"drone":
			if t < 14.0:
				return false
			var b := _f.book
			var mapped := not b.is_empty() and BookCombatPolicy.AIR.has(str(b.move))
			_ok("a drone decides from the casebook: its plan is on it, and its mode is that move's",
					_f.name_tag.text == "Drone  ·  Rifleman Flyer" and mapped and (b.facts as Array).has("we_flyer")
					and float(b.amounts.dist) > 5.0,
					"\"%s\": %s -> %s at %.0f m" % [_f.name_tag.text, b.get("moment"), b.get("move"), float(b.get("amounts", {}).get("dist", 0.0))])
			_ok("it shoots, and keeps over the height field", _f.shots > 0 and _f.lowest_clearance >= Flyer.CLEARANCE - 1.0,
					"%d shot(s), never lower than %.1f m" % [_f.shots, _f.lowest_clearance])
			return true
		"hound":
			if t < 9.0 and _so.melee_hits < 1:
				return false
			var lost := float(_log.hp0) - _p.health.total_current()
			_ok("a hound: a small body on the small map, the cheap tier, no gun",
					is_equal_approx(_so.pawn.stand_height, 0.6) and _so.nav == a.s.nav_for("small") and _so.nav.get_span() == 1
					and _so.tier == AgentTier.DIRECTED and _so.no_gun and _so.name_tag.text == "Hound  ·  Weak Melee",
					"%.1f m tall, \"%s\"" % [_so.pawn.stand_height, _so.name_tag.text])
			_ok("it runs in and bites", _so.melee_hits >= 1 and lost >= Soldier.MELEE_DAMAGE * 0.9 and _so.shots == 0,
					"%d bite(s), player lost %.0f hp after %.1f s" % [_so.melee_hits, lost, t])
			return true
	return true


func _on_tick() -> void:
	_tick += 1
	if _tick == 2:
		_ok("soldiers and flyers wear the same name tag", r != null and Soldier.TAG_ENEMY == TypeKit.TAG_ENEMY
				and is_equal_approx(Soldier.TAG_RANGE, TypeKit.TAG_RANGE))
		_begin("gnat")
		return
	if _tick < 2:
		return
	a.tick()
	if not _check(a.s.now() - _t0):
		return
	var order := ["gnat", "drone", "hound"]
	var i := order.find(_stage)
	if i + 1 < order.size():
		_begin(order[i + 1])
		return
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
