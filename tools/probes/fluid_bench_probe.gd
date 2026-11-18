extends SceneTree

## What the water costs (Docs/MineWater.md 12, measured before stage 5).
##
##     godot --headless --path . --script res://tools/probes/fluid_bench_probe.gd
##
## A TIMING probe: only trustworthy with the editor closed, no other test run
## going and a cool machine (CLAUDE.md). It checks nothing; it prints:
## - a flood: 64 sources on a wide floor spreading at once, ticks with
##   thousands of cells awake -- the doc's "a tick with 20k active cells";
## - a spill: 10,000 water bricks dropped and spreading (still water);
## - calm: the same world settled, ticks with nothing awake (should be ~0);
## - a sea: a generated world with the sea on, a channel dug off it;
## - the save's scan of every section (main thread, each autosave).
## Each as ticks, cells evaluated, ms a tick and ns a cell (the per-cell cost
## the plan estimated at 50 ns). The build is godot-cpp's template_debug,
## which is /O2 (optimize=speed_trace), so these are optimised numbers.

const FLOOR := 1000
const W := FLOOR + 1


func _initialize() -> void:
	_run.call_deferred()


## In strips of 64 studs: fill_box refuses more than 200k cells, and a floor
## that silently is not there lets the water fall into the void for ever.
func _floor(x0: int, z0: int, x1: int, z1: int) -> void:
	for sz in range(z0, z1 + 1, 64):
		var ez := mini(sz + 63, z1)
		var r: Dictionary = BrickTerrain.fill_box(Vector3i(x0, FLOOR * 3, sz), Vector3i(x1, FLOOR * 3 + 2, ez), 4, false)
		assert(int(r.changed) > 0)
		BrickFluid.terrain_changed(Vector3i(x0, FLOOR * 3, sz), Vector3i(x1, W * 3 + 2, ez))
	# Walls a brick tall round it, so nothing runs off.
	for b in [[x0, z0, x1, z0], [x0, z1, x1, z1], [x0, z0, x0, z1], [x1, z0, x1, z1]]:
		BrickTerrain.fill_box(Vector3i(b[0], W * 3, b[1]), Vector3i(b[2], W * 3 + 2, b[3]), 4, false)
		BrickFluid.terrain_changed(Vector3i(b[0], W * 3, b[1]), Vector3i(b[2], W * 3 + 2, b[3]))


## Tick until calm or `max_ticks`; the totals of the ticks that did work.
func _measure(label: String, max_ticks: int) -> Dictionary:
	var ms := 0.0
	var mesh_ms := 0.0
	var sample_ms := 0.0
	var columns := 0
	var meshes := 0
	var evals := 0
	var worst := 0.0
	var worst_cells := 0
	var peak_awake := 0
	var ticks := 0
	var busy := 0
	for i in max_ticks:
		var t0 := Time.get_ticks_usec()
		BrickFluid.tick_now(1)
		var wall := float(Time.get_ticks_usec() - t0) / 1000.0
		var s: Dictionary = BrickFluid.stats()
		var tick_ms := float(s.tick_ms)
		var n := int(s.evals)
		ticks += 1
		peak_awake = maxi(peak_awake, BrickFluid.active_count())
		mesh_ms += float(s.mesh_ms)
		sample_ms += float(s.sample_ms)
		columns += int(s.columns)
		meshes += int(s.meshes)
		if n > 0:
			busy += 1
			ms += tick_ms
			evals += n
			if tick_ms > worst:
				worst = tick_ms
				worst_cells = n
		BrickFluid.take()
		if BrickFluid.active_count() == 0 and i > 2:
			break
		if wall > 2000.0:
			break
	var ns := (ms - mesh_ms - sample_ms) * 1.0e6 / maxf(evals, 1)
	print("  [%s] %d ticks (%d busy), %d cells evaluated, peak %d awake; mean %.2f ms a busy tick, worst %.2f ms (%d cells); rules %.0f ns a cell; new columns %d in %.0f ms (%.1f us each); meshing %.0f ms for %d tile meshes (%.2f ms a mesh), %.0f%% of the time" % [
			label, ticks, busy, evals, peak_awake, ms / maxf(busy, 1), worst, worst_cells, ns,
			columns, sample_ms, sample_ms * 1000.0 / maxf(columns, 1), mesh_ms, meshes, mesh_ms / maxf(meshes, 1), 100.0 * mesh_ms / maxf(ms, 0.001)])
	return { "ms": ms, "evals": evals, "ns": ns, "worst": worst }


func _run() -> void:
	print("[fluid_bench] (timing: editor closed, nothing else running)")
	BrickTerrain.set_generator(0)
	BrickTerrain.configure(1337)
	BrickTerrain.clear_terrain_edits()
	BrickFluid.reset(20.0, false)
	BrickFluid.set_centre(Vector3.ZERO, 100000.0)

	# The flood: 64 sources 32 studs apart on a 290-stud floor.
	_floor(-5, -5, 285, 285)
	BrickFluid.tick_now(1)
	for i in 8:
		for j in 8:
			BrickFluid.place(Vector3i(16 + i * 34, W, 16 + j * 34), 1, BrickFluid.SOURCE, 3)
	_measure("flood, 64 sources", 400)
	# Calm: the flood settled, ticks with nothing to do.
	var t0 := Time.get_ticks_usec()
	for i in 100:
		BrickFluid.tick_now(1)
		BrickFluid.take()
	print("  [calm] 100 ticks of a settled flood: %.3f ms a tick, %d awake" % [
			float(Time.get_ticks_usec() - t0) / 100000.0, BrickFluid.active_count()])

	# The spill: 10,000 water bricks dropped from three bricks up.
	_floor(1995, -5, 2205, 205)
	BrickFluid.tick_now(1)
	for x in range(2050, 2150):
		for z in range(50, 150):
			BrickFluid.place(Vector3i(x, W + 3, z), 1, BrickFluid.STILL, 3)
	_measure("spill, 10k bricks", 600)
	var by_b := {}
	for x in range(2000, 2201, 2):
		for z in range(0, 201, 2):
			for b in range(W - 1, W + 5):
				var c: Dictionary = BrickFluid.cell_info(Vector3i(x, b, z))
				if int(c.fluid) != 0:
					by_b[b - W] = int(by_b.get(b - W, 0)) + int(c.amount)
	print("  [spill] where it is (every 4th column, tiles by course over the floor): %s, %d timers" % [
			by_b, int(BrickFluid.stats().timers)])

	# The save's scan (on the main thread, every autosave): all of the above.
	var ts := Time.get_ticks_usec()
	var save := BrickFluid.get_save()
	print("  [save] %d sections scanned, %d changed cells, %d bytes, %.1f ms" % [
			BrickFluid.section_count(), (save.size() - 5) / 15, save.size(),
			float(Time.get_ticks_usec() - ts) / 1000.0])

	# The sea: a generated world, a channel dug off a coast.
	BrickTerrain.clear_terrain_edits()
	BrickTerrain.set_generator(1)
	BrickTerrain.reset_gen_params()
	var gen: Dictionary = BrickTerrain.get_gen_params()
	gen["water"] = true
	BrickTerrain.set_gen_params(gen)
	BrickFluid.reset(20.0, true)
	BrickFluid.set_centre(Vector3.ZERO, 100000.0)
	var sea_b := BrickFluid.get_sea_course()
	var coast := Vector2i(1 << 30, 0)
	for r in range(0, 12000, 16):
		var h := BrickTerrain.surface_plate(r, 0)
		if h < sea_b * 3 - 9:
			coast = Vector2i(r, 0)
			break
	if coast.x != 1 << 30:
		var t1 := Time.get_ticks_usec()
		var field := BrickWave.compute_shore_field(coast.x, coast.y, 3072, 8)
		print("  [shore field] 3072 studs each way, every 8: %.0f ms (%d samples)" % [
				float(Time.get_ticks_usec() - t1) / 1000.0, field.size() / 2])
		for i in range(1, 40):
			var x := coast.x - i
			var h := BrickTerrain.surface_plate(x, 0)
			BrickTerrain.fill_box(Vector3i(x, (sea_b - 3) * 3, -2), Vector3i(x, maxi(h, (sea_b - 3) * 3), 2), 0, false)
			BrickFluid.terrain_changed(Vector3i(x, (sea_b - 3) * 3, -2), Vector3i(x, maxi(h, (sea_b - 3) * 3), 2))
		_measure("sea channel, 39 studs", 400)
	BrickTerrain.set_generator(0)
	BrickTerrain.reset_gen_params()
	BrickFluid.reset(20.0, false)
	BrickTerrain.clear_terrain_edits()
	print("[fluid_bench] done")
	quit(0)
