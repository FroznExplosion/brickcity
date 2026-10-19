extends SceneTree

## Acceptance probe for SECTION MESHES.
##
##     godot --headless --path . --script tools/section_probe.gd
##
## Rebuilding a building's mesh is linear in the whole building however few
## bricks changed, and on the `--big` shapes that is ~104 ms -- which a collapse
## forces, and which measured as 104 of a 162 ms worst tick. So a chunk's
## drawing is cut into horizontal bands: the face bake comes out grouped by
## band, a band's vertices are therefore contiguous, and a band can be rebuilt
## or patched on its own.
##
## Drawing only. The chunk, the occupancy, the damage record, the stress solve
## and the collision are all still whole-chunk, and this probe checks that too:
## the claim is that sectioning changes what is UPLOADED and nothing else.
##
## The claims:
##
##   * the bands together are exactly the whole mesh -- same vertices, same
##     indices, same faces actually drawn;
##   * every index in a band points inside that band's own vertices;
##   * a band's face range is contiguous and the ranges tile the bake;
##   * damage in one band moves only that band's index bytes;
##   * the structural answers do not change when the section height does;
##   * TILES (set_chunk_section_studs, Docs/Structures.md 2.2): a wide
##     building cut into 32-stud tiles is still exactly the whole mesh, every
##     block in one tile, and a blast moves the tiles it is in, not the rest of
##     that floor.

var _pass := 0
var _fail := 0


func _init() -> void:
	print("section probe")
	_check_bands_are_the_whole_mesh()
	_check_damage_touches_one_band()
	_check_structure_is_unchanged()
	_check_tiles()
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s" % what)
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _tower() -> Array:
	var w := BrickWorld.new()
	var pal := TowerRecipe.bake_palette(w)
	var reg := BuildingRegistry.new(w, pal)
	var id := reg.register(20, 20, 18, Transform3D())
	var chunk := reg.materialise(id)
	w.set_tension_per_stud(chunk, 9.3)
	return [w, reg, id, chunk]


## How many faces an index buffer actually draws, and how many of its indices
## fall outside the vertex array it belongs to.
static func _count(idx: PackedInt32Array, verts: int) -> Array:
	var drawn := 0
	var bad := 0
	for k in range(0, idx.size(), 6):
		if idx[k] == 0 and idx[k + 1] == 0 and idx[k + 2] == 0:
			continue   # degenerate: a culled face, kept so the buffer never resizes
		drawn += 1
		for j in 6:
			if idx[k + j] < 0 or idx[k + j] >= verts:
				bad += 1
	return [drawn, bad]


func _check_bands_are_the_whole_mesh() -> void:
	print("\nthe bands are the whole mesh, cut up")
	var res := _tower()
	var w: BrickWorld = res[0]
	var chunk: int = res[3]

	var whole: Array = w.build_chunk_mesh(chunk)
	var whole_v: int = (whole[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	var whole_i: int = (whole[Mesh.ARRAY_INDEX] as PackedInt32Array).size()
	var whole_drawn: int = _count(whole[Mesh.ARRAY_INDEX], whole_v)[0]
	_ok("the tower has a mesh to cut up", whole_v > 0 and whole_drawn > 0,
			"%d verts, %d drawn" % [whole_v, whole_drawn])
	_ok("and one section by default", w.get_chunk_sections(chunk) == 1)

	for plates in [24, 12, 6]:
		w.set_chunk_section_plates(chunk, plates)
		var n := w.get_chunk_sections(chunk)
		var sv := 0
		var si := 0
		var sd := 0
		var bad := 0
		var empty := 0
		for s in n:
			var a: Array = w.build_chunk_mesh_section(chunk, s)
			if a.is_empty():
				empty += 1
				continue
			var verts: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
			var idx: PackedInt32Array = a[Mesh.ARRAY_INDEX]
			var counted := _count(idx, verts.size())
			sv += verts.size()
			si += idx.size()
			sd += int(counted[0])
			bad += int(counted[1])
		_ok("%d plates a band: %d band(s) hold every vertex" % [plates, n],
				sv == whole_v, "%d against %d" % [sv, whole_v])
		_ok("  and every index", si == whole_i, "%d against %d" % [si, whole_i])
		_ok("  and draw exactly the faces the whole mesh draws", sd == whole_drawn,
				"%d against %d" % [sd, whole_drawn])
		_ok("  with no index pointing outside its own band", bad == 0,
				"%d out of range" % bad)


func _check_damage_touches_one_band() -> void:
	print("\ndamage moves the band it happened in, and not the others")
	var res := _tower()
	var w: BrickWorld = res[0]
	var chunk: int = res[3]
	w.set_chunk_section_plates(chunk, 12)
	var n := w.get_chunk_sections(chunk)
	_ok("the tower is in several bands", n > 2, "%d" % n)
	for s in n:
		w.build_chunk_mesh_section(chunk, s)

	# Nothing has changed, so nothing should need uploading.
	_ok("an untouched building uploads nothing",
			w.update_index_regions(chunk, 4).is_empty())

	# A blast low down, in one band.
	var cell := BrickWorld.get_cell_size()
	var at := w.get_chunk_transform(chunk) * Vector3(10 * cell.x, 4 * cell.y, 0.0)
	var killed: PackedInt32Array = w.apply_hit(chunk, at, 1.2)
	_ok("a blast killed bricks", killed.size() > 0, "%d" % killed.size())

	var moved: Array = w.update_index_regions(chunk, 4)
	_ok("and something needs uploading", moved.size() > 0)
	var bands := {}
	for d in moved:
		bands[int((d as Dictionary).section)] = true
	_ok("but not every band", bands.size() < n,
			"%d of %d band(s) moved" % [bands.size(), n])
	var lowest := 1 << 30
	for b in bands:
		lowest = mini(lowest, int(b))
	_ok("and the ones that moved are down where the blast was", lowest <= 1,
			"lowest moved band %d" % lowest)


func _check_structure_is_unchanged() -> void:
	print("\nsectioning is a drawing decision and nothing else")
	var res := _tower()
	var w: BrickWorld = res[0]
	var chunk: int = res[3]

	var stress_one: Dictionary = w.solve_stress(chunk)
	var balance_one: Dictionary = w.check_stability(chunk)
	var blocks_one := w.get_alive_block_count(chunk)
	var boxes_one: int = (w.get_body_boxes(chunk).get("boxes", []) as Array).size()

	w.set_chunk_section_plates(chunk, 9)
	for s in w.get_chunk_sections(chunk):
		w.build_chunk_mesh_section(chunk, s)
	var stress_two: Dictionary = w.solve_stress(chunk)
	var balance_two: Dictionary = w.check_stability(chunk)

	_ok("the same bricks are alive", w.get_alive_block_count(chunk) == blocks_one)
	_ok("the stress answer is the same",
			int(stress_two.failures) == int(stress_one.failures)
			and is_equal_approx(float(stress_two.peak_load), float(stress_one.peak_load)))
	_ok("the balance answer is the same",
			bool(balance_two.stable) == bool(balance_one.stable)
			and (balance_two.com as Vector3).distance_to(balance_one.com as Vector3) < 0.0001)
	_ok("and the collision is the same",
			(w.get_body_boxes(chunk).get("boxes", []) as Array).size() == boxes_one)


func _check_tiles() -> void:
	print("
tiles: a wide building cut across as well as up")
	var w := BrickWorld.new()
	var pal := TowerRecipe.bake_palette(w)
	var reg := BuildingRegistry.new(w, pal)
	var id := reg.register(120, 70, 12, Transform3D())
	var chunk := reg.materialise(id)
	var whole: Array = w.build_chunk_mesh(chunk)
	var whole_v: int = (whole[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	var whole_drawn: int = _count(whole[Mesh.ARRAY_INDEX], whole_v)[0]
	w.set_chunk_section_plates(chunk, 24)
	var layers := w.get_chunk_sections(chunk)
	w.set_chunk_section_studs(chunk, 32)
	var n := w.get_chunk_sections(chunk)
	var dims: Vector3i = w.get_chunk_dims(chunk)
	var want := layers * ceili(dims.x / 32.0) * ceili(dims.z / 32.0)
	_ok("%d layer(s) of %d x %d studs: %d tiles" % [layers, dims.x, dims.z, n], n == want,
			"%d, wanted %d" % [n, want])
	var sv := 0
	var sd := 0
	var bad := 0
	var boxes: Array[AABB] = []
	for s in n:
		var a: Array = w.build_chunk_mesh_section(chunk, s)
		if a.is_empty():
			boxes.append(AABB())
			continue
		var verts: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
		var counted := _count(a[Mesh.ARRAY_INDEX], verts.size())
		sv += verts.size()
		sd += int(counted[0])
		bad += int(counted[1])
		var box := AABB(verts[0], Vector3.ZERO)
		for v in verts:
			box = box.expand(v)
		boxes.append(box)
	_ok("the tiles hold every vertex", sv == whole_v, "%d against %d" % [sv, whole_v])
	_ok("  and draw exactly the faces the whole mesh draws", sd == whole_drawn,
			"%d against %d" % [sd, whole_drawn])
	_ok("  with no index outside its own tile", bad == 0, "%d" % bad)
	var cell := BrickWorld.get_cell_size()
	var narrow := 0
	var widest := 0.0
	for box in boxes:
		widest = maxf(widest, maxf(box.size.x, box.size.z))
		# A floor panel starting on the tile's last stud (the upper layer's,
		# half a panel over) is the longest reach past it: 31 + PANEL.
		if maxf(box.size.x, box.size.z) <= (31 + TowerRecipe.PANEL) * cell.x + 0.001:
			narrow += 1
	# A brick belongs to the tile its lowest corner is in, so a tile's drawing
	# reaches a brick's length past its edge, no further.
	_ok("  and every tile is 32 studs across or a panel more, not the building's width",
			narrow == boxes.size(), "%d of %d; widest %.1f studs" % [narrow, boxes.size(), widest / cell.x])

	var ids := PackedInt32Array()
	for i in w.get_block_count(chunk):
		ids.append(i)
	var secs := w.get_block_sections(chunk, ids)
	var outside := 0
	for s in secs:
		if s < 0 or s >= n:
			outside += 1
	_ok("every brick is in a tile", outside == 0, "%d not" % outside)

	_ok("an untouched building uploads nothing", w.update_index_regions(chunk, 4).is_empty())
	var at := w.get_chunk_transform(chunk) * Vector3(100 * cell.x, 4 * cell.y, 2 * cell.z)
	var killed: PackedInt32Array = w.apply_hit(chunk, at, 1.2)
	var moved: Array = w.update_index_regions(chunk, 4)
	var hit := {}
	for d in moved:
		hit[int((d as Dictionary).section)] = true
	var on_floor := n / layers
	_ok("a blast at one end of the ground floor moves its tile(s), not the whole floor",
			killed.size() > 0 and hit.size() > 0 and hit.size() < on_floor,
			"%d killed, %d of %d tiles of that layer moved" % [killed.size(), hit.size(), on_floor])
