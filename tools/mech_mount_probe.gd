extends SceneTree

## Probe for getting into and out of a mech (Docs/AIRoster.md 4.4, 4.7; RO8).
##
##     godot --headless --path . --script tools/mech_mount_probe.gd
##
## A. Boarding: an AI pilot walks to a parked mech of its side -- to the front of
##    a medium, to the back of a light -- gets in from its hatch's side, and the
##    mech's brain wakes; inside, the pilot is nobody's target.
## B. The spot must be clear: with bricks where it would stand, it does not try.
## C. A wrong pilot (R14): an AI never sets out for another side's mech; a pilot
##    of another side who tries sets off its self-destruct -- soldiers of its side
##    get clear of the blast, and the would-be thief, standing there, is killed.
## D. Bailing out: told by the casebook to bail, the pilot is on the ground at the
##    hatch, a target again, and the mech fights on, on auto.
## E. Nuke eject: a Nuker's pilot is thrown clear of the nuke and lives.
## F. Shot through the hatch, the pilot (a soldier) dies; the mech goes to auto.
## G. A mech destroyed with its pilot inside takes the pilot with it.

const Arena := preload("res://tools/ai_arena.gd")

var _pass := 0
var _fail := 0
var a: Arena
var mech_nav: AINav
var _tick := 0
var _stage := ""
var _t0 := 0.0
var _log := {}
var m: MechBrain
var m2: MechBrain
var so: Soldier
var so2: Soldier
var thief: Pawn
var other: Mech


func _init() -> void:
	print("mech mount probe")
	a = Arena.new(self, 31)
	physics_frame.connect(_on_tick)


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _bare(feet: Vector3, yaw: float, team: int) -> Mech:
	var mm := Mech.spawn(root, feet, yaw, team)
	var g := GunInstance.from_result(GunGenerator.generate(a.lib, 5 + team + _tick, WeaponClass.builtin(&"lmg"), 1))
	g.visible = false
	mm.arm.add_child(g)
	mm.gun.equip(g)
	mm.gun.rng = a.s.rng
	mm.gun.on_structure_hit = a.structure_hit
	return mm


func _mech(feet: Vector3, yaw: float, team: int, type := "medium_gunner") -> MechBrain:
	var br := MechBrain.attach(a.s, _bare(feet, yaw, team), mech_nav, MechTree.enemy(), team)
	br.mech.set_type(type, Roster.shared())
	return br


## A mech with a soldier of its side inside it.
func _crewed(feet: Vector3, yaw: float, team: int, type := "medium_gunner") -> Array:
	var br := _mech(feet, yaw, team, type)
	var pilot := a.soldier(feet + Vector3(6.0, 0.0, 6.0), team, 40 + _tick)
	br.mech.mount(pilot.pawn, true)
	return [br, pilot]


## Out of the fight: its brain off, and nobody's target any more.
func _retire(x: Variant) -> void:
	if x is MechBrain:
		var br := x as MechBrain
		br.enabled = false
		br.mech.gun.set_trigger(false)
		_forget(br.mech.pawn)
		if br.mech.pilot_pawn != null:
			_forget(br.mech.pilot_pawn)
	elif x is Mech:
		_forget((x as Mech).pawn)
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


func _strip(l: MechLayers, type: StringName) -> void:
	for i in 8:
		if l.value(type) <= 0.0:
			return
		l.take(l.value(type), &"mech")


func _hidden(p: Pawn) -> bool:
	return not a.s.pawns.has(p) and not p.body.visible and p.body.collision_layer == 0


func _begin(stage: String) -> void:
	_stage = stage
	_t0 = a.s.now()
	_log.clear()
	match stage:
		"board":
			m = _mech(Vector3(0.0, 0.0, 0.0), 0.0, 1)
			m.mech.park()
			so = a.soldier(Vector3(9.0, 0.0, 12.0), 1, 11)
			m2 = _mech(Vector3(60.0, 0.0, 0.0), 0.0, 1, "light_gunner")
			m2.mech.park()
			so2 = a.soldier(Vector3(66.0, 0.0, -12.0), 1, 12)
			_log["asleep"] = not m.enabled and not m2.enabled and m.mech.is_empty()
			for pair in [[m, so, "front"], [m2, so2, "back"]]:
				var br: MechBrain = pair[0]
				var pilot: Soldier = pair[1]
				br.mech.mounted.connect(func(_p: Pawn) -> void:
					_log[pair[2]] = _log.get("walk_" + pair[2], Vector3.INF))
				_log["set_" + pair[2]] = pilot.go_board(br.mech)
		"blocked":
			_retire(m)
			_retire(m2)
			m = _mech(Vector3(120.0, 0.0, 0.0), 0.0, 1)
			m.mech.park()
			# A wall across the front of it, where a pilot would stand.
			var mp := m.mech.feet() + Vector3(0.0, 0.0, -Mech.MOUNT_OUT)
			a.bricks(Vector3i(int((mp.x - 2.0) / Arena.STUD), 0, int((mp.z - 0.6) / Arena.STUD)),
					Vector3i(int(4.0 / Arena.STUD), 8, 4))
			so = a.soldier(Vector3(128.0, 0.0, 10.0), 1, 13)
			_log["set"] = so.go_board(m.mech)
		"wrong":
			_retire(m)
			_retire(so)
			m = _mech(Vector3(-120.0, 0.0, 0.0), 0.0, 1)
			m.mech.park()
			so = a.soldier(Vector3(-120.0, 0.0, 0.0) + Vector3(5.0, 0.0, 0.0), 1, 14)
			# Not hostile to anyone here: the soldier is on the mech's side, the
			# thief a stranger nobody shoots at (team -1 is nobody's hostile).
			var stranger := a.soldier(Vector3(-140.0, 0.0, 0.0), 0, 15)
			_log["ai_refuses"] = not stranger.go_board(m.mech)
			_retire(stranger)
			thief = a.player(m.mech.mount_point(), 100.0, false, 0)
			_forget(thief)
			a.s.pawns.append(thief)
			thief.team = -1
			m.mech.layers.fuse_lit.connect(func(kind: String, secs: float) -> void:
				_log["fuse"] = [kind, secs])
			m.mech.layers.exploded.connect(func(_kind: String, at: Vector3) -> void:
				_log["gap"] = so.pawn.chest().distance_to(at))
			# The thief's own side is not the mech's: try_enter takes the side asked.
			_log["got_in"] = m.mech.mount(_as_team(thief, 0))
			thief.team = -1
		"bail":
			_retire(m)
			_retire(so)
			var sure := TacticsBook.load_book()
			sure.moments["mech_fight"].weights = {"m_bail": 100.0, "m_fire": 1.0}
			a.s.policy = BookCombatPolicy.new(sure)
			var c := _crewed(Vector3(200.0, 0.0, 0.0), 0.0, 1)
			m = c[0]
			so = c[1]
			_log["hidden"] = _hidden(so.pawn) and m.mech.pilot_pawn == so.pawn and m.enabled
			m.mech.layers.blow_hatch()
			other = _bare(Vector3(200.0, 0.0, -45.0), PI, 0)
			a.s.add_pawn(other.make_target())
			m.mech.dismounted.connect(func(p: Pawn, thrown: bool) -> void:
				_log["out"] = [p, thrown, m.shots, a.s.now(), p.feet().distance_to(m.mech.mount_point())])
		"eject":
			_retire(m)
			_retire(other)
			a.s.policy = BookCombatPolicy.new()
			var c := _crewed(Vector3(-200.0, 0.0, 200.0), 0.0, 1, "heavy_gunner_nuker")
			m = c[0]
			so = c[1]
			m.enabled = false
			m.mech.layers.exploded.connect(func(kind: String, _at: Vector3) -> void: _log["blast"] = kind)
			for type in [MechLayers.SHIELD, MechLayers.ARMOR, MechLayers.HEALTH]:
				_strip(m.mech.layers, type)
			_log["thrown"] = so.pawn.feet().distance_to(m.mech.feet())
			_log["visible"] = a.s.pawns.has(so.pawn) and so.pawn.body.visible
		"killed":
			_retire(m)
			_retire(so)
			var c := _crewed(Vector3(200.0, 0.0, 200.0), 0.0, 1)
			m = c[0]
			so = c[1]
			m.enabled = false
			m.mech.layers.blow_hatch()
			var hull := m.mech.health.total_current()
			for i in 6:
				m.mech.layers.take(40.0, &"person", &"hatch")
			_log["ok"] = so.is_dead() and not m.mech.layers.piloted and m.mech.layers.auto \
					and m.mech.pilot_pawn == null and is_equal_approx(hull, m.mech.health.total_current())
		"cell":
			_retire(m)
			var c := _crewed(Vector3(0.0, 0.0, 200.0), 0.0, 1)
			m = c[0]
			so = c[1]
			m.enabled = false
			var l := m.mech.layers
			for i in 10:
				if l.cell_door_off:
					break
				l.take(400.0, &"mech", &"cell")
			for i in 10:
				if l.dead:
					break
				l.take(400.0, &"mech", &"cell")
			_log["ok"] = l.dead and l.cause == "cell" and so.is_dead()


## `p` asking as a member of `team` (the thief is nobody's hostile in this probe,
## but asks to get in as the other side).
func _as_team(p: Pawn, team: int) -> Pawn:
	p.team = team
	return p


func _check(t: float) -> bool:
	match _stage:
		"board":
			# Where each pilot was standing the tick before it got in.
			if so.board_mech != null:
				_log["walk_front"] = so.pawn.feet()
			if so2.board_mech != null:
				_log["walk_back"] = so2.pawn.feet()
			var done: bool = _log.has("front") and _log.has("back")
			if t < 30.0 and not done:
				return false
			var ok_front := false
			var ok_back := false
			if _log.has("front"):
				var f: Vector3 = _log.front
				ok_front = f.z < m.mech.feet().z - 1.0
			if _log.has("back"):
				var b: Vector3 = _log.back
				ok_back = b.z > m2.mech.feet().z + 1.0
			_ok("a parked mech sleeps until its pilot is in",
					bool(_log.asleep) and bool(_log.set_front) and bool(_log.set_back))
			_ok("an AI pilot walks to the hatch side and gets in: in front of a medium, behind a light",
					ok_front and ok_back and m.mech.pilot_pawn == so.pawn and m2.mech.pilot_pawn == so2.pawn,
					"got in at %s and %s after %.1f s" % [_log.get("front", "-"), _log.get("back", "-"), t])
			_ok("inside, its brain wakes and the pilot is nobody's target",
					m.enabled and m2.enabled and m.mech.layers.piloted and not m.mech.layers.auto
					and _hidden(so.pawn) and _hidden(so2.pawn))
			return true
		"blocked":
			if t < 3.0 and so.board_mech != null:
				return false
			_ok("with bricks where its pilot would stand, nobody gets in",
					bool(_log.set) and so.board_failed == "blocked" and m.mech.is_empty() and not m.mech.mount_spot_clear(),
					"failed: '%s'" % so.board_failed)
			return true
		"wrong":
			if t < 3.0:
				return false
			var fuse: Array = _log.get("fuse", [])
			var gap := float(_log.get("gap", 0.0))
			_ok("an AI never sets out for another side's mech; a wrong pilot is kept out and lights its self-destruct",
					bool(_log.ai_refuses) and not bool(_log.got_in) and fuse.size() == 2 and fuse[0] == "self_destruct",
					"fuse %s" % [fuse])
			_ok("it goes off: its own side got clear, the would-be thief standing at it is killed",
					m.mech.layers.dead and m.mech.layers.cause == "self_destruct" and thief.health.is_dead()
					and not so.is_dead() and gap > float(MechLayers.SELF_DESTRUCT[1]),
					"its soldier %.1f m from the blast (reach %.0f)" % [gap, float(MechLayers.SELF_DESTRUCT[1])])
			return true
		"bail":
			if not _log.has("out"):
				if t < 12.0:
					return false
				_ok("told to bail, the pilot gets out", false, "still in after %.0f s; stance %s, state %s" % [t, m.stance, m.state])
				return true
			var out: Array = _log.out
			if a.s.now() - float(out[3]) < 4.0:
				return false
			var p: Pawn = out[0]
			_ok("the pilot is out: on the ground by the hatch, a target again",
					p == so.pawn and not bool(out[1]) and a.s.pawns.has(p) and p.body.visible and not so.is_dead()
					and float(out[4]) < 1.0 and so.board_mech == null,
					"put down %.1f m from the hatch spot" % float(out[4]))
			_ok("and the mech fights on, on auto",
					not m.mech.layers.piloted and m.mech.layers.auto and m.enabled and m.shots > int(out[2]),
					"%d shot(s) before, %d after" % [int(out[2]), m.shots])
			return true
		"eject":
			if t < 5.0 and not _log.has("blast"):
				return false
			_ok("a doomed Nuker throws its pilot clear of the nuke, and the pilot lives",
					float(_log.thrown) > float(MechLayers.NUKE[1]) and bool(_log.visible) and _log.get("blast", "") == "nuke"
					and not so.is_dead(),
					"thrown %.0f m (reach %.0f); blast %s" % [float(_log.thrown), float(MechLayers.NUKE[1]), _log.get("blast", "none")])
			return true
		"killed":
			_ok("shot through the open hatch the pilot dies, and the mech goes to auto, its hull untouched", bool(_log.ok))
			return true
		"cell":
			_ok("its power cell destroyed, the mech goes -- and the pilot inside with it", bool(_log.ok))
			return true
	return true


func _on_tick() -> void:
	_tick += 1
	if _tick == 2:
		mech_nav = MechBrain.mech_nav(a.s.ai_world)
		_begin("board")
		return
	if _tick < 2:
		return
	a.tick()
	mech_nav.service(800)
	if not _check(a.s.now() - _t0):
		return
	var order := ["board", "blocked", "wrong", "bail", "eject", "killed", "cell"]
	var i := order.find(_stage)
	if i + 1 < order.size():
		_begin(order[i + 1])
		return
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
