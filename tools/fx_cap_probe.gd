extends SceneTree
## The caps on the fight's effects (Docs/PerfCaps.md 7): damage numbers, death
## bursts, the guns' flashes and trails, and VfxPool's emitters, arcs and
## shatters. Each was a node made per event with no ceiling.
##
##   godot --headless --path . --script res://tools/fx_cap_probe.gd

var _pass := 0
var _fail := 0


func _ok(what: String, cond: bool, detail := "") -> void:
	if cond:
		_pass += 1
	else:
		_fail += 1
	print("  %s %s%s" % ["ok  " if cond else "FAIL", what, (" -- " + detail) if detail != "" else ""])


func _initialize() -> void:
	await process_frame
	var city := Node3D.new()
	root.add_child(city)
	var fb := CombatFeedback.new()
	root.add_child(fb)
	fb.setup(city)

	print("damage numbers")
	# A shotgun's ten pellets on one body: five numbers, the damage all there.
	var each := []
	for i in 10:
		each.append([7.0 + i, i == 3, Vector3(0.0, 1.0 + 0.05 * i, -5.0)])
	fb.on_player_shot(_info(each, false))
	var shown := _labels(fb)
	var total := 0
	for l in shown:
		total += int((l as Label3D).text.trim_suffix("!"))
	_ok("ten pellets on one body show five numbers", shown.size() == CombatFeedback.PELLET_NUMBERS,
			"%d" % shown.size())
	_ok("and the five add up to the ten", total == 115, "%d of 115" % total)
	_ok("a crit pellet marks its number", shown.any(func(l): return (l as Label3D).text.ends_with("!")))
	_ok("and it counts as one hit's number", fb.numbers_shown == 1, "%d" % fb.numbers_shown)
	# Three pellets: three numbers, each its own.
	_clear(fb)
	fb.on_player_shot(_info([[4.0, false, Vector3.ZERO], [5.0, false, Vector3.ZERO],
			[6.0, false, Vector3.ZERO]], false))
	_ok("three pellets show three numbers", _labels(fb).size() == 3, "%d" % _labels(fb).size())
	# A rifle round: one number.
	_clear(fb)
	fb.on_player_shot(_info([], false))
	_ok("one round shows one number", _labels(fb).size() == 1)
	# The kill colours the last of a spread.
	_clear(fb)
	fb.on_player_shot(_info(each.slice(0, 4), true))
	var reds := _labels(fb).filter(func(l): return (l as Label3D).modulate.g < 0.5)
	_ok("a killing spread colours one number red", reds.size() == 1, "%d" % reds.size())
	# Shotgun into a crowd: never more than MAX_NUMBERS labels.
	for i in 40:
		fb.on_player_shot(_info(each, false))
	_ok("forty spreads keep to %d labels" % CombatFeedback.MAX_NUMBERS,
			_labels(fb).size() <= CombatFeedback.MAX_NUMBERS
			and fb.labels_made <= CombatFeedback.MAX_NUMBERS,
			"%d shown, %d made, %d taken over" % [_labels(fb).size(), fb.labels_made, fb.numbers_recycled])

	print("death bursts")
	for i in 25:
		fb.burst(Vector3(i, 0.0, 0.0), Color(randf(), randf(), randf()))
	var bursts := city.get_children().filter(func(c): return c is CPUParticles3D)
	_ok("twenty-five kills keep to %d bursts" % CombatFeedback.MAX_BURSTS,
			bursts.size() == CombatFeedback.MAX_BURSTS, "%d" % bursts.size())
	_ok("each takes its kill's colour", (bursts[0] as CPUParticles3D).color != Color.WHITE
			and ((bursts[0] as CPUParticles3D).mesh.surface_get_material(0) as StandardMaterial3D)
			.vertex_color_use_as_albedo)
	_ok("the last is emitting where it was asked", (bursts[(25 - 1) % 8] as CPUParticles3D).emitting)

	print("gun flashes and trails")
	var live: Array[Node] = []
	for i in 50:
		GunInstance._make_room(live, GunInstance.MAX_TRAILS)
		var n := Node3D.new()
		city.add_child(n)
		live.append(n)
	await process_frame
	var trails := city.get_children().filter(func(c): return c.get_class() == "Node3D" and c.get_script() == null)
	_ok("fifty trails keep to %d" % GunInstance.MAX_TRAILS, trails.size() == GunInstance.MAX_TRAILS,
			"%d" % trails.size())

	print("VfxPool")
	var pool = load("res://autoload/vfx_pool.gd").new()
	var scene := PackedScene.new()
	var gp := GPUParticles3D.new()
	scene.pack(gp)
	gp.free()
	pool.emitter_scenes = {"spark": scene}
	pool.max_per_key = 6
	pool.max_arcs = 3
	pool.prewarm_per_key = 2
	root.add_child(pool)
	var got := 0
	for i in 20:
		if pool.acquire_emitter("spark", city) != null:
			got += 1
	_ok("an emitter key keeps to max_per_key", got == 6, "%d of 20" % got)
	_ok("an unknown key is null, not a crash", pool.acquire_emitter("nope", city) == null)
	pool.arc_ribbon_scene = scene
	var arcs := 0
	for i in 10:
		if pool.acquire_arc(city) != null:
			arcs += 1
	_ok("arcs keep to max_arcs", arcs == 3, "%d of 10" % arcs)
	for i in 15:
		pool.spawn_shatter(Vector3.ZERO, Vector3.ONE, 8)
	_ok("shatters keep to max_shatters", pool._shatters.size() == pool.max_shatters,
			"%d" % pool._shatters.size())

	print("%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _info(each: Array, killed: bool) -> Dictionary:
	var r := DamageSystem.DamageResult.new()
	r.dealt = 0.0
	for p in each:
		r.dealt += float(p[0])
	if each.is_empty():
		r.dealt = 30.0
	r.killed = killed
	return {"point": Vector3(0, 1, -5), "result": r, "each": each}


func _labels(fb: CombatFeedback) -> Array:
	return fb._numbers.map(func(e): return e[0])


func _clear(fb: CombatFeedback) -> void:
	for e in fb._numbers:
		(e[0] as Label3D).visible = false
		fb._spare_labels.append(e[0])
	fb._numbers.clear()
