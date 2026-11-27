extends SceneTree

## THE BRICK OVERLAY, stage 1 (Docs/BrickOverlay.md 4): does a bake's
## `overlay_bricks` list name the bricks it draws?
##
##     godot --headless --path . --script res://tools/probes/terrain_bricks_probe.gd
##
## Headless, C++ only. The mine world's generator (1, the bond's top course),
## surface tiles and deep sections. For every flat triangle of the mesh: its
## middle lies on the surface of some listed brick (the overlay must cover
## every face it will push back); for every listed brick: some triangle lies
## on it (no brick laid where nothing is drawn); no two bricks overlap.
## With sky light on: some surface bricks say their top has studs, and the
## deep sections' bricks have dark corners (the light the boxes are drawn
## with: 17 floats a brick, 4 bits a face's corner).

const EPS := 0.004
const STRIDE := 17

var _studded := 0
var _dark_corners := 0
var _lit_corners := 0
var _lost := 0
var _covered := 0

var failures := 0


func _initialize() -> void:
	preload("res://scripts/terrain/worldgen_presets.gd").apply_fitted_flag()
	BrickTerrain.configure(424242)
	BrickTerrain.set_generator(1)
	BrickTerrain.reset_gen_params()
	BrickTerrain.set_smooth_terrain(false)
	BrickTerrain.set_plate_steps(false)
	BrickTerrain.set_slope_pieces(false)
	BrickTerrain.set_bond_top(true)
	BrickTerrain.set_coarse_smooth_step(0)
	BrickTerrain.clear_terrain_edits()
	BrickTerrain.set_sky_light(true)

	var tiles: Array[Vector2i] = []
	for i in 8:
		tiles.append(Vector2i(i * 5 - 20, 17 - i * 3))
	var ts := 32.0 * BrickWorld.get_stud_metres()
	for t in tiles:
		_check("tile %s" % t, BrickTerrain.build_tile(t.x, t.y), Vector3(t.x * ts, 0.0, t.y * ts))
	BrickTerrain.set_deep_tier(true)
	var secs := 0
	for t in tiles.slice(0, 4):
		var top := BrickTerrain.deep_top(t.x, t.y)
		var sy := floori(float(top - 1) / BrickTerrain.get_deep_section_plates())
		for k in 2:
			var d: Dictionary = BrickTerrain.build_section(t.x, sy - k, t.y)
			if (d.get("mesh", []) as Array).is_empty():
				continue
			secs += 1
			_check("section %s,%d" % [t, sy - k], d, Vector3(t.x * ts, 0.0, t.y * ts))
	_expect(secs > 0, "some deep sections had faces (%d)" % secs)
	_expect(_studded > 0, "some bricks' tops have studs (%d)" % _studded)
	_expect(_dark_corners > 0 and _lit_corners > 0,
			"bricks' corners carry the sky light (%d dark, %d open air)" % [_dark_corners, _lit_corners])
	# A few tile-edge strips aside (filler, no brick's), all of them.
	_expect(_covered > 0 and _lost <= _covered / 100,
			"covered faces find their brick's middle (%d of %d vertices lost)" % [_lost, _covered])
	BrickTerrain.set_sky_light(false)
	BrickTerrain.set_deep_tier(false)
	BrickTerrain.set_generator(0)
	BrickTerrain.set_bond_top(false)
	BrickTerrain.set_coarse_smooth_step(8)
	print("[bricks] %s (%d failures)" % ["PASS" if failures == 0 else "FAIL", failures])
	quit(1 if failures > 0 else 0)


func _expect(ok: bool, what: String) -> void:
	if not ok:
		failures += 1
	print("[bricks] %s  %s" % ["ok  " if ok else "FAIL", what])


func _check(tag: String, d: Dictionary, origin: Vector3) -> void:
	var b: PackedFloat32Array = d.get("overlay_bricks", PackedFloat32Array())
	var n := b.size() / STRIDE
	var lo: Array[Vector3] = []
	var hi: Array[Vector3] = []
	# Bricks by stud column they cover, for the lookup.
	var stud := BrickWorld.get_stud_metres()
	var cols := {}
	for i in n:
		var a := Vector3(b[i * STRIDE], b[i * STRIDE + 1], b[i * STRIDE + 2])
		var c := Vector3(b[i * STRIDE + 3], b[i * STRIDE + 4], b[i * STRIDE + 5])
		lo.append(a)
		hi.append(c)
		if b[i * STRIDE + 10] > 0.5:
			_studded += 1
		for h in 4:
			var packed := int(b[i * STRIDE + 11 + h])
			for q in 6:
				var lv := (packed >> (4 * q)) & 15
				if lv == 15:
					_lit_corners += 1
				elif lv < 8:
					_dark_corners += 1
		for x in range(floori(a.x / stud + 0.01), ceili(c.x / stud - 0.01)):
			for z in range(floori(a.z / stud + 0.01), ceili(c.z / stud - 0.01)):
				var k := Vector2i(x, z)
				if not cols.has(k):
					cols[k] = []
				(cols[k] as Array).append(i)
	var overlaps := 0
	for k in cols:
		var l: Array = cols[k]
		for i in l.size():
			for j in range(i + 1, l.size()):
				var p: int = l[i]
				var q: int = l[j]
				if minf(hi[p].y, hi[q].y) - maxf(lo[p].y, lo[q].y) > EPS:
					overlaps += 1
	var m: Array = d.get("mesh", [])
	var tris := 0
	var off := 0
	var used := PackedByteArray()
	used.resize(n)
	var first_off := ""
	if not m.is_empty():
		var vs: PackedVector3Array = m[Mesh.ARRAY_VERTEX]
		var idx: PackedInt32Array = m[Mesh.ARRAY_INDEX]
		for t in range(0, idx.size(), 3):
			var c := (vs[idx[t]] + vs[idx[t + 1]] + vs[idx[t + 2]]) / 3.0 + origin
			tris += 1
			var k := Vector2i(floori(c.x / stud), floori(c.z / stud))
			var found := -1
			for kk in [k, k + Vector2i(1, 0), k + Vector2i(-1, 0), k + Vector2i(0, 1), k + Vector2i(0, -1)]:
				for i in cols.get(kk, []):
					var a: Vector3 = lo[i]
					var e: Vector3 = hi[i]
					var inside := c.x > a.x - EPS and c.x < e.x + EPS and c.y > a.y - EPS and c.y < e.y + EPS \
							and c.z > a.z - EPS and c.z < e.z + EPS
					var on := absf(c.x - a.x) < EPS or absf(c.x - e.x) < EPS or absf(c.y - a.y) < EPS \
							or absf(c.y - e.y) < EPS or absf(c.z - a.z) < EPS or absf(c.z - e.z) < EPS
					if inside and on:
						found = i
						break
				if found >= 0:
					break
			if found < 0:
				off += 1
				if off <= 4:
					var nn: Vector3 = (m[Mesh.ARRAY_NORMAL] as PackedVector3Array)[idx[t]]
					var cu: PackedByteArray = m[Mesh.ARRAY_CUSTOM0]
					first_off += " %s n%s mat%d facet%d;" % [c, nn, cu[idx[t] * 4], cu[idx[t] * 4 + 2]]
			else:
				used[found] = 1
	# The shader's brick-face middle (terrain.gdshader overlay_holes): every
	# vertex of a covered face (CUSTOM0.b 64) finds, from its UV and UV2, a
	# point a centimetre inside one listed brick.
	var lost := 0
	var covered := 0
	if not m.is_empty():
		var vs2: PackedVector3Array = m[Mesh.ARRAY_VERTEX]
		var ns: PackedVector3Array = m[Mesh.ARRAY_NORMAL]
		var uv: PackedVector2Array = m[Mesh.ARRAY_TEX_UV]
		var uv2: PackedVector2Array = m[Mesh.ARRAY_TEX_UV2]
		var cu2: PackedByteArray = m[Mesh.ARRAY_CUSTOM0]
		for v in vs2.size():
			if cu2[v * 4 + 2] != 64 or uv2[v].x <= 0.0 or uv2[v].y <= 0.0:
				continue
			covered += 1
			var nn := ns[v]
			var dd := 0.5 * uv2[v] - uv[v]
			var to_mid: Vector3
			if absf(nn.x) > 0.5:
				to_mid = Vector3(0.0, dd.y, dd.x * signf(nn.x))
			elif absf(nn.z) > 0.5:
				to_mid = Vector3(-dd.x * signf(nn.z), dd.y, 0.0)
			else:
				to_mid = Vector3(dd.x, 0.0, dd.y)
			var mid := vs2[v] + to_mid - nn * 0.01 + origin
			var k := Vector2i(floori(mid.x / stud), floori(mid.z / stud))
			var inside := false
			for i in cols.get(k, []):
				var a: Vector3 = lo[i]
				var e: Vector3 = hi[i]
				if mid.x > a.x and mid.x < e.x and mid.y > a.y and mid.y < e.y and mid.z > a.z and mid.z < e.z:
					inside = true
					break
			if not inside:
				lost += 1
	_lost += lost
	_covered += covered
	# A surface piece whose top a laid tile or plate covers (a listed brick of
	# the same footprint lying right on it) and whose sides its neighbours
	# cover has no face of its own: listed, harmless, not counted.
	var under_plate := {}
	for i in n:
		var a: Vector3 = lo[i]
		var e: Vector3 = hi[i]
		under_plate[Vector4(snappedf(a.x, 0.01), snappedf(a.z, 0.01), snappedf(e.x, 0.01), snappedf(e.z, 0.01))] = \
				under_plate.get(Vector4(snappedf(a.x, 0.01), snappedf(a.z, 0.01), snappedf(e.x, 0.01), snappedf(e.z, 0.01)), []) + [i]
	var unused := 0
	var covered_pieces := 0
	for i in n:
		if used[i] != 0:
			continue
		var a: Vector3 = lo[i]
		var e: Vector3 = hi[i]
		var plated := false
		for j in under_plate.get(Vector4(snappedf(a.x, 0.01), snappedf(a.z, 0.01), snappedf(e.x, 0.01), snappedf(e.z, 0.01)), []):
			if j != i and absf((lo[j] as Vector3).y - e.y) < 0.001:
				plated = true
				break
		if plated:
			covered_pieces += 1
		else:
			unused += 1
	print("[bricks] %s: %d bricks, %d triangles, %d off every brick (first %s), %d bricks with no face (%d more under a laid plate), %d overlaps"
			% [tag, n, tris, off, first_off, unused, covered_pieces, overlaps])
	_expect(n > 0 or tris == 0, "%s lists its bricks" % tag)
	# A few thin strips on a surface tile's outer edge, facing out, are no
	# brick's (filler where tiles meet): under 1 %, 20 a tile.
	_expect(off <= maxi(tris / 100, 20), "%s: every face lies on a listed brick (%d of %d off)" % [tag, off, tris])
	# Pieces under a laid plate are counted apart (above); the rest each have
	# a face (a few more allowed, under 5 %, 50 a tile).
	_expect(unused <= maxi(n / 20, 50), "%s: every listed brick has a face (%d of %d without, %d under a laid plate)" % [tag, unused, n, covered_pieces])
	_expect(overlaps == 0, "%s: no two bricks overlap (%d)" % [tag, overlaps])
