extends SceneTree

## What one tower costs in each way of drawing it (Docs/HandoffPerf.md 8).
##
##     godot --headless --path . --script res://tools/probes/brick_cost_probe.gd
##
## Baked faces, a box a brick (the instance buffers of CityDrawing's boxed
## bands), the coarse merged mesh, the chamfered mesh, and its studs: vertices,
## triangles, bytes handed to the renderer, and the time to make them. Prints;
## checks nothing.

const SIZES := [[20, 20, 12], [40, 30, 24], [30, 30, 42], [30, 40, 60]]
const VERT_BYTES := 56   # pos 12, normal 12, colour 16, uv 8, uv2 8 (uncompressed)


func _ms(t: int) -> float:
	return float(Time.get_ticks_usec() - t) / 1000.0


func _verts(arrays: Array) -> int:
	if arrays.is_empty():
		return 0
	return (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()


func _idx(arrays: Array) -> int:
	if arrays.is_empty():
		return 0
	return (arrays[Mesh.ARRAY_INDEX] as PackedInt32Array).size()


func _init() -> void:
	var w := BrickWorld.new()
	w.set_seed(4)
	var palette := TowerRecipe.bake_palette(w)
	var reg := BuildingRegistry.new(w, palette)
	for size in SIZES:
		reg.register(int(size[0]), int(size[1]), int(size[2]),
				Transform3D(Basis(), Vector3(0.0, 0.0, -200.0)))
	reg.prepare_templates()
	var n := 0
	for size in SIZES:
		n += 1
		var id := reg.register(int(size[0]), int(size[1]), int(size[2]),
				Transform3D(Basis(), Vector3(n * 60.0, 0.0, 0.0)))
		var chunk := reg.materialise(id)
		var bricks := w.get_alive_block_count(chunk)
		var t := Time.get_ticks_usec()
		w.bake_chunk_async(chunk)
		while not w.bake_ready(chunk):
			OS.delay_usec(100)
		var bake_ms := _ms(t)
		t = Time.get_ticks_usec()
		var arrays: Array = w.build_chunk_mesh(chunk)
		var mesh_ms := _ms(t)
		var st: Dictionary = w.get_mesh_stats(chunk)
		var verts := _verts(arrays)
		var slots := _idx(arrays) / 3
		var drawn := int(st.get("triangles", 0))
		t = Time.get_ticks_usec()
		var bufs: Array = w.get_instance_buffers(chunk, PackedInt32Array(), PackedInt64Array())
		var box_ms := _ms(t)
		var floats := 0
		var special := 0
		for e in bufs:
			floats += ((e as Dictionary).buffer as PackedFloat32Array).size()
			special += _verts((e as Dictionary).special)
		t = Time.get_ticks_usec()
		var coarse: Array = w.build_chunk_coarse_mesh(chunk)
		var coarse_ms := _ms(t)
		t = Time.get_ticks_usec()
		var cham: Array = w.build_chunk_chamfer_mesh(chunk, 0.013)
		var cham_ms := _ms(t)
		t = Time.get_ticks_usec()
		var studs: PackedFloat32Array = w.get_chunk_studs(chunk)
		var stud_ms := _ms(t)
		print("\n%dx%d, %d courses: %d bricks" % [size[0], size[1], size[2], bricks])
		print("  baked faces : %d verts (%.1f a brick), %.2f MB; index slots %d tris, drawn %d (%.0f%%); bake %.1f ms, arrays %.1f ms" % [
				verts, float(verts) / bricks, verts * VERT_BYTES / 1048576.0 + slots * 12 / 1048576.0,
				slots, drawn, 100.0 * drawn / maxf(slots, 1), bake_ms, mesh_ms])
		print("  box a brick : %d instances, %.2f MB, %d tris (%d bevelled); %d vertices of parts that are not boxes; %.2f ms" % [
				floats / 20, floats * 4 / 1048576.0, floats / 20 * 12, floats / 20 * 36, special, box_ms])
		print("  coarse      : %d verts, %d tris, %.2f MB; %.1f ms" % [
				_verts(coarse), _idx(coarse) / 3, _verts(coarse) * VERT_BYTES / 1048576.0, coarse_ms])
		print("  chamfered   : %d verts, %d tris, %.2f MB; %.1f ms" % [
				_verts(cham), _idx(cham) / 3, _verts(cham) * VERT_BYTES / 1048576.0, cham_ms])
		print("  studs       : %d (%.1f a brick); fetch %.1f ms" % [
				studs.size() / 16, float(studs.size()) / 16.0 / bricks, stud_ms])
	quit(0)
