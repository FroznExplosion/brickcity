extends SceneTree

## Acceptance probe for the dormant tier: wreckage given back.
##
##     godot --headless --path . --script tools/dormant_probe.gd
##
## The claim, from Docs/Status.md's "give islands back to the world": a piece
## that has come to rest, far from anybody, should stop costing a chunk, an
## occupancy grid, a bake, a mesh and a body -- and should still be the same
## piece when somebody walks back to it.
##
## This is the truth layer's half: `ChunkRecord` round-trips a chunk exactly.
## The scene's half is `godot --path . -- --dormant`, which is where the
## distances, the budgets and the memory actually are.

var _pass := 0
var _fail := 0


func _init() -> void:
	print("dormant probe")
	_check_round_trip()
	_check_damage_is_not_history()
	_check_what_it_saves()
	_check_the_box_it_leaves_behind()
	_check_what_left_stays_gone()
	_check_furniture_stays_furniture()
	_check_furniture_survives_a_split()
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s" % what)
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _world() -> Array:
	var w := BrickWorld.new()
	return [w, TowerRecipe.bake_palette(w)]


## A lump of wreckage: a tower, built and then cut loose, which is what an
## island actually is.
func _rubble(w: BrickWorld, palette: Dictionary, courses: int = 6) -> int:
	var chunk := w.create_chunk(Vector3i.ZERO, TowerRecipe.chunk_dims(12, 12, courses))
	TowerRecipe.build(w, chunk, palette, 12, 12, courses)
	w.set_chunk_transform(chunk, Transform3D(Basis(Vector3.UP, 0.7), Vector3(11.0, 0.0, -4.0)))
	return chunk


# ---------------------------------------------------------------------------

func _check_round_trip() -> void:
	print("\na record is the piece, not a picture of it")
	var res := _world()
	var w: BrickWorld = res[0]
	var chunk := _rubble(w, res[1])
	var alive := w.get_alive_block_count(chunk)
	var before: Array = w.build_chunk_mesh(chunk)

	var record := ChunkRecord.capture(w, chunk)
	_ok("every standing block is in it", record.block_count() == alive,
			"%d of %d" % [record.block_count(), alive])
	_ok("with where it stands", record.xform.is_equal_approx(w.get_chunk_transform(chunk)))

	w.release_chunk(chunk)
	var back := record.restore(w)
	_ok("it builds again", back >= 0)
	_ok("with the same blocks", w.get_alive_block_count(back) == alive,
			"%d of %d" % [w.get_alive_block_count(back), alive])
	_ok("in the same place", w.get_chunk_transform(back).is_equal_approx(record.xform))

	# The mesh is the test that matters: same geometry, same colours, same
	# order. A piece somebody walks back to has to be the piece they left.
	var after: Array = w.build_chunk_mesh(back)
	_ok("and it draws byte-identically",
			(before[Mesh.ARRAY_VERTEX] as PackedVector3Array)
			== (after[Mesh.ARRAY_VERTEX] as PackedVector3Array))
	_ok("colours included",
			(before[Mesh.ARRAY_COLOR] as PackedColorArray)
			== (after[Mesh.ARRAY_COLOR] as PackedColorArray))

	# And it is still a piece of the world: breakable, not scenery.
	var hit: PackedInt32Array = w.apply_hit(back, record.xform * Vector3(1.0, 0.6, 1.0), 1.2)
	_ok("it can still be shot", hit.size() > 0, "%d blocks" % hit.size())


func _check_damage_is_not_history() -> void:
	print("\nwhat is gone is simply not in it")
	var res := _world()
	var w: BrickWorld = res[0]
	var chunk := _rubble(w, res[1])
	var whole := w.get_alive_block_count(chunk)
	w.apply_hit(chunk, w.get_chunk_transform(chunk) * Vector3(1.4, 0.8, 1.4), 1.6)
	var standing := w.get_alive_block_count(chunk)
	_ok("the hit removed bricks", standing < whole, "%d -> %d" % [whole, standing])

	var record := ChunkRecord.capture(w, chunk)
	_ok("the record holds what is left, not what was there",
			record.block_count() == standing, "%d of %d" % [record.block_count(), standing])
	w.release_chunk(chunk)
	var back := record.restore(w)
	_ok("and it comes back damaged", w.get_alive_block_count(back) == standing)
	_ok("with no damage record of its own to replay",
			w.get_dead_blocks(back).is_empty(), "%d dead" % w.get_dead_blocks(back).size())

	# Removed blocks -- tombstones that keep their id -- are not part of a
	# shape either.
	var edited := _rubble(w, res[1])
	var before := w.get_alive_block_count(edited)
	w.remove_block(edited, 4)
	var rec2 := ChunkRecord.capture(w, edited)
	_ok("a removed block is left out too", rec2.block_count() == before - 1,
			"%d of %d" % [rec2.block_count(), before - 1])


func _check_what_it_saves() -> void:
	print("\nand it is a fraction of what it replaces")
	var res := _world()
	var w: BrickWorld = res[0]
	var chunk := _rubble(w, res[1], 10)
	# Bake the faces, because a settled island has a bake and that is most of
	# what it costs.
	w.build_chunk_mesh(chunk)
	var resident: Dictionary = w.get_memory_report()
	var record := ChunkRecord.capture(w, chunk)
	w.release_chunk(chunk)
	var after: Dictionary = w.get_memory_report()

	_ok("releasing the chunk gives the world's memory back",
			int(after.total_bytes) < int(resident.total_bytes),
			"%d -> %d bytes" % [int(resident.total_bytes), int(after.total_bytes)])
	_ok("and no chunks are left", int(after.chunks) == int(resident.chunks) - 1)
	var per_block := float(record.bytes()) / float(maxi(record.block_count(), 1))
	# Seventeen: three ints of cell, an int of archetype, a byte of colour.
	_ok("the record is seventeen bytes a block", per_block <= 17.0,
			"%.1f bytes for %d blocks" % [per_block, record.block_count()])
	_ok("which is a small fraction of the chunk it replaces",
			record.bytes() * 10 < int(resident.total_bytes) - int(after.total_bytes),
			"%d bytes against %d freed" % [
				record.bytes(), int(resident.total_bytes) - int(after.total_bytes)])


## A piece that has SHED bricks -- detached, now standing on a piece of their own
## -- must not get them back by going to sleep. get_dead_blocks leaves detached
## blocks out on purpose (a building rebuilt from its recipe must not show them
## as holes), and the record used to ask it; so a piece that had shed and then
## slept woke with those bricks standing in it again, twice in the world.
func _check_what_left_stays_gone() -> void:
	print("\nwhat left a piece stays gone when it sleeps")
	var res := _world()
	var w: BrickWorld = res[0]
	var chunk := _rubble(w, res[1], 10)
	w.separate_plane(chunk, w.get_chunk_transform(chunk) * Vector3(3.0, 5 * 3 * 0.14, 2.0),
			w.get_chunk_transform(chunk).basis * Vector3.UP, 0.42)
	var comps: Array = w.get_components(chunk)
	if comps.size() < 2:
		_ok("the cut made pieces to shed", false, "%d component(s)" % comps.size())
		return
	var cut: Dictionary = w.split_island(chunk, comps[1])
	var alive := w.get_alive_block_count(chunk)
	# What the old rule would have kept: everything not in get_dead_blocks.
	var dead := {}
	for id in w.get_dead_blocks(chunk):
		dead[id] = true
	var old_rule := 0
	for id in w.get_block_count(chunk):
		if not dead.has(id) and not w.get_block_ticks(chunk, id).is_empty():
			old_rule += 1
	print("  shed %d block(s); %d standing; the old rule would have kept %d" % [
		int(cut.block_count), alive, old_rule])
	var record := ChunkRecord.capture(w, chunk)
	_ok("the record holds what is standing, not what left", record.block_count() == alive,
			"%d of %d" % [record.block_count(), alive])
	w.release_chunk(chunk)
	var back := record.restore(w)
	_ok("and wakes with exactly that", w.get_alive_block_count(back) == alive,
			"%d of %d" % [w.get_alive_block_count(back), alive])
	_check_rebuilt_building_stays_cut()


## The same for a standing building the registry lets go of and builds again
## from its recipe: what left it as a piece must not grow back (BuildingRegistry
## Building.gone).
func _check_rebuilt_building_stays_cut() -> void:
	var res := _world()
	var w: BrickWorld = res[0]
	var reg := BuildingRegistry.new(w, res[1])
	var id := reg.register(12, 12, 10, Transform3D(Basis(), Vector3(11.0, 0.0, -4.0)))
	var chunk := reg.materialise(id)
	w.separate_plane(chunk, w.get_chunk_transform(chunk) * Vector3(3.0, 5 * 3 * 0.14, 2.0),
			Vector3.UP, 0.42)
	var comps: Array = w.get_components(chunk)
	if comps.size() < 2:
		_ok("the building's cut made a piece to shed", false, "%d component(s)" % comps.size())
		return
	var cut: Dictionary = w.split_island(chunk, comps[1])
	var alive := w.get_alive_block_count(chunk)
	reg.dematerialise(id)
	var again := reg.materialise(id)
	_ok("a rebuilt building does not grow back what left it",
			again >= 0 and w.get_alive_block_count(again) == alive,
			"%d standing, %d after the rebuild, %d shed" % [alive,
			w.get_alive_block_count(again) if again >= 0 else -1, int(cut.block_count)])


## Furniture rides a piece as decorative blocks: weightless in a solve, open air
## to grounding. It has to wake up that way, not as load-bearing brick.
func _check_furniture_stays_furniture() -> void:
	print("\nfurniture wakes up as furniture")
	var res := _world()
	var w: BrickWorld = res[0]
	var chunk := _rubble(w, res[1])
	var some := PackedInt32Array([0, 1, 2, 5, 8])
	w.set_blocks_decorative(chunk, some, true)
	var record := ChunkRecord.capture(w, chunk)
	w.release_chunk(chunk)
	var back := record.restore(w)
	var still := 0
	for id in w.get_decorative_blocks(back):
		still += 1
	_ok("the same blocks are furniture after it wakes", still == some.size(),
			"%d of %d" % [still, some.size()])


## And when the piece carrying it breaks. split_island used to lay the new
## piece's blocks fresh -- furniture as structure, severed joints whole, damage
## gone. It carries all three now; and so does a record, through a sleep.
func _check_furniture_survives_a_split() -> void:
	print("\nwhat a block is survives its piece breaking")
	var res := _world()
	var w: BrickWorld = res[0]
	var furnished := func() -> Array:
		var chunk := _rubble(w, res[1], 10)
		w.separate_plane(chunk, w.get_chunk_transform(chunk) * Vector3(3.0, 5 * 3 * 0.14, 2.0),
				w.get_chunk_transform(chunk).basis * Vector3.UP, 0.42)
		# The piece above the cut: its grid cannot start at zero, which is what
		# lets the sleep check below tell a kept origin from a reset one.
		var group := PackedInt32Array()
		var best := -1
		for comp in w.get_components(chunk):
			var ids: PackedInt32Array = comp
			if ids.size() < 8:
				continue
			var lo := 1 << 30
			for id in ids:
				lo = mini(lo, (w.get_block_ticks(chunk, id)[0] as Vector3i).y)
			if lo > best:
				best = lo
				group = ids
		# Half of the group is furniture.
		var marked := PackedInt32Array()
		for k in range(0, group.size(), 2):
			marked.append(group[k])
		w.set_blocks_decorative(chunk, marked, true)
		return [chunk, group, marked.size()]
	var a: Array = furnished.call()
	var cut: Dictionary = w.split_island(a[0], a[1])
	var kept := w.get_decorative_blocks(int(cut.chunk)).size()
	# split_island used to lay every block as structure; it measured 0 of 25 kept.
	_ok("every furniture block is still furniture after the split", kept == int(a[2]),
			"%d of %d" % [kept, int(a[2])])

	# Severed joints go with the blocks too. Cut some by hand, split, look.
	var b: Array = furnished.call()
	var group: PackedInt32Array = b[1]
	var severed := {}
	for k in range(1, group.size(), 3):
		var joints := BrickWorld.JOINT_BOTTOM_BROKEN if k % 2 else BrickWorld.JOINT_SUPPORT_BROKEN
		w.set_block_joints(b[0], group[k], joints)
		severed[group[k]] = joints
	var cut2: Dictionary = w.split_island(b[0], group)
	var taken: PackedInt32Array = cut2.source_blocks
	var same := 0
	for k in taken.size():
		if w.get_block_joints(int(cut2.chunk), k) == int(severed.get(taken[k], 0)):
			same += 1
	_ok("a joint severed before the split is still severed after it",
			same == taken.size() and not severed.is_empty(),
			"%d of %d blocks agree, %d severed" % [same, taken.size(), severed.size()])

	# And through a sleep: the record keeps them, and keeps where the grid starts.
	var piece := int(cut2.chunk)
	var origin := w.get_chunk_origin(piece)
	var before := {}
	for id in w.get_block_count(piece):
		before[id] = w.get_block_joints(piece, id)
	var record := ChunkRecord.capture(w, piece)
	w.release_chunk(piece)
	var back := record.restore(w)
	var kept_joints := 0
	var n := 0
	for id in before:
		if int(before[id]) != 0:
			n += 1
			if w.get_block_joints(back, int(id)) == int(before[id]):
				kept_joints += 1
	_ok("and still severed after the piece sleeps and wakes", n > 0 and kept_joints == n,
			"%d of %d" % [kept_joints, n])
	_ok("which wakes at the grid origin it slept at", w.get_chunk_origin(back) == origin
			and origin != Vector3i.ZERO, "%s" % w.get_chunk_origin(back))


func _check_the_box_it_leaves_behind() -> void:
	print("\nit still knows where it is while it sleeps")
	var res := _world()
	var w: BrickWorld = res[0]
	var chunk := _rubble(w, res[1])
	var record := ChunkRecord.capture(w, chunk)
	var here: Vector3 = record.xform.origin

	_ok("it has a world box", record.box.size.length() > 0.0, "%v" % [record.box.size])
	_ok("around where the piece stands", record.box.grow(0.5).has_point(here),
			"%s vs %v" % [record.box, here])

	# Which is what a blast asks it: a piece that is asleep because nobody is
	# near it still has to take the hit (Plan section 4.4).
	var inside: Vector3 = record.box.get_center()
	_ok("a blast inside it is inside it", record.box.grow(1.0).has_point(inside))
	_ok("and one a hundred metres away is not",
			not record.box.grow(1.0).has_point(inside + Vector3(100.0, 0.0, 0.0)))
	w.release_chunk(chunk)
