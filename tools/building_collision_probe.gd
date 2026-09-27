extends SceneTree

## BuildingCollision: a standing building's collision as one static body per
## band of the building, so a hit rebuilds the band it landed in and not the
## whole tower.
##
##     godot --headless --path . --script tools/building_collision_probe.gd
##
## Checks the bands hold exactly what one body held -- every brick's box in one
## band and only one, the band BrickWorld says it is in -- that a hit rebuilds
## only the bands it touched (a merged band merged again at flush, a band of a
## box a brick switched off at once), and that a quiet building merges back a
## band at a time. `-- --time` adds what the old whole-building rebuild
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
	_check_furniture()
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
	print("
a hit rebuilds only the bands it touched")
	var r := _tower(20, 16, 60)
	var w: BrickWorld = r[0]
	var chunk: int = r[1]
	var n := w.get_chunk_sections(chunk)
	var pos_of := {}
	for box in w.get_block_boxes(chunk):
		pos_of[int(box.block)] = box.pos

	# Merged: the band goes stale, and is merged again at flush.
	var col := BuildingCollision.new(w, chunk, _space, Transform3D.IDENTITY, true)
	# Low on one wall: the ground floor's band.
	var killed: PackedInt32Array = w.apply_hit(chunk, Vector3(3.0, 1.0, 0.2), 1.5)
	_ok("the hit killed bricks", killed.size() > 0, "%d" % killed.size())
	var bands := col.bands_of(killed)
	col.disable(killed)
	var stale := 0
	for si in n:
		if col.stale[si]:
			stale += 1
	_ok("a merged band hit is marked stale, not rebuilt on the spot",
			stale == bands.size() and col.reshapes == 0, "%d stale, %d rebuilds" % [stale, col.reshapes])
	col.flush()
	_ok("flush merges again only the bands it landed in", col.reshapes == bands.size()
			and col.all_merged() and not col.any_stale(), "%d rebuilds for %d bands" % [col.reshapes, bands.size()])
	_ok("the dead bricks are not solid any more", _solid(col, killed, pos_of) == 0,
			"%d solid" % _solid(col, killed, pos_of))
	# And the query can see a box at all: a brick nobody touched is solid.
	var sample := PackedInt32Array()
	var said := w.get_block_sections(chunk, PackedInt32Array(range(w.get_block_count(chunk))))
	for bid in w.get_block_count(chunk):
		if said[bid] == bands[0] and not killed.has(bid) and w.get_block_hp(chunk, bid) > 0:
			sample.append(bid)
			if sample.size() >= 5:
				break
	_ok("bricks nobody touched are still solid", _solid(col, sample, pos_of) == sample.size(),
			"%d of %d" % [_solid(col, sample, pos_of), sample.size()])

	# A piece cut out of a merged band: stale until flush, by when the piece
	# has taken its bricks, and they are left out.
	var before := col.reshapes
	col.disable(sample)
	w.split_island(chunk, sample)
	col.flush()
	_ok("a piece cut out of a merged band is one rebuild of that band", col.reshapes == before + 1,
			"%d rebuilds" % (col.reshapes - before))
	_ok("and its bricks are not solid in the building any more", _solid(col, sample, pos_of) == 0)

	# More stale than the budget: the rest are parked out of the space until
	# their turn, so their stale boxes cannot overlap a piece cut out of them.
	for si in n:
		col.stale[si] = true
	var done := col.flush(2)
	var out := 0
	for si in n:
		if not PhysicsServer3D.body_get_space(col.bodies[si]).is_valid():
			out += 1
	_ok("a flush over budget merges the budget's worth", done == 2, "%d" % done)
	_ok("and parks the rest out of the space", out == n - 2 and col.parked.count(true) == n - 2,
			"%d out, %d parked" % [out, col.parked.count(true)])
	col.flush()
	out = 0
	for si in n:
		if not PhysicsServer3D.body_get_space(col.bodies[si]).is_valid():
			out += 1
	_ok("which go back in when their turn comes", out == 0 and not col.any_stale()
			and not col.parked.has(true), "%d still out" % out)
	col.free_bodies()

	# A box a brick (a building made bricks by a hit): switched off at once.
	var r2 := _tower(20, 16, 60)
	var w2: BrickWorld = r2[0]
	var c2: int = r2[1]
	var per := BuildingCollision.new(w2, c2, _space, Transform3D.IDENTITY, false)
	var k2: PackedInt32Array = w2.apply_hit(c2, Vector3(3.0, 1.0, 0.2), 1.5)
	per.disable(k2)
	_ok("a band a box a brick is not rebuilt for a hit", per.reshapes == 0 and not per.any_stale(),
			"%d rebuilds" % per.reshapes)
	_ok("its dead bricks are switched off at once", _live_boxes(per, k2, pos_of) == 0)
	var alive_ids := PackedInt32Array()
	var map0: Dictionary = per.maps[per.bands_of(k2)[0]]
	for bid in map0:
		if alive_ids.size() >= 20:
			break
		if w2.get_block_hp(c2, bid) > 0:
			alive_ids.append(bid)
	per.disable(alive_ids)
	_ok("bricks cut out alive are switched off one at a time",
			alive_ids.size() > 0 and _live_boxes(per, alive_ids, pos_of) == 0,
			"%d of %d still solid" % [_live_boxes(per, alive_ids, pos_of), alive_ids.size()])

	# Quiet again: merged back one band a call.
	var steps := 0
	while per.merge_next():
		steps += 1
	_ok("a quiet building merges back a band at a time", steps == n and per.all_merged(),
			"%d steps for %d bands" % [steps, n])
	var owns := true
	for body in per.bodies:
		owns = owns and per.owns(body)
	_ok("it knows its own bodies", owns and not per.owns(RID()))
	per.free_bodies()


## Furniture has a body of its own (CityScene._room_body): it is in no band, and
## shutting a room does not rebuild the band it stood in.
func _check_furniture() -> void:
	print("\nfurniture is not the building's collision")
	var r := _tower(20, 16, 60)
	var w: BrickWorld = r[0]
	var chunk: int = r[1]
	var pos_of := {}
	for box in w.get_block_boxes(chunk):
		pos_of[int(box.block)] = box.pos
	# Stand-ins for a room's contents: some of the building's own bricks,
	# marked as furniture.
	var chairs := PackedInt32Array()
	for bid in range(200, 212):
		chairs.append(bid)
	w.set_blocks_decorative(chunk, chairs, true)
	var col := BuildingCollision.new(w, chunk, _space, Transform3D.IDENTITY, true)
	_ok("furniture is in no band", _solid(col, chairs, pos_of) == 0,
			"%d solid" % _solid(col, chairs, pos_of))
	col.disable(chairs)
	_ok("so taking it away leaves every band as it was",
			not col.any_stale() and col.reshapes == 0)
	col.free_bodies()


## How many of these blocks a point query at the block's centre finds any of
## the building's boxes at -- merged or not.
func _solid(col: BuildingCollision, ids: PackedInt32Array, pos_of: Dictionary) -> int:
	var state := PhysicsServer3D.space_get_direct_state(_space)
	var solid := 0
	for bid in ids:
		if not pos_of.has(bid):
			continue
		var q := PhysicsPointQueryParameters3D.new()
		q.position = pos_of[bid]
		q.collision_mask = Layers.STRUCTURE
		for hit in state.intersect_point(q, 64):
			if col.owns(hit.rid):
				solid += 1
				break
	return solid


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

		# New: a body a band, merged; the hit merges its band again.
		var col := BuildingCollision.new(w, chunk, _space, Transform3D.IDENTITY, true)
		var t3 := Time.get_ticks_usec()
		col.disable(killed)
		col.flush()
		var t_new := Time.get_ticks_usec()
		col.free_bodies()
		# And a box a brick, switching 30 off.
		col = BuildingCollision.new(w, chunk, _space, Transform3D.IDENTITY, false)
		var t_per := Time.get_ticks_usec()
		col.disable(probe_ids)
		var t_new_dis := Time.get_ticks_usec()
		t_new_dis -= t_per - t_new
		print("  %dx%dx%d, %5d blocks, %2d bands: un-merge whole %5.1f ms (shapes %4.1f + space %4.1f), band re-merged %4.1f ms; switch 30 off: whole %4.1f ms, band %4.1f ms" % [
				s[0], s[1], s[2], w.get_block_count(chunk), col.bodies.size(),
				float(t_old - t) / 1000.0, float(t_add - t) / 1000.0, float(t_old - t_add) / 1000.0,
				float(t_new - t3) / 1000.0,
				float(t_old_dis - t2) / 1000.0, float(t_new_dis - t_new) / 1000.0])
		col.free_bodies()
