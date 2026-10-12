extends SceneTree

## Probe for the casebook's "Player is in a building" (Docs/Tactics, TacticsSense
## ways_in; Docs/AI.md 4.3): following the player in, by the route costs.
##
##     godot --headless --path . --script tools/inside_probe.gd
##
## A house 12 m square with a roof, its door in the south wall; the player in it.
## A. Readings: a soldier by the door reads "Player is in a building" and "A way
##    in close by"; one on the far side, "The way in is a long way round" and
##    "Breaching in is much the shorter"; the door bricked up, "No way in on
##    foot". The door it would watch is the house's door.
## B. The odds: close by, sweeping in by the door outweighs breaching; a long
##    way round, breaching outweighs the door; no way in, nobody walks in --
##    breach or hold outside.
## C. Its own way in: a soldier on the far side sent in on the breaching map
##    plants a charge where its path goes into the wall, blows it, and gets in.

const Arena := preload("res://tools/ai_arena.gd")
const STUD := 0.35

var _pass := 0
var _fail := 0
var a: Arena
var _tick := 0
var _stage := ""
var _t0 := 0.0
var _log := {}
var p: Pawn
var near: Soldier
var far: Soldier
var book: TacticsBook


func _init() -> void:
	print("inside probe")
	a = Arena.new(self, 91)
	book = TacticsBook.load_book()
	physics_frame.connect(_on_tick)


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _w(cx: float, cz: float, plates := 0) -> Vector3:
	return Vector3(cx * STUD, plates * 0.14, cz * STUD)


func _sense(so: Soldier) -> Dictionary:
	a.s.knowledge_of(1).saw(p, p.feet(), a.s.now())
	var c := so.contact()
	# In the game the sense asks the nav queue for the ways in and has them a
	# few ticks later (TacticsSense.ways_known); here they are looked up first,
	# in one go, so the reading is the one a soldier settles on.
	TacticsSense.ways_in(so, p.feet())
	return TacticsSense.read(so, c, {})


func _p(rows: Array, move: String) -> float:
	for r in rows:
		if r.move == move:
			return float(r.p)
	return 0.0


func _begin(stage: String) -> void:
	_stage = stage
	_t0 = a.s.now()
	_log.clear()
	match stage:
		"build":
			# The house: x 0..34, z 0..34 studs, 8 courses, a 4-stud door at
			# x 15..19 in the south wall (z = 0), and a roof.
			a.room(0, 0, 34, 34, 8, 15, 4, 1)
			a.bricks(Vector3i(0, 24, 0), Vector3i(34, 1, 34))
			p = a.player(_w(17, 20), 1e7, false, 0)
			near = a.soldier(_w(17, -20), 1, 11)
			far = a.soldier(_w(17, 40), 1, 12)
			for so in [near, far]:
				so.process_mode = Node.PROCESS_MODE_DISABLED


func _check(el: float) -> bool:
	match _stage:
		"build":
			if el < 0.5:
				return false
			print("A. readings")
			var sn := _sense(near)
			_ok("by the door: the player is in a building, a way in close by",
					sn.moment == "player_inside" and (sn.facts as Array).has("way_near"), "%s %s" % [sn.moment, sn.facts])
			var sf := _sense(far)
			_ok("on the far side: a long way round, and breaching much the shorter",
					sf.moment == "player_inside" and (sf.facts as Array).has("way_far")
					and (sf.facts as Array).has("breach_short"), "%s %s" % [sf.moment, sf.facts])
			var w := TacticsSense.ways_in(near, p.feet())
			_ok("the way out it would watch is the house's door",
					w.door != Vector3.INF and (w.door as Vector3).distance_to(_w(17, 0)) < 2.5, "door %v" % w.door)
			print("B. the odds")
			var on := book.odds(sn.moment, sn.facts, sn.amounts)
			var of := book.odds(sf.moment, sf.facts, sf.amounts)
			_ok("close by: in by the door outweighs breaching", _p(on, "sweep") + _p(on, "flash") > _p(on, "breach"),
					"sweep %.2f flash %.2f breach %.2f" % [_p(on, "sweep"), _p(on, "flash"), _p(on, "breach")])
			_ok("a long way round: breaching outweighs the door", _p(of, "breach") > _p(of, "sweep") + _p(of, "flash"),
					"breach %.2f sweep %.2f flash %.2f guard %.2f" % [_p(of, "breach"), _p(of, "sweep"), _p(of, "flash"),
					_p(of, "guard_exits")])
			# The door bricked up.
			a.bricks(Vector3i(15, 0, 0), Vector3i(4, 8, 1))
			TacticsSense._ways.clear()
			var sb := _sense(near)
			var ob := book.odds(sb.moment, sb.facts, sb.amounts)
			_ok("the door bricked up: no way in on foot", (sb.facts as Array).has("no_way"), str(sb.facts))
			_ok("and nobody walks in: breach, or hold outside", _p(ob, "sweep") + _p(ob, "flash") + _p(ob, "rush") < 0.001
					and _p(ob, "breach") + _p(ob, "guard_exits") + _p(ob, "wait") > 0.4,
					"breach %.2f guard %.2f wait %.2f" % [_p(ob, "breach"), _p(ob, "guard_exits"), _p(ob, "wait")])
			print("C. its own way in")
			# Its brain stays off: the probe walks it (move_to), its body moves.
			far.breach_way = true
			_log["blocks0"] = a.breached_blocks
			_stage = "breach"
			_t0 = a.s.now()
			return false
		"breach":
			var r := far.move_to(p.feet(), true)
			var inside := BTShelter.covered(a.s, far.pawn.feet())
			if not inside and el < 40.0:
				return false
			_ok("from the far side, on the breaching map: a charge planted where it goes in, blown, and in",
					inside and far.charges >= 1 and a.breached_blocks > int(_log.blocks0),
					"%d charge(s), %d bricks, inside %s after %.0f s (%s)" % [far.charges,
					a.breached_blocks - int(_log.blocks0), inside, el, far.state])
			return true
	return true


func _on_tick() -> void:
	_tick += 1
	if _tick == 2:
		_begin("build")
		return
	if _tick < 2:
		return
	a.tick()
	if not _check(a.s.now() - _t0):
		return
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
