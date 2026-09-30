extends SceneTree

## Acceptance probe for many agents at once (Docs/AIPlan.md P8; AI.md 10.2), in an
## arena.
##
##     godot --headless --path . --script tools/many_probe.gd
##
## One player in the middle of: 36 soldiers in squads of six, three flyers, a
## herd of five animals, and a swarm of 300 rows. The ImportanceBudget keeps ten
## SMART and the rest DIRECTED; swarm rows that reach the player become animals
## hunting it (promotion), and go back to rows once the player has gone (demotion).
## Twenty seconds in, a tower beside the fight is cut at its foot and comes down,
## and nobody stops firing (never deferred, AI.md 10.1). One clean piece falling
## is not a frame-filling collapse: the arbiter stepping DOWN under one is gated
## in the city's `-- --stress --agents` pass, where a whole block comes down.
## Timings are judged headless; with other Godot processes running they are not
## to be trusted.

const Arena := preload("res://tools/ai_arena.gd")
const SOLDIERS := 36
const SQUAD := 6
const FLYERS := 3
const HERD := 5
const ROWS := 300
const COLLAPSE_AT := 20.0
const LEAVE_AT := 45.0
const END_AT := 58.0

var _pass := 0
var _fail := 0
var a: Arena
var islands: IslandManager
var budget := ImportanceBudget.new()
var swarm: SwarmSide
var player: Pawn
var soldiers: Array[Soldier] = []
var flyers: Array[Flyer] = []
var herd: AnimalPack
var hunters: Array[Animal] = []
var tower := -1
var _tick := 0
var _t0 := -1.0
var _log := {}
var _levels := {}
var _ai_us: Array[int] = []
var _collapse_ms := 0.0
var _shots_in_collapse := 0
var _tiers_bad := 0
var _dist0 := 0.0
var _home := Vector3.ZERO


func _init() -> void:
	print("many probe")
	a = Arena.new(self, 8)
	a.s.sched.set_base_budget_ms(2.5)
	a.s.sched.set_thresholds(8.0, 4.0)
	a.s.sched.set_hysteresis(3, 45)
	physics_frame.connect(_on_tick)


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _build() -> void:
	islands = IslandManager.new()
	root.add_child(islands)
	islands.setup(a.w, ShaderMaterial.new(), null)
	# A few blocks to go round and fly over, and the tower that comes down.
	for bx in [[-40, 60], [60, -40], [-120, -60], [80, 90]]:
		a.bricks(Vector3i(bx[0], 0, bx[1]), Vector3i(18, 10, 18))
	tower = _tower(Vector3i(40, 0, 40), 36)
	player = a.player(Vector3.ZERO)
	budget.players = [player]
	# Soldiers, in squads, in a ring 35-70 m out.
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	for q in SOLDIERS / SQUAD:
		var ang := TAU * q / float(SOLDIERS / SQUAD)
		var centre := Vector3(cos(ang), 0.0, sin(ang)) * rng.randf_range(35.0, 70.0)
		var members: Array[Soldier] = []
		for i in SQUAD:
			var so := a.soldier(a.s.ai_nav.snap(centre + Vector3((i % 3) * 1.5, 0.0, (i / 3) * 1.5)),
					1, 100 + q * 10 + i, 300.0)
			so.pawn.intents.look_yaw = atan2(centre.x, centre.z)
			members.append(so)
			soldiers.append(so)
			budget.add(so)
		Squad.make(a.s, root, members, 1)
	for i in FLYERS:
		var ang := TAU * i / float(FLYERS) + 0.4
		var f := Flyer.spawn(a.s, root, Vector3(cos(ang) * 45.0, 18.0, sin(ang) * 45.0), 1,
				a.rifle(200 + i))
		flyers.append(f)
		budget.add(f)
	# Wildlife: on no side.
	_home = Vector3(-20.0, 0.0, -24.0)
	herd = AnimalPack.new(a.s, -1, _home, 3)
	for i in HERD:
		var an := Animal.spawn(a.s, root, a.s.ai_nav.snap(_home + Vector3(i * 1.5, 0.0, 0.0)), herd,
				60.0, 300 + i if i < 2 else -1)
		budget.add(an)
	# The swarm: 300 rows in a ring 60-95 m out.
	var pts := PackedVector3Array()
	for i in ROWS:
		var ang := rng.randf() * TAU
		pts.append(Vector3(cos(ang), 0.0, sin(ang)) * rng.randf_range(60.0, 95.0))
	swarm = SwarmSide.new()
	swarm.chunks = func() -> Array: return a.chunks
	swarm.spawn_promoted = _promoted
	swarm.node_room = func() -> int: return ImportanceBudget.SMART_CAP + ImportanceBudget.DIRECTED_CAP - _live_nodes()
	swarm.setup(a.s, root, 1, pts, 40.0, 11)
	swarm.refresh()
	budget.demote_to_swarm = swarm.demote
	_dist0 = _mean_soldier_distance()


## A tower 10 x 10 studs, `courses` high: brick walls round a hollow, and a
## 10x10 plate every third course tying the walls together -- a building, not a
## bundle of loose columns: cut at its foot, it goes as one piece.
func _tower(lo: Vector3i, courses: int) -> int:
	var c := a.w.create_chunk(lo, Vector3i(10, courses * 3 + 1, 10))
	for y in courses:
		if y % 3 == 2:
			a.w.place_block(c, lo + Vector3i(0, y * 3, 0), a.palette["plate_10x10"], 2)
			for x in 10:
				for z in 10:
					if x == 0 or z == 0 or x == 9 or z == 9:
						a.w.place_block(c, lo + Vector3i(x, y * 3 + 1, z), a.palette["plate_1x1"], 4)
						a.w.place_block(c, lo + Vector3i(x, y * 3 + 2, z), a.palette["plate_1x1"], 4)
			continue
		for x in 10:
			for z in 10:
				if x == 0 or z == 0 or x == 9 or z == 9:
					a.w.place_block(c, lo + Vector3i(x, y * 3, z), a.palette["brick_1x1"], 4)
	a.w.set_chunk_anchored(c, true)
	a.w.set_tension_per_stud(c, 9.3)
	var body := StaticBody3D.new()
	body.collision_layer = Layers.STRUCTURE
	var built: Dictionary = a.w.add_chunk_shapes(body.get_rid(), c, Vector3.ZERO, false)
	root.add_child(body)
	a.chunks.append(c)
	a._shapes[c] = [body.get_rid(), built.map]
	a.s.ai_world.sync()
	return c


func _live_nodes() -> int:
	var n := 0
	for ag in budget.agents:
		if is_instance_valid(ag) and not ag.is_dead():
			n += 1
	return n


## A row that reached the player: an animal of its own pack, hunting it.
func _promoted(pos: Vector3, hp: float) -> Object:
	var pack := AnimalPack.new(a.s, 1, pos, hunters.size())
	var an := Animal.spawn(a.s, root, a.s.ai_nav.snap(pos), pack, maxf(hp, 1.0), -1, AgentTier.DIRECTED)
	an.swarm_born = true
	pack.hunt(player)
	hunters.append(an)
	budget.add(an)
	return an


func _mean_soldier_distance() -> float:
	var d := 0.0
	var n := 0
	for so in soldiers:
		if not so.is_dead():
			d += so.pawn.feet().distance_to(player.feet())
			n += 1
	return d / maxf(n, 1)


func _on_tick() -> void:
	_tick += 1
	if _tick == 1:
		_build()
		return
	var now := a.s.now()
	if _t0 < 0.0:
		_t0 = now
	var t := now - _t0
	# Destruction first, as the city does: its cost is what the arbiter reads.
	var d0 := Time.get_ticks_usec()
	islands.tick()
	var destruction_ms := (Time.get_ticks_usec() - d0) / 1000.0
	if t >= COLLAPSE_AT and not _log.has("collapsed"):
		var c0 := Time.get_ticks_usec()
		_collapse()
		destruction_ms += (Time.get_ticks_usec() - c0) / 1000.0
		_collapse_ms = (Time.get_ticks_usec() - c0) / 1000.0
	a.s.sched.report_destruction_ms(destruction_ms)
	var dk := "d_" + ("before" if t < COLLAPSE_AT else ("collapse" if t < COLLAPSE_AT + 8.0 else "after"))
	_log[dk] = maxf(float(_log.get(dk, 0.0)), destruction_ms)
	var u0 := Time.get_ticks_usec()
	a.tick()
	budget.tick(now)
	var ai_us := Time.get_ticks_usec() - u0 + int(swarm.tick_ms() * 1000.0)
	if _tick > 30:
		_ai_us.append(ai_us)
	var phase := "before" if t < COLLAPSE_AT else ("collapse" if t < COLLAPSE_AT + 8.0 else "after")
	_levels[phase] = maxi(int(_levels.get(phase, 0)), a.s.sched.get_level())
	_levels["end"] = a.s.sched.get_level()
	if phase == "collapse":
		for so in soldiers:
			if so.pawn.intents.fire:
				_shots_in_collapse += 1
	_player_script(t)
	_watch(t)
	if t >= END_AT:
		_finish()


## The player: turns slowly, firing in bursts -- at whatever is in front of it.
func _player_script(t: float) -> void:
	if t < LEAVE_AT:
		player.intents.look_yaw = t * 0.25
		player.intents.look_pitch = -0.05
		player.intents.fire = fmod(t, 3.0) < 1.2
	elif not _log.has("left"):
		# Gone: far away and quiet. What was born of the swarm goes back to it.
		_log["left"] = true
		_log["hunters_before"] = _live_hunters()
		_log["bites"] = _bites()
		player.place(Vector3(0.0, 0.0, -400.0))
		player.intents.fire = false
	else:
		player.intents.fire = false


func _live_hunters() -> int:
	var n := 0
	for h in hunters:
		if is_instance_valid(h) and not h.is_dead():
			n += 1
	return n


func _collapse() -> void:
	_log["collapsed"] = true
	# Cut at its foot: the tower above is one piece, and it goes.
	var cut := Vector3(40 * Arena.STUD + 1.75, 3 * Arena.COURSE + 0.05, 40 * Arena.STUD + 0.05)
	a.w.sever_seams(tower, PackedVector3Array([cut]), Vector3.UP)
	var groups: Array = a.w.find_detached_groups(tower)
	var n := 0
	for g in groups:
		a._disable(tower, g)
		var isl := islands.spawn(tower, g, Vector3(0.6, 0.0, 0.3))
		if isl != null:
			n += 1
	_log["pieces"] = n
	a.s.ai_world.sync()


func _watch(t: float) -> void:
	if t >= 10.0 and t < LEAVE_AT and budget.ticked:
		budget.ticked = false
		# Ten smart, the rest directed -- and the smart ones the most important,
		# by the scores the budget itself used.
		var smart := []
		var directed := []
		for sc in budget.last_scores:
			var ag: Object = sc[1]
			if not is_instance_valid(ag) or ag.is_dead():
				continue
			var imp: float = sc[0]
			if ag.tier_hsm.tier() == AgentTier.SMART:
				smart.append(imp)
			else:
				directed.append(imp)
		var live := smart.size() + directed.size()
		var weakest_smart: float = smart.min() if not smart.is_empty() else INF
		var strongest_directed: float = directed.max() if not directed.is_empty() else 0.0
		# A promotion held back by the per-tick cap waits a tick: that is the rule
		# (PROMOTIONS_PER_TICK), not a miss.
		if smart.size() != mini(ImportanceBudget.SMART_CAP, live) \
				or directed.size() > ImportanceBudget.DIRECTED_CAP \
				or (strongest_directed > weakest_smart * ImportanceBudget.HYSTERESIS
					and budget.deferred_last == 0):
			_tiers_bad += 1
		_log["tier_samples"] = int(_log.get("tier_samples", 0)) + 1
		_log["smart"] = smart.size()
		_log["directed"] = directed.size()
	if t >= 35.0 and not _log.has("closed"):
		_log["closed"] = _mean_soldier_distance()
	if herd.mode == AnimalPack.Mode.GRAZE and t > 5.0 and t < 12.0:
		var spread := 0.0
		for m in herd.alive():
			spread = maxf(spread, (m.budget_pos() as Vector3).distance_to(herd.centre()))
		_log["graze_spread"] = maxf(float(_log.get("graze_spread", 0.0)), spread)


func _finish() -> void:
	physics_frame.disconnect(_on_tick)
	var sum := 0
	var worst := 0
	for u in _ai_us:
		sum += u
		worst = maxi(worst, u)
	var mean := float(sum) / maxf(_ai_us.size(), 1) / 1000.0
	_ai_us.sort()
	var p99 := _ai_us[int(_ai_us.size() * 0.99)] / 1000.0 if not _ai_us.is_empty() else 0.0
	print("  AI per tick: mean %.3f ms, 99th %.2f ms, worst %.2f ms; swarm tick %.2f ms; budget %.2f ms; %d field(s)" % [
			mean, p99, worst / 1000.0, swarm.tick_ms(), budget.last_ms, a.s.fields_built])
	print("  arbiter level: %s; collapse cut %.1f ms, %s piece(s); worst destruction ms before %.1f, collapse %.1f, after %.1f; islands %d" % [_levels, _collapse_ms, _log.get("pieces", 0), float(_log.get("d_before", 0.0)), float(_log.get("d_collapse", 0.0)), float(_log.get("d_after", 0.0)), islands.islands.size()])
	_ok("ten smart, the rest directed, the smart the most important",
			_tiers_bad == 0 and int(_log.get("tier_samples", 0)) > 10,
			"%d of %d samples off; last %d smart, %d directed; %d promotion(s), %d demotion(s) in the budget" % [
			_tiers_bad, int(_log.get("tier_samples", 0)), int(_log.get("smart", 0)),
			int(_log.get("directed", 0)), budget.promotions, budget.demotions])
	_ok("the swarm is there: rows walk on the player and its rounds hit them",
			swarm.alive() > ROWS / 2 and swarm.rows_hit > 0,
			"%d rows alive, %d hit" % [swarm.alive(), swarm.rows_hit])
	_ok("rows that reach the player become animals hunting it, and bite",
			swarm.promoted >= 1 and hunters.size() >= 1 and int(_log.get("bites", 0)) > 0,
			"%d promoted, %d bite(s)" % [swarm.promoted, int(_log.get("bites", 0))])
	_ok("with the player gone, the swarm-born go back to rows",
			swarm.demoted >= 1 and _live_hunters() < int(_log.get("hunters_before", 0)),
			"%d demoted; %d hunter(s) before, %d after" % [swarm.demoted,
			int(_log.get("hunters_before", 0)), _live_hunters()])
	_ok("directed soldiers close on the shared flow field",
			a.s.fields_built >= 1 and float(_log.get("closed", INF)) < _dist0 - 5.0,
			"mean %.1f m -> %.1f m; %d field(s)" % [_dist0, float(_log.get("closed", -1.0)), a.s.fields_built])
	var low := INF
	var fshots := 0
	for f in flyers:
		low = minf(low, f.lowest_clearance)
		fshots += f.shots
	_ok("flyers keep over the height field and fight", low >= Flyer.CLEARANCE - 1.0 and fshots > 0,
			"lowest %.1f m over it; %d round(s)" % [low, fshots])
	_ok("the herd grazes together and runs from gunfire",
			float(_log.get("graze_spread", 99.0)) < 8.0 and herd.fled >= 1,
			"spread %.1f m grazing; fled %d time(s)" % [float(_log.get("graze_spread", -1.0)), herd.fled])
	_ok("through the tower coming down the arbiter settles back to full service",
			_log.has("collapsed") and int(_levels.get("end", 9)) == 0,
			"levels %s" % [_levels])
	_ok("firing is never deferred: soldiers still shoot during the collapse", _shots_in_collapse > 0,
			"%d soldier-ticks firing" % _shots_in_collapse)
	var blocked := 0
	for so in soldiers:
		blocked += so.blocked_shots
	for f in flyers:
		blocked += f.blocked_shots
	_ok("no round through a wall", blocked == 0, "%d" % blocked)
	_ok("inside the AI budget", mean < 2.5, "mean %.3f ms a tick (with the swarm's own tick)" % mean)
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _bites() -> int:
	var n := 0
	for h in hunters:
		if is_instance_valid(h):
			n += h.bites
	return n
