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
##   * PATTERNS: the game's picking (the library, Docs/HandoffBrickPatterns.md)
##     on the same ground; `-- --lookup` runs only its consistency check.
## Pictures (first area): a wall seen face on, user://dev/region_fit/.

const Presets := preload("res://scripts/terrain/worldgen_presets.gd")

var failures := 0

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
## About 10 % tall (the user, 2026-11-24).
const TALL10 := [0.90, 0.07, 0.03]
## A deeper band's own mix: bigger and taller blocks down in the caves.
const MIX_DEEP := {
	"2x4": 0.22, "2x6": 0.10, "2x2": 0.15, "3x4": 0.06, "3x6": 0.05, "3x3": 0.04, "2x3": 0.05,
	"1x4": 0.04, "1x6": 0.03, "1x2": 0.18, "1x1": 0.08,
}
## The surface band the probe sees reaches only some metres under the top.
const DEEP_M := 3.0


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
	if "--lookup" in OS.get_cmdline_user_args():
		_check_lookup(areas)
		quit(1 if failures > 0 else 0)
		return
	# The shipped settings (what a new world uses), the deep band left out:
	# the surface band this probe samples is only metres deep.
	var chosen: Dictionary = Presets.complete_bricks({})
	chosen.erase("bands")
	var variants: Array = [
		{"name": "old pattern (bond_rect)", "mode": "bond"},
		_with(chosen, {"name": "one material a brick", "mixed": false}),
		_with(chosen, {"name": "mixed, aim 0"}).merged({"aim": 0.0}, true),
		_with(chosen, {"name": "CHOSEN: mixed, aim +30%"}),
		_with(chosen, {"name": "PATTERNS: library (the game's)", "mode": "patterns"}),
		_with(chosen, {"name": "patterns, not calibrated", "mode": "patterns", "calibrate": false}),
		_with(chosen, {"name": "patterns, 6 calibration steps", "mode": "patterns", "calibrate_steps": 6}),
		_with(chosen, {"name": "mixed, aim +60%", "aim": 0.6}),
		_with(chosen, {"name": "chosen, caves strong too", "cave_stagger": 0.0}),
		_with(chosen, {"name": "chosen + deep band (from %.0f m)" % DEEP_M,
				"bands": [_with(Presets.DEFAULT_BRICKS.bands[0], {"below_m": DEEP_M})]}),
		_with(chosen, {"name": "chosen, cross 0", "cross": 0.0}),
		_with(chosen, {"name": "chosen, no pair merge", "pair_merge": false}),
		_with(chosen, {"name": "chosen, not calibrated", "calibrate": false}),
		_with(chosen, {"name": "chosen, stagger across layers", "stagger_layers": true}),
		_with(chosen, {"name": "chosen, no stagger", "stagger": -1.0, "cave_stagger": -2.0}),
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
		if not v.has("shapes") or not (v.get("bands", []) as Array).is_empty():
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
	_check_lookup(areas)
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
	quit(1 if failures > 0 else 0)


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


## THE PATTERN LIBRARY (Docs/HandoffBrickPatterns.md) the game asks: a
## cell's brick is the brick over it in the pattern its region picks. Every
## cell of a brick must name that same brick -- across the odd courses'
## shifted squares and up a tall brick's courses -- or two tiles (or the
## mesher and the collapse) would disagree on it. Asked over a box at the
## surface and deep down, both depth bands.
func _check_lookup(areas: Array) -> void:
	TerrainFit.configure(Presets.complete_bricks({}))
	TerrainFit.set_enabled(true)
	for a: Vector2i in areas:
		for depth in [0, 200]:
			var x0: int = a.x * 32 + 64
			var z0: int = a.y * 32 + 64
			var c0: int = BrickTerrain.height_at(x0, z0) - 12 - depth
			var checked := 0
			var wrong := 0
			var seen := {}
			for c in range(c0, c0 + 9):
				for z in range(z0, z0 + 40):
					for x in range(x0, x0 + 40):
						var b: Dictionary = TerrainFit.brick_at(x, c, z)
						if b.is_empty():
							wrong += 1
							continue
						var key := Vector3i(b.x, b.c, b.z)
						if seen.has(key):
							continue
						seen[key] = true
						if x < b.x or x >= b.x + b.sx or z < b.z or z >= b.z + b.sz or c < b.c or c >= b.c + b.h:
							wrong += 1
						for cc in range(b.c, b.c + b.h):
							for zz in range(b.z, b.z + b.sz):
								for xx in range(b.x, b.x + b.sx):
									checked += 1
									if TerrainFit.brick_at(xx, cc, zz) != b:
										wrong += 1
			print("[fit] patterns %s %s: %d bricks, %d cells checked, %d wrong" % [
					a, "surface" if depth == 0 else "%d courses down" % depth, seen.size(), checked, wrong])
			if wrong > 0 or checked == 0:
				failures += 1
	print("[fit] library: %s" % TerrainFit.get_calibration())
	TerrainFit.set_enabled(false)
	# The calibration's cells made straight from the generator equal the
	# kept ones (tile and deep sections, built first so they are kept).
	var sp := BrickTerrain.get_deep_section_plates()
	for a: Vector2i in areas:
		var t: Vector2i = a + Vector2i(2, 2)
		BrickTerrain.build_tile(t.x, t.y)
		var floor_p := BrickTerrain.deep_top(t.x, t.y)
		var sy := floori(float(floor_p - 1) / sp)
		BrickTerrain.build_section(t.x, sy, t.y)
		BrickTerrain.build_section(t.x, sy - 1, t.y)
		var g: Dictionary = TerrainFit.check_generated(t, (sy - 1) * sp, BrickTerrain.surface_plate(t.x * 32, t.y * 32) + 60)
		print("[fit] generated cells %s: %d of %d differ, %d tops differ" % [t, g.cells_differ, g.cells, g.tops_differ])
		if int(g.cells_differ) > 0 or int(g.tops_differ) > 0:
			failures += 1
	print("[fit] patterns %s" % ("PASS" if failures == 0 else "FAIL (%d areas disagree)" % failures))


func _with(base: Dictionary, over: Dictionary) -> Dictionary:
	var d := base.duplicate()
	d.merge(over, true)
	return d


func _shares_plain(r: Dictionary) -> void:
	var keys: Array = (r.share as Dictionary).keys()
	keys.sort_custom(func(a, b): return r.share[a] > r.share[b])
	var line := "[fit] shares %-30s" % str(r.name).left(30)
	for k in keys:
		line += "  %s %.0f/%.0f" % [k, 100 * r.share[k], 100 * (r.share_vis as Dictionary).get(k, 0.0)]
	print(line + "   (all/visible %)")
