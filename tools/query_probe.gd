extends SceneTree

## Two questions CityScene used to answer by walking every brick in script, now
## asked of the engine: BrickWorld.rest_contacts (where a settled piece rests on
## a building -- _wreck_settled) and BrickWorld.any_block_centre_in (is anything
## left standing round a stairwell -- _with_stairs). Each has to answer exactly
## what the script walk it replaced did, which is kept here as the reference:
## many poses and boxes, some bricks shot out, some cut away.

var passed := 0
var failed := 0


func _init() -> void:
	print("the engine's answers are the script walks' answers")
	_check_centres()
	_check_contacts()
	print("\n%d passed, %d failed" % [passed, failed])
	quit(1 if failed > 0 else 0)


func _ok(what: String, cond: bool, detail := "") -> void:
	if cond:
		passed += 1
		print("  ok   %s%s" % [what, (" -- " + detail) if detail else ""])
	else:
		failed += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _tower(w: BrickWorld, palette: Dictionary, x: int, z: int, courses: int) -> int:
	var chunk := w.create_chunk(Vector3i.ZERO, TowerRecipe.chunk_dims(x, z, courses))
	TowerRecipe.build(w, chunk, palette, x, z, courses)
	w.set_chunk_transform(chunk, Transform3D.IDENTITY)
	return chunk


## _with_stairs' walk, as it was.
func _centre_in_walk(w: BrickWorld, chunk: int, box: AABB, exclude: Dictionary) -> bool:
	for bx in w.get_block_boxes(chunk):
		var d: Dictionary = bx
		if not bool(d.alive) or exclude.has(int(d.block)):
			continue
		if box.has_point(d.pos as Vector3):
			return true
	return false


func _check_centres() -> void:
	print("\nany_block_centre_in")
	var w := BrickWorld.new()
	var palette := TowerRecipe.bake_palette(w)
	var chunk := _tower(w, palette, 24, 20, 36)
	w.apply_hit(chunk, Vector3(1.0, 1.0, 0.4), 2.5)
	w.apply_hit(chunk, Vector3(4.0, 6.0, 3.0), 2.0)
	var n := w.get_block_count(chunk)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	# Cut some away as a split would: dead and detached.
	var away := PackedInt32Array()
	for i in 40:
		away.append(rng.randi_range(0, n - 1))
	w.kill_blocks(chunk, away)
	var dims := Vector3(w.get_chunk_dims(chunk)) * BrickWorld.get_cell_size()
	var same := 0
	var hits := 0
	var cases := 300
	for i in cases:
		var p := Vector3(rng.randf() * dims.x, rng.randf() * dims.y, rng.randf() * dims.z)
		var size := Vector3(rng.randf_range(0.05, 3.0), rng.randf_range(0.05, 3.0), rng.randf_range(0.05, 3.0))
		var box := AABB(p - size * 0.5, size)
		var ex := {}
		var packed := PackedInt32Array()
		for k in rng.randi_range(0, 400):
			var id := rng.randi_range(0, n - 1)
			ex[id] = true
			packed.append(id)
		var a := _centre_in_walk(w, chunk, box, ex)
		var b := w.any_block_centre_in(chunk, box, packed)
		if a == b:
			same += 1
		if a:
			hits += 1
	_ok("the same answer for every box", same == cases,
			"%d of %d, %d of them with something in" % [same, cases, hits])
	_ok("and both answers were asked", hits > 20 and hits < cases - 20, "%d yes" % hits)


## _wreck_settled's walk, as it was: every live box of the piece, the point
## just under it, the building's cell there if solid.
func _contacts_walk(w: BrickWorld, piece: int, xf: Transform3D, building: int) -> Array:
	var out := []
	var cell := BrickWorld.get_cell_size()
	for bx in w.get_block_boxes(piece):
		var d: Dictionary = bx
		if not bool(d.alive):
			continue
		var size: Vector3 = d.size
		var centre: Vector3 = xf * (d.pos as Vector3)
		var hy := absf(xf.basis.x.y) * size.x * 0.5 + absf(xf.basis.y.y) * size.y * 0.5 \
				+ absf(xf.basis.z.y) * size.z * 0.5
		var under := centre - Vector3.UP * (hy + 0.05)
		var local := w.get_chunk_transform(building).affine_inverse() * under
		var at := w.get_chunk_origin(building) + Vector3i(floori(local.x / cell.x),
				floori(local.y / cell.y), floori(local.z / cell.z))
		if w.is_solid(building, at) and w.block_at(building, at) >= 0:
			if not out.has(at):
				out.append(at)
	return out


func _check_contacts() -> void:
	print("\nrest_contacts")
	var w := BrickWorld.new()
	var palette := TowerRecipe.bake_palette(w)
	var building := _tower(w, palette, 24, 20, 24)
	var piece := _tower(w, palette, 8, 6, 6)
	w.apply_hit(piece, Vector3(0.5, 0.3, 0.5), 1.2)
	var top := Vector3(w.get_chunk_dims(building)) * BrickWorld.get_cell_size()
	var roof := TowerRecipe.total_plates(24) * BrickWorld.get_cell_size().y
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var same := 0
	var touching := 0
	var cases := 60
	for i in cases:
		# On the roof, turned about and tipped a little, sometimes on its side,
		# sometimes sunk into the building, sometimes off the edge.
		var basis := Basis(Vector3.UP, rng.randf() * TAU)
		if i % 3 == 1:
			basis = basis * Basis(Vector3.RIGHT, rng.randf_range(-0.3, 0.3))
		if i % 5 == 2:
			basis = basis * Basis(Vector3.FORWARD, PI * 0.5)
		var at := Vector3(rng.randf_range(-2.0, top.x), roof + rng.randf_range(-1.0, 0.4),
				rng.randf_range(-2.0, top.z))
		var xf := Transform3D(basis, at)
		var a := _contacts_walk(w, piece, xf, building)
		var packed := w.rest_contacts(piece, xf, building)
		var b := []
		for k in range(0, packed.size(), 3):
			b.append(Vector3i(packed[k], packed[k + 1], packed[k + 2]))
		if str(a) == str(b):
			same += 1
		if not a.is_empty():
			touching += 1
	_ok("the same cells, in the same order, for every pose", same == cases,
			"%d of %d, %d touching" % [same, cases, touching])
	_ok("and enough of them touch for that to mean something", touching >= 15, "%d" % touching)
