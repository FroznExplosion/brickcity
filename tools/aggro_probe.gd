extends SceneTree

## Acceptance probe for aggro (Docs/AIPlan.md P6, AI.md 8, A8), in an arena.
##
##     godot --headless --path . --script tools/aggro_probe.gd
##
## The table on its own: the focus moves only when another row leads it by the
## margin, and aggro fades by half each HALF_LIFE. Then in a fight: two players
## -- the first with a stand-in for its mech beside it -- and two soldiers.
##   1. Player 1 shoots: its meter climbs, it takes the focus, the soldiers aim
##      at it.
##   2. Player 2 joins, shooting as hard: the focus HOLDS on player 1.
##   3. Player 1 stops: its aggro fades, player 2's grows past the margin, the
##      focus moves, and the soldiers turn on player 2.
##   4. Player 1's mech opens up: the mech's share shows beside the pilot's.

const Arena := preload("res://tools/ai_arena.gd")

var _pass := 0
var _fail := 0
var a: Arena
var p1: Pawn
var mech: Pawn
var p2: Pawn
var enemies: Array[Soldier] = []
var meter: AggroMeter
var table: AggroTable
var _tick := 0
var _t0 := -1.0
var _log := {}


func _init() -> void:
	print("aggro probe")
	_table_alone()
	a = Arena.new(self, 11)
	physics_frame.connect(_on_tick)


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _table_alone() -> void:
	var t := AggroTable.new()
	var x := RefCounted.new()
	var y := RefCounted.new()
	t.add(x, 100.0)
	var first := t.focus() == x
	t.add(y, 110.0)
	var held_110 := t.focus() == x
	t.add(y, 14.0)   # 124: under 1.25 x 100
	var held_124 := t.focus() == x
	t.add(y, 2.0)    # 126: over both margins
	var moved := t.focus() == y
	_ok("the table: the focus holds until another leads by the margin, then moves",
			first and held_110 and held_124 and moved and t.switches == 2,
			"110 %s, 124 %s, 126 %s" % ["held" if held_110 else "MOVED", "held" if held_124 else "MOVED",
			"moved" if moved else "HELD"])
	var v0 := t.value(x)
	t.decay(AggroTable.HALF_LIFE)
	_ok("aggro halves every %.0f s of nothing" % AggroTable.HALF_LIFE,
			absf(t.value(x) - v0 * 0.5) < 0.01, "%.1f -> %.1f" % [v0, t.value(x)])


func _build() -> void:
	p1 = a.player(Vector3(-4.0, 0.0, 0.0), 1e7, true, 0)
	# The mech, until P7 gives it a body: a pawn in player 1's name, counted as
	# its mech.
	mech = a.player(Vector3(0.0, 0.0, 1.0), 1e7, true, 0)
	mech.set_meta(&"aggro_kind", "mech")
	p2 = a.player(Vector3(4.0, 0.0, 0.0), 1e7, true, 1)
	for i in 2:
		var so := a.soldier(Vector3(-2.0 + 4.0 * i, 0.0, -18.0), 1, 60 + i, 1e7)
		so.pawn.intents.look_yaw = PI
		enemies.append(so)
	table = a.s.aggro_of(1)
	for p in [p1, mech, p2]:
		a.s.arm(p)
	meter = AggroMeter.new()
	meter.table = table
	meter.player = 0
	root.add_child(meter)


func _shoot(p: Pawn, on: bool) -> void:
	if on:
		Arena.look(p, enemies[0].pawn.chest())
	p.intents.fire = on


func _on_tick() -> void:
	_tick += 1
	if _tick == 1:
		_build()
		return
	a.tick()
	var now := a.s.now()
	if _t0 < 0.0:
		_t0 = now
	var t := now - _t0
	_shoot(p1, t >= 1.0 and t < 7.0)
	_shoot(p2, t >= 4.0 and t < 20.0)
	_shoot(mech, t >= 16.0 and t < 20.0)
	if t >= 1.0 and not _log.has("r1"):
		_log["r1"] = meter.reading()
	if t >= 4.0 and not _log.has("r4"):
		_log["r4"] = meter.reading()
		_log["f4"] = table.focus()
		_log["aim4"] = _aimed_at()
		_log["sw4"] = table.switches
	if t >= 7.0 and not _log.has("f7"):
		_log["f7"] = table.focus()
		_log["sw7"] = table.switches
		_log["v7"] = [table.value(p1), table.value(p2)]
	if t >= 15.0 and not _log.has("f15"):
		_log["f15"] = table.focus()
		_log["aim15"] = _aimed_at()
		_log["v15"] = [table.value(p1), table.value(p2)]
	if t >= 20.0:
		_log["r20"] = meter.reading()
		_finish()


## Who the soldiers are aiming at, by count.
func _aimed_at() -> Dictionary:
	var out := {"p1": 0, "p2": 0, "mech": 0, "none": 0}
	for so in enemies:
		var tgt = so._aim_target
		out[("p1" if tgt == p1 else "p2" if tgt == p2 else "mech" if tgt == mech else "none")] += 1
	return out


func _finish() -> void:
	physics_frame.disconnect(_on_tick)
	var r1: Dictionary = _log.r1
	var r4: Dictionary = _log.r4
	_ok("player 1 shoots: its meter climbs and it takes the focus",
			float(r4.pilot) > float(r1.pilot) + 0.3 and _log.f4 == p1 and r4.holder == "pilot",
			"pilot share %.2f -> %.2f, holder %s" % [float(r1.pilot), float(r4.pilot), r4.holder])
	_ok("the soldiers aim at whoever holds the focus", int((_log.aim4 as Dictionary).p1) == 2,
			"%s" % [_log.aim4])
	_ok("player 2 shoots as hard: the focus holds on player 1 (hysteresis)",
			_log.f7 == p1 and int(_log.sw7) == int(_log.sw4),
			"aggro p1 %.0f, p2 %.0f" % [float(_log.v7[0]), float(_log.v7[1])])
	_ok("player 1 stops: its aggro fades, player 2 leads by the margin and takes the focus",
			_log.f15 == p2 and int((_log.aim15 as Dictionary).p2) == 2,
			"aggro p1 %.0f, p2 %.0f; aiming %s" % [float(_log.v15[0]), float(_log.v15[1]), _log.aim15])
	var r20: Dictionary = _log.r20
	_ok("the mech's share shows beside its pilot's", float(r20.mech) > 0.1,
			"pilot %.2f, mech %.2f" % [float(r20.pilot), float(r20.mech)])
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
