extends SceneTree

## The chamfered brick mesh, as numbers (Docs/BrickBevel.md). Headless.
##
##     godot --headless --path . --script res://tools/brick_bevel_probe.gd
##
## Whether the bevels open the wall is a picture, and tools/brick_bevel_gap_probe.gd
## looks at it. This is the bookkeeping the picture cannot show going wrong
## until a dead brick is still drawn:
##
##   * a chunk chamfered band by band on workers is the same triangles as the
##     chunk chamfered whole, and as the whole built in one call;
##   * every triangle faces the way its normal says;
##   * a hit patches the bands' index buffers to exactly what a fresh build
##     gives, and a band whose bake has gone says so instead of being patched;
##   * the studs counted band by band are the studs of the chunk, with none
##     under a brick and none on a smooth part.

const BEVEL := 0.013

var passed := 0
var failed := 0


func _init() -> void:
	print("the chamfered brick mesh adds up")
	_check_tower()
	_check_studs()
	print("\n%d passed, %d failed" % [passed, failed])
	quit(1 if failed > 0 else 0)


func _ok(what: String, cond: bool, detail := "") -> void:
	if cond:
		passed += 1
		print("  ok   %s%s" % [what, (" -- " + detail) if detail else ""])
	else:
		failed += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


## Triangles an index array draws: three zeros (or any repeat) draw nothing.
func _drawn(idx: PackedInt32Array) -> int:
	var n := 0
	for i in range(0, idx.size() - 2, 3):
		if idx[i] != idx[i + 1] and idx[i + 1] != idx[i + 2] and idx[i] != idx[i + 2]:
			n += 1
	return n


## Triangles wound against their normal. The engine draws clockwise as the
## front, so (b - a) x (c - a) points AWAY from the side a face is seen from.
func _backwards(arrays: Array) -> int:
	var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var nn: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var bad := 0
	for i in range(0, idx.size() - 2, 3):
		var a := v[idx[i]]
		var b := v[idx[i + 1]]
		var c := v[idx[i + 2]]
		var cross := (b - a).cross(c - a)
		if cross.length_squared() < 1e-14:
			continue
		if cross.dot(nn[idx[i]]) > 0.0:
			bad += 1
	return bad


func _wait(w: BrickWorld, chunk: int, section: int) -> Array:
	w.chamfer_section_async(chunk, section, BEVEL)
	for i in 20000:
		if w.chamfer_ready(chunk, section):
			break
		OS.delay_msec(1)
	return w.take_chamfer_section(chunk, section)


## An index buffer as the renderer holds it, and a patch written into it.
func _bytes(idx: PackedInt32Array, width: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(idx.size() * width)
	for i in idx.size():
		if width == 2:
			out.encode_u16(i * 2, idx[i])
		else:
			out.encode_s32(i * 4, idx[i])
	return out


func _indices(bytes: PackedByteArray, width: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	@warning_ignore("integer_division")
	out.resize(bytes.size() / width)
	for i in out.size():
		out[i] = bytes.decode_u16(i * 2) if width == 2 else bytes.decode_s32(i * 4)
	return out


func _check_tower() -> void:
	print("\na tower, in bands")
	var w := BrickWorld.new()
	var palette := TowerRecipe.bake_palette(w)
	var chunk := w.create_chunk(Vector3i.ZERO, TowerRecipe.chunk_dims(20, 16, 24))
	TowerRecipe.build(w, chunk, palette, 20, 16, 24)
	w.set_chunk_transform(chunk, Transform3D.IDENTITY)
	w.set_chunk_section_plates(chunk, 18)
	var sections := w.get_chunk_sections(chunk)

	var flat: Array = w.build_chunk_mesh(chunk)
	var whole: Array = w.build_chunk_chamfer_mesh(chunk, BEVEL)
	var flat_tris := _drawn(flat[Mesh.ARRAY_INDEX])
	var whole_tris := _drawn(whole[Mesh.ARRAY_INDEX])
	_ok("it builds", IslandManager.mesh_arrays_ok(whole, "chamfered"),
			"%d triangles to the flat mesh's %d (x%.1f), %.2f ms" % [whole_tris, flat_tris,
				float(whole_tris) / maxf(flat_tris, 1.0), w.get_last_chamfer_ms()])
	_ok("every triangle faces the way its normal says", _backwards(whole) == 0,
			"%d do not" % _backwards(whole))
	_ok("and the flat mesh's do too (the check on the check)", _backwards(flat) == 0)
	var with_no_bevel: Array = w.build_chunk_chamfer_mesh(chunk, 0.0)
	_ok("with no bevel it is the flat mesh's triangles",
			_drawn(with_no_bevel[Mesh.ARRAY_INDEX]) == flat_tris,
			"%d" % _drawn(with_no_bevel[Mesh.ARRAY_INDEX]))

	# Band by band, on workers.
	var bands := []
	var widths := []
	var band_tris := 0
	var backwards := 0
	for s in sections:
		var arrays: Array = _wait(w, chunk, s)
		bands.append(arrays)
		if arrays.is_empty():
			widths.append(4)
			continue
		widths.append(IslandManager.index_width(arrays))
		band_tris += _drawn(arrays[Mesh.ARRAY_INDEX])
		backwards += _backwards(arrays)
	_ok("%d bands draw what the whole chunk does" % sections, band_tris == whole_tris,
			"%d against %d" % [band_tris, whole_tris])
	_ok("facing the right way", backwards == 0, "%d do not" % backwards)

	# A hit: patches, written into the buffers as the renderer would.
	var held := []
	for s in sections:
		held.append(_bytes(bands[s][Mesh.ARRAY_INDEX], widths[s]) if not bands[s].is_empty()
				else PackedByteArray())
	w.apply_hit(chunk, Vector3(0.4, 2.0, 2.5), 1.6)
	w.apply_hit(chunk, Vector3(3.5, 5.0, 0.3), 1.2)
	var regions: Array = w.update_chamfer_regions(chunk)
	var moved := 0
	var fits := true
	for entry in regions:
		var d: Dictionary = entry
		if d.get("stale", false):
			fits = false
			continue
		var s := int(d.section)
		var data: PackedByteArray = d.data
		if int(d.offset) + data.size() > (held[s] as PackedByteArray).size():
			fits = false
			continue
		for i in data.size():
			held[s][int(d.offset) + i] = data[i]
		moved += 1
	_ok("a hit moves some bands' indices and no band is stale", moved > 0 and fits,
			"%d of %d bands" % [moved, sections])
	var patched := 0
	var expected := 0
	for s in sections:
		if (held[s] as PackedByteArray).is_empty():
			continue
		patched += _drawn(_indices(held[s], widths[s]))
		expected += w.get_chamfer_expected_triangles(chunk, s)
	var fresh: Array = w.build_chunk_chamfer_mesh(chunk, BEVEL)
	var fresh_tris := _drawn(fresh[Mesh.ARRAY_INDEX])
	_ok("patched, the bands draw what a fresh build of the damaged chunk does",
			patched == fresh_tris and expected == fresh_tris,
			"%d patched, %d expected, %d fresh" % [patched, expected, fresh_tris])
	_ok("which is not what they drew before", fresh_tris != whole_tris)
	_ok("a second ask finds nothing moved", w.update_chamfer_regions(chunk).is_empty())

	# The chunk as one mesh (a piece, a build's frame).
	w.drop_chamfer(chunk, 0, true)
	var one: Array = _wait(w, chunk, -1)
	_ok("the chunk as one band is the same again",
			not one.is_empty() and _drawn(one[Mesh.ARRAY_INDEX]) == fresh_tris,
			"%d" % (_drawn(one[Mesh.ARRAY_INDEX]) if not one.is_empty() else -1))

	# A new bake: what was built from the old one is no good, and says so.
	w.chamfer_section_async(chunk, 1, BEVEL)
	w.drop_chunk_bake(chunk)
	w.build_chunk_mesh(chunk)
	for i in 20000:
		if w.chamfer_ready(chunk, 1):
			break
		OS.delay_msec(1)
	_ok("a band built from a bake that has gone is not handed over",
			w.take_chamfer_section(chunk, 1).is_empty())
	var stale := false
	for entry in w.update_chamfer_regions(chunk):
		if (entry as Dictionary).get("stale", false):
			stale = true
	_ok("and one held from it is called stale, not patched", stale)
	w.release_chunk(chunk)
	_ok("releasing the chunk gives its bands back",
			w.get_chamfer_expected_triangles(chunk, -1) == -1)


func _check_studs() -> void:
	print("\nstuds, band by band")
	var w := BrickWorld.new()
	var palette := TowerRecipe.bake_palette(w)
	var chunk := w.create_chunk(Vector3i.ZERO, TowerRecipe.chunk_dims(20, 16, 24))
	TowerRecipe.build(w, chunk, palette, 20, 16, 24)
	w.set_chunk_section_plates(chunk, 18)
	@warning_ignore("integer_division")
	var all := w.get_chunk_studs_section(chunk, -1).size() / 16
	var sum := 0
	for s in w.get_chunk_sections(chunk):
		@warning_ignore("integer_division")
		sum += w.get_chunk_studs_section(chunk, s).size() / 16
	_ok("the bands' studs are the chunk's", sum == all and all > 0, "%d and %d" % [sum, all])
	w.apply_hit(chunk, Vector3(0.4, 2.0, 2.5), 1.6)
	@warning_ignore("integer_division")
	var after := w.get_chunk_studs_section(chunk, -1).size() / 16
	_ok("a crater changes them", after != all, "%d, then %d" % [all, after])

	# The workshop's rule, on three parts.
	var pal := BrickPalette.bake(w)
	var c := w.create_chunk(Vector3i.ZERO, Vector3i(8, 12, 8))
	w.place_block(c, Vector3i(0, 0, 0), int(pal["brick_2x4_x"]), 0)
	@warning_ignore("integer_division")
	var bare := w.get_chunk_studs_section(c, -1).size() / 16
	_ok("a 2x4 brick shows eight studs", bare == 8, "%d" % bare)
	w.place_block(c, Vector3i(0, 3, 0), int(pal["brick_2x2"]), 1)
	@warning_ignore("integer_division")
	var covered := w.get_chunk_studs_section(c, -1).size() / 16
	_ok("four of them go under a 2x2 on top, which shows its own four", covered == 8,
			"%d" % covered)
	w.place_block(c, Vector3i(0, 6, 0), int(pal["tile_2x2"]), 2)
	@warning_ignore("integer_division")
	var tiled := w.get_chunk_studs_section(c, -1).size() / 16
	_ok("a smooth tile on that covers them and shows none", tiled == 4, "%d" % tiled)
