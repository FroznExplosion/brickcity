extends SceneTree

## Acceptance probe for gap 8, part one: authored surfaces.
##
##     godot --headless --path . --script tools/mesh_probe.gd
##
## An archetype may carry authored triangles, and the face bake draws those in
## place of voxel faces. The claim that makes this safe is that ONLY the drawing
## changes: the cell mask stays the truth for connectivity, stress, occupancy
## and collision, so nothing about how a part stands or breaks moves. Most of
## this checks that claim rather than the triangles.

var _pass := 0
var _fail := 0


func _init() -> void:
	print("mesh probe (gap 8: authored surfaces)")
	_check_setter()
	_check_bake_draws_the_mesh()
	_check_mask_is_still_the_truth()
	_check_culling()
	_check_damage_still_patches()
	_check_variants_carry_the_mesh()
	_check_staircase()
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s" % what)
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


## A 1x1 brick's box as twelve authored triangles, deliberately wound both ways
## so the extension's winding fix-up is exercised.
func _box_mesh() -> Array:
	var sx := BrickPalette.STUD_M
	var sy := 3.0 * BrickPalette.PLATE_M
	var pos := PackedVector3Array()
	var nrm := PackedVector3Array()
	var c := [Vector3(0, 0, 0), Vector3(sx, 0, 0), Vector3(sx, 0, sx), Vector3(0, 0, sx),
			Vector3(0, sy, 0), Vector3(sx, sy, 0), Vector3(sx, sy, sx), Vector3(0, sy, sx)]
	var faces := [[[0, 1, 2, 3], Vector3.DOWN], [[4, 5, 6, 7], Vector3.UP],
			[[0, 1, 5, 4], Vector3.FORWARD], [[3, 2, 6, 7], Vector3.BACK],
			[[0, 3, 7, 4], Vector3.LEFT], [[1, 2, 6, 5], Vector3.RIGHT]]
	var flip := false
	for f in faces:
		var q: Array = f[0]
		var n: Vector3 = f[1]
		var a: Vector3 = c[q[0]]
		var b: Vector3 = c[q[1]]
		var cc: Vector3 = c[q[2]]
		var d: Vector3 = c[q[3]]
		if flip:
			pos.append_array([a, cc, b, a, d, cc])
		else:
			pos.append_array([a, b, cc, a, cc, d])
		for i in 6:
			nrm.push_back(n)
		flip = not flip
	return [pos, nrm]


func _stats(w: BrickWorld, c: int) -> Dictionary:
	w.build_chunk_mesh(c)
	return w.get_mesh_stats(c)


# ---------------------------------------------------------------------------

func _check_setter() -> void:
	print("\nsetting a mesh")
	var w := BrickWorld.new()
	var a := w.bake_archetype("m", Vector3i(1, 3, 1), 0.3)
	_ok("a plain archetype has none", w.get_archetype_mesh_triangles(a) == 0)
	var m := _box_mesh()
	w.set_archetype_mesh(a, m[0], m[1])
	_ok("twelve triangles stored", w.get_archetype_mesh_triangles(a) == 12)
	w.set_archetype_mesh(a, PackedVector3Array([Vector3.ZERO]), PackedVector3Array([Vector3.UP]))
	_ok("a malformed mesh is refused and changes nothing", w.get_archetype_mesh_triangles(a) == 12)
	w.set_archetype_mesh(a, PackedVector3Array(), PackedVector3Array())
	_ok("empty arrays go back to voxel faces", w.get_archetype_mesh_triangles(a) == 0)


func _check_bake_draws_the_mesh() -> void:
	print("\nthe bake draws the authored triangles instead of voxel faces")
	var w := BrickWorld.new()
	var a := w.bake_archetype("m", Vector3i(1, 3, 1), 0.3)
	var m := _box_mesh()
	w.set_archetype_mesh(a, m[0], m[1])
	var c := w.create_chunk(Vector3i.ZERO, Vector3i(4, 8, 4))
	w.place_block(c, Vector3i(1, 0, 1), a, 4)
	var st := _stats(w, c)
	_ok("one baked face per authored triangle", st.baked_faces == 12, "%d" % st.baked_faces)
	_ok("all drawn: nothing is next to it", st.faces_emitted == 12, "%d" % st.faces_emitted)

	# Winding: every drawn triangle must face along its normal, which is what
	# decides whether Godot draws it or culls it as a back face.
	var arrays: Array = w.build_chunk_mesh(c)
	var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var n: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var bad := 0
	for f in 12:
		var i := f * 4
		var cross := (v[i + 1] - v[i]).cross(v[i + 2] - v[i])
		# Godot's front face is CLOCKWISE: the cross product points INTO the part.
		if cross.dot(n[i] + n[i + 1] + n[i + 2]) >= 0.0:
			bad += 1
	_ok("every triangle is wound to face outward, whichever way it was authored",
			bad == 0, "%d wrong" % bad)
	_ok("the fourth corner repeats the second, so the pair's second triangle is empty",
			v[3].is_equal_approx(v[1]))


func _check_mask_is_still_the_truth() -> void:
	print("\nthe cell mask is still what connects, loads and collides")
	var w := BrickWorld.new()
	var p := BrickPalette.bake(w)
	var plain: int = p["brick_1x1"]
	var meshed := w.bake_archetype("m", Vector3i(1, 3, 1), 0.3)
	var m := _box_mesh()
	w.set_archetype_mesh(meshed, m[0], m[1])
	_ok("a meshed part and a plain one with the same cells are different archetypes",
			meshed != plain)

	var c := w.create_chunk(Vector3i.ZERO, Vector3i(4, 16, 4))
	var lo := w.place_block(c, Vector3i(0, 0, 0), plain, 4)
	var mid := w.place_block(c, Vector3i(0, 3, 0), meshed, 4)
	var hi := w.place_block(c, Vector3i(0, 6, 0), plain, 4)
	_ok("it stacks: occupancy is its cells", lo >= 0 and mid >= 0 and hi >= 0)
	_ok("it joins the brick below by studs", w.get_block_neighbours(c, lo).has(mid))
	_ok("and the brick above", w.get_block_neighbours(c, mid).has(hi))
	w.set_foundation_level(c, 0)
	var g: PackedByteArray = w.solve_grounded(c)
	_ok("the stack is grounded through it", g[hi] != 0)
	var boxes: Array = w.get_block_boxes(c)
	_ok("and it collides as its cells, like any part", boxes.size() == 3, "%d" % boxes.size())


func _check_culling() -> void:
	print("\na voxel brick hides an authored face; another authored one does not")
	var w := BrickWorld.new()
	var p := BrickPalette.bake(w)
	var meshed := w.bake_archetype("m", Vector3i(1, 3, 1), 0.3)
	var m := _box_mesh()
	w.set_archetype_mesh(meshed, m[0], m[1])

	var c := w.create_chunk(Vector3i.ZERO, Vector3i(4, 16, 4))
	w.place_block(c, Vector3i(0, 0, 0), meshed, 4)
	var cap := w.place_block(c, Vector3i(0, 3, 0), p["brick_1x1"], 4)
	var st := _stats(w, c)
	# Meshed top (2 tris) hidden by the voxel brick; the voxel brick's bottom is
	# hidden too, because to a voxel face an occupied cell is an occupied cell.
	_ok("the two triangles under a voxel brick are culled",
			st.faces_culled >= 2, "%d culled" % st.faces_culled)
	w.kill_block(c, Vector3i(0, 3, 0))
	var after := _stats(w, c)
	_ok("destroying the brick on top reveals them again",
			after.faces_emitted >= 12, "%d emitted" % after.faces_emitted)
	var _u := cap

	var c2 := w.create_chunk(Vector3i.ZERO, Vector3i(4, 16, 4))
	w.place_block(c2, Vector3i(0, 0, 0), meshed, 4)
	w.place_block(c2, Vector3i(0, 3, 0), meshed, 4)
	var st2 := _stats(w, c2)
	_ok("two authored parts meeting cull nothing -- their shapes need not fill a cell",
			st2.faces_culled == 0 and st2.faces_emitted == 24,
			"%d emitted, %d culled" % [st2.faces_emitted, st2.faces_culled])


func _check_damage_still_patches() -> void:
	print("\ndamage still works by degenerate triangles")
	var w := BrickWorld.new()
	var meshed := w.bake_archetype("m", Vector3i(1, 3, 1), 0.3)
	var m := _box_mesh()
	w.set_archetype_mesh(meshed, m[0], m[1])
	var c := w.create_chunk(Vector3i.ZERO, Vector3i(8, 8, 8))
	w.place_block(c, Vector3i(0, 0, 0), meshed, 4)
	w.place_block(c, Vector3i(4, 0, 0), meshed, 4)
	var before := _stats(w, c)
	w.kill_block(c, Vector3i(0, 0, 0))
	var after := _stats(w, c)
	_ok("the baked face count does not change -- the buffer length is fixed",
			after.baked_faces == before.baked_faces)
	_ok("the dead part's twelve are culled", after.faces_emitted == before.faces_emitted - 12,
			"%d -> %d" % [before.faces_emitted, after.faces_emitted])


func _check_variants_carry_the_mesh() -> void:
	print("\na rotated variant turns its mesh with it")
	var w := BrickWorld.new()
	var base := w.bake_archetype("long", Vector3i(1, 3, 4), 1.2)
	# A single triangle along the part's length, so a turn is visible.
	var S := BrickPalette.STUD_M
	var pos := PackedVector3Array([Vector3(0, 0, 0), Vector3(0, 0, 4 * S), Vector3(S, 0, 0)])
	var nrm := PackedVector3Array([Vector3.DOWN, Vector3.DOWN, Vector3.DOWN])
	w.set_archetype_mesh(base, pos, nrm)
	var turned := w.bake_variant(base, "long_x", 1, false)
	_ok("the variant has the mesh", w.get_archetype_mesh_triangles(turned) == 1)
	_ok("and is its own archetype", turned != base)
	var c := w.create_chunk(Vector3i.ZERO, Vector3i(8, 8, 8))
	w.place_block(c, Vector3i(0, 0, 0), turned, 4)
	var arrays: Array = w.build_chunk_mesh(c)
	var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var box := AABB(Vector3.ZERO, Vector3(4 * S, 3 * BrickPalette.PLATE_M, S)).grow(0.001)
	var inside := true
	for i in 3:
		inside = inside and box.has_point(v[i])
	_ok("every vertex lands inside the turned part's box (4 x 3 x 1)", inside,
			"%v %v %v" % [v[0], v[1], v[2]])
	var span := maxf(maxf(v[0].x, v[1].x), v[2].x) - minf(minf(v[0].x, v[1].x), v[2].x)
	_ok("its long edge now runs along X", is_equal_approx(span, 4 * S), "%.3f" % span)


func _check_staircase() -> void:
	print("\nthe staircase is drawn as its shape")
	var w := BrickWorld.new()
	var parts: PackedInt32Array = StaircaseRecipe.bake_parts(w)
	var all := true
	for id in parts:
		all = all and w.get_archetype_mesh_triangles(id) > 0
	_ok("all eight steps carry a surface", all)

	# Every vertex inside the step's own box: a surface that pokes out of its
	# cells would draw through whatever is next to it.
	var S := BrickPalette.STUD_M
	var box := AABB(Vector3.ZERO, Vector3(StaircaseRecipe.DIAMETER * S,
			StaircaseRecipe.STEP_PLATES * BrickPalette.PLATE_M,
			StaircaseRecipe.DIAMETER * S)).grow(0.001)
	var out := 0
	for s in StaircaseRecipe.STEPS_PER_TURN:
		var m: Array = StaircaseRecipe.step_mesh(s)
		for v in (m[0] as PackedVector3Array):
			if not box.has_point(v):
				out += 1
	_ok("no step's surface leaves its box", out == 0, "%d vertices outside" % out)

	# And the flight is as sound as it was: the drawing changed, nothing else.
	var c := w.create_chunk(Vector3i.ZERO, StaircaseRecipe.chunk_dims(16))
	var placed := StaircaseRecipe.build(w, c, parts, 16)
	_ok("a two-turn flight builds", placed == 16, "%d" % placed)
	w.set_foundation_level(c, 0)
	var g: PackedByteArray = w.solve_grounded(c)
	_ok("and every step is grounded through the newel", g.count(1) == 16, "%d" % g.count(1))
	var st := _stats(w, c)
	_ok("it draws its authored triangles", st.faces_emitted > 16 * 40, "%d" % st.faces_emitted)
