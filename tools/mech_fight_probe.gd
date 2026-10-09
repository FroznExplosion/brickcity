extends SceneTree

## Probe for mechs that know their layers and whom to watch (Docs/AIRoster.md
## 4.3, 5, 6; RO7).
##
##     godot --headless --path . --script tools/mech_fight_probe.gd
##
## A. The loop (5): the player's mech stands and fights on its own; the pilot is
##    out of it. The enemy mech shoots the MECH; the side's attention is on the
##    mech; a pilot nobody sees gains none of it; and with the pilot twelve
##    metres behind the enemy mech, the enemy mech is still on the player's mech.
## B. Aiming: at a mech with its hatch off, from the hatch's side, the aim is the
##    pilot behind it; from the other side, the hull.
## C. Guarding: a mech with its hatch off in front, told by the casebook to guard,
##    turns its open side away from what it faces and gives ground.
## D. The finisher: a doomed mech near it is walked up to and punched dead.
## E. Soldiers: facing a mech with its hatch off they know it, aim for the pilot,
##    and their rifles reach him -- and nothing else of the mech.

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
var other: Mech
var so: Soldier


func _init() -> void:
	print("mech fight probe")
	a = Arena.new(self, 77)
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


func _mech(feet: Vector3, yaw: float, team: int, tree: BehaviorTree) -> MechBrain:
	return MechBrain.attach(a.s, _bare(feet, yaw, team), mech_nav, tree, team)


## Out of the fight: its brain off, and nobody's target any more.
func _retire(x: Variant) -> void:
	if x is MechBrain:
		var br := x as MechBrain
		br.enabled = false
		br.mech.gun.set_trigger(false)
		_forget(br.mech.pawn)
	elif x is Mech:
		_forget((x as Mech).pawn)
	elif x is Soldier:
		(x as Soldier).process_mode = Node.PROCESS_MODE_DISABLED
		(x as Soldier).pawn.body.process_mode = Node.PROCESS_MODE_DISABLED
		a.s.pawns.erase((x as Soldier).pawn)
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


func _begin(stage: String) -> void:
	_stage = stage
	_t0 = a.s.now()
	_log.clear()
	match stage:
		"loop":
			pm = _mech(Vector3(0.0, 0.0, 0.0), 0.0, 0, MechTree.companion())
			pm.order = MechBrain.Order.HOLD
			pm.order_point = pm.mech.feet()
			em = _mech(Vector3(0.0, 0.0, -50.0), PI, 1, MechTree.enemy())
			# The pilot, out of it: behind a wall six metres high, off to the side.
			a.bricks(Vector3i(int(28.0 / Arena.STUD), 0, int(-12.0 / Arena.STUD)), Vector3i(1, 16, int(24.0 / Arena.STUD)))
			pilot = a.player(Vector3(32.0, 0.0, 0.0), 1e7, false, 0)
		"guard":
			_retire(pm)
			_retire(em)
			_retire(pilot)
			var sure := TacticsBook.load_book()
			sure.moments["mech_fight"].weights = {"m_guard": 100.0, "m_fire": 1.0}
			a.s.policy = BookCombatPolicy.new(sure)
			em = _mech(Vector3(200.0, 0.0, 0.0), 0.0, 1, MechTree.enemy())
			em.mech.layers.blow_hatch()
			other = _bare(Vector3(200.0, 0.0, -40.0), PI, 0)
			a.s.add_pawn(other.make_target())
			_log["d0"] = em.mech.feet().distance_to(other.feet())
		"finisher":
			_retire(em)
			_retire(other)
			a.s.policy = BookCombatPolicy.new()
			em = _mech(Vector3(-200.0, 0.0, 0.0), 0.0, 1, MechTree.enemy())
			# A Nuker, doomed, eight metres off: shot dead it goes off; punched it does not.
			other = _bare(Vector3(-200.0, 0.0, -8.0), PI, 0)
			other.set_type("heavy_gunner_nuker", Roster.shared())
			a.s.add_pawn(other.make_target())
			other.layers.exploded.connect(func(kind: String, _at: Vector3) -> void: _log["blast"] = kind)
			for type in [MechLayers.SHIELD, MechLayers.ARMOR, MechLayers.HEALTH]:
				_strip(other.layers, type)
			_log["doomed"] = other.layers.doomed and not other.layers.dead and other.layers.fuse_kind == "nuke"
		"soldier":
			_retire(em)
			_retire(other)
			other = _bare(Vector3(400.0, 0.0, -20.0), PI, 0)
			a.s.add_pawn(other.make_target())
			other.layers.blow_hatch()
			so = a.soldier(Vector3(400.0, 0.0, 0.0), 1, 91)
			Arena.look(so.pawn, other.pawn.chest())
			_log["hull0"] = other.layers.value(MechLayers.ARMOR) + other.layers.value(MechLayers.HEALTH)
			_log["pilot0"] = other.layers.pilot_hp


func _aggro(p: Pawn) -> float:
	return a.s.aggro_of(1).value(p)


func _check(t: float) -> bool:
	match _stage:
		"loop":
			if t >= 3.0 and not _log.has("pilot_a"):
				_log["pilot_a"] = _aggro(pilot)
			if t >= 9.0 and not _log.has("target_9"):
				_log["target_9"] = em._target == pm.mech.pawn
				_log["focus_9"] = a.s.aggro_of(1).focus() == pm.mech.pawn
				_log["mech_9"] = _aggro(pm.mech.pawn)
				_log["pilot_9"] = _aggro(pilot)
				_log["em_shots"] = em.shots
				_log["pm_shots"] = pm.shots
				# The pilot goes round: twelve metres behind the enemy mech.
				pilot.place(em.mech.feet() + Vector3(0.0, 0.0, -12.0))
			if t < 16.0:
				return false
			_ok("the player's mech fights on by itself, and the enemy mech shoots the mech",
					int(_log.pm_shots) > 0 and int(_log.em_shots) > 0 and bool(_log.target_9),
					"%d and %d shot(s) in 9 s" % [int(_log.pm_shots), int(_log.em_shots)])
			_ok("the side's attention is on the mech; a pilot nobody sees gains none",
					bool(_log.focus_9) and float(_log.mech_9) > 20.0 and float(_log.pilot_9) <= float(_log.pilot_a) + 0.01,
					"mech %.0f, pilot %.1f (was %.1f at 3 s)" % [float(_log.mech_9), float(_log.pilot_9), float(_log.pilot_a)])
			_ok("with the pilot twelve metres behind it, the enemy mech is still on the player's mech",
					em._target == pm.mech.pawn and a.s.aggro_of(1).focus() == pm.mech.pawn
					and pilot.feet().distance_to(em.mech.feet()) < 14.0,
					"pilot %.0f m behind it; pilot's aggro %.1f, the mech's %.0f" % [pilot.feet().distance_to(em.mech.feet()),
					_aggro(pilot), _aggro(pm.mech.pawn)])
			# B, on a mech nobody has touched, facing -z.
			var fresh := _bare(Vector3(-400.0, 0.0, 0.0), 0.0, 0)
			fresh.make_target()
			var l := fresh.layers
			var front := fresh.feet() + Vector3(0.0, 2.0, -30.0)
			var back := fresh.feet() + Vector3(0.0, 2.0, 30.0)
			var whole := MechLayers.aim_point(fresh.pawn, front)
			l.blow_hatch()
			var open_front := MechLayers.aim_point(fresh.pawn, front)
			var open_back := MechLayers.aim_point(fresh.pawn, back)
			_ok("aiming: hatch off and seen from its side, the pilot behind it; from the other side, the hull",
					whole.distance_to(l.hatch_point()) > 0.5 and open_front.distance_to(l.hatch_point()) < 0.01
					and open_back.distance_to(l.hatch_point()) > 0.5 and l.zone_at(open_front) == &"hatch")
			return true
		"guard":
			if t < 7.0:
				return false
			var l := em.mech.layers
			var faced := l.side_faces(l.hatch_point(), other.feet())
			var d := em.mech.feet().distance_to(other.feet())
			_ok("guarding: its hatch off in front, it turns the open side away from what it faces, and gives ground",
					em.stance == MechBrain.Stance.GUARD and not faced and d > float(_log.d0) + 3.0
					and str(em.book.get("move", "")) == "m_guard" and (em.book.facts as Array).has("our_hatch_off"),
					"stance %s; hatch faces the enemy: %s; %.0f m -> %.0f m" % [em.state, faced, float(_log.d0), d])
			return true
		"finisher":
			if t < 20.0 and not other.layers.dead:
				return false
			_ok("the finisher: a doomed Nuker is not shot -- it is walked up to and punched dead before it goes off",
					bool(_log.doomed) and other.layers.dead and other.layers.cause == "finisher" and em.mech.melee_hits >= 1
					and not _log.has("blast"),
					"%s after %.1f s; %d punch(es); blast %s" % [other.layers.cause, t, em.mech.melee_hits, _log.get("blast", "none")])
			return true
		"soldier":
			if t < 1.0:
				return false
			if not _log.has("sense"):
				var k := so.knowledge()
				k.saw(other.pawn, other.pawn.feet(), a.s.now(), so)
				_log["sense"] = TacticsSense.read(so, k.of(other.pawn), {})
			if t < 10.0 and other.layers.piloted:
				return false
			var sense: Dictionary = _log.sense
			var hull := other.layers.value(MechLayers.ARMOR) + other.layers.value(MechLayers.HEALTH)
			_ok("soldiers know a mech with its hatch off, aim for the pilot, and their rifles reach him -- and nothing else of it",
					sense.facts.has("p_mech") and sense.facts.has("p_hatch_off") and other.layers.pilot_hp < float(_log.pilot0)
					and is_equal_approx(hull, float(_log.hull0)) and so.shots > 0,
					"facts %s; pilot %.0f -> %.0f; hull untouched; %d shot(s)" % [sense.facts, float(_log.pilot0),
					other.layers.pilot_hp, so.shots])
			return true
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
	var order := ["loop", "guard", "finisher", "soldier"]
	var i := order.find(_stage)
	if i + 1 < order.size():
		_begin(order[i + 1])
		return
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
