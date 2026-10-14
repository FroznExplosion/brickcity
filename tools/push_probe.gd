extends SceneTree

## A blast pushes what it reaches, and loose bricks clatter
## (Docs/CollapseNext.md 1.10 (4)).
##
##     godot --headless --path . --script tools/push_probe.gd
##
## IslandManager.push_near: every loose piece within PUSH_REACH of a blast's
## radius is shoved away from it and a little up -- a light one thrown, a
## heavy one barely moved -- and wreckage at rest stays at rest unless the shove
## is worth waking it for (PUSH_WAKE_SPEED). A gun's wear pushes nothing.
## Crumbs (a brick or a handful) bounce when they come down hard, then stop.
## Both are feel numbers with a slider in Options; a test runs on the defaults.

var _pass := 0
var _fail := 0
var _started := false
var _w: BrickWorld
var _palette: Dictionary
var _m: IslandManager


func _init() -> void:
	print("a blast pushes what it reaches, and loose bricks clatter")
	_w = BrickWorld.new()
	_palette = TowerRecipe.bake_palette(_w)
	var ground := StaticBody3D.new()
	ground.collision_layer = Layers.WORLD
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(400.0, 1.0, 400.0)
	shape.shape = box
	shape.position = Vector3(0.0, -0.5, 0.0)
	ground.add_child(shape)
	root.add_child(ground)
	_m = IslandManager.new()
	root.add_child(_m)
	_m.setup(_w, null, null)
	_m.interest = func() -> PackedVector3Array: return PackedVector3Array([Vector3(0, 1, 0)])
	physics_frame.connect(_run)


func _ok(what: String, cond: bool, detail := "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _ticks(n: int) -> void:
	for k in n:
		await physics_frame
		_m.tick()


## A piece of tower `fx` x `fz` studs and `courses` high, its grid's corner at `at`.
func _piece(at: Vector3, fx: int, fz: int, courses: int) -> BrickIsland:
	var c := _w.create_chunk(Vector3i.ZERO, TowerRecipe.chunk_dims(fx, fz, courses))
	TowerRecipe.build(_w, c, _palette, fx, fz, courses)
	_w.set_chunk_transform(c, Transform3D(Basis(), at))
	var ids := PackedInt32Array()
	for id in _w.get_block_count(c):
		ids.append(id)
	return _m.spawn(c, ids, Vector3.ZERO, Vector3.ZERO, -1, -1)


## A piece put down and settled where it lies.
func _resting(at: Vector3, fx: int, fz: int, courses: int) -> BrickIsland:
	var p := _piece(at, fx, fz, courses)
	await _ticks(60)
	_m.settle_now(p)
	return p


## The world point `gap` metres off the -x side of a piece, at its middle.
func _beside(p: BrickIsland, gap: float) -> Vector3:
	var b := _m.world_aabb(p)
	return Vector3(b.position.x - gap, b.get_center().y, b.get_center().z)


func _run() -> void:
	if _started:
		return
	_started = true

	# --- light and heavy ------------------------------------------------------------
	print("\na rocket beside a handful of bricks, and beside a heap of a thousand")
	var light := await _resting(Vector3(0.0, 0.05, 0.0), 8, 8, 2)
	var heavy := await _resting(Vector3(40.0, 0.05, 0.0), 28, 16, 8)
	var far := await _resting(Vector3(80.0, 0.05, 0.0), 8, 8, 2)
	var n_light := _w.get_alive_block_count(light.chunk)
	var n_heavy := _w.get_alive_block_count(heavy.chunk)
	_ok("both are down and at rest", light.settled and heavy.settled and far.settled,
			"%d and %d bricks" % [n_light, n_heavy])
	var light_x := light.body.global_position.x
	var pushed := _m.push_near(_beside(light, 0.5), 1.3)
	_m.push_near(_beside(heavy, 0.5), 1.3)
	_m.push_near(_beside(far, 6.0), 1.3)
	_ok("the handful is knocked over: woken, and moving", pushed == 1 and not light.settled,
			"%d pushed" % pushed)
	# The shove is in the body's velocity once the physics has stepped.
	await _ticks(1)
	var v := light.body.linear_velocity
	_ok("away from the blast, and a little up", v.x > 0.5 and v.y > 0.0, "%v" % v)
	_ok("the heap shrugs it off: still at rest, where it was", heavy.settled
			and int(_m.push_census[2]) == 1, str(_m.push_census))
	_ok("and nothing past the blast's reach is touched", far.settled)
	await _ticks(30)
	_ok("half a second on, the handful has gone somewhere",
			light.is_valid() and light.body.global_position.x > light_x + 0.2,
			"%.2f m" % (light.body.global_position.x - light_x))

	# --- how hard ---------------------------------------------------------------------
	print("\nhow hard")
	var a := await _resting(Vector3(0.0, 0.05, 30.0), 8, 8, 2)
	var b := await _resting(Vector3(20.0, 0.05, 30.0), 8, 8, 2)
	_m.push_near(_beside(a, 0.2), 1.3)
	_m.push_near(_beside(b, 2.2), 1.3)
	await _ticks(1)
	var va := a.body.linear_velocity.length()
	var vb := b.body.linear_velocity.length() if not b.settled else 0.0
	_ok("nearer the blast, harder", va > vb, "%.2f against %.2f m/s" % [va, vb])
	_ok("and never past PUSH_MAX_SPEED", va <= IslandManager.PUSH_MAX_SPEED + 0.01)
	var pushes0: int = _m.push_census[0]
	IslandManager.push_times = 0.0
	var c := await _resting(Vector3(40.0, 0.05, 30.0), 8, 8, 2)
	_m.push_near(_beside(c, 0.2), 1.3)
	_ok("at 0 on the slider, nothing is pushed", c.settled and _m.push_census[0] == pushes0)
	IslandManager.push_times = IslandManager.PUSH_DEFAULT_TIMES

	# --- through the shots' own path ------------------------------------------------------
	print("\nthrough damage_near")
	var d := await _resting(Vector3(60.0, 0.05, 30.0), 8, 8, 2)
	pushes0 = _m.push_census[0]
	_m.damage_near(_beside(d, 0.3), 0.3, 60)
	_ok("a gun's wear pushes nothing", d.settled and _m.push_census[0] == pushes0)
	_m.damage_near(_beside(d, 0.3), 1.3)
	_ok("a blast does", _m.push_census[0] > pushes0)

	# --- in the air -------------------------------------------------------------------------
	print("\na piece falling past a blast")
	var falling := _piece(Vector3(0.0, 12.0, 60.0), 8, 8, 2)
	await _ticks(10)
	var vx0 := falling.body.linear_velocity.x
	_m.push_near(_beside(falling, 0.3), 1.3)
	await _ticks(1)
	_ok("is knocked sideways on its way down", falling.body.linear_velocity.x > vx0 + 0.5,
			"%.2f -> %.2f m/s" % [vx0, falling.body.linear_velocity.x])

	# --- and it all comes to rest -----------------------------------------------------------------
	var moving := 0
	for t in 30 * 12:
		await _ticks(1)
		moving = 0
		for p in _m.islands:
			if p.is_valid() and not p.settled:
				moving += 1
		if moving == 0:
			break
	_ok("everything pushed comes to rest again", moving == 0, "%d still moving" % moving)

	# --- clatter ------------------------------------------------------------------------------------
	print("\nloose bricks clatter")
	var tower := _w.create_chunk(Vector3i.ZERO, TowerRecipe.chunk_dims(16, 16, 20))
	TowerRecipe.build(_w, tower, _palette, 16, 16, 20)
	_w.set_chunk_transform(tower, Transform3D(Basis(), Vector3(0.0, 0.0, 120.0)))
	var at := Vector3(2.8, 3.0, 120.2)
	var killed: PackedInt32Array = _w.apply_hit(tower, at, 1.6)
	_m.throw_killed(tower, killed, at, 1.6)
	var thrown := _m.crumb_count
	var under := 0
	var risen := 0
	var landed := 0
	for t in 80:
		await _ticks(1)
		var now_landed := 0
		for key in _m._crumbs:
			var cr = _m._crumbs[key]
			for i in cr.pos.size():
				var foot: float = cr.pos[i].y - cr.half_h[i]
				if foot < cr.floor_y[i] - 0.01:
					under += 1
				if cr.landed[i] > 0:
					now_landed += 1
				if cr.vel[i].y > 0.5 and foot < cr.floor_y[i] + 0.3:
					risen += 1
		landed = maxi(landed, now_landed)
	_ok("bricks thrown off a wall bounce when they hit the street",
			thrown > 0 and _m.crumb_bounces > 0 and risen > 0,
			"%d thrown, %d bounce(s)" % [thrown, _m.crumb_bounces])
	_ok("never sinking into it, and coming to rest on it", under == 0 and landed > 0,
			"%d at rest at once at the most, %d sample(s) under the street" % [landed, under])
	await _ticks(30)
	var bounces0 := _m.crumb_bounces
	IslandManager.crumb_bounce = 0.0
	at = Vector3(2.8, 2.0, 120.2)
	killed = _w.apply_hit(tower, at, 1.6)
	_m.throw_killed(tower, killed, at, 1.6)
	await _ticks(70)
	_ok("at 0 on the slider, none bounces", _m.crumb_bounces == bounces0)
	IslandManager.crumb_bounce = IslandManager.CRUMB_BOUNCE

	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
