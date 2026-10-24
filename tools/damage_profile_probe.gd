extends SceneTree
## BrickWorld.build_damage_profile against a plain reading of it: every column
## of the footprint walked, band by band, from a copy of which cells stand
## (get_solid_cells). The C++ walks only the outer ring the rectangle tests
## read, alive per block (2026-10-23); this says it answers the same, over a
## big tower shot at random until it is mostly gone, and how long each takes.
##   --headless --path . --script res://tools/damage_profile_probe.gd

const FX := 40
const FZ := 30
const COURSES := 34

var _fails := 0


func _init() -> void:
	var w := BrickWorld.new()
	var palette := TowerRecipe.bake_palette(w)
	var reg := BuildingRegistry.new(w, palette)
	var id := reg.register(FX, FZ, COURSES, Transform3D())
	var chunk := reg.materialise(id)
	var b := reg.get_building(id)
	var bands := PackedInt32Array()
	for band in TowerRecipe.layout(COURSES):
		bands.push_back(int(band.y))
		bands.push_back(int(band.plates))
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var top := float(b.recipe.courses) * 0.4
	var cpp_us := 0
	var worst_us := 0
	var rounds := 0
	var damaged_seen := 0
	for r in 60:
		# Hits on the walls and inside, growing: holes, then whole stretches.
		for k in 4 + r:
			var p := Vector3(rng.randf_range(-0.5, FX * 0.4 + 0.5), rng.randf_range(0.0, top),
					rng.randf_range(-0.5, FZ * 0.4 + 0.5))
			reg.damage(id, p, rng.randf_range(0.6, 2.4))
		var t0 := Time.get_ticks_usec()
		var got: Dictionary = w.build_damage_profile(chunk, FX, FZ, TowerRecipe.WALL_THICK,
				BuildingShell.SEGMENTS, bands)
		var dt := Time.get_ticks_usec() - t0
		cpp_us += dt
		worst_us = maxi(worst_us, dt)
		var want := _reference(w, chunk, bands)
		rounds += 1
		if not got.is_empty():
			damaged_seen += 1
		if not _same(got, want):
			_fails += 1
			print("  FAIL round %d: %d band(s) vs %d expected" % [r, got.size(), want.size()])
	print("  %d rounds, %d with damage in the profile; alive at the end %d" % [
			rounds, damaged_seen, w.get_alive_block_count(chunk)])
	print("  build_damage_profile: mean %.3f ms, worst %.3f ms" % [
			float(cpp_us) / rounds / 1000.0, float(worst_us) / 1000.0])
	_ok("every round matches the full walk", _fails == 0)
	_ok("and the tower was damaged in most of them", damaged_seen > rounds / 2)
	print("[damage_profile] %s" % ("ok" if _fails == 0 else "FAIL"))
	quit(0 if _fails == 0 else 1)


## The profile as the full walk gives it: a column is alive in a band if any
## cell of the band's rows in it stands; then the four walls' segment masks.
func _reference(w: BrickWorld, chunk: int, bands: PackedInt32Array) -> Dictionary:
	var out := {}
	var solid := w.get_solid_cells(chunk)
	var o: Vector3i = w.get_chunk_origin(chunk)
	var d: Vector3i = w.get_chunk_dims(chunk)
	var thick := TowerRecipe.WALL_THICK
	var segs := BuildingShell.SEGMENTS
	for bi in bands.size() / 2:
		var y0 := bands[bi * 2] - o.y
		var y1 := y0 + bands[bi * 2 + 1]
		var col := PackedByteArray()
		col.resize(d.x * d.z)
		for y in range(maxi(0, y0), mini(d.y, y1)):
			for z in d.z:
				for x in d.x:
					if solid[x + d.x * (y + d.y * z)] != 0:
						col[x + d.x * z] = 1
		var masks := [0, 0, 0, 0]
		for seg in segs:
			var ax := (seg * FX) / segs
			var bx := maxi(ax + 1, ((seg + 1) * FX) / segs)
			var az := (seg * FZ) / segs
			var bz := maxi(az + 1, ((seg + 1) * FZ) / segs)
			var bit := 1 << seg
			if _any(col, ax, bx, 0, thick): masks[0] |= bit
			if _any(col, ax, bx, FZ - thick, FZ): masks[1] |= bit
			if _any(col, 0, thick, az, bz): masks[2] |= bit
			if _any(col, FX - thick, FX, az, bz): masks[3] |= bit
		# As 32-bit ints, like the C++: every bit set is -1 (ALL_STANDING).
		var m := PackedInt32Array(masks)
		if m[0] != -1 or m[1] != -1 or m[2] != -1 or m[3] != -1:
			out[bi] = m
	return out


func _any(col: PackedByteArray, x0: int, x1: int, z0: int, z1: int) -> bool:
	for z in range(maxi(z0, 0), z1):
		for x in range(maxi(x0, 0), x1):
			var i := x + FX * z
			if i >= 0 and i < col.size() and col[i] != 0:
				return true
	return false


func _same(a: Dictionary, b: Dictionary) -> bool:
	if a.size() != b.size():
		return false
	for k in a:
		if not b.has(k) or PackedInt32Array(a[k]) != PackedInt32Array(b[k]):
			return false
	return true


func _ok(what: String, cond: bool) -> void:
	print("  %s %s" % ["ok  " if cond else "FAIL", what])
	if not cond:
		_fails += 1
