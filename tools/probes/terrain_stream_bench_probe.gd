extends SceneTree
## THE STREAMING BENCH (Docs/HandoffBrickPatterns.md, TerrainRegions.md 13):
## what a NEW tile costs to bake, the way the mine world streams them --
## 7 x 7 tiles in rings round a centre, `build_tile` each, cold (a fresh
## process: nothing kept). Two centres: the steepest ground the region fit's
## probe finds (cliffs, caves) and the highest. Run it once with the fit off
## and once with `-- --fitted` (the pattern library), each in its own process.
##
##   Godot --headless --path . --script res://tools/probes/terrain_stream_bench_probe.gd [-- --fitted]
##
## Prints the mean and worst ms a tile and the library's set-up cost. Timing:
## only with the editor closed and nothing else running (CLAUDE.md).

const Presets = preload("res://scripts/terrain/worldgen_presets.gd")
const CENTRES := [Vector2i(56, 41), Vector2i(20, -58)]
const RINGS := 3   # 7 x 7


func _initialize() -> void:
	var s: Dictionary = Presets.load_settings("res://content/base/worldgen/default.json")
	BrickTerrain.set_flat_mode(false)
	BrickTerrain.set_smooth_terrain(false)
	BrickTerrain.set_plate_steps(false)
	BrickTerrain.set_slope_pieces(false)
	BrickTerrain.set_bond_top(true)
	BrickTerrain.clear_terrain_edits()
	BrickTerrain.configure(int(s.seed))
	BrickTerrain.set_generator(1)
	BrickTerrain.set_deep_tier(true)
	BrickTerrain.reset_gen_params()
	BrickTerrain.set_gen_params(s.gen)
	var fitted := "--fitted" in OS.get_cmdline_user_args()
	var t_set := Time.get_ticks_usec()
	if fitted:
		TerrainFit.configure(Presets.complete_bricks({}))
		TerrainFit.set_enabled(true)
	var set_ms := float(Time.get_ticks_usec() - t_set) / 1000.0
	var times: Array[float] = []
	for c: Vector2i in CENTRES:
		for t: Vector2i in _rings(c):
			var t0 := Time.get_ticks_usec()
			var d: Dictionary = BrickTerrain.build_tile(t.x, t.y)
			times.append(float(Time.get_ticks_usec() - t0) / 1000.0)
			if d.is_empty():
				print("[bench] tile %s: empty" % t)
	var sum := 0.0
	var worst := 0.0
	for ms in times:
		sum += ms
		worst = maxf(worst, ms)
	var sorted := times.duplicate()
	sorted.sort()
	print("[bench] %s: %d tiles, a tile mean %.1f ms, median %.1f, worst %.1f; set-up %.0f ms %s" % [
			"PATTERNS (fit on)" if fitted else "old pattern (fit off)", times.size(), sum / times.size(),
			sorted[sorted.size() / 2], worst, set_ms, TerrainFit.get_calibration() if fitted else {}])
	if fitted:
		TerrainFit.set_enabled(false)
	BrickTerrain.set_generator(0)
	BrickTerrain.set_bond_top(false)
	BrickTerrain.set_deep_tier(false)
	quit(0)


## Tiles round `c`, ring by ring outwards, each ring in order round it.
func _rings(c: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = [c]
	for r in range(1, RINGS + 1):
		for dz in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if maxi(absi(dx), absi(dz)) == r:
					out.append(c + Vector2i(dx, dz))
	return out
