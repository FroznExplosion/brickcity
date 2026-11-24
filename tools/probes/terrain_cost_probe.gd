extends SceneTree

## WHAT ONE BROKEN BRICK COSTS, step by step, in the mine world's settings
## (Docs/MineWorld.md 21). Headless; a report, not checks.
##
##     godot --headless --path . --script res://tools/probes/terrain_cost_probe.gd
##
## Each step a shot sets off is timed on its own, on this thread, as the game
## runs it on a worker or the main thread:
##
##   * find_brick (worker in play): samples the whole hit tile to find one piece.
##   * clear_runs (main thread): the cells cleared, the edit recorded.
##   * build_tile (a worker): the whole tile again.
##   * TerrainCollapse.survey (worker): the ground round the edit.
##   * the tiles an edit names (a brick at a tile edge rebuilds its neighbour).
## With sky light on and off, so its share shows. Timings are only fair on a
## quiet machine (CLAUDE.md); they are single-thread costs, not frame costs.

const Presets := preload("res://scripts/terrain/worldgen_presets.gd")


func _initialize() -> void:
	var s: Dictionary = Presets.load_settings("res://content/base/worldgen/default.json")
	BrickTerrain.set_flat_mode(false)
	BrickTerrain.set_smooth_terrain(false)
	BrickTerrain.set_plate_steps(false)
	BrickTerrain.set_slope_pieces(false)
	BrickTerrain.set_bond_top(true)
	BrickTerrain.set_coarse_smooth_step(0)
	BrickTerrain.set_sun_direction(Vector3.ZERO)
	BrickTerrain.clear_terrain_edits()
	BrickTerrain.configure(int(s.seed))
	BrickTerrain.set_generator(1)
	BrickTerrain.set_deep_tier(true)
	BrickTerrain.reset_gen_params()
	BrickTerrain.set_gen_params(s.gen)
	var stud := BrickWorld.get_stud_metres()
	print("[cost] stud %.3f m, tile %d studs (%.1f m)" % [stud, BrickTerrain.get_tile_studs(),
			BrickTerrain.get_tile_studs() * stud])
	for sky in [true, false]:
		BrickTerrain.set_sky_light(sky)
		BrickTerrain.configure(int(s.seed))
		BrickTerrain.set_gen_params(s.gen)
		_run(sky, stud)
	# The mine world's bake: sky light on, the faces behind the overlay's
	# bricks too (Docs/BrickOverlay.md 6b).
	BrickTerrain.set_sky_light(true)
	BrickTerrain.set_behind_faces(true)
	BrickTerrain.configure(int(s.seed))
	BrickTerrain.set_gen_params(s.gen)
	print("[cost] with behind faces:")
	_run(true, stud)
	BrickTerrain.set_behind_faces(false)
	BrickTerrain.set_generator(0)
	BrickTerrain.set_bond_top(false)
	quit(0)


func _ms(t0: int) -> float:
	return (Time.get_ticks_usec() - t0) / 1000.0


func _run(sky: bool, stud: float) -> void:
	var tile := BrickTerrain.get_tile_studs()
	var sums := {}
	var n := 0
	var tiles_named := 0
	var tris := 0
	var verts := 0
	var boxes := 0
	var solved := 0
	for k in 12:
		var tx := 3 + k * 2
		var tz := -5 + k
		# Warm: the tile drawn once, as the game has it before it is shot.
		var t0 := Time.get_ticks_usec()
		var d: Dictionary = BrickTerrain.build_tile(tx, tz)
		_add(sums, "build_tile (first)", _ms(t0))
		var m: Array = d.get("mesh", [])
		if m.size() > Mesh.ARRAY_INDEX and m[Mesh.ARRAY_VERTEX] != null:
			verts += (m[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
			var ix = m[Mesh.ARRAY_INDEX]
			tris += (ix.size() if ix != null else (m[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()) / 3
		boxes += (d.get("boxes", PackedFloat32Array()) as PackedFloat32Array).size() / 6
		# A shot into the middle of the tile, down onto its top.
		var cx := tx * tile + 9 + k
		var cz := tz * tile + 11
		var top := float(BrickTerrain.surface_plate(cx, cz) + 1) * BrickWorld.get_plate_metres()
		var p := Vector3((cx + 0.5) * stud, top - 0.05, (cz + 0.5) * stud)
		t0 = Time.get_ticks_usec()
		var f: Dictionary = BrickTerrain.find_brick(p, Vector3.UP)
		_add(sums, "find_brick", _ms(t0))
		var runs: PackedInt32Array = f.get("runs", PackedInt32Array())
		if runs.is_empty():
			continue
		t0 = Time.get_ticks_usec()
		var res: Dictionary = BrickTerrain.clear_runs(runs)
		_add(sums, "clear_runs (main)", _ms(t0))
		tiles_named += (res.get("tiles", PackedInt32Array()) as PackedInt32Array).size() / 2
		# The next shot, before the rebuild: the edit made the pack stale.
		t0 = Time.get_ticks_usec()
		BrickTerrain.find_brick(p + Vector3(-stud * 3, 0, 0), Vector3.UP)
		_add(sums, "find_brick (right after an edit)", _ms(t0))
		t0 = Time.get_ticks_usec()
		BrickTerrain.build_tile(tx, tz)
		_add(sums, "build_tile (after edit)", _ms(t0))
		t0 = Time.get_ticks_usec()
		BrickTerrain.find_brick(p + Vector3(stud * 3, 0, 0), Vector3.UP)
		_add(sums, "find_brick (tile kept)", _ms(t0))
		if res.has("box_lo"):
			t0 = Time.get_ticks_usec()
			var r: Dictionary = TerrainCollapse.survey(res.box_lo, res.box_hi,
					BrickStrength.tension() * 4.0, BrickPalette.MASS_PER_CELL)
			_add(sums, "TerrainCollapse.survey", _ms(t0))
			solved += 1 if bool(r.get("solved", false)) else 0
		n += 1
	print("[cost] sky light %s, %d shots (%d surveys solved), %.1f tiles named a shot; a tile: %d verts, %d tris, %d boxes" % [
			"ON" if sky else "off", n, solved, float(tiles_named) / maxf(1.0, n), verts / 12, tris / 12, boxes / 12])
	for key in sums:
		var a: Array = sums[key]
		var tot := 0.0
		var worst := 0.0
		for v in a:
			tot += float(v)
			worst = maxf(worst, float(v))
		print("  %-36s mean %6.2f ms  worst %6.2f ms" % [key, tot / a.size(), worst])
	print("  pack store: %s" % BrickTerrain.get_tile_pack_stats(true))
	BrickTerrain.clear_terrain_edits()


func _add(sums: Dictionary, key: String, v: float) -> void:
	if not sums.has(key):
		sums[key] = []
	(sums[key] as Array).append(v)
