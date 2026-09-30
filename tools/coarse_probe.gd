extends SceneTree

## The coarse stand-in a far piece is drawn with (BrickWorld.build_chunk_coarse_mesh;
## IslandManager.ISLAND_MESH_RANGE). It has to cover exactly the surface the
## bricks do -- the same exposed area facing each way, so nothing is missing
## and nothing buried shows -- with far fewer triangles, and carry a brick-sized
## UV2 so the seam shader still draws brick outlines on it.

var passed := 0
var failed := 0

const SEAM_SIDE := Vector2(0.7, 0.42)
const SEAM_FLAT := Vector2(0.7, 0.7)


func _init() -> void:
	print("the coarse stand-in covers what the bricks do, for far less")
	for c in [
			{"name": "a small tower", "x": 20, "z": 20, "courses": 36, "hits": []},
			{"name": "shot through", "x": 20, "z": 20, "courses": 36,
					"hits": [[Vector3(0.4, 0.5, 0.4), 2.5], [Vector3(3.0, 2.0, 0.3), 2.0]]},
			{"name": "a big one", "x": 40, "z": 30, "courses": 60,
					"hits": [[Vector3(0.5, 1.0, 0.5), 3.2]]},
	]:
		_check(c)
	_check_empty()
	print("\n%d passed, %d failed" % [passed, failed])
	quit(1 if failed > 0 else 0)


func _ok(what: String, cond: bool, detail := "") -> void:
	if cond:
		passed += 1
		print("  ok   %s%s" % [what, (" -- " + detail) if detail else ""])
	else:
		failed += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _tower(w: BrickWorld, c: Dictionary) -> int:
	var palette := TowerRecipe.bake_palette(w)
	var chunk := w.create_chunk(Vector3i.ZERO,
			TowerRecipe.chunk_dims(int(c.x), int(c.z), int(c.courses)))
	TowerRecipe.build(w, chunk, palette, int(c.x), int(c.z), int(c.courses))
	w.set_chunk_transform(chunk, Transform3D.IDENTITY)
	for h in c.hits:
		w.apply_hit(chunk, h[0], h[1])
	return chunk


func _check(c: Dictionary) -> void:
	print("\n%s" % c.name)
	var w := BrickWorld.new()
	var chunk := _tower(w, c)
	var bricks: Array = w.build_chunk_mesh(chunk)
	var coarse: Array = w.build_chunk_coarse_mesh(chunk)
	# The best of a few: the first pays for warming caches, and what is asked is
	# what the build costs, not what the machine was doing.
	var ms := w.get_last_coarse_ms()
	for i in 4:
		w.build_chunk_coarse_mesh(chunk)
		ms = minf(ms, w.get_last_coarse_ms())
	_ok("it builds", not coarse.is_empty() and IslandManager.mesh_arrays_ok(coarse, "coarse"))
	if coarse.is_empty():
		return
	var a := _area_by_face(bricks)
	var b := _area_by_face(coarse)
	# An authored part (a round brick, a spiral step) is drawn by the bricks as
	# its shape and by the stand-in as the cells it fills: the two differ there,
	# on purpose. None in these towers, or the comparison is not exact.
	var authored := w.get_chunk_authored_tris(chunk)
	var worst := 0.0
	for f in 6:
		worst = maxf(worst, absf(a[f] - b[f]) / maxf(a[f], 1e-6))
	_ok("the same exposed area facing each way", authored == 0 and worst < 1e-4,
			"worst side off by %.4f%%, bricks %s, stand-in %s, %d authored tris" % [
				worst * 100.0, _fmt(a), _fmt(b), authored])
	var tris_bricks := _triangles(bricks)
	var tris_coarse := (coarse[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3
	var verts_bricks := (bricks[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	var verts_coarse := (coarse[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	_ok("in under half the triangles", tris_coarse * 2 < tris_bricks,
			"%d against %d drawn (%.0f%%)" % [tris_coarse, tris_bricks,
				100.0 * tris_coarse / maxf(tris_bricks, 1)])
	_ok("and under a fifth of the vertices", verts_coarse * 5 < verts_bricks,
			"%d against %d uploaded (%.0f%%), built in %.2f ms" % [verts_coarse, verts_bricks,
				100.0 * verts_coarse / maxf(verts_bricks, 1), ms])
	var seams_ok := true
	var normals: PackedVector3Array = coarse[Mesh.ARRAY_NORMAL]
	var uv2s: PackedVector2Array = coarse[Mesh.ARRAY_TEX_UV2]
	for i in uv2s.size():
		var want := SEAM_FLAT if absf(normals[i].y) > 0.5 else SEAM_SIDE
		if not uv2s[i].is_equal_approx(want):
			seams_ok = false
			break
	_ok("a brick-sized UV2 on every face, so the shader draws brick outlines", seams_ok)
	_ok("where the bricks are", _box(coarse).is_equal_approx(_box_drawn(bricks)),
			"%s against %s" % [_box(coarse), _box_drawn(bricks)])


## Everything dead: nothing to draw, and nothing is what comes back.
func _check_empty() -> void:
	print("\nnothing left alive")
	var w := BrickWorld.new()
	var chunk := _tower(w, {"x": 8, "z": 8, "courses": 6, "hits": []})
	var all := PackedInt32Array()
	for id in w.get_block_count(chunk):
		all.push_back(id)
	w.kill_blocks(chunk, all)
	_ok("an empty stand-in", w.build_chunk_coarse_mesh(chunk).is_empty())


## Area of the triangles drawn, by which way they face (+x -x +y -y +z -z).
## Degenerate triangles are what the bake draws hidden faces as; they add 0.
func _area_by_face(arrays: Array) -> PackedFloat64Array:
	var out := PackedFloat64Array([0, 0, 0, 0, 0, 0])
	var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	for t in range(0, idx.size(), 3):
		var p0 := v[idx[t]]
		var cr := (v[idx[t + 1]] - p0).cross(v[idx[t + 2]] - p0)
		var area := cr.length() * 0.5
		if area < 1e-9:
			continue
		var n := cr.normalized()
		var f := 0
		if absf(n.x) > 0.5:
			f = 0 if n.x < 0.0 else 1
		elif absf(n.y) > 0.5:
			f = 2 if n.y < 0.0 else 3
		else:
			f = 4 if n.z < 0.0 else 5
		out[f] += area
	return out


func _triangles(arrays: Array) -> int:
	var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var n := 0
	for t in range(0, idx.size(), 3):
		if (v[idx[t + 1]] - v[idx[t]]).cross(v[idx[t + 2]] - v[idx[t]]).length_squared() > 1e-12:
			n += 1
	return n


func _box(arrays: Array) -> AABB:
	var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var box := AABB(v[0], Vector3.ZERO)
	for p in v:
		box = box.expand(p)
	return box


## The box of what the bricks DRAW: the bake holds every face, hidden or not.
func _box_drawn(arrays: Array) -> AABB:
	var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var box := AABB()
	var first := true
	for t in range(0, idx.size(), 3):
		var p0 := v[idx[t]]
		if (v[idx[t + 1]] - p0).cross(v[idx[t + 2]] - p0).length_squared() <= 1e-12:
			continue
		for k in 3:
			if first:
				box = AABB(v[idx[t + k]], Vector3.ZERO)
				first = false
			else:
				box = box.expand(v[idx[t + k]])
	return box


func _fmt(a: PackedFloat64Array) -> String:
	var parts := []
	for x in a:
		parts.append("%.1f" % x)
	return "[" + ", ".join(parts) + "]"
