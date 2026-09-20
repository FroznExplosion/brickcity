extends SceneTree

## M0 acceptance probe. Headless, no rendering, no scene.
##
##     godot --headless --path . --script tools/m0_probe.gd
##
## Checks the things the M0 gate actually claims: the grid round-trips, face
## culling culls, damage opens new faces instead of merely deleting them, and
## an identical world meshes byte-identically (the substrate gate G6 needs).
## The ancestor of the probe suite in Reference/mvs-c.md section 8.

var failures := 0


func _initialize() -> void:
	_check_grid()
	_check_archetypes()
	_check_culling()
	_check_damage()
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


# ---------------------------------------------------------------------------

func _check_grid() -> void:
	print("grid")
	var stud := BrickWorld.get_stud_metres()
	var plate := BrickWorld.get_plate_metres()
	_ok("stud is 0.35 m", is_equal_approx(stud, 0.35), "%.3f" % stud)
	_ok("plate is 0.14 m", is_equal_approx(plate, 0.14), "%.3f" % plate)
	_ok("brick is 3 plates", is_equal_approx(plate * 3.0, 0.42), "%.3f" % (plate * 3.0))

	# Round-trip every cell in a small block of the grid, including negatives.
	var bad := 0
	for x in range(-8, 9):
		for y in range(-8, 9):
			for z in range(-8, 9):
				var cell := Vector3i(x, y, z)
				var world_pos: Vector3 = BrickWorld.grid_to_world(cell)
				# sample the middle of the cell so floor() cannot land on a seam
				var mid := world_pos + BrickWorld.get_cell_size() * 0.5
				if BrickWorld.world_to_grid(mid) != cell:
					bad += 1
	_ok("grid round-trips over 4913 cells", bad == 0, "%d bad" % bad)


func _check_archetypes() -> void:
	print("archetypes")
	var w := BrickWorld.new()
	var brick := w.bake_archetype("brick_1x1", Vector3i(1, 3, 1), 0.3)
	var plate := w.bake_archetype("plate_2x4", Vector3i(2, 1, 4), 0.8)
	_ok("ids are sequential", brick == 0 and plate == 1)
	_ok("size survives the boundary", w.get_archetype_size(plate) == Vector3i(2, 1, 4))
	_ok("name survives the boundary", w.get_archetype_name(brick) == "brick_1x1")
	_ok("a bad id is rejected, not crashed", w.get_archetype_size(99) == Vector3i.ZERO)
	_ok("zero-size archetype is refused", w.bake_archetype("bad", Vector3i(0, 1, 1), 1.0) == -1)


func _check_culling() -> void:
	print("culling")
	var w := BrickWorld.new()
	var a := w.bake_archetype("brick_1x1", Vector3i(1, 3, 1), 0.3)
	var c := w.create_chunk(Vector3i.ZERO, Vector3i(4, 9, 4))

	# One lone block: a 1 x 3 x 1 part, three cells stacked in Y.
	#
	# Cell faces that are buried inside the block are never baked -- geometry
	# that can never be seen is not generated. What is left is greedy-merged per
	# face plane, so the arithmetic is:
	#
	#   +X, -X   3 stacked cell faces each, merged      -> 1 + 1
	#   +Z, -Z   3 stacked cell faces each, merged      -> 1 + 1
	#   +Y, -Y   one cell each; the middles are buried  -> 1 + 1
	#                                                      = 6 faces
	#
	# Before merging this same block baked 14.
	w.place_block(c, Vector3i(1, 0, 1), a, 4)
	w.build_chunk_mesh(c)
	var lone: Dictionary = w.get_mesh_stats(c)
	_ok("lone block keeps its shell", lone.faces_emitted == 6, "%d faces" % lone.faces_emitted)
	_ok("its own internal seams are never baked", lone.baked_faces == 6,
			"%d baked" % lone.baked_faces)
	_ok("nothing baked is wasted on a lone block", lone.faces_culled == 0,
			"%d culled" % lone.faces_culled)

	# A second block beside it in X. Each block still bakes six faces: merging
	# never crosses a block boundary, because the two sides of that boundary are
	# owned by different blocks and either could be revealed on its own. The one
	# touching face per block is baked and not drawn.
	w.place_block(c, Vector3i(2, 0, 1), a, 5)
	w.build_chunk_mesh(c)
	var pair: Dictionary = w.get_mesh_stats(c)
	_ok("the shared faces are baked, ready to be revealed", pair.baked_faces == 12,
			"%d baked" % pair.baked_faces)
	_ok("but they are not drawn while both blocks live", pair.faces_emitted == 10,
			"%d drawn, expected 10" % pair.faces_emitted)
	_ok("the difference is exactly the shared faces", pair.faces_culled == 2,
			"%d culled" % pair.faces_culled)
	_ok("triangles are two per drawn face", pair.triangles == pair.faces_emitted * 2)
	_ok("vertices are four per BAKED face", pair.vertices == pair.baked_faces * 4,
			"%d for %d faces" % [pair.vertices, pair.baked_faces])

	# Kill one and the hidden faces appear, without a vertex being regenerated.
	var verts_before: int = pair.vertices
	w.kill_block(c, Vector3i(2, 0, 1))
	w.build_chunk_mesh(c)
	var holed: Dictionary = w.get_mesh_stats(c)
	_ok("killing a neighbour reveals the faces it was hiding",
			holed.faces_emitted == 6, "%d drawn" % holed.faces_emitted)
	_ok("and regenerates no geometry to do it", holed.vertices == verts_before,
			"%d vs %d" % [holed.vertices, verts_before])


func _check_damage() -> void:
	print("damage")
	var w := BrickWorld.new()
	var a := w.bake_archetype("brick_1x1", Vector3i(1, 3, 1), 0.3)
	var c := w.create_chunk(Vector3i.ZERO, Vector3i(6, 9, 6))

	# Solid 4x4 slab, one course deep. Interior blocks contribute nothing.
	for x in range(1, 5):
		for z in range(1, 5):
			w.place_block(c, Vector3i(x, 0, z), a, 2)
	w.build_chunk_mesh(c)
	var intact: Dictionary = w.get_mesh_stats(c)
	_ok("slab built", w.get_block_count(c) == 16 and w.get_alive_block_count(c) == 16)

	# Kill an interior block. Its own faces go, but four neighbours now have an
	# exposed inner wall each, so the face count must go UP, not down. This is
	# the whole reason a hole is visible.
	_ok("kill returns the block id", w.kill_block(c, Vector3i(2, 1, 2)) >= 0)
	_ok("killing it again returns -1", w.kill_block(c, Vector3i(2, 1, 2)) == -1)
	_ok("cell is no longer solid", not w.is_solid(c, Vector3i(2, 1, 2)))
	_ok("dead block still resolves", w.block_at(c, Vector3i(2, 1, 2)) >= 0)
	_ok("alive count dropped", w.get_alive_block_count(c) == 15)

	w.build_chunk_mesh(c)
	var holed: Dictionary = w.get_mesh_stats(c)
	_ok("a hole exposes more surface than it removes",
			holed.faces_emitted > intact.faces_emitted,
			"%d -> %d" % [intact.faces_emitted, holed.faces_emitted])
	_ok("dead block meshes nothing", holed.blocks_meshed == 15)

	# The index partition is what lets damage be an index edit rather than a
	# remesh. A dead block keeps its SLOTS -- they are written as degenerate
	# triangles -- because a fixed buffer length is what makes the surface
	# patchable in place instead of rebuilt.
	var dead_id := w.block_at(c, Vector3i(2, 1, 2))
	_ok("a dead block keeps its index slots", w.get_block_index_range(c, dead_id).y > 0,
			"%d slots" % w.get_block_index_range(c, dead_id).y)
	_ok("the buffer length never changes", holed.index_slots == intact.index_slots,
			"%d vs %d" % [holed.index_slots, intact.index_slots])
	_ok("but the dead block draws nothing",
			holed.degenerate_triangles >= w.get_block_index_range(c, dead_id).y / 3)
	var total := 0
	for i in w.get_block_count(c):
		total += w.get_block_index_range(c, i).y
	_ok("block index ranges tile the buffer", total == holed.index_slots,
			"%d vs %d" % [total, holed.index_slots])


func _check_determinism() -> void:
	print("determinism")
	var first := _build_reference_world()
	var second := _build_reference_world()
	_ok("same input, same vertex count", first.vertices == second.vertices)
	_ok("same input, same index count", first.indices == second.indices)
	_ok("same input, same geometry", first.hash == second.hash,
			"%d vs %d" % [first.hash, second.hash])


func _build_reference_world() -> Dictionary:
	var w := BrickWorld.new()
	w.set_seed(1234)
	var a2x4 := w.bake_archetype("brick_2x4_x", Vector3i(4, 3, 2), 2.4)
	var a2x2 := w.bake_archetype("brick_2x2", Vector3i(2, 3, 2), 1.2)
	var c := w.create_chunk(Vector3i.ZERO, Vector3i(16, 24, 8))
	for course in 8:
		var y := course * 3
		var offset := 2 if course % 2 == 1 else 0
		if offset > 0:
			w.place_block(c, Vector3i(0, y, 0), a2x2, course % 12)
		var x := offset
		while x + 4 <= 16:
			w.place_block(c, Vector3i(x, y, 0), a2x4, course % 12)
			x += 4
	# carve something so the dead-block path is part of the comparison
	w.kill_block(c, Vector3i(5, 9, 0))
	w.kill_block(c, Vector3i(9, 12, 1))
	var arrays: Array = w.build_chunk_mesh(c)
	var stats: Dictionary = w.get_mesh_stats(c)
	return {
		"vertices": stats.vertices,
		"indices": stats.indices,
		"hash": hash(arrays[Mesh.ARRAY_VERTEX]) ^ hash(arrays[Mesh.ARRAY_INDEX]),
	}
