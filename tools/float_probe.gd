extends SceneTree

## Floating wreckage: a settled piece is frozen, and one that settled resting on
## something that later went -- a piece deleted, a piece that woke and slid
## off, a chunk a collapse let go -- used to stay where it was, in mid-air, and
## whatever fell next landed on it and stuck.
##
##     godot --headless --path . --script tools/float_probe.gd
##
## IslandManager.support_gone and the ripple: what rested on a piece that is
## removed, or that starts to move, is woken; a piece put to sleep for distance
## keeps what rests on it asleep too; a falling piece that lands on a frozen one
## wakes it; and a piece with no mesh still has a box to be found by.
## A piece touching nothing is never frozen, however many support tries it has
## used; the watchdog wakes one frozen in mid-air; hold_awake keeps a piece in
## the wind from settling until it is let go.

var _pass := 0
var _fail := 0
var _started := false
var _w: BrickWorld
var _palette: Dictionary
var _m: IslandManager


func _init() -> void:
	print("floating wreckage wakes when what held it goes")
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
		print("  ok   %s" % what)
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


## A slab of brick as a piece, its grid's corner at `at`.
func _piece(at: Vector3, fx := 8, fz := 8, courses := 2) -> BrickIsland:
	var c := _w.create_chunk(Vector3i.ZERO, TowerRecipe.chunk_dims(fx, fz, courses))
	TowerRecipe.build(_w, c, _palette, fx, fz, courses)
	_w.set_chunk_transform(c, Transform3D(Basis(), at))
	var ids := PackedInt32Array()
	for id in _w.get_block_count(c):
		ids.append(id)
	return _m.spawn(c, ids, Vector3.ZERO, Vector3.ZERO, -1, -1)


func _ticks(n: int) -> void:
	for k in n:
		await physics_frame
		_m.tick()


func _y(isl: BrickIsland) -> float:
	return isl.body.global_position.y if isl.is_valid() else -INF


## Two slabs, one dropped onto the other, both settled where they came to rest.
func _stack(x: float) -> Array:
	var b := _piece(Vector3(x, 0.05, 0.0))
	var a := _piece(Vector3(x + 0.3, 1.5, 0.3))
	await _ticks(90)
	_m.settle_now(b)
	_m.settle_now(a)
	return [a, b]


func _run() -> void:
	if _started:
		return
	_started = true

	# --- the piece under it is deleted -----------------------------------------
	print("\nthe piece under it is deleted")
	var s1: Array = await _stack(0.0)
	var a1: BrickIsland = s1[0]
	var b1: BrickIsland = s1[1]
	var beside := _piece(Vector3(6.0, 0.05, 0.0))
	await _ticks(60)
	_m.settle_now(beside)
	_ok("the top slab came to rest on the bottom one", _y(a1) > _y(b1) + 0.2,
			"%.2f over %.2f" % [_y(a1), _y(b1)])
	var y0 := _y(a1)
	_m._retire(b1, _m.islands.find(b1), &"cap")
	await _ticks(3)
	_ok("taking the bottom one away wakes the top one", a1.is_valid() and not a1.settled)
	_ok("and a piece beside it, not on it, sleeps on", beside.settled)
	await _ticks(45)
	_ok("which falls to the ground", _y(a1) < y0 - 0.2, "%.2f from %.2f" % [_y(a1), y0])

	# --- the piece under it goes to sleep for distance --------------------------
	print("\nthe piece under it goes to sleep for distance")
	var s2: Array = await _stack(20.0)
	var a2: BrickIsland = s2[0]
	var b2: BrickIsland = s2[1]
	_m._retire(b2, _m.islands.find(b2), &"slept")
	await _ticks(5)
	_ok("what rests on a piece put to sleep sleeps on (both come back together)", a2.settled)

	# --- the piece under it is woken and slides away -----------------------------
	print("\nthe piece under it wakes")
	var s3: Array = await _stack(40.0)
	var a3: BrickIsland = s3[0]
	var b3: BrickIsland = s3[1]
	_m.wake(b3)
	await _ticks(5)
	_ok("woken and staying put, it wakes nothing", a3.settled)
	_m.wake(b3)
	b3.body.linear_velocity = Vector3(4.0, 0.0, 0.0)
	await _ticks(5)
	_ok("once it moves off, what rested on it is woken", not a3.settled)
	_ok("counted", _m.ripple_woken >= 2, "%d" % _m.ripple_woken)

	# --- a frozen piece in mid-air, landed on ------------------------------------
	print("\na floater is landed on")
	# The watchdog would find this floater on its own; off here, so it is the
	# landing that has to wake it.
	_m.audit_enabled = false
	var floater := _piece(Vector3(60.0, 3.0, 0.0))
	_m.settle_now(floater)
	var fy := _y(floater)
	var dropped := _piece(Vector3(60.3, 6.0, 0.3))
	var guard := 0
	while floater.settled and guard < 120:
		await _ticks(1)
		guard += 1
	_ok("what lands on it wakes it", not floater.settled, "%d ticks" % guard)
	await _ticks(60)
	_ok("and it falls under the load instead of holding it up", _y(floater) < fy - 1.0,
			"%.2f from %.2f" % [_y(floater), fy])
	_ok("counted", _m.touch_woken >= 1, "%d" % _m.touch_woken)
	_m.audit_enabled = true

	# --- a piece on the ground, landed on -------------------------------------------
	print("
wreckage on the ground is landed on")
	var pile := _piece(Vector3(160.0, 0.05, 0.0))
	await _ticks(30)
	_m.settle_now(pile)
	var touched_before := _m.touch_woken
	var onto := _piece(Vector3(160.3, 3.0, 0.3))
	var g3 := 0
	while not onto.settled and g3 < 150:
		await _ticks(1)
		g3 += 1
	_ok("what lands on wreckage that is held up does not wake it",
			pile.settled and _m.touch_woken == touched_before,
			"settled %s, woken %d" % [pile.settled, _m.touch_woken - touched_before])

	# --- a box for a piece with no mesh --------------------------------------------
	print("\na piece with its mesh dropped can still be found")
	var far := _piece(Vector3(80.0, 0.05, 0.0))
	await _ticks(30)
	if far.mesh != null:
		far.mesh.mesh = null
	var box := _m.world_aabb(far)
	_ok("its box is its grid's, not nothing", box.size.length() > 1.0, "%s" % box)
	_m.settle_now(far)
	_m.wake_near(box.get_center(), 0.5)
	_ok("and a blast at its middle wakes it", not far.settled)

	# --- held in mid-air by nothing under it ------------------------------------
	print("\na piece with nothing under it does not settle there")
	var wall := _piece(Vector3(120.0, 0.05, 0.0), 8, 8, 12)
	await _ticks(2)
	_m.settle_now(wall)
	var wbox := _m.world_aabb(wall)
	var stuck := _piece(Vector3(wbox.end.x, 2.5, 0.0))
	_ok("the wall is solid beside it", wall.settled)
	# Held where it is -- as friction against the bricks it came from holds one.
	stuck.body.gravity_scale = 0.0
	stuck.body.linear_velocity = Vector3.ZERO
	stuck.born_ms -= 5000
	var sy := _y(stuck)
	var g2 := 0
	while stuck.unsupported_tries == 0 and g2 < 150:
		await _ticks(1)
		g2 += 1
	_ok("it is not frozen where it hangs", not stuck.settled and stuck.unsupported_tries >= 1,
			"%d tries, settled %s" % [stuck.unsupported_tries, stuck.settled])
	stuck.body.gravity_scale = 1.0
	await _ticks(45)
	_ok("and, let go, it falls", _y(stuck) < sy - 0.5, "%.2f from %.2f" % [_y(stuck), sy])
	var rest := _piece(Vector3(140.0, 0.05, 0.0))
	await _ticks(2)
	_ok("a piece on the ground is supported", _m._supported_below(rest))

	# --- held up by nothing at all, past every try -----------------------------------
	print("\na piece touching nothing is never frozen, however long it hangs")
	var hung := _piece(Vector3(0.0, 20.0, 60.0))
	await _ticks(2)
	_ok("nothing touches it", not _m._touching_anything(hung))
	hung.born_ms -= 20000
	var refused0 := _m.floating_refused
	var tries_seen := 0
	for k in 30 * 6:
		# Held still, as the wind holds a piece at the top of its climb.
		hung.body.gravity_scale = 0.0
		hung.body.linear_velocity = Vector3.ZERO
		hung.body.angular_velocity = Vector3.ZERO
		await _ticks(1)
		tries_seen = maxi(tries_seen, hung.unsupported_tries)
	_ok("past its SUPPORT_TRIES it is still not frozen", not hung.settled
			and tries_seen > IslandManager.SUPPORT_TRIES and _m.floating_refused > refused0,
			"%d tries, %d refused, settled %s" % [tries_seen, _m.floating_refused - refused0, hung.settled])
	hung.body.gravity_scale = 1.0
	var g4 := 0
	while not hung.settled and g4 < 300:
		await _ticks(1)
		g4 += 1
	_ok("let go, it falls and settles on the ground", hung.settled and _y(hung) < 3.0,
			"y %.2f, settled %s after %d ticks" % [_y(hung), hung.settled, g4])

	# --- frozen in mid-air: the watchdog ------------------------------------------------
	print("\nthe watchdog wakes a piece frozen in mid-air")
	var frozen := _piece(Vector3(20.0, 15.0, 60.0))
	await _ticks(1)
	_m.settle_now(frozen)
	var woken0 := _m.audit_woken
	var fz := _y(frozen)
	var g5 := 0
	while frozen.settled and g5 < 300:
		await _ticks(1)
		g5 += 1
	_ok("it is found and woken", not frozen.settled and _m.audit_woken > woken0, "%d ticks" % g5)
	await _ticks(60)
	_ok("and falls", _y(frozen) < fz - 3.0, "%.2f from %.2f" % [_y(frozen), fz])
	var ground_piece := _piece(Vector3(40.0, 0.05, 60.0))
	await _ticks(30)
	_m.settle_now(ground_piece)
	await _ticks(90)
	_ok("while a piece resting on the ground is left asleep", ground_piece.settled)

	# --- held awake by wind --------------------------------------------------------------
	print("\na piece held awake does not settle until let go")
	var windy := _piece(Vector3(60.0, 0.05, 60.0))
	await _ticks(30)
	_m.hold_awake(windy, 2500)
	await _ticks(45)
	_ok("resting, but held: not settled", not windy.settled)
	var g6 := 0
	while not windy.settled and g6 < 180:
		await _ticks(1)
		g6 += 1
	_ok("and settles once the hold runs out", windy.settled, "%d more ticks" % g6)
	_m.settle_now(windy)
	_m.hold_awake(windy, 500)
	_ok("holding a settled piece wakes it", not windy.settled)

	# --- a piece that is only furniture ----------------------------------------------
	print("
a piece that is only furniture has nothing to draw")
	_ok("an empty mesh has an index width", IslandManager.index_width([]) == 4)
	var chairs := _piece(Vector3(180.0, 0.05, 0.0))
	var all := PackedInt32Array()
	for id in _w.get_block_count(chairs.chunk):
		all.append(id)
	_w.set_blocks_decorative(chairs.chunk, all, true)
	# Its faces were baked as bricks; furniture is not in the bake.
	_w.drop_chunk_bake(chairs.chunk)
	_m.rebuild_mesh(chairs, true, true)
	_ok("and builds as nothing, not as an error", chairs.array_mesh == null
			and chairs.index_width == 4)

	# --- support_gone on its own ----------------------------------------------------
	print("\nsupport_gone wakes what is on the box, not what is under it")
	var under := _piece(Vector3(100.0, 0.05, 0.0))
	var over := _piece(Vector3(100.0, 3.0, 0.0))
	await _ticks(2)
	_m.settle_now(under)
	_m.settle_now(over)
	var gone := _m.world_aabb(under)
	gone.position.y += gone.size.y   # a box just above the lower slab...
	gone.size.y = 2.0                # ...up to the upper one
	_m.support_gone(gone)
	await _ticks(2)
	_ok("the piece on top of the box wakes", not over.settled)
	_ok("the piece under the box does not", under.settled)

	# A piece in the air carries nothing: a hit cuts it where it DISCONNECTS it
	# and nowhere else (IslandManager.solve_island; Docs/CollapseNext.md 1.4).
	# Stood on its lowest bricks and stress-solved, as a piece on the ground
	# is, a falling section failed all the way across for one shot: 174 bodies
	# off 262 hits in the air in a --big --shot, where 155 on the ground made 12.
	print("\na hit on a piece in the air cuts it only where it disconnects it")
	var tall := _piece(Vector3(160.0, 80.0, 0.0), 20, 20, 36)
	await _ticks(2)
	var tall_box := _m.world_aabb(tall)
	var bodies := _m.islands.size()
	var skipped: int = _m.air_solves_skipped
	_m.damage(tall, Vector3(tall_box.position.x + 0.2, tall_box.get_center().y, tall_box.get_center().z), 1.2)
	await _ticks(3)
	_ok("a hole blown in a falling section's wall leaves it one piece, and it is not stress-solved",
			tall.is_valid() and not tall.landed and _m.islands.size() == bodies
			and _m.air_solves_skipped > skipped,
			"%d bodies before, %d after; landed %s; %d solve(s) skipped" % [
				bodies, _m.islands.size(), tall.landed, _m.air_solves_skipped - skipped])
	# Cut clean through, it is two.
	var dims: Vector3i = _w.get_chunk_dims(tall.chunk)
	var origin: Vector3i = _w.get_chunk_origin(tall.chunk)
	var band := PackedInt32Array()
	@warning_ignore("integer_division")
	var cut_y := dims.y / 2
	for y in range(cut_y, cut_y + 6):
		for x in dims.x:
			for z in dims.z:
				var blk: int = _w.block_at(tall.chunk, origin + Vector3i(x, y, z))
				if blk >= 0 and not band.has(blk):
					band.push_back(blk)
	_w.kill_blocks(tall.chunk, band)
	tall.disable_blocks(band)
	bodies = _m.islands.size()
	_m.solve_island(tall)
	_ok("cut clean through in the air, it is two pieces", _m.islands.size() == bodies + 1
			and not tall.landed,
			"%d brick(s) cut; %d bodies before, %d after" % [band.size(), bodies, _m.islands.size()])
	# Down, the same question is the stress solve: nothing is skipped.
	tall.landed = true
	skipped = _m.air_solves_skipped
	_m.solve_island(tall)
	_ok("once it is down it is solved for what it can hold", _m.air_solves_skipped == skipped)
	# And a hit's solve is made before the piece is put to sleep, not lost with it.
	var other := _piece(Vector3(200.0, 80.0, 0.0), 20, 20, 36)
	await _ticks(2)
	var ob := _m.world_aabb(other)
	_m.damage(other, Vector3(ob.position.x + 0.2, ob.get_center().y, ob.get_center().z), 1.2)
	var owed: bool = (_m.pending_state().resolve as PackedInt32Array).size() > 0 \
			or _m._resolve_queue.has(other)
	_m._decide_owed(other)
	_ok("a decision queued for a piece is made before it sleeps", owed and not _m._resolve_queue.has(other))

	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
