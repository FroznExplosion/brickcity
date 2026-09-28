extends SceneTree

## Gate for Docs/Collapse.md: collapse, LOD and the AI.
##
##     godot --headless --path . --script res://tools/collapse_probe.gd
##     ... -- --only=shell,fake,...   run just those sections
##
## shell  (1) the coarse box tier is for undamaged buildings only.
## fake   (2) a room's fake is redrawn when its building's structure changes:
##        a floor taken out while nobody was near, the building given back and
##        rebuilt, and no faked item is left standing on air.
## stairs (4) a tower whose ground storey is gone but for its staircase does not
##        stand on the staircase: nothing above is grounded through it.
## handover (3) sections cut off buildings -- some just promoted, bands still
##        building; some long built -- and no tick where a piece that left
##        draws nothing while its building has stopped (gap), nor where it
##        draws and its building still draws the same bricks (double).

var _pass := 0
var _fail := 0
var city: Node3D
## Building id -> its staircase's box in its chunk, taken before the cut.
var _shafts := {}
## Buildings a section has used: later sections want untouched ones, or they
## meet the rubble of earlier ones (a trapped soldier found a way down through
## the last section's wreckage).
var _touched: Array = []


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


func _drain(limit := 30 * 30) -> void:
	var n := 0
	while (not city._damage_queue.is_empty() or not city._dirty.is_empty()) and n < limit:
		await physics_frame
		n += 1


func _only(name: String) -> bool:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--only="):
			return name in a.split("=", true, 1)[1].split(",")
	return true


func _run() -> void:
	print("collapse probe")
	if _only("stairs"):
		_check_stairs()
	city = load("res://scenes/city.tscn").instantiate()
	root.add_child(city)
	await _ticks(30)
	if _only("shell"):
		await _check_shell()
	if _only("fake"):
		await _check_fake()
	if _only("handover"):
		await _check_handover()
	if _only("crush"):
		await _check_crush()
	if _only("far"):
		await _check_far()
	if _only("shelter"):
		await _check_shelter()
	if _only("tops"):
		await _check_tops()
	if _only("inside"):
		await _check_inside_topple()
	if _only("weather"):
		await _check_weather()
	if _only("carried"):
		await _check_carried()
	if _only("fall"):
		await _check_fall()
	if _only("trapped"):
		await _check_trapped()
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


# --- (5) ------------------------------------------------------------------------

## A slab of brick as a falling piece in the city's world, its corner at `at`.
func _drop(at: Vector3, fx: int, fz: int, courses: int) -> BrickIsland:
	var w: BrickWorld = city.world
	var c := w.create_chunk(Vector3i.ZERO, TowerRecipe.chunk_dims(fx, fz, courses))
	TowerRecipe.build(w, c, city.palette, fx, fz, courses)
	w.set_chunk_transform(c, Transform3D(Basis(), at))
	var ids := PackedInt32Array()
	for id in w.get_block_count(c):
		ids.append(id)
	return city.islands.spawn(c, ids, Vector3.ZERO, Vector3.ZERO, -1, -1)


func _soldier_at(p: Vector3, hp := 500.0) -> Soldier:
	var so: Soldier = city._spawn_soldier(city.ai_nav.snap(p))
	if hp > 0.0:
		so.pawn.health.layer_configs[0].max_value = hp
		so.pawn.health.reset()
	return so


func _check_crush() -> void:
	print("crush: what falls on a soldier hurts it, and nobody is left inside a piece")
	var open := Vector3(-80.0, 0.0, -80.0)
	city.camera.global_position = open + Vector3(10.0, 8.0, 10.0)

	var so := _soldier_at(open)
	await _ticks(20)
	so.stop()
	var hp0: float = so.pawn.health.total_current()
	var f := so.pawn.feet()
	# Watched: a small piece nobody can see is deleted where it would spawn.
	city.camera.look_at_from_position(f + Vector3(10.0, 6.0, 10.0), f)
	var piece := _drop(f + Vector3(-0.7, 5.0, -0.7), 4, 4, 2)
	await _ticks(60)
	var hp1: float = so.pawn.health.total_current()
	_ok("a small piece dropped on a soldier hurts it", hp1 < hp0 and not so.pawn.health.is_dead(),
			"%.0f -> %.0f hp" % [hp0, hp1])

	var big := _soldier_at(open + Vector3(30.0, 0.0, 0.0), -1.0)
	await _ticks(20)
	# Held still: a thinking soldier walks out from under a falling piece (it
	# did, even from 2 m) -- this is about what happens when one cannot.
	big.brain.active = false
	big.stop()
	var bf := big.pawn.feet()
	city.camera.look_at_from_position(bf + Vector3(16.0, 8.0, 16.0), bf)
	var hp_big: float = big.pawn.health.total_current()
	# A wall of it straight down on the soldier (a hollow slab's middle is air),
	# from low enough that it cannot get out from under it: soldiers evade a
	# piece they see falling, which is the AI doing its job.
	var slab := _drop(bf + Vector3(-3.0, 2.2, -0.35), 18, 18, 6)
	await _ticks(90)
	print("  --   big piece %s, %d bricks; soldier %.0f -> %.0f hp; crush hits %d kills %d" % [slab,
			city.world.get_alive_block_count(slab.chunk) if slab != null and slab.is_valid() else -1,
			hp_big, big.pawn.health.total_current(), city.crush.hits, city.crush.kills])
	_ok("a big one kills it", big.pawn.health.is_dead(), "%d kill(s)" % city.crush.kills)

	var stuck := _soldier_at(open + Vector3(0.0, 0.0, 30.0))
	await _ticks(20)
	stuck.stop()
	var sf := stuck.pawn.feet()
	city.camera.look_at_from_position(sf + Vector3(10.0, 6.0, 10.0), sf)
	# Around it, at rest: a piece born where it stands.
	# One of its walls through the soldier: the corner just behind it, the
	# wall along x (a hollow slab's middle is air).
	var pushes0: int = city.crush.pushes
	var ring := _drop(sf + Vector3(-1.4, 0.05, -0.35), 8, 8, 2)
	await _ticks(60)
	var was_inside: bool = city.crush.pushes > pushes0
	var still: bool = city.crush._inside(ring, [stuck.pawn.feet() + Vector3.UP * 0.3,
			stuck.pawn.chest(), stuck.pawn.feet() + Vector3.UP * 1.55])
	_ok("a soldier inside a piece is pushed out of it", was_inside and not still,
			"inside at first %s, after 2 s %s; %d push tick(s)" % [was_inside, still, city.crush.pushes])


## A generated building, not a player build, not toppled, of at least `storeys`.
func _tower(storeys := 4, skip: Array = []) -> int:
	for b in city.registry.buildings:
		if b.is_build() or b.toppled or skip.has(b.id) or _touched.has(b.id) or b.is_damaged():
			continue
		if int(b.recipe.courses) / TowerRecipe.COURSES_PER_FLOOR >= storeys:
			_touched.append(b.id)
			return b.id
	return -1


func _box(id: int) -> AABB:
	return CityPlacer.box_of(city.registry.get_building(id))


# --- (1) ------------------------------------------------------------------------

func _check_shell() -> void:
	print("shell: the box tier only for undamaged buildings")
	var hit := _tower(3)
	var whole := _tower(3, [hit])
	var box := _box(hit)
	city._blast(box.get_center() + Vector3(0, box.size.y * 0.3, 0), 2.5)
	await _drain()
	var b = city.registry.get_building(hit)
	_ok("the hit building is damaged", b.is_damaged())
	city._free_shell(hit)
	city._make_shell(hit, true)
	_ok("asked for the box tier, a damaged building gets the banded shell",
			not bool(city._shell_coarse.get(hit, true)))
	city._free_shell(whole)
	city._make_shell(whole, true)
	_ok("an undamaged one gets the box", bool(city._shell_coarse.get(whole, false)))
	city._free_shell(hit)
	city._free_shell(whole)


# --- (2) ------------------------------------------------------------------------

## Outer rooms of `id` with a fake drawing, and how many of their drawn items
## stand on nothing.
func _fake_state(id: int) -> Dictionary:
	var b = city.registry.get_building(id)
	var rooms := 0
	var stale := 0
	var floating := 0
	for room in city.registry.rooms_of(id):
		if not room.outer or room.fake_buffer.is_empty():
			continue
		rooms += 1
		if room.fake_stamp != b.structure_version:
			stale += 1
		for i in room.items.size():
			if room.gone.has(i):
				continue
			var item: Dictionary = room.items[i]
			if b.is_materialised() and not RoomManifest.item_supported(city.world, b.chunk,
					str(item.type), item.cell as Vector3i):
				floating += 1
	return {"rooms": rooms, "stale": stale, "floating": floating}


func _check_fake() -> void:
	print("fake: a room's fake follows the building's structure")
	var id := _tower(4)
	var box := _box(id)
	var c := box.get_center()
	var cam: Camera3D = city.camera
	var near_at := Vector3(c.x - box.size.x * 0.5 - 50.0, 12.0, c.z)
	# Near enough to fake, too far to draw; its bricks, as a hit would bring them.
	cam.global_position = near_at
	city._promote(id)
	var n := 0
	var st := {}
	while n < 30 * 10:
		await physics_frame
		n += 1
		st = _fake_state(id)
		if int(st.rooms) > 0 and int(st.stale) == 0:
			break
	_ok("its outer rooms are faked", int(st.rooms) > 0, "%s" % [st])

	# Away, out of fake range; then a floor goes, with nobody there.
	cam.global_position = near_at + Vector3(-400.0, 0.0, 0.0)
	await _ticks(20)
	_ok("far off, its fake is dropped", not city._fake_rooms.has(id))
	var b = city.registry.get_building(id)
	var v0: int = b.structure_version
	var slab_y := box.position.y + (1 + 2 * (TowerRecipe.COURSES_PER_FLOOR * 3 + 1)) * BrickPalette.PLATE_M
	var x := box.position.x + 0.8
	while x < box.end.x:
		var z := box.position.z + 0.8
		while z < box.end.z:
			city._blast(Vector3(x, slab_y, z), 1.0)
			z += 1.6
		x += 1.6
	await _drain()
	await _ticks(30)
	_ok("its structure moved on", b.structure_version > v0,
			"version %d -> %d" % [v0, b.structure_version])

	# Given back -- trimmed as a quiet far building is -- and rebuilt on return.
	if b.is_materialised() and not b.toppled:
		city._demote(id, 0.0)
		city._materialised.erase(id)
	cam.global_position = near_at
	if not b.toppled:
		city._promote(id)
	n = 0
	while n < 30 * 10:
		await physics_frame
		n += 1
		st = _fake_state(id)
		if int(st.stale) == 0 and n > 30:
			break
	_ok("back in range, every faked room is redrawn", int(st.stale) == 0, "%s" % [st])
	_ok("and no faked item stands on air", int(st.floating) == 0, "%s" % [st])


# --- (3) ------------------------------------------------------------------------

## Cut building `id` through its second storey, all round and through the
## middle: everything above comes away.
func _undercut(id: int) -> void:
	var box := _box(id)
	var y := box.position.y + (1 + 1 * (TowerRecipe.COURSES_PER_FLOOR * 3 + 1)) * BrickPalette.PLATE_M + 1.2
	# Round the stairwell, not through it: a cut that spares the staircase is the
	# one that left a section hanging on it (Docs/Collapse.md 2.1).
	var shaft := AABB()
	var b = city.registry.get_building(id)
	if b.is_materialised():
		var ids := PackedInt32Array()
		for f in b.fixtures:
			ids.append_array(f.blocks)
		if not ids.is_empty():
			shaft = city.world.get_chunk_transform(b.chunk) * city.world.get_blocks_box(b.chunk, ids)
			_shafts[id] = city.world.get_blocks_box(b.chunk, ids)
			shaft = shaft.grow(1.6)
	var x := box.position.x + 0.6
	while x < box.end.x:
		var z := box.position.z + 0.6
		while z < box.end.z:
			var p := Vector3(x, y, z)
			if shaft.size == Vector3.ZERO or not (p.x > shaft.position.x and p.x < shaft.end.x
					and p.z > shaft.position.z and p.z < shaft.end.z):
				city._blast(p, 1.3)
			z += 2.0
		x += 2.0


func _check_handover() -> void:
	print("handover: a piece leaving a building, drawn exactly once")
	var used: Array = []
	var fresh: Array = []
	var built: Array = []
	for i in 3:
		var id := _tower(4, used)
		if id < 0:
			break
		used.append(id)
		built.append(id)
		city._promote(id)
	await _ticks(30 * 4)
	for i in 3:
		var id := _tower(4, used)
		if id < 0:
			break
		used.append(id)
		fresh.append(id)
	# Stand where it can all be seen, as a player would.
	var c := _box(used[0]).get_center()
	city.camera.global_position = c + Vector3(-40.0, 20.0, -40.0)
	for id in built:
		_undercut(id)
	for id in fresh:
		city._promote(id)
		_undercut(id)
	await _ticks(30 * 12)
	# (4) in the city: no stair block is left standing above an undercut.
	var stairs_left := 0
	var stairless := 0
	for id in used:
		var b = city.registry.get_building(id)
		if b.toppled or not b.is_materialised():
			continue
		var cut_y := (1 + 1 * (TowerRecipe.COURSES_PER_FLOOR * 3 + 1)) * BrickPalette.PLATE_M + 2.5
		var dead := {}
		for bid in city.world.get_dead_blocks(b.chunk):
			dead[bid] = true
		# Cut out into a piece: gone from here, though it still has a box.
		for bid in city.world.get_detached_blocks(b.chunk):
			dead[bid] = true
		var stair := {}
		var here := 0
		for f in b.fixtures:
			for bid in f.blocks:
				stair[bid] = true
				var sb: AABB = city.world.get_blocks_box(b.chunk, PackedInt32Array([bid]))
				if not dead.has(bid) and sb.size != Vector3.ZERO and sb.get_center().y > cut_y:
					here += 1
		# And the floors round the stairwell: anything but stairs still standing
		# above the cut next to the shaft? (Floors on the far side of the
		# building do not make a flight in an empty shaft usable.)
		var near: AABB = (_shafts.get(id, AABB()) as AABB).grow(1.2)
		var floors := 0
		for bx in city.world.get_block_boxes(b.chunk):
			var d: Dictionary = bx
			var p: Vector3 = d.pos
			if bool(d.alive) and not stair.has(int(d.block)) and p.y > cut_y and near.has_point(p):
				floors += 1
		print("  --   building %d: %d stair block(s), %d other box(es) round the stairwell above the cut" % [id, here, floors])
		# Stairs above floors still standing are where they belong; stairs with
		# nothing left round them are the column a section hung on.
		if floors == 0:
			stairs_left += here
		elif here == 0:
			stairless += 1
	_ok("no staircase left standing alone where its floors fell", stairs_left == 0,
			"%d stair block(s) above the cut" % stairs_left)
	_ok("and floors still standing keep their stairs", stairless == 0,
			"%d building(s) with floors and no stairs above the cut" % stairless)
	var hs: Dictionary = city.handover_stats
	print("  --   %s" % [hs])
	_ok("pieces left buildings", int(hs.count) > 0, "%d hand-over(s)" % hs.count)
	_ok("no gap: a piece that left always drawn once its building stopped", int(hs.gap_worst) == 0,
			"worst %d tick(s), %d of %d hand-overs" % [hs.gap_worst, hs.gap_handovers, hs.count])
	_ok("no double: a building stops drawing what it shed", int(hs.double_worst) <= 1,
			"worst %d tick(s), %d of %d hand-overs" % [hs.double_worst, hs.double_handovers, hs.count])


# --- (4) ------------------------------------------------------------------------

## A tower of `courses` with its staircase, alone in a world of its own, built.
func _stair_tower(courses: int) -> Array:
	var w := BrickWorld.new()
	var palette := TowerRecipe.bake_palette(w)
	var reg := BuildingRegistry.new(w, palette)
	var fx := 30
	var fz := 30
	var id := reg.register(fx, fz, courses, Transform3D())
	var sx := TowerRecipe.stair_line(fx)
	var sz := TowerRecipe.stair_line(fz)
	reg.add_fixture(id, "staircase", {"steps": StaircaseRecipe.steps_for_courses(courses),
			"colour": 11}, Vector3i(sx, TowerRecipe.SLAB_PLATES, sz))
	var chunk := reg.materialise(id)
	return [w, reg, id, chunk]


func _check_stairs() -> void:
	print("stairs: a staircase does not hold a building up")
	var t := _stair_tower(30)
	var w: BrickWorld = t[0]
	var reg: BuildingRegistry = t[1]
	var chunk: int = t[3]
	var stair := {}
	for f in reg.get_building(t[2]).fixtures:
		for bid in f.blocks:
			stair[bid] = true
	_ok("the tower has a staircase", stair.size() > 0, "%d stair blocks" % stair.size())
	# Everything in the ground storey but the stairs, gone.
	var storey := (1 + TowerRecipe.COURSES_PER_FLOOR * 3) * BrickPalette.PLATE_M
	var kill := PackedInt32Array()
	var above := 0
	for bx in w.get_block_boxes(chunk):
		var d: Dictionary = bx
		if not bool(d.alive):
			continue
		var bid := int(d.block)
		var y: float = (d.pos as Vector3).y
		if y < storey - 0.2 and y > 0.2 and not stair.has(bid):
			kill.append(bid)
		elif y > storey + 0.5 and not stair.has(bid):
			above += 1
	w.kill_blocks(chunk, kill)
	var grounded := w.solve_grounded(chunk)
	var held := 0
	for bx in w.get_block_boxes(chunk):
		var d: Dictionary = bx
		var bid := int(d.block)
		if bool(d.alive) and not stair.has(bid) and (d.pos as Vector3).y > storey + 0.5 				and bid < grounded.size() and grounded[bid] != 0:
			held += 1
	_ok("with the ground storey gone but for the stairs, nothing above is grounded through them",
			held == 0, "%d of %d block(s) above still grounded" % [held, above])
	var stair_left := 0
	for bx in w.get_block_boxes(chunk):
		var d: Dictionary = bx
		var bid := int(d.block)
		if bool(d.alive) and stair.has(bid) and bid < grounded.size() and grounded[bid] != 0:
			stair_left += 1
	print("  --   stair blocks still grounded: %d of %d" % [stair_left, stair.size()])


# --- (6) ------------------------------------------------------------------------

func _check_fall() -> void:
	print("fall: a drop past 1.5 m hurts; being put somewhere does not")
	var so := _soldier_at(Vector3(-80.0, 0.0, -110.0))
	await _ticks(30)
	so.stop()
	var hp0: float = so.pawn.health.total_current()
	# Lifted 5 m without place(): it falls, as off a ledge.
	so.pawn.body.global_position += Vector3.UP * 5.0
	await _ticks(60)
	var hp1: float = so.pawn.health.total_current()
	_ok("a 5 m fall hurts", hp1 < hp0 and so.pawn.last_fall > 4.0,
			"fell %.1f m, %.0f -> %.0f hp" % [so.pawn.last_fall, hp0, hp1])
	var hp2 := hp1
	so.pawn.place(so.pawn.feet() + Vector3.UP * 5.0)
	await _ticks(60)
	_ok("being placed 5 m up does not", absf(so.pawn.health.total_current() - hp2) < 0.01,
			"%.0f -> %.0f hp" % [hp2, so.pawn.health.total_current()])


## Stairs gone: cut off, then a hole in the wall and a storey's drop out.
func _check_trapped() -> void:
	print("trapped: stairs gone, a soldier is cut off -- until a drop opens")
	var id := _tower(4, [])
	var box := _box(id)
	city.camera.global_position = box.get_center() + Vector3(-40.0, 10.0, 0.0)
	var chunk: int = city._promote(id)
	await _ticks(30)
	var b = city.registry.get_building(id)
	var ids := PackedInt32Array()
	for f in b.fixtures:
		ids.append_array(f.blocks)
	city.world.kill_blocks(chunk, ids)
	city._mark_dirty(id)
	await _drain()
	await _ticks(30)
	var storey_h := (TowerRecipe.COURSES_PER_FLOOR * 3 + 1) * BrickPalette.PLATE_M
	# The SECOND floor: with the stairs dead the shaft is an open drop, but from
	# here it is two storeys -- further than anyone drops.
	var floor_y := box.position.y + (1 + 2 * (TowerRecipe.COURSES_PER_FLOOR * 3 + 1)) * BrickPalette.PLATE_M
	var cz := box.get_center().z
	var inside: Vector3 = city.ai_nav.snap(Vector3(box.position.x + 2.2, floor_y + 0.2, cz))
	var below: Vector3 = city.ai_nav.snap(Vector3(box.position.x + 2.2, box.position.y + 0.4, cz + 2.0))
	_ok("the soldier's spot is on the second floor, the goal on the ground floor",
			absf(inside.y - floor_y) < 0.6 and below.y < 1.0,
			"%.2f against %.2f; below at %.2f" % [inside.y, floor_y, below.y])
	var none: PackedVector3Array = city.ai_nav.find_path(inside, below, 60000)
	_ok("stairs gone, from the second floor there is no way down (the shaft is two storeys)",
			none.is_empty(), "%d waypoints" % none.size())
	var so: Soldier = city._spawn_soldier(inside)
	await _ticks(10)
	so.brain.active = false
	var n := 0
	while not so.trapped and n < 30 * 20:
		so.move_to(below)
		await physics_frame
		n += 1
	_ok("it asks, finds no way, and is trapped", so.trapped, "%.1f s" % (n / 30.0))

	# A hole in its floor a few metres off -- to the side, clear of the stairwell
	# in the middle of the building, which is open all the way down: a storey to
	# the first floor, then the open shaft.
	city._blast(Vector3(box.position.x + 2.2, floor_y, cz + 3.5), 1.0)
	await _drain()
	await _ticks(30)
	var way: PackedVector3Array = city.ai_nav.find_path(so.pawn.feet(), below, 60000)
	var drops := 0
	for i in range(1, way.size()):
		if way[i - 1].y - way[i].y > AINav.SAFE_DROP * BrickPalette.PLATE_M:
			drops += 1
	_ok("a hole in the floor, and there is a way down, a storey's drop at a time",
			not way.is_empty() and drops >= 1, "%d drop(s) over %d waypoints" % [drops, way.size()])
	var hp0: float = so.pawn.health.total_current()
	n = 0
	var r := 0
	while n < 30 * 30:
		r = so.move_to(below)
		await physics_frame
		n += 1
		if r == 1:
			break
	if r != 1:
		var sp: Vector3 = so.pawn.feet()
		print("  --   stuck at %v, wp %d of %s" % [sp, so._wp, so._path])
		if so._wp < so._path.size():
			var nxt: Vector3 = so._path[so._wp]
			var flat := Vector3(nxt.x - sp.x, 0.0, nxt.z - sp.z)
			for hgt in [0.2, 0.9, 1.5]:
				var q := PhysicsRayQueryParameters3D.create(sp + Vector3.UP * hgt,
						sp + Vector3.UP * hgt + flat.normalized() * (flat.length() + 0.6))
				q.exclude = [so.pawn.body.get_rid()]
				var hit := city.get_world_3d().direct_space_state.intersect_ray(q)
				print("  --     toward it at +%.1f m: %s" % [hgt, hit.get("position", "clear")])
	_ok("it looks again, follows it down, and lands hurt", r == 1 and so.pawn.feet().y < 1.0
			and so.pawn.health.total_current() < hp0 and not so.trapped,
			"move_to %d after %.1f s; feet %.2f; %.0f -> %.0f hp" % [r, n / 30.0,
			so.pawn.feet().y, hp0, so.pawn.health.total_current()])

	# Trapped: somewhere there is no way to at all -- another tower's sealed
	# ground floor -- asked for again and again.
	var other := _tower(3, [id])
	var ob := _box(other)
	city._promote(other)
	await _ticks(20)
	var sealed: Vector3 = city.ai_nav.snap(Vector3(ob.get_center().x, ob.position.y + 0.4, ob.get_center().z))
	# On open ground well away from every earlier section's rubble.
	var cut := _soldier_at(Vector3(-110.0, 0.0, -150.0))
	await _ticks(10)
	cut.brain.active = false
	n = 0
	while not cut.trapped and n < 30 * 20:
		cut.move_to(sealed)
		await physics_frame
		n += 1
	_ok("asked again and again for a way there is not, it is trapped", cut.trapped,
			"%.1f s" % (n / 30.0))
	# A few steps from where it stands: there is surely a way there.
	var free: Vector3 = city.ai_nav.snap(cut.pawn.feet() + Vector3(-3.0, 0.0, 0.0))
	n = 0
	var found := false
	while n < 30 * 12:
		cut.move_to(free)
		await physics_frame
		n += 1
		if not cut.trapped and cut._path.size() > 0:
			found = true
			break
	_ok("and when it looks again with a way to go, it is not", found, "%.1f s" % (n / 30.0))


# --- (7) ------------------------------------------------------------------------

func _spawned() -> int:
	var c: Dictionary = city.islands.spawn_census
	return int(c.landmark[0]) + int(c.small[0])


## Bring building `id` down (cut through its second storey) with the camera at
## `eye`, and count the pieces it became.
func _bring_down(id: int, eye: Vector3) -> Dictionary:
	city.camera.global_position = eye
	city.camera.look_at(_box(id).get_center())
	city._promote(id)
	await _ticks(20)
	var s0 := _spawned()
	var f0: int = city.director.far_collapses
	_undercut(id)
	await _ticks(30 * 10)
	return {"pieces": _spawned() - s0, "far": city.director.far_collapses - f0}


func _check_far() -> void:
	print("far: a building coming down where nobody is near comes down coarse")
	var near_id := _tower(5, [])
	var far_id := _tower(5, [])
	var nb := _box(near_id)
	var near := await _bring_down(near_id, nb.get_center() + Vector3(-30.0, 15.0, -30.0))
	var fb := _box(far_id)
	var away := (fb.get_center() - nb.get_center())
	away.y = 0.0
	var far := await _bring_down(far_id, fb.get_center() + away.normalized() * 260.0 + Vector3.UP * 40.0)
	print("  --   near: %s   far: %s" % [near, far])
	_ok("the far one takes the coarse path", int(far.far) > 0 and int(near.far) == 0)
	_ok("and comes down in a few big pieces, far fewer than close by",
			int(far.pieces) <= 4 and int(far.pieces) < int(near.pieces),
			"%d piece(s) far, %d near" % [far.pieces, near.pieces])


# --- (8) ------------------------------------------------------------------------

func _check_shelter() -> void:
	print("shelter: in a storm, soldiers get under a roof and duck the strokes")
	var s: AIServices = city.ai_services
	# The city fills this in with its first soldier; none has been made yet.
	if s.world3d == null:
		s.world3d = city.get_world_3d()
	var id := _tower(4, [])
	var box := _box(id)
	city.camera.global_position = box.get_center() + Vector3(-35.0, 12.0, 0.0)
	city._promote(id)
	# Its brick collision up, every band of it: the top bands come last.
	var w := 0
	while (city._bands_building(id) or w < 30) and w < 30 * 20:
		await physics_frame
		w += 1
	# The TOP storey: only its roof is over it. (Lower down, any slab above
	# counts, and rightly -- a floor two up still keeps the lightning off.)
	var storeys := ceili(float(city.registry.get_building(id).recipe.courses) / TowerRecipe.COURSES_PER_FLOOR)
	var storey_h := (TowerRecipe.COURSES_PER_FLOOR * 3 + 1) * BrickPalette.PLATE_M
	var floor_y := box.position.y + (1 + (storeys - 1) * (TowerRecipe.COURSES_PER_FLOOR * 3 + 1)) * BrickPalette.PLATE_M
	var cz := box.get_center().z
	# A top-storey spot with its roof over it: the first of a few that has one
	# (the roof has openings -- the shaft, a light well -- so do not assume).
	var spot := Vector3.INF
	for off in [Vector2(2.2, 3.0), Vector2(2.2, -3.0), Vector2(3.5, 0.0), Vector2(2.2, 1.5),
			Vector2(4.5, 3.0), Vector2(4.5, -3.0)]:
		var p: Vector3 = city.ai_nav.snap(Vector3(box.position.x + off.x, floor_y + 0.2, cz + off.y))
		if absf(p.y - floor_y) < 0.5 and BTShelter.covered(s, p):
			spot = p
			break
	var street: Vector3 = city.ai_nav.snap(Vector3(box.position.x - 6.0, 0.0, cz))
	_ok("a top-storey room has a roof over it; the street has none",
			spot != Vector3.INF and not BTShelter.covered(s, street), "spot %s" % [spot])
	if spot == Vector3.INF:
		return
	# Its roof blown open over the soldier.
	city._blast(Vector3(spot.x, floor_y + storey_h, spot.z), 1.6)
	await _drain()
	await _ticks(60)
	_ok("with its roof blown open, the spot is under the sky", not BTShelter.covered(s, spot))
	var so: Soldier = city._spawn_soldier(spot)
	await _ticks(30)
	s.storm = true
	var n := 0
	while n < 30 * 15 and not BTShelter.covered(s, so.pawn.feet()):
		await physics_frame
		n += 1
	_ok("in a storm, a soldier under the sky moves under a roof", BTShelter.covered(s, so.pawn.feet()),
			"%.1f s, state '%s', moved %.1f m" % [n / 30.0, so.state, so.pawn.feet().distance_to(spot)])
	s.storm = false
	# Ducking: a stroke about to land beside it.
	var ducked: int = city.disasters.ctx.duck_near(so.pawn.feet() + Vector3(3.0, 0.0, 0.0), 12.0, 1.5)
	await _ticks(6)
	_ok("a stroke's leader beside it: it gets low", ducked == 1 and so.pawn.is_crouched(),
			"%d ducked, crouched %s" % [ducked, so.pawn.is_crouched()])
	await _ticks(60)
	_ok("and stands again after", not so.pawn.is_crouched())


# --- Weather and riding ---------------------------------------------------------

func _check_weather() -> void:
	print("weather: eyes a little, hands a lot")
	var s: AIServices = city.ai_services
	var ctx: DisasterContext = city.disasters.ctx
	var a := _soldier_at(Vector3(-100.0, 0.0, -180.0))
	var b := _soldier_at(Vector3(-100.0, 0.0, -125.0))
	await _ticks(20)
	a.brain.active = false
	b.brain.active = false
	a.stop()
	b.stop()
	var to := b.pawn.chest() - a.eye_pos()
	a.pawn.intents.look_yaw = atan2(-to.x, -to.z)
	await _ticks(5)
	var d := a.eye_pos().distance_to(b.pawn.chest())
	var clear_sees: bool = a.can_see(b.pawn)
	ctx.set_weather(1.0, 0.85, 2.2)
	var storm_sees: bool = a.can_see(b.pawn)
	_ok("at %.0f m it sees in clear weather, not in a storm (%.0f m sight)" % [d, 60.0 * s.sight_mul],
			clear_sees and not storm_sees)
	var aim := AimModel.new(RandomNumberGenerator.new())
	aim.track(b.pawn, 0.0)
	var clear_cone := aim.cone_deg(0.5)
	aim.weather = s.aim_mul
	_ok("its aim is much worse", absf(aim.cone_deg(0.5) - clear_cone * 2.2) < 0.01,
			"cone %.1f -> %.1f deg" % [clear_cone, aim.cone_deg(0.5)])
	ctx.set_weather(0.0, 1.0, 1.0)
	_ok("and clear again, all as it was", s.sight_mul == 1.0 and s.aim_mul == 1.0)
	# A real storm sets it, and leaves it clear.
	city.disasters.start("lightning")
	var st: Disaster = city.disasters.current
	var n := 0
	while st.phase != Disaster.Phase.ACTIVE and n < 30 * 10:
		await physics_frame
		n += 1
	await _ticks(10)
	var mid := [s.sight_mul, s.aim_mul]
	city.disasters.stop()
	n = 0
	while city.disasters.is_running() and n < 30 * 15:
		await physics_frame
		n += 1
	_ok("a lightning storm: sight %.2f, aim x%.1f while it rages; clear when it is over" % mid,
			float(mid[0]) < 0.9 and float(mid[1]) > 2.0 and s.sight_mul == 1.0 and s.aim_mul == 1.0)
	await _until_quiet()


func _until_quiet() -> void:
	if city.disasters.fire.is_burning():
		city.disasters.fire.douse()
	var n := 0
	while city.disasters.fire.is_burning() and n < 30 * 20:
		await physics_frame
		n += 1


func _check_carried() -> void:
	print("carried: a soldier on something moving goes with it, and is thrown when it stops")
	var at := Vector3(-140.0, 0.0, -200.0)
	city.camera.look_at_from_position(at + Vector3(12.0, 8.0, 12.0), at)
	var slab := _drop(at + Vector3(-2.1, 0.02, -2.1), 12, 12, 1)
	await _ticks(40)
	var top: float = city.islands.world_aabb(slab).end.y
	var so := _soldier_at(Vector3(at.x, 0.0, at.z))
	so.pawn.place(Vector3(at.x, top + 0.05, at.z))
	await _ticks(20)
	so.brain.active = false
	so.stop()
	# Awake, and kept from settling while it is pushed (it had frozen at rest).
	city.islands.hold_awake(slab, 5000)
	await _ticks(2)
	var p0: Vector3 = slab.body.global_position
	var s0: Vector3 = so.pawn.feet()
	for i in 45:
		slab.body.linear_velocity = Vector3(4.0, 0.0, 0.0)
		slab.body.sleeping = false
		await physics_frame
	var moved: float = slab.body.global_position.x - p0.x
	var carried: float = so.pawn.feet().x - s0.x
	_ok("it moves with the slab under it", moved > 3.0 and carried > moved * 0.6,
			"slab %.1f m, soldier %.1f m, %d ride tick(s)" % [moved, carried, city.crush.rides])
	# Stopped dead: the soldier is not.
	var throws0: int = city.crush.throws
	slab.body.linear_velocity = Vector3.ZERO
	await _ticks(1)
	var kept: Vector3 = so.pawn.shove
	var s1: Vector3 = so.pawn.feet()
	await _ticks(10)
	# (How far it then goes is up to what is in the way -- this slab has a rim.)
	_ok("stopped dead, it keeps going: thrown with what it was carried at",
			city.crush.throws > throws0 and kept.x > 3.0,
			"shove %.1f m/s after the stop; %.1f m on" % [kept.x, so.pawn.feet().x - s1.x])


# --- Cut-free tops ------------------------------------------------------------------

## Cut tower `id` through at the joint over storey `storey`, as a SEVER.
func _sever(id: int, storey: int) -> float:
	var b = city.registry.get_building(id)
	var chunk: int = city._promote(id)
	var fx := float(b.recipe.footprint_x) * BrickPalette.STUD_M
	var fz := float(b.recipe.footprint_z) * BrickPalette.STUD_M
	var y := (1 + storey * (TowerRecipe.COURSES_PER_FLOOR * 3 + 1)) * BrickPalette.PLATE_M
	var cut: Vector3 = b.xform * Vector3(fx * 0.5, y, fz * 0.5)
	city.world.separate_plane(chunk, cut, Vector3.UP, 0.14)
	city.authority.commit(Engine.get_physics_frames(), DamageLog.Kind.SEVER, id, cut, 0.14, Vector3.UP)
	city._mark_dirty(id)
	return cut.y


## The biggest piece above `cut_y` inside `box`.
func _top_piece(box: AABB, cut_y: float) -> BrickIsland:
	var best: BrickIsland = null
	var most := 0
	for isl in city.islands.islands:
		if not isl.is_valid() or not is_instance_valid(isl.body):
			continue
		var p: Vector3 = isl.body.global_position
		if p.y < cut_y or not box.grow(1.0).has_point(p):
			continue
		var n: int = city.world.get_alive_block_count(isl.chunk)
		if n > most:
			most = n
			best = isl
	return best


## How many of a piece's bricks are inside some OTHER static body.
func _overlaps(isl: BrickIsland) -> Dictionary:
	var xf: Transform3D = city.world.get_chunk_transform(isl.chunk)
	var q := PhysicsPointQueryParameters3D.new()
	q.collision_mask = 0xFFFFFFFF
	q.exclude = [isl.body.get_rid()]
	var sp := city.get_world_3d().direct_space_state
	var n := 0
	var hit := 0
	var what := {}
	for bx in city.world.get_block_boxes(isl.chunk):
		var d: Dictionary = bx
		if not bool(d.alive):
			continue
		n += 1
		if n % 7 != 0:
			continue
		q.position = xf * (d.pos as Vector3)
		for h in sp.intersect_point(q, 4):
			hit += 1
			var c = h.collider
			var name := str(c.name) if c is Node else "rid"
			what[name] = int(what.get(name, 0)) + 1
			break
	return {"sampled": n / 7, "inside_other": hit, "what": what}


func _check_tops() -> void:
	print("tops: a tower cut through at a slab -- does the freed top move?")
	for storeys in [5, 7]:
		var id := _tower(storeys, [])
		if id < 0:
			continue
		var box := _box(id)
		city.camera.look_at_from_position(box.get_center() + Vector3(-40.0, 15.0, -40.0), box.get_center())
		city._promote(id)
		var w := 0
		while (city._bands_building(id) or w < 30) and w < 30 * 20:
			await physics_frame
			w += 1
		var cut_y := _sever(id, 1)
		var top: BrickIsland = null
		var n := 0
		while top == null and n < 30 * 3:
			await physics_frame
			n += 1
			top = _top_piece(box, cut_y)
		if top == null:
			_ok("building %d: a top came free" % id, false)
			continue
		await _ticks(5)
		var ov := _overlaps(top)
		var bricks: int = city.world.get_alive_block_count(top.chunk)
		print("  --   building %d (%d storeys): top %d bricks, merged %s, settled %s, inside other bodies: %s" % [
				id, storeys, bricks, top.merged, top.settled, ov])
		# Stairs of the building below reaching up into the freed top's shaft?
		var b_now = city.registry.get_building(id)
		var gone := {}
		for bid in city.world.get_dead_blocks(b_now.chunk):
			gone[bid] = true
		for bid in city.world.get_detached_blocks(b_now.chunk):
			gone[bid] = true
		var up_into := 0
		var up_top := -INF
		var bxf: Transform3D = city.world.get_chunk_transform(b_now.chunk)
		for f in b_now.fixtures:
			for bid in f.blocks:
				if gone.has(bid):
					continue
				var sb: AABB = bxf * city.world.get_blocks_box(b_now.chunk, PackedInt32Array([bid]))
				if sb.end.y > cut_y + 0.3:
					up_into += 1
					up_top = maxf(up_top, sb.end.y)
		_ok("building %d: none of the staircase below reaches up into the freed top" % id, up_into == 0,
				"%d stair block(s) up to %.1f m, cut at %.1f" % [up_into, up_top, cut_y])
		# What would be OUR bug: the top overlapping the building it came off
		# (stale collision), frozen, or its rotation locked. None of these.
		var bd: RigidBody3D = top.body
		_ok("building %d: its %d-brick top is free -- overlaps nothing, not frozen, no locked axis" % [
				id, bricks], int(ov.inside_other) == 0 and not bd.freeze and not bd.lock_rotation
				and not (bd.axis_lock_angular_x or bd.axis_lock_angular_y or bd.axis_lock_angular_z),
				"%s" % [ov])
		# And pushed, it turns. It did not, at all, for as long as the staircase
		# of the building below ran up through its stairwell -- a rod through a
		# bead (Docs/Collapse.md 6).
		var tilt := 0.0
		city.islands.hold_awake(top, 3000)
		for k in 30:
			bd.angular_velocity = Vector3(0, 0, -0.6)
			bd.sleeping = false
			await physics_frame
			tilt = maxf(tilt, rad_to_deg(acos(clampf(bd.global_basis.y.dot(Vector3.UP), -1.0, 1.0))))
		_ok("building %d: pushed over, it turns" % id, tilt > 10.0, "%.1f deg in a second" % tilt)


# --- A soldier inside a building that topples --------------------------------------

func _check_inside_topple() -> void:
	print("inside: a soldier in a building that topples is carried, thrown, hurt -- never left in it")
	var id := _tower(5, [])
	var box := _box(id)
	var c := box.get_center()
	city.camera.look_at_from_position(c + Vector3(-45.0, 20.0, -45.0), c)
	city._promote(id)
	var w := 0
	while (city._bands_building(id) or w < 30) and w < 30 * 20:
		await physics_frame
		w += 1
	var floor_y := box.position.y + (1 + 2 * (TowerRecipe.COURSES_PER_FLOOR * 3 + 1)) * BrickPalette.PLATE_M
	# Off the middle: the stairwell is there, open to the ground.
	var at: Vector3 = city.ai_nav.snap(Vector3(c.x - box.size.x * 0.3, floor_y + 0.2, c.z + box.size.z * 0.3))
	_ok("the soldier stands on the second floor", absf(at.y - floor_y) < 0.5, "%.2f / %.2f" % [at.y, floor_y])
	var so: Soldier = city._spawn_soldier(at)
	await _ticks(10)
	so.brain.active = false
	so.stop()
	var start: Vector3 = so.pawn.feet()
	var hp0: float = so.pawn.health.total_current()
	var rides0: int = city.crush.rides
	# The earthquake's soft storey: the ground storey blasted out on one side,
	# most of the way across -- the city's own topple does the rest.
	var y := box.position.y + 0.7
	var dd := 0.0
	while dd <= box.size.x * 0.85:
		var zz := -box.size.z * 0.5 + 0.4
		while zz <= box.size.z * 0.5 - 0.4:
			city._blast(Vector3(box.end.x - 0.3 - dd, y, c.z + zz), 1.1)
			zz += 1.5
		dd += 1.5
	var b = city.registry.get_building(id)
	var n := 0
	while not b.toppled and n < 30 * 10:
		await physics_frame
		n += 1
	_ok("the building topples", b.toppled, "%.1f s" % (n / 30.0))
	# Over its undermined (+x) edge, as the earthquake helps it (Earthquake.tip).
	var piece: BrickIsland = null
	var most := 0
	for isl in city.islands.islands:
		if isl.is_valid() and is_instance_valid(isl.body) and box.grow(4.0).has_point(isl.body.global_position):
			var k: int = city.world.get_alive_block_count(isl.chunk)
			if k > most:
				most = k
				piece = isl
	var pushed := 0.0
	for k in 30 * 4:
		if piece == null or not piece.is_valid():
			break
		pushed = maxf(pushed, rad_to_deg(acos(clampf(piece.body.global_basis.y.dot(Vector3.UP), -1.0, 1.0))))
		if rad_to_deg(acos(clampf(piece.body.global_basis.y.dot(Vector3.UP), -1.0, 1.0))) > Earthquake.TIP_ANGLE:
			break
		city.islands.hold_awake(piece, 500)
		Earthquake.tip(piece, Vector3.RIGHT, box)
		await physics_frame
	await _ticks(30 * 6)
	var tilt := 0.0
	for isl in city.islands.islands:
		if isl.is_valid() and is_instance_valid(isl.body) and city.world.get_alive_block_count(isl.chunk) > 500 				and box.grow(12.0).has_point(isl.body.global_position):
			tilt = maxf(tilt, rad_to_deg(acos(clampf(isl.body.global_basis.y.dot(Vector3.UP), -1.0, 1.0))))
	print("  --   pushed to %.0f deg; soldier now at %v (started %v)" % [pushed, so.pawn.feet(), start])
	var moved: float = so.pawn.feet().distance_to(start)
	var embedded := false
	for isl in city.islands.islands:
		if isl.is_valid() and is_instance_valid(isl.body) and not so.is_dead() 				and city.crush._inside(isl, [so.pawn.feet() + Vector3.UP * 0.3, so.pawn.chest()]):
			embedded = true
	_ok("the soldier rode it as it went over", city.crush.rides > rides0 and moved > 1.0,
			"moved %.1f m, %d ride tick(s)" % [moved, city.crush.rides - rides0])
	var fell := start.y - so.pawn.feet().y
	var should_hurt := so.pawn.last_fall > Pawn.SAFE_FALL + 0.3
	_ok("and was not left inside it; hurt if it fell far enough to be",
			not embedded and (not should_hurt or so.is_dead() or so.pawn.health.total_current() < hp0),
			"dropped %.1f m (last fall %.1f m), %.0f -> %.0f hp, dead %s, inside %s" % [fell,
			so.pawn.last_fall, hp0, so.pawn.health.total_current(), so.is_dead(), embedded])
