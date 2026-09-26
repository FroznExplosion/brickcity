extends SceneTree

## BuildingCollision: a standing building's collision as one static body per
## band of the building, so a hit rebuilds the band it landed in and not the
## whole tower.
##
##     godot --headless --path . --script tools/building_collision_probe.gd
##
## Checks the bands hold exactly what one body held -- every brick's box in one
## band and only one, the band BrickWorld says it is in -- that a hit un-merges
## and switches off only the bands it touched, and that a quiet building merges
## back a band at a time. `-- --time` adds what the old whole-building rebuild
## and the band rebuild cost on the big city's tower sizes.

var passed := 0
var failed := 0
var _space: RID


func _init() -> void:
	print("building collision: a body a band")
	_space = get_root().get_world_3d().space
	_check_small()
	_check_bands()
	_check_hit()
	if OS.get_cmdline_user_args().has("--time"):
		_time()
	print("\n%d passed, %d failed" % [passed, failed])
	quit(1 if failed > 0 else 0)


func _ok(what: String, cond: bool, detail := "") -> void:
	if cond:
		passed += 1
		print("  ok   %s" % what)
	else:
		failed += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


## A tower, banded the way CityScene._section_plates bands one.
func _tower(x: int, z: int, courses: int) -> Array:
	var w := BrickWorld.new()
	var palette := TowerRecipe.bake_palette(w)
	var chunk := w.create_chunk(Vector3i.ZERO, TowerRecipe.chunk_dims(x, z, courses))
	TowerRecipe.build(w, chunk, palette, x, z, courses)
	w.set_chunk_transform(chunk, Transform3D.IDENTITY)
	w.set_tension_per_stud(chunk, 9.3)
	var plates: int = w.get_chunk_dims(chunk).y
	@warning_ignore("integer_division")
	w.set_chunk_section_plates(chunk, maxi(24, (plates + 15) / 16))
	return [w, chunk]


## What one body for the whole building holds.
func _one_body(w: BrickWorld, chunk: int, merge: bool) -> Array:
	var body := PhysicsServer3D.body_create()
	var built: Dictionary = w.add_chunk_shapes(body, chunk, Vector3.ZERO, merge, merge)
	return [body, built]


func _check_small() -> void:
	print("\na building of one band is one body, as it always was")
	var r := _tower(8, 8, 4)
	var w: BrickWorld = r[0]
	var chunk: int = r[1]
	_ok("a short building is one band", w.get_chunk_sections(chunk) == 1,
			"%d" % w.get_chunk_sections(chunk))
	var col := BuildingCollision.new(w, chunk, _space, Transform3D.IDENTITY, false)
	var one := _one_body(w, chunk, false)
	_ok("one body", col.bodies.size() == 1)
	_ok("the same boxes one body had", col.shape_count() == int(one[1].count),
			"%d against %d" % [col.shape_count(), int(one[1].count)])
	PhysicsServer3D.free_rid(one[0])
	col.free_bodies()


func _check_bands() -> void:
	print("\na tall building is a body a band, holding what one body held")
	var r := _tower(20, 16, 60)
	var w: BrickWorld = r[0]
	var chunk: int = r[1]
	var n := w.get_chunk_sections(chunk)
	_ok("a tall building has several bands", n > 1, "%d" % n)
	var col := BuildingCollision.new(w, chunk, _space, Transform3D.IDENTITY, false)
	_ok("a body a band", col.bodies.size() == n, "%d bodies, %d bands" % [col.bodies.size(), n])
	var one := _one_body(w, chunk, false)
	_ok("the bands hold as many boxes as one body did", col.shape_count() == int(one[1].count),
			"%d against %d" % [col.shape_count(), int(one[1].count)])
	# Every block in exactly one band's map, and in the band the world says.
	var ids := PackedInt32Array()
	for bid in w.get_block_count(chunk):
		ids.append(bid)
	var says := w.get_block_sections(chunk, ids)
	var one_map: Dictionary = one[1].map
	var wrong := 0
	var twice := 0
	var missing := 0
	for bid in ids:
		var found := -1
		for si in n:
			if col.maps[si].has(bid):
				if found >= 0:
					twice += 1
				found = si
		if one_map.has(bid) and found < 0:
			missing += 1
		elif found >= 0 and found != says[bid]:
			wrong += 1
	_ok("every brick's box is in a band", missing == 0, "%d missing" % missing)
	_ok("and in only one", twice == 0, "%d twice" % twice)
	_ok("the band BrickWorld says the brick is in", wrong == 0, "%d elsewhere" % wrong)
	var empty := PackedInt32Array()
	for si in n:
		if PhysicsServer3D.body_get_shape_count(col.bodies[si]) == 0:
			empty.append(si)
	# The chunk is a little taller than the tower (headroom for the roof), so
	# its top band can hold nothing. No other band may.
	_ok("no band but the top one is empty", empty.is_empty() or (empty.size() == 1 and empty[0] == n - 1),
			"empty: %s of %d; %d plates, bands of %d" % [empty, n, w.get_chunk_dims(chunk).y,
			maxi(24, (w.get_chunk_dims(chunk).y + 15) / 16)])
	PhysicsServer3D.free_rid(one[0])
	col.free_bodies()

	var merged_col := BuildingCollision.new(w, chunk, _space, Transform3D.IDENTITY, true)
	var one_m := _one_body(w, chunk, true)
	_ok("merged, every band is merged", merged_col.all_merged())
	_ok("merged bands are far fewer boxes than a box a brick",
			merged_col.shape_count() * 4 < int(one[1].count),
			"%d merged against %d" % [merged_col.shape_count(), int(one[1].count)])
	# A merge cannot run across a band boundary, so a few more boxes than one
	# body merged -- not many.
	_ok("and not many more than one body merged",
			merged_col.shape_count() <= int(one_m[1].count) * 2,
			"%d against %d" % [merged_col.shape_count(), int(one_m[1].count)])
	PhysicsServer3D.free_rid(one_m[0])
	merged_col.free_bodies()


func _check_hit() -> void:
	print("\na hit un-merges and switches off only the bands it touched")
	var r := _tower(20, 16, 60)
	var w: BrickWorld = r[0]
	var chunk: int = r[1]
	var n := w.get_chunk_sections(chunk)
	var col := BuildingCollision.new(w, chunk, _space, Transform3D.IDENTITY, true)
	# Low on one wall: the ground floor's band.
	var killed: PackedInt32Array = w.apply_hit(chunk, Vector3(3.0, 1.0, 0.2), 1.5)
	_ok("the hit killed bricks", killed.size() > 0, "%d" % killed.size())
	var bands := col.bands_of(killed)
	col.disable(killed)
	var unmerged := 0
	for si in n:
		if not col.merged[si]:
			unmerged += 1
	_ok("only the bands it landed in were un-merged", unmerged == bands.size() and unmerged < n,
			"%d un-merged, hit %d of %d" % [unmerged, bands.size(), n])
	_ok("so one rebuild a band, not the building", col.reshapes == bands.size(),
			"%d rebuilds" % col.reshapes)
	# The dead have no live box: none at all (built skip_dead), or switched off.
	var pos_of := {}
	for box in w.get_block_boxes(chunk):
		pos_of[int(box.block)] = box.pos
	var live := _live_boxes(col, killed, pos_of)
	_ok("the dead bricks have no live box", live == 0, "%d live" % live)
	# And the query can see a box at all: a brick nobody touched is solid.
	var sample := PackedInt32Array()
	for bid in (col.maps[bands[0]] as Dictionary):
		if not killed.has(bid):
			sample.append(bid)
			break
	_ok("a brick nobody touched is still solid", _live_boxes(col, sample, pos_of) == 1)

	# A second hit in the same band: already a box a brick, so no rebuild --
	# switched off shape by shape.
	var before := col.reshapes
	var killed2: PackedInt32Array = w.apply_hit(chunk, Vector3(5.0, 1.0, 0.2), 1.5)
	# Detached-group style: bricks still alive, handed over to a piece.
	var alive_ids := PackedInt32Array()
	var map0: Dictionary = col.maps[bands[0]]
	for bid in map0:
		if alive_ids.size() >= 20:
			break
		if w.get_block_hp(chunk, bid) > 0:
			alive_ids.append(bid)
	col.disable(killed2)
	col.disable(alive_ids)
	_ok("a band already a box a brick is not rebuilt again", col.reshapes == before,
			"%d rebuilds" % (col.reshapes - before))
	_ok("the probe found bricks still alive to cut out", alive_ids.size() > 0)
	var still := _live_boxes(col, alive_ids, pos_of)
	_ok("bricks cut out alive are switched off one at a time", still == 0,
			"%d of %d still solid" % [still, alive_ids.size()])

	# Quiet again: merged back one band a call.
	var steps := 0
	while col.merge_next():
		steps += 1
	_ok("a quiet building merges back a band at a time", steps == unmerged and col.all_merged(),
			"%d steps for %d bands" % [steps, unmerged])
	var owns := true
	for body in col.bodies:
		owns = owns and col.owns(body)
	_ok("it knows its own bodies", owns and not col.owns(RID()))
	col.free_bodies()


## How many of these blocks' own boxes a point query at the block still finds:
## a switched-off shape is not found.
func _live_boxes(col: BuildingCollision, ids: PackedInt32Array, pos_of: Dictionary) -> int:
	var state := PhysicsServer3D.space_get_direct_state(_space)
	var live := 0
	for bid in ids:
		if not pos_of.has(bid):
			continue
		var q := PhysicsPointQueryParameters3D.new()
		q.position = pos_of[bid]
		q.collision_mask = Layers.STRUCTURE
		for hit in state.intersect_point(q, 64):
			var si := col.bodies.find(hit.rid)
			if si < 0:
				continue
			var map: Dictionary = col.maps[si]
			if map.has(bid) and (map[bid] as PackedInt32Array).has(int(hit.shape)):
				live += 1
	return live


## The old whole-building rebuild against a band's, on the big city's sizes.
func _time() -> void:
	print("\nwhat the first hit's collision rebuild costs")
	for s in [[40, 30, 60], [60, 40, 162], [80, 60, 204]]:
		var r := _tower(s[0], s[1], s[2])
		var w: BrickWorld = r[0]
		var chunk: int = r[1]
		var hit := Vector3(3.0, 1.0, 0.2)
		var killed: PackedInt32Array = w.apply_hit(chunk, hit, 1.5)
		# Old: one body, merged, un-merged whole.
		var body := PhysicsServer3D.body_create()
		PhysicsServer3D.body_set_mode(body, PhysicsServer3D.BODY_MODE_STATIC)
		w.add_chunk_shapes(body, chunk, Vector3.ZERO, true, true)
		PhysicsServer3D.body_set_space(body, _space)
		var t := Time.get_ticks_usec()
		PhysicsServer3D.body_set_space(body, RID())
		PhysicsServer3D.body_clear_shapes(body)
		var built: Dictionary = w.add_chunk_shapes(body, chunk, Vector3.ZERO, true, false)
		var t_add := Time.get_ticks_usec()
		PhysicsServer3D.body_set_space(body, _space)
		var t_old := Time.get_ticks_usec()
		# And the disable that follows, one body.
		var t2 := Time.get_ticks_usec()
		PhysicsServer3D.body_set_space(body, RID())
		var map: Dictionary = built.map
		var probe_ids := PackedInt32Array()
		for bid in map:
			probe_ids.append(bid)
			if probe_ids.size() >= 30:
				break
		for bid in probe_ids:
			for idx in map[bid]:
				PhysicsServer3D.body_set_shape_disabled(body, idx, true)
		PhysicsServer3D.body_set_space(body, _space)
		var t_old_dis := Time.get_ticks_usec()
		PhysicsServer3D.free_rid(body)

		# New: a body a band, merged; the hit un-merges its band.
		var col := BuildingCollision.new(w, chunk, _space, Transform3D.IDENTITY, true)
		var t3 := Time.get_ticks_usec()
		col.disable(killed)
		var t_new := Time.get_ticks_usec()
		col.disable(probe_ids)
		var t_new_dis := Time.get_ticks_usec()
		print("  %dx%dx%d, %5d blocks, %2d bands: un-merge whole %5.1f ms (shapes %4.1f + space %4.1f), band %4.1f ms; switch 30 off: whole %4.1f ms, band %4.1f ms" % [
				s[0], s[1], s[2], w.get_block_count(chunk), col.bodies.size(),
				float(t_old - t) / 1000.0, float(t_add - t) / 1000.0, float(t_old - t_add) / 1000.0,
				float(t_new - t3) / 1000.0,
				float(t_old_dis - t2) / 1000.0, float(t_new_dis - t_new) / 1000.0])
		col.free_bodies()
