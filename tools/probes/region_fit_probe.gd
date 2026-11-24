extends SceneTree

## WHICH BRICK FILL (Docs/TerrainRegions.md 3.3, 11). Headless; a report and
## pictures, not checks: the user picks the mix, the stagger and the
## crossing chance from it.
##
##     godot --headless --path . --script res://tools/probes/region_fit_probe.gd
##
## The mine world's generator (default preset), three 5 x 5 tile areas, the
## surface band. Each variant fits the same ground (TerrainFit.run, C++) and
## is measured over the middle 3 x 3 tiles of each area:
##   * bricks a tile, mean cells a brick, 1x1 share (sand and gravel are
##     1x1 always and counted apart): what the overlay, the survey and the
##     solve pay for, and the look.
##   * shares by footprint against the target, all bricks and the VISIBLE
##     ones (next to air): the look; the user wants each within +-5 points.
##   * heights: the tall bricks' share (the caves' horizontal lines).
##   * along X: both directions used (0.5 is even).
##   * seams over seams per 1000 joints, and over 3 courses: crack planes,
##     what makes an overhang peel (the old pattern: 0 by construction).
##   * joints a brick: how tied in a brick is (stress).
##   * across tile edges, in 4 tiles, across section boundaries, chunks a
##     brick: what a break rebuilds.
##   * fit ms a tile, us a region: the cost (debug build: ratios only).
## Pictures (first area): a wall seen face on, user://dev/region_fit/.

const Presets := preload("res://scripts/terrain/worldgen_presets.gd")

const MIX_A := {
	"2x4": 0.20, "2x2": 0.20, "1x3": 0.03, "1x4": 0.03, "1x5": 0.02, "1x6": 0.02,
	"2x3": 0.04, "2x5": 0.02, "2x6": 0.03, "3x3": 0.02, "3x4": 0.02, "3x5": 0.01, "3x6": 0.01,
	"1x2": 0.25, "1x1": 0.10,
}
const MIX_B := {
	"2x4": 0.25, "2x6": 0.08, "2x2": 0.15, "3x4": 0.05, "3x6": 0.03, "2x3": 0.06, "1x4": 0.05,
	"1x6": 0.03, "3x3": 0.03, "1x3": 0.03, "2x5": 0.03, "1x5": 0.02, "3x5": 0.02,
	"1x2": 0.12, "1x1": 0.05,
}
## Even sizes first: the old pattern's parity trick keeps 2x2 / 2x4 / 2x6
## seams off the course below; 1-wide and odd sizes are what stacks.
const MIX_C := {
	"2x4": 0.30, "2x2": 0.25, "2x6": 0.08, "2x3": 0.04, "1x2": 0.12, "1x4": 0.05, "1x3": 0.03,
	"1x6": 0.03, "3x3": 0.02, "3x4": 0.02, "1x1": 0.06,
}
const FLAT := [1.0, 0.0, 0.0]
const TALL := [0.85, 0.10, 0.05]


func _initialize() -> void:
	var s: Dictionary = Presets.load_settings("res://content/base/worldgen/default.json")
	BrickTerrain.set_flat_mode(false)
	BrickTerrain.set_smooth_terrain(false)
	BrickTerrain.set_plate_steps(false)
	BrickTerrain.set_slope_pieces(false)
	BrickTerrain.set_bond_top(true)
	BrickTerrain.set_coarse_smooth_step(0)
	BrickTerrain.clear_terrain_edits()
	BrickTerrain.configure(int(s.seed))
	BrickTerrain.set_generator(1)
	BrickTerrain.set_deep_tier(true)
	BrickTerrain.reset_gen_params()
	BrickTerrain.set_gen_params(s.gen)

	var areas: Array = _pick_areas()
	var variants: Array = [
		{"name": "old pattern (bond_rect)", "mode": "bond"},
		{"name": "A, no stagger, flat", "shapes": MIX_A, "heights": FLAT},
		{"name": "A, stagger 0, flat, 1 try", "shapes": MIX_A, "heights": FLAT, "stagger": 0.0},
		{"name": "A, stagger 0, flat, 6 tries", "shapes": MIX_A, "heights": FLAT, "stagger": 0.0, "tries": 6},
		{"name": "A, stagger 0, tall, 6 tries", "shapes": MIX_A, "heights": TALL, "stagger": 0.0, "tries": 6},
		{"name": "A, stagger 0, tall, 12 tries", "shapes": MIX_A, "heights": TALL, "stagger": 0.0, "tries": 12},
		{"name": "A, s0, tall, 6 tries, seams x3", "shapes": MIX_A, "heights": TALL, "stagger": 0.0, "tries": 6, "try_seams": 3.0},
		{"name": "A, s0.35, tall, 6 (caves weak)", "shapes": MIX_A, "heights": TALL, "stagger": 0.35, "tries": 6, "try_seams": 0.3},
		{"name": "B (bigger), s0, tall, 6 tries", "shapes": MIX_B, "heights": TALL, "stagger": 0.0, "tries": 6},
		{"name": "C (even), s0, tall, 6 tries", "shapes": MIX_C, "heights": TALL, "stagger": 0.0, "tries": 6},
		{"name": "A, s0, tall, 6, cross 0", "shapes": MIX_A, "heights": TALL, "stagger": 0.0, "tries": 6, "cross": 0.0},
		{"name": "A, s0, tall, 6, cross 0.5", "shapes": MIX_A, "heights": TALL, "stagger": 0.0, "tries": 6, "cross": 0.5},
	]
	var t0 := Time.get_ticks_msec()
	var res: Array = TerrainFit.run(areas, variants)
	print("[fit] %d variants over %d areas in %.1f s (stagger: the tolerance over the best outline's share on seams; 0 = always the best)" % [res.size(), areas.size(), (Time.get_ticks_msec() - t0) / 1000.0])
	for r: Dictionary in res:
		print("[fit]   %s: %d bricks, %d visible, %d sand/gravel" % [r.name, r.bricks, r.visible, r.loose])
	print("[fit] %-34s %6s %5s %9s %9s %6s %7s %6s %6s %6s %6s %5s %5s %6s %6s %7s" % ["variant", "/tile", "cells",
			"1x1%(ore)", "tall2/3%", "alongX", "stack/k", "stack%", "long/k", "jnt/b", "xtile%", "in4%", "xsec%", "chunks",
			"ms/til", "us/reg"])
	for r: Dictionary in res:
		var h: Array = r.heights
		print("[fit] %-34s %6.0f %5.2f %4.1f(%3.1f) %4.1f/%-4.1f %6.2f %7.1f %6.1f %6.1f %6.2f %6.2f %5.2f %5.2f %6.3f %6.1f %7.1f" % [
				str(r.name).left(34), r.per_tile, r.mean_cells, 100.0 * r.ones, 100.0 * r.ore_ones, 100.0 * h[1], 100.0 * h[2],
				r.along_x, r.stacked_k, 100.0 * r.stacked_share, r.long_k, r.joints_per_brick, 100.0 * r.cross_tile, 100.0 * r.in4,
				100.0 * r.cross_sec, r.chunks_per_brick, r.ms_tile, r.us_region])
	# Shares against the targets, for the quota variants.
	for i in res.size():
		var v: Dictionary = variants[i]
		if not v.has("shapes"):
			_shares_plain(res[i])
			continue
		var r: Dictionary = res[i]
		var line := "[fit] shares %-30s" % str(r.name).left(30)
		var off := 0
		for k in v.shapes:
			var t: float = v.shapes[k]
			var a: float = (r.share as Dictionary).get(k, 0.0)
			var vis: float = (r.share_vis as Dictionary).get(k, 0.0)
			var bad := absf(a - t) > 0.05
			if bad:
				off += 1
			line += "  %s %.0f->%.0f/%.0f%s" % [k, 100 * t, 100 * a, 100 * vis, "!" if bad else ""]
		print(line + "   (target->all/visible %%, ! = off by over 5; %d off)" % off)
	DirAccess.make_dir_recursive_absolute(UserPaths.DEV + "region_fit")
	for i in res.size():
		var r: Dictionary = res[i]
		var img := Image.create_from_data(int(r.slice_w), int(r.slice_h), false, Image.FORMAT_RGB8, r.slice)
		var path := UserPaths.DEV + "region_fit/%d.png" % i
		img.save_png(path)
		print("[fit] picture %d (%s): wall at z=%d -> %s" % [i, r.name, int(r.slice_z), ProjectSettings.globalize_path(path)])
	BrickTerrain.set_generator(0)
	BrickTerrain.set_bond_top(false)
	BrickTerrain.set_deep_tier(false)
	quit(0)


## Three 5 x 5 tile areas worth fitting, from a scan of 120 x 120 tiles
## round the origin (the origin itself is beach): the steepest (cliffs and
## overhangs), the steepest with grass on top (medium ground), and the
## highest. Each is the area's corner tile.
func _pick_areas() -> Array:
	var best := [Vector2i.ZERO, Vector2i.ZERO, Vector2i.ZERO]
	var score := [-1.0, -1.0, -1.0]
	var grass := [1, 23, 24, 25, 26, 27]   # grass, podzol and the grass kinds (MAT_ ids)
	for tz in range(-60, 60, 3):
		for tx in range(-60, 60, 3):
			var lo := 1 << 30
			var hi := -(1 << 30)
			var mean := 0.0
			for k in 25:
				var h := BrickTerrain.surface_plate(tx * 32 + 16 + (k % 5) * 32, tz * 32 + 16 + (k / 5) * 32)
				lo = mini(lo, h)
				hi = maxi(hi, h)
				mean += h / 25.0
			var cx := tx * 32 + 80
			var cz := tz * 32 + 80
			var top := BrickTerrain.material_at(cx, cz)
			var steep := float(hi - lo)
			var picks := [steep, steep if top in grass else -1.0, mean]
			for i in 3:
				var t := Vector2i(tx, tz)
				if picks[i] > score[i] and not (t in best.slice(0, i)):
					score[i] = picks[i]
					best[i] = t
	print("[fit] areas: steepest %s (%.0f plates of relief), grassy %s, highest %s (mean %.0f)" % [best[0], score[0], best[1], best[2], score[2]])
	return best


func _shares_plain(r: Dictionary) -> void:
	var keys: Array = (r.share as Dictionary).keys()
	keys.sort_custom(func(a, b): return r.share[a] > r.share[b])
	var line := "[fit] shares %-30s" % str(r.name).left(30)
	for k in keys:
		line += "  %s %.0f/%.0f" % [k, 100 * r.share[k], 100 * (r.share_vis as Dictionary).get(k, 0.0)]
	print(line + "   (all/visible %)")
