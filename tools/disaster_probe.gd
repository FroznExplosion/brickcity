extends SceneTree

## Gate for natural disasters (Docs/Disasters.md section 8).
##
##     godot --headless --path . --script res://tools/disaster_probe.gd
##     ... -- --disaster-shot (windowed, not --headless) save shots/disaster_*.png
##     ... -- --also-big also check the big city has no director (slow: builds it)
##
## D0: the director exists in the small city, runs one disaster at a time
## through every phase on the physics tick, can be ended early, and a drill
## changes no brick.
## D1: a meteor shower rolls the same schedule from the same seed, every meteor
## lands, none on the player, the ones that strike a building are committed
## blasts, and the sky comes back as it was.

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
	await _until_over(dir)

	await _check_meteor(city, dir)
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


func _until_over(dir: DisasterDirector, limit_s := 120.0) -> int:
	var n := 0
	while dir.is_running() and n < int(limit_s * Engine.physics_ticks_per_second):
		await physics_frame
		n += 1
	return n


func _check_meteor(city: Node3D, dir: DisasterDirector) -> void:
	print("meteor shower")
	# The same seed rolls the same shower -- without a city: the schedule is
	# the rng's alone.
	var a := MeteorShower.new()
	var b := MeteorShower.new()
	a.begin(dir.ctx, 1234)
	b.begin(dir.ctx, 1234)
	var same := a.meteors.size() == b.meteors.size() and a.entry_dir == b.entry_dir
	for i in mini(a.meteors.size(), b.meteors.size()):
		for k in ["t", "radius", "big", "ignite", "to_building", "u", "v", "w"]:
			same = same and a.meteors[i][k] == b.meteors[i][k]
	_ok("one seed, one shower", same, "%d meteors" % a.meteors.size())
	a.free()
	b.free()
	var base: Color = dir.ctx.sky_base().sun_colour

	var n0: int = city.authority.commands.size()
	_ok("a shower starts", dir.start("meteor"))
	var m: MeteorShower = dir.current
	_ok("25-40 meteors in 3-4 bursts", m.meteors.size() >= 25 and m.meteors.size() <= 40
			and m.bursts >= 3 and m.bursts <= 4, "%d in %d" % [m.meteors.size(), m.bursts])
	var mid_sky := Color.BLACK
	var worst := 0.0
	var total := 0.0
	var ticks := 0
	var limit := int((m.warning_s + m.active_s + m.ending_s + 5.0) * Engine.physics_ticks_per_second)
	var impacts: Array[Dictionary] = []
	var count := m.meteors.size()
	var shots := "--disaster-shot" in OS.get_cmdline_user_args()
	var shot_at: Array = []
	if shots:
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://shots"))
		var t0 := float(m.meteors[0].t)
		# The warning's red sky; a ring and a meteor on its way; the strike.
		shot_at = [[-1.0, "warning"], [t0 - 0.35, "incoming"], [t0 + 0.1, "impact"],
				[t0 + 1.5, "after"]]
	var framed := false
	var cam_home: Transform3D = city.camera.global_transform
	while dir.is_running() and ticks < limit:
		await physics_frame
		ticks += 1
		# Frame the first meteor from the side as soon as its spot is known.
		if shots and not framed and m.meteors[0].stage != MeteorShower.Stage.WAITING:
			framed = true
			var aim: Vector3 = m.meteors[0].aim
			var side := m.entry_dir.cross(Vector3.UP).normalized()
			city.camera.look_at_from_position(aim + side * 60.0 + Vector3.UP * 10.0
					+ Vector3(m.entry_dir.x, 0.0, m.entry_dir.z) * 25.0, aim + Vector3.UP * 16.0)
		if not shot_at.is_empty() and dir.current != null:
			var when: float = shot_at[0][0]
			var due := (when < 0.0 and m.phase == Disaster.Phase.WARNING and m.phase_t > m.warning_s - 0.5) 					or (when >= 0.0 and m.phase != Disaster.Phase.WARNING and m._clock >= when)
			if due:
				await RenderingServer.frame_post_draw
				var img := root.get_texture().get_image()
				var path := "res://shots/disaster_meteor_%s.png" % shot_at[0][1]
				img.save_png(ProjectSettings.globalize_path(path))
				print("  --   saved %s" % path)
				shot_at.pop_front()
				if shot_at.is_empty():
					# Back where it stood: the targets follow the player, and the
					# gate below wants the city in reach.
					city.camera.global_transform = cam_home
		var ms := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
		worst = maxf(worst, ms)
		total += ms
		if dir.current != null and dir.current.phase == Disaster.Phase.ACTIVE:
			mid_sky = (city._sun as DirectionalLight3D).light_color
			impacts = m.impacts
	impacts = m.impacts if is_instance_valid(m) else impacts
	_ok("it ends", not dir.is_running(), "%d tick(s)" % ticks)
	_ok("every meteor lands", impacts.size() == count, "%d of %d" % [impacts.size(), count])
	var nearest := INF
	var first_nearest := INF
	var on_structure := 0
	var big := 0
	for i in impacts:
		nearest = minf(nearest, float(i.player_dist))
		if int(i.burst) == 0:
			first_nearest = minf(first_nearest, float(i.player_dist))
		on_structure += 1 if i.structure else 0
		big += 1 if i.big else 0
	_ok("none in the first burst within 6 m of the player", first_nearest >= 6.0,
			"nearest %.1f m (%.1f m over the whole shower)" % [first_nearest, nearest])
	_ok("some strike buildings", on_structure > 0,
			"%d of %d on structure, %d big" % [on_structure, impacts.size(), big])
	# Let the damage queue drain, then count what was committed.
	var wait := 0
	while not city._damage_queue.is_empty() and wait < 600:
		await physics_frame
		wait += 1
	var blasts := 0
	for i in range(n0, city.authority.commands.size()):
		if city.authority.commands.entries[i].kind == DamageLog.Kind.BLAST:
			blasts += 1
	_ok("the ones on buildings are committed blasts", blasts >= on_structure,
			"%d BLAST command(s), queue drained in %d tick(s)" % [blasts, wait])
	_ok("the sky reddened while it fell", mid_sky != base and mid_sky.g < base.g,
			"sun %s -> %s" % [base, mid_sky])
	_ok("and came back as it was", (city._sun as DirectionalLight3D).light_color == base)
	print("  --   physics tick during the shower: mean %.2f ms, worst %.1f ms" % [
			total / maxf(ticks, 1), worst])


func _finish() -> void:
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
