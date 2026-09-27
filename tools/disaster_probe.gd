extends SceneTree

## Gate for natural disasters (Docs/Disasters.md section 8).
##
##     godot --headless --path . --script res://tools/disaster_probe.gd
##     ... -- --also-big also check the big city has no director (slow: builds it)
##
## D0: the director exists in the small city, runs one disaster at a time
## through every phase on the physics tick, can be ended early, and a drill
## changes no brick.

var _pass := 0
var _fail := 0


func _initialize() -> void:
	_run.call_deferred()


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _ticks(n: int) -> void:
	for i in n:
		await physics_frame


func _run() -> void:
	print("disaster probe")
	var city: Node3D = load("res://scenes/city.tscn").instantiate()
	root.add_child(city)
	await _ticks(30)
	var dir: DisasterDirector = city.disasters
	_ok("the small city has a director", dir != null)
	if dir == null:
		_finish()
		return

	# A drill, run through, one phase after another on the physics tick.
	var log0: int = city.authority.commands.size()
	_ok("a drill starts", dir.start("drill"))
	_ok("a second does not start while one runs", not dir.start("drill"))
	var d := dir.current
	var expect_ticks := int(round((d.warning_s + d.active_s + d.ending_s)
			* Engine.physics_ticks_per_second))
	var seen: Array[int] = [d.phase]
	var ticks := 0
	while dir.is_running() and ticks < expect_ticks * 2:
		await physics_frame
		ticks += 1
		if dir.current != null and dir.current.phase != seen[-1]:
			seen.append(dir.current.phase)
	_ok("it goes warning, active, ending, in that order",
			seen == [Disaster.Phase.WARNING, Disaster.Phase.ACTIVE, Disaster.Phase.ENDING],
			"saw %s" % [seen])
	_ok("and is over when its phases add up", absi(ticks - expect_ticks) <= 2,
			"%d tick(s), expected %d" % [ticks, expect_ticks])
	_ok("a drill changes no brick", city.authority.commands.size() == log0,
			"%d command(s) logged" % (city.authority.commands.size() - log0))

	# Ended early: straight to ENDING, and over when that runs out.
	_ok("another starts once it is over", dir.start("drill"))
	await _ticks(30)
	dir.on_key(true)
	_ok("Shift+H sends it to its ending", dir.current.phase == Disaster.Phase.ENDING)
	var end_ticks := int(ceil(dir.current.ending_s * Engine.physics_ticks_per_second)) + 2
	await _ticks(end_ticks)
	_ok("and it is over after the ending", not dir.is_running())
	_ok("the director counted both", dir.count == 2)

	# H with nothing running starts one.
	dir.on_key(false)
	_ok("H starts a rolled disaster", dir.is_running(), "kind '%s'" % dir.current_kind)
	dir.stop()
	await _ticks(int(ceil(3.0 * Engine.physics_ticks_per_second)))
	root.remove_child(city)
	city.free()

	if "--also-big" in OS.get_cmdline_user_args():
		var big: Node3D = load("res://scenes/big_city.tscn").instantiate()
		root.add_child(big)
		await _ticks(5)
		_ok("the big city has none", big.disasters == null)
		root.remove_child(big)
		big.free()
	_finish()


func _finish() -> void:
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
