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


func _shift_test() -> void:
	var c = city
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
			await _view_shot(views[i], Vector3.ZERO, "planet_shift_%d_a" % i)
			await _view_shot(views[i], Vector3.ZERO, "planet_shift_%d_b" % i)
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
			await city._save("planet_shift_0_c0")
	print("[planet] shift: by %v -- %s" % [offset, r])
	var deltas: Array = []
	for i in range(1, stamps.size()):
		deltas.append(snappedf(float(stamps[i] - stamps[i - 1]) / 1000.0, 0.1))
	print("[planet] shift: frame ms round it (shift after frame %d): %s" % [shift_at - 1, deltas])
	if drawn:
		for i in views.size():
			await _view_shot(views[i], offset, "planet_shift_%d_c" % i)
			_diff_shots("planet_shift_%d_a" % i, "planet_shift_%d_b" % i, "planet_shift_%d_ab" % i)
			_diff_shots("planet_shift_%d_b" % i, "planet_shift_%d_c" % i, "planet_shift_%d_bc" % i)
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
func _make_debris(skip: bool) -> void:
	var c = city
	var target = null
	for b in c.registry.buildings:
		if b.is_build():
			continue
		if target == null or b.xform.origin.length() < target.xform.origin.length():
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
	print("[planet] settled after %d ticks (%d pieces awake)" % [t, _awake_pieces()])


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


## A column of ten 2x4 bricks and a staggered wall of 4-3-2-1, plain rigid
## bodies, to see Jolt's own sleep and contacts.
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
	for i in 10:
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
