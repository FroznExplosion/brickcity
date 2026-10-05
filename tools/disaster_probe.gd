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
##     ... -- --only=meteor,lightning,fire,pawn,soldiers,tornado,real,intensity,quake,acid,char,coop,hurricane,snow,multi,hail,giant

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
	if only == "" or "acid" in only:
		await _check_acid(city, dir)
	if only == "" or "char" in only:
		await _check_char(city, dir)
	if only == "" or "coop" in only:
		await _check_coop(city, dir)
	if only == "" or "hurricane" in only:
		await _check_city_hurricane(city, dir)
	if only == "" or "snow" in only:
		await _check_city_snow(city, dir)
	if only == "" or "multi" in only:
		await _check_multi(city, dir)
	if only == "" or "hail" in only:
		await _check_hail(city, dir)
	if only == "" or "giant" in only:
		await _check_giant(city, dir)
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
					"speed": t.speed, "length": t._along[t._along.size() - 1],
					"pushed": t.pushed.size(), "cap": maxi(1, int(round(Tornado.MAX_PUSHED * t.intensity)))}
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
	var seams := 0
	for i in range(n0, city.authority.commands.size()):
		var e: DamageLog.Entry = city.authority.commands.entries[i]
		if e.kind == DamageLog.Kind.SEVER and e.flags & DamageLog.FLAG_SEAM:
			seams += 1
	_ok("the buildings it pushes over are cut where their joints give (a SEVER seam each), to its cap",
			seams == int(stats.pushed) and int(stats.pushed) <= int(stats.cap),
			"%d pushed over, %d seam(s), cap %d" % [stats.pushed, seams, stats.cap])
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
	dir.ctx.forget(null)
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
	dir.ctx.forget(null)
	_ok("more intensity, more buildings fail", sizes[0] <= sizes[1] and sizes[1] <= sizes[2]
			and sizes[2] > 0, "%s at Low / Medium / Extreme" % [sizes])

	# The sideways load (BrickWorld.lateral_check): slender fails before squat.
	var tall = null
	var squat = null
	for b in city.registry.buildings:
		if b.toppled or b.is_build() or b.is_damaged():
			continue
		var h := CityPlacer.box_of(b).size.y
		if tall == null or h > CityPlacer.box_of(tall).size.y:
			tall = b
		if squat == null or h < CityPlacer.box_of(squat).size.y:
			squat = b
	for b in [tall, squat]:
		if b != null and b.chunk < 0:
			city._promote(b.id)
	var rt := dir.ctx.lateral(tall.id, 0.6, Vector3.RIGHT) if tall != null else {}
	var rs := dir.ctx.lateral(squat.id, 0.6, Vector3.RIGHT) if squat != null else {}
	_ok("at 0.6 g the tallest tower fails and the squattest block holds",
			not rt.is_empty() and not rs.is_empty() and float(rt.ratio) >= 1.0 and float(rs.ratio) < 1.0,
			"%.2f / %.2f" % [float(rt.get("ratio", 0.0)), float(rs.get("ratio", 0.0))])
	_ok("and it fails above its foundation, low down", not rt.is_empty() and rt.has("level")
			and (rt.level as Vector3).y > CityPlacer.box_of(tall).position.y + 0.5
			and (rt.level as Vector3).y < CityPlacer.box_of(tall).get_center().y,
			"at %.1f m" % [(rt.get("level", Vector3.ZERO) as Vector3).y])

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
			var lateral := 0
			var tilts := []
			for c in q.collapses:
				lateral += 1 if c.lateral else 0
				toppled += 1 if c.toppled else 0
				went_over += 1 if c.tilt >= 10.0 else 0
				survived += 1 if c.survived else 0
				tilts.append("%d deg, %d blasts" % [int(c.tilt), int(c.blasts)])
			stats = {"collapses": q.collapses.size(), "peak": q.peak_at_once, "held": q.held,
					"dropped": q.dropped, "chips": q.facade_chips, "shears": q.facade_shears,
					"toppled": toppled, "over": went_over, "survived": survived, "plan": q.plan.size(),
					"tilts": tilts, "lateral": lateral, "checks": q.lateral_checks}
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
	_ok("buildings near fail where their joints do (the solver), far ones by roll",
			int(stats.lateral) > 0, "%d of %d by the solver, %d check(s)" % [stats.lateral,
			stats.collapses, stats.checks])
	_ok("cut or undermined, most of them topple", int(stats.toppled) * 2 >= int(stats.collapses),
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
	var seams := 0
	for i in range(n0, city.authority.commands.size()):
		var e: DamageLog.Entry = city.authority.commands.entries[i]
		if e.kind == DamageLog.Kind.SEVER and e.flags & DamageLog.FLAG_SEAM:
			seams += 1
	var undermined := int(stats.collapses) - int(stats.lateral)
	_ok("the failures go through the authority: a SEVER seam per cut, blasts and topples per undermining",
			seams == int(stats.lateral) and (undermined == 0
			or (int(kinds.get(DamageLog.Kind.BLAST, 0)) > 0 and int(kinds.get(DamageLog.Kind.TOPPLE, 0)) > 0)),
			"%d seam(s), %d BLAST, %d TOPPLE" % [seams, kinds.get(DamageLog.Kind.BLAST, 0),
			kinds.get(DamageLog.Kind.TOPPLE, 0)])
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
		var e: DamageLog.Entry = city.authority.commands.entries[i]
		if e.kind == DamageLog.Kind.TOPPLE or (e.kind == DamageLog.Kind.SEVER and e.flags & DamageLog.FLAG_SEAM):
			topples0 += 1
	_ok("with 0 at once, nothing collapses", none and topples0 == 0)


## Acid rain (Docs/Disasters.md 14): it wears plastic, as committed CHIPs,
## leaves metal and stone alone, and burns whoever is out in it.
func _check_acid(city: Node3D, dir: DisasterDirector) -> void:
	print("acid rain")
	_ok("acid minds PLA most, nylon less, metal and stone not at all",
			AcidRain.susceptibility(0) == 1.0 and AcidRain.susceptibility(6) < 0.5
			and AcidRain.susceptibility(11) == 0.0 and AcidRain.susceptibility(12) == 0.0)
	var s: AIServices = city.ai_services
	var feet: Vector3 = city.ai_nav.snap(Vector3(0.0, 0.0, -40.0))
	var so: Soldier = city._spawn_soldier(feet)
	so.brain.active = false   # stay out in it
	await _ticks(5)
	var open_sky := not BTShelter.covered(s, so.pawn.feet())
	var before: float = so.pawn.health.total_current()
	var n0: int = city.authority.commands.size()
	_ok("acid rain starts", dir.start("acid"))
	var ar: AcidRain = dir.current
	var stormy := false
	var sight := 1.0
	var aim := 1.0
	var screen := 0.0
	var ticks := 0
	var got := [0, 0, 0, 0]   # drops, worn, spared, burnt: the rain is freed when done
	while dir.is_running() and ticks < 30 * 70:
		await physics_frame
		ticks += 1
		if is_instance_valid(ar):
			got = [ar.drops, ar.worn, ar.spared, ar.burnt]
		if is_instance_valid(ar) and ar.phase == Disaster.Phase.ACTIVE:
			stormy = stormy or s.storm
			sight = minf(sight, s.sight_mul)
			aim = maxf(aim, s.aim_mul)
			if dir.ctx.screen != null:
				screen = maxf(screen, float(dir.ctx.screen.get_shader_parameter("rain")))
	var wait := 0
	while not city._damage_queue.is_empty() and wait < 600:
		await physics_frame
		wait += 1
	var chips := 0
	for i in range(n0, city.authority.commands.size()):
		if city.authority.commands.entries[i].kind == DamageLog.Kind.CHIP:
			chips += 1
	_ok("drops fell, and wore bricks", got[0] > 100 and got[1] > 20,
			"%d drop(s), %d wore a brick, %d on metal or stone" % [got[0], got[1], got[2]])
	_ok("the wear is committed CHIPs", chips >= got[1], "%d CHIP(s)" % chips)
	_ok("a soldier out in it is burnt", open_sky and got[3] > 0
			and so.pawn.health.total_current() < before,
			"%.0f -> %.0f" % [before, so.pawn.health.total_current()])
	_ok("the AI shelters, sees a little less and aims a lot worse",
			stormy and sight < 1.0 and sight >= 0.85 and aim > 1.2, "sight %.2f, aim %.2f" % [sight, aim])
	var lens := dir.ctx.screen
	_ok("the lens streaks", lens != null and screen > 0.5)
	_ok("and it all clears", not dir.is_running() and not s.storm and s.sight_mul == 1.0
			and s.aim_mul == 1.0 and not dir.ctx.raining
			and (lens == null or float(lens.get_shader_parameter("rain")) == 0.0))


## Charred bricks and burning debris (Docs/Disasters.md 15): fire blackens
## what it burns, as committed SCORCH commands the building keeps across being
## handed back; a piece that breaks off a burning building carries the fire.
func _check_char(city: Node3D, dir: DisasterDirector) -> void:
	print("charred bricks, burning debris")
	await _until_out(dir)
	# A wall no fire has been at: earlier sections burn and char the city, and
	# a burnt-out cell never catches again. Undamaged buildings first.
	var b: BuildingRegistry.Building = null
	var wall := Vector3.INF
	var order: Array = []
	for c in city.registry.buildings:
		if not c.toppled:
			order.append(c)
	order.sort_custom(func(x, y) -> bool: return not x.is_damaged() and y.is_damaged())
	for c in order:
		var cbox := CityPlacer.box_of(c)
		# Collision is only streamed in near the camera, and material_at needs it.
		city.camera.global_position = Vector3(cbox.position.x - 15.0, cbox.position.y + 6.0,
				cbox.get_center().z)
		if c.chunk < 0:
			city._promote(c.id)
		await _ticks(15)
		if c.chunk < 0:
			continue
		for k in range(1, 6):
			var y := cbox.position.y + 1.3 + FireSpread.CELL.y * k
			if y > cbox.end.y - 3.0:
				break
			# In from the -x side, to the first brick of this building.
			var from := Vector3(cbox.position.x - 4.0, y, cbox.get_center().z + 0.4)
			var hit := dir.ctx.ray(from, Vector3(cbox.get_center().x, y, from.z))
			if hit.is_empty() or hit.has("building") or dir.ctx.building_at(hit.position, 0.3) != c.id:
				continue
			var at: Vector3 = (hit.position as Vector3) + Vector3(0.2, 0.0, 0.0)
			var ok := dir.ctx.material_at(at) >= 0
			for q in [at]:
				ok = ok and not dir.fire._burnt.has(FireSpread.key_of(q)) and not dir.fire._by_key.has(FireSpread.key_of(q))
			if ok:
				wall = at
				break
		if wall != Vector3.INF:
			b = c
			break
	_ok("a standing building with its bricks in", b != null and b.chunk >= 0)
	if b == null:
		return
	var box := CityPlacer.box_of(b)
	var world: BrickWorld = city.world
	var n0: int = city.authority.commands.size()
	var before := world.get_scorched_blocks(b.chunk).size()
	var got := dir.ctx.scorch(wall, 1.0)
	var after := world.get_scorched_blocks(b.chunk).size()
	var scorches := 0
	for i in range(n0, city.authority.commands.size()):
		if city.authority.commands.entries[i].kind == DamageLog.Kind.SCORCH:
			scorches += 1
	_ok("a scorch blackens bricks, as a committed SCORCH", got > 0 and after > before and scorches == got,
			"%d -> %d scorched, %d SCORCH" % [before, after, scorches])
	var again := dir.ctx.scorch(wall, 1.0)
	_ok("and scorching them twice changes nothing, and says nothing", again == 0)
	city.registry._record_damage(b)
	_ok("the building keeps it for when its bricks come back", b.scorched_in(0).size() == after)
	if "--disaster-shot" in OS.get_cmdline_user_args():
		dir.ctx.scorch(wall + Vector3(0.0, 1.5, 1.5), 1.6)
		city.camera.look_at_from_position(wall + Vector3(-9.0, 2.0, 1.0), wall + Vector3(0.0, 1.0, 0.8))
		await _ticks(90)   # the recolour: a full rebuild of the bands, a few a tick
		await _save_shot("char")

	# A fire chars as it takes hold.
	var s0 := dir.fire.scorches
	dir.ctx.ignite(wall, 0.8)
	var t := 0
	while dir.fire.scorches == s0 and t < 30 * 10:
		await physics_frame
		t += 1
	_ok("a burning cell chars its walls", dir.fire.scorches > s0, "after %.1f s" % [t / 30.0])

	# A clump knocked off the burning wall takes the fire with it.
	var caught0 := dir.debris.caught
	var lit_at := wall
	# Cut the storey under the fire right through: what is above comes away
	# as pieces, the burning wall with them.
	var cut_y := lit_at.y - 1.2
	var fx := box.position.x
	while fx <= box.end.x:
		var fz := box.position.z
		while fz <= box.end.z:
			dir.ctx.blast(Vector3(fx, cut_y, fz), 1.3)
			fz += 1.6
		fx += 1.6
	t = 0
	while dir.debris.caught == caught0 and t < 30 * 8:
		await physics_frame
		t += 1
	_ok("a piece off a burning building catches", dir.debris.caught > caught0,
			"%d piece(s) burning; %d piece(s) now, near: %d" % [dir.debris.count(),
			city.islands.islands.size(), dir.ctx.islands_near(lit_at, 5.0).size()])
	# That piece burns out; others off the same fire may still be catching.
	var first: BrickIsland = dir.debris._burning.keys()[0] if dir.debris.count() > 0 else null
	t = 0
	while first != null and dir.debris.is_burning(first) and t < 30 * 20:
		await physics_frame
		t += 1
	_ok("and burns out", first != null and not dir.debris.is_burning(first),
			"%.0f s; %d lit where it landed, %d caught in all" % [
			t / 30.0, dir.debris.landed_lit, dir.debris.caught - caught0])
	dir.debris.douse()
	await _until_out(dir)


## Co-op (Docs/Disasters.md 16): the host sends a start, a client plays the
## same disaster from the same seed, caught up to the host's tick, and changes
## nothing itself. A second director in the same city stands in for the client;
## the "wire" is two arrays, as in the loopback probe.
func _check_coop(city: Node3D, dir: DisasterDirector) -> void:
	print("co-op")
	await _until_out(dir)
	var cd := DisasterDirector.new()
	cd.name = "ClientDisasters"
	city.add_child(cd)
	cd.setup(city)
	var up: Array = []     # client -> host
	var down: Array = []   # host -> client
	cd.set_client(func(m: Array) -> void: up.append(m))
	dir.add_client(func(m: Array) -> void: down.append(m))

	_ok("the host sends a start", dir.start("meteor", 1.0) and down.size() == 1
			and down[0][0] == "start" and down[0][1] == "meteor", str(down))
	await _ticks(30 * 9)   # joins late: the shower is well under way
	cd.receive(down[0])
	var h: Disaster = dir.current
	var c: Disaster = cd.current
	_ok("the client plays the same disaster, caught up to the host's tick",
			c != null and c.phase == h.phase and absf(c.phase_t - h.phase_t) < 0.05
			and c.rng.state == h.rng.state,
			"host %s %.2f s, client %s %.2f s" % [Disaster.phase_name(h.phase), h.phase_t,
			Disaster.phase_name(c.phase) if c != null else "-", c.phase_t if c != null else 0.0])
	var late: Array = []
	dir.add_client(func(m: Array) -> void: late.append(m))
	_ok("a client joining mid-way is sent the running one", late.size() == 1 and late[0][0] == "start")

	var feet: Vector3 = city.ai_nav.snap(Vector3(0.0, 0.0, -40.0))
	var so: Soldier = city._spawn_soldier(feet)
	so.brain.active = false
	await _ticks(2)
	# Measured round the client's calls alone: the host's meteors land meanwhile.
	var q0: int = city._damage_queue.size()
	var n0: int = city.authority.commands.size()
	var wall := CityPlacer.box_of(city.registry.buildings[0]).get_center()
	cd.ctx.blast(wall, 2.0)
	cd.ctx.chip(wall, 1.0, 100)
	var lit := cd.ctx.ignite(wall, 1.0)
	var charred := cd.ctx.scorch(wall, 1.0)
	var hurt := cd.ctx.damage_pawns(so.pawn.chest(), 2.0, 50.0)
	_ok("and changes nothing itself: no blast, chip, fire, char or wound",
			city._damage_queue.size() == q0 and city.authority.commands.size() == n0
			and not lit and charred == 0 and hurt == 0)

	dir.stop()
	_ok("the host's stop reaches the client", down.size() == 2 and down[1][0] == "stop")
	cd.receive(down[1])
	_ok("and ends its disaster too", cd.current != null and cd.current.phase == Disaster.Phase.ENDING)
	var t := 0
	while (dir.is_running() or cd.is_running()) and t < 30 * 30:
		await physics_frame
		t += 1
	_ok("both are over", not dir.is_running() and not cd.is_running())

	# The client asks; the host decides and tells it.
	var d0 := down.size()
	_ok("a client's request goes to the host", cd.start("lightning", 1.6) and up.size() == 1
			and up[0][0] == "request" and not cd.is_running())
	dir.receive(up[0])
	_ok("the host starts it and sends the start back", dir.current_kind == "lightning"
			and down.size() == d0 + 1 and down[d0][1] == "lightning" and float(down[d0][4]) == 1.6)
	cd.receive(down[d0])
	_ok("the client plays it, at the intensity asked", cd.current_kind == "lightning"
			and is_equal_approx(cd.current.intensity, 1.6))
	cd.stop()
	dir.receive(up[up.size() - 1])
	cd.receive(down[down.size() - 1])
	_ok("its stop request stops the host's, and so its own",
			dir.current != null and dir.current.phase == Disaster.Phase.ENDING
			and cd.current != null and cd.current.phase == Disaster.Phase.ENDING)
	t = 0
	while (dir.is_running() or cd.is_running()) and t < 30 * 30:
		await physics_frame
		t += 1
	city.remove_child(cd)
	cd.free()
	await _until_out(dir)


## The hurricane in the city (Docs/Disasters.md 18): the city offers it; the
## wind leans on loose pieces and puts a sideways load on buildings -- any it
## blows over is a SEVER seam, to its cap; everything gets wet and sways; and
## it all clears.
func _check_city_hurricane(city: Node3D, dir: DisasterDirector) -> void:
	print("hurricane in the city")
	await _until_out(dir)
	_ok("the city offers a hurricane", dir.roll.has("hurricane"))
	# The tallest standing tower, its bricks in, the camera beside it: what the
	# wind can put over is what is near the player.
	var tall = null
	for b in city.registry.buildings:
		if not b.toppled and not b.is_build() and (tall == null
				or CityPlacer.box_of(b).size.y > CityPlacer.box_of(tall).size.y):
			tall = b
	var tbox := CityPlacer.box_of(tall)
	city.camera.global_position = tbox.get_center() + Vector3(-tbox.size.x - 20.0, 0.0, 0.0)
	if tall.chunk < 0:
		city._promote(tall.id)
	await _ticks(10)
	var n0: int = city.authority.commands.size()
	_ok("a hurricane starts", dir.start("hurricane", 2.5))
	var h: Hurricane = dir.current
	var cap := maxi(1, int(round(Hurricane.MAX_PUSHED * 2.5)))
	var pushed := 0
	var pieces := 0
	var tilt := 0.0
	var soak := 0.0
	var gale := 0.0
	var t := 0
	while dir.is_running() and t < 30 * 130:
		await physics_frame
		t += 1
		if is_instance_valid(h):
			pushed = h.pushed_buildings.size()
			pieces = h.pieces_pushed
			tilt = h.peak_tilt
		soak = maxf(soak, dir.ctx.wet)
		gale = maxf(gale, dir.ctx.gale.length())
	await _ticks(6)
	var seams := 0
	for i in range(n0, city.authority.commands.size()):
		var e: DamageLog.Entry = city.authority.commands.entries[i]
		if e.kind == DamageLog.Kind.SEVER and e.flags & DamageLog.FLAG_SEAM:
			seams += 1
	_ok("it runs its course", not dir.is_running(), "%.0f s" % (t / 30.0))
	_ok("at Extreme it blows the tallest tower over, cut where its joints give, to its cap",
			pushed > 0 and seams == pushed and pushed <= cap, "%d blown over, %d seam(s), cap %d" % [pushed, seams, cap])
	_ok("and its top goes over downwind", tilt > 10.0, "%.0f degrees" % tilt)
	print("  --   %d push(es) to loose pieces" % pieces)
	_ok("the city gets wet, sways, and the wind stops after", soak > 0.9 and gale > 0.5
			and dir.ctx.gale == Vector3.ZERO and dir.ctx.wet > 0.5,
			"wet %.2f, gale %.2f" % [soak, gale])
	await _until_out(dir)


## Snow on a building (Docs/Disasters.md 21): tiles on its tops open to the
## sky, none on the floors under its roof -- until a hole in the roof lets the
## snow onto the floor below.
func _check_city_snow(city: Node3D, dir: DisasterDirector) -> void:
	print("snow on the city")
	await _until_out(dir)
	_ok("the city offers a snowfall", dir.roll.has("snow"))
	# A tower with its roof still on -- earlier sections cut the tops off some
	# -- undamaged first, tallest first; its bricks in, the camera by it.
	var order: Array = []
	for c in city.registry.buildings:
		if not c.toppled and not c.is_build() and not city._is_tree(c.id):
			order.append(c)
	order.sort_custom(func(x, y) -> bool:
		if x.is_damaged() != y.is_damaged():
			return not x.is_damaged()
		return CityPlacer.box_of(x).size.y > CityPlacer.box_of(y).size.y)
	var b = null
	var box := AABB()
	for c in order:
		var cbox := CityPlacer.box_of(c)
		city.camera.global_position = cbox.get_center() + Vector3(-cbox.size.x - 15.0, 0.0, 0.0)
		if c.chunk < 0:
			city._promote(c.id)
		await _ticks(10)
		var top := dir.ctx.top_of(cbox)
		if not top.is_empty() and (top.position as Vector3).y > cbox.end.y - 3.0:
			b = c
			box = cbox
			break
	_ok("a tower with its roof on", b != null)
	if b == null:
		return
	_ok("a snowfall starts", dir.start("snow", 2.5))
	var t := 0
	var cover: SnowCover = null
	while t < 30 * 40:
		await physics_frame
		t += 1
		cover = dir.ctx.snow_cover
		if cover != null and cover.covers.has(b.id) and cover.covers[b.id].node != null \
				and dir.ctx.snow > 0.8:
			break
	var tops := _snow_tops(cover, b.id)
	_ok("snow lies on the building", tops.size() > 0, "%d tile top(s)" % tops.size())
	if "--disaster-shot" in OS.get_cmdline_user_args():
		var cam := Camera3D.new()
		cam.far = 2000.0
		city.add_child(cam)
		cam.look_at_from_position(box.get_center() + Vector3(-28.0, box.size.y * 0.5 + 12.0, -22.0),
				box.get_center() + Vector3(0.0, box.size.y * 0.35, 0.0))
		cam.make_current()
		await _ticks(40)
		await _save_shot("snow_city")
		cam.queue_free()
		city.camera.make_current()
	var highest := -INF
	for p in tops:
		highest = maxf(highest, (p as Vector3).y)
	_ok("on its roof: open to the sky, nothing under the roof",
			highest > box.end.y - 2.0, "highest %.1f m, the box's top %.1f m" % [highest, box.end.y])
	# A hole through the roof: the floor below is open to the sky now.
	var roof := Vector3(box.get_center().x, box.end.y - 0.5, box.get_center().z)
	var before := _snow_height_at(cover, b.id, roof)
	for k in 3:
		dir.ctx.blast(roof + Vector3(0.0, -1.2 * k, 0.0), 2.2)
	var builds0: int = cover.cover_builds
	t = 0
	while t < 30 * 8 and cover.cover_builds == builds0:
		await physics_frame
		t += 1
	await _ticks(10)
	var after := _snow_height_at(cover, b.id, roof)
	_ok("a hole in the roof lets it onto the floor below", cover.cover_builds > builds0
			and after < before - 1.0,
			"snow over the roof's middle at %.1f m, then %.1f m" % [before, after])
	dir.stop()
	await _until_over(dir)
	dir.ctx.snow = 0.0005
	await _ticks(10)
	_ok("and it all goes once melted", dir.ctx.snow_cover == null)


## The world points of the tops of a building's snow tiles.
func _snow_tops(cover: SnowCover, id: int) -> Array:
	var out := []
	if cover == null or not cover.covers.has(id) or cover.covers[id].node == null:
		return out
	var mi: MeshInstance3D = cover.covers[id].node
	if not is_instance_valid(mi):
		return out
	var arrays: Array = mi.mesh.surface_get_arrays(0)
	var vs: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var cs: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	var xf := mi.global_transform
	for i in vs.size():
		if cs[i].r > 0.5:
			out.append(xf * vs[i])
	return out


## How high the building's snow lies over `at` (its XZ): each box's first
## four vertices are its top (BrickWorld.build_snow_cover). -INF for none.
func _snow_height_at(cover: SnowCover, id: int, at: Vector3) -> float:
	if cover == null or not cover.covers.has(id) or cover.covers[id].node == null:
		return -INF
	var mi: MeshInstance3D = cover.covers[id].node
	if not is_instance_valid(mi):
		return -INF
	var vs: PackedVector3Array = mi.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var xf := mi.global_transform
	var best := -INF
	for i in range(0, vs.size() - 3, 20):
		var a := xf * vs[i]
		var c := xf * vs[i + 2]
		if at.x >= minf(a.x, c.x) and at.x <= maxf(a.x, c.x) and at.z >= minf(a.z, c.z) \
				and at.z <= maxf(a.z, c.z):
			best = maxf(best, a.y)
	return best


## Several at once (Docs/Disasters.md 22): a combo starts each of its kinds,
## each on its own seed; their hazards do not overwrite each other; the winds
## add; a client joining mid-way is sent every start; stop ends them all; and
## when the last has gone the sky, the AI's weather, the lens, the storm and
## the hazards are all as they were.
func _check_multi(city: Node3D, dir: DisasterDirector) -> void:
	print("several at once")
	await _until_out(dir)
	var ctx := dir.ctx
	var base: Color = ctx.sky_base().sun_colour
	_ok("the city offers combos", dir.combos().has("outbreak") and dir.combos().has("superstorm"),
			str(dir.combos()))
	_ok("a tornado outbreak starts three tornadoes", dir.start("outbreak", 1.0)
			and dir.running.size() == 3 and dir.running.all(func(d) -> bool: return d is Tornado))
	var paths := {}
	for d in dir.running:
		paths[(d as Tornado).path[0].snapped(Vector3.ONE)] = true
	_ok("each on its own path", paths.size() == 3)
	var late: Array = []
	dir.add_client(func(m: Array) -> void: late.append(m))
	_ok("a client joining mid-way is sent all three", late.size() == 3)
	var most_hazards := 0
	var gale := 0.0
	var t := 0
	while dir.is_running() and t < 30 * 150:
		await physics_frame
		t += 1
		most_hazards = maxi(most_hazards, ctx.hazards.size())
		gale = maxf(gale, ctx.gale.length())
	_ok("their hazards stand side by side", most_hazards >= 3, "%d at most" % most_hazards)
	_ok("the winds add, to the cap", gale > 0.3 and gale <= 1.5 + 1e-4, "gale up to %.2f" % gale)
	_ok("they all end", not dir.is_running() and dir.running.is_empty(), "%.0f s" % (t / 30.0))
	await _ticks(5)
	_ok("and leave nothing behind: sky, AI weather, lens, storm, hazards", _all_clear(city, ctx, base))

	_ok("a superstorm starts a hurricane and two tornadoes", dir.start("superstorm", 1.0)
			and dir.running.size() == 3)
	_ok("nothing else starts while they run", not dir.start("meteor"))
	await _ticks(30 * 20)
	dir.stop()
	_ok("stop ends them all", dir.running.all(func(d) -> bool:
			return d.phase == Disaster.Phase.ENDING or d.phase == Disaster.Phase.DONE))
	t = 0
	while dir.is_running() and t < 30 * 60:
		await physics_frame
		t += 1
	await _ticks(5)
	_ok("and they leave nothing behind either", not dir.is_running() and _all_clear(city, ctx, base))
	await _until_out(dir)


func _all_clear(city: Node3D, ctx: DisasterContext, base: Color) -> bool:
	var lens_clear := ctx.screen == null or (float(ctx.screen.get_shader_parameter("rain")) == 0.0
			and float(ctx.screen.get_shader_parameter("dust")) == 0.0)
	var ok: bool = ((city._sun as DirectionalLight3D).light_color == base and ctx.hazards.is_empty()
			and city.ai_services.sight_mul == 1.0 and city.ai_services.aim_mul == 1.0
			and not city.ai_services.storm and lens_clear and ctx.gale == Vector3.ZERO
			and not ctx.raining)
	if not ok:
		print("  --   left: sun %s (base %s), %d hazard(s), sight %.2f aim %.2f storm %s lens %s gale %s rain %s" % [
				(city._sun as DirectionalLight3D).light_color, base, ctx.hazards.size(),
				city.ai_services.sight_mul, city.ai_services.aim_mul, city.ai_services.storm,
				lens_clear, ctx.gale, ctx.raining])
	return ok


## Hail (Docs/Disasters.md 24): stones land on what is open to the sky, wear
## it as committed CHIPs, are heard as the material they hit, bruise whoever
## is out in it, and lie thin.
func _check_hail(city: Node3D, dir: DisasterDirector) -> void:
	print("hail")
	await _until_out(dir)
	var ctx := dir.ctx
	# On a roof's edge: the roof under the stones, the street beside.
	var b = null
	for c in city.registry.buildings:
		if not c.toppled and not c.is_build() and not city._is_tree(c.id):
			b = c
			break
	var box := CityPlacer.box_of(b)
	city.camera.global_position = Vector3(box.position.x - 2.0, box.end.y + 3.0, box.get_center().z)
	if b.chunk < 0:
		city._promote(b.id)
	var feet: Vector3 = city.ai_nav.snap(Vector3(box.position.x - 6.0, 0.0, box.get_center().z))
	var so: Soldier = city._spawn_soldier(feet)
	so.brain.active = false
	await _ticks(10)
	var n0: int = city.authority.commands.size()
	_ok("a hailstorm starts", dir.start("hail", 1.0))
	var h: Hailstorm = dir.current
	var heard := {}
	var lying := 0.0
	var got := [0, 0, 0]
	var t := 0
	while dir.is_running() and t < 30 * 70:
		await physics_frame
		t += 1
		lying = maxf(lying, ctx.snow)
		if is_instance_valid(h):
			got = [h.landings, h.chips, h.bruised]
			var rs = h.get_node_or_null("RainSplash")
			if rs != null and (rs as RainSplash).sounds != null:
				heard = (rs as RainSplash).sounds.by_family.duplicate()
	var wait := 0
	while not city._damage_queue.is_empty() and wait < 300:
		await physics_frame
		wait += 1
	var chipped := 0
	for i in range(n0, city.authority.commands.size()):
		if city.authority.commands.entries[i].kind == DamageLog.Kind.CHIP:
			chipped += 1
	_ok("stones land, and wear what they hit as committed CHIPs", got[0] > 100 and got[1] > 0
			and chipped >= got[1], "%d landing(s), %d chip(s), %d CHIP command(s)" % [got[0], got[1], chipped])
	_ok("heard as what they hit: the roof's plastic among it", int(heard.get("plastic", 0)) > 20,
			str(heard))
	_ok("a soldier out in it is bruised", got[2] > 0)
	_ok("they lie, thin", lying > 0.2 and lying <= Hailstorm.LIE_CAP + 0.01, "%.2f" % lying)
	_ok("and it clears", not dir.is_running() and not ctx.snowing and not ctx.raining)
	ctx.snow = 0.0005
	await _ticks(10)


## The meteor variants (Docs/Disasters.md 23): the heavy shower has two to
## three times the rocks; the mixed one small rocks and one or two giants; and
## a giant lands as one crater, a shockwave and ejecta, through the authority.
func _check_giant(city: Node3D, dir: DisasterDirector) -> void:
	print("meteor variants")
	await _until_out(dir)
	var normal := MeteorShower.new()
	normal.begin(dir.ctx, 77)
	var heavy := MeteorStorm.new()
	heavy.begin(dir.ctx, 77)
	var mixed := MeteorMixed.new()
	mixed.begin(dir.ctx, 77)
	var giants := 0
	var small_max := 0.0
	for m in mixed.meteors:
		if m.get("giant", false):
			giants += 1
		else:
			small_max = maxf(small_max, float(m.radius))
	_ok("a heavy shower has two to three times the rocks", heavy.meteors.size() >= normal.meteors.size() * 1.7,
			"%d against %d" % [heavy.meteors.size(), normal.meteors.size()])
	_ok("a mixed one, small rocks and one or two giants", giants >= 1 and giants <= 2 and small_max <= 2.3,
			"%d giant(s), small ones up to %.1f m" % [giants, small_max])
	normal.free()
	heavy.free()
	mixed.free()
	dir.ctx.forget(null)

	# A giant, for real: by the tallest tower, its bricks in, the camera off it.
	var b = null
	for c in city.registry.buildings:
		if not c.toppled and not c.is_build() and not city._is_tree(c.id) and (b == null
				or CityPlacer.box_of(c).size.y > CityPlacer.box_of(b).size.y):
			b = c
	var box := CityPlacer.box_of(b)
	city.camera.global_position = box.get_center() + Vector3(-box.size.x - 40.0, 10.0, 0.0)
	if b.chunk < 0:
		city._promote(b.id)
	await _ticks(10)
	var n0: int = city.authority.commands.size()
	_ok("a giant meteor starts", dir.start("big_meteor", 1.0))
	var g: BigMeteor = dir.current
	var landed := 0
	var pieces := 0
	var radius := 0.0
	var worst := 0.0
	var worst_parts := {}
	var impact_ms := 0.0
	var worst_when := ""
	var pawns_hit := 0
	var t := 0
	while dir.is_running() and t < 30 * 60:
		await physics_frame
		t += 1
		var tick_ms := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
		if tick_ms > worst and is_instance_valid(g) and g.giants_landed > 0:
			worst = tick_ms
			worst_parts = (city._prof as Dictionary).duplicate()
			worst_when = "%s %.1f s" % [Disaster.phase_name(g.phase), g.phase_t] if is_instance_valid(g) else "after"
		# Once its spot is marked: soldiers just outside the crater, for the wave.
		if is_instance_valid(g) and not g.has_meta("placed") and g.meteors[0].has("aim"):
			g.set_meta("placed", true)
			var aim: Vector3 = g.meteors[0].aim
			var rr := float(g.meteors[0].radius)
			for k in 3:
				var a := TAU * k / 3.0
				var w: Soldier = city._spawn_soldier(city.ai_nav.snap(aim + Vector3(cos(a), 0.0, sin(a)) * rr * 1.6))
				w.brain.active = false
		if is_instance_valid(g):
			landed = g.giants_landed
			impact_ms = g.impact_ms
			pawns_hit = g.shocked_pawns
			pieces = g.shocked_pieces
			if not g.impacts.is_empty():
				radius = float(g.impacts[0].radius)
				if "--disaster-shot" in OS.get_cmdline_user_args() and not g.has_meta("shot") 						and g.phase_t > float(g.meteors[0].t) + 1.5:
					g.set_meta("shot", true)
					var cam := Camera3D.new()
					cam.far = 2000.0
					city.add_child(cam)
					var at: Vector3 = g.impacts[0].pos
					cam.look_at_from_position(at + Vector3(-60.0, 35.0, -45.0), at + Vector3(0.0, 4.0, 0.0))
					cam.make_current()
					await _ticks(3)
					await _save_shot("giant_meteor")
					cam.queue_free()
					city.camera.make_current()
	var wait := 0
	while not city._damage_queue.is_empty() and wait < 600:
		await physics_frame
		wait += 1
	var blasts := 0
	for i in range(n0, city.authority.commands.size()):
		if city.authority.commands.entries[i].kind == DamageLog.Kind.BLAST:
			blasts += 1
	_ok("one giant lands, a crater of %.1f m" % radius, landed == 1 and radius >= MeteorShower.GIANT_RADIUS - 0.01)
	_ok("its crater and its ejecta are committed blasts", blasts >= 2, "%d BLAST(s)" % blasts)
	_ok("the shockwave knocks down whoever is near", pawns_hit > 0, "%d soldier(s); %d piece(s) thrown" % [pawns_hit, pieces])
	var parts := []
	for k in worst_parts:
		if float(worst_parts[k]) >= 2.0:
			parts.append("%s %.0f" % [k, float(worst_parts[k])])
	print("  --   worst physics tick after it lands: %.1f ms (%s); the impact itself %.1f ms; at %s" % [worst, ", ".join(parts), impact_ms, worst_when])
	_ok("and it clears", not dir.is_running() and dir.ctx.hazards.is_empty())
	await _until_out(dir)


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
	# Made outside the director: what they set in WARNING is no one's to clear.
	dir.ctx.forget(null)
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
