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
## D2: a lightning storm's strokes land on the tallest building near where they
## were rolled, are committed blasts, rain while it lasts, sky back after.
## D3: fire on its own (no city): metal and stone do not burn, fire climbs,
## never passes MAX_CELLS, burns out, and burns less in rain. In the city: a
## building catches, spreads, wears bricks through CHIP commands, and goes out.
## A pawn in reach of a stroke is hurt.
## D4: a tornado crosses the city past the player, pulls loose pieces (never past
## the debris cap), strips facades only inside its funnel through CHIPs, shoves
## a soldier, and leaves no hazard behind.
## D5: soldiers run out of a hazard (a meteor's ring), a burning cell is danger
## and its smoke blocks sight, and both go when the fire does.
##
## Real bricks: with the tallest building's top half blown away, its top is
## where its bricks end, lightning aims there, and fire finds air where the
## roof was. After the tornado nothing is left frozen in mid-air.
## Menu: H opens it, Start runs its choice. Intensity scales meteors (count,
## size) and the names read right. Earthquake: more intensity plans more
## failures; at Extreme with 1 at once / 3 in all, never more than that, the
## failures undermine and topple buildings; with 0 at once nothing falls.
##
##     ... -- --only=meteor,lightning,fire,pawn,soldiers,tornado,real,intensity,quake

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

	var only := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--only="):
			only = a.split("=", true, 1)[1]
	if only == "" or "director" in only:
		await _check_director(city, dir)
	if only == "" or "meteor" in only:
		await _check_meteor(city, dir)
		await _until_out(dir)
	if only == "" or "fire" in only:
		_check_fire_alone()
		await _check_fire(city, dir)
	if only == "" or "lightning" in only:
		await _check_lightning(city, dir)
		await _until_out(dir)
	if only == "" or "pawn" in only:
		_check_pawn(city, dir)
	if only == "" or "soldiers" in only:
		await _check_soldiers(city, dir)
		await _check_shove(city)
	if only == "" or "real" in only:
		await _check_real_bricks(city, dir)
	if only == "" or "intensity" in only:
		_check_intensity(dir)
	if only == "" or "quake" in only:
		await _check_quake(city, dir)
	if only == "" or "tornado" in only:
		await _check_tornado(city, dir)
	root.remove_child(city)
	city.free()

	if "--also-big" in OS.get_cmdline_user_args():
		var big: Node3D = load("res://scenes/big_city.tscn").instantiate()
		root.add_child(big)
		await _ticks(5)
		_ok("the big city has disasters too", big.disasters != null)
		if big.disasters != null:
			big.disasters.start("meteor")
			var bm: MeteorShower = big.disasters.current
			var bn := 0
			var landed := 0
			while big.disasters.is_running() and bn < 30 * 50:
				await physics_frame
				bn += 1
				if is_instance_valid(bm):
					landed = bm.impacts.size()
			_ok("and a meteor shower lands there", landed > 0, "%d meteor(s) in %.0f s" % [landed, bn / 30.0])
		root.remove_child(big)
		big.free()
	_finish()


func _check_director(city: Node3D, dir: DisasterDirector) -> void:
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

	# H opens the menu; Start runs what it holds -- Random by default.
	dir.on_key(false)
	_ok("H opens the disaster menu", dir.is_menu_open())
	await _ticks(3)
	await _save_shot("menu")
	dir.menu_kind = ""
	_ok("Start runs a rolled disaster, and closes it", dir.start_from_menu() and dir.is_running()
			and not dir.is_menu_open(), "kind '%s'" % dir.current_kind)
	dir.stop()
	await _until_over(dir)


func _until_over(dir: DisasterDirector, limit_s := 120.0) -> int:
	var n := 0
	while dir.is_running() and n < int(limit_s * Engine.physics_ticks_per_second):
		await physics_frame
		n += 1
	return n


## Wait for any fire left behind to go out, so the next section starts clean.
func _until_out(dir: DisasterDirector) -> void:
	if dir.fire.is_burning():
		dir.fire.douse()
	var n := 0
	while dir.fire.is_burning() and n < 30 * 30:
		await physics_frame
		n += 1


func _save_shot(name: String) -> void:
	if not "--disaster-shot" in OS.get_cmdline_user_args():
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://shots"))
	await RenderingServer.frame_post_draw
	var path := "res://shots/disaster_%s.png" % name
	root.get_texture().get_image().save_png(ProjectSettings.globalize_path(path))
	print("  --   saved %s" % path)


## Fire with no city: a made-up block of PLA, with metal from `metal_from_y` up.
func _fire_world(metal_from_y: int, wet: bool, seed_value := 77) -> Dictionary:
	var f := FireSpread.new()
	var chips := [0]
	f.material_at = func(p: Vector3) -> int:
		var k := FireSpread.key_of(p)
		if absi(k.x) > 5 or absi(k.z) > 5 or k.y < 0 or k.y > 8:
			return -1
		return 11 if k.y >= metal_from_y else 0
	f.chip = func(_p: Vector3, _r: float, _hp: int) -> void: chips[0] += 1
	f.raining = func() -> bool: return wet
	f.setup(seed_value, false)
	var start := Vector3i(0, 1, 0)
	var lit := f.ignite(FireSpread.centre_of(start), 0.6)
	var top := start.y
	var n := 0
	while n < 30 * 120:
		f.tick()
		n += 1
		for c in f.cells:
			top = maxi(top, c.key.y)
		if not f.is_burning():
			break
	var up := 0
	var down := 0
	for k in f._burnt:
		if k.y > start.y:
			up += 1
		elif k.y < start.y:
			down += 1
	var out := {"lit": lit, "peak": f.peak, "caught": f.caught, "capped": f.capped,
			"top": top, "up": up, "down": down, "out": not f.is_burning(),
			"seconds": n / 30.0, "chips": chips[0]}
	f.free()
	return out


func _check_fire_alone() -> void:
	print("fire, alone")
	_ok("metal and stone do not burn; wood burns best",
			FireSpread.flammability(11) == 0.0 and FireSpread.flammability(12) == 0.0
			and FireSpread.flammability(10) == 1.0 and FireSpread.flammability(0) == 0.5
			and FireSpread.flammability(-1) == 0.0)
	var dry := _fire_world(99, false)
	_ok("a spark in PLA catches and spreads", dry.lit and dry.caught > 10,
			"%d cell(s) caught" % dry.caught)
	_ok("it never passes the cap", dry.peak <= FireSpread.MAX_CELLS,
			"peak %d of %d, %d refused at the cap" % [dry.peak, FireSpread.MAX_CELLS, dry.capped])
	_ok("it climbs", dry.up > dry.down and dry.top > 1,
			"%d cell(s) burnt above the spark, %d below; reached storey %d" % [dry.up, dry.down, dry.top])
	_ok("and burns out", dry.out, "%.0f s" % dry.seconds)
	_ok("it wears bricks as it goes", dry.chips > dry.caught, "%d chip(s)" % dry.chips)
	var metal := _fire_world(2, false)
	_ok("a metal storey stops it", metal.top < 2, "top storey reached %d" % metal.top)
	var wet := _fire_world(99, true)
	_ok("rain slows it", wet.caught < dry.caught,
			"%d caught in rain, %d dry" % [wet.caught, dry.caught])


func _check_fire(city: Node3D, dir: DisasterDirector) -> void:
	print("a building catches")
	await _until_out(dir)
	var n0: int = city.authority.commands.size()
	var caught0 := dir.fire.caught
	_ok("a fire starts", dir.start("fire"))
	var bf: BuildingFire = dir.current
	var lit := {}
	var ticks := 0
	var shot := false
	var peak := 0
	while dir.is_running() and ticks < 30 * 120:
		await physics_frame
		ticks += 1
		peak = maxi(peak, dir.fire.count())
		if is_instance_valid(bf) and not bf.lit.is_empty():
			lit = bf.lit
		if not shot and dir.fire.count() >= 12 and not lit.is_empty():
			shot = true
			var at: Vector3 = lit.point
			var out: Vector3 = lit.out
			city.camera.look_at_from_position(at + out * 4.5 + out.cross(Vector3.UP) * 9.0
					+ Vector3.UP * 1.0, at + Vector3.UP * 2.0)
			await _save_shot("fire")
	_ok("a building near the player caught", not lit.is_empty() and int(lit.building) >= 0,
			"%s" % [lit])
	_ok("it spread", peak > BuildingFire.SPARKS,
			"peak %d cell(s), %d caught" % [peak, dir.fire.caught - caught0])
	_ok("under the cap", peak <= FireSpread.MAX_CELLS)
	_ok("and went out, ending the disaster", not dir.is_running() and not dir.fire.is_burning(),
			"%.0f s" % (ticks / 30.0))
	var wait := 0
	while not city._damage_queue.is_empty() and wait < 600:
		await physics_frame
		wait += 1
	var chips := 0
	for i in range(n0, city.authority.commands.size()):
		if city.authority.commands.entries[i].kind == DamageLog.Kind.CHIP:
			chips += 1
	_ok("it wore the building through CHIP commands", chips > 0, "%d CHIP(s)" % chips)


func _check_lightning(city: Node3D, dir: DisasterDirector) -> void:
	print("lightning storm")
	var base: Color = dir.ctx.sky_base().sun_colour
	var n0: int = city.authority.commands.size()
	var caught0 := dir.fire.caught
	_ok("a storm starts", dir.start("lightning"))
	var ls: LightningStorm = dir.current
	var rolled := ls.strikes.size()
	var landed: Array[Dictionary] = ls.landed
	var rained := false
	var dark := Color.WHITE
	var ticks := 0
	var framed := false
	var shot := false
	while dir.is_running() and ticks < 30 * 80:
		await physics_frame
		ticks += 1
		if not is_instance_valid(ls) or ls.phase != Disaster.Phase.ACTIVE:
			continue
		rained = rained or dir.ctx.raining
		dark = (city._sun as DirectionalLight3D).light_color
		if not framed and int(ls.strikes[0].stage) >= 1 and "--disaster-shot" in OS.get_cmdline_user_args():
			framed = true
			ls.hold_bolt = true
			var t: Vector3 = ls.strikes[0].target
			city.camera.look_at_from_position(t + Vector3(-45, 8, -45), t + Vector3(0, 25, 0))
		if framed and not shot and ls._bolt.visible:
			shot = true
			await _ticks(3)
			await _save_shot("lightning")
	_ok("it ends, and the rain with it", not dir.is_running() and not dir.ctx.raining)
	_ok("12 or more strokes over 45 s, every one landed", rolled >= 12 and landed.size() == rolled,
			"%d rolled, %d landed" % [rolled, landed.size()])
	var aimed := 0
	var on_aimed := 0
	var on_building := 0
	var nearest := INF
	for l in landed:
		nearest = minf(nearest, float(l.player_dist))
		if int(l.building) >= 0:
			on_building += 1
		if int(l.aimed) >= 0:
			aimed += 1
			if int(l.aimed) == int(l.building):
				on_aimed += 1
	_ok("a stroke aimed at the tallest nearby lands on it, 70% or more",
			aimed > 0 and on_aimed >= 0.7 * aimed, "%d of %d" % [on_aimed, aimed])
	var wait := 0
	while not city._damage_queue.is_empty() and wait < 600:
		await physics_frame
		wait += 1
	var blasts := 0
	for i in range(n0, city.authority.commands.size()):
		if city.authority.commands.entries[i].kind == DamageLog.Kind.BLAST:
			blasts += 1
	# A blast is committed only when it kills a brick, and a stroke on a corner
	# an earlier stroke already took may find nothing left to kill.
	_ok("the strokes on buildings are committed blasts, most of them",
			on_building > 0 and blasts * 2 >= on_building,
			"%d BLAST(s), %d stroke(s) on buildings" % [blasts, on_building])
	_ok("it rained", rained)
	_ok("the sky darkened, and came back", dark.r < base.r
			and (city._sun as DirectionalLight3D).light_color == base, "sun %s -> %s" % [base, dark])
	print("  --   strokes lit %d fire cell(s); nearest stroke %.0f m from the player" % [
			dir.fire.caught - caught0, nearest])


func _check_pawn(city: Node3D, dir: DisasterDirector) -> void:
	print("a pawn in reach")
	var feet: Vector3 = city.ai_nav.snap(Vector3(0.0, 0.0, -40.0))
	var so: Soldier = city._spawn_soldier(feet)
	var before: float = so.pawn.health.total_current()
	var hurt := dir.ctx.damage_pawns(so.pawn.chest() + Vector3(0.5, 0, 0), LightningStorm.SHOCK_RADIUS,
			LightningStorm.SHOCK_DAMAGE)
	_ok("a stroke beside a soldier hurts it", hurt == 1 and so.pawn.health.total_current() < before,
			"%.0f -> %.0f" % [before, so.pawn.health.total_current()])
	var far := dir.ctx.damage_pawns(so.pawn.chest() + Vector3(10, 0, 0), LightningStorm.SHOCK_RADIUS,
			LightningStorm.SHOCK_DAMAGE)
	_ok("and one 10 m off does not", far == 0)


func _check_tornado(city: Node3D, dir: DisasterDirector) -> void:
	print("tornado")
	await _until_out(dir)
	var ctx := dir.ctx
	# Stand the player in the middle of the city, so the path bends through it,
	# and make some rubble there for it to pick up.
	var bounds := ctx.city_bounds()
	var mid := bounds.get_center()
	var home: Transform3D = city.camera.global_transform
	city.camera.global_position = Vector3(mid.x, 20.0, mid.z)
	var near: Array = []
	for b in city.registry.buildings:
		if not b.toppled:
			var c := CityPlacer.box_of(b).get_center()
			near.append([Vector2(c.x - mid.x, c.z - mid.z).length(), b])
	near.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	for i in mini(3, near.size()):
		var box := CityPlacer.box_of(near[i][1])
		city._blast(Vector3(box.position.x, 3.0, box.get_center().z), 3.2)
		city._blast(Vector3(box.get_center().x, box.end.y - 2.0, box.position.z), 3.2)
	await _ticks(90)
	var feet: Vector3 = city.ai_nav.snap(Vector3(mid.x + 4.0, 0.0, mid.z + 4.0))
	var so: Soldier = city._spawn_soldier(feet)
	var n0: int = city.authority.commands.size()
	var base: Color = ctx.sky_base().sun_colour
	_ok("a tornado starts", dir.start("tornado"))
	var t: Tornado = dir.current
	var evaded := false
	var shoved := false
	var worst := 0.0
	var total := 0.0
	var ticks := 0
	var shot := false
	var stats := {}
	while dir.is_running() and ticks < 30 * 90:
		await physics_frame
		ticks += 1
		var ms := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
		worst = maxf(worst, ms)
		total += ms
		if is_instance_valid(so) and not so.is_dead():
			evaded = evaded or so.state == "evade"
			shoved = shoved or so.pawn.shove.length() > 1.0
		if is_instance_valid(t):
			stats = {"nearest": t.nearest_player, "pulled": t.pieces_pulled.size(),
					"fastest": t.fastest_piece, "chips": t.chips, "shoved": t.pawns_shoved,
					"speed": t.speed, "length": t._along[t._along.size() - 1]}
			if not shot and t.phase == Disaster.Phase.ACTIVE and t.phase_t > 12.0 \
					and "--disaster-shot" in OS.get_cmdline_user_args():
				shot = true
				# A camera of the probe's own: the city's may be walking, and a
				# walking camera falls wherever it is put.
				var side := t.vel.normalized().cross(Vector3.UP)
				var cam := Camera3D.new()
				cam.far = 2000.0
				city.add_child(cam)
				cam.look_at_from_position(t.pos + side * 80.0 + Vector3.UP * 22.0,
						t.pos + Vector3.UP * 22.0)
				cam.make_current()
				await _ticks(3)
				await _save_shot("tornado")
				cam.queue_free()
				city.camera.make_current()
	_ok("it walks across and ends", not dir.is_running(),
			"%.0f m at %.1f m/s, %.0f s" % [stats.length, stats.speed, ticks / 30.0])
	_ok("its path bends past the player", float(stats.nearest) <= 30.0,
			"nearest %.1f m" % stats.nearest)
	_ok("it picks up loose pieces", int(stats.pulled) > 0,
			"%d piece(s), fastest %.1f m/s" % [stats.pulled, stats.fastest])
	_ok("none faster than the debris cap", float(stats.fastest) <= IslandManager.MAX_DEBRIS_SPEED)
	var chips: Array = stats.chips
	var far := 0
	for c in chips:
		var p: Vector3 = c.point
		var a: Vector3 = c.axis
		if Vector2(p.x - a.x, p.z - a.z).length() > 5.0 + 25.0 * 0.25 + 2.0 + 1.0:
			far += 1
	_ok("it strips facades, only inside the funnel", chips.size() > 0 and far == 0,
			"%d chip(s), %d outside" % [chips.size(), far])
	var wait := 0
	while not city._damage_queue.is_empty() and wait < 600:
		await physics_frame
		wait += 1
	var logged := 0
	for i in range(n0, city.authority.commands.size()):
		if city.authority.commands.entries[i].kind == DamageLog.Kind.CHIP:
			logged += 1
	_ok("through CHIP commands", logged > 0, "%d CHIP(s)" % logged)
	var sheared := 0
	for i in range(n0, city.authority.commands.size()):
		if city.authority.commands.entries[i].kind == DamageLog.Kind.SHEAR:
			sheared += 1
	_ok("and tears clumps off whole (SHEAR) for the funnel to throw", sheared > 0,
			"%d SHEAR(s)" % sheared)
	# The soldier runs (D5), usually faster than the funnel walks: shoved only
	# if it is caught. Either is right; standing still in it is not.
	_ok("a soldier near it runs from it", evaded)
	_ok("and is shoved if caught, or gets clear", shoved or evaded,
			"%d pawn-tick(s) shoved" % stats.shoved)
	_ok("sky back, and no hazard left behind", (city._sun as DirectionalLight3D).light_color == base
			and ctx.hazards.is_empty())
	# Nothing it carried is left hanging: give it a few seconds to come down,
	# then no settled piece may have nothing under it and nothing touching it.
	await _ticks(30 * 6)
	var floating := 0
	var settled := 0
	for isl in city.islands.islands:
		if isl.is_valid() and isl.settled:
			settled += 1
			if not city.islands._supported_below(isl) and not city.islands._touching_anything(isl):
				floating += 1
	_ok("nothing it carried is left frozen in mid-air", floating == 0,
			"%d of %d settled piece(s) floating; %d settle(s) refused, %d woken by the watchdog" % [
			floating, settled, city.islands.floating_refused, city.islands.audit_woken])
	print("  --   physics tick during the tornado: mean %.2f ms, worst %.1f ms" % [
			total / maxf(ticks, 1), worst])
	city.camera.global_transform = home


## The wind itself: a shove moves a pawn along it and lifts it, and bleeds off.
func _check_shove(city: Node3D) -> void:
	var feet: Vector3 = city.ai_nav.snap(Vector3(30.0, 0.0, 40.0))
	var so: Soldier = city._spawn_soldier(feet)
	await _ticks(10)
	so.stop()
	var from := so.pawn.feet()
	var rose := 0.0
	for i in 20:
		so.pawn.shove = Vector3(9.0, 3.5, 0.0)
		await physics_frame
		rose = maxf(rose, so.pawn.feet().y - from.y)
	var moved := so.pawn.feet() - from
	_ok("a shove carries a pawn along it and off its feet", moved.x > 2.0 and rose > 0.3,
			"%.1f m along, %.1f m up" % [moved.x, rose])
	await _ticks(30)
	_ok("and bleeds off once the wind stops", so.pawn.shove.length() < 0.5)


func _check_soldiers(city: Node3D, dir: DisasterDirector) -> void:
	print("soldiers react")
	await _until_out(dir)
	var ctx := dir.ctx
	var w: AIWorld = city.ai_world
	var feet: Vector3 = city.ai_nav.snap(Vector3(-20.0, 0.0, 40.0))
	var so: Soldier = city._spawn_soldier(feet)
	await _ticks(10)
	# A meteor's ring on top of it: the same hazard the shower sets.
	ctx.set_hazard(900, AABB(so.pawn.feet() - Vector3(4.0, 1.0, 4.0), Vector3(8.0, 6.0, 8.0)))
	var evaded := false
	var n := 0
	while n < 30 * 8:
		await physics_frame
		n += 1
		evaded = evaded or so.state == "evade"
		if evaded and w.danger_distance(so.pawn.feet()) > 2.0:
			break
	_ok("a soldier in a meteor's ring runs out of it", evaded and w.danger_distance(so.pawn.feet()) > 2.0,
			"%.1f m clear after %.1f s" % [w.danger_distance(so.pawn.feet()), n / 30.0])
	ctx.clear_hazard(900)
	await _ticks(2)
	_ok("and the ring is gone from the AI's world once it lands", not w.in_danger(feet))

	# A fire: burning cells are danger, and its smoke blocks sight.
	var fire_at := Vector3.INF
	for b in city.registry.buildings:
		if not b.toppled:
			var box := CityPlacer.box_of(b)
			fire_at = Vector3(box.position.x + 0.8, box.position.y + FireSpread.CELL.y * 1.5,
					box.get_center().z)
			break
	var lit := ctx.ignite(fire_at, 0.8)
	await _ticks(20)
	var cell := FireSpread.centre_of(FireSpread.key_of(fire_at))
	_ok("a burning cell is somewhere not to stand", lit and w.in_danger(cell))
	var smoky := false
	for spot in dir.fire.smoke_spots:
		var c: Vector3 = spot[0]
		smoky = smoky or w.smoke_blocks(c + Vector3(-20, 0, 0), c + Vector3(20, 0, 0))
	_ok("and its smoke blocks a soldier's sight", smoky, "%d smoke column(s)" % dir.fire.smoke_spots.size())
	await _until_out(dir)
	await _ticks(20)
	_ok("once out, neither is left", not w.in_danger(cell) and dir.fire.smoke_spots.is_empty())


## Lightning and fire go for bricks that exist, not for the recipe's box.
func _check_real_bricks(city: Node3D, dir: DisasterDirector) -> void:
	print("real bricks, not the recipe")
	await _until_out(dir)
	var ctx := dir.ctx
	# The tallest building, its top half blown away.
	var tall_id := -1
	var tall_box := AABB()
	for pair in ctx.buildings():
		var box: AABB = pair[1]
		if box.size.y > tall_box.size.y:
			tall_box = box
			tall_id = int(pair[0])
	var cut := tall_box.position.y + tall_box.size.y * 0.5
	var y := tall_box.end.y - 1.0
	while y > cut:
		var x := tall_box.position.x + 1.0
		while x < tall_box.end.x:
			var z := tall_box.position.z + 1.0
			while z < tall_box.end.z:
				city._blast(Vector3(x, y, z), 3.2)
				z += 4.0
			x += 4.0
		y -= 4.0
	var wait := 0
	while not city._damage_queue.is_empty() and wait < 30 * 30:
		await physics_frame
		wait += 1
	await _ticks(60)
	var b = city.registry.get_building(tall_id)
	if b == null or b.toppled:
		_ok("the tall building still stands, cut down", false, "it toppled -- pick another")
		return
	var top := ctx.top_of(tall_box)
	var top_y: float = (top.position as Vector3).y if not top.is_empty() else -INF
	_ok("its top is where its bricks now end, not its recipe's roof",
			not top.is_empty() and top_y < tall_box.end.y - 3.0,
			"%.1f m, roof was %.1f m" % [top_y, tall_box.end.y])
	var c := tall_box.get_center()
	var near := ctx.tallest_near(c, 2.0)
	_ok("and that is what lightning aims at", not near.is_empty() and int(near.building) == tall_id
			and absf((near.top as Vector3).y - top_y) < 0.01)
	var hit_y := top_y
	var landed := ctx.ray(Vector3(c.x, tall_box.end.y + 60.0, c.z), Vector3(c.x, -50.0, c.z))
	_ok("a stroke from above comes down on something real", not landed.is_empty(),
			"at %.1f m" % ((landed.position as Vector3).y if not landed.is_empty() else -INF))
	var air := Vector3(c.x, tall_box.end.y - 1.0, c.z)
	_ok("where the roof was is air to fire (was PLA)", ctx.material_at(air) == -1,
			"material %d" % ctx.material_at(air))
	_ok("and the bricks still standing are not", ctx.material_at(
			(top.position as Vector3) + Vector3.DOWN * 0.1) >= 0 if not top.is_empty() else false)
	var caught_air := ctx.ignite(air + Vector3.UP * 2.0, 0.8) or ctx.ignite(air, 0.8)
	var why := ""
	for cell in dir.fire.cells:
		var cc := FireSpread.centre_of(cell.key)
		var h := FireSpread.CELL * 0.5
		for off in [Vector3.ZERO, Vector3(0, -h.y + 0.1, 0), Vector3(h.x - 0.2, 0, 0),
				Vector3(-h.x + 0.2, 0, 0), Vector3(0, 0, h.z - 0.2), Vector3(0, 0, -h.z + 0.2)]:
			var bk: Dictionary = city._material_fx.brick_at(cc + off)
			if not bk.is_empty():
				why += " %v -> %s (building %d);" % [cc + off, bk, ctx.building_at(cc + off, 0.0)]
	_ok("so fire will not catch in the air", not caught_air,
			"%d burning:%s" % [dir.fire.count(), why])
	await _until_out(dir)


func _check_intensity(dir: DisasterDirector) -> void:
	print("intensity")
	var low := MeteorShower.new()
	low.intensity = 0.5
	low.begin(dir.ctx, 99)
	var mid := MeteorShower.new()
	mid.begin(dir.ctx, 99)
	var high := MeteorShower.new()
	high.intensity = 2.5
	high.begin(dir.ctx, 99)
	_ok("more intensity, more meteors", low.meteors.size() < mid.meteors.size()
			and mid.meteors.size() < high.meteors.size(),
			"%d / %d / %d at Low / Medium / Extreme" % [low.meteors.size(), mid.meteors.size(),
			high.meteors.size()])
	var r_mid := 0.0
	var r_high := 0.0
	for m in mid.meteors:
		r_mid += float(m.radius) / mid.meteors.size()
	for m in high.meteors:
		r_high += float(m.radius) / high.meteors.size()
	_ok("and bigger", r_high > r_mid, "mean radius %.1f -> %.1f m" % [r_mid, r_high])
	low.free()
	mid.free()
	high.free()
	_ok("the names", DisasterDirector.intensity_name(1.0) == "Medium"
			and DisasterDirector.intensity_name(2.5) == "Extreme")


func _check_quake(city: Node3D, dir: DisasterDirector) -> void:
	print("earthquake")
	await _until_out(dir)
	# Who would fail, by intensity -- the plan alone, nothing shaken.
	var sizes := []
	for k in [0.5, 1.0, 2.5]:
		var q := Earthquake.new()
		q.intensity = k
		q.begin(dir.ctx, 4242)
		q._plan()
		sizes.append(q.plan.size())
		q.free()
	_ok("more intensity, more buildings fail", sizes[0] <= sizes[1] and sizes[1] <= sizes[2]
			and sizes[2] > 0, "%s at Low / Medium / Extreme" % [sizes])

	# The caps: one at a time, three in all, at Extreme.
	var n0: int = city.authority.commands.size()
	_ok("a quake starts", dir.start("earthquake", 2.5,
			{"max_collapse_at_once": 1, "max_collapse_total": 3}))
	var q: Earthquake = dir.current
	var worst := 0.0
	var total := 0.0
	var ticks := 0
	var over := false
	var stats := {}
	var shot := false
	while dir.is_running() and ticks < 30 * 90:
		await physics_frame
		ticks += 1
		var ms := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
		worst = maxf(worst, ms)
		total += ms
		if is_instance_valid(q):
			over = over or q.active_collapses() > q.max_collapse_at_once
			var toppled := 0
			var went_over := 0
			var survived := 0
			var tilts := []
			for c in q.collapses:
				toppled += 1 if c.toppled else 0
				went_over += 1 if c.tilt >= 10.0 else 0
				survived += 1 if c.survived else 0
				tilts.append("%d deg, %d blasts" % [int(c.tilt), int(c.blasts)])
			stats = {"collapses": q.collapses.size(), "peak": q.peak_at_once, "held": q.held,
					"dropped": q.dropped, "chips": q.facade_chips, "shears": q.facade_shears,
					"toppled": toppled, "over": went_over, "survived": survived, "plan": q.plan.size(),
					"tilts": tilts}
			if not shot and q.collapses.size() > 0 and "--disaster-shot" in OS.get_cmdline_user_args():
				var c: Dictionary = q.collapses[0]
				if c.toppled:
					shot = true
					var box: AABB = c.box
					var cam := Camera3D.new()
					cam.far = 2000.0
					city.add_child(cam)
					var d: Vector3 = c.dir
					cam.look_at_from_position(box.get_center() + d.cross(Vector3.UP) * 70.0 - d * 20.0
							+ Vector3.UP * 40.0, box.get_center() + Vector3.UP * 4.0)
					cam.make_current()
					await _ticks(75)
					await _save_shot("earthquake")
					cam.queue_free()
					city.camera.make_current()
	_ok("it ends", not dir.is_running(), "%.0f s" % (ticks / 30.0))
	_ok("buildings fail", int(stats.collapses) > 0, "%s" % [stats])
	_ok("never more than the cap at once", not over and int(stats.peak) <= 1,
			"peak %d" % stats.peak)
	_ok("never more than the cap in all", int(stats.collapses) <= 3)
	_ok("undermined, most of them topple", int(stats.toppled) * 2 >= int(stats.collapses),
			"%d of %d toppled, %d survived" % [stats.toppled, stats.collapses, stats.survived])
	_ok("and go over (more than 10 degrees off upright; most come to rest leaning)",
			int(stats.over) >= int(stats.toppled) and int(stats.over) > 0,
			"%s" % [stats.tilts])
	_ok("facades shed bricks", int(stats.chips) + int(stats.shears) > 0,
			"%d chip(s), %d clump(s)" % [stats.chips, stats.shears])
	var wait := 0
	while not city._damage_queue.is_empty() and wait < 600:
		await physics_frame
		wait += 1
	var kinds := {}
	for i in range(n0, city.authority.commands.size()):
		var k: int = city.authority.commands.entries[i].kind
		kinds[k] = int(kinds.get(k, 0)) + 1
	_ok("the failures are blasts and topples through the authority",
			int(kinds.get(DamageLog.Kind.BLAST, 0)) > 0 and int(kinds.get(DamageLog.Kind.TOPPLE, 0)) > 0,
			"%d BLAST, %d TOPPLE" % [kinds.get(DamageLog.Kind.BLAST, 0), kinds.get(DamageLog.Kind.TOPPLE, 0)])
	_ok("no hazard left behind", dir.ctx.hazards.is_empty())
	print("  --   physics tick during the quake: mean %.2f ms, worst %.1f ms" % [
			total / maxf(ticks, 1), worst])

	# Zero at once: it shakes, and nothing falls.
	var n1: int = city.authority.commands.size()
	dir.start("earthquake", 2.5, {"max_collapse_at_once": 0, "max_collapse_total": 5})
	var q0: Earthquake = dir.current
	var worst0 := 0.0
	var total0 := 0.0
	for i in 30 * 12:
		await physics_frame
		var ms := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
		worst0 = maxf(worst0, ms)
		total0 += ms
	var none: bool = q0.collapses.is_empty()
	print("  --   shaking alone, no collapses, 12 s: mean %.2f ms, worst %.1f ms; %d chip(s), %d clump(s)" % [
			total0 / (30 * 12), worst0, q0.facade_chips, q0.facade_shears])
	dir.stop()
	await _until_over(dir)
	var topples0 := 0
	for i in range(n1, city.authority.commands.size()):
		if city.authority.commands.entries[i].kind == DamageLog.Kind.TOPPLE:
			topples0 += 1
	_ok("with 0 at once, nothing collapses", none and topples0 == 0)


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
