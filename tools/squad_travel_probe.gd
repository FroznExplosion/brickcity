extends SceneTree

## A squad travelling in file against the same four going on their own
## (Docs/AI.md 4.3, "squads path once"; BTPlayTravel):
##
##     godot --headless --path . --script res://tools/squad_travel_probe.gd
##
## Walls across the way make the route bend. First the squad is ordered MOVE to
## the far end: the leader paths, the rest follow its trail. Then the same four,
## put back, each walk to the same end alone. What the paths cost is AINav's
## expansion count for each run; the file must hold together on the way and
## everyone must get there.

const Arena := preload("res://tools/ai_arena.gd")
const START := Vector3(0.0, 0.0, 0.0)
const GOAL := Vector3(0.0, 0.0, -48.0)
const LIMIT := 30 * 90

var _pass := 0
var _fail := 0
var a: Arena
var q: Squad
var members: Array[Soldier] = []
var _tick := 0
var _stage := "build"
var _t := 0.0
var _exp0 := 0
var _paths0 := 0
var _log := {}
var _spread_max := 0.0
var _spread_sum := 0.0
var _spread_n := 0


func _init() -> void:
	print("squad travel probe")
	a = Arena.new(self, 7)
	physics_frame.connect(_on_tick)


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _build() -> void:
	# Walls across the way, standing height, gaps at alternating ends: the
	# route is a zigzag, not a straight line.
	for k in 4:
		var z := int((-10.0 - k * 9.0) / Arena.STUD)
		var x := -30 if k % 2 == 0 else -10
		a.bricks(Vector3i(x, 0, z), Vector3i(40, 5, 1))
	for i in 4:
		var so := a.soldier(a.s.ai_nav.snap(START + Vector3(-1.5 + i, 0.0, 0.0)), 1, 10 + i)
		so.pawn.intents.look_yaw = 0.0
		members.append(so)
	q = Squad.make(a.s, root, members, 1)


func _stats() -> Dictionary:
	return a.s.ai_nav.get_stats()


func _on_tick() -> void:
	_tick += 1
	if _tick == 1:
		_build()
	a.tick()
	var now := a.s.now()
	match _stage:
		"build":
			if _tick >= 10:
				var st := _stats()
				_exp0 = int(st.expansions)
				_paths0 = int(st.paths)
				var o := SquadMsg.Order.make(SquadMsg.OrderKind.MOVE)
				o.point = GOAL
				_log["order"] = q.give(o)
				_stage = "squad"
				_t = now
		"squad":
			_measure_spread()
			for r in q.reports:
				if r.order_id == int(_log.order) and r.kind != SquadMsg.ReportKind.ACCEPTED:
					_log["report"] = r
			if _log.has("report") or now - _t > 70.0:
				var st := _stats()
				_log["squad_exp"] = int(st.expansions) - _exp0
				_log["squad_paths"] = int(st.paths) - _paths0
				_log["squad_time"] = now - _t
				_log["squad_arrived"] = _arrived()
				# Back to the start, out of the squad's hands, for the solo run.
				q.clear_assignments()
				q.order = null
				for i in members.size():
					members[i].squad = null
					members[i].pawn.place(a.s.ai_nav.snap(START + Vector3(-1.5 + i, 0.0, 0.0)))
				_stage = "reset"
				_t = now
		"reset":
			if now - _t > 1.0:
				var st := _stats()
				_exp0 = int(st.expansions)
				_paths0 = int(st.paths)
				_stage = "solo"
				_t = now
		"solo":
			# Each on its own: the brain stood down, and a move_to a tick to the end.
			var done := true
			for i in members.size():
				var m := members[i]
				m.brain.active = false
				var goal := a.s.ai_nav.snap(GOAL + Vector3(-1.5 + i, 0.0, 0.0))
				if m.move_to(goal) != 1 and m.pawn.feet().distance_to(goal) > 1.5:
					done = false
			if done or now - _t > 70.0:
				var st := _stats()
				_log["solo_exp"] = int(st.expansions) - _exp0
				_log["solo_paths"] = int(st.paths) - _paths0
				_log["solo_time"] = now - _t
				_log["solo_arrived"] = _arrived()
				_stage = "done"
	if _tick >= LIMIT or _stage == "done":
		_finish()


func _measure_spread() -> void:
	var c := q.center()
	var far := 0.0
	for m in q.alive():
		far = maxf(far, m.pawn.feet().distance_to(c))
	_spread_max = maxf(_spread_max, far)
	_spread_sum += far
	_spread_n += 1


func _arrived() -> int:
	var n := 0
	for m in members:
		if m.pawn.feet().distance_to(GOAL) < 7.0:
			n += 1
	return n


func _finish() -> void:
	physics_frame.disconnect(_on_tick)
	var rep: SquadMsg.Report = _log.get("report")
	_ok("ordered MOVE, the squad gets there and reports DONE",
			rep != null and rep.kind == SquadMsg.ReportKind.DONE and int(_log.get("squad_arrived", 0)) == 4,
			"%s in %.1f s, %d of 4 there" % [rep, float(_log.get("squad_time", -1.0)),
			int(_log.get("squad_arrived", 0))])
	var mean_spread := _spread_sum / maxf(_spread_n, 1)
	_ok("in file: it keeps together on the way", mean_spread < 6.0 and _spread_max < 14.0,
			"mean %.1f m from the middle, at most %.1f m" % [mean_spread, _spread_max])
	_ok("alone, the four get there too", int(_log.get("solo_arrived", 0)) == 4,
			"%d of 4 in %.1f s" % [int(_log.get("solo_arrived", 0)), float(_log.get("solo_time", -1.0))])
	var se := int(_log.get("squad_exp", -1))
	var so := int(_log.get("solo_exp", -1))
	_ok("the squad's paths cost well under the four's alone (one long search, short hops)",
			se >= 0 and so > 0 and se < so * 0.6,
			"%d expansions in %d path(s) as a squad, %d in %d alone (%.0f%%)" % [se,
			int(_log.get("squad_paths", 0)), so, int(_log.get("solo_paths", 0)),
			100.0 * float(se) / maxf(so, 1)])
	print("  AI mean %.3f ms a tick, worst %.2f ms" % [a.mean_ai_ms(), a.worst_ai_us / 1000.0])
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
