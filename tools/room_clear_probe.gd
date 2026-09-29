extends SceneTree

## Acceptance probe for clearing a room (Docs/AIPlan.md P6), in an arena.
##
##     godot --headless --path . --script tools/room_clear_probe.gd
##
## Two rooms, one squad of four each, each given a CLEAR_ROOM order:
##   A. A room with a door and somebody hidden in its far corner whom nobody
##      knows about. The squad stacks either side of the door, waits for all four
##      (the reply barrier), flashes the room, goes in crisscross, takes the four
##      corners, finds and drops the defender, sweeps, calls it clear and reports
##      DONE.
##   B. The same, but the squad knows a defender is in there watching the door:
##      it makes a door of its own in the wall beside it (mouse-holing) and goes
##      in through that.

const Arena := preload("res://tools/ai_arena.gd")
const LIMIT := 30 * 70

var _pass := 0
var _fail := 0
var a: Arena
var _tick := 0
var _runs: Array[Dictionary] = []


func _init() -> void:
	print("room clear probe")
	a = Arena.new(self, 17)
	physics_frame.connect(_on_tick)


## Built on the first tick, once the root is in the tree: a pawn's eye has no
## global position before that.
func _build() -> void:
	# Room A: 16 x 12 studs, a 4-stud door in the south wall. The squad waits
	# 8 m south of it.
	_runs.append(_stage("A", 0, 0, false, Vector3(3.0, 0.0, -8.0)))
	# Room B, 40 m east: the same, but the defender stands where it watches the
	# door, and the squad knows it is there.
	_runs.append(_stage("B", 115, 0, true, Vector3(43.0, 0.0, -8.0)))


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _stage(label: String, x0: int, z0: int, known: bool, squad_at: Vector3) -> Dictionary:
	# B is wider, its door off to one side: there has to be wall beside a door to
	# make another in.
	var wx := 24 if known else 16
	var r := a.room(x0, z0, wx, 12, 5, x0 + (5 if known else 6), 4, _runs.size() + 1)
	var room: RoomTactics = r.room
	var box := room.box
	var defender: Pawn
	if known:
		# Against the north wall, facing the door: it sees anyone come through it.
		defender = a.player(Vector3(box.get_center().x + 0.6, 0.0, box.end.z - 0.6), 100.0, false)
		Arena.look(defender, (r.opening.center as Vector3) + Vector3.UP * 1.2)
	else:
		# Against the west wall, halfway in: out of the line through the door.
		defender = a.player(Vector3(box.position.x + 0.45, 0.0, box.get_center().z + 0.3), 100.0, false)
		Arena.look(defender, room.center())
	var members: Array[Soldier] = []
	for i in 4:
		var so := a.soldier(a.s.ai_nav.snap(squad_at + Vector3((i % 2) * 1.2, 0.0, -(i / 2) * 1.2)),
				1, 30 + i + x0)
		so.pawn.intents.look_yaw = 0.0
		members.append(so)
	var q := Squad.make(a.s, root, members, 1)
	var run := {"label": label, "room": room, "opening": r.opening, "defender": defender,
			"squad": q, "members": members, "crossed": {}, "slots_ok": false, "at_stack": [],
			"known": known, "order": 0, "done_at": -1.0, "hp": []}
	for m in members:
		(run.hp as Array).append(m.pawn.health.total_current())
	return run


func _order(run: Dictionary) -> void:
	var q: Squad = run.squad
	if run.known:
		# Intel: the side knows somebody is in there, and where.
		var d: Pawn = run.defender
		a.s.knowledge_of(1).heard(d, d.feet(), a.s.now())
	var o := SquadMsg.Order.make(SquadMsg.OrderKind.CLEAR_ROOM)
	o.room = run.room
	o.opening = run.opening
	o.wall_thick = Arena.STUD
	run.order = q.give(o)


func _on_tick() -> void:
	_tick += 1
	if _tick == 1:
		_build()
	a.tick()
	if _tick == 10:
		for run in _runs:
			_order(run)
	var all_done := true
	for run in _runs:
		_watch(run)
		if float(run.done_at) < 0.0:
			all_done = false
	if (all_done and _tick > 20) or _tick >= LIMIT:
		_finish()


func _watch(run: Dictionary) -> void:
	var q: Squad = run.squad
	var room: RoomTactics = run.room
	var now := a.s.now()
	# Where each member first steps inside the room.
	for m: Soldier in run.members:
		var f := m.pawn.feet()
		var key := m.get_instance_id()
		if not (run.crossed as Dictionary).has(key) and room.contains(f):
			run.crossed[key] = f
	if q.events.has("cleared") and not run.has("at_clear"):
		var at: Array[Vector3] = []
		for m: Soldier in run.members:
			at.append(m.pawn.feet())
		run.at_clear = at
	if q.events.has("stacked") and (run.at_stack as Array).is_empty():
		for m: Soldier in run.members:
			(run.at_stack as Array).append(m.pawn.feet())
	if float(run.done_at) < 0.0:
		for r in q.reports:
			if r.order_id == int(run.order) and r.kind != SquadMsg.ReportKind.ACCEPTED:
				run.done_at = now
				run.report = r


func _finish() -> void:
	physics_frame.disconnect(_on_tick)
	for run in _runs:
		_judge(run)
	print("  AI mean %.3f ms a tick, worst %.2f ms" % [a.mean_ai_ms(), a.worst_ai_us / 1000.0])
	_ok("inside the AI budget with two squads of four", a.mean_ai_ms() < 1.5,
			"mean %.3f ms" % a.mean_ai_ms())
	var said := {}
	for l in a.s.callouts.said:
		said[l[2]] = true
	_ok("the plays are called out", said.has("stack") and said.has("flash") and said.has("go")
			and said.has("clear") and said.has("breaching"), "%s" % [said.keys()])
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _judge(run: Dictionary) -> void:
	var q: Squad = run.squad
	var room: RoomTactics = run.room
	var ev := q.events
	var tag := "[%s] " % run.label
	var op: Dictionary = ev.get("way_in", {})
	var shown := ev.duplicate()
	shown.erase("way_in")
	print("  %s events %s" % [tag, shown])
	# The stack: four there at once, two either side of the way in.
	var sides := [0, 0]
	var at_slot := 0
	var slots: Array[Vector3] = RoomTactics.stack_slots(op, 4) if not op.is_empty() else ([] as Array[Vector3])
	for i in (run.at_stack as Array).size():
		var f: Vector3 = run.at_stack[i]
		var right := (f - (op.center as Vector3)).dot(RoomTactics.right_of(op)) > 0.0
		sides[1 if right else 0] += 1
		for sl in slots:
			if Vector2(f.x - sl.x, f.z - sl.z).length() < 0.8:
				at_slot += 1
				break
	_ok(tag + "four stack, two either side of the way in, and the play waits for all of them",
			ev.has("stacked") and sides == [2, 2] and at_slot == 4,
			"sides %s, %d in their slots, at %.1f s" % [sides, at_slot, float(ev.get("stacked", -1.0))])
	_ok(tag + "the room is prepped: a flashbang after the stack and before the entry",
			ev.has("flashed") and float(ev.flashed) >= float(ev.get("stacked", INF))
			and float(ev.get("entered", -1.0)) >= float(ev.flashed),
			"flash %.1f s, entry %.1f s" % [float(ev.get("flashed", -1.0)), float(ev.get("entered", -1.0))])
	# Crisscross: the first two through end on the side they did not stack on.
	var crossed := 0
	var cornered := 0
	var corners: Array[Vector3] = room.crisscross(op, 4) if not op.is_empty() else ([] as Array[Vector3])
	var team := q.members
	for i in team.size():
		var m: Soldier = team[i]
		if m.is_dead():
			continue
		var f: Vector3 = run.at_clear[i] if run.has("at_clear") else m.pawn.feet()
		for c in corners:
			if Vector2(f.x - c.x, f.z - c.z).length() < 0.9:
				cornered += 1
				break
	# Who went first, and where it ended up.
	var stack_side := {}
	for i in (run.at_stack as Array).size():
		var f: Vector3 = run.at_stack[i]
		stack_side[team[i].get_instance_id()] = (f - (op.center as Vector3)).dot(RoomTactics.right_of(op)) > 0.0
	var firsts := _first_two(run)
	for m in firsts:
		var end: Vector3 = run.at_clear[team.find(m)] if run.has("at_clear") else m.pawn.feet()
		var end_right := (end - (op.center as Vector3)).dot(RoomTactics.right_of(op)) > 0.0
		if stack_side.has(m.get_instance_id()) and end_right != bool(stack_side[m.get_instance_id()]):
			crossed += 1
	_ok(tag + "in crisscross: the first two through cross to the other side, and all four take corners",
			crossed == 2 and cornered == 4, "%d crossed, %d in corners" % [crossed, cornered])
	# In through the way the play chose.
	var through := 0
	for k in run.crossed:
		var p: Vector3 = run.crossed[k]
		if not op.is_empty() and Vector2(p.x - op.center.x, p.z - op.center.z).length() < 1.3:
			through += 1
	_ok(tag + "all four go in through the " + ("hole it made" if run.known else "door"),
			through == 4, "%d of %d went in within 1.3 m of it" % [through, (run.crossed as Dictionary).size()])
	var d: Pawn = run.defender
	var rep: SquadMsg.Report = run.get("report")
	_ok(tag + "the defender is found and dropped, the room called clear, and the order reported DONE",
			d.health.is_dead() and q.cleared.has(room.id) and rep != null
			and rep.kind == SquadMsg.ReportKind.DONE and q.reports[0].kind == SquadMsg.ReportKind.ACCEPTED,
			"defender %s; reports %s; in %.1f s" % ["down" if d.health.is_dead() else "UP", q.reports,
			float(run.done_at) - 10.0 / 30.0])
	var blocked := 0
	var hurt := 0
	for i in team.size():
		blocked += team[i].blocked_shots
		if team[i].pawn.health.total_current() < float(run.hp[i]):
			hurt += 1
	_ok(tag + "no round through a wall, nobody shot by a squadmate", blocked == 0 and hurt == 0,
			"%d blocked, %d hurt" % [blocked, hurt])
	if run.known:
		var hole: Vector3 = ev.get("opening", Vector3.INF)
		var door: Vector3 = run.opening.center
		_ok(tag + "the door is watched, so it makes its own beside it (mouse-holing)",
				bool(ev.get("breach", false)) and ev.has("breached") and a.breached_blocks > 0
				and hole.distance_to(door) > 1.3,
				"hole %.1f m from the door, %d bricks blown" % [hole.distance_to(door), a.breached_blocks])


## The first two members to step into the room.
func _first_two(run: Dictionary) -> Array[Soldier]:
	var order: Array[Soldier] = []
	var q: Squad = run.squad
	var ev := q.events
	# Entry order is the stack order: the squad's play put the stack's first two
	# first. Stack order = which slot each took: nearest to the opening first.
	var op_c: Vector3 = ev.get("opening", Vector3.ZERO)
	var by := []
	for i in (run.at_stack as Array).size():
		by.append([(run.at_stack[i] as Vector3).distance_to(op_c), q.members[i]])
	by.sort_custom(func(x, y): return x[0] < y[0])
	for k in mini(2, by.size()):
		order.append(by[k][1])
	return order
