extends SceneTree

## The biome generator's probe (Docs/MineWorld.md). Headless.
##
##     godot --headless --path . --script res://tools/probes/mine_world_probe.gd
##
## What each check is for:
##
##   * params round-trip: the world-gen menu writes a Dictionary and reads it
##     back; a key that does not come back is a slider that does nothing.
##   * classic untouched: every other scene keeps the old field. Turning the
##     biome generator on and off again must leave height_at as it was.
##   * determinism: the same seed and params give the same world, a new seed
##     a different one -- streaming rebuilds tiles in any order.
##   * biome mix: every biome the defaults list shows up somewhere in 8 km.
##   * relief: basins below the sea line, mountains well above it.
##   * overhangs: solid over air above the 2D surface, on cliff ground.
##   * ores and layers: ores in stone at their depths, bedrock at the floor
##     and carve cannot remove it.
##   * bake cost: a tile and a coarse block, so streaming stays affordable.
##   * Generate: new params change the world.
##   * build mode: the ray finds the cell and face it looks at; a block placed
##     ABOVE the generated ground is solid, raises the surface and is in the
##     baked tile (the mask reaches up to it); breaking it leaves air; fill
##     never breaks bedrock.
##   * a shot breaks WHOLE bricks: the surface piece hit goes, all of it, and
##     every other piece of the tile is laid exactly as before (no re-laying
##     round the hole); a wall hit takes one brick cell.

var failures := 0
var _names: PackedStringArray


func _initialize() -> void:
	BrickTerrain.configure(424242)
	_names = BrickTerrain.material_names()
	var classic_before := _classic_sample()
	BrickTerrain.set_generator(1)
	BrickTerrain.reset_gen_params()
	BrickTerrain.set_smooth_terrain(false)
	BrickTerrain.set_plate_steps(false)
	# The mine world's top course: on the ground's bond (Docs/TerrainBond.md).
	BrickTerrain.set_bond_top(true)

	_check_params_roundtrip()
	_check_determinism()
	_check_biomes_and_relief()
	_check_overhangs()
	_check_ores_and_bedrock()
	_check_bake_cost()
	_check_regenerate()
	_check_preview()
	_check_build_blocks()
	_check_break_brick()
	_check_bond()
	_check_pick_area()
	_check_cave_colliders()
	_check_deep_tier()
	await _check_solid_trunks()

	BrickTerrain.set_generator(0)
	BrickTerrain.set_bond_top(false)
	var classic_after := _classic_sample()
	_expect(classic_before == classic_after, "classic generator unchanged after biomes on/off")

	print("[mine] %s (%d failures)" % ["PASS" if failures == 0 else "FAIL", failures])
	quit(1 if failures > 0 else 0)


## Cave floors are collided (Docs/MineWorld.md 13): build_tile's boxes
## follow column tops, and a cave floor under a column had no box -- the pawn
## fell through bricks it could see. Every cave floor found under the tiles
## scanned must be inside a box (a sealed chamber may not be: it is not drawn
## either), and the cave boxes must not cost the bake much.
func _check_cave_colliders() -> void:
	BrickTerrain.clear_terrain_edits()
	var stud := BrickWorld.get_stud_metres()
	var plate := BrickWorld.get_plate_metres()
	var floors := 0
	var held := 0
	var tiles := 0
	var cave_boxes := 0
	var all_boxes := 0
	var ms := 0.0
	var missed := ""
	for i in 40:
		var tx := i * 5 - 100
		var tz := 37 - i * 3
		var t0 := Time.get_ticks_usec()
		var d: Dictionary = BrickTerrain.build_tile(tx, tz)
		ms += float(Time.get_ticks_usec() - t0) / 1000.0
		tiles += 1
		# The tile's own plates only: under its floor the deep caves are the
		# deep tier's (_check_deep_tier).
		var floor_p := BrickTerrain.deep_top(tx, tz)
		cave_boxes += int(d.get("cave_box_count", 0))
		var boxes: PackedFloat32Array = d.boxes
		all_boxes += boxes.size() / 6
		for lz in range(1, 32, 6):
			for lx in range(1, 32, 6):
				var x := tx * 32 + lx
				var z := tz * 32 + lz
				var top := BrickTerrain.surface_plate(x, z)
				# Down from a brick under the top: the first air, then the floor.
				var yp := top - 4
				var lo := maxi(top - 600, floor_p)
				while yp > lo and BrickTerrain.solid_at(x, yp, z) != 0:
					yp -= 1
				if yp <= lo:
					continue
				var air := 0
				while yp > lo and BrickTerrain.solid_at(x, yp, z) == 0:
					yp -= 1
					air += 1
				if yp <= lo or air < 12:
					continue   # not a room a walker stands in
				floors += 1
				var p := Vector3((lx + 0.5) * stud, (yp + 1) * plate - 0.03, (lz + 0.5) * stud)
				var inside := false
				for o in range(0, boxes.size(), 6):
					var c := Vector3(boxes[o], boxes[o + 1], boxes[o + 2])
					var h := Vector3(boxes[o + 3], boxes[o + 4], boxes[o + 5]) * 0.5
					if absf(p.x - c.x) <= h.x and absf(p.y - c.y) <= h.y and absf(p.z - c.z) <= h.z:
						inside = true
						break
				if inside:
					held += 1
				elif missed == "":
					missed = " (first miss: column %d, %d, floor plate %d, top %d)" % [x, z, yp, top]
	print("[mine] cave floors: %d of %d collided over %d tiles; %d cave boxes of %d, %.1f ms a tile%s"
			% [held, floors, tiles, cave_boxes, all_boxes, ms / tiles, missed])
	_expect(floors > 5, "the scan found cave floors (%d)" % floors)
	_expect(held >= floors * 0.9, "cave floors are collided (%d of %d)" % [held, floors])


## THE DEEP TIER (Docs/MineWorld.md 16): caves go on under a surface tile's
## floor (deep_top) down to the bedrock; with the tier on, a tile draws only
## down to its floor and sections (build_section) draw and collide the rest,
## each only its own plates.
func _check_deep_tier() -> void:
	BrickTerrain.clear_terrain_edits()
	BrickTerrain.set_deep_tier(true)
	var stud := BrickWorld.get_stud_metres()
	var plate := BrickWorld.get_plate_metres()
	var sec := BrickTerrain.get_deep_section_plates()
	var bed := BrickTerrain.get_bedrock_plate()
	# Deep cave air under the floors.
	var cols := 0
	var deep_air := 0
	for i in 60:
		var x := i * 37 - 900
		var z := 400 - i * 23
		var t := Vector2i(floori(float(x) / 32.0), floori(float(z) / 32.0))
		var floor_p := BrickTerrain.deep_top(t.x, t.y)
		for yp in range(bed + 12, floor_p, 3):
			cols += 1
			if BrickTerrain.solid_at(x, yp, z) == 0:
				deep_air += 1
	print("[mine] deep caves: %d of %d cells under the tiles' floors are air (bedrock plate %d)" % [deep_air, cols, bed])
	_expect(deep_air > cols / 50, "caves go on under the surface tiles' floors")
	# Ownership, faces and colliders, over a few tile columns.
	var t_ms := 0.0
	var s_ms := 0.0
	var n_sec := 0
	var tris := 0
	var boxes_n := 0
	var tile_below := 0
	var sec_outside := 0
	var floors := 0
	var held := 0
	for i in 6:
		var tx := i * 9 - 30
		var tz := 11 - i * 7
		var floor_p := BrickTerrain.deep_top(tx, tz)
		var t0 := Time.get_ticks_usec()
		var d: Dictionary = BrickTerrain.build_tile(tx, tz)
		t_ms += float(Time.get_ticks_usec() - t0) / 1000.0
		var mesh: Array = d.mesh
		if not mesh.is_empty():
			for v in (mesh[Mesh.ARRAY_VERTEX] as PackedVector3Array):
				if v.y < floor_p * plate - 0.01:
					tile_below += 1
		for sy in range(floori(float(bed) / sec), floori(float(floor_p) / sec) + 1):
			t0 = Time.get_ticks_usec()
			var s: Dictionary = BrickTerrain.build_section(tx, sy, tz)
			s_ms += float(Time.get_ticks_usec() - t0) / 1000.0
			if not s.has("own_lo"):
				continue
			n_sec += 1
			tris += int(s.triangle_count)
			var boxes: PackedFloat32Array = s.boxes
			boxes_n += boxes.size() / 6
			var sm: Array = s.mesh
			if not sm.is_empty():
				for v in (sm[Mesh.ARRAY_VERTEX] as PackedVector3Array):
					if v.y < int(s.own_lo) * plate - 0.01 or v.y > int(s.own_hi) * plate + 0.01:
						sec_outside += 1
			# Cave floors in this section: inside one of its boxes.
			for lz in range(2, 32, 7):
				for lx in range(2, 32, 7):
					var x := tx * 32 + lx
					var z := tz * 32 + lz
					for yp in range(int(s.own_lo), int(s.own_hi) - 1):
						if BrickTerrain.solid_at(x, yp, z) != 0 and BrickTerrain.solid_at(x, yp + 1, z) == 0 								and BrickTerrain.solid_at(x, yp + 6, z) == 0 and yp + 6 < int(s.own_hi):
							floors += 1
							var p := Vector3((lx + 0.5) * stud, (yp + 1) * plate - 0.03, (lz + 0.5) * stud)
							for o in range(0, boxes.size(), 6):
								if absf(p.x - boxes[o]) <= boxes[o + 3] * 0.5 and absf(p.y - boxes[o + 1]) <= boxes[o + 4] * 0.5 										and absf(p.z - boxes[o + 2]) <= boxes[o + 5] * 0.5:
									held += 1
									break
	print("[mine] deep tier: tiles %.1f ms; %d sections %.1f ms each, %d tris, %d boxes each; tile vertices under its floor %d, section vertices outside its plates %d; deep floors collided %d of %d"
			% [t_ms / 6.0, n_sec, s_ms / maxf(n_sec, 1), tris / maxi(n_sec, 1), boxes_n / maxi(n_sec, 1),
			tile_below, sec_outside, held, floors])
	_expect(n_sec > 6 and tris > 0, "sections draw the deep caves")
	_expect(tile_below == 0, "a tile draws nothing under its floor")
	_expect(sec_outside == 0, "a section draws only its own plates")
	_expect(floors > 5 and held >= floors * 0.9, "deep cave floors are collided (%d of %d)" % [held, floors])
	BrickTerrain.set_deep_tier(false)


## Trees streamed by TerrainTrees have solid trunks near the camera
## (solid_m): a ray at knee height through a near trunk hits it, the same
## ray once the camera has gone far away does not.
func _check_solid_trunks() -> void:
	var cam := Camera3D.new()
	root.add_child(cam)
	var trees := TerrainTrees.new()
	root.add_child(trees)
	await process_frame
	trees.setup(cam, StandardMaterial3D.new())
	trees.stream(7, func(_x: int, _z: int) -> float: return 1.0,
			func(_x: int, _z: int, _r: float) -> int: return 2, 120.0)
	trees.solid_m = 64.0
	for i in 60:
		trees._stream_step()
		if trees._queue.is_empty() and i > 2:
			break
	var counts: Vector2i = trees.solid_counts()
	_expect(counts.y > 0, "trunks near the camera are solid (%d cells, %d trunks)" % [counts.x, counts.y])
	# The nearest tree to the camera, and a ray through its trunk.
	var best: Dictionary = {}
	var best_d := INF
	for c in trees._cells:
		for row in trees._cells[c]:
			var o: Vector3 = (row.xf as Transform3D) * Trees.trunk_foot(int(row.variant))
			var d := Vector2(o.x, o.z).length()
			if d < best_d:
				best_d = d
				best = row
	if best.is_empty():
		_expect(false, "a tree was placed")
		return
	var foot: Vector3 = (best.xf as Transform3D) * Trees.trunk_foot(int(best.variant))
	await physics_frame
	await physics_frame
	var space := root.get_world_3d().direct_space_state
	var knee := foot + Vector3(0, 0.5, 0)
	var q := PhysicsRayQueryParameters3D.create(knee + Vector3(-3, 0, 0), knee + Vector3(3, 0, 0),
			Layers.PAWN_MASK)
	var hit := space.intersect_ray(q)
	_expect(not hit.is_empty() and absf((hit.position as Vector3).x - (knee.x - Trees.trunk_size(int(best.variant)).x * 0.5)) < 0.05,
			"a walker meets the trunk %.0f m from the camera (hit %s)" % [best_d, hit.get("position", "nothing")])
	cam.global_position = Vector3(5000, 0, 5000)
	trees._solid_at = Vector3.INF
	trees._stream_step()
	await physics_frame
	await physics_frame
	hit = space.intersect_ray(q)
	_expect(hit.is_empty(), "the trunk is not solid once the camera is far away")
	trees.queue_free()
	cam.queue_free()


func _expect(ok: bool, what: String) -> void:
	print("[mine] %s  %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		failures += 1


func _mat(n: String) -> int:
	return _names.find(n)


func _classic_sample() -> Array:
	var out := []
	for i in 40:
		out.append(BrickTerrain.height_at(i * 37 - 700, i * 53 - 900))
	return out


func _check_params_roundtrip() -> void:
	var d: Dictionary = BrickTerrain.get_gen_params()
	d["peak_height_m"] = 91.0
	d["caves"] = false
	(d["biomes"] as Array)[4]["hilliness"] = 0.33
	(d["ores"] as Array)[0]["chance"] = 0.21
	BrickTerrain.set_gen_params(d)
	var back: Dictionary = BrickTerrain.get_gen_params()
	var ok := is_equal_approx(float(back["peak_height_m"]), 91.0) and not bool(back["caves"]) \
			and is_equal_approx(float((back["biomes"] as Array)[4]["hilliness"]), 0.33) \
			and is_equal_approx(float((back["ores"] as Array)[0]["chance"]), 0.21)
	var missing := []
	for k in d:
		if not back.has(k):
			missing.append(k)
	_expect(ok and missing.is_empty(), "params round-trip (missing: %s)" % [missing])
	BrickTerrain.reset_gen_params()


func _check_determinism() -> void:
	var a := []
	for i in 60:
		a.append([BrickTerrain.surface_plate(i * 211, -i * 97), BrickTerrain.biome_at(i * 211, -i * 97)])
	var b := []
	for i in 60:
		b.append([BrickTerrain.surface_plate(i * 211, -i * 97), BrickTerrain.biome_at(i * 211, -i * 97)])
	_expect(a == b, "same seed, same world")
	BrickTerrain.configure(777)
	var c := []
	for i in 60:
		c.append([BrickTerrain.surface_plate(i * 211, -i * 97), BrickTerrain.biome_at(i * 211, -i * 97)])
	_expect(a != c, "new seed, new world")
	BrickTerrain.configure(424242)


func _check_biomes_and_relief() -> void:
	var names := BrickTerrain.biome_names()
	var counts := {}
	var sea: float = float(BrickTerrain.get_gen_params()["sea_m"])
	var plate := BrickWorld.get_plate_metres()
	var heights: Array[float] = []
	# 8 km square, a sample every 48 studs (16.8 m).
	var half := 11400
	var step := 48
	for z in range(-half, half, step * 4):
		for x in range(-half, half, step):
			var bi := BrickTerrain.biome_at(x, z)
			counts[bi] = int(counts.get(bi, 0)) + 1
			heights.append(float(BrickTerrain.surface_plate(x, z) + 1) * plate - sea)
	heights.sort()
	var total := heights.size()
	var lines := []
	var missing := []
	for i in names.size():
		var n := int(counts.get(i, 0))
		lines.append("%s %.1f%%" % [names[i], 100.0 * n / total])
		if n == 0:
			missing.append(names[i])
	print("[mine] biomes: %s" % ", ".join(lines))
	var p := func(q: float) -> float: return heights[clampi(int(q * total), 0, total - 1)]
	print("[mine] height above sea: min %.1f  p10 %.1f  p50 %.1f  p90 %.1f  p99 %.1f  max %.1f m"
			% [heights[0], p.call(0.1), p.call(0.5), p.call(0.9), p.call(0.99), heights[total - 1]])
	_expect(missing.size() <= 2, "nearly every biome appears (missing: %s)" % [missing])
	_expect(heights[0] < -6.0, "dry ocean basins reach well below the sea line")
	_expect(heights[total - 1] > 40.0, "mountains reach 40 m above the sea line")
	var flat_share := float(counts.get(names.find("Plains"), 0)) / total
	_expect(flat_share > 0.05, "plains are common (%.0f%%)" % (flat_share * 100.0))


func _check_overhangs() -> void:
	var found := 0
	var columns := 0
	for z in range(-6000, 6000, 23):
		for x in range(-6000, 6000, 61):
			var top := BrickTerrain.surface_plate(x, z)
			# Walk down from the top: solid, then air, then solid again within
			# 40 plates is a cell hanging over a gap.
			var seen_air := false
			for yp in range(top - 1, top - 40, -1):
				var s := BrickTerrain.solid_at(x, yp, z)
				if s == 0:
					seen_air = true
				elif seen_air:
					found += 1
					break
			columns += 1
	print("[mine] overhang/cave columns: %d of %d sampled" % [found, columns])
	_expect(found > 20, "overhangs or cave roofs exist near the surface")


func _check_ores_and_bedrock() -> void:
	var sea: float = float(BrickTerrain.get_gen_params()["sea_m"])
	var plate := BrickWorld.get_plate_metres()
	var counts := {}
	var stone := 0
	# The underground from 2 m below the sea line down to the bedrock (126 m
	# deep since the deep worlds, Docs/MineWorld.md 16).
	var floor_m: float = sea + float(BrickTerrain.get_gen_params()["bedrock_m"]) + 2.0
	for z in range(0, 96, 2):
		for x in range(0, 96, 2):
			for yp in range(int(floor_m / plate), int((sea - 2.0) / plate), 3):
				var m := BrickTerrain.solid_at(x, yp, z)
				counts[m] = int(counts.get(m, 0)) + 1
				if m == _mat("stone") or m == _mat("dark stone"):
					stone += 1
	var ore_lines := []
	var ores := 0
	for n in ["coal ore", "iron ore", "copper ore", "gold ore", "redstone ore", "lapis ore", "diamond ore"]:
		var c := int(counts.get(_mat(n), 0))
		ores += c
		ore_lines.append("%s %d" % [n, c])
	print("[mine] underground: stone %d, %s, deepslate %d, granite %d, diorite %d, gravel %d"
			% [stone, ", ".join(ore_lines), int(counts.get(_mat("dark stone"), 0)),
			int(counts.get(_mat("granite"), 0)), int(counts.get(_mat("diorite"), 0)),
			int(counts.get(_mat("gravel"), 0))])
	_expect(ores > 20, "ores are scattered through the stone")
	var missing := []
	for n in ["coal ore", "iron ore", "copper ore", "gold ore", "redstone ore", "lapis ore", "diamond ore"]:
		if int(counts.get(_mat(n), 0)) == 0:
			missing.append(n)
	_expect(missing.is_empty(), "every ore is found somewhere down to the bedrock (missing %s)" % [missing])
	_expect(float(BrickTerrain.get_gen_params()["bedrock_m"]) <= -125.0,
			"the bedrock is 300 bricks under the sea line (%.0f m)" % float(BrickTerrain.get_gen_params()["bedrock_m"]))
	_expect(int(counts.get(_mat("dark stone"), 0)) > 100, "deepslate below its band")
	var bed_m: float = sea + float(BrickTerrain.get_gen_params()["bedrock_m"])
	var bed_p := int(floor(bed_m / plate)) - 6
	_expect(BrickTerrain.solid_at(5, bed_p, 5) == _mat("bedrock"), "bedrock at the floor")
	var res: Dictionary = BrickTerrain.carve(Vector3(5 * 0.35, bed_p * plate, 5 * 0.35), 1.0)
	_expect(BrickTerrain.solid_at(5, bed_p, 5) == _mat("bedrock"), "carve leaves bedrock (%d removed)" % int(res["removed"]))
	BrickTerrain.clear_terrain_edits()


func _check_bake_cost() -> void:
	# The hilliest spot in a coarse scan, and a flat one, so both ends show.
	var best := Vector2i.ZERO
	var best_h := -1e9
	var low := Vector2i.ZERO
	var low_h := 1e9
	for tz in range(-200, 200, 9):
		for tx in range(-200, 200, 9):
			var h := BrickTerrain.surface_plate(tx * 32, tz * 32)
			if h > best_h:
				best_h = h
				best = Vector2i(tx, tz)
			if h < low_h:
				low_h = h
				low = Vector2i(tx, tz)
	for spot in [best, low]:
		var t0 := Time.get_ticks_usec()
		var tris := 0
		for dz in 2:
			for dx in 2:
				var d: Dictionary = BrickTerrain.build_tile(spot.x + dx, spot.y + dz)
				tris += int(d.get("tri_count", 0))
		var ms := float(Time.get_ticks_usec() - t0) / 4000.0
		print("[mine] tile bake at %s: %.1f ms a tile" % [spot, ms])
		_expect(ms < 120.0, "a tile bakes in under 120 ms (%.1f)" % ms)
	var t1 := Time.get_ticks_usec()
	BrickTerrain.set_coarse_smooth_step(0)
	var c: Dictionary = BrickTerrain.build_coarse(best.x, best.y, 4, 4)
	var cms := float(Time.get_ticks_usec() - t1) / 1000.0
	print("[mine] coarse 4x4 block step 4: %.1f ms, keys %s" % [cms, c.keys()])
	_expect(cms < 600.0, "a coarse block bakes in under 600 ms")


func _check_regenerate() -> void:
	var before := []
	for i in 30:
		before.append(BrickTerrain.surface_plate(i * 300, i * 170))
	BrickTerrain.set_gen_params({"height_scale": 2.0, "cont_weight_m": 40.0})
	var after := []
	for i in 30:
		after.append(BrickTerrain.surface_plate(i * 300, i * 170))
	_expect(before != after, "new params change the world")
	BrickTerrain.reset_gen_params()
	var again := []
	for i in 30:
		again.append(BrickTerrain.surface_plate(i * 300, i * 170))
	_expect(before == again, "reset gives the default world back")


func _check_preview() -> void:
	var t0 := Time.get_ticks_usec()
	var px: PackedByteArray = BrickTerrain.gen_preview(BrickTerrain.get_seed(), {}, 0, 0, 192, 192, 16, 0)
	var ms := float(Time.get_ticks_usec() - t0) / 1000.0
	_expect(px.size() == 192 * 192 * 3, "map preview is 192x192 RGB (%.0f ms)" % ms)
	var img := Image.create_from_data(192, 192, false, Image.FORMAT_RGB8, px)
	DirAccess.make_dir_recursive_absolute("user://dev")
	img.save_png("user://dev/mine_preview.png")
	var px2: PackedByteArray = BrickTerrain.gen_preview(BrickTerrain.get_seed(), {"height_scale": 1.5}, 0, 0, 192, 192, 16, 1)
	Image.create_from_data(192, 192, false, Image.FORMAT_RGB8, px2).save_png("user://dev/mine_preview_biomes.png")


func _check_build_blocks() -> void:
	BrickTerrain.clear_terrain_edits()
	var stud := BrickWorld.get_stud_metres()
	var plate := BrickWorld.get_plate_metres()
	# Somewhere on dry land.
	var x := 0
	var z := 0
	var sea_p := int(float(BrickTerrain.get_gen_params()["sea_m"]) / plate)
	for i in 400:
		x = i * 37
		z = -i * 23
		if BrickTerrain.surface_plate(x, z) > sea_p + 6:
			break
	var top := BrickTerrain.surface_plate(x, z)
	var eye := Vector3((x + 0.5) * stud, (top + 12) * plate, (z + 0.5) * stud)
	var hit: Dictionary = BrickTerrain.ray_cell(eye, Vector3.DOWN, 20.0)
	_expect(not hit.is_empty() and hit.cell == Vector3i(x, top, z) and hit.normal == Vector3i(0, 1, 0),
			"ray finds the top cell and its face (%s)" % [hit])
	# A 2x2 brick (3 plates) high above the ground: 6 bricks up.
	var lo := Vector3i(x, top + 18, z)
	var hi := Vector3i(x + 1, top + 20, z + 1)
	var mat := _mat("sandstone")
	var res: Dictionary = BrickTerrain.fill_box(lo, hi, mat, true)
	_expect(int(res.changed) == 12 and (res.tiles as PackedInt32Array).size() >= 2,
			"placing fills 12 plate cells (%d)" % int(res.changed))
	_expect(BrickTerrain.solid_at(x, top + 19, z) == mat, "placed block is solid")
	_expect(BrickTerrain.surface_plate(x, z) == top + 20, "the surface scan finds a block above the ground")
	var tx := floori(float(x) / BrickTerrain.get_tile_studs())
	var tz := floori(float(z) / BrickTerrain.get_tile_studs())
	var with_block: Dictionary = BrickTerrain.build_tile(tx, tz)
	BrickTerrain.fill_box(lo, hi, 0, false)
	_expect(BrickTerrain.solid_at(x, top + 19, z) == 0, "breaking leaves air")
	var without: Dictionary = BrickTerrain.build_tile(tx, tz)
	_expect(str(with_block.get("pieces", with_block.keys())) != str(without.get("pieces", without.keys()))
			or int(with_block.get("tri_count", 0)) != int(without.get("tri_count", 0))
			or (with_block.get("mesh", []) as Array).size() != (without.get("mesh", []) as Array).size()
			or _tile_tris(with_block) != _tile_tris(without),
			"the baked tile draws the floating block (%d vs %d tris)" % [_tile_tris(with_block), _tile_tris(without)])
	var bed_p := int(floor((float(BrickTerrain.get_gen_params()["sea_m"])
			+ float(BrickTerrain.get_gen_params()["bedrock_m"])) / plate)) - 6
	BrickTerrain.fill_box(Vector3i(x, bed_p, z), Vector3i(x, bed_p, z), 0, false)
	_expect(BrickTerrain.solid_at(x, bed_p, z) == _mat("bedrock"), "fill never breaks bedrock")
	# Saving: every edit out as bytes and back, negative coordinates included.
	BrickTerrain.clear_terrain_edits()
	BrickTerrain.fill_box(lo, hi, mat, true)
	var nx := -1429
	var nz := -2221
	BrickTerrain.carve(Vector3((nx + 0.5) * stud, (BrickTerrain.surface_plate(nx, nz) - 1) * plate,
			(nz + 0.5) * stud), 0.8)
	var n := BrickTerrain.get_edit_count()
	_expect(n > 12, "a carve at negative coordinates made edits (%d)" % (n - 12))
	var bytes: PackedByteArray = BrickTerrain.get_edits()
	BrickTerrain.clear_terrain_edits()
	var back := BrickTerrain.set_edits(bytes)
	_expect(back == n and BrickTerrain.get_edit_count() == n and bytes.size() == n * 13
			and BrickTerrain.solid_at(x, top + 19, z) == mat,
			"edits save and load back (%d of %d)" % [back, n])
	BrickTerrain.clear_terrain_edits()


## Triangles in a baked tile, whatever the dictionary calls its surfaces.
func _tile_tris(d: Dictionary) -> int:
	var n := 0
	for k in d:
		var v = d[k]
		if v is Array and (v as Array).size() > Mesh.ARRAY_INDEX and (v as Array)[Mesh.ARRAY_VERTEX] is PackedVector3Array:
			var idx = (v as Array)[Mesh.ARRAY_INDEX]
			if idx is PackedInt32Array and (idx as PackedInt32Array).size() > 0:
				@warning_ignore("integer_division")
				n += (idx as PackedInt32Array).size() / 3
			else:
				@warning_ignore("integer_division")
				n += ((v as Array)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3
	return n


## THE GROUND'S BOND (Docs/TerrainBond.md), read back through find_brick:
## every cell of a brick names the same brick; between two courses of solid
## ground no seam stands right over a seam (where both bricks are whole: 2x2,
## 2x4, 4x2); the top course sits so on the course under it too.
func _check_bond() -> void:
	BrickTerrain.clear_terrain_edits()
	# A flat patch well inside a tile (the top course is one plate there).
	var x0 := 0
	var z0 := 0
	var top := 0
	for i in 600:
		x0 = (i % 30) * 64 - 960 + 8
		z0 = int(i / 30.0) * 64 - 640 + 8
		top = BrickTerrain.surface_plate(x0, z0)
		var flat := (top + 1) % 3 == 0
		for dz in range(0, 12, 3):
			for dx in range(0, 12, 3):
				if BrickTerrain.surface_plate(x0 + dx, z0 + dz) != top:
					flat = false
		if flat:
			break
	var tc := int((top + 1) / 3.0) - 1
	# Brick rectangles a course, by cell.
	var courses := [tc, tc - 1, tc - 6, tc - 7]
	var rects := {}
	var mismatched := 0
	for c in courses:
		for dz in 10:
			for dx in 10:
				rects[Vector3i(x0 + dx, c, z0 + dz)] = _brick_of(x0 + dx, c * 3 + 1, z0 + dz)
	# One brick, one answer.
	for k in rects:
		var r: Rect2i = rects[k]
		for cz in range(r.position.y, r.end.y):
			for cx in range(r.position.x, r.end.x):
				var o := Vector3i(cx, k.y, cz)
				if rects.has(o) and rects[o] != r:
					mismatched += 1
	_expect(mismatched == 0, "bond: every cell of a brick names the same brick (%d disagree)" % mismatched)
	# No seam over a seam, course over course.
	var pairs := 0
	var over := 0
	for pair in [[tc, tc - 1], [tc - 6, tc - 7]]:
		for dz in 9:
			for dx in 9:
				for step in [Vector2i(1, 0), Vector2i(0, 1)]:
					var a := Vector2i(x0 + dx, z0 + dz)
					var b: Vector2i = a + step
					var ua: Rect2i = rects[Vector3i(a.x, pair[0], a.y)]
					var ub: Rect2i = rects[Vector3i(b.x, pair[0], b.y)]
					var la: Rect2i = rects[Vector3i(a.x, pair[1], a.y)]
					var lb: Rect2i = rects[Vector3i(b.x, pair[1], b.y)]
					if not (_whole(ua) and _whole(ub) and _whole(la) and _whole(lb)):
						continue
					pairs += 1
					if ua != ub and la != lb:
						over += 1
	_expect(pairs > 60 and over == 0, "bond: no seam over a seam (%d of %d joints, top course and deep rock)" % [over, pairs])
	# Breaking takes exactly the brick.
	var r0: Rect2i = rects[Vector3i(x0 + 4, tc - 6, z0 + 4)]
	var stud := BrickWorld.get_stud_metres()
	var plate := BrickWorld.get_plate_metres()
	var res: Dictionary = BrickTerrain.clear_runs(BrickTerrain.find_brick(
			Vector3((x0 + 4.5) * stud, ((tc - 6) * 3 + 1.5) * plate, (z0 + 4.5) * stud), Vector3.UP)["runs"])
	_expect(int(res.get("removed", 0)) == r0.get_area() * 3,
			"bond: a buried brick broken takes its %dx%d, no more (%d plates)" % [r0.size.x, r0.size.y, int(res.get("removed", 0))])
	print("  bond patch at (%d, %d), top course %d; sizes deep: %s" % [x0, z0, tc, _size_mix(rects, tc - 6)])
	BrickTerrain.clear_terrain_edits()


func _whole(r: Rect2i) -> bool:
	return r.size.x % 2 == 0 and r.size.y % 2 == 0


func _size_mix(rects: Dictionary, c: int) -> String:
	var n := {}
	for k in rects:
		if k.y == c:
			var r: Rect2i = rects[k]
			var key := "%dx%d" % [mini(r.size.x, r.size.y), maxi(r.size.x, r.size.y)]
			n[key] = int(n.get(key, 0)) + 1
	return str(n)


## The brick holding cell (x, plate yp, z), as find_brick gives it.
func _brick_of(x: int, yp: int, z: int) -> Rect2i:
	var stud := BrickWorld.get_stud_metres()
	var plate := BrickWorld.get_plate_metres()
	var f: Dictionary = BrickTerrain.find_brick(Vector3((x + 0.5) * stud, (yp + 0.5) * plate, (z + 0.5) * stud), Vector3.UP)
	var runs: PackedInt32Array = f.get("runs", PackedInt32Array())
	if runs.is_empty():
		return Rect2i()
	var lo := Vector2i(runs[0], runs[1])
	var hi := lo
	for i in range(0, runs.size(), 4):
		lo = Vector2i(mini(lo.x, runs[i]), mini(lo.y, runs[i + 1]))
		hi = Vector2i(maxi(hi.x, runs[i]), maxi(hi.y, runs[i + 1]))
	return Rect2i(lo, hi - lo + Vector2i.ONE)


func _pieces(tx: int, tz: int) -> Array:
	var raw: PackedInt32Array = BrickTerrain.pack_tile(tx, tz)
	var stride := BrickTerrain.get_piece_stride()
	var out := []
	for i in range(0, raw.size(), stride):
		out.append([raw[i], raw[i + 1], raw[i + 2], raw[i + 3], raw[i + 4], raw[i + 5]])
	return out


## The Mega Pickaxe's area (BrickTerrain.find_bricks): every surface piece the
## box touches goes WHOLE -- no piece cut in parts -- and every other piece of
## the tile is laid exactly as before (the pickaxe used to clear a box of plate
## cells, and the packer laid the ground round it again).
func _check_pick_area() -> void:
	BrickTerrain.clear_terrain_edits()
	var plate := BrickWorld.get_plate_metres()
	var sea_p := int(float(BrickTerrain.get_gen_params()["sea_m"]) / plate)
	var tx := 0
	var tz := 0
	var x := 0
	var z := 0
	for i in 400:
		tx = i * 3 + 1
		tz = -i * 2 - 1
		x = tx * 32 + 16
		z = tz * 32 + 16
		var t := BrickTerrain.surface_plate(x, z)
		if t > sea_p + 6 and BrickTerrain.surface_plate(x + 3, z) == t and BrickTerrain.surface_plate(x, z + 3) == t:
			break
	var top := BrickTerrain.surface_plate(x, z)
	var lo := Vector3i(x - 2, top - 2, z - 2)
	var hi := Vector3i(x + 2, top, z + 2)
	var before := _pieces(tx, tz)
	var t0 := Time.get_ticks_usec()
	var found: Dictionary = BrickTerrain.find_bricks(lo, hi)
	var ms := (Time.get_ticks_usec() - t0) / 1000.0
	var res: Dictionary = BrickTerrain.clear_runs(found.get("runs", PackedInt32Array()))
	# The pieces the box touches, whole.
	var box := Rect2i(lo.x - tx * 32, lo.z - tz * 32, 5, 5)
	var gone: Array = []
	var cells := 0
	for p in before:
		if box.intersects(Rect2i(p[0], p[1], p[2], p[3])):
			gone.append(p)
			cells += int(p[2]) * int(p[3]) * 3
	_expect(int(res.get("removed", 0)) == cells and cells > 0,
			"a pickaxe area takes the pieces it touches whole (%d plates, %d pieces want %d; %.1f ms)" % [
			int(res.get("removed", 0)), gone.size(), cells, ms])
	var after := _pieces(tx, tz)
	var lost := []
	for p in before:
		if gone.has(p):
			continue
		var near := false
		for g in gone:
			if Rect2i(g[0], g[1], g[2], g[3]).intersects(Rect2i(p[0], p[1], p[2], p[3])):
				near = true
		if near:
			continue
		if not after.has(p):
			lost.append(p)
	_expect(lost.is_empty(), "every other brick of the tile is laid as before (re-laid: %s)" % [lost.slice(0, 4)])
	BrickTerrain.clear_terrain_edits()


func _check_break_brick() -> void:
	BrickTerrain.clear_terrain_edits()
	var stud := BrickWorld.get_stud_metres()
	var plate := BrickWorld.get_plate_metres()
	var sea_p := int(float(BrickTerrain.get_gen_params()["sea_m"]) / plate)
	# Flat-ish dry ground in the middle of a tile, so the piece is whole.
	var tx := 0
	var tz := 0
	var x := 0
	var z := 0
	for i in 400:
		tx = i * 3
		tz = -i * 2
		x = tx * 32 + 16
		z = tz * 32 + 16
		var t := BrickTerrain.surface_plate(x, z)
		if t > sea_p + 6 and BrickTerrain.surface_plate(x + 1, z) == t and BrickTerrain.surface_plate(x, z + 1) == t:
			break
	var before := _pieces(tx, tz)
	var top := BrickTerrain.surface_plate(x, z)
	var hit := Vector3((x + 0.5) * stud, (top + 1) * plate - 0.02, (z + 0.5) * stud)
	var res: Dictionary = BrickTerrain.break_brick(hit, Vector3.UP)
	var deb: PackedFloat32Array = res.get("debris", PackedFloat32Array())
	_expect(int(res.get("removed", 0)) > 0 and deb.size() == 9,
			"a shot breaks a brick and throws one (%d cells, debris %s)" % [int(res.get("removed", 0)),
			Vector3(deb[3], deb[4], deb[5]) if deb.size() == 9 else "none"])
	# The broken piece: the one in `before` holding (x, z).
	var lx := x - tx * 32
	var lz := z - tz * 32
	var gone: Array = []
	for p in before:
		if lx >= p[0] and lx < p[0] + p[2] and lz >= p[1] and lz < p[1] + p[3]:
			gone = p
	var cells: int = gone[2] * gone[3] * 3 if not gone.is_empty() else -1
	_expect(int(res.get("removed", 0)) == cells, "the whole piece went, no more and no less (%d of %d cells, piece %s)"
			% [int(res.get("removed", 0)), cells, gone])
	var after := _pieces(tx, tz)
	var kept := 0
	var lost := []
	for p in before:
		if p == gone:
			continue
		var hole := Rect2i(gone[0], gone[1], gone[2], gone[3])
		if hole.intersects(Rect2i(p[0], p[1], p[2], p[3])):
			continue
		if after.has(p):
			kept += 1
		else:
			lost.append(p)
	_expect(lost.is_empty(), "every other brick of the tile is laid as before (%d kept, re-laid: %s)" % [kept, lost.slice(0, 4)])
	# A wall: dig the hole a course deeper, then shoot its side below the
	# surface course -- its whole brick of the ground's bond (Docs/
	# TerrainBond.md), not one 1x1 cell as it was: every cell of the brick
	# the debris names, a course each.
	BrickTerrain.break_brick(Vector3((x + 0.5) * stud, (top - 2) * plate - 0.02, (z + 0.5) * stud), Vector3.UP)
	var edge_z: float = (int(gone[1]) + tz * 32) * stud
	var wall := Vector3((x + 0.5) * stud, (top - 4.5) * plate, edge_z + 0.01)
	var res2: Dictionary = BrickTerrain.break_brick(wall, Vector3(0, 0, 1))
	var deb2: PackedFloat32Array = res2.get("debris", PackedFloat32Array())
	var brick_cells := roundi(deb2[3] / stud) * roundi(deb2[5] / stud) * 3 if deb2.size() == 9 else -1
	_expect(int(res2.get("removed", 0)) > 0 and int(res2.get("removed", 0)) == brick_cells,
			"a wall hit takes its whole bond brick (%d plates, brick %d)" % [int(res2.get("removed", 0)), brick_cells])
	BrickTerrain.clear_terrain_edits()
