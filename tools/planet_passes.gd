extends Node

## The sphere-planet feasibility tests (Docs/Planets.md 10b, "Feasibility
## tests"), run on the city scene: `res://scenes/city.tscn -- --planet=<test>`.
##
## Prototype measurements. Nothing here changes how the game plays: each test
## builds what it needs on top of a city that was set up as usual, measures,
## prints, and quits.

const PlanetOrigin := preload("res://tools/planet_origin.gd")

var city: Node3D


func _init(c: Node3D) -> void:
	city = c
	name = "PlanetPasses"


func run(test: String) -> void:
	print("[planet] test %s" % test)
	match test:
		"dump":
			await _dump()
		"shift":
			await _shift_test()
		"jitter":
			await _jitter_test()
		"tilt":
			await (load("res://tools/planet_tilt.gd") as GDScript).new(self).run()
		"sun":
			await (load("res://tools/planet_sun.gd") as GDScript).new(self).run()
		_:
			print("[planet] FAIL unknown test %s" % test)
	city.get_tree().quit()


## Drawn frames; headless, where nothing is drawn, process frames.
func _frames(n: int) -> void:
	var headless := DisplayServer.get_name() == "headless"
	for i in n:
		if headless:
			await city.get_tree().process_frame
		else:
			await RenderingServer.frame_post_draw


func _ticks(n: int) -> void:
	for i in n:
		await city.get_tree().physics_frame


## What the scene holds, by class: the inventory a shift has to move.
func _dump() -> void:
	await _ticks(30)
	var counts := {}
	var top := []
	_walk(city, counts, top, false)
	print("[planet] top-level 3D nodes (no Node3D ancestor below the city): %d" % top.size())
	var by_class := {}
	for n in top:
		var k: String = n.get_class() + ("(" + n.get_script().resource_path.get_file() + ")" if n.get_script() else "")
		by_class[k] = int(by_class.get(k, 0)) + 1
	for k in by_class:
		print("  top %-50s %d" % [k, by_class[k]])
	for k in counts:
		print("  all %-50s %d" % [k, counts[k]])
	print("[planet] chunks %d" % city.world.get_chunk_count())


func _walk(n: Node, counts: Dictionary, top: Array, under3d: bool) -> void:
	for c in n.get_children():
		var k := c.get_class()
		counts[k] = int(counts.get(k, 0)) + 1
		var is3d := c is Node3D
		if is3d and (not under3d or (c as Node3D).top_level):
			top.append(c)
		_walk(c, counts, top, under3d or is3d)


# ---------------------------------------------------------------------------
# Test 2: the origin shift. Settle debris, put soldiers out, record what the
# scene answers (rays, the AI's lines, paths, sleep), shift ~2 km in whole
# tiles in ONE frame, and ask again with every question moved by the offset.
# Whatever answers differently holds a position the shift did not move.

const RAYS := 600
const AI_LINES := 200


## Shot names: the plain city's and the terrain city's apart.
var _tag := "planet_shift"


func _shift_test() -> void:
	var c = city
	_tag = "planet_shift_terrain" if c._terrain_mode else "planet_shift_plain"
	var args := OS.get_cmdline_user_args()
	await _ticks(20)
	var stack_at := Vector3(-66.0, 0.0, -72.0)
	if c._terrain_mode:
		stack_at.y = _ground_y(stack_at)
	var stack := _add_stack(stack_at)
	await _make_debris("--no-debris" in args)
	# Soldiers, standing about.
	for i in 4:
		var at := Vector3(-60.0 + 6.0 * i, 0.5, -60.0)
		if c._terrain_mode:
			at.y = _ground_y(at) + 0.5
		c._spawn_soldier(at)
	await _ticks(90)
	if c._terrain_mode:
		c._lod_frozen = true
	await _ticks(5)

	var offset := PlanetOrigin.whole_tiles(Vector3(1414.0, 0.0, 1414.0))
	var rng := RandomNumberGenerator.new()
	rng.seed = 0x5EED

	# Pictures: two before (what water and the sky's TIME change on their
	# own), one after from the same place moved by the offset.
	var views: Array = []
	var drawn := DisplayServer.get_name() != "headless"
	if drawn:
		views = [
			[Vector3(-90.0, 45.0, -90.0), Vector3(0.0, 15.0, 0.0)],
			[Vector3(-74.0, 4.0, -80.0), Vector3(-62.0, 1.0, -70.0)],
			[stack_at + Vector3(-2.5, 1.6, -3.0), stack_at + Vector3(1.5, 1.0, 0.0)],
		]
		if c._terrain_mode:
			for v in views:
				v[0].y += _ground_y(v[0])
				v[1].y += _ground_y(v[1])
		for i in views.size():
			await _view_shot(views[i], Vector3.ZERO, (_tag + "_%d_a") % i)
			await _view_shot(views[i], Vector3.ZERO, (_tag + "_%d_b") % i)
		_look(views[0], Vector3.ZERO)
		await _frames(30)

	var questions := _questions(rng)
	var before := _answers(questions, Vector3.ZERO)
	var sleep0 := _sleep_census()
	var path0 := _path_time(Vector3.ZERO)
	print("[planet] shift: before -- %s; path %s" % [_census_str(sleep0), path0])

	# The shift, alone in its frame.
	var stamps: Array[int] = []
	for i in 30:
		await _frames(1)
		stamps.append(Time.get_ticks_usec())
	var r := PlanetOrigin.shift(c, offset)
	if drawn:
		_look(views[0], offset)
	var shift_at := stamps.size()
	for i in 30:
		await _frames(1)
		stamps.append(Time.get_ticks_usec())
		# The first frame drawn after it: physics interpolation reset, or a
		# 2 km smear.
		if i == 1 and drawn:
			await city._save(_tag + "_0_c0")
	print("[planet] shift: by %v -- %s" % [offset, r])
	var deltas: Array = []
	for i in range(1, stamps.size()):
		deltas.append(snappedf(float(stamps[i] - stamps[i - 1]) / 1000.0, 0.1))
	print("[planet] shift: frame ms round it (shift after frame %d): %s" % [shift_at - 1, deltas])
	if drawn:
		for i in views.size():
			await _view_shot(views[i], offset, (_tag + "_%d_c") % i)
			_diff_shots((_tag + "_%d_a") % i, (_tag + "_%d_b") % i, (_tag + "_%d_ab") % i)
			_diff_shots((_tag + "_%d_b") % i, (_tag + "_%d_c") % i, (_tag + "_%d_bc") % i)
	var phys: Array = []
	for i in 12:
		await city.get_tree().physics_frame
		phys.append(snappedf(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0, 0.01))
		print("    tick %d: %s" % [i, _top_phases(c._prof)])
	print("[planet] shift: physics ms the 12 ticks after (each the tick before it): %s" % [phys])
	var sleep1 := _sleep_census()
	await _ticks(60)
	var sleep2 := _sleep_census()
	print("[planet] shift: after (6 ticks) -- %s" % _census_str(sleep1))
	print("[planet] shift: after (66 ticks) -- %s" % _census_str(sleep2))
	var after := _answers(questions, offset)
	_compare(questions, before, after)
	var path1 := _path_time(offset)
	var path2 := _path_time(offset)
	print("[planet] shift: path after (cold) %s, again (warm) %s" % [path1, path2])


## The ground storey of the tower nearest the middle, shot out, and the pieces
## left to settle (until none has moved for three seconds, or 40 s).
func _make_debris(skip: bool, near := Vector3.ZERO, exclude := {}, min_dist := 0.0) -> int:
	var c = city
	var target = null
	for b in c.registry.buildings:
		if b.is_build() or exclude.has(b.id) or b.xform.origin.distance_to(near) < min_dist:
			continue
		if target == null or b.xform.origin.distance_to(near) < target.xform.origin.distance_to(near):
			target = b
	var blasts := 0
	if not skip and target != null:
		c._promote(target.id)
		await _frames(20)
		var fx: float = target.recipe.footprint_x * c.STUD
		var fz: float = target.recipe.footprint_z * c.STUD
		var x := 0.0
		while x <= fx + 0.01:
			var z := 0.0
			while z <= fz + 0.01:
				c._blast(target.xform * Vector3(minf(x, fx), 1.2, minf(z, fz)), 2.2)
				blasts += 1
				z += 2.5
			x += 2.5
	print("[planet] %d blasts on building %d" % [blasts, target.id if target else -1])
	var t := 0
	var quiet := 0
	while t < 1200 and quiet < 90:
		await _ticks(1)
		t += 1
		quiet = quiet + 1 if _awake_pieces() == 0 else 0
	_last_settle = t - quiet
	print("[planet] settled after %d ticks (%d pieces awake)" % [t, _awake_pieces()])
	return target.id if target != null else -1


var _last_settle := 0


# ---------------------------------------------------------------------------
# Test 1: jitter at distance. The pawn with its arms and gun beside a stack of
# loose bricks, the scene moved to 0, 2, 8 and 15 km from the origin along the
# diagonal (every axis that far: the worst case) and left there. At each:
#   * a fresh stack dropped and watched for 20 s: when it sleeps, whether it
#     wakes again, how far any brick creeps, how deep the contacts sink;
#   * a fresh collapse next door: how long its pieces take to settle;
#   * a strafe of 1 mm a physics tick: the gun's transform relative to the
#     camera every frame (what the hands' IK reads, through world space), and
#     the screen position of a brick 2 m off, against where it should be;
#   * pictures.

const JITTER_KM := [0.0, 2.0, 8.0, 15.0]
var _stack: Array[RigidBody3D] = []


func _jitter_test() -> void:
	var c = city
	await _ticks(20)
	var spot := Vector3(-70.0, 0.0, -70.0)   # open ground at the city's corner
	c._player.drive_uncaptured = true
	c._enter_pawn(spot + Vector3(0.0, 1.0, 0.0))
	await _ticks(60)
	var at := Vector3.ZERO
	var dir := Vector3(1.0, 1.0, 1.0).normalized()
	var hit := {}
	var rows: Array = []
	var kms: Array = JITTER_KM
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--km="):
			kms = [float(a.trim_prefix("--km="))]
	for km in kms:
		var want := PlanetOrigin.whole_tiles(dir * km * 1000.0)
		if want != at:
			PlanetOrigin.shift(c, want - at)
			at = want
		await _ticks(10)
		print("[planet] jitter: %.0f km -- scene origin at %v, %.2f km out; float step there %.3f mm" % [
				km, at, at.length() / 1000.0, _ulp(maxf(absf(at.x), absf(at.y))) * 1000.0])
		rows.append(await _jitter_at(km, spot + at, hit))
	print("[planet] jitter summary")
	print("  km | stack asleep at tick | woke | creep mm | sink mm/contact | pieces (not settled) | gun px rms: strafe, turn | brick 3 m off px rms: strafe, turn")
	for r in rows:
		print("  %4.0f | %4d | %3d | %5.2f | %6.2f | %3d (%d) | %.3f, %.3f | %.3f, %.3f" % r)


## The spacing of 32-bit floats at `x`.
static func _ulp(x: float) -> float:
	if x < 1e-30:
		return 1.4e-45
	return pow(2.0, floor(log(x) / log(2.0)) - 23.0)


func _jitter_at(km: float, spot: Vector3, hit: Dictionary) -> Array:
	var c = city
	var pawn = c._player_pawn
	var cam: Camera3D = c.camera
	# Stand the pawn at the spot, looking along +X at the stack.
	pawn.place(spot + Vector3(0.0, 0.2, 0.0))
	cam.global_rotation = Vector3(-0.12, -PI * 0.5, 0.0)
	await _ticks(30)

	# A fresh stack 2.5 m in front.
	for b in _stack:
		if is_instance_valid(b):
			b.queue_free()
	_stack = _add_stack(spot + Vector3(3.5, 0.0, -0.35))
	var t := 0
	while t < 900:
		await _ticks(1)
		t += 1
		var all := true
		for b in _stack:
			all = all and b.sleeping
		if all:
			break
	var sleep_tick := t
	var rest: Array[Vector3] = []
	for b in _stack:
		rest.append(b.global_position)
	var woke := 0
	var creep := 0.0
	var contacts := 0
	for i in 600:
		await _ticks(1)
		for k in _stack.size():
			var b := _stack[k]
			if not b.sleeping:
				woke += 1
			creep = maxf(creep, b.global_position.distance_to(rest[k]))
	for b in _stack:
		contacts += b.get_contact_count()
	# The column's ten bricks: centre of the top one over the bottom one,
	# against nine brick heights. What is missing is how far contacts sink.
	var col_h: float = _stack[COLUMN - 1].global_position.y - _stack[0].global_position.y
	var sink := ((COLUMN - 1) * 0.42 - col_h) / float(COLUMN - 1)
	var bottom_sink: float = 0.21 - (_stack[0].global_position.y - spot.y)

	# A collapse next door.
	# Far enough that nothing it drops reaches the pawn or the stack.
	# `--stack-only`: the physics alone, repeated cheaply headless.
	var stack_only := "--stack-only" in OS.get_cmdline_user_args()
	var bid := -1 if stack_only else await _make_debris(false, spot, hit, 30.0)
	hit[bid] = true
	var debris_ticks := _last_settle
	var debris_n := 0
	var unsettled := 0
	for isl in c.islands.islands:
		if isl.is_valid() and isl.body != null:
			debris_n += 1
			if not isl.settled:
				unsettled += 1

	# Back to the stack, and the strafe.
	pawn.place(spot + Vector3(0.0, 0.2, 0.0))
	cam.global_rotation = Vector3(-0.12, -PI * 0.5, 0.0)
	await _ticks(30)
	var drawn := DisplayServer.get_name() != "headless" and not stack_only
	var pics := {}
	const TURN := 0.002   # rad a frame: 7 degrees over a measurement
	if drawn:
		await c._save("planet_jitter_%02dkm_stack" % int(km))
		var home := func() -> void:
			pawn.place(spot + Vector3(0.0, 0.2, 0.0))
			cam.global_rotation = Vector3(-0.12, -PI * 0.5, 0.0)
		pics.gun_strafe = await _strafe_gun(km)
		home.call()
		pics.gun_turn = await _strafe_gun(km, TURN)
		if km == 0.0:
			home.call()
			pics.control_03mm = await _strafe_gun(km, TURN, 0.0003)
			home.call()
			pics.control_01mm = await _strafe_gun(km, TURN, 0.0001)
		home.call()
		await _ticks(30)
		pics.near_strafe = await _strafe_near(km, _stack[2])
		home.call()
		await _ticks(30)
		pics.near_turn = await _strafe_near(km, _stack[2], TURN * 0.25)
		if km == 0.0:
			home.call()
			await _ticks(30)
			pics.near_control_03mm = await _strafe_near(km, _stack[2], TURN * 0.25, 0.0003)
		home.call()
		await _ticks(30)
	for k in pics:
		print("[planet] jitter %.0f km picture %-13s %.3f px rms, %.3f max frame to frame (%d frames)" % [
				km, k, pics[k][0], pics[k][1], pics[k][2]])
	var gun: Node3D = c._gun.gun
	var right := cam.global_transform.basis.x
	var rels: Array[Vector3] = []
	var gaps := 0.0
	var px_err: Array[float] = []
	var shot_done := false
	var target: Vector3 = _stack[4].global_position   # a column brick ~2 m off
	var cam_start := cam.global_position
	var strafing := [true]
	var mover := func() -> void:
		if strafing[0]:
			pawn.body.global_position += right * 0.001
	city.get_tree().physics_frame.connect(mover)
	for f in 90:
		await _frames(1)
		var rel: Transform3D = cam.global_transform.affine_inverse() * gun.global_transform
		rels.append(rel.origin)
		gaps = maxf(gaps, maxf(c._view.arms.reach_gap[0], c._view.arms.reach_gap[1]))
		# Where the brick should be on screen, from positions subtracted in
		# double, against where the engine's float camera puts it.
		var want := _project_exact(cam, target)
		var got := cam.unproject_position(target)
		px_err.append(want.distance_to(got))
		if f == 45 and not shot_done and DisplayServer.get_name() != "headless":
			shot_done = true
			await c._save("planet_jitter_%02dkm" % int(km))
	strafing[0] = false
	city.get_tree().physics_frame.disconnect(mover)
	print("[planet] jitter %.0f km: the camera went %.1f mm in the strafe (pawn %s)" % [
			km, cam.global_position.distance_to(cam_start) * 1000.0, pawn.body.global_position - spot])
	var mean := Vector3.ZERO
	for r in rels:
		mean += r
	mean /= float(rels.size())
	var jit := 0.0
	for r in rels:
		jit = maxf(jit, r.distance_to(mean))
	var rms := 0.0
	var mx := 0.0
	for e in px_err:
		rms += e * e
		mx = maxf(mx, e)
	rms = sqrt(rms / maxf(px_err.size(), 1))
	var pv := func(k: String) -> float:
		return float(pics[k][0]) if pics.has(k) else -1.0
	print("[planet] jitter %.0f km: stack asleep at tick %d, woke %d brick-ticks in 20 s, crept %.2f mm, %d contacts, sink %.2f mm/contact (bottom %.2f mm); collapse of building %d: %d pieces, %d not settled after %d ticks; gun vs camera (CPU) %.3f mm, hand gap %.2f mm" % [
			km, sleep_tick, woke, creep * 1000.0, contacts, sink * 1000.0, bottom_sink * 1000.0, bid,
			debris_n, unsettled, debris_ticks, jit * 1000.0, gaps * 1000.0])
	return [km, sleep_tick, woke, creep * 1000.0, sink * 1000.0, debris_n, unsettled,
			pv.call("gun_strafe"), pv.call("gun_turn"), pv.call("near_strafe"), pv.call("near_turn")]


## The gun against the sky while strafing 1 mm a tick: its frame-to-frame
## motion on screen by Lucas-Kanade over a crop of the lower right, where the
## viewmodel is. Fixed to the camera, it should not move; the sky behind is
## near-uniform, so what moves is the gun. [rms px, max px, frames] of the
## deviation from the median motion (a sway spring's slow drift is not jitter).
const GUN_CROP := Rect2i(760, 400, 480, 300)


## `turn` radians of yaw a frame instead of the strafe (turning is where the
## big translation meets the rotation); `shake` metres of random offset a
## frame on the gun, the positive control: what jitter of that size reads as.
func _strafe_gun(km: float, turn := 0.0, shake := 0.0) -> Array:
	var c = city
	var cam: Camera3D = c.camera
	cam.global_rotation = Vector3(0.55, -PI * 0.5, 0.0)
	await _ticks(30)
	var pawn = c._player_pawn
	var gun: Node3D = c._gun.gun
	var gun_at := gun.position
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var right := cam.global_transform.basis.x
	var strafing := [turn == 0.0]
	var mover := func() -> void:
		if strafing[0]:
			pawn.body.global_position += right * 0.001
	city.get_tree().physics_frame.connect(mover)
	var cam0 := cam.global_position
	var prev := PackedFloat32Array()
	var moves: Array[Vector2] = []
	for f in 70:
		if turn != 0.0:
			cam.global_rotation.y += turn
		if shake > 0.0:
			gun.position = gun_at + Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1),
					rng.randf_range(-1, 1)) * shake
		await RenderingServer.frame_post_draw
		if f < 10:
			continue   # the sway springs take up a turn's speed first
		var img := city.get_viewport().get_texture().get_image()
		if f == 30 and turn == 0.0 and shake == 0.0:
			img.save_png("res://shots/planet_jitter_%02dkm_gun.png" % int(km))
		var l := _luma(img, GUN_CROP)
		if not prev.is_empty():
			moves.append(_lk(prev, l, GUN_CROP.size.x, GUN_CROP.size.y))
		prev = l
	strafing[0] = false
	city.get_tree().physics_frame.disconnect(mover)
	gun.position = gun_at
	if turn == 0.0 and shake == 0.0:
		print("[planet] jitter %.0f km: the camera went %.1f mm in the gun strafe" % [
				km, cam.global_position.distance_to(cam0) * 1000.0])
	return _spread(moves)


## A brick ~3 m off, measured the way the gun is: Lucas-Kanade over a fixed
## crop round it, frame to frame, less the motion an exact projection of its
## centre predicts. What is left is jitter. `shake` moves only its mesh, the
## positive control.
func _strafe_near(km: float, brick: RigidBody3D, turn := 0.0, shake := 0.0) -> Array:
	var c = city
	var cam: Camera3D = c.camera
	var pawn = c._player_pawn
	var right := cam.global_transform.basis.x
	var mesh: MeshInstance3D = null
	for ch in brick.get_children():
		if ch is MeshInstance3D:
			mesh = ch
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var strafing := [turn == 0.0]
	var mover := func() -> void:
		if strafing[0]:
			pawn.body.global_position += right * 0.001
	city.get_tree().physics_frame.connect(mover)
	var crop := Rect2i()
	var prev := PackedFloat32Array()
	var prev_want := Vector2.ZERO
	var moves: Array[Vector2] = []
	for f in 60:
		if turn != 0.0:
			cam.global_rotation.y += turn
		if shake > 0.0:
			mesh.position = Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1),
					rng.randf_range(-1, 1)) * shake
		await RenderingServer.frame_post_draw
		if f < 6:
			continue
		var img := city.get_viewport().get_texture().get_image()
		var want := _project_exact(cam, brick.global_position)
		if crop.size == Vector2i.ZERO:
			crop = Rect2i(int(want.x) - 90, int(want.y) - 60, 180, 120).intersection(
					Rect2i(0, 0, img.get_width(), img.get_height()))
			if turn == 0.0 and shake == 0.0:
				img.save_png("res://shots/planet_jitter_%02dkm_near.png" % int(km))
		var l := _luma(img, crop)
		if not prev.is_empty():
			moves.append(_lk(prev, l, crop.size.x, crop.size.y) - (want - prev_want))
		prev = l
		prev_want = want
	strafing[0] = false
	city.get_tree().physics_frame.disconnect(mover)
	if mesh != null:
		mesh.position = Vector3.ZERO
	return _spread(moves)


func _spread(moves: Array[Vector2]) -> Array:
	if moves.is_empty():
		return [0.0, 0.0, 0]
	var xs: Array[float] = []
	var ys: Array[float] = []
	for m in moves:
		xs.append(m.x)
		ys.append(m.y)
	xs.sort()
	ys.sort()
	var med := Vector2(xs[xs.size() / 2], ys[ys.size() / 2])
	var rms := 0.0
	var mx := 0.0
	for m in moves:
		var d := (m - med).length()
		rms += d * d
		mx = maxf(mx, d)
	return [sqrt(rms / moves.size()), mx, moves.size()]


func _luma(img: Image, r: Rect2i) -> PackedFloat32Array:
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	var data := img.get_data()
	var w := img.get_width()
	var out := PackedFloat32Array()
	out.resize(r.size.x * r.size.y)
	var k := 0
	for y in range(r.position.y, r.position.y + r.size.y):
		var row := (y * w + r.position.x) * 4
		for x in r.size.x:
			var i := row + x * 4
			out[k] = 0.299 * data[i] + 0.587 * data[i + 1] + 0.114 * data[i + 2]
			k += 1
	return out


## The shift that takes `a` to `b`, in pixels, by one Lucas-Kanade step
## (small shifts: a pixel or two).
func _lk(a: PackedFloat32Array, b: PackedFloat32Array, w: int, h: int) -> Vector2:
	var sxx := 0.0
	var sxy := 0.0
	var syy := 0.0
	var sxt := 0.0
	var syt := 0.0
	for y in range(1, h - 1):
		for x in range(1, w - 1):
			var i := y * w + x
			var ix := (a[i + 1] - a[i - 1]) * 0.5
			var iy := (a[i + w] - a[i - w]) * 0.5
			var it := b[i] - a[i]
			sxx += ix * ix
			sxy += ix * iy
			syy += iy * iy
			sxt += ix * it
			syt += iy * it
	var det := sxx * syy - sxy * sxy
	if absf(det) < 1e-6:
		return Vector2.ZERO
	# b(x) = a(x - d)  =>  it = -grad . d
	return Vector2(-(syy * sxt - sxy * syt) / det, -(sxx * syt - sxy * sxt) / det)


func _red_centroid(img: Image, r: Rect2i) -> Vector2:
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	r = r.intersection(Rect2i(0, 0, img.get_width(), img.get_height()))
	var data := img.get_data()
	var w := img.get_width()
	var sx := 0.0
	var sy := 0.0
	var n := 0
	for y in range(r.position.y, r.position.y + r.size.y):
		for x in range(r.position.x, r.position.x + r.size.x):
			var i := (y * w + x) * 4
			if data[i] > 110 and data[i + 1] < 80 and data[i + 2] < 80:
				sx += x
				sy += y
				n += 1
	if n < 20:
		return Vector2.INF
	return Vector2(sx / n, sy / n)


## A world point on screen with the camera-relative vector taken in double:
## two floats subtracted in GDScript's 64-bit arithmetic are exact.
func _project_exact(cam: Camera3D, p: Vector3) -> Vector2:
	var o := cam.global_transform.origin
	var d := [float(p.x) - float(o.x), float(p.y) - float(o.y), float(p.z) - float(o.z)]
	var b := cam.global_transform.basis
	var vx: float = d[0] * b.x.x + d[1] * b.x.y + d[2] * b.x.z
	var vy: float = d[0] * b.y.x + d[1] * b.y.y + d[2] * b.y.z
	var vz: float = d[0] * b.z.x + d[1] * b.z.y + d[2] * b.z.z
	var size := cam.get_viewport().get_visible_rect().size
	var f: float = (size.y * 0.5) / tan(deg_to_rad(cam.fov) * 0.5)
	return Vector2(size.x * 0.5 + vx / -vz * f, size.y * 0.5 - vy / -vz * f)


func _look(view: Array, offset: Vector3) -> void:
	var cam: Camera3D = city.camera
	cam.global_position = view[0] + offset
	cam.look_at(view[1] + offset, Vector3.UP)
	cam.reset_physics_interpolation()


func _view_shot(view: Array, offset: Vector3, shot: String) -> void:
	_look(view, offset)
	await _frames(12)
	await city._save(shot)


## Where two shots differ: the share of pixels off by more than 0.06 in any
## channel, and an image of it (white = differs).
func _diff_shots(a: String, b: String, out: String) -> void:
	var ia := Image.load_from_file("res://shots/%s.png" % a)
	var ib := Image.load_from_file("res://shots/%s.png" % b)
	if ia == null or ib == null or ia.get_size() != ib.get_size():
		print("[planet] diff %s/%s: missing" % [a, b])
		return
	var w := ia.get_width()
	var h := ia.get_height()
	var d := Image.create(w, h, false, Image.FORMAT_RGB8)
	var n := 0
	for y in h:
		for x in w:
			var pa := ia.get_pixel(x, y)
			var pb := ib.get_pixel(x, y)
			var m := maxf(absf(pa.r - pb.r), maxf(absf(pa.g - pb.g), absf(pa.b - pb.b)))
			if m > 0.06:
				n += 1
			d.set_pixel(x, y, Color(m * 4.0, m * 4.0, m * 4.0))
	d.save_png("res://shots/%s.png" % out)
	print("[planet] diff %s -> %s: %.2f%% of pixels differ" % [a, b, 100.0 * n / float(w * h)])


func _awake_pieces() -> int:
	var n := 0
	for isl in city.islands.islands:
		if isl.is_valid() and isl.body != null and not isl.body.sleeping:
			n += 1
	return n


## The city's own sleep: a settled piece is FROZEN (IslandManager.settle_now),
## a quiet one goes dormant as a record. Jolt's sleep is for everything else
## (the test stack).
func _sleep_census() -> Dictionary:
	var d := {"pieces": 0, "settled": 0, "frozen": 0, "asleep": 0, "rigid": 0, "rigid_asleep": 0,
			"dormant": city.islands.dormant.size(), "woken": city.islands.woken}
	for isl in city.islands.islands:
		if isl.is_valid() and isl.body != null:
			d.pieces += 1
			if isl.settled:
				d.settled += 1
			if isl.body.freeze:
				d.frozen += 1
			if isl.body.sleeping:
				d.asleep += 1
	_count_rigid(city.get_tree().root, d)
	return d


## A column of five 2x4 bricks and a staggered wall of 4-3-2-1, plain rigid
## bodies, to see Jolt's own sleep and contacts. (Ten in a column toppled at
## the origin as readily as 15 km out: loose boxes 0.7 m deep, six to one.)
const COLUMN := 5

func _add_stack(at: Vector3) -> Array[RigidBody3D]:
	var out: Array[RigidBody3D] = []
	var size := Vector3(1.4, 0.42, 0.7)
	var shape := BoxShape3D.new()
	shape.size = size
	var mesh := BoxMesh.new()
	mesh.size = size
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.85, 0.2, 0.15)
	mesh.material = mat
	var spots: Array[Vector3] = []
	for i in COLUMN:
		spots.append(Vector3(0.0, size.y * (i + 0.5), 0.0))
	for row in 4:
		for k in 4 - row:
			spots.append(Vector3(3.0 + (k + row * 0.5) * size.x, size.y * (row + 0.5), 0.0))
	for s in spots:
		var b := RigidBody3D.new()
		b.collision_layer = Layers.DEBRIS
		b.collision_mask = Layers.FALLING_MASK
		b.mass = 2.0
		var cs := CollisionShape3D.new()
		cs.shape = shape
		b.add_child(cs)
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		b.add_child(mi)
		b.contact_monitor = true
		b.max_contacts_reported = 8
		city.add_child(b)
		b.global_position = at + s + Vector3(0.0, 0.002, 0.0)
		out.append(b)
	return out


func _top_phases(prof: Dictionary) -> String:
	var a: Array = []
	for k in prof:
		if k.begins_with("col_") or k == "script_total":
			continue
		a.append([float(prof[k]), k])
	a.sort_custom(func(x, y): return x[0] > y[0])
	var s := "total %.1f:" % float(prof.get("script_total", 0.0))
	for i in mini(4, a.size()):
		s += " %s %.1f" % [a[i][1], a[i][0]]
	return s


func _count_rigid(n: Node, d: Dictionary) -> void:
	for ch in n.get_children():
		if ch is RigidBody3D:
			d.rigid += 1
			if (ch as RigidBody3D).sleeping:
				d.rigid_asleep += 1
		_count_rigid(ch, d)


func _census_str(d: Dictionary) -> String:
	return "pieces %d (%d settled, %d frozen, %d Jolt-asleep), %d dormant, woken so far %d; rigid bodies %d (%d Jolt-asleep)" % [
			d.pieces, d.settled, d.frozen, d.asleep, d.dormant, d.woken, d.rigid, d.rigid_asleep]


func _ground_y(p: Vector3) -> float:
	var stud: float = BrickWorld.get_stud_metres()
	return float(BrickTerrain.surface_plate(int(floor(p.x / stud)), int(floor(p.z / stud))) + 1) * BrickWorld.get_plate_metres()


## Rays from inside the city in every direction, and lines between points in
## it for the AI. All in the scene's coordinates before the shift.
func _questions(rng: RandomNumberGenerator) -> Dictionary:
	var reach := 60.0
	for b in city.registry.buildings:
		reach = maxf(reach, maxf(absf(b.xform.origin.x), absf(b.xform.origin.z)) + 20.0)
	var rays: Array = []
	for i in RAYS:
		var from := Vector3(rng.randf_range(-reach, reach), rng.randf_range(0.5, 40.0),
				rng.randf_range(-reach, reach))
		var dir := Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 0.3),
				rng.randf_range(-1, 1)).normalized()
		rays.append([from, from + dir * 150.0])
	var lines: Array = []
	for i in AI_LINES:
		var a := Vector3(rng.randf_range(-reach, reach), rng.randf_range(0.5, 20.0),
				rng.randf_range(-reach, reach))
		var b := Vector3(rng.randf_range(-reach, reach), rng.randf_range(0.5, 20.0),
				rng.randf_range(-reach, reach))
		lines.append([a, b])
	return {"rays": rays, "lines": lines}


func _answers(q: Dictionary, offset: Vector3) -> Dictionary:
	var space := city.get_world_3d().direct_space_state
	var rays: Array = []
	for r in q.rays:
		var p := PhysicsRayQueryParameters3D.create(r[0] + offset, r[1] + offset)
		var h := space.intersect_ray(p)
		if h.is_empty():
			rays.append(null)
		else:
			rays.append([h.position - offset, h.rid, h.collider_id])
	city.ai_world.sync()
	var lines: Array = []
	for l in q.lines:
		var tr: Dictionary = city.ai_world.trace(l[0] + offset, l[1] + offset)
		lines.append([tr.get("bricks", 0), snappedf(float(tr.get("proxy_bricks", 0.0)), 0.01),
				tr.get("hit", false), int(tr.get("chunk", -1))])
	return {"rays": rays, "lines": lines}


func _compare(q: Dictionary, a: Dictionary, b: Dictionary) -> void:
	var same := 0
	var moved_hit := 0
	var lost := 0
	var gained := 0
	var other := 0
	var worst := 0.0
	var examples: Array = []
	for i in q.rays.size():
		var x = a.rays[i]
		var y = b.rays[i]
		if x == null and y == null:
			same += 1
		elif x == null:
			gained += 1
			if examples.size() < 8:
				examples.append("gained %v (rid %s obj %d)" % [y[0], y[1], y[2]])
		elif y == null:
			lost += 1
			if examples.size() < 8:
				examples.append("lost %v (rid %s obj %d)" % [x[0], x[1], x[2]])
		elif x[1] != y[1] or x[2] != y[2]:
			other += 1
			if examples.size() < 8:
				examples.append("other collider at %v" % [x[0]])
		else:
			var d: float = (x[0] - y[0]).length()
			worst = maxf(worst, d)
			if d < 0.005:
				same += 1
			else:
				moved_hit += 1
	print("[planet] shift: rays %d same, %d hit elsewhere, %d lost, %d gained, %d other collider; worst same-collider %.2f mm" % [
			same, moved_hit, lost, gained, other, worst * 1000.0])
	for e in examples:
		print("    %s" % e)
	var lsame := 0
	var ldiff: Array = []
	for i in q.lines.size():
		if str(a.lines[i]) == str(b.lines[i]):
			lsame += 1
		elif ldiff.size() < 8:
			ldiff.append("%s -> %s" % [a.lines[i], b.lines[i]])
	print("[planet] shift: AI lines %d of %d the same" % [lsame, q.lines.size()])
	for e in ldiff:
		print("    %s" % e)


## One path across the city, timed.
func _path_time(offset: Vector3) -> String:
	var a := Vector3(-70.0, 0.5, -70.0)
	var b := Vector3(70.0, 0.5, 70.0)
	if city._terrain_mode:
		a.y = _ground_y(a) + 0.5
		b.y = _ground_y(b) + 0.5
	a = city.ai_nav.snap(a + offset) - offset
	b = city.ai_nav.snap(b + offset) - offset
	var t0 := Time.get_ticks_usec()
	var p: PackedVector3Array = city.ai_nav.find_path(a + offset, b + offset, 200000)
	var ms := float(Time.get_ticks_usec() - t0) / 1000.0
	var length := 0.0
	for i in range(1, p.size()):
		length += p[i].distance_to(p[i - 1])
	return "%.1f ms, %d points, %.1f m" % [ms, p.size(), length]
