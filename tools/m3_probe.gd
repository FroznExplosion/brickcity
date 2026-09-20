extends SceneTree

## M3a acceptance probe — shaped parts and islands. Headless, no physics.
##
##     godot --headless --path . --script tools/m3_probe.gd
##
## Two claims to pin. First, nothing downstream assumes a part fills its
## bounding box: placement, connectivity, stress, meshing and collision all read
## the mask. Second, a detached island is a real chunk — it can be shot,
## re-solved and split, and its grid survives the move.

var failures := 0

var A_BRICK := -1   # 4 x 3 x 2, full box
var A_CUBE := -1    # 1 x 3 x 1, full box
var A_NOTCH := -1   # 2 x 3 x 2, with the z=1 column cut back to one plate
var A_TILE := -1    # 2 x 1 x 2, no studs on top


func _initialize() -> void:
	_check_shape_masks()
	_check_shaped_placement()
	_check_stud_masks()
	_check_island_is_a_chunk()
	_check_island_damage_and_split()
	_check_determinism()

	print("")
	if failures == 0:
		print("[probe] PASS")
	else:
		print("[probe] FAIL — %d check(s)" % failures)
	quit(1 if failures > 0 else 0)


func _ok(label: String, condition: bool, detail: String = "") -> void:
	if condition:
		print("  ok    %s%s" % [label, ("  " + detail) if detail else ""])
	else:
		failures += 1
		print("  FAIL  %s%s" % [label, ("  " + detail) if detail else ""])


func _world() -> BrickWorld:
	var w := BrickWorld.new()
	w.set_seed(11)
	A_BRICK = w.bake_archetype("brick_2x4_x", Vector3i(4, 3, 2), 2.4)
	A_CUBE = w.bake_archetype("brick_1x1", Vector3i(1, 3, 1), 1.0)

	# Notch: solid everywhere at y=0, but the z=1 column stops there. Eight of
	# twelve cells. Studs only on the full-height column.
	var size := Vector3i(2, 3, 2)
	var cells := PackedByteArray()
	cells.resize(size.x * size.y * size.z)
	for z in size.z:
		for y in size.y:
			for x in size.x:
				cells[x + size.x * (y + size.y * z)] = 1 if (z == 0 or y == 0) else 0
	var studs := PackedByteArray()
	studs.resize(size.x * size.z)
	for z in size.z:
		for x in size.x:
			studs[x + size.x * z] = 1 if z == 0 else 0
	var sockets := PackedByteArray()
	sockets.resize(size.x * size.z)
	sockets.fill(1)
	A_NOTCH = w.bake_shaped_archetype("notch_2x2", size, 0.9, cells, studs, sockets)

	# Tile: a full box of geometry, but nothing clips to its top.
	var no_studs := PackedByteArray()
	no_studs.resize(4)
	no_studs.fill(0)
	var all_sockets := PackedByteArray()
	all_sockets.resize(4)
	all_sockets.fill(1)
	A_TILE = w.bake_shaped_archetype("tile_2x2", Vector3i(2, 1, 2), 0.4,
			PackedByteArray(), no_studs, all_sockets)
	return w


# ---------------------------------------------------------------------------

func _check_shape_masks() -> void:
	print("shape masks")
	var w := _world()
	_ok("a plain archetype is a full box", w.is_archetype_full_box(A_BRICK))
	_ok("a masked one is not", not w.is_archetype_full_box(A_NOTCH))
	_ok("a full box counts every cell", w.get_archetype_solid_cells(A_BRICK) == 24,
			"%d" % w.get_archetype_solid_cells(A_BRICK))
	_ok("a masked one counts only what it fills", w.get_archetype_solid_cells(A_NOTCH) == 8,
			"%d of 12" % w.get_archetype_solid_cells(A_NOTCH))
	_ok("a stud mask alone leaves the box full", w.is_archetype_full_box(A_TILE))

	# Bad masks are refused rather than silently misread.
	var short := PackedByteArray()
	short.resize(5)
	_ok("a wrong-sized cell mask is refused",
			w.bake_shaped_archetype("bad", Vector3i(2, 3, 2), 1.0, short,
					PackedByteArray(), PackedByteArray()) == -1)
	var empty := PackedByteArray()
	empty.resize(12)
	empty.fill(0)
	_ok("an entirely hollow part is refused",
			w.bake_shaped_archetype("hollow", Vector3i(2, 3, 2), 1.0, empty,
					PackedByteArray(), PackedByteArray()) == -1)


func _check_shaped_placement() -> void:
	print("shaped placement")
	var w := _world()
	var c := w.create_chunk(Vector3i.ZERO, Vector3i(8, 12, 8))

	var notch := w.place_block(c, Vector3i(0, 0, 0), A_NOTCH, 4)
	_ok("a masked part places", notch >= 0)

	# Its own cells are claimed...
	_ok("it claims the cells it fills", w.is_solid(c, Vector3i(0, 2, 0)))
	# ...and the ones it does not fill are genuinely free.
	_ok("it leaves its notch empty", not w.is_solid(c, Vector3i(0, 2, 1)))

	# Which means something else can occupy the notch. A box part could never.
	var tenant := w.place_block(c, Vector3i(0, 1, 1), A_CUBE, 5)
	_ok("another part can sit in the notch", tenant >= 0)
	_ok("and a part may not overlap what IS filled",
			w.place_block(c, Vector3i(0, 0, 0), A_CUBE, 6) == -1)

	# Meshing walks the mask, so the empty cells contribute no faces.
	w.build_chunk_mesh(c)
	var shaped_stats: Dictionary = w.get_mesh_stats(c)
	_ok("the mesh covers both parts", int(shaped_stats.blocks_meshed) == 2)

	# Collision is per solid cell for a masked part, one box for a plain one.
	var boxes: Array = w.get_block_boxes(c)
	var notch_boxes := 0
	var cube_boxes := 0
	for b in boxes:
		if int(b.block) == notch:
			notch_boxes += 1
		elif int(b.block) == tenant:
			cube_boxes += 1
	_ok("a masked part collides as its solid cells", notch_boxes == 8, "%d" % notch_boxes)
	_ok("a box part still collides as one box", cube_boxes == 1, "%d" % cube_boxes)
	_ok("every box names its block", boxes.size() == notch_boxes + cube_boxes)


func _check_stud_masks() -> void:
	print("stud masks")
	var w := _world()
	var c := w.create_chunk(Vector3i.ZERO, Vector3i(8, 12, 8))

	# A tile is solid, so a brick can rest ON it geometrically -- but it offers
	# no studs, so nothing joins to its top. That is a structural fact.
	var tile := w.place_block(c, Vector3i(0, 0, 0), A_TILE, 4)
	var above := w.place_block(c, Vector3i(0, 1, 0), A_BRICK, 5)
	_ok("both placed", tile >= 0 and above >= 0)
	_ok("nothing clips to a studless top",
			not w.get_block_neighbours(c, tile).has(above),
			"tile has %d neighbour(s)" % w.get_block_neighbours(c, tile).size())

	# Sitting on a normal brick instead, the same part connects fine.
	var w2 := _world()
	var c2 := w2.create_chunk(Vector3i.ZERO, Vector3i(8, 12, 8))
	var base := w2.place_block(c2, Vector3i(0, 0, 0), A_BRICK, 4)
	var top := w2.place_block(c2, Vector3i(0, 3, 0), A_BRICK, 5)
	_ok("a studded top does connect", w2.get_block_neighbours(c2, base).has(top))

	# The notch only carries studs on its full-height column, so a part over the
	# short column connects to nothing.
	var w3 := _world()
	var c3 := w3.create_chunk(Vector3i.ZERO, Vector3i(8, 12, 8))
	var notch := w3.place_block(c3, Vector3i(0, 0, 0), A_NOTCH, 4)
	var over_notch := w3.place_block(c3, Vector3i(0, 3, 0), A_CUBE, 5)
	_ok("a part over the studded column connects",
			w3.get_block_neighbours(c3, notch).has(over_notch))
	_ok("grounding follows the same joints", w3.find_detached_groups(c3).is_empty())


func _check_island_is_a_chunk() -> void:
	print("islands are chunks")
	var w := _world()
	var c := w.create_chunk(Vector3i.ZERO, Vector3i(6, 40, 6))
	var ids: Array[int] = []
	for i in 8:
		ids.append(w.place_block(c, Vector3i(0, i * 3, 0), A_CUBE, i % 12))

	w.kill_block(c, Vector3i(0, 0, 0))
	var groups: Array = w.find_detached_groups(c)
	_ok("the severed column is one island", groups.size() == 1)

	var split: Dictionary = w.split_island(c, groups[0])
	_ok("split returns a chunk", not split.is_empty() and int(split.chunk) != c)

	var island: int = split.chunk
	_ok("the island is alive", w.is_chunk_alive(island))
	_ok("the island is not anchored", not w.is_chunk_anchored(island))
	_ok("the source chunk still is", w.is_chunk_anchored(c))
	_ok("every block came across", w.get_alive_block_count(island) == 7,
			"%d" % w.get_alive_block_count(island))
	_ok("the source kept none of them", w.get_alive_block_count(c) == 0,
			"%d" % w.get_alive_block_count(c))
	_ok("mass came across", is_equal_approx(float(split.mass), 7.0), "%.2f" % split.mass)

	# The island kept the grid, so connectivity still works inside it.
	var comps: Array = w.get_components(island)
	_ok("the island is one connected piece", comps.size() == 1,
			"%d component(s)" % comps.size())
	_ok("it can be meshed like any chunk", not (w.build_chunk_mesh(island) as Array).is_empty())

	# And it starts exactly where the blocks stood.
	var expect := BrickWorld.grid_to_world(Vector3i(0, 3, 0))
	var got: Vector3 = w.get_chunk_transform(island).origin
	_ok("it starts where the group stood", got.distance_to(expect) < 0.001,
			"%s vs %s" % [got, expect])


func _check_island_damage_and_split() -> void:
	print("island damage")
	var w := _world()
	var c := w.create_chunk(Vector3i.ZERO, Vector3i(6, 60, 6))
	for i in 16:
		w.place_block(c, Vector3i(0, i * 3, 0), A_CUBE, i % 12)
	w.kill_block(c, Vector3i(0, 0, 0))
	var island: int = w.split_island(c, w.find_detached_groups(c)[0]).chunk
	_ok("island built", w.get_alive_block_count(island) == 15)

	# Move it somewhere arbitrary. A shot has to land in the right place anyway.
	var moved := Transform3D(Basis(Vector3.UP, 0.7), Vector3(40.0, 12.0, -25.0))
	w.set_chunk_transform(island, moved)

	# Aim at the middle block, in world space, through that transform.
	var mid_local := BrickWorld.grid_to_world(Vector3i(0, 24, 0)) + Vector3(0.17, 0.2, 0.17)
	var killed: PackedInt32Array = w.apply_hit(island, moved * mid_local, 0.45)
	_ok("a moved island can still be shot", not killed.is_empty(), "%d block(s)" % killed.size())

	var comps: Array = w.get_components(island)
	_ok("cutting it in the middle makes two pieces", comps.size() == 2,
			"%d" % comps.size())

	var before := w.get_alive_block_count(island)
	var piece: Dictionary = w.split_island(island, comps[1])
	_ok("a piece can split off an island", not piece.is_empty())
	_ok("the piece is its own chunk", w.is_chunk_alive(int(piece.chunk)))
	_ok("the parent lost exactly that piece",
			w.get_alive_block_count(island) == before - int(piece.block_count),
			"%d -> %d, piece %d" % [before, w.get_alive_block_count(island), piece.block_count])
	_ok("the piece inherits the parent's placement",
			w.get_chunk_transform(int(piece.chunk)).basis.is_equal_approx(moved.basis))

	# Releasing frees the slot without invalidating anybody else's id.
	w.release_chunk(int(piece.chunk))
	_ok("a released chunk reports dead", not w.is_chunk_alive(int(piece.chunk)))
	_ok("its neighbours are untouched", w.is_chunk_alive(island) and w.is_chunk_alive(c))
	_ok("a dead id answers empty, not garbage", w.get_components(int(piece.chunk)).is_empty())


func _check_determinism() -> void:
	print("determinism")
	var a := _run()
	var b := _run()
	_ok("same input, same island sizes", a.sizes == b.sizes, "%s vs %s" % [a.sizes, b.sizes])
	_ok("same input, same survivors", a.alive == b.alive, "%d vs %d" % [a.alive, b.alive])
	_ok("same input, same geometry", a.hash == b.hash)


func _run() -> Dictionary:
	var w := _world()
	var c := w.create_chunk(Vector3i.ZERO, Vector3i(24, 40, 6))
	w.set_tension_per_stud(c, 26.0)
	for course in 12:
		var y := course * 3
		var x := 2 if course % 2 == 1 else 0
		while x + 4 <= 24:
			w.place_block(c, Vector3i(x, y, 0), A_BRICK, course % 12)
			x += 4
	for i in 3:
		w.place_block(c, Vector3i(i * 2, 36, 0), A_NOTCH, 7)

	for i in 4:
		w.apply_hit(c, Vector3(2.0 + i * 1.3, 18 * BrickWorld.get_plate_metres(), 0.3), 1.0)

	var sizes: Array[int] = []
	var islands: Array[int] = []
	for step in 20:
		w.solve_stress(c)
		var groups: Array = w.find_detached_groups(c)
		if groups.is_empty():
			break
		for g in groups:
			var s: Dictionary = w.split_island(c, g)
			if not s.is_empty():
				islands.append(int(s.chunk))
				sizes.append(int(s.block_count))
	sizes.sort()

	var h := 0
	for island in islands:
		var arrays: Array = w.build_chunk_mesh(island)
		if not arrays.is_empty():
			h ^= hash(arrays[Mesh.ARRAY_VERTEX])
	return {"sizes": sizes, "alive": w.get_alive_block_count(c), "hash": h}
