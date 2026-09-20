extends SceneTree

## How many buildings fit, measured rather than extrapolated.
##
##     godot --headless --path . --script tools/city_probe.gd
##
## Builds towers one at a time and reports where the memory actually goes, so
## the M3 case (a building is a recipe until something damages it) rests on
## numbers instead of arithmetic. No rendering, no physics -- this is about what
## BrickWorld itself costs to hold.

const COURSE_COUNTS := [40, 120, 357]   # 17 m, 50 m, 150 m
const FOOTPRINTS := {40: Vector2i(24, 16), 120: Vector2i(32, 32), 357: Vector2i(48, 48)}


func _initialize() -> void:
	for courses in COURSE_COUNTS:
		_measure_one(courses)
	_measure_many(357, 8)
	_measure_many(40, 64)
	_measure_registry(5000)
	_check_damage_survives_dematerialise()
	_check_shell_streaming()
	quit(0)


func _mb(bytes: float) -> String:
	return "%.1f MB" % (bytes / 1048576.0)


## Every building gets its OWN chunk at grid origin and is placed in the world
## by its transform. Chunks have independent grids, so they do not need to be
## spread out in grid space -- and the recipe places at absolute coordinates
## from zero, so giving a chunk a non-zero origin silently produces an empty
## building. (It did: the first version of this probe reported eight towers
## holding exactly one tower's worth of blocks.)
func _build(w: BrickWorld, palette: Dictionary, courses: int, index: int) -> int:
	var fp: Vector2i = FOOTPRINTS[courses]
	var c := w.create_chunk(Vector3i.ZERO, TowerRecipe.chunk_dims(fp.x, fp.y, courses))
	TowerRecipe.build(w, c, palette, fp.x, fp.y, courses)
	w.set_chunk_transform(c, Transform3D(Basis(),
			Vector3(index * (fp.x + 8) * BrickWorld.get_stud_metres(), 0.0, 0.0)))
	return c


func _measure_one(courses: int) -> void:
	var fp: Vector2i = FOOTPRINTS[courses]
	var height: float = courses * TowerRecipe.PLATES_PER_COURSE * BrickWorld.get_plate_metres()
	print("
=== one tower: %d courses, %.0f m, %dx%d studs ===" % [courses, height, fp.x, fp.y])

	var w := BrickWorld.new()
	var palette := TowerRecipe.bake_palette(w)

	var t0 := Time.get_ticks_usec()
	var c := _build(w, palette, courses, 0)
	var build_ms := (Time.get_ticks_usec() - t0) / 1000.0

	# Untouched: no mesh has been asked for, so nothing is baked.
	var cold: Dictionary = w.get_memory_report()
	print("  built      %d blocks in %.1f ms" % [w.get_block_count(c), build_ms])
	print("  unbaked    %s total  (occupancy %s, blocks %s)" % [
		_mb(cold.total_bytes), _mb(cold.occupancy_bytes), _mb(cold.block_bytes)])

	var t1 := Time.get_ticks_usec()
	w.build_chunk_mesh(c)
	var bake_ms := (Time.get_ticks_usec() - t1) / 1000.0
	var hot: Dictionary = w.get_memory_report()
	var ms: Dictionary = w.get_mesh_stats(c)
	print("  baked      %s total in %.1f ms  (verts %s, indices %s, topology %s)" % [
		_mb(hot.total_bytes), bake_ms, _mb(hot.bake_vertex_bytes),
		_mb(hot.index_bytes), _mb(hot.bake_topology_bytes)])
	print("  faces      %d baked, %d drawn -> %d triangles" % [
		ms.baked_faces, ms.faces_emitted, ms.triangles])
	print("  per block  %.0f B unbaked, %.0f B baked" % [
		cold.bytes_per_block, hot.bytes_per_block])
	print("  the bake is %.1fx the resting cost" % (float(hot.total_bytes) / maxf(float(cold.total_bytes), 1.0)))


func _measure_many(courses: int, count: int) -> void:
	var fp: Vector2i = FOOTPRINTS[courses]
	var height: float = courses * TowerRecipe.PLATES_PER_COURSE * BrickWorld.get_plate_metres()
	print("
=== %d towers of %.0f m, standing, nothing damaged ===" % [count, height])

	var w := BrickWorld.new()
	var palette := TowerRecipe.bake_palette(w)
	var chunks: Array[int] = []

	var t0 := Time.get_ticks_usec()
	for i in count:
		chunks.append(_build(w, palette, courses, i))
	var build_ms := (Time.get_ticks_usec() - t0) / 1000.0
	var cold: Dictionary = w.get_memory_report()
	print("  built      %d blocks across %d chunks in %.0f ms  (%d per tower)" % [
		cold.blocks, cold.chunks, build_ms, int(cold.blocks) / max(count, 1)])
	print("  unbaked    %s" % _mb(cold.total_bytes))

	# Now ask every one of them for a mesh, which is what "visible" costs today.
	var t1 := Time.get_ticks_usec()
	for c in chunks:
		w.build_chunk_mesh(c)
	var bake_ms := (Time.get_ticks_usec() - t1) / 1000.0
	var hot: Dictionary = w.get_memory_report()
	print("  baked      %s in %.0f ms  (%.0f ms per tower)" % [
		_mb(hot.total_bytes), bake_ms, bake_ms / count])
	print("             verts %s, indices %s, occupancy %s, blocks %s" % [
		_mb(hot.bake_vertex_bytes), _mb(hot.index_bytes),
		_mb(hot.occupancy_bytes), _mb(hot.block_bytes)])
	print("  headroom   %.0f towers in 4 GB at this cost" % (4.0 * 1073741824.0 / maxf(float(hot.total_bytes) / count, 1.0)))


## The M3 gate: 5000 buildings registered, none of them holding bricks.
func _measure_registry(count: int) -> void:
	print("
=== %d buildings as recipes (Plan B1) ===" % count)
	var w := BrickWorld.new()
	var palette := TowerRecipe.bake_palette(w)
	var reg := BuildingRegistry.new(w, palette)

	var t0 := Time.get_ticks_usec()
	for i in count:
		# A mix of heights, laid out on a grid, none of them touched.
		var courses: int = COURSE_COUNTS[i % COURSE_COUNTS.size()]
		var fp: Vector2i = FOOTPRINTS[courses]
		var x := (i % 80) * 60.0
		var z := float(i / 80) * 60.0
		reg.register(fp.x, fp.y, courses, Transform3D(Basis(), Vector3(x, 0.0, z)))
	var register_ms := (Time.get_ticks_usec() - t0) / 1000.0

	var mem: Dictionary = w.get_memory_report()
	var rep: Dictionary = reg.report()
	print("  registered %d buildings in %.0f ms" % [rep.buildings, register_ms])
	print("  BrickWorld holds %s across %d chunks" % [_mb(mem.total_bytes), mem.chunks])
	print("  materialised %d, damaged %d, live blocks %d" % [
		rep.materialised, rep.damaged, rep.live_blocks])

	# Now shoot a handful and see what materialising costs.
	var hits := 12
	var t1 := Time.get_ticks_usec()
	for i in hits:
		var b: BuildingRegistry.Building = reg.buildings[i * 137 % count]
		reg.damage(b.id, b.xform.origin + Vector3(1.0, 2.0, 0.5), 1.4)
	var damage_ms := (Time.get_ticks_usec() - t1) / 1000.0

	mem = w.get_memory_report()
	rep = reg.report()
	print("  after %d hits: %s, %d materialised, %d damaged, %.0f ms (%.1f ms per building)" % [
		hits, _mb(mem.total_bytes), rep.materialised, rep.damaged,
		damage_ms, damage_ms / hits])

	# Give the bricks back. The damage stays.
	var freed := reg.trim(Vector3(1e9, 0, 0), 1.0, 0, count)
	mem = w.get_memory_report()
	rep = reg.report()
	print("  after trimming %d: %s, %d materialised, %d still damaged" % [
		freed, _mb(mem.total_bytes), rep.materialised, rep.damaged])
	print("  >> %s for %d buildings, %d of them damaged" % [
		_mb(mem.total_bytes), rep.buildings, rep.damaged])


## Damage has to survive the bricks being given back and rebuilt.
func _check_damage_survives_dematerialise() -> void:
	print("
=== damage is permanent across de-materialisation ===")
	var w := BrickWorld.new()
	var palette := TowerRecipe.bake_palette(w)
	var reg := BuildingRegistry.new(w, palette)
	var id := reg.register(24, 16, 40, Transform3D())

	var c := reg.materialise(id)
	var before := w.get_alive_block_count(c)
	reg.damage(id, Vector3(2.0, 3.0, 0.3), 1.6)
	var after := w.get_alive_block_count(c)
	var record := reg.get_building(id).dead.size()
	print("  %d blocks -> %d standing, damage record holds %d" % [before, after, record])

	reg.dematerialise(id)
	print("  de-materialised: %d chunks live" % int(w.get_memory_report().chunks))

	var c2 := reg.materialise(id)
	var rebuilt := w.get_alive_block_count(c2)
	if rebuilt == after:
		print("  ok    rebuilt with the same %d standing -- the hole came back" % rebuilt)
	else:
		print("  FAIL  rebuilt with %d standing, expected %d" % [rebuilt, after])


## What the far tier actually costs, and what streaming it saves.
##
## A registered building nobody can see is a recipe and a damage record. The
## question M4 has to answer is what the ones you CAN see cost, because that is
## the number that has to stay flat as the city grows.
func _check_shell_streaming() -> void:
	print("
=== 5000 buildings, shells streamed by distance ===")
	var w := BrickWorld.new()
	var palette := TowerRecipe.bake_palette(w)
	var reg := BuildingRegistry.new(w, palette)

	# A 71 x 71 grid on 13 m spacing: the same spacing the city scene uses.
	var spacing := 13.0
	var side := 71
	# The same mix of shapes the city scene uses.
	var shapes := [
		{"x": 16, "z": 16, "courses": 18},
		{"x": 20, "z": 16, "courses": 30},
		{"x": 24, "z": 20, "courses": 46},
		{"x": 16, "z": 24, "courses": 62},
		{"x": 28, "z": 20, "courses": 26},
		{"x": 20, "z": 20, "courses": 80},
	]
	var placed := 0
	var positions: Array[Vector3] = []
	for row in side:
		for col in side:
			if placed >= 5000:
				break
			var sh: Dictionary = shapes[placed % shapes.size()]
			var pos := Vector3(col * spacing, 0.0, row * spacing)
			positions.append(pos)
			reg.register(sh.x, sh.z, sh.courses, Transform3D(Basis(), pos))
			placed += 1

	# Stand in the middle and count what is inside the shell range.
	var here := Vector3(side * spacing * 0.5, 20.0, side * spacing * 0.5)
	var range_m := 260.0
	var near_ids: Array[int] = []
	for i in positions.size():
		if positions[i].distance_to(here) < range_m:
			near_ids.append(i)
	print("  registered %d buildings, %d of them within %.0f m" % [
			placed, near_ids.size(), range_m])

	# Build the resident set at the tier each building would actually get, and
	# measure it against the naive version where every shell is detailed.
	var detail_m := 110.0
	var t0 := Time.get_ticks_usec()
	var tris := 0
	var bytes := 0
	var naive_tris := 0
	var naive_bytes := 0
	var detailed := 0
	var meshes: Array[ArrayMesh] = []
	for i in near_ids:
		var sh: Dictionary = shapes[i % shapes.size()]
		var near := positions[i].distance_to(here) <= detail_m
		if near:
			detailed += 1
		var mesh := (BuildingShell.build_mesh(sh.x, sh.z, sh.courses) if near
				else BuildingShell.build_coarse_mesh(sh.x, sh.z, sh.courses))
		meshes.append(mesh)
		var t := _mesh_cost(mesh)
		tris += int(t.tris)
		bytes += int(t.bytes)
		var full := _mesh_cost(BuildingShell.build_mesh(sh.x, sh.z, sh.courses))
		naive_tris += int(full.tris)
		naive_bytes += int(full.bytes)
	var ms := (Time.get_ticks_usec() - t0) / 1000.0
	print("  resident shells: %d (%d detailed, %d coarse), %d triangles, %.1f MB, built in %.0f ms" % [
			near_ids.size(), detailed, near_ids.size() - detailed, tris,
			float(bytes) / 1048576.0, ms])
	print("  all-detailed instead: %d triangles, %.1f MB -- the coarse tier saves %.0f%%" % [
			naive_tris, float(naive_bytes) / 1048576.0,
			(1.0 - float(bytes) / maxf(naive_bytes, 1)) * 100.0])
	var all_bytes := float(naive_bytes) / maxf(near_ids.size(), 1) * placed
	print("  without streaming at all the city is %.1f MB of shell geometry" % [
			all_bytes / 1048576.0])
	var mem: Dictionary = w.get_memory_report()
	print("  BrickWorld still holds %.1f MB across %d chunks" % [
			float(mem.total_bytes) / 1048576.0, mem.chunks])
	if near_ids.size() < placed:
		print("  ok    the resident set is %.0f%% of the city" % [
				float(near_ids.size()) / placed * 100.0])
	else:
		print("  FAIL  streaming saved nothing")


## Triangles and an estimate of the vertex+index bytes a mesh will occupy:
## 12 B position, 12 normal, 16 colour, 8 uv, 8 uv2, plus 4 B per index.
func _mesh_cost(mesh: ArrayMesh) -> Dictionary:
	var faces := mesh.get_faces()
	@warning_ignore("integer_division")
	var tris := faces.size() / 3
	return {"tris": tris, "bytes": faces.size() * 56 + tris * 3 * 4}
