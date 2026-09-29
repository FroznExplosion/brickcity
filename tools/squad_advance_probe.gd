extends SceneTree

## Acceptance probe for a squad in the open (Docs/AIPlan.md P6), in an arena.
##
##     godot --headless --path . --script tools/squad_advance_probe.gd
##
## A squad of four and a player 45 m off behind a low wall, watching them. Rows of
## low walls between. On the physics tick:
##   1. ADVANCE: bounding overwatch -- two move while two suppress, then swap --
##      and a mover goes only while its move is masked. Midway every suppressor
##      reloads at once: the movers must hold until the fire is back on the
##      player. Never more than two shoot the player at once (attack tokens).
##   2. SEARCH: the player slips away out of sight. The squad searches its last
##      known position in two pairs, one either side, and marks it searched.
##   3. MORALE: the player is back, close, and two of the squad are dropped. The
##      two left break and fall back, away from it, and hold.

const Arena := preload("res://tools/ai_arena.gd")
const LIMIT := 30 * 110
const P0 := Vector3(0.0, 0.0, -45.0)

var _pass := 0
var _fail := 0
var a: Arena
var q: Squad
var members: Array[Soldier] = []
var player: Pawn
var _tick := 0
var _stage := "build"
var _t := 0.0
var _log := {}
var _reasons := {}
var _max_firing := 0
var _max_tokens := 0
var _reload_held := 0
var _order_adv := 0


func _init() -> void:
	print("squad advance probe")
	a = Arena.new(self, 23)
	physics_frame.connect(_on_tick)


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _build() -> void:
	# Rows of walls (5 courses, 2.1 m: cover for somebody standing -- nobody
	# crouches, Docs/AI.md A21), staggered.
	var rows := [-8, -16, -24, -32]
	for k in rows.size():
		var z: int = int(rows[k] / Arena.STUD)
		var x: int = -14 if k % 2 == 0 else 2
		a.bricks(Vector3i(x, 0, z), Vector3i(12, 5, 1))
	# The player's wall, low enough that the player is seen over it (2 courses),
	# and a big block to slip behind later.
	a.bricks(Vector3i(-6, 0, int(-43.5 / Arena.STUD)), Vector3i(12, 2, 1))
	# Big enough that a soldier who has pushed right up to it cannot see round
	# it to where the player hides (8.4 m square, 3.4 m tall).
	a.bricks(Vector3i(30, 0, -170), Vector3i(24, 8, 24))
	player = a.player(P0)
	for i in 4:
		var so := a.soldier(a.s.ai_nav.snap(Vector3(-1.5 + i, 0.0, 0.0)), 1, 40 + i, 400.0)
		so.pawn.intents.look_yaw = 0.0
		members.append(so)
	q = Squad.make(a.s, root, members, 1)


func _on_tick() -> void:
	_tick += 1
	if _tick == 1:
		_build()
	a.tick()
	var now := a.s.now()
	if _stage == "build" and _tick >= 15:
		# Seen first, then ordered: the squad knows what it is advancing on.
		if q.contact() != null:
			var o := SquadMsg.Order.make(SquadMsg.OrderKind.ADVANCE)
			o.point = P0
			_order_adv = q.give(o)
			_stage = "advance"
			_t = now
	match _stage:
		"advance":
			_advance(now)
		"search":
			_search(now)
		"morale":
			_morale(now)
	if _tick >= LIMIT or _stage == "done":
		_finish()


func _watch_player() -> void:
	# The player watches the squad, always.
	Arena.look(player, q.center() + Vector3.UP * 1.0)


func _advance(now: float) -> void:
	_watch_player()
	var firing := 0
	for m in members:
		if m.pawn.intents.fire and m._aim_target == player:
			firing += 1
		if m.masked_move and m.mask_state != "":
			_reasons[m.mask_state] = int(_reasons.get(m.mask_state, 0)) + 1
	_max_firing = maxi(_max_firing, firing)
	_max_tokens = maxi(_max_tokens, a.s.tokens_on(player))
	# Midway, every suppressor reloads at once.
	if not _log.has("reload_at") and int(q.events.get("bounds", 0)) >= 3:
		var n := 0
		for m in members:
			if m.suppress_point != Vector3.INF:
				m.pawn.gun.ammo = 0
				m.pawn.gun.reload()
				n += 1
		if n > 0:
			_log["reload_at"] = now
			_log["reload_n"] = n
			_log["held0"] = _held()
	if _log.has("reload_at") and not _log.has("held1") and now - float(_log.reload_at) > 2.5:
		_log["held1"] = _held()
	for r in q.reports:
		if r.order_id == _order_adv and r.kind != SquadMsg.ReportKind.ACCEPTED and not _log.has("adv_report"):
			_log["adv_report"] = r
			_log["adv_time"] = now - _t
			_log["adv_near"] = _nearest(P0)
	if _log.has("adv_report") or now - _t > 70.0:
		_log["unmasked"] = 0.0
		_log["masked"] = 0.0
		for m in members:
			_log.unmasked += m.unmasked_moved
			_log.masked += m.masked_moved
		# The player slips away behind the block.
		player.place(Vector3(14.7, 0.0, -62.5))
		_log["lkp"] = P0
		_stage = "search"
		_t = now


func _held() -> int:
	var n := 0
	for m in members:
		n += m.held_ticks
	return n


func _nearest(p: Vector3) -> float:
	var d := INF
	for m in q.alive():
		d = minf(d, m.pawn.feet().distance_to(p))
	return d


func _search(now: float) -> void:
	Arena.look(player, player.eye.global_position + Vector3.FORWARD)
	if q.play == "search pairs" and not _log.has("pairs_at"):
		_log["pairs_at"] = now - _t
		# "Either side" is across the squad's own approach to the spot, as the
		# play lays its pairs out (BTPlaySearchPairs), not a fixed world axis:
		# after an advance the squad can come at it from the side.
		var c0 := q.contact()
		var along := (c0.pos if c0 != null else P0) - q.center()
		along.y = 0.0
		_log["search_right"] = along.normalized().cross(Vector3.UP) if along.length() > 0.1 \
				else Vector3.FORWARD.cross(Vector3.UP)
		_log["lkp"] = c0.pos if c0 != null else P0
	if q.events.has("searched") and not _log.has("searched"):
		_log["searched"] = now - _t
		# Where each member stood when it swept: two either side of the spot.
		var sides := [0, 0]
		var c := q.contact()
		var lkp: Vector3 = _log.lkp
		var dir := lkp - Vector3(0, 0, 0)
		var right: Vector3 = _log.get("search_right", Vector3.FORWARD.cross(Vector3.UP))
		for m in q.alive():
			var f := m.pawn.feet()
			if f.distance_to(lkp) < 5.0:
				sides[0 if (f - lkp).dot(right) > 0.0 else 1] += 1
		_log["search_sides"] = sides
		# Back, close, in the open, and two of the squad dropped.
		player.place(Vector3(0.0, 0.0, -30.0))
		_stage = "morale"
		_t = now
		_log["morale0"] = q.morale
	elif now - _t > 40.0:
		_stage = "morale"
		_t = now


func _morale(now: float) -> void:
	_watch_player()
	if not _log.has("dropped") and now - _t > 1.0:
		var alive := q.alive()
		for k in 2:
			alive[k].pawn.health.apply_impact(1e6, &"")
		_log["dropped"] = now
		_log["from"] = _nearest(player.feet())
	if _log.has("dropped") and q.play == "fall back" and not _log.has("fell_at"):
		_log["fell_at"] = now - float(_log.dropped)
	if _log.has("dropped") and now - float(_log.dropped) > 12.0:
		_log["to"] = _nearest(player.feet())
		var holding := 0
		for m in q.alive():
			if m.assignment != null and m.assignment.task == SquadMsg.Task.HOLD:
				holding += 1
		_log["holding"] = holding
		_log["broken"] = q.broken
		_stage = "done"


func _finish() -> void:
	physics_frame.disconnect(_on_tick)
	var rep: SquadMsg.Report = _log.get("adv_report")
	print("  events %s; mask reasons (mover-ticks) %s" % [q.events, _reasons])
	_ok("the squad advances by bounds and gets there: ADVANCE reported DONE",
			rep != null and rep.kind == SquadMsg.ReportKind.DONE and int(q.events.get("bounds", 0)) >= 3,
			"%s after %.1f s, %d bound(s), nearest %.1f m" % [rep, float(_log.get("adv_time", -1.0)),
			int(q.events.get("bounds", 0)), float(_log.get("adv_near", -1.0))])
	_ok("a mover moves only while masked",
			float(_log.get("unmasked", 1.0)) < 0.05 and float(_log.get("masked", 0.0)) > 15.0,
			"%.2f m moved unmasked, %.1f m masked" % [float(_log.get("unmasked", -1.0)),
			float(_log.get("masked", -1.0))])
	_ok("with the suppressors all reloading and the player watching, the movers hold",
			_log.has("reload_at") and int(_log.get("held1", 0)) > int(_log.get("held0", 0)),
			"%d reloading at %.1f s; held %d -> %d mover-ticks" % [int(_log.get("reload_n", 0)),
			float(_log.get("reload_at", -1.0)), int(_log.get("held0", 0)), int(_log.get("held1", 0))])
	_ok("suppression masks the moves", int(_reasons.get(Masking.SUPPRESSED, 0)) > 30,
			"%d mover-ticks masked by suppression" % int(_reasons.get(Masking.SUPPRESSED, 0)))
	_ok("never more than two shoot the player at once (attack tokens)",
			_max_firing <= AIServices.TOKENS and _max_tokens <= AIServices.TOKENS,
			"at most %d firing, %d tokens held" % [_max_firing, _max_tokens])
	_ok("lost, the player is searched for in pairs, one either side of where it was",
			_log.has("searched") and _log.get("search_sides", []) == [2, 2],
			"pairs at %.1f s, searched at %.1f s, sides %s" % [float(_log.get("pairs_at", -1.0)),
			float(_log.get("searched", -1.0)), _log.get("search_sides", [])])
	_ok("two dropped, the rest break and fall back, and hold",
			_log.has("fell_at") and float(_log.get("to", 0.0)) > float(_log.get("from", 0.0)) + 6.0
			and int(_log.get("holding", 0)) == 2,
			"fell back %.1f s after; %.1f m -> %.1f m from the player; %d holding; broken %s" % [
			float(_log.get("fell_at", -1.0)), float(_log.get("from", -1.0)), float(_log.get("to", -1.0)),
			int(_log.get("holding", 0)), _log.get("broken", "?")])
	var said := {}
	for l in a.s.callouts.said:
		said[l[2]] = true
	_ok("the squad calls it: moving, covering, man down, fall back",
			said.has("moving") and said.has("covering") and said.has("down") and said.has("fallback"),
			"%s" % [said.keys()])
	var blocked := 0
	for m in members:
		blocked += m.blocked_shots
	_ok("no round through a wall", blocked == 0, "%d" % blocked)
	print("  AI mean %.3f ms a tick, worst %.2f ms" % [a.mean_ai_ms(), a.worst_ai_us / 1000.0])
	_ok("inside the AI budget", a.mean_ai_ms() < 1.0, "mean %.3f ms" % a.mean_ai_ms())
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
