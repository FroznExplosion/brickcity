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
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


## A generated building, not a player build, not toppled, of at least `storeys`.
func _tower(storeys := 4, skip: Array = []) -> int:
	for b in city.registry.buildings:
		if b.is_build() or b.toppled or skip.has(b.id):
			continue
		if int(b.recipe.courses) / TowerRecipe.COURSES_PER_FLOOR >= storeys:
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
	var x := box.position.x + 0.6
	while x < box.end.x:
		var z := box.position.z + 0.6
		while z < box.end.z:
			city._blast(Vector3(x, y, z), 1.3)
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
	for id in used:
		var b = city.registry.get_building(id)
		if b.toppled or not b.is_materialised():
			continue
		var cut_y := (1 + 1 * (TowerRecipe.COURSES_PER_FLOOR * 3 + 1)) * BrickPalette.PLATE_M + 2.5
		var dead := {}
		for bid in city.world.get_dead_blocks(b.chunk):
			dead[bid] = true
		for f in b.fixtures:
			for bid in f.blocks:
				var sb: AABB = city.world.get_blocks_box(b.chunk, PackedInt32Array([bid]))
				if not dead.has(bid) and sb.size != Vector3.ZERO and sb.get_center().y > cut_y:
					stairs_left += 1
	_ok("no stair left standing above a cut-off section", stairs_left == 0,
			"%d stair block(s) above the cut" % stairs_left)
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
