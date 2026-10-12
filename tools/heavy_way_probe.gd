extends SceneTree

## Probe for the casebook's "Our armour makes the way in" (heavy_way; Docs/Tactics,
## TacticsSense.ask_way): a squad outside the player's building asks its mech to
## blast a doorway on its side, then walks in through it.
##
##     godot --headless --path . --script tools/heavy_way_probe.gd
##
## A house 12 m square with a roof, its only door in the south wall; the player
## in it; a soldier on the north side, where the walk round is long.
## A. The odds: with no heavy of ours near, the move is not possible; with our
##    mech near, it is, and the way it would ask for is in the north wall.
## B. The doorway: asked, the mech -- standing east, where its own line to the
##    player goes into the EAST wall -- goes round and opens the NORTH wall where
##    it was asked, at a soldier's height.
## C. In: the way in is close by now, and the soldier walks in through it.

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
var so: Soldier
var mech: MechBrain
var mech_nav: AINav
var book: TacticsBook
var wall := Vector3.INF


func _init() -> void:
	print("heavy way probe")
	a = Arena.new(self, 47)
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


func _sense() -> Dictionary:
	a.s.knowledge_of(1).saw(p, p.feet(), a.s.now())
	return TacticsSense.read(so, so.contact(), {})


func _p(rows: Array, move: String) -> float:
	for r in rows:
		if r.move == move:
			return float(r.p)
	return 0.0


func _mech(feet: Vector3, yaw: float) -> MechBrain:
	var m := Mech.spawn(root, feet, yaw, 1)
	var g := GunInstance.from_result(GunGenerator.generate(a.lib, 6, WeaponClass.builtin(&"lmg"), 1))
	g.visible = false
	m.arm.add_child(g)
	m.gun.equip(g)
	m.gun.rng = a.s.rng
	m.gun.on_structure_hit = a.structure_hit
	var br := MechBrain.attach(a.s, m, mech_nav, MechTree.enemy(), 1)
	br.arm_launcher(GunInstance.from_result(GunGenerator.generate(a.lib, 9,
			WeaponClass.builtin(&"rocket_launcher"), 1)), a.s.rng, a.structure_hit)
	return br


func _check(el: float) -> bool:
	match _stage:
		"build":
			if el < 0.5:
				return false
			print("A. the odds")
			var s0 := _sense()
			var o0 := book.odds(s0.moment, s0.facts, s0.amounts)
			_ok("no heavy of ours near: the move is not possible", s0.moment == "player_inside"
					and not (s0.facts as Array).has("heavy_near") and _p(o0, "heavy_way") == 0.0,
					"%s %s heavy_way %.2f" % [s0.moment, s0.facts, _p(o0, "heavy_way")])
			mech_nav = MechBrain.mech_nav(a.s.ai_world)
			# East of the house, level with the player: its own line goes into the
			# east wall. Facing west.
			mech = _mech(_w(80, 20), PI / 2.0)
			_stage = "mech"
			_t0 = a.s.now()
			return false
		"mech":
			if el < 0.5:
				return false
			TacticsSense._ways.clear()
			var s1 := _sense()
			var o1 := book.odds(s1.moment, s1.facts, s1.amounts)
			_ok("our mech near: the move is possible", (s1.facts as Array).has("heavy_near")
					and _p(o1, "heavy_way") > 0.05, "%s heavy_way %.2f breach %.2f guard %.2f" % [s1.facts,
					_p(o1, "heavy_way"), _p(o1, "breach"), _p(o1, "guard_exits")])
			var w := TacticsSense.ways_in(so, p.feet())
			wall = w.wall
			_ok("the casebook move is one the soldiers carry out", BookCombatPolicy.DOABLE.has("heavy_way"), "")
			_ok("the way it would ask for is in the north wall, the long way round on foot",
					wall != Vector3.INF and absf(wall.z - 34 * STUD) < 1.0 and bool(w.far),
					"wall %v, walk %.0f m, straight %.0f m" % [wall, w.walk, w.straight])
			print("B. the doorway")
			TacticsSense.ask_way(mech.mech, wall, a.s.now())
			_log["east0"] = _east_open()
			# Out of the mech's way while it works.
			so.pawn.place(_w(-20, 50))
			_stage = "blast"
			_t0 = a.s.now()
			return false
		"blast":
			a.s.knowledge_of(1).saw(p, p.feet(), a.s.now())
			if TacticsSense.way_asked(mech.mech, a.s.now()) != Vector3.INF:
				TacticsSense.ask_way(mech.mech, wall, a.s.now())
			var open := TacticsSense.way_open(a.s, wall + Vector3(0, 0, 3), wall)
			if not open and el < 45.0:
				if mech.state == "to the way":
					_log["went_round"] = true
				return false
			_ok("the mech goes round to the side it was asked for", _log.has("went_round"), mech.state)
			_ok("and opens the north wall there, at a soldier's height", open and mech.launched >= 1,
					"after %.1f s, %d launcher round(s), %d brick(s) blown; state %s" % [el, mech.launched,
					a.breached_blocks, mech.state])
			_ok("not the east wall, its own line", not _east_open() or bool(_log.east0), "")
			print("C. in")
			so.pawn.place(_w(17, 40))
			TacticsSense._ways.clear()
			var w := TacticsSense.ways_in(so, p.feet())
			_ok("the way in is close by now", not bool(w.far) and not bool(w.no_way),
					"walk %.0f m, straight %.0f m" % [w.walk, w.straight])
			# Stop the mech so it does not take the rest of the house.
			mech.process_mode = Node.PROCESS_MODE_DISABLED
			mech.mech.process_mode = Node.PROCESS_MODE_DISABLED
			so.breach_way = false
			_stage = "walk"
			_t0 = a.s.now()
			return false
		"walk":
			so.move_to(p.feet(), true)
			var gap := so.pawn.feet().distance_to(p.feet())
			if gap > 2.5 and el < 25.0:
				return false
			_ok("the soldier walks in through it to the player, no charge of its own",
					gap <= 2.5 and BTShelter.covered(a.s, so.pawn.feet()) and so.charges == 0,
					"%.1f m from the player after %.1f s" % [gap, el])
			return true
	return true


## Is the east wall open on the line from the mech's first spot to the player?
func _east_open() -> bool:
	var at := Vector3(34 * STUD, 1.0, p.feet().z)
	return a.s.ai_world.line_clear(at + Vector3(1.2, 0, 0), at - Vector3(1.2, 0, 0))


func _on_tick() -> void:
	_tick += 1
	if _tick == 2:
		_stage = "build"
		_t0 = 0.0
		# The house: x 0..34, z 0..34 studs, 8 courses, a 4-stud door at x 15..19
		# in the south wall (z = 0), and a roof.
		a.room(0, 0, 34, 34, 8, 15, 4, 1)
		a.bricks(Vector3i(0, 24, 0), Vector3i(34, 1, 34))
		p = a.player(_w(17, 20), 1e7, false, 0)
		so = a.soldier(_w(17, 40), 1, 12)
		so.process_mode = Node.PROCESS_MODE_DISABLED
		_t0 = a.s.now()
		return
	if _tick < 2:
		return
	a.tick()
	if mech_nav != null:
		mech_nav.service(800)
	if not _check(a.s.now() - _t0):
		return
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
