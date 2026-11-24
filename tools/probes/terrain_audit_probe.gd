extends SceneTree

## The mine world's ground, mesh and colliders against the field
## (Docs/MineWorld.md 20). Headless.
##
##     godot --headless --path . --script res://tools/probes/terrain_audit_probe.gd
##
## What each check is for (BrickTerrain.audit_tile does the counting):
##
##   * see-through faces: every face of a solid cell that open air touches is
##     covered by a triangle of the tile's flat mesh. A face left out is a
##     hole you see the sky through (a top piece's side over a cave, a partly
##     covered face).
##   * invisible walls: no collider box holds open air under its column's
##     top. A box there is a wall you walk into where the cave is drawn open.
##   * and no holes the other way: every solid cell open air touches is
##     inside a box, or a walker falls through ground that is drawn.
##   * both again with the deep tier on (tiles over their floor, then the
##     sections under them), and after shots have broken bricks.
##   * kept generated cells (Docs/MineWorld.md 21, item 1): a tile built from
##     the kept noise is the same, byte for byte, as one built from the noise
##     afresh -- after shots, a pit dug under the kept cells (deep tier off)
##     and a block placed above every column.
##   * studs (Docs/MineWorld.md 20): the surface keeps a mix of studded and
##     smooth top pieces; cave floors carry studs, more often than the
##     surface; a top piece that a higher column stands on (its bond
##     footprint reaches under it) always has studs.

var failures := 0


func _initialize() -> void:
	BrickTerrain.configure(424242)
	BrickTerrain.set_generator(1)
	BrickTerrain.reset_gen_params()
	BrickTerrain.set_smooth_terrain(false)
	BrickTerrain.set_plate_steps(false)
	BrickTerrain.set_slope_pieces(false)
	BrickTerrain.set_bond_top(true)
	BrickTerrain.set_coarse_smooth_step(0)
	BrickTerrain.clear_terrain_edits()

	_audit("surface tiles", false)
	BrickTerrain.set_deep_tier(true)
	_audit("deep tier on", true)
	_shoot_some()
	_audit("after shots", true)
	_kept_same("deep tier on, after shots", true)
	BrickTerrain.set_deep_tier(false)
	_dig_and_place()
	_kept_same("deep tier off, a pit and a placed block", false)
	BrickTerrain.clear_terrain_edits()

	BrickTerrain.set_generator(0)
	BrickTerrain.set_bond_top(false)
	BrickTerrain.set_coarse_smooth_step(8)
	print("[audit] %s (%d failures)" % ["PASS" if failures == 0 else "FAIL", failures])
	quit(1 if failures > 0 else 0)


func _tiles() -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for i in 30:
		out.append(Vector2i(i * 5 - 80, 37 - i * 3))
	return out


func _audit(label: String, deep: bool) -> void:
	var exposed := 0
	var undrawn := 0
	var dirs := PackedInt32Array([0, 0, 0, 0, 0, 0])
	var air_top := 0
	var air_cave := 0
	var bare := 0
	var bex := []
	var ex := []
	var aex := []
	var sec_n := 0
	var st := {}
	for t in _tiles():
		var a: Dictionary = BrickTerrain.audit_tile(t.x, t.y, -2147483648)
		var parts: Array = [a]
		if deep:
			var top := BrickTerrain.deep_top(t.x, t.y)
			var sp := BrickTerrain.get_deep_section_plates()
			var sy0 := floori(float(top - 1) / sp)
			for sy in range(sy0, sy0 - 3, -1):
				var s: Dictionary = BrickTerrain.audit_tile(t.x, t.y, sy)
				if not s.is_empty():
					parts.append(s)
					sec_n += 1
		for p in parts:
			exposed += int(p.exposed)
			undrawn += int(p.undrawn)
			var ud: PackedInt32Array = p.undrawn_dir
			for k in 6:
				dirs[k] += ud[k]
			air_top += int(p.box_air_top)
			air_cave += int(p.box_air_cave)
			bare += int(p.uncollided)
			for k in ["top_cells", "top_studded", "held", "held_bare", "cave_cells", "cave_studded"]:
				st[k] = int(st.get(k, 0)) + int(p[k])
			if bex.size() < 6:
				bex.append_array((p.bare_examples as Array).slice(0, 6 - bex.size()))
			if ex.size() < 6:
				ex.append_array((p.examples as Array).slice(0, 6 - ex.size()))
			if aex.size() < 6:
				aex.append_array((p.air_examples as Array).slice(0, 6 - aex.size()))
	print("[audit] %s: %d tiles, %d sections; %d exposed faces, %d undrawn (-x %d +x %d -y %d +y %d -z %d +z %d) %s"
			% [label, _tiles().size(), sec_n, exposed, undrawn, dirs[0], dirs[1], dirs[2], dirs[3], dirs[4], dirs[5], ex])
	print("[audit] %s: open air inside colliders: %d cells in column-top boxes, %d in cave boxes %s"
			% [label, air_top, air_cave, aex])
	print("[audit] %s: %d solid cells open air touches with no collider %s" % [label, bare, bex])
	_expect(exposed > 1000, "%s: the scan found exposed faces (%d)" % [label, exposed])
	_expect(undrawn == 0, "%s: every exposed face is drawn (%d undrawn)" % [label, undrawn])
	_expect(air_top == 0 and air_cave == 0,
			"%s: no collider holds open air (%d top, %d cave)" % [label, air_top, air_cave])
	_expect(bare == 0, "%s: every solid cell open air touches is collided (%d not)" % [label, bare])
	var top_share := float(st.top_studded) / maxf(float(st.top_cells), 1.0)
	var cave_share := float(st.cave_studded) / maxf(float(st.cave_cells), 1.0)
	print("[audit] %s: studs on %.0f%% of %d top-course cells; %d held bricks, %d of them smooth; studs on %.0f%% of %d cave-top cells"
			% [label, top_share * 100.0, st.top_cells, st.held, st.held_bare, cave_share * 100.0, st.cave_cells])
	_expect(top_share > 0.5 and top_share < 0.9, "%s: the surface is a mix of studded and smooth (%.0f%% studded)" % [label, top_share * 100.0])
	_expect(st.held > 0 and st.held_bare == 0, "%s: every brick something stands on has studs (%d of %d smooth)" % [label, st.held_bare, st.held])
	_expect(st.cave_cells > 100 and cave_share > top_share and cave_share < 0.97,
			"%s: cave tops are studded more often than the surface, not always (%.0f%% vs %.0f%%)" % [label, cave_share * 100.0, top_share * 100.0])


## Break bricks round the tiles' middles, the way a shot does (find_brick then
## clear_runs), so the audit sees edited ground too.
func _shoot_some() -> void:
	var stud := BrickWorld.get_stud_metres()
	var plate := BrickWorld.get_plate_metres()
	var n := 0
	for t in _tiles():
		for k in 6:
			var x := t.x * 32 + 4 + k * 5
			var z := t.y * 32 + 6 + (k * 7) % 20
			var top := BrickTerrain.surface_plate(x, z)
			var p := Vector3((x + 0.5) * stud, (top + 0.5) * plate, (z + 0.5) * stud)
			var found: Dictionary = BrickTerrain.find_brick(p, Vector3.UP)
			var runs: PackedInt32Array = found.get("runs", PackedInt32Array())
			if runs.is_empty():
				continue
			var res: Dictionary = BrickTerrain.clear_runs(runs)
			n += int(res.get("removed", 0))
	print("[audit] shots removed %d cells" % n)


## A pit far down (under what a first sample keeps) and a column of blocks
## above the ground, in the first few tiles.
func _dig_and_place() -> void:
	var tiles := _tiles()
	for i in 4:
		var t: Vector2i = tiles[i]
		var x := t.x * 32 + 10
		var z := t.y * 32 + 12
		var top := BrickTerrain.surface_plate(x, z)
		BrickTerrain.fill_box(Vector3i(x, top - 120, z), Vector3i(x + 2, top, z + 2), 0, false)
		BrickTerrain.fill_box(Vector3i(x + 6, top + 1, z), Vector3i(x + 6, top + 40, z), 2, true)


## Every tile (and with the deep tier on, the top 3 sections under it) built
## twice: from the kept cells, then with the field's serial bumped
## (reset_gen_params: the same params) so the noise is sampled afresh.
func _kept_same(label: String, deep: bool) -> void:
	var warm := {}
	var sp := BrickTerrain.get_deep_section_plates()
	for t in _tiles():
		BrickTerrain.build_tile(t.x, t.y)   # keeps the cells if not kept yet
		warm[t] = _bytes(BrickTerrain.build_tile(t.x, t.y))
		if deep:
			var sy0 := floori(float(BrickTerrain.deep_top(t.x, t.y) - 1) / sp)
			for sy in range(sy0, sy0 - 3, -1):
				BrickTerrain.build_section(t.x, sy, t.y)
				warm[Vector3i(t.x, sy, t.y)] = _bytes(BrickTerrain.build_section(t.x, sy, t.y))
	var stats := BrickTerrain.get_tile_pack_stats(true)
	BrickTerrain.reset_gen_params()
	var differ := 0
	for k in warm:
		var d: Dictionary = BrickTerrain.build_tile(k.x, k.y) if k is Vector2i 				else BrickTerrain.build_section(k.x, k.y, k.z)
		if _bytes(d) != warm[k]:
			differ += 1
	var hits := int(stats.get("gen_hits", 0)) + int(stats.get("gen_sec_hits", 0))
	_expect(differ == 0 and int(stats.get("gen_hits", 0)) > 0 and (not deep or int(stats.get("gen_sec_hits", 0)) > 0),
			"%s: %d of %d tiles and sections differ built from kept cells (%d kept-cell hits)"
			% [label, differ, warm.size(), hits])


func _bytes(d: Dictionary) -> PackedByteArray:
	var out := var_to_bytes(d.get("mesh", []))
	out.append_array(var_to_bytes(d.get("boxes", PackedFloat32Array())))
	out.append_array(var_to_bytes(d.get("overlay_bricks", PackedFloat32Array())))
	return out


func _expect(ok: bool, what: String) -> void:
	print("[audit] %s  %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		failures += 1
