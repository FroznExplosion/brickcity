extends SceneTree

## Probe for the two kinds of aircraft (Docs/AIRoster.md 7, R10; RO9).
##
##     godot --headless --path . --script tools/air_support_probe.gd
##
## A. A hover craft (the Skimmer): circles and makes slow passes over its area,
##    shoots the player in it -- and when the player leaves the area it stays
##    in it, at its edge.
## B. Shot down, it falls and crashes, hurting what is under it.
## C. A strafing run: warned of first, rounds along its line hurt a body on
##    the line and not one twenty metres off it; then it is gone, and the side
##    has to wait for the next.
## D. A bombing run on a target under a roof: six bombs along the line, the
##    bricks hit too.
## E. A plane can be shot down on its pass: its body takes a gun's hit like a
##    flyer's, and down, it crashes and the run is over.
## F. A soldier's "call in air" (the casebook's call_air) brings a run onto the
##    contact; while the planes are away it is not on offer.

const Arena := preload("res://tools/ai_arena.gd")

var _pass := 0
var _fail := 0
var a: Arena
var _tick := 0
var _stage := ""
var _t0 := 0.0
var _log := {}
var f: Flyer
var p: Pawn
var off: Pawn
var so: Soldier
var run: AirStrike


func _init() -> void:
	print("air support probe")
	a = Arena.new(self, 23)
	physics_frame.connect(_on_tick)


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _forget(x: Pawn) -> void:
	if x == null or not is_instance_valid(x):
		return
	a.s.pawns.erase(x)
	for team in [0, 1]:
		a.s.knowledge_of(team).contacts.erase(x.get_instance_id())


func _skimmer(at: Vector3) -> Flyer:
	var unit := UnitCatalog.get_unit(&"skimmer")
	var g := GunInstance.from_result(GunGenerator.generate(a.lib, 7, WeaponClass.builtin(StringName(unit.weapon)), 1))
	var fl := Flyer.spawn(a.s, root, at + Vector3.UP * 20.0, 1, g)
	UnitCatalog.apply_health(fl.health, &"skimmer", 1)
	fl.set_type(str(unit.get("recipe", "")), Roster.shared())
	fl.set_loiter(at)
	return fl


func _begin(stage: String) -> void:
	_stage = stage
	_t0 = a.s.now()
	_log.clear()
	match stage:
		"hover":
			f = _skimmer(Vector3.ZERO)
			p = a.player(Vector3(18.0, 0.0, 0.0), 5000.0, false, 0)
			_log["hp0"] = p.health.total_current()
			_log["far"] = 0.0
			_log["runs"] = 0
		"crash":
			# Under it, a body the crash should catch.
			var at := f.body.global_position
			off = a.player(Vector3(at.x, 0.0, at.z), 5000.0, false, 0)
			_log["hp0"] = off.health.total_current()
			f.health.apply_impact(1e9, &"")
		"strafe":
			_forget(p)
			_forget(off)
			a.s.air_of(1).parent = root
			p = a.player(Vector3(200.0, 0.0, 0.0), 5000.0, false, 0)
			off = a.player(Vector3(200.0, 0.0, 20.0), 5000.0, false, 0)
			so = a.soldier(Vector3(200.0, 0.0, -40.0), 1, 31)
			so.process_mode = Node.PROCESS_MODE_DISABLED
			_log["avail"] = a.s.air_of(1).available()
			run = a.s.air_of(1).request(p.feet(), so.pawn)
			run.warned.connect(func(_k: String, _at: Vector3) -> void: _log["warned"] = a.s.now())
			_log["warned"] = a.s.now()
			_log["kind"] = run.kind
			_log["hp_on"] = p.health.total_current()
			_log["hp_off"] = off.health.total_current()
		"bombs":
			_forget(p)
			_forget(off)
			a.s.air_of(1).ready_at = 0.0
			# A roof, 4 m up, over where the target stands.
			a.bricks(Vector3i(int(-210.0 / Arena.STUD), 10 * 3, int(-10.0 / Arena.STUD)),
					Vector3i(int(20.0 / Arena.STUD), 1, int(20.0 / Arena.STUD)))
			p = a.player(Vector3(-200.0, 0.0, 0.0), 5000.0, false, 0)
			_log["breached0"] = a.breached_blocks
			run = a.s.air_of(1).request(p.feet())
			_log["kind"] = run.kind
		"down":
			_forget(p)
			a.s.air_of(1).ready_at = 0.0
			p = a.player(Vector3(0.0, 0.0, 200.0), 5000.0, false, 0)
			run = a.s.air_of(1).request(p.feet(), null, "strafe")
			run.shot_down.connect(func(at: Vector3) -> void: _log["down_at"] = at)
			_log["pool"] = DamageSystem._find_health_pool(run.body) == run.health \
					and (run.body.collision_layer & Layers.PAWN) != 0
		"call":
			_forget(p)
			a.s.air_of(1).ready_at = 0.0
			var sure := TacticsBook.load_book()
			for m in sure.moments:
				sure.moments[m].weights = {"call_air": 100.0, "trade": 0.01, "hold": 0.01}
			a.s.policy = BookCombatPolicy.new(sure)
			p = a.player(Vector3(-200.0, 0.0, 200.0), 1e6, false, 0)
			so = a.soldier(Vector3(-200.0, 0.0, 170.0), 1, 33)
			Arena.look(so.pawn, p.chest())
			_log["runs0"] = a.s.air_of(1).runs


func _check(t: float) -> bool:
	match _stage:
		"hover":
			_log["far"] = maxf(float(_log.far), f.from_center())
			if f.state == "run" and not _log.has("in_run"):
				_log["runs"] = int(_log.runs) + 1
			if f.state == "run":
				_log["in_run"] = true
			else:
				_log.erase("in_run")
			if t >= 20.0 and not _log.has("left"):
				_log["left"] = true
				_log["hp20"] = p.health.total_current()
				_log["far20"] = _log.far
				p.place(Vector3(95.0, 0.0, 0.0))
			if t < 40.0:
				return false
			_ok("a hover craft circles and makes slow passes in its area, and shoots the player in it",
					int(_log.runs) >= 1 and f.shots > 0 and float(_log.hp20) < float(_log.hp0)
					and float(_log.far20) <= Flyer.LOITER + 6.0,
					"%d pass(es), %d shot(s), the player %.0f -> %.0f; never more than %.0f m out" % [int(_log.runs), f.shots,
					float(_log.hp0), float(_log.hp20), float(_log.far20)])
			_ok("the player leaves the area: it stays in it, at its edge",
					float(_log.far) <= Flyer.LOITER + 6.0 and f.from_center() > Flyer.LOITER * 0.5,
					"at most %.0f m from its centre; now %.0f m, the player %.0f m" % [float(_log.far), f.from_center(),
					Vector2(p.feet().x, p.feet().z).length()])
			return true
		"crash":
			if t < 8.0 and not f.crashed:
				return false
			var y := f.body.global_position.y
			_ok("shot down, it falls and crashes on what is under it",
					f.crashed and y < 2.0 and off.health.total_current() < float(_log.hp0),
					"down at %.1f m in %.1f s; under it %.0f -> %.0f" % [y, t, float(_log.hp0), off.health.total_current()])
			return true
		"strafe":
			if is_instance_valid(run) and run.rounds > 0 and not _log.has("first_round"):
				_log["first_round"] = a.s.now()
			if is_instance_valid(run) and t < 20.0:
				return false
			var on_lost := float(_log.hp_on) - p.health.total_current()
			var off_lost := float(_log.hp_off) - off.health.total_current()
			_ok("a strafing run is warned of first, and its rounds hurt a body on its line and not one 20 m off it",
					bool(_log.avail) and _log.kind == "strafe" and _log.has("first_round")
					and float(_log.first_round) - float(_log.warned) >= AirStrike.WARN_SECONDS - 0.1
					and on_lost > 0.0 and off_lost == 0.0,
					"first round %.1f s after the warning; on the line -%.0f, off it -%.0f" % [float(_log.get("first_round", 0.0)) - float(_log.warned), on_lost, off_lost])
			_ok("then it is gone, and the side waits for the next",
					not is_instance_valid(run) and not a.s.air_of(1).available() and a.s.air_of(1).request(p.feet()) == null)
			return true
		"bombs":
			if is_instance_valid(run) and t < 20.0:
				return false
			_ok("a bombing run on a target under a roof: six bombs along its line, the bricks hit too",
					_log.kind == "bombs" and (not is_instance_valid(run) or run.bombs == AirStrike.BOMBS)
					and a.breached_blocks > int(_log.breached0),
					"%s; blocks breached %d -> %d" % [_log.kind, int(_log.breached0), a.breached_blocks])
			return true
		"down":
			if is_instance_valid(run) and run.state == "pass" and run.rounds > 3 and not _log.has("hit"):
				_log["hit"] = true
				# The player's fire: what a gun's hits do to a body with a HealthPool.
				run.health.apply_impact(AirStrike.HEALTH + 1.0, &"")
			if is_instance_valid(run) and t < 20.0:
				return false
			_ok("a plane can be shot down on its pass: it crashes, and the run is over",
					bool(_log.pool) and _log.has("down_at"),
					"shot down at %s" % [_log.get("down_at", "-")])
			return true
		"call":
			if t < 12.0:
				return false
			var air := a.s.air_of(1)
			var called: Array = air.log[air.log.size() - 1] if air.runs > int(_log.runs0) else []
			_ok("a soldier's call for air brings a run onto the contact, and only one while the planes are away",
					air.runs == int(_log.runs0) + 1 and called.size() == 3 and called[2] == so.pawn
					and (called[1] as Vector3).distance_to(p.feet()) < 6.0,
					"%d run(s) called; on %s, the player at %s" % [air.runs - int(_log.runs0), called[1] if called.size() == 3 else "-", p.feet()])
			return true
	return true


func _on_tick() -> void:
	_tick += 1
	if _tick == 2:
		_begin("hover")
		return
	if _tick < 2:
		return
	a.tick()
	if not _check(a.s.now() - _t0):
		return
	var order := ["hover", "crash", "strafe", "bombs", "down", "call"]
	var i := order.find(_stage)
	if i + 1 < order.size():
		_begin(order[i + 1])
		return
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
