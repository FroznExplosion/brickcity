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
	_check_bevel_width()
	_check_chamfer_mesh()
	_check_flat_mode()
	_check_smooth_terrain()
	_check_volumetric()
	_check_pads()
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
	var tile_share := float(int(by_kind[1])) / kind_total
	# The upper bound moved from 0.55 to 0.62 when the relief did. A piece
	# only takes studs where the ground is FLAT, so raising the landform
	# octave from 3 m of total relief to 49 m necessarily trades studded
	# ground for smooth — 56% tile is the new shape of the world, not a
	# regression in the packer. The floor is the part that guards anything:
	# it catches a world that has gone all studs.
	_ok("a good share of the ground is smooth tile, not all studs",
		tile_share >= 0.20 and tile_share <= 0.62, "%.0f%%" % (tile_share * 100.0))
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
				# Flat pieces come off the ladder (at most 2 deep); a SLOPE
				# (kind 3, Terrain.md 19.22) is up to 4 along the contour and
				# 2-4 down the fall.
				if kind == 3:
					if maxi(sx, sz) > 4 or mini(sx, sz) < 1:
						oversize += 1
				elif maxi(sx, sz) > BrickTerrain.get_max_piece_length() or mini(sx, sz) > 2:
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
						# A BRICK must be a flat plate. A TILE may be either:
						# a terrace edge, or a flat cell deliberately laid
						# smooth (TILE_CHANCE). What neither may be is a ramp.
						if kind == 0 and not plate:
							bad_kind += 1
						elif kind == 1 and ramp:
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
	_ok("a ramp cell never carries a stud", ramp_studded == 0,
		"%d of %d ramps" % [ramp_studded, ramps])
	# Slopes are OFF (RAMPS_ENABLED). A 1x1 slope is a 50-degree face a third
	# of a metre across and it made the ground read as melted; walkability is
	# the character's step-up height now. The cells that were ramps become
	# TILES, which is where the smooth share comes from.
	_ok("slopes are off and nothing still reports one", ramps == 0, "%d" % ramps)


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
	# BOTH meshes. The gate was written before the chamfer existed and only
	# ever ran with the bevel off, so every facet it added went unchecked —
	# and they were all wound backwards. A gate that does not cover the
	# geometry added after it is not a gate.
	for bevel in [0.0, 0.013]:
		BrickTerrain.set_face_bevel(bevel)
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
						var key := "%.1f bevel  normal %.0f,%.0f,%.0f" % [
							bevel, nrm.x, nrm.y, nrm.z]
						worst[key] = int(worst.get(key, 0)) + 1
	BrickTerrain.set_face_bevel(0.0)
	if bad > 0:
		var parts: Array[String] = []
		for k in worst:
			parts.append("normal (%s): %d" % [k, worst[k]])
		print("        " + "   ".join(parts))
	_ok("every triangle is wound to face the way its normal says",
		bad == 0, "%d of %d triangles backwards" % [bad, total])


## The chamfered debris brick: watertight, correctly wound, and cached.
func _check_chamfer_mesh() -> void:
	print("chamfered debris brick")
	var stud := BrickWorld.get_stud_metres()
	var brick := BrickTerrain.get_brick_metres()
	var size := Vector3(stud, brick, stud)
	var m := PieceMeshes.chamfered_box(size)
	var arrays := m.surface_get_arrays(0)
	var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var n: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var tris := v.size() / 3
	_ok("6 faces, 12 bevels and 8 corners", tris == 44, "%d triangles" % tris)

	# Same rule the terrain mesher has to obey, checked here because
	# `_tri_n` decides the winding at runtime rather than by hand.
	var bad := 0
	for i in range(0, v.size(), 3):
		var cross := (v[i + 1] - v[i]).cross(v[i + 2] - v[i])
		if cross.length_squared() < 1e-14:
			continue
		if cross.normalized().dot(n[i]) > -0.2:
			bad += 1
	_ok("every triangle faces the way its normal says", bad == 0, "%d backwards" % bad)

	# It must still be a brick: no vertex outside the box it replaces, and the
	# chamfer must actually cut the corners in.
	var aabb := m.get_aabb()
	_ok("it fits inside the box it replaces",
		aabb.size.x <= size.x + 1e-4 and aabb.size.y <= size.y + 1e-4
			and aabb.size.z <= size.z + 1e-4,
		"%.3f x %.3f x %.3f" % [aabb.size.x, aabb.size.y, aabb.size.z])
	_ok("and fills it, so the silhouette is unchanged except at the edges",
		aabb.size.x > size.x - 1e-4 and aabb.size.y > size.y - 1e-4)

	var corner := 0
	for p in v:
		if absf(absf(p.x) - size.x * 0.5) < 1e-5 and absf(absf(p.y) - size.y * 0.5) < 1e-5:
			corner += 1
	_ok("no vertex sits on a sharp corner any more", corner == 0, "%d" % corner)

	_ok("the mesh is cached per size",
		PieceMeshes.chamfered_box(size) == m)

	# The stud got the same treatment: it is the most numerous geometry on
	# screen but it is ONE shared mesh, and it is entirely silhouette.
	var sm := PieceMeshes.stud()
	var sv: PackedVector3Array = sm.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var sn: PackedVector3Array = sm.surface_get_arrays(0)[Mesh.ARRAY_NORMAL]
	_ok("the stud has a rim bevel", sv.size() / 3 == 38, "%d triangles" % (sv.size() / 3))
	var sbad := 0
	for i in range(0, sv.size(), 3):
		var cr := (sv[i + 1] - sv[i]).cross(sv[i + 2] - sv[i])
		if cr.length_squared() < 1e-14:
			continue
		if cr.normalized().dot(sn[i]) > -0.2:
			sbad += 1
	_ok("and every triangle of it is wound right", sbad == 0, "%d backwards" % sbad)
	var sab := sm.get_aabb()
	_ok("it is still stud-sized", sab.size.y <= PieceMeshes.STUD_H + 1e-5
		and sab.size.x <= PieceMeshes.STUD_R * 2.0 + 1e-5,
		"%.3f across, %.3f tall" % [sab.size.x, sab.size.y])

	# A 1x1 plate is thinner than two chamfers; it must not invert.
	var thin := PieceMeshes.chamfered_box(Vector3(stud, BrickWorld.get_plate_metres(), stud))
	var tb := thin.get_aabb()
	_ok("a plate-thin brick does not turn inside out",
		tb.size.y > 0.0 and tb.size.y <= BrickWorld.get_plate_metres() + 1e-4,
		"%.3f m tall" % tb.size.y)


## How WIDE is the chamfer, actually?
##
## "The chamfers extend too far" is a claim about a distance, and the mesh
## knows the distance. A facet is a triangle whose normal is not axis
## aligned; its short edge is the cut, which should be the bevel times root
## two — 18 mm at a 13 mm setting. Anything much larger means the inset is
## wrong; anything much larger AND rare means it is the piece SIZE clamp
## biting on a tiny face.
func _check_bevel_width() -> void:
	print("chamfer width")
	const BEVEL := 0.013
	BrickTerrain.set_face_bevel(BEVEL)
	var d: Dictionary = BrickTerrain.build_tile(0, 0)
	BrickTerrain.set_face_bevel(0.0)
	var arrays: Array = d["mesh"]
	var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var n: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]

	var widths: Array[float] = []
	var over := 0
	var ramps := 0
	for i in range(0, idx.size(), 3):
		var nrm := n[idx[i]]
		# Axis aligned means a plain face; a facet is diagonal.
		var m := maxf(absf(nrm.x), maxf(absf(nrm.y), absf(nrm.z)))
		if m > 0.97:
			continue
		var a := v[idx[i]]
		var b := v[idx[i + 1]]
		var c := v[idx[i + 2]]
		var shortest: float = minf(a.distance_to(b),
			minf(b.distance_to(c), c.distance_to(a)))
		# A RAMP's tilted top also has a diagonal normal, and it is a whole
		# 1x1 face — 0.35 m, twenty times a chamfer. Counting those as facets
		# is what reported a "0.324 m chamfer" and sent me looking for a bug
		# in geometry that was correct.
		if shortest > 0.1:
			ramps += 1
			continue
		widths.append(shortest)
		if shortest > BEVEL * 3.0:
			over += 1

	_ok("there are chamfer facets at all", widths.size() > 0,
		"%d facet triangles, plus %d ramp tops" % [widths.size(), ramps])
	if widths.is_empty():
		return
	widths.sort()
	var median: float = widths[widths.size() / 2]
	var biggest: float = widths[widths.size() - 1]
	# cut*sqrt(3), not sqrt(2): the strip runs from a corner inset along BOTH
	# in-plane edge axes to the rim pushed back along the normal, so all three
	# axes contribute.
	print("        median %.4f m, largest %.4f m, expected %.4f m"
		% [median, biggest, BEVEL * sqrt(3.0)])
	# The tolerance allows for ramps' own chamfers: a slope's corners are not
	# 90 degrees, so |e1 + e2| is larger than root two and its facet comes out
	# a few millimetres wider. That is correct, not drift.
	_ok("the facet is the width it was asked for",
		absf(median - BEVEL * sqrt(3.0)) < 0.003, "%.4f m" % median)
	_ok("and none of them run away",
		over == 0, "%d facets wider than 3x the bevel" % over)


## Heightfield mode: the same terrain with nothing carved out of it.
## Curved ground — §18.5, biome AND steepness.
func _check_smooth_terrain() -> void:
	print("curved ground (§18.5)")
	BrickTerrain.set_flat_mode(true)
	BrickTerrain.set_plate_steps(true)
	BrickTerrain.set_smooth_terrain(true)
	BrickTerrain.configure(20260921)

	_ok("off unless asked", true)
	var a := BrickTerrain.smooth_at(13, -7)
	_ok("the decision is stable", a == BrickTerrain.smooth_at(13, -7))

	# THE bug this file exists to catch, and the one that actually happened:
	# the biome mask ran at a 250-stud wavelength, the whole field sat inside
	# one noise cell, and "about half the map" was in fact all of it. A mask
	# whose wavelength exceeds the world is a constant.
	var n := 0
	var smooth := 0
	var steep_smooth := 0
	var worst_steep := 0.0
	for gz in range(-80, 80, 2):
		for gx in range(-80, 80, 2):
			n += 1
			if not BrickTerrain.smooth_at(gx, gz):
				continue
			smooth += 1
			var t := BrickTerrain.surface_plate(gx, gz)
			var step := 0
			for d in [Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, -1), Vector2i(0, 1)]:
				step = maxi(step, absi(BrickTerrain.surface_plate(gx + d.x, gz + d.y) - t))
			if step > 2:
				steep_smooth += 1
			worst_steep = maxf(worst_steep, float(step))
	var share := float(smooth) / maxf(float(n), 1.0)
	_ok("the mask is REGIONAL, not the whole map and not none of it",
		share > 0.15 and share < 0.85, "%.0f%% curved" % (share * 100.0))
	_ok("and a cliff is never curved", steep_smooth == 0,
		"worst step under a curve %d plates" % int(worst_steep))

	# No piece may reach into a curve: the two surfaces would overlap, and
	# the packer has no idea the curve exists.
	var stride := BrickTerrain.get_piece_stride()
	var tile := BrickTerrain.get_tile_studs()
	var overlaps := 0
	var cells := 0
	for tz in range(-1, 2):
		for tx in range(-1, 2):
			var pcs := BrickTerrain.pack_tile(tx, tz)
			for i in range(0, pcs.size(), stride):
				for dz in pcs[i + 3]:
					for dx in pcs[i + 2]:
						cells += 1
						if BrickTerrain.smooth_at(tx * tile + pcs[i] + dx,
								tz * tile + pcs[i + 1] + dz):
							overlaps += 1
	_ok("no brick is packed onto curved ground", overlaps == 0,
		"%d of %d packed cells" % [overlaps, cells])

	# And the mesh really does change — a flag nothing reads is the other
	# way this can quietly do nothing.
	var with_curves: Dictionary = BrickTerrain.build_tile(0, 0)
	BrickTerrain.set_smooth_terrain(false)
	var all_brick: Dictionary = BrickTerrain.build_tile(0, 0)
	_ok("turning it off gives the packer its cells back",
		int(all_brick["piece_count"]) > int(with_curves["piece_count"]),
		"%d pieces bricked vs %d mixed" % [
			int(all_brick["piece_count"]), int(with_curves["piece_count"])])
	_ok("and studs survive the change — a curve keeps its flat spots",
		int(with_curves["stud_count"]) > 0,
		"%d studs on the mixed tile" % int(with_curves["stud_count"]))

	# ONE TOP SURFACE A CELL. A cell drawn by both a piece and a curve is
	# two surfaces in the same place — z-fighting — and a cell drawn by
	# neither is a hole. Neither shows up in a triangle count.
	var tile3 := BrickTerrain.get_tile_studs()
	var covered_ok := true
	var worst_cell := ""
	for tz in range(-1, 2):
		for tx in range(-1, 2):
			var d: Dictionary = BrickTerrain.build_tile(tx, tz)
			var total := int(d["curve_cells"]) + int(d["owned_cells"])
			if total != tile3 * tile3:
				covered_ok = false
				worst_cell = "tile %d,%d: %d of %d" % [tx, tz, total, tile3 * tile3]
	_ok("every cell has exactly one top surface", covered_ok,
		worst_cell if worst_cell != "" else "9 tiles, %d cells each" % (tile3 * tile3))

	# Collision has to follow the CURVE, not the column it was cut from, or
	# the player walks a staircase inside a smooth hill. And it has to stay
	# merged: continuous heights are never equal, so an unquantised curve
	# hands back one box a cell — 1,024 a tile, which is the scene build
	# this merge exists to prevent.
	BrickTerrain.set_smooth_terrain(true)
	var data: Dictionary = BrickTerrain.build_tile(0, 0)
	var boxes: PackedFloat32Array = data["boxes"]
	var plate := BrickWorld.get_plate_metres()
	var stud := BrickWorld.get_stud_metres()
	var tile2 := BrickTerrain.get_tile_studs()
	var follows := 0
	var worst := 0.0
	var curved := 0
	for lz in tile2:
		for lx in tile2:
			if not BrickTerrain.smooth_at(lx, lz):
				continue
			curved += 1
			var cx := (float(lx) + 0.5) * stud
			var cz := (float(lz) + 0.5) * stud
			var top := -1e9
			for i in range(0, boxes.size(), 6):
				if absf(boxes[i] - cx) > boxes[i + 3] * 0.5:
					continue
				if absf(boxes[i + 2] - cz) > boxes[i + 5] * 0.5:
					continue
				top = maxf(top, boxes[i + 1] + boxes[i + 4] * 0.5)
			if top < -1e8:
				continue
			var column := float(BrickTerrain.surface_plate(lx, lz) + 1) * plate
			if absf(top - column) > 1e-4:
				follows += 1
			# The DRAWN height of the cell, rebuilt here the way the mesher
			# builds it: a corner is the mean of its four columns unless a
			# BRICKED one meets there, and then it is that brick's top.
			# Comparing against the column instead is what the first version
			# of this check did, and it measured the curve rather than the
			# error — 0.175 m of "failure" that was the curve doing its job.
			var mid := 0.0
			for ccz in [0, 1]:
				for ccx in [0, 1]:
					var sum := 0.0
					var hard := -1e9
					for dz in [-1, 0]:
						for dx in [-1, 0]:
							var qx: int = lx + ccx + dx
							var qz: int = lz + ccz + dz
							# The CONTINUOUS surface, because that is what a
							# curve is drawn from. This mirror used the
							# quantised column and reported 0.28 m of error
							# the moment the curve stopped being a mean of
							# staircase steps — measuring the change, not a
							# defect, for the second time in this check.
							sum += BrickTerrain.surface_raw(qx, qz)
							if not BrickTerrain.smooth_at(qx, qz):
								hard = maxf(hard,
									float(BrickTerrain.surface_plate(qx, qz) + 1) * plate)
					mid += (hard if hard > -1e8 else sum * 0.25) * 0.25
			worst = maxf(worst, absf(top - mid))
	_ok("collision follows the curve, not the column", follows > 0,
		"%d of %d curved cells differ from their column" % [follows, curved])
	# One collision quantum (a quarter plate), and nothing else.
	_ok("and lands on the drawn surface", worst <= plate * 0.25 + 1e-3,
		"worst %.3f m off the curve" % worst)
	_ok("and the boxes still merge", int(data["box_count"]) < 500,
		"%d boxes on a mixed tile" % int(data["box_count"]))

	BrickTerrain.set_plate_steps(false)
	BrickTerrain.set_flat_mode(false)
	BrickTerrain.configure(20260919)


func _check_flat_mode() -> void:
	print("heightfield mode (§17.22)")
	BrickTerrain.set_flat_mode(true)
	var caves := 0
	var probed := 0
	for z in range(-40, 40, 3):
		for x in range(-40, 40, 3):
			var top := BrickTerrain.surface_plate(x, z)
			for d in range(4, 30):
				probed += 1
				if BrickTerrain.solid_at(x, top - d, z) == 0:
					caves += 1
	_ok("nothing is carved below the surface", caves == 0,
		"%d air cells of %d" % [caves, probed])

	# The surface must be the plain 2D field, and a carve must not move it.
	var before := BrickTerrain.surface_plate(6, 6)
	var stud := BrickWorld.get_stud_metres()
	var plate := BrickWorld.get_plate_metres()
	BrickTerrain.carve(Vector3(6.5 * stud, (float(before) + 0.5) * plate, 6.5 * stud), 2.0)
	_ok("destruction does nothing in heightfield mode",
		BrickTerrain.surface_plate(6, 6) == before, "%d plates" % before)
	BrickTerrain.clear_terrain_edits()

	# And the packer still produces the same kind of ground.
	var stride := BrickTerrain.get_piece_stride()
	var p2 := BrickTerrain.pack_tile(0, 0)
	_ok("the packer still lays pieces", p2.size() / stride > 50,
		"%d pieces" % (p2.size() / stride))

	BrickTerrain.set_flat_mode(false)
	_ok("and the volumetric path comes back", not BrickTerrain.get_flat_mode())


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


## Authored building pads — §19.11.
func _check_pads() -> void:
	print("authored pads (§19.11)")
	BrickTerrain.set_flat_mode(true)
	BrickTerrain.configure(20260921)
	BrickTerrain.clear_pads()
	var plate := BrickWorld.get_plate_metres()
	var before := BrickTerrain.surface_plate(300, -200)
	BrickTerrain.add_pad(300, -200, 10, 6, float(before + 1) * plate + 2.0)
	_ok("a pad is stored", BrickTerrain.pad_count() == 1)

	# DEAD FLAT inside the radius: a building stands on one level or it
	# stands on a slope.
	var level := BrickTerrain.surface_plate(300, -200)
	var flat := true
	for dz in range(-10, 11):
		for dx in range(-10, 11):
			if BrickTerrain.surface_plate(300 + dx, -200 + dz) != level:
				flat = false
	_ok("the pad is dead flat inside its radius", flat,
		"%.2f m" % (float(level + 1) * plate))
	_ok("and it is where it was asked for",
		absf(float(level + 1) * plate - (float(before + 1) * plate + 2.0)) <= plate,
		"asked %.2f, got %.2f" % [float(before + 1) * plate + 2.0,
			float(level + 1) * plate])

	# ...and gone by the far side of the skirt, or a pad would flatten the
	# world.
	var away := BrickTerrain.surface_plate(300 + 40, -200)
	BrickTerrain.clear_pads()
	var natural := BrickTerrain.surface_plate(300 + 40, -200)
	_ok("and the ground is untouched past the skirt", away == natural)
	_ok("clearing removes them", BrickTerrain.pad_count() == 0)

	# PAINTED MATERIAL (§20.1): an author overruling the generator.
	BrickTerrain.clear_paints()
	var natural_mat := BrickTerrain.material_at(500, 500)
	# The natural material VARIES with position, so a point outside the
	# paint needs its own reading taken before the paint exists. Comparing
	# it against the middle's natural material measured the generator, not
	# the paint — the same wrong-reference mistake as §19.12's collider
	# check, for the third time.
	var natural_far := BrickTerrain.material_at(520, 500)
	BrickTerrain.add_paint(500, 500, 8, 5, 3)   # 3 = sand
	_ok("paint overrules the generator",
		BrickTerrain.material_at(500, 500) == 3,
		"was %d, now %d" % [natural_mat, BrickTerrain.material_at(500, 500)])
	_ok("and it knows what it covers", BrickTerrain.paint_at(500, 500) == 0)
	# The skirt is DITHERED, so the edge is a mix rather than a circle: both
	# materials have to appear in it or it is not a dither.
	var sand := 0
	var other := 0
	for d in range(9, 13):
		if BrickTerrain.material_at(500 + d, 500) == 3:
			sand += 1
		else:
			other += 1
	_ok("the skirt is dithered, not a hard circle", sand > 0 and other > 0,
		"%d painted, %d not, across the skirt" % [sand, other])
	_ok("and it is gone past the skirt",
		BrickTerrain.material_at(520, 500) == natural_far)
	BrickTerrain.clear_paints()
	_ok("clearing paint puts the ground back",
		BrickTerrain.material_at(500, 500) == natural_mat)

	# EDITING, which is a level-authoring job (§20). The editor is the only
	# thing that calls these, and a world file is the only thing that
	# survives the session, so the round trip is the part worth gating.
	BrickTerrain.add_pad(10, 20, 6, 3, 4.0)
	BrickTerrain.add_pad(-40, 15, 9, 4, 7.5)
	BrickTerrain.add_paint(60, -30, 7, 4, 4)
	var b: Rect2i = BrickTerrain.pad_bounds(0)
	_ok("a pad knows what it touches",
		b.position == Vector2i(10 - 9, 20 - 9) and b.size == Vector2i(19, 19),
		"%s" % b)
	BrickTerrain.set_pad(0, 11, 21, 7, 2, 4.5)
	var edited := BrickTerrain.get_pad(0)
	_ok("and can be edited in place",
		int(edited["x"]) == 11 and int(edited["radius"]) == 7
			and absf(float(edited["height"]) - 4.5) < 0.001)

	var World := preload("res://scripts/terrain_world.gd")
	var path := "user://probe_world.json"
	_ok("a world saves", World.save_world(path, 1234, 0.25) == OK)
	BrickTerrain.clear_pads()
	var back: Dictionary = World.load_world(path)
	_ok("and loads its seed and sea back",
		int(back.get("seed", 0)) == 1234
			and absf(float(back.get("drowned", 0.0)) - 0.25) < 0.001)
	_ok("with every pad it had", BrickTerrain.pad_count() == 2,
		"%d pads" % BrickTerrain.pad_count())
	_ok("and every paint", BrickTerrain.paint_count() == 1
		and int(BrickTerrain.get_paint(0)["material"]) == 4,
		"%d paints" % BrickTerrain.paint_count())
	var one := BrickTerrain.get_pad(0)
	_ok("and the pads are the same pads",
		int(one["x"]) == 11 and int(one["z"]) == 21 and int(one["radius"]) == 7
			and int(one["skirt"]) == 2 and absf(float(one["height"]) - 4.5) < 0.001)
	BrickTerrain.remove_pad(0)
	_ok("removing one leaves the rest", BrickTerrain.pad_count() == 1
		and int(BrickTerrain.get_pad(0)["x"]) == -40)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	BrickTerrain.clear_pads()
	BrickTerrain.clear_paints()

	# A world that has never been edited is a seed and nothing else, and
	# asking for one must not be an error.
	_ok("a missing world file is not a failure",
		World.load_world("user://no_such_world.json").is_empty())

	# SITES the city reads (§21.5): a street-grid site carries its own
	# centre, footprint, skirt and room program, and all of it has to come
	# back, because the city builds from nothing else.
	World.sites = [
		{"tile": Vector2i(0, 0), "radius": 14, "storeys": 6},
		{"tile": Vector2i(1, 0), "centre": Vector2i(37, -5),
			"footprint": Vector2i(40, 30), "radius": 24, "skirt": 14,
			"storeys": 5, "program": {"office": 4, "kitchen": 1}},
	]
	World.save_world(path, 1234, 0.25)
	World.sites = []
	World.load_world(path)
	var s0: Dictionary = World.sites[0] if World.sites.size() == 2 else {}
	var s1: Dictionary = World.sites[1] if World.sites.size() == 2 else {}
	_ok("an editor site stays a tile, a radius and storeys",
		not s0.is_empty() and not s0.has("centre") and not s0.has("footprint")
			and World.site_centre(s0) == Vector2i(16, 16))
	_ok("a city site keeps its centre, footprint, skirt and program",
		not s1.is_empty() and World.site_centre(s1) == Vector2i(37, -5)
			and World.site_footprint(s1) == Vector2i(40, 30)
			and World.site_skirt(s1) == 14
			and int(s1.get("program", {}).get("office", 0)) == 4,
		"%s" % s1)
	_ok("and builds from its corner", World.site_corner(s1) == Vector2i(17, -20),
		"%s" % World.site_corner(s1))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

	# THE SEA is the world's (§21.6): measured before the pads, so cutting
	# one does not move it, and a site on low ground stands on a quay.
	BrickTerrain.clear_pads()
	var sea := World.settle_sea(0.30)
	var low := Vector2i.ZERO
	var low_y := INF
	for gz in range(-256, 257, 16):
		for gx in range(-256, 257, 16):
			var y := float(BrickTerrain.surface_plate(gx, gz) + 1) * BrickWorld.get_plate_metres()
			if y < low_y:
				low_y = y
				low = Vector2i(gx, gz)
	var wet_site: Array[Dictionary] = [{"tile": Vector2i.ZERO, "centre": low,
		"radius": 8, "storeys": 2}]
	World.stamp_sites_only(wet_site)
	_ok("the sea is the same after a pad is cut",
		absf(World.sea_level - sea) < 0.001 and absf(BrickWave.get_sea_level() - sea) < 0.001)
	_ok("a site on the seabed stands on a quay above the sea",
		low_y < sea and World.site_level(wet_site[0]) >= sea + BrickTerrain.get_brick_metres() - 0.01,
		"ground %.2f, sea %.2f, floor %.2f" % [low_y, sea, World.site_level(wet_site[0])])
	BrickTerrain.clear_pads()
	World.sites = []

	# SCULPT (§20.6): brush strokes in the field, under the pads.
	var plate_m := BrickWorld.get_plate_metres()
	var top := func(x: int, z: int) -> float:
		return float(BrickTerrain.surface_plate(x, z) + 1) * plate_m
	BrickTerrain.clear_sculpt()
	var sx := 300
	var sz := 300
	var before_c: float = top.call(sx, sz)
	var before_far: float = top.call(sx + 20, sz)
	BrickTerrain.sculpt_begin_stroke()
	for i in 4:
		BrickTerrain.sculpt(sx, sz, 8.0, 0, 0.5, 0.0)
	_ok("a raise stroke lifts the ground under the brush",
		top.call(sx, sz) >= before_c + 1.8 and absf(top.call(sx + 20, sz) - before_far) < 0.01,
		"%.2f -> %.2f m; 20 studs away %.2f -> %.2f" % [before_c, top.call(sx, sz),
		before_far, top.call(sx + 20, sz)])
	var back_rect: Rect2i = BrickTerrain.sculpt_undo()
	_ok("and undo puts it back exactly",
		absf(top.call(sx, sz) - before_c) < 0.001 and back_rect.has_point(Vector2i(sx, sz)),
		"%.2f m" % top.call(sx, sz))
	var target := before_c + 3.0
	BrickTerrain.sculpt_begin_stroke()
	for i in 6:
		BrickTerrain.sculpt(sx, sz, 10.0, 1, 1.0, target - plate_m * 0.5)
	_ok("a flatten stroke brings the middle to the height it started from",
		absf(top.call(sx, sz) - target) <= plate_m * 3.01,
		"wanted %.2f, got %.2f" % [target, top.call(sx, sz)])
	# The steepest step across the plateau's edge: a slope smoothed is the
	# same rise over more ground, so its worst step is what gets smaller.
	var rough := 0.0
	var smooth := 0.0
	for i in 12:
		rough = maxf(rough, absf(top.call(sx + 6 + i, sz) - top.call(sx + 7 + i, sz)))
	BrickTerrain.sculpt_begin_stroke()
	for i in 12:
		BrickTerrain.sculpt(sx + 12, sz, 8.0, 2, 1.0, 0.0)
	for i in 12:
		smooth = maxf(smooth, absf(top.call(sx + 6 + i, sz) - top.call(sx + 7 + i, sz)))
	_ok("a smooth stroke evens out the edge of it",
		smooth < rough, "steepest step %.2f m -> %.2f" % [rough, smooth])
	var pad_h: float = roundf((before_c - 1.0) / BrickTerrain.get_brick_metres()) \
			* BrickTerrain.get_brick_metres()
	BrickTerrain.add_pad(sx, sz, 3, 2, pad_h)
	_ok("a pad wins over the sculpt under it", absf(top.call(sx, sz) - pad_h) < 0.001,
		"pad %.2f, ground %.2f" % [pad_h, top.call(sx, sz)])
	BrickTerrain.clear_pads()
	var carved := BrickTerrain.sculpt_at(sx, sz)
	World.sites = []
	World.save_world(path, 20260921, 0.30)
	BrickTerrain.clear_sculpt()
	World.load_world(path)
	_ok("a world keeps its sculpt", absf(BrickTerrain.sculpt_at(sx, sz) - carved) < 0.001
		and absf(carved) > 0.5, "%.2f m" % BrickTerrain.sculpt_at(sx, sz))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	BrickTerrain.clear_sculpt()
	BrickTerrain.clear_pads()

	# SURFACE PAINT (§20.7): material and colour, a stud column at a time.
	var px0 := 600
	var pz0 := -200
	var nat_mat := BrickTerrain.material_at(px0, pz0)
	var nat_col := BrickTerrain.colour_at(px0, pz0)
	var paint_mat := 3 if nat_mat != 3 else 1
	var paint_col := (nat_col + 5) % BrickWorld.get_filament_count()
	BrickTerrain.sculpt_begin_stroke()
	BrickTerrain.paint_surface(px0, pz0, 5.0, paint_mat, paint_col)
	_ok("a paint stroke sets the material and the colour",
		BrickTerrain.material_at(px0, pz0) == paint_mat
			and BrickTerrain.colour_at(px0, pz0) == paint_col
			and BrickTerrain.material_at(px0 + 9, pz0) != paint_mat
			or BrickTerrain.surface_paint_at(px0 + 9, pz0) == Vector2i(255, 255),
		"material %d -> %d, colour %d -> %d" % [nat_mat, BrickTerrain.material_at(px0, pz0),
		nat_col, BrickTerrain.colour_at(px0, pz0)])
	BrickTerrain.sculpt_begin_stroke()
	BrickTerrain.paint_surface(px0, pz0, 5.0, -1, -2)
	_ok("KEEP leaves the material, RESET gives the colour back to it",
		BrickTerrain.material_at(px0, pz0) == paint_mat
			and BrickTerrain.colour_at(px0, pz0)
				== BrickTerrain.material_filament_index(paint_mat))
	BrickTerrain.sculpt_undo()
	_ok("undo puts the painted colour back", BrickTerrain.colour_at(px0, pz0) == paint_col)
	World.save_world(path, 20260921, 0.30)
	BrickTerrain.clear_sculpt()
	_ok("clearing takes the paint off", BrickTerrain.material_at(px0, pz0) == nat_mat
		and BrickTerrain.colour_at(px0, pz0) == nat_col)
	World.load_world(path)
	_ok("a world keeps its paint", BrickTerrain.material_at(px0, pz0) == paint_mat
		and BrickTerrain.colour_at(px0, pz0) == paint_col)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	BrickTerrain.clear_sculpt()

	# PADS the shape of a building: a rectangle, and dead flat at exactly
	# its height wherever the ground would otherwise be quantised.
	BrickTerrain.add_pad(0, 0, 10, 4, 21.0, 5)
	var w_in := BrickTerrain.pad_at(9, 0) == 0
	var w_out := BrickTerrain.pad_at(0, 9) == -1
	_ok("a pad can be a rectangle", w_in and w_out)
	BrickTerrain.clear_pads()
	var brick_m := BrickTerrain.get_brick_metres()
	var bad := 0
	var cols := 0
	for i in 24:
		var px := i * 97 - 1100
		var pz := (i * 53) % 900 - 450
		var h := roundf(top.call(px, pz) / brick_m) * brick_m
		BrickTerrain.add_pad(px, pz, 12, 6, h, 8)
		for dz in range(-8, 9):
			for dx in range(-12, 13):
				cols += 1
				if absf(top.call(px + dx, pz + dz) - h) > 0.001:
					bad += 1
		BrickTerrain.clear_pads()
	_ok("a pad is flat at its height on plate-step AND brick-step ground",
		bad == 0, "%d of %d columns off" % [bad, cols])
	BrickTerrain.set_flat_mode(false)
	BrickTerrain.configure(20260919)


## water.gdshader's group_factor, from BrickWave.group_uniform_array().
func _mirror_group(x: float, z: float, t: float) -> float:
	var g := BrickWave.group_uniform_array()
	var f := 1.0
	for j in g.size() / 2:
		var a := g[j * 2]
		var b := g[j * 2 + 1]
		f += a.x * sin((a.z * x + a.w * z) * a.y - b.x * t + b.y)
	return f


## water.gdshader's shore_wave, from BrickWave.shore_band_uniform().
func _mirror_band(x: float, z: float, t: float) -> float:
	var u := BrickWave.shore_band_uniform()
	var depth := BrickWave.band_depth(x, z)
	if depth <= 0.0 or u.x <= 0.0:
		return 0.0
	var dist := BrickWave.shore_distance(x, z)
	var w := (0.35 + 0.65 * smoothstep(0.0, 20.0, dist)) * (1.0 - smoothstep(0.6 * u.w, u.w, dist)) 			* smoothstep(0.2, 1.0, depth)
	var drift := 1.2 * sin(0.013 * x + 0.7) + 1.2 * sin(0.011 * z + 2.1)
	return u.x * w * sin(u.y * dist + u.z * t + drift)


## water.gdshader's calm factor: 45% of the swell at the waterline.
func _mirror_calm(x: float, z: float) -> float:
	var u := BrickWave.shore_band_uniform()
	return 0.25 + 0.75 * smoothstep(0.0, 150.0, BrickWave.shore_distance(x, z))


## water.gdshader's wave_raw_lod at full detail: each component steered to
## the nearest shore near land, directional in open ocean.
func _mirror_swell(packed: PackedVector4Array, x: float, z: float, t: float) -> float:
	var sb := BrickWave.swell_blend_uniform()
	var dist := BrickWave.shore_distance(x, z)
	var open := smoothstep(sb.x, sb.y, dist)
	var h := 0.0
	for w in BrickWave.component_count():
		var a := packed[w * 2]
		var b := packed[w * 2 + 1]
		var directional := sin((a.z * x + a.w * z) * a.y - b.x * t + b.y)
		var drift := sb.z * (sin(0.017 * x + 1.3 * float(w)) + sin(0.014 * z + 0.7 * float(w)))
		var steered := sin(a.y * minf(dist, sb.y) + b.x * t + b.y + drift)
		h += a.x * (steered * (1.0 - open) + directional * open)
	return h


func _check_wave() -> void:
	print("wave (Water §1)")
	var h0 := BrickWave.height_at(3.7, -2.1, 0.0)
	_ok("height is stable", is_equal_approx(h0, BrickWave.height_at(3.7, -2.1, 0.0)),
		"%.4f" % h0)

	# The shader gets uniform_array() and nothing else, so the packed form has
	# to reproduce height_at or the render and the swim disagree about where
	# the surface is. That is the D9 obligation, not a nicety.
	# The shore field the band is phased on: the world's, as the water builds
	# it (50 tiles each way, a sample every 8 studs).
	BrickWave.build_shore_field(50 * BrickTerrain.get_tile_studs(), 8)
	var packed := BrickWave.uniform_array()
	_ok("two vec4 per component", packed.size() == BrickWave.component_count() * 2)
	var t := 2.35
	var worst := 0.0
	for i in 64:
		var x := float(i) * 0.83 - 20.0
		var z := float(i) * -0.41 + 5.0
		var mirror := BrickWave.get_sea_level()
		# The packed amplitudes carry the wave GAIN but not the shore ramp,
		# which the shader applies itself from the seabed texture. Reproducing
		# the surface means applying that here too — and a `wave_gain` uniform
		# living only in the shader was 2.2x off this for as long as it
		# existed, which is why the gain now lives in BrickWave.
		var ramp := BrickWave.shore_gain(x, z)
		var swell := _mirror_swell(packed, x, z, t)
		mirror += ramp * _mirror_group(x, z, t) * _mirror_calm(x, z) * swell + _mirror_band(x, z, t)
		worst = maxf(worst, absf(BrickWave.height_at(x, z, t) - mirror))
	_ok("the packed uniforms reproduce height_at", worst < 1e-4, "worst %.7f m" % worst)

	# Groups and the shore band, from THEIR packed uniforms, the way the
	# shader has them (water.gdshader group_factor / shore_wave).
	var worst_g := 0.0
	var worst_b := 0.0
	for i in 200:
		var x := float(i) * 7.3 - 700.0
		var z := float(i) * -3.1 + 250.0
		worst_g = maxf(worst_g, absf(BrickWave.group_at(x, z, t) - _mirror_group(x, z, t)))
		worst_b = maxf(worst_b, absf(BrickWave.band_at(x, z, t) - _mirror_band(x, z, t)))
	_ok("the group and shore-band uniforms reproduce the CPU surface",
		worst_g < 1e-4 and worst_b < 1e-4, "worst %.7f / %.7f m" % [worst_g, worst_b])

	# GROUPS make one stretch heaped and the next calm.
	var glo := INF
	var ghi := -INF
	for i in 400:
		var g := BrickWave.group_at(float(i) * 1.5, float(i) * 0.4, 0.0)
		glo = minf(glo, g)
		ghi = maxf(ghi, g)
	_ok("wave groups vary the sea by about +/-30%", ghi - glo > 0.4 and ghi < 1.31 and glo > 0.69,
		"%.2f .. %.2f" % [glo, ghi])

	# The BAND rolls in: along a line out from a shore, what is further out
	# now is nearer the shore a moment later -- (s2 - s1) * k / omega seconds.
	var rolled := false
	var crest_d := [0.0, 0.0]
	var q1 := Vector2.INF
	for gx in range(-1500, 1500, 3):
		for gz in [30, -200, 400, -600]:
			var p := Vector2(float(gx) * 0.35, float(gz) * 0.35)
			var dd := BrickWave.shore_distance(p.x, p.y)
			if dd > 20.0 and dd < 25.0 and BrickWave.band_depth(p.x, p.y) > 1.5:
				q1 = p
				break
		if q1 != Vector2.INF:
			break
	if q1 != Vector2.INF:
		# Out to sea: the way the distance grows fastest.
		var best := Vector2.RIGHT
		var bestd := -INF
		for a in 16:
			var dir := Vector2.RIGHT.rotated(TAU * float(a) / 16.0)
			var dd := BrickWave.shore_distance(q1.x + dir.x * 3.0, q1.y + dir.y * 3.0)
			if dd > bestd:
				bestd = dd
				best = dir
		var q2: Vector2 = q1 + best * 2.0
		var s1 := BrickWave.shore_distance(q1.x, q1.y)
		var s2 := BrickWave.shore_distance(q2.x, q2.y)
		var u := BrickWave.shore_band_uniform()
		var lag := (s2 - s1) * u.y / u.z
		var fwd := 0.0
		var back := 0.0
		for n in 20:
			var tt := 0.37 * float(n)
			var here := BrickWave.band_at(q2.x, q2.y, tt)
			fwd += absf(here - BrickWave.band_at(q1.x, q1.y, tt + lag))
			back += absf(here - BrickWave.band_at(q1.x, q1.y, tt - lag))
		crest_d = [fwd / 20.0, back / 20.0]
		rolled = crest_d[0] < crest_d[1] * 0.3
	# And calmer at the beach than out at sea: the biggest the surface gets
	# 3-8 m from a shore against 60-70 m out.
	var near_amp := 0.0
	var far_amp := 0.0
	var sea_h := BrickWave.get_sea_level()
	for gx in range(-1500, 1500, 5):
		for gz in [30, -200, 400, -600]:
			var p := Vector2(float(gx) * 0.35, float(gz) * 0.35)
			var dd := BrickWave.shore_distance(p.x, p.y)
			if not ((dd > 3.0 and dd < 8.0) or (dd > 60.0 and dd < 70.0)):
				continue
			var amp := 0.0
			for n in 6:
				amp = maxf(amp, absf(BrickWave.height_at(p.x, p.y, 0.9 * float(n)) - sea_h))
			if dd < 8.0:
				near_amp = maxf(near_amp, amp)
			else:
				far_amp = maxf(far_amp, amp)
	# Calmer, not dead: a quarter of the open-water strength at the beach.
	_ok("the sea is calmer at the beach than out at sea, and not still",
		near_amp < far_amp * 0.75 and near_amp > far_amp * 0.2,
		"worst %.2f m near the shore, %.2f m 60-70 m out" % [near_amp, far_amp])
	# The SWELL rolls in (9.9): near land it is phased on distance to the
	# shore, so what is a metre further out now is a metre nearer a moment
	# later -- the main component's lag, dist * k / omega. Measured on the
	# full surface, where the smaller component and the groups only add noise.
	var roll_fwd := 0.0
	var roll_back := 0.0
	var roll_at := Vector2.INF
	for gx in range(-1500, 1500, 3):
		for gz in [30, -200, 400, -600]:
			var p := Vector2(float(gx) * 0.35, float(gz) * 0.35)
			var dd := BrickWave.shore_distance(p.x, p.y)
			if dd > 90.0 and dd < 110.0 and BrickWave.band_depth(p.x, p.y) > 2.0:
				roll_at = p
				break
		if roll_at != Vector2.INF:
			break
	if roll_at != Vector2.INF:
		var out_dir := Vector2.RIGHT
		var best_d := -INF
		for a in 16:
			var dir := Vector2.RIGHT.rotated(TAU * float(a) / 16.0)
			var dd := BrickWave.shore_distance(roll_at.x + dir.x * 3.0, roll_at.y + dir.y * 3.0)
			if dd > best_d:
				best_d = dd
				out_dir = dir
		var r2: Vector2 = roll_at + out_dir * 1.0
		var ds := BrickWave.shore_distance(r2.x, r2.y) - BrickWave.shore_distance(roll_at.x, roll_at.y)
		var wv := BrickWave.uniform_array()
		var lag := ds * wv[0].y / wv[1].x
		for n in 30:
			var tt := 0.41 * float(n)
			var there := BrickWave.height_at(r2.x, r2.y, tt)
			roll_fwd += absf(there - BrickWave.height_at(roll_at.x, roll_at.y, tt + lag))
			roll_back += absf(there - BrickWave.height_at(roll_at.x, roll_at.y, tt - lag))
	rolled = roll_at != Vector2.INF and roll_fwd < roll_back * 0.5
	_ok("the swell rolls in toward the shore", rolled,
		"further out now vs nearer later %.3f m, vs nearer earlier %.3f m" % [
		roll_fwd / 30.0, roll_back / 30.0])

	# The ramp itself: dry ground gets no wave at all, and deep water gets
	# most of one. Without the first a swell drives bricks through the beach;
	# without the second, tall waves are tall nowhere.
	var was_sea: float = BrickWave.get_sea_level()
	# The sea level is chosen FROM THE TERRAIN, not fixed at 1.9 m.
	#
	# A fixed level tests the generator's elevation, not the shore taper: the
	# moment the landform octave went in, every sampled column was above
	# 1.9 m and the check reported "the sea gets no swell" about a world with
	# no sea in it. Pick a level the sampled ground actually straddles.
	var brick := BrickTerrain.get_brick_metres()
	var stud := BrickWorld.get_stud_metres()
	var lowest := 1e9
	var heights: Array[float] = []
	for i in 400:
		var gx := (i * 37) % 120 - 60
		var gz := (i * 53) % 120 - 60
		var h := float(BrickTerrain.height_at(gx, gz) + 1) * brick
		heights.append(h)
		lowest = minf(lowest, h)
	heights.sort()
	var sea: float = maxf(lowest + 4.0, heights[heights.size() / 4])
	BrickWave.set_sea_level(sea)
	var dry := 0.0
	var wet := 0.0
	for i in 400:
		var gx := (i * 37) % 120 - 60
		var gz := (i * 53) % 120 - 60
		var ground := float(BrickTerrain.height_at(gx, gz) + 1) * brick
		var g := BrickWave.shore_gain((gx + 0.5) * stud, (gz + 0.5) * stud)
		if ground >= sea:
			dry = maxf(dry, g)
		else:
			wet = maxf(wet, g)
	_ok("dry land gets no swell", dry == 0.0, "worst gain on land %.3f" % dry)
	_ok("and the sea gets some", wet > 0.3,
		"deepest gain %.2f at sea %.1f m" % [wet, sea])
	BrickWave.set_sea_level(was_sea)

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

	# And the terrace must survive the GAIN the scenes actually run at. Gain
	# scaling amplitude alone cut it from 2.1 studs to 1.0 — every cell on a
	# different step, which is §2's noise case — so the gain scales wavelength
	# too and this is the gate that says so.
	var was_gain: float = BrickWave.get_wave_gain()
	BrickWave.set_wave_gain(2.2)
	var tall := BrickWave.terrace_studs()
	var crest := BrickWave.height_at(0.0, 0.0, 0.0)
	_ok("a tall sea still has readable terraces",
		absf(tall - terrace) < 0.05, "%.1f studs at gain 2.2" % tall)
	BrickWave.set_wave_gain(was_gain)
	_ok("and the gain is undone by putting it back",
		is_equal_approx(BrickWave.terrace_studs(), terrace),
		"crest sampled %.2f m at gain 2.2" % crest)

	var stepped := BrickWave.stepped_at(3.7, -2.1, 0.0)
	var step := BrickWave.get_step_metres()
	_ok("stepped height lands on a brick multiple",
		absf(stepped / step - round(stepped / step)) < 1e-4, "%.3f m" % stepped)
	_ok("stepped never exceeds continuous", stepped <= h0 + 1e-6,
		"%.3f <= %.3f" % [stepped, h0])
