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
##   * sky light (Docs/MineWorld.md 18): off, the mesh is as it was; on, open
##     tops full, enclosed caves dark, tiles and deep sections agree at their
##     seams, the eye's level, a dug shaft lights the cave, and its cost.
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
	_check_edit_regions()
	_check_pick_area()
	_check_cave_colliders()
	_check_deep_tier()
	_check_sky_light()
	_check_block_light()
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


## SKY LIGHT IN THE CELLS (Docs/MineWorld.md 18): the bake writes each
## vertex's sky light into CUSTOM0.a. Off (every other scene) it stays 255.
## On: open tops are full, floors of enclosed caves deep under their column
## are dark, two tiles agree on their shared edge and a tile on the edge it
## shares with the deep section under it (light depends only on cells within
## 15 steps, and the fill reads past the tile for them), the eye's level
## agrees, a shaft dug down to a dark cave lights its floor once the tile is
## baked again, and the pass costs the bake little.
func _check_sky_light() -> void:
	BrickTerrain.clear_terrain_edits()
	BrickTerrain.set_deep_tier(true)
	var stud := BrickWorld.get_stud_metres()
	var plate := BrickWorld.get_plate_metres()
	# Off: nothing changes.
	BrickTerrain.set_sky_light(false)
	var off_not_full := 0
	var off_ms := 0.0
	var tiles: Array[Vector2i] = []
	for i in 12:
		tiles.append(Vector2i(i * 5 - 100, 37 - i * 3))
	for t in tiles:
		var d: Dictionary = BrickTerrain.build_tile(t.x, t.y)
		off_ms += float(d.build_ms)
		var m: Array = d.mesh
		if m.is_empty():
			continue
		var cu: PackedByteArray = m[Mesh.ARRAY_CUSTOM0]
		for k in range(3, cu.size(), 4):
			if cu[k] != 255:
				off_not_full += 1
	_expect(off_not_full == 0, "sky light off: every vertex's CUSTOM0.a is 255 (%d not)" % off_not_full)
	BrickTerrain.set_sky_light(true)
	var on_ms := 0.0
	var sky_ms := 0.0
	var tops := 0
	var tops_full := 0
	var deep_floors := 0
	var deep_dark := 0
	var dark_tiles := 0
	var dark_spot := Vector3i(1 << 30, 0, 0)
	for t in tiles:
		var d: Dictionary = BrickTerrain.build_tile(t.x, t.y)
		on_ms += float(d.build_ms)
		sky_ms += float(d.get("sky_ms", 0.0))
		if bool(d.get("sky_dark", false)):
			dark_tiles += 1
		var m: Array = d.mesh
		if m.is_empty():
			continue
		var vs: PackedVector3Array = m[Mesh.ARRAY_VERTEX]
		var ns: PackedVector3Array = m[Mesh.ARRAY_NORMAL]
		var cu: PackedByteArray = m[Mesh.ARRAY_CUSTOM0]
		for i in range(0, vs.size(), 3):
			var v := vs[i]
			if ns[i].y < 0.9:
				continue
			# The cell above the face's middle-ish: a corner sits on an edge.
			var x := t.x * 32 + clampi(floori(v.x / stud - 0.01), 0, 31)
			var z := t.y * 32 + clampi(floori(v.z / stud - 0.01), 0, 31)
			var top := BrickTerrain.surface_plate(x, z)
			var yp := roundi(v.y / plate)
			if yp == top + 1:
				# An open top with nothing over the four columns round it.
				var open := true
				for dz in range(-1, 2):
					for dx in range(-1, 2):
						if BrickTerrain.surface_plate(x + dx, z + dz) > top + 3:
							open = false
				if open:
					tops += 1
					if cu[i * 4 + 3] >= 250:
						tops_full += 1
			elif yp < top - 60 and _enclosed(x, yp, z, 18):
				deep_floors += 1
				if cu[i * 4 + 3] < 40:
					deep_dark += 1
					if dark_spot.x == 1 << 30:
						dark_spot = Vector3i(x, yp, z)
	print("[mine] sky light: tiles %.1f ms off, %.1f ms on (the pass %.2f ms, %d of %d tiles had dark cells); open tops full %d of %d; enclosed floors 8 m+ under dark %d of %d"
			% [off_ms / tiles.size(), on_ms / tiles.size(), sky_ms / tiles.size(), dark_tiles, tiles.size(),
			tops_full, tops, deep_dark, deep_floors])
	_expect(tops > 100 and tops_full >= tops * 0.98, "open tops are in full sky light (%d of %d)" % [tops_full, tops])
	_expect(deep_floors > 5 and deep_dark >= deep_floors * 0.8,
			"floors of enclosed caves deep under their column are dark (%d of %d)" % [deep_dark, deep_floors])
	_expect(sky_ms / tiles.size() < 8.0, "the pass costs a tile under 8 ms (%.2f)" % (sky_ms / tiles.size()))
	# Seams: tile A's +X edge against tile B's -X edge, and a tile's floor
	# against the deep section under it.
	var seam_n := 0
	var seam_bad := 0
	for t in tiles.slice(0, 6):
		var a := _light_at_plane(BrickTerrain.build_tile(t.x, t.y), 0, 32.0 * stud)
		var b := _light_at_plane(BrickTerrain.build_tile(t.x + 1, t.y), 0, 0.0)
		for k in a:
			if b.has(k):
				seam_n += 1
				if absi(int(a[k]) - int(b[k])) > 2:
					seam_bad += 1
	var deep_n := 0
	var deep_bad := 0
	var sec := BrickTerrain.get_deep_section_plates()
	var sec_ms := 0.0
	var secs := 0
	for t in tiles.slice(0, 6):
		var floor_p := BrickTerrain.deep_top(t.x, t.y)
		var a := _light_at_plane(BrickTerrain.build_tile(t.x, t.y), 1, floor_p * plate)
		var s: Dictionary = BrickTerrain.build_section(t.x, floori(float(floor_p - 1) / sec), t.y)
		sec_ms += float(s.get("sky_ms", 0.0))
		secs += 1
		var b := _light_at_plane(s, 1, floor_p * plate)
		for k in a:
			if b.has(k):
				deep_n += 1
				if absi(int(a[k]) - int(b[k])) > 2:
					deep_bad += 1
	print("[mine] sky light seams: tile to tile %d of %d vertices differ; tile to deep section %d of %d; the pass in a section %.2f ms"
			% [seam_bad, seam_n, deep_bad, deep_n, sec_ms / secs])
	_expect(seam_n > 50 and seam_bad == 0, "two tiles agree on their shared edge's sky light (%d of %d differ)" % [seam_bad, seam_n])
	_expect(deep_bad == 0, "a tile and the deep section under it agree (%d of %d differ)" % [deep_bad, deep_n])
	# The eye.
	var x0 := tiles[0].x * 32 + 5
	var z0 := tiles[0].y * 32 + 7
	var above := Vector3((x0 + 0.5) * stud, (BrickTerrain.surface_plate(x0, z0) + 12) * plate, (z0 + 0.5) * stud)
	var at_sky := BrickTerrain.sky_light_at(above)
	_expect(at_sky == 15.0, "the eye over open ground sees level 15 (%.0f)" % at_sky)
	if dark_spot.x != 1 << 30:
		var in_cave := Vector3((dark_spot.x + 0.5) * stud, (dark_spot.y + 4) * plate, (dark_spot.z + 0.5) * stud)
		var t0 := Time.get_ticks_usec()
		var at_cave := BrickTerrain.sky_light_at(in_cave)
		var eye_ms := float(Time.get_ticks_usec() - t0) / 1000.0
		print("[mine] sky light at the eye: open %.0f, dark cave floor %.0f (%.2f ms)" % [at_sky, at_cave, eye_ms])
		_expect(at_cave <= 3.0, "the eye in a dark cave sees a low level (%.0f)" % at_cave)
		# Dig a shaft from the sky down to that floor: lit once baked again.
		var c := dark_spot
		var top := BrickTerrain.surface_plate(c.x, c.z)
		BrickTerrain.fill_box(Vector3i(c.x - 1, c.y + 1, c.z - 1), Vector3i(c.x + 1, top + 3, c.z + 1), 0, false)
		var tx := floori(float(c.x) / 32.0)
		var tz := floori(float(c.z) / 32.0)
		var d: Dictionary = BrickTerrain.build_tile(tx, tz)
		var lit := -1
		var m: Array = d.mesh
		var vs: PackedVector3Array = m[Mesh.ARRAY_VERTEX]
		var ns: PackedVector3Array = m[Mesh.ARRAY_NORMAL]
		var cu: PackedByteArray = m[Mesh.ARRAY_CUSTOM0]
		var want := Vector3((c.x - tx * 32 + 0.5) * stud, (c.y + 1) * plate, (c.z - tz * 32 + 0.5) * stud)
		for i in vs.size():
			if ns[i].y > 0.9 and absf(vs[i].y - want.y) < 0.01 and absf(vs[i].x - want.x) <= stud \
					and absf(vs[i].z - want.z) <= stud:
				lit = maxi(lit, cu[i * 4 + 3])
		var eye_after := BrickTerrain.sky_light_at(in_cave)
		print("[mine] sky light after a shaft dug to it: floor %d of 255, eye %.0f" % [lit, eye_after])
		_expect(lit >= 240, "a shaft dug down to a dark cave lights its floor (%d)" % lit)
		_expect(eye_after == 15.0, "and the eye at its foot sees the sky (%.0f)" % eye_after)
	else:
		_expect(false, "found a dark cave floor to test the eye and a shaft")
	BrickTerrain.clear_terrain_edits()
	BrickTerrain.set_sky_light(false)
	BrickTerrain.set_deep_tier(false)


## BLOCK LIGHT from lava (Docs/MineWorld.md 18): a lava cell lights the
## cells round it 15 less a step, written per vertex into CUSTOM0.g as
## 0..60. A cave is dug across a tile seam (in the tiles, then again in the
## deep sections), lava put in it with BrickFluid; the two sides must agree
## on their shared edge, and the floor's light must fall off a level a step.
func _check_block_light() -> void:
	BrickTerrain.clear_terrain_edits()
	BrickTerrain.set_deep_tier(true)
	BrickTerrain.set_sky_light(true)
	BrickFluid.reset(0.0, false)
	var stud := BrickWorld.get_stud_metres()
	var plate := BrickWorld.get_plate_metres()
	# No lava: no block light anywhere.
	var none_lit := 0
	for t in [Vector2i(-40, 12), Vector2i(-41, 12)]:
		var m: Array = BrickTerrain.build_tile(t.x, t.y).mesh
		if m.is_empty():
			continue
		var cu: PackedByteArray = m[Mesh.ARRAY_CUSTOM0]
		for k in range(1, cu.size(), 4):
			if cu[k] != 0:
				none_lit += 1
	_expect(none_lit == 0, "no lava: no vertex has block light (%d do)" % none_lit)
	# A cave in the tiles: plates between the deep tier's top and the ground.
	var tx := 0
	var tz := 0
	var yb := 0
	var found := false
	for i in 40:
		tx = -40 + i * 3
		tz = 12 + (i % 5) * 4
		var floor_p := maxi(BrickTerrain.deep_top(tx - 1, tz), BrickTerrain.deep_top(tx, tz))
		yb = (floor_p + 9) / 3 * 3
		var low := 1 << 30
		for x in range(tx * 32 - 14, tx * 32 + 14):
			for z in range(tz * 32 + 10, tz * 32 + 20):
				low = mini(low, BrickTerrain.surface_plate(x, z))
		if low > yb + 24:
			found = true
			break
	_expect(found, "found a tile pair with room for a cave over the deep tier")
	if not found:
		return
	var seam := tx * 32
	var z0 := tz * 32 + 15
	var lava := Vector3i(seam - 1, yb / 3, z0)
	var dug := _block_cave(seam, yb, z0, lava)
	var res: Dictionary = dug[0]
	var lava_cells: Array = dug[1]
	var relit := {}
	var lit_flat: PackedInt32Array = res.get("lava_light", PackedInt32Array())
	for i in range(0, lit_flat.size(), 4):
		if lit_flat[i + 2] <= yb and lit_flat[i + 3] >= yb:
			relit[Vector2i(lit_flat[i], lit_flat[i + 1])] = true
	_expect(lava_cells.size() > 0, "lava placed in the cave (%d cells)" % lava_cells.size())
	_expect(relit.has(Vector2i(tx - 1, tz)) and relit.has(Vector2i(tx, tz)),
			"take() names the tiles on both sides of the lava for relighting (%s)" % [relit.keys()])
	var a: Dictionary = BrickTerrain.build_tile(tx - 1, tz)
	var b: Dictionary = BrickTerrain.build_tile(tx, tz)
	_expect(int(a.get("block_seeds", 0)) > 0 and int(b.get("block_seeds", 0)) > 0,
			"both tiles' bakes see the lava (%d, %d seeds)" % [int(a.get("block_seeds", 0)), int(b.get("block_seeds", 0))])
	var sa := _block_at_plane(a, 0, 32.0 * stud)
	var sb := _block_at_plane(b, 0, 0.0)
	var seam_n := 0
	var seam_lit := 0
	var seam_bad := 0
	for k in sa:
		if sb.has(k):
			seam_n += 1
			if int(sa[k]) > 0 or int(sb[k]) > 0:
				seam_lit += 1
			if absi(int(sa[k]) - int(sb[k])) > 1:
				seam_bad += 1
	# The floor: each vertex blends the four cells round it (it lies on
	# their edges, half a cell under their middle), 15 less the steps to
	# the nearest lava cell.
	var fall_n := 0
	var fall_bad := 0
	var worst := 0
	var near_g := 0
	var far_g := 255
	for side in [[a, tx - 1], [b, tx]]:
		var m: Array = (side[0] as Dictionary).mesh
		var vs: PackedVector3Array = m[Mesh.ARRAY_VERTEX]
		var ns: PackedVector3Array = m[Mesh.ARRAY_NORMAL]
		var cu: PackedByteArray = m[Mesh.ARRAY_CUSTOM0]
		for i in vs.size():
			if ns[i].y < 0.9 or absf(vs[i].y - yb * plate) > 0.002:
				continue
			var X := roundi(vs[i].x / stud) + int(side[1]) * 32
			var Z := roundi(vs[i].z / stud) + tz * 32
			if X < seam - 11 or X > seam + 11 or Z < z0 - 1 or Z > z0 + 2:
				continue
			var want := 0.0
			for o in [Vector2i(-1, -1), Vector2i(0, -1), Vector2i(-1, 0), Vector2i(0, 0)]:
				var best := 0
				for l: Vector3i in lava_cells:
					var d := absi(X + o.x - l.x) + absi(yb / 3 - l.y) + absi(Z + o.y - l.z)
					best = maxi(best, 15 - d)
				want += best / 4.0
			var g := cu[i * 4 + 1]
			var e := roundi(want / 15.0 * 60.0)
			fall_n += 1
			worst = maxi(worst, absi(g - e))
			if absi(g - e) > 1:
				fall_bad += 1
			if absi(X - lava.x) <= 1:
				near_g = maxi(near_g, g)
			if absi(X - lava.x) >= 10:
				far_g = mini(far_g, g)
	print("[mine] block light: tile seam %d of %d vertices differ (%d lit); floor %d of %d off the expected fall-off (worst %d of 60); by the lava %d, 10+ studs off %d; the pass %.2f / %.2f ms"
			% [seam_bad, seam_n, seam_lit, fall_bad, fall_n, worst, near_g, far_g,
			float(a.get("block_ms", 0.0)), float(b.get("block_ms", 0.0))])
	_expect(seam_lit > 10 and seam_bad == 0, "two tiles agree on their shared edge's block light (%d of %d lit differ)" % [seam_bad, seam_lit])
	_expect(fall_n > 10 and fall_bad == 0, "the floor's block light falls off a level a step (%d of %d off, worst %d)" % [fall_bad, fall_n, worst])
	_expect(near_g >= 52 and far_g <= 24, "bright by the lava (%d), dim 10 studs off (%d)" % [near_g, far_g])
	# The lava taken away: dark again once relit.
	for l: Vector3i in lava_cells:
		BrickFluid.remove(l, -1)
	BrickFluid.tick_now(1)
	var gone: Dictionary = BrickFluid.take()
	var left := int(BrickFluid.stats().get("lava_cells", -1))
	var after := 0
	var cu2: PackedByteArray = BrickTerrain.build_tile(tx, tz).mesh[Mesh.ARRAY_CUSTOM0]
	for k in range(1, cu2.size(), 4):
		if cu2[k] != 0:
			after += 1
	_expect(left == 0 and (gone.get("lava_light", PackedInt32Array()) as PackedInt32Array).size() > 0 and after == 0,
			"lava removed: none left (%d), relight asked, tile dark (%d lit)" % [left, after])
	# The same in the deep sections, two or more sections down, in solid
	# rock (a cave dug inside a generated cavern has no walls near the lava).
	BrickFluid.reset(0.0, false)
	var sec := BrickTerrain.get_deep_section_plates()
	var dtx := tx
	var sy := 0
	var yd := 0
	var rock := false
	for i in 60:
		dtx = tx + (i % 12) * 2
		var top := mini(BrickTerrain.deep_top(dtx - 1, tz), BrickTerrain.deep_top(dtx, tz))
		sy = floori(float(top) / sec) - 2 - i / 12
		yd = (sy * sec + 30) / 3 * 3
		var solid := 0
		var all := 0
		for x in range(dtx * 32 - 13, dtx * 32 + 13, 2):
			for y in range(yd - 3, yd + 12, 2):
				for z in range(z0 - 3, z0 + 4):
					all += 1
					if BrickTerrain.solid_at(x, y, z) != 0:
						solid += 1
		if solid >= all * 0.97:
			rock = true
			break
	_expect(rock, "found solid rock for a deep cave")
	seam = dtx * 32
	var dlava := Vector3i(seam - 1, yd / 3, z0)
	_block_cave(seam, yd, z0, dlava)
	var da: Dictionary = BrickTerrain.build_section(dtx - 1, sy, tz)
	var db: Dictionary = BrickTerrain.build_section(dtx, sy, tz)
	var pa := _block_at_plane(da, 0, 32.0 * stud)
	var pb := _block_at_plane(db, 0, 0.0)
	var dn := 0
	var dlit := 0
	var dbad := 0
	for k in pa:
		if pb.has(k):
			dn += 1
			if int(pa[k]) > 0 or int(pb[k]) > 0:
				dlit += 1
			if absi(int(pa[k]) - int(pb[k])) > 1:
				dbad += 1
	print("[mine] block light, deep sections: seam %d of %d differ (%d lit); seeds %d, %d; the pass %.2f ms"
			% [dbad, dn, dlit, int(da.get("block_seeds", 0)), int(db.get("block_seeds", 0)), float(db.get("block_ms", 0.0))])
	_expect(int(da.get("block_seeds", 0)) > 0 and int(db.get("block_seeds", 0)) > 0, "both deep sections see the lava")
	_expect(dlit > 10 and dbad == 0, "two deep sections agree on their shared edge's block light (%d of %d lit differ)" % [dbad, dlit])
	BrickFluid.reset(0.0, false)
	BrickTerrain.clear_terrain_edits()
	BrickTerrain.set_sky_light(false)
	BrickTerrain.set_deep_tier(false)


## A cave 24 studs along X across the seam, 5 wide, 3 courses tall from
## plate `yb`, and a lava source at `lava`. [take()'s result, the lava cells
## in the cave after one tick].
func _block_cave(seam: int, yb: int, z0: int, lava: Vector3i) -> Array:
	BrickTerrain.fill_box(Vector3i(seam - 12, yb, z0 - 2), Vector3i(seam + 11, yb + 8, z0 + 2), 0, false)
	BrickFluid.place(lava, 2, 0, 3)  # lava, a source
	BrickFluid.tick_now(1)
	var res: Dictionary = BrickFluid.take()
	var cells: Array = []
	for x in range(seam - 12, seam + 12):
		for c in range(yb / 3, yb / 3 + 3):
			for z in range(z0 - 2, z0 + 3):
				if int(BrickFluid.cell_info(Vector3i(x, c, z)).get("fluid", 0)) == 2:
					cells.append(Vector3i(x, c, z))
	return [res, cells]


## CUSTOM0.g (block light, 0..60) of a baked mesh's vertices on a plane, keyed
## as _light_at_plane keys them.
func _block_at_plane(d: Dictionary, axis: int, at: float) -> Dictionary:
	var out := {}
	var m: Array = d.get("mesh", [])
	if m.is_empty():
		return out
	var vs: PackedVector3Array = m[Mesh.ARRAY_VERTEX]
	var ns: PackedVector3Array = m[Mesh.ARRAY_NORMAL]
	var cu: PackedByteArray = m[Mesh.ARRAY_CUSTOM0]
	for i in vs.size():
		var v := vs[i]
		if absf((v.x if axis == 0 else v.y) - at) >= 0.002:
			continue
		var k := "%.3f,%.3f,%.2f,%.2f,%.2f" % [v.y if axis == 0 else v.x, v.z, ns[i].x, ns[i].y, ns[i].z]
		out[k] = cu[i * 4 + 1]
	return out


## Is the air cell over plate `yp` of column (x, z) under rock for `up` plates
## in this column and the four beside it (a cave's floor, not a ravine's)?
func _enclosed(x: int, yp: int, z: int, up: int) -> bool:
	for o in [Vector2i(0, 0), Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		var solid := false
		for k in range(1, up * 4):
			if BrickTerrain.solid_at(x + o.x, yp + k, z + o.y) != 0:
				solid = true
				break
		if not solid:
			return false
	return true


## The sky light (CUSTOM0.a) of a baked mesh's vertices lying on the plane
## axis `axis` (0 x, 1 y) = `at`, keyed by the other coordinates and the
## normal; X is turned into the neighbour's frame by the caller's choice of
## plane, so keys of two tiles match.
func _light_at_plane(d: Dictionary, axis: int, at: float) -> Dictionary:
	var out := {}
	var m: Array = d.get("mesh", [])
	if m.is_empty():
		return out
	var vs: PackedVector3Array = m[Mesh.ARRAY_VERTEX]
	var ns: PackedVector3Array = m[Mesh.ARRAY_NORMAL]
	var cu: PackedByteArray = m[Mesh.ARRAY_CUSTOM0]
	for i in vs.size():
		var v := vs[i]
		var on := absf((v.x if axis == 0 else v.y) - at) < 0.002
		if not on:
			continue
		var k := "%.3f,%.3f,%.2f,%.2f,%.2f" % [v.y if axis == 0 else v.x, v.z, ns[i].x, ns[i].y, ns[i].z]
		out[k] = cu[i * 4 + 3]
	return out


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
## EDITS BY REGION (Docs/MineWorld.md 9): a save asks for the regions edited
## since it last asked (take_dirty_regions) and writes each one's edits
## (get_region_edits) -- not every edit of the world on the main thread.
func _check_edit_regions() -> void:
	BrickTerrain.clear_terrain_edits()
	var rs := BrickTerrain.get_region_studs()
	BrickTerrain.fill_box(Vector3i(10, 1500, 10), Vector3i(11, 1502, 11), 4, false)       # region (0, 0)
	BrickTerrain.fill_box(Vector3i(rs * 3 + 5, 1500, -rs + 5), Vector3i(rs * 3 + 5, 1502, -rs + 5), 4, false)   # (3, -1)
	var d := BrickTerrain.take_dirty_regions()
	var got := {}
	for i in range(0, d.size(), 2):
		got[Vector2i(d[i], d[i + 1])] = true
	_expect(got.size() == 2 and got.has(Vector2i(0, 0)) and got.has(Vector2i(3, -1)),
			"regions: the two edited regions are dirty (%s)" % [got.keys()])
	_expect(BrickTerrain.take_dirty_regions().is_empty(), "regions: asking again, none")
	BrickTerrain.fill_box(Vector3i(12, 1500, 12), Vector3i(12, 1500, 12), 4, false)
	d = BrickTerrain.take_dirty_regions()
	_expect(d.size() == 2 and d[0] == 0 and d[1] == 0, "regions: an edit again, only its region (%s)" % [d])
	# A region's bytes load back to the same cells.
	var a := BrickTerrain.get_region_edits(0, 0)
	var b := BrickTerrain.get_region_edits(3, -1)
	_expect(a.size() == (12 + 1) * 13 and b.size() == 3 * 13,
			"regions: (0,0) holds 13 cells, (3,-1) 3 (%d, %d)" % [a.size() / 13, b.size() / 13])
	BrickTerrain.clear_terrain_edits()
	BrickTerrain.set_edits(a)
	BrickTerrain.set_edits(b)
	_expect(BrickTerrain.get_edit_count() == 16 and BrickTerrain.solid_at(rs * 3 + 5, 1501, -rs + 5) == 4,
			"regions: loaded back, 16 cells, as they were")
	# What a save costs at a million edits: one changed region, not all.
	var buf := PackedByteArray()
	var n := 1000000
	buf.resize(n * 13)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for i in n:
		buf.encode_s32(i * 13, rng.randi_range(-3000, 3000))
		buf.encode_s32(i * 13 + 4, rng.randi_range(0, 300))
		buf.encode_s32(i * 13 + 8, rng.randi_range(-3000, 3000))
		buf[i * 13 + 12] = 0
	BrickTerrain.set_edits(buf)
	BrickTerrain.take_dirty_regions()
	BrickTerrain.fill_box(Vector3i(20, 300, 20), Vector3i(23, 302, 21), 4, false)   # a brick laid
	var t0 := Time.get_ticks_usec()
	var dr := BrickTerrain.take_dirty_regions()
	var bytes := 0
	for i in range(0, dr.size(), 2):
		bytes += BrickTerrain.get_region_edits(dr[i], dr[i + 1]).size()
	var region_ms := (Time.get_ticks_usec() - t0) / 1000.0
	t0 = Time.get_ticks_usec()
	var all := BrickTerrain.get_edits().size()
	var all_ms := (Time.get_ticks_usec() - t0) / 1000.0
	print("  save at %d edits: the changed region %.2f ms (%d KB), every edit %.1f ms (%d KB)" % [
			BrickTerrain.get_edit_count(), region_ms, bytes / 1024, all_ms, all / 1024])
	_expect(dr.size() == 2 and region_ms < all_ms / 4.0, "regions: a save after one brick asks one region, far under all of them")
	BrickTerrain.clear_terrain_edits()


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
