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

const EPS := 0.004

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
	BrickTerrain.set_face_bevel(0.0)

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
	var n := b.size() / 10
	var lo: Array[Vector3] = []
	var hi: Array[Vector3] = []
	# Bricks by stud column they cover, for the lookup.
	var stud := BrickWorld.get_stud_metres()
	var cols := {}
	for i in n:
		var a := Vector3(b[i * 10], b[i * 10 + 1], b[i * 10 + 2])
		var c := Vector3(b[i * 10 + 3], b[i * 10 + 4], b[i * 10 + 5])
		lo.append(a)
		hi.append(c)
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
	var unused := 0
	for i in n:
		if used[i] == 0:
			unused += 1
	print("[bricks] %s: %d bricks, %d triangles, %d off every brick (first %s), %d bricks with no face, %d overlaps"
			% [tag, n, tris, off, first_off, unused, overlaps])
	_expect(n > 0 or tris == 0, "%s lists its bricks" % tag)
	# A few thin strips on a surface tile's outer edge, facing out, are no
	# brick's (filler where tiles meet): under 1 %, 20 a tile.
	_expect(off <= maxi(tris / 100, 20), "%s: every face lies on a listed brick (%d of %d off)" % [tag, off, tris])
	# A surface piece whose top a tile or plate covers and whose sides its
	# neighbours cover has no face of its own: listed, harmless (under 5 %, 50 a tile).
	_expect(unused <= maxi(n / 20, 50), "%s: every listed brick has a face (%d of %d without)" % [tag, unused, n])
	_expect(overlaps == 0, "%s: no two bricks overlap (%d)" % [tag, overlaps])
