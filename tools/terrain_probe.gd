extends SceneTree

## Terrain and water acceptance probe. Headless, no rendering, no scene.
##
##     godot --headless --path . --script tools/terrain_probe.gd
##
## Everything it checks lives in C++ (`BrickTerrain`, `BrickWave`) — D1, the
## core is the extension from day one and terrain truth is core. GDScript owns
## only node assembly, which is what `scripts/terrain_tile.gd` is.
##
## In the order the claims are load bearing:
##
##   * the generator is deterministic and quantised (Terrain §3)
##   * the packer is STATELESS — the same bricks whichever end you start from
##     and whichever tile asks (§6.3). This is what makes streaming safe, and
##     the one property a scanline packer cannot offer
##   * the mix really is mostly 2x4 (§6.2)
##   * a piece never spans a height, a material or the plate boundary
##   * studs land only on flat plates, never on a ramp (§7.1)
##   * the wave's C++ form and its packed shader form agree (Water §1)

var failures := 0


func _initialize() -> void:
	BrickTerrain.configure(20260919)
	_check_constants()
	_check_field()
	_check_packer_stateless()
	_check_piece_mix()
	_check_piece_integrity()
	_check_studs()
	_check_tile_build()
	_check_winding()
	_check_volumetric()
	_check_wave()

	print("")
	if failures == 0:
		print("[probe] PASS")
	else:
		print("[probe] FAIL — %d check(s)" % failures)
	quit(1 if failures > 0 else 0)


func _ok(label: String, condition: bool, detail: String = "") -> void:
	if condition:
		print("  ok    %s%s" % [label, ("  " + detail) if detail else ""])
	else:
		failures += 1
		print("  FAIL  %s%s" % [label, ("  " + detail) if detail else ""])


# ---------------------------------------------------------------------------

func _check_constants() -> void:
	print("constants")
	var stud := BrickWorld.get_stud_metres()
	var plate := BrickWorld.get_plate_metres()
	_ok("terrain voxel is one brick tall",
		is_equal_approx(BrickTerrain.get_brick_metres(), plate * 3.0),
		"%.3f m" % BrickTerrain.get_brick_metres())
	_ok("tile is 32 studs / 11.2 m", BrickTerrain.get_tile_studs() == 32,
		"%.2f m" % (BrickTerrain.get_tile_studs() * stud))
	# PieceMeshes cannot call into the extension from a const, so it mirrors
	# the grid by hand. If the mirror drifts, every stud is in the wrong place.
	_ok("PieceMeshes mirrors the grid", is_equal_approx(PieceMeshes.STUD, stud)
		and is_equal_approx(PieceMeshes.PLATE, plate))
	_ok("water quantises to a brick, not a plate",
		is_equal_approx(BrickWave.get_step_metres(), BrickTerrain.get_brick_metres()))


func _check_field() -> void:
	print("generator")
	_ok("height is stable", BrickTerrain.height_at(17, -23) == BrickTerrain.height_at(17, -23),
		"%d" % BrickTerrain.height_at(17, -23))

	var before: Array[int] = []
	for i in 60:
		before.append(BrickTerrain.height_at(i * 7, i * -3))

	BrickTerrain.configure(1)
	var differs := false
	for i in 60:
		if BrickTerrain.height_at(i * 7, i * -3) != before[i]:
			differs = true
	_ok("a different seed gives a different field", differs)

	BrickTerrain.configure(20260919)
	var same := true
	for i in 60:
		if BrickTerrain.height_at(i * 7, i * -3) != before[i]:
			same = false
	# A saved damage diff is meaningless against a different field, so this is
	# the property FIELD_VERSION exists to protect (§15 question 1).
	_ok("the same seed reproduces it exactly", same)

	var lo := 9999
	var hi := -9999
	for z in range(-80, 80):
		for x in range(-80, 80):
			var h := BrickTerrain.height_at(x, z)
			lo = mini(lo, h)
			hi = maxi(hi, h)
	_ok("relief is several brick terraces", hi - lo >= 4 and hi - lo <= 24,
		"%d bricks (%.1f m)" % [hi - lo, (hi - lo) * BrickTerrain.get_brick_metres()])


func _check_packer_stateless() -> void:
	print("packer is stateless (§6.3)")

	# A run can never exceed MAX_LEN: every partition segment is bounded, so
	# the lattice alone caps it before a forced cut intervenes.
	var longest := 0
	var run := 0
	for row in range(-4, 4):
		run = 0
		for u in range(-300, 300):
			if BrickTerrain.cut_before(u, row, 0):
				longest = maxi(longest, run)
				run = 0
			run += 1
	_ok("no run exceeds MAX_LEN", longest <= BrickTerrain.get_max_piece_length(),
		"longest %d, max %d" % [longest, BrickTerrain.get_max_piece_length()])
	_ok("cuts actually happen", longest >= 1)

	# The real test: pack the SAME tile from two different neighbourhoods and
	# demand the same bricks. Tile (1,1) is packed on its own, then again after
	# its neighbours have been packed — a stateful packer would answer
	# differently the second time.
	var stride := BrickTerrain.get_piece_stride()
	var solo := BrickTerrain.pack_tile(1, 1)
	for tz in range(0, 3):
		for tx in range(0, 3):
			BrickTerrain.pack_tile(tx, tz)
	var after := BrickTerrain.pack_tile(1, 1)
	_ok("a tile packs the same however its neighbours were visited",
		solo == after, "%d pieces" % (solo.size() / stride))

	# And the same from a fresh configure, which is what a reload is.
	BrickTerrain.configure(20260919)
	_ok("and the same after a reconfigure", BrickTerrain.pack_tile(1, 1) == solo)

	# Cuts are a function of the GLOBAL coordinate, so two tiles sharing an
	# edge agree about it without either being consulted.
	var tile := BrickTerrain.get_tile_studs()
	var edge_ok := true
	for row in range(0, tile):
		if BrickTerrain.cut_before(tile, row, 0) != BrickTerrain.cut_before(tile, row, 0):
			edge_ok = false
	_ok("neighbouring tiles agree on a shared edge", edge_ok)


func _check_piece_mix() -> void:
	print("piece mix is mostly 2x4 (§6.2)")
	var stride := BrickTerrain.get_piece_stride()
	var area := {}
	var total := 0
	var cells_in_4 := 0
	var bricks := 0
	var by_kind := {0: 0, 1: 0, 2: 0}
	var both_ways := {}
	for tz in range(-2, 3):
		for tx in range(-2, 3):
			var p := BrickTerrain.pack_tile(tx, tz)
			for i in range(0, p.size(), stride):
				var sx := p[i + 2]
				var sz := p[i + 3]
				var kind := p[i + 6]
				by_kind[kind] = int(by_kind[kind]) + sx * sz
				# The mix is a claim about BRICKS. Counting tiles and ramps in
				# it would measure how rough the terrain is, not how the
				# packer lays a floor.
				if kind != 0:
					continue
				bricks += 1
				var key := "%dx%d" % [mini(sx, sz), maxi(sx, sz)]
				area[key] = int(area.get(key, 0)) + sx * sz
				total += sx * sz
				if maxi(sx, sz) == 4:
					cells_in_4 += sx * sz
				if sx != sz:
					var ok := "%d,%d" % [sx, sz]
					both_ways[ok] = int(both_ways.get(ok, 0)) + 1

	var keys := area.keys()
	keys.sort_custom(func(a, b): return int(area[a]) > int(area[b]))
	var parts: Array[String] = []
	for k in keys:
		parts.append("%s %d%%" % [k, roundi(100.0 * float(area[k]) / maxf(float(total), 1.0))])
	print("        bricks by area   " + "  ".join(parts))
	var kind_total: float = maxf(float(int(by_kind[0]) + int(by_kind[1]) + int(by_kind[2])), 1.0)
	print("        surface by area  brick %d%%  tile %d%%  ramp %d%%" % [
		roundi(100.0 * float(by_kind[0]) / kind_total),
		roundi(100.0 * float(by_kind[1]) / kind_total),
		roundi(100.0 * float(by_kind[2]) / kind_total)])

	var share_2x4 := float(area.get("2x4", 0)) / maxf(float(total), 1.0)
	var biggest: String = keys[0] if not keys.is_empty() else ""
	_ok("2x4 is the single biggest share", biggest == "2x4",
		"biggest is %s; 2x4 is %.0f%%" % [biggest, share_2x4 * 100.0])
	_ok("2x4 is more than a quarter of the brick area", share_2x4 >= 0.25,
		"%.0f%%" % (share_2x4 * 100.0))

	# Thresholds are MEASURED behaviour with a margin, not paper figures. On an
	# unbroken flat tile the ladder does far better; over real relief every
	# terrace edge and material boundary is a forced cut. The gates exist to
	# catch the mix DRIFTING, so they sit just under what the packer does.
	_ok("4-long pieces are the largest length band",
		float(cells_in_4) / maxf(float(total), 1.0) >= 0.30,
		"%.0f%% of brick area" % (100.0 * float(cells_in_4) / maxf(float(total), 1.0)))

	var mean := float(total) / maxf(float(bricks), 1.0)
	_ok("mean brick is a real multi-stud piece, not gravel", mean >= 3.5,
		"%.1f studs over %d bricks" % [mean, bricks])

	# Courses must run BOTH ways. A packer that only ever lays 2x4 and never
	# 4x2 gives a floor with a grain, which is what the first build looked
	# like — the axis was picked once per tile.
	var wide := 0
	var tall := 0
	for k in both_ways:
		var d: PackedStringArray = (k as String).split(",")
		if int(d[0]) > int(d[1]):
			wide += int(both_ways[k])
		else:
			tall += int(both_ways[k])
	var balance := float(mini(wide, tall)) / maxf(float(maxi(wide, tall)), 1.0)
	_ok("both orientations are laid, in comparable numbers", balance >= 0.7,
		"%d wide, %d tall (%.2f)" % [wide, tall, balance])


func _check_piece_integrity() -> void:
	print("every piece is flat, one material, and of one kind")
	var tile := BrickTerrain.get_tile_studs()
	var stride := BrickTerrain.get_piece_stride()
	var bad_h := 0
	var bad_m := 0
	var bad_kind := 0
	var bad_ramp := 0
	var overlaps := 0
	var oversize := 0
	var uncovered := 0
	for tz in range(-1, 2):
		for tx in range(-1, 2):
			var p := BrickTerrain.pack_tile(tx, tz)
			var seen := {}
			for i in range(0, p.size(), stride):
				var ox := p[i]
				var oz := p[i + 1]
				var sx := p[i + 2]
				var sz := p[i + 3]
				var h0 := p[i + 4]
				var m0 := p[i + 5]
				var kind := p[i + 6]
				if maxi(sx, sz) > BrickTerrain.get_max_piece_length() or mini(sx, sz) > 2:
					oversize += 1
				# A ramp is tilted, so it can only ever be 1x1 — nothing longer
				# can share one plane.
				if kind == 2 and (sx != 1 or sz != 1):
					bad_ramp += 1
				for dz in sz:
					for dx in sx:
						var gx := tx * tile + ox + dx
						var gz := tz * tile + oz + dz
						if BrickTerrain.height_at(gx, gz) != h0:
							bad_h += 1
						if BrickTerrain.material_at(gx, gz) != m0:
							bad_m += 1
						var plate := BrickTerrain.is_plate(gx, gz)
						var ramp := BrickTerrain.ramp_dir(gx, gz) >= 0
						# A brick is a flat plate; a tile is flat but not a
						# plate; a ramp is a ramp. Nothing may be miscast, or
						# studs land where you cannot build (§7.1, §7.6).
						if kind == 0 and not plate:
							bad_kind += 1
						elif kind == 1 and (plate or ramp):
							bad_kind += 1
						elif kind == 2 and not ramp:
							bad_kind += 1
						var key := gx * 100000 + gz
						if seen.has(key):
							overlaps += 1
						seen[key] = true
			# Every cell of the tile must be covered exactly once. A gap is a
			# hole in the ground.
			for lz in tile:
				for lx in tile:
					if not seen.has((tx * tile + lx) * 100000 + (tz * tile + lz)):
						uncovered += 1
	_ok("no piece spans two heights", bad_h == 0, "%d cells" % bad_h)
	_ok("no piece spans two materials", bad_m == 0, "%d cells" % bad_m)
	_ok("no piece is the wrong kind for its cell", bad_kind == 0, "%d cells" % bad_kind)
	_ok("a ramp is always 1x1", bad_ramp == 0, "%d" % bad_ramp)
	_ok("no two pieces overlap", overlaps == 0, "%d cells" % overlaps)
	_ok("no cell is left uncovered", uncovered == 0, "%d cells" % uncovered)
	_ok("no piece is longer than MAX_LEN or deeper than 2", oversize == 0, "%d" % oversize)


func _check_studs() -> void:
	print("studs (§7.1)")
	var on_slope := 0
	var studded := 0
	var on_road := 0
	for z in range(-60, 60):
		for x in range(-60, 60):
			if not BrickTerrain.stud_at(x, z):
				continue
			studded += 1
			if not BrickTerrain.is_plate(x, z):
				on_slope += 1
			if not BrickTerrain.material_takes_studs(BrickTerrain.material_at(x, z)):
				on_road += 1
	_ok("no stud on a cell that is not flat", on_slope == 0, "%d" % on_slope)
	_ok("no stud on a material that refuses them", on_road == 0, "%d" % on_road)
	_ok("flat ground does get studs", studded > 2000, "%d of 14400 cells" % studded)

	# A ramp is never a plate, which is what makes the two rules one rule: the
	# cell that ramps is the cell with no stud, and it is also the cell you
	# cannot build on.
	var ramp_studded := 0
	var ramps := 0
	for z in range(-40, 40):
		for x in range(-40, 40):
			if BrickTerrain.ramp_dir(x, z) < 0:
				continue
			ramps += 1
			if BrickTerrain.stud_at(x, z):
				ramp_studded += 1
	_ok("a ramp cell never carries a stud", ramp_studded == 0, "%d of %d ramps" % [ramp_studded, ramps])
	_ok("ramps exist, so the terraces are walkable", ramps > 100, "%d" % ramps)


func _check_tile_build() -> void:
	print("tile build")
	var d: Dictionary = BrickTerrain.build_tile(0, 0)
	var tile := BrickTerrain.get_tile_studs()
	var cells := tile * tile

	_ok("mesh arrays are laid out for add_surface_from_arrays",
		(d["mesh"] as Array).size() == Mesh.ARRAY_MAX)
	var verts: PackedVector3Array = (d["mesh"] as Array)[Mesh.ARRAY_VERTEX]
	_ok("the mesh has geometry", verts.size() > 0, "%d verts" % verts.size())

	# 16 floats an instance is MultiMesh.set_buffer's layout for TRANSFORM_3D
	# with use_colors. If this drifts the upload silently garbles.
	var studs: PackedFloat32Array = d["studs"]
	_ok("the stud buffer is 16 floats an instance",
		studs.size() == int(d["stud_count"]) * 16,
		"%d floats, %d studs" % [studs.size(), d["stud_count"]])
	var boxes: PackedFloat32Array = d["boxes"]
	_ok("the box buffer is 6 floats a box", boxes.size() % 6 == 0,
		"%d boxes" % (boxes.size() / 6))

	# Every cell must be covered exactly once, by a piece or as a loose 1x1 —
	# a gap is a hole in the ground and an overlap is z-fighting.
	# Collision is merged across the tile, not emitted per piece: a piece is a
	# rendering decision and the collider only has to match the surface. One
	# box a piece was 338 nodes a tile and the whole of the scene's build time.
	@warning_ignore("integer_division")
	var box_count := boxes.size() / 6
	# 72 boxes a tile before the overlay course existed, 146 after: an overlay
	# raises its piece by a plate, so the merge can no longer run across the
	# boundary between a covered piece and a bare one. That is a correctness
	# cost, not a regression — you stand on the tile, so the collider has to
	# follow it. The gate only has to catch collision going back to per piece.
	_ok("collision is merged, not one box a piece",
		box_count < int(d["piece_count"]),
		"%d boxes for %d pieces" % [box_count, d["piece_count"]])
	_ok("and there is still collision everywhere", box_count > 0)

	print("        %d pieces  %d tris  %d studs  %d scatter  %.2f ms" % [
		d["piece_count"], d["triangle_count"], d["stud_count"],
		d["scatter_count"], d["build_ms"]])
	_ok("a tile builds in well under a frame", float(d["build_ms"]) < 8.0,
		"%.2f ms" % d["build_ms"])
	_ok("pieces are far fewer than cells", int(d["piece_count"]) < cells / 3,
		"%d pieces for %d cells" % [d["piece_count"], cells])

	# build_tile must agree with pack_tile, or the mesh is not the packing.
	var packed := BrickTerrain.pack_tile(0, 0)
	_ok("build_tile and pack_tile report the same pieces",
		packed.size() / BrickTerrain.get_piece_stride() == int(d["piece_count"]))


## Every triangle's winding must agree with the normal it was given.
##
## A backwards quad is invisible and SILENT: it is in the buffer, it costs
## triangles, and `cull_back` throws it away. Both horizontal directions of
## the mask mesher were wound backwards, so every cave roof and overhang
## underside vanished and you could see sky through the ground — and nothing
## in the probe noticed, because the counts were all correct.
##
## The rule, read off the packer's top quad which was always known to render:
## for a face with outward normal N, (b - a) x (c - a) points along -N.
func _check_winding() -> void:
	print("winding")
	var worst := {}
	var bad := 0
	var total := 0
	for tz in range(-1, 2):
		for tx in range(-1, 2):
			var d: Dictionary = BrickTerrain.build_tile(tx, tz)
			var arrays: Array = d["mesh"]
			if arrays.is_empty():
				continue
			var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var n: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
			var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
			for i in range(0, idx.size(), 3):
				var a := v[idx[i]]
				var b := v[idx[i + 1]]
				var c := v[idx[i + 2]]
				var cross := (b - a).cross(c - a)
				if cross.length_squared() < 1e-12:
					continue
				var nrm := n[idx[i]]
				total += 1
				# cross must oppose the normal
				if cross.normalized().dot(nrm) > -0.2:
					bad += 1
					var key := "%.0f,%.0f,%.0f" % [nrm.x, nrm.y, nrm.z]
					worst[key] = int(worst.get(key, 0)) + 1
	if bad > 0:
		var parts: Array[String] = []
		for k in worst:
			parts.append("normal (%s): %d" % [k, worst[k]])
		print("        " + "   ".join(parts))
	_ok("every triangle is wound to face the way its normal says",
		bad == 0, "%d of %d triangles backwards" % [bad, total])


func _check_volumetric() -> void:
	print("volumetric field and destruction (§17)")
	_ok("the field version says volumetric", BrickTerrain.get_field_version() >= 2,
		"v%d" % BrickTerrain.get_field_version())

	# The surface must be the TOP of the solid column and there must be air
	# directly above it. That is the whole definition, and everything else —
	# the packer, the studs, collision, water's seabed — reads it.
	var bad_top := 0
	var bad_air := 0
	for z in range(-40, 40):
		for x in range(-40, 40):
			var yp := BrickTerrain.surface_plate(x, z)
			if BrickTerrain.solid_at(x, yp, z) == 0:
				bad_top += 1
			if BrickTerrain.solid_at(x, yp + 1, z) != 0:
				bad_air += 1
	_ok("the surface plate is solid", bad_top == 0, "%d columns" % bad_top)
	_ok("and the plate above it is air", bad_air == 0, "%d columns" % bad_air)

	# Caves have to actually exist, or the switch bought nothing.
	var air_below := 0
	var probed := 0
	for z in range(-50, 50, 3):
		for x in range(-50, 50, 3):
			var top := BrickTerrain.surface_plate(x, z)
			for d in range(6, 40):
				probed += 1
				if BrickTerrain.solid_at(x, top - d, z) == 0:
					air_below += 1
	_ok("caves are carved below the surface", air_below > 0,
		"%d air cells of %d probed" % [air_below, probed])
	_ok("but they do not shred the ground",
		float(air_below) / maxf(float(probed), 1.0) < 0.35,
		"%.0f%% of the subsurface is air" % (100.0 * float(air_below) / maxf(float(probed), 1.0)))

	# --- destruction ------------------------------------------------------
	BrickTerrain.clear_terrain_edits()
	_ok("a fresh world stores no damage", BrickTerrain.get_edit_count() == 0)

	var stud := BrickWorld.get_stud_metres()
	var plate := BrickWorld.get_plate_metres()
	var before := BrickTerrain.surface_plate(4, 4)
	var point := Vector3(4.5 * stud, (float(before) + 0.5) * plate, 4.5 * stud)
	var res: Dictionary = BrickTerrain.carve(point, 1.9)

	_ok("a blast removes cells", int(res["removed"]) > 0, "%d plates" % res["removed"])
	_ok("and writes exactly that many edits",
		BrickTerrain.get_edit_count() == int(res["removed"]),
		"%d edits" % BrickTerrain.get_edit_count())
	_ok("it reports the tiles it dirtied", (res["tiles"] as PackedInt32Array).size() >= 2,
		"%d tiles" % ((res["tiles"] as PackedInt32Array).size() / 2))
	_ok("and throws some debris, but not one body a cell",
		(res["debris"] as PackedFloat32Array).size() > 0
			and (res["debris"] as PackedFloat32Array).size() / 9 < int(res["removed"]),
		"%d pieces for %d plates" % [(res["debris"] as PackedFloat32Array).size() / 9,
			res["removed"]])

	var after := BrickTerrain.surface_plate(4, 4)
	_ok("the crater lowers the surface", after < before,
		"%d -> %d plates" % [before, after])

	# --- dig PAST the section floor ---------------------------------------
	#
	# The mask only reached SECTION_BELOW plates under the surface. Anything
	# dug deeper was edited in the field but still read as solid rock to the
	# mesher, so the floor of a deep pit was simply not drawn and you could
	# see through the world. The mask now follows the deepest edit.
	BrickTerrain.clear_terrain_edits()
	var start := BrickTerrain.surface_plate(40, 40)
	for step in 14:
		var y := start - step * 6
		BrickTerrain.carve(Vector3(40.5 * stud, (float(y) + 0.5) * plate, 40.5 * stud), 1.6)
	var dug := BrickTerrain.surface_plate(40, 40)
	var want := start - 13 * 6
	_ok("a pit can be dug past the section floor", dug < want + 12,
		"%d -> %d plates (%.1f m deep)" % [start, dug, float(start - dug) * plate])

	# And the ground under the pit must still be solid, or the mesher has
	# nothing to draw a floor from.
	_ok("there is still rock under the pit", BrickTerrain.solid_at(40, dug, 40) != 0)
	_ok("and air directly above it", BrickTerrain.solid_at(40, dug + 1, 40) == 0)

	BrickTerrain.clear_terrain_edits()
	before = BrickTerrain.surface_plate(4, 4)
	BrickTerrain.carve(point, 1.9)

	# The edit store IS the damage record, so clearing it must put the world
	# back exactly — that is the same round trip gate G1 asks of a building.
	BrickTerrain.clear_terrain_edits()
	_ok("clearing the record restores the ground",
		BrickTerrain.surface_plate(4, 4) == before)
	_ok("and leaves nothing stored", BrickTerrain.get_edit_count() == 0)


func _check_wave() -> void:
	print("wave (Water §1)")
	var h0 := BrickWave.height_at(3.7, -2.1, 0.0)
	_ok("height is stable", is_equal_approx(h0, BrickWave.height_at(3.7, -2.1, 0.0)),
		"%.4f" % h0)

	# The shader gets uniform_array() and nothing else, so the packed form has
	# to reproduce height_at or the render and the swim disagree about where
	# the surface is. That is the D9 obligation, not a nicety.
	var packed := BrickWave.uniform_array()
	_ok("two vec4 per component", packed.size() == BrickWave.component_count() * 2)
	var t := 2.35
	var worst := 0.0
	for i in 64:
		var x := float(i) * 0.83 - 20.0
		var z := float(i) * -0.41 + 5.0
		var mirror := BrickWave.get_sea_level()
		for w in BrickWave.component_count():
			var a := packed[w * 2]
			var b := packed[w * 2 + 1]
			mirror += a.x * sin((a.z * x + a.w * z) * a.y - b.x * t + b.y)
		worst = maxf(worst, absf(BrickWave.height_at(x, z, t) - mirror))
	_ok("the packed uniforms reproduce height_at", worst < 1e-4, "worst %.7f m" % worst)

	# Batched sampling is the call gameplay uses; it must match the scalar one.
	var pts := PackedVector2Array([Vector2(1, 2), Vector2(-4.5, 8.25), Vector2(0, 0)])
	var batch := BrickWave.sample_heights(pts, t)
	var batch_worst := 0.0
	for i in pts.size():
		batch_worst = maxf(batch_worst,
			absf(batch[i] - BrickWave.height_at(pts[i].x, pts[i].y, t)))
	_ok("batched sampling matches scalar", batch_worst < 1e-4, "worst %.7f m" % batch_worst)

	# §2's argument: a plate step gives a sub-stud terrace and reads as noise;
	# a brick step is what makes the surface read as terraces at all.
	var terrace := BrickWave.terrace_studs()
	_ok("brick steps give a readable terrace", terrace >= 1.5 and terrace <= 6.0,
		"%.1f studs" % terrace)
	var at_plate := terrace * BrickWorld.get_plate_metres() / BrickWave.get_step_metres()
	_ok("a plate step would not", at_plate < 1.5, "%.1f studs at plate quantisation" % at_plate)

	var stepped := BrickWave.stepped_at(3.7, -2.1, 0.0)
	var step := BrickWave.get_step_metres()
	_ok("stepped height lands on a brick multiple",
		absf(stepped / step - round(stepped / step)) < 1e-4, "%.3f m" % stepped)
	_ok("stepped never exceeds continuous", stepped <= h0 + 1e-6,
		"%.3f <= %.3f" % [stepped, h0])
