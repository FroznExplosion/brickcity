extends SceneTree

## What one intact brick building costs, by its parts, for the question "how
## many can stand in bricks round the player" (Docs/PlanetCost.md 4).
##
##     godot --headless --path . --script res://tools/probes/building_budget_probe.gd
##
## The planet towns' sizes (PlanetBuildings.add_town: 24-36 studs a side,
## 12-60 courses) and a city tower: bricks, CPU memory by BrickWorld's own
## report (blocks, occupancy, joints, the bake), the GPU's share drawn as baked
## faces (the planet's way) and as a box a brick (the city's), collision shapes
## merged, and the time to make each. Prints; checks nothing.

const SIZES := [[24, 24, 12], [30, 30, 36], [36, 36, 60], [30, 40, 60]]
const VERT_BYTES := 56


func _ms(t: int) -> float:
	return float(Time.get_ticks_usec() - t) / 1000.0


func _mb(b: float) -> float:
	return b / 1048576.0


func _init() -> void:
	var w := BrickWorld.new()
	w.set_seed(4)
	var palette := TowerRecipe.bake_palette(w)
	var reg := BuildingRegistry.new(w, palette)
	for size in SIZES:
		reg.register(int(size[0]), int(size[1]), int(size[2]), Transform3D(Basis(), Vector3(0.0, 0.0, -400.0)))
	reg.prepare_templates()
	var n := 0
	for size in SIZES:
		n += 1
		var before: Dictionary = w.get_memory_report()
		var id := reg.register(int(size[0]), int(size[1]), int(size[2]),
				Transform3D(Basis(), Vector3(n * 80.0, 0.0, 0.0)))
		var t := Time.get_ticks_usec()
		var chunk := reg.materialise(id)
		var lay_ms := _ms(t)
		var bricks := w.get_alive_block_count(chunk)
		var laid: Dictionary = w.get_memory_report()
		t = Time.get_ticks_usec()
		w.bake_chunk_async(chunk)
		while not w.bake_ready(chunk):
			OS.delay_usec(100)
		var bake_ms := _ms(t)
		var baked: Dictionary = w.get_memory_report()
		var arrays: Array = w.build_chunk_mesh(chunk)
		var st: Dictionary = w.get_mesh_stats(chunk)
		var verts := (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() if not arrays.is_empty() else 0
		var bufs: Array = w.get_instance_buffers(chunk, PackedInt32Array(), PackedInt64Array())
		var floats := 0
		for e in bufs:
			floats += ((e as Dictionary).buffer as PackedFloat32Array).size()
		var sections := w.get_chunk_sections(chunk)
		var coarse: Array = w.build_chunk_coarse_mesh(chunk)
		var coarse_tris := (coarse[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3 if not coarse.is_empty() else 0
		var cpu_laid := float(laid.total_bytes) - float(before.total_bytes) if laid.has("total_bytes") else -1.0
		var cpu_bake := float(baked.total_bytes) - float(laid.total_bytes) if baked.has("total_bytes") else -1.0
		print("\n%dx%d studs, %d courses: %d bricks, %d bands; laid from its template in %.1f ms, baked in %.1f ms" % [
				size[0], size[1], size[2], bricks, sections, lay_ms, bake_ms])
		print("  CPU, the bricks themselves (blocks, occupancy, joints): %.2f MB (%.0f bytes a brick)" % [
				_mb(cpu_laid), cpu_laid / maxf(bricks, 1)])
		print("  CPU, its bake (kept for hits): %.2f MB" % _mb(cpu_bake))
		print("  GPU, baked faces: %d verts, %.2f MB, %d tris drawn" % [verts, _mb(verts * VERT_BYTES), int(st.get("triangles", 0))])
		print("  GPU, a box a brick: %d instances, %.2f MB, %d tris (%d bevelled near)" % [
				floats / 20, _mb(floats * 4), floats / 20 * 12, floats / 20 * 36])
		print("  coarse stand-in: %d tris" % coarse_tris)
	print("\nmemory report keys: %s" % [w.get_memory_report().keys()])
	quit(0)
