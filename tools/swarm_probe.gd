extends SceneTree

## Acceptance probe for SwarmCore in this project's build (Docs/AIPlan.md P1, R18).
##
##     godot --headless --path . --script tools/swarm_probe.gd
##
## BoomerBorder's C++ horde, compiled into the brick extension: it loads, a ring of
## agents closes on the goal, a bullet finds one, a grenade kills a clump, the
## deaths come back for effects, and the tick stays inside a budget. Its rolls come
## from its own seeded generator (set_seed), not the global one (D9).

const POP := 400
const RING := 40.0
## Six seconds at a paced 60 fps: a headless run is otherwise unthrottled, and
## the horde walks by the clock, not by the frame.
const FRAMES := 360
## A horde this size has to tick well inside a frame.
const BUDGET_MS := 4.0

var _pass := 0
var _fail := 0
var _swarm: SwarmCore
var _frame := 0
var _start_dist := 0.0
var _worst_ms := 0.0


func _init() -> void:
	print("swarm probe")
	Engine.max_fps = 60
	_ok("SwarmCore is in the brick extension", ClassDB.class_exists(&"SwarmCore")
			and ClassDB.class_exists(&"LaneGraph") and ClassDB.class_exists(&"FlowGrid"))
	_swarm = SwarmCore.new()
	_swarm.name = "Swarm"
	_swarm.set_seed(7)
	_swarm.configure(POP, 2.0, 60)
	root.add_child(_swarm)
	_swarm.set_goal_position(Vector3.ZERO)
	_swarm.set_camera_position(Vector3(0.0, 2.0, 0.0))
	var ring := PackedVector3Array()
	for i in POP:
		var a := TAU * float(i) / POP
		ring.append(Vector3(cos(a), 0.0, sin(a)) * (RING + float(i % 5)))
	_swarm.spawn_batch(ring, 100.0)
	process_frame.connect(_on_frame)


func _mean_dist() -> float:
	var total := 0.0
	var n := 0
	for i in POP:
		var st: Dictionary = _swarm.get_agent_state(_swarm.make_handle(i))
		if st.is_empty() or float(st.get("health", 0.0)) <= 0.0:
			continue
		var p: Vector3 = st.position
		total += Vector2(p.x, p.z).length()
		n += 1
	return total / maxf(n, 1)


func _on_frame() -> void:
	_frame += 1
	_swarm.set_goal_position(Vector3.ZERO)
	# Spawning is metered per frame; wait for the whole ring.
	if _start_dist == 0.0 and _swarm.get_alive_count() == POP:
		_ok("the whole ring spawns", true, "by frame %d" % _frame)
		_start_dist = _mean_dist()
	if _frame > 5:
		_worst_ms = maxf(_worst_ms, _swarm.get_last_tick_ms())
	if _frame == FRAMES:
		_finish()


func _finish() -> void:
	process_frame.disconnect(_on_frame)
	if _start_dist == 0.0:
		_ok("the whole ring spawns", false, "%d of %d" % [_swarm.get_alive_count(), POP])
	var now := _mean_dist()
	_ok("it closes on the goal", now < _start_dist - 3.0,
			"%.1f m -> %.1f m" % [_start_dist, now])
	var tiers: PackedInt32Array = _swarm.get_tier_counts()
	var sum := 0
	for t in tiers:
		sum += t
	_ok("every live agent has a tier", sum == _swarm.get_alive_count(), "%s" % tiers)

	# A bullet down the line from the goal to an agent finds somebody.
	var st: Dictionary = _swarm.get_agent_state(_swarm.make_handle(0))
	var p: Vector3 = st.position
	var aim := Vector3(p.x, p.y + 0.9, p.z)
	var from := Vector3(0.0, aim.y, 0.0)
	var shot: Dictionary = _swarm.apply_hitscan(from, (aim - from).normalized(), 30.0)
	_ok("a bullet finds an agent", float(shot.get("dealt", 0.0)) > 0.0, "%s" % shot)

	var before := _swarm.get_alive_count()
	var killed := _swarm.apply_radial_damage(Vector3(p.x, 0.0, p.z), 5.0, 1000.0)
	_ok("a grenade kills the clump round it", killed > 0
			and _swarm.get_alive_count() == before - killed, "%d killed" % killed)
	var deaths := PackedVector3Array()
	for i in 20:
		deaths.append_array(_swarm.poll_deaths())
	_ok("and the deaths come back for effects", deaths.size() > 0, "%d" % deaths.size())
	_ok("the tick fits the budget", _worst_ms < BUDGET_MS,
			"worst %.2f ms for %d agents" % [_worst_ms, POP])
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])
