extends SceneTree

## Probe for RO11's second part (Docs/AIRoster.md 8; R11-R13): the commander
## learns from the casebook's tally, and the FRIENDLY commander follows the
## players without orders.
##
##     godot --headless --path . --script tools/ally_probe.gd
##
## A. Learning: a tally where flanking paid and rushing got soldiers killed lifts
##    the flankers and lowers the attackers; a move judged too few times teaches
##    nothing; the clamp holds.
## B. What the players are doing (PlayerIntent): the enemy a player shoots at is
##    the focus; with no shooting, where its mech was sent; with neither, where
##    the player is heading.
## C. Lanes: straight down a player's look is in front of its gun, off to the side
##    is not; a support point is beside the player, never in a lane, and two
##    squads take the two sides.
## D. In an arena: a friendly squad behind the player, an enemy ahead that the
##    player shoots at. The friendly commander sends the squad to the fight's
##    flank, out to the side first; it never sends it to a place in front of the
##    player's gun, and the squad spends little time in one on the way (a path
##    between two safe places can still cross a lane: the walking map does not
##    know them).

const Arena := preload("res://tools/ai_arena.gd")

var _pass := 0
var _fail := 0
var a: Arena
var _tick := 0
var _t0 := 0.0
var player: Pawn
var enemy: Soldier
var cm: Commander
var q: Squad
var _lane_ticks := 0
var _ticks := 0
var _ordered := ""
var _sent_in_lane := 0


func _init() -> void:
	print("ally probe")
	_learning()
	a = Arena.new(self, 61)
	physics_frame.connect(_on_tick)


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


# --- A. learning ------------------------------------------------------------------

func _learning() -> void:
	var tally := {"moments": {
		"first_contact": {"outcomes": {
			"flank": {"n": 12, "reward": 12 * 25.0}, "rush": {"n": 9, "reward": 9 * -60.0}}},
		"losing": {"outcomes": {
			"rush": {"n": 6, "reward": 6 * -50.0}, "melee": {"n": 4, "reward": 4 * 40.0}}},
	}}
	var plain := Doctrine.new()
	plain.update(ThreatProfile.new(), 0.0, 0.6)
	var d := Doctrine.new()
	d.learn(tally)
	d.update(ThreatProfile.new(), 0.0, 0.6)
	_ok("from the tally: flanking paid, so flankers up; rushing got men killed, so attackers down",
			float(d.roster[&"boarder"]) > float(plain.roster[&"boarder"])
			and float(d.roster[&"assault"]) < float(plain.roster[&"assault"]),
			"boarder %.2f (%.2f), assault %.2f (%.2f); from %s" % [d.roster[&"boarder"], plain.roster[&"boarder"],
			d.roster[&"assault"], plain.roster[&"assault"], d.learned_from])
	_ok("a move judged too few times teaches nothing",
			not d.learned_from.has("melee") and not d.learned.has("attack:melee"))
	var within := true
	for id in d.roster:
		var k := float(d.roster[id]) / Doctrine.base_of(id)
		if k < 0.5 - 1e-4 or k > 2.0 + 1e-4:
			within = false
	_ok("and it stays inside the clamp, and inside LEARN_RANGE per move",
			within and float(d.learned["role:attacker"]) >= Doctrine.LEARN_RANGE[0] - 1e-4
			and float(d.learned["role:flanker"]) <= Doctrine.LEARN_RANGE[1] + 1e-4)


# --- B, C. the players' intent ------------------------------------------------------

func _intent() -> void:
	var it := PlayerIntent.new(a.s)
	var p := a.player(Vector3(0.0, 0.0, 0.0), 1e7, false, 0)
	Arena.look(p, Vector3(0.0, 1.5, -40.0))
	p.eye.rotation = Vector3(p.intents.look_pitch, p.intents.look_yaw, 0.0)
	it.players = func() -> Array: return [p]
	var mech := MechBrain.new()
	it.mechs = func() -> Array: return [mech]
	it.observe()
	var f: Array = it.focus()
	_ok("standing still, no shots, no mech order: the focus is where the player is",
			(f[0] as Vector3).distance_to(p.feet()) < 0.5, str(f[1]))
	mech.order = MechBrain.Order.ATTACK_AREA
	mech.order_point = Vector3(30.0, 0.0, -30.0)
	f = it.focus()
	_ok("its mech sent to attack: the focus is there", (f[0] as Vector3).distance_to(mech.order_point) < 0.5,
			str(f[1]))
	var foe := a.soldier(Vector3(5.0, 0.0, -35.0), 1, 70)
	foe.process_mode = Node.PROCESS_MODE_DISABLED
	it._on_player_fired({"collider": foe.pawn.body, "point": foe.pawn.chest(), "structure": false}, p)
	f = it.focus()
	_ok("it shoots at an enemy: the focus is that enemy, over the mech's order",
			(f[0] as Vector3).distance_to(foe.pawn.feet()) < 0.5, str(f[1]))
	it.last_target = {}
	mech.order = MechBrain.Order.FOLLOW
	# Walking: two looks a second apart, 4 m on.
	var tr := {"pos": p.feet(), "at": a.s.now() - 1.0, "vel": Vector3(4.0, 0.0, 0.0)}
	it._track[p.get_instance_id()] = tr
	it.observe()
	f = it.focus()
	_ok("walking: the focus is ahead, where the player is going",
			(f[0] as Vector3).x > p.feet().x + 3.0, "%s at %v" % [f[1], f[0]])
	# Lanes.
	_ok("straight down its look is in front of its gun; off to the side is not",
			it.in_lane(Vector3(0.0, 0.0, -20.0)) and not it.in_lane(Vector3(10.0, 0.0, -20.0))
			and not it.in_lane(Vector3(0.0, 0.0, 10.0)))
	var at := Vector3(0.0, 0.0, -40.0)
	var s0 := it.support_point(at, 0)
	var s1 := it.support_point(at, 1)
	_ok("support points: beside the player, out of every lane, one squad each side",
			s0 != Vector3.INF and s1 != Vector3.INF and not it.in_lane(s0) and not it.in_lane(s1)
			and signf(s0.x) != signf(s1.x) and s0.distance_to(p.feet()) < 20.0,
			"%v, %v" % [s0, s1])
	a.s.pawns.erase(foe.pawn)
	a.s.pawns.erase(p)
	foe.pawn.body.free()
	p.body.free()


# --- D. in an arena ---------------------------------------------------------------

func _begin() -> void:
	player = a.player(Vector3(100.0, 0.0, 0.0), 1e7, true, 0)
	enemy = a.soldier(Vector3(100.0, 0.0, -38.0), 1, 71, 1e6)
	# It holds where it is: a lane that sweeps after an enemy walking round
	# the player crosses anybody (a limit noted in AIRoster.md RO11).
	enemy.process_mode = Node.PROCESS_MODE_DISABLED
	Arena.look(player, enemy.pawn.chest())
	var members: Array[Soldier] = []
	for i in 3:
		members.append(a.soldier(Vector3(98.0 + 2.0 * i, 0.0, 12.0), 0, 80 + i, 1e6))
	cm = Commander.new()
	root.add_child(cm)
	cm.setup(a.s, 0)
	cm.intent = PlayerIntent.new(a.s)
	cm.intent.players = func() -> Array: return [player]
	q = Squad.make(a.s, root, members, 0)
	cm.adopt(q)
	cm.decided.connect(func(w: String) -> void:
		if w.contains("support"):
			print("  (order) %s" % w)
			_ordered = w)
	# The player is shooting at it.
	cm.intent._on_player_fired({"collider": enemy.pawn.body, "point": enemy.pawn.chest(), "structure": false}, player)
	a.s.knowledge_of(0).saw(enemy.pawn, enemy.pawn.feet(), a.s.now())
	_t0 = a.s.now()


func _on_tick() -> void:
	_tick += 1
	if _tick == 2:
		_intent()
		return
	if _tick == 3:
		_begin()
		return
	if _tick < 3:
		return
	a.tick()
	# Keep looking at it, and keep shooting at it.
	Arena.look(player, enemy.pawn.chest())
	cm.intent.last_target["at"] = a.s.now()
	a.s.knowledge_of(0).saw(enemy.pawn, enemy.pawn.feet(), a.s.now())
	var sent: Dictionary = cm.support_to.get(q.id, {}) if cm != null else {}
	if not sent.is_empty() and cm.intent.in_lane(sent.at):
		_sent_in_lane += 1
	if _ordered != "":
		for so in q.alive():
			_ticks += 1
			if cm.intent.in_lane(so.pawn.feet()):
				_lane_ticks += 1
	if a.s.now() - _t0 < 40.0:
		return
	var to: Vector3 = (cm.support_to.get(q.id, {}) as Dictionary).get("at", Vector3.INF)
	var c := q.center()
	_ok("the friendly commander sends its squad to the flank of what the player shoots at",
			_ordered.contains("ADVANCE the flank of") and to != Vector3.INF
			and absf(to.x - enemy.pawn.feet().x) > 5.0, "%s; to %v" % [_ordered, to])
	_ok("and it gets there", to != Vector3.INF and Vector2(c.x - to.x, c.z - to.z).length() < 8.0,
			"squad centre %.1f m from it" % Vector2(c.x - to.x, c.z - to.z).length())
	_ok("it is never sent to a place in front of the player's gun", _sent_in_lane == 0,
			"%d tick(s) with its order's point in a lane" % _sent_in_lane)
	_ok("and spends little time in one on the way: under 10 % of member-ticks",
			_ticks > 100 and float(_lane_ticks) / _ticks < 0.10,
			"%d of %d member-ticks (%.1f %%)" % [_lane_ticks, _ticks, 100.0 * _lane_ticks / maxf(_ticks, 1)])
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
