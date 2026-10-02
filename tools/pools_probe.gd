extends SceneTree

## Pools: dug ground that fills from the sea (Docs/Water.md 12).
##
##     godot --headless --path . --script res://tools/pools_probe.gd
##
## What each check is for:
## - a hole dug into the beach THROUGH to the sea fills by flowing, not at
##   once, and ends level with the sea (the breach);
## - a hole dug a few studs up the beach, with sand between it and the sea,
##   fills too, slowly (seeping);
## - a hole dug below the sea far inland stays dry: the sea is not under
##   everything;
## - water poured into a basin spreads flat and none is lost or made;
## - still water stops being ticked (a pool costs nothing at rest);
## - ground dug deeper under the sea is still sea, not a pool;
## - the sea tiers do not draw in a dug hole (the seabed reads it as dry,
##   and the stud mask hides the sea's waves over it).

const TerrainWorldScript := preload("res://scripts/terrain_world.gd")
const STEP := 1.0 / 60.0

var _passed := 0
var _failed := 0
var _stud := 0.35
var _plate := 0.14
var _tile := 32
var _sea := 0.0


func _initialize() -> void:
	_run.call_deferred()


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_passed += 1
	else:
		_failed += 1
	print("  %s %s%s" % ["ok  " if cond else "FAIL", what, ("  " + detail) if detail != "" else ""])


func _ground(x: int, z: int) -> float:
	return float(BrickTerrain.surface_plate(x, z) + 1) * _plate


func _bare(x: int, z: int) -> float:
	return float(BrickTerrain.generated_plate(x, z) + 1) * _plate


## Lower every column in `r` by `metres` (a sculpt, as the editor's brush
## writes it), and tell the pools.
func _dig(r: Rect2i, metres: float) -> void:
	var t0 := Vector2i(floori(float(r.position.x) / _tile), floori(float(r.position.y) / _tile))
	var t1 := Vector2i(floori(float(r.end.x - 1) / _tile), floori(float(r.end.y - 1) / _tile))
	for tz in range(t0.y, t1.y + 1):
		for tx in range(t0.x, t1.x + 1):
			var arr: PackedFloat32Array = BrickTerrain.get_sculpt_tile(tx, tz)
			if arr.size() != _tile * _tile:
				arr = PackedFloat32Array()
				arr.resize(_tile * _tile)
			for lz in _tile:
				for lx in _tile:
					if r.has_point(Vector2i(tx * _tile + lx, tz * _tile + lz)):
						arr[lz * _tile + lx] -= metres
			BrickTerrain.set_sculpt_tile(tx, tz, arr)
	BrickPools.ground_changed(r)


func _sim(seconds: float) -> int:
	var ticked := 0
	for i in int(seconds / STEP):
		ticked += BrickPools.tick(STEP)
	return ticked


## Mean water level over the columns of `r`, and how many are wet.
func _mean_level(r: Rect2i) -> Vector2:
	var sum := 0.0
	var wet := 0
	for z in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			var d := BrickPools.depth_at(x, z)
			if d > 0.02:
				sum += _ground_floor(x, z) + d
				wet += 1
	return Vector2(sum / maxf(wet, 1), wet)


func _ground_floor(x: int, z: int) -> float:
	var l := BrickPools.level_at((x + 0.5) * _stud, (z + 0.5) * _stud)
	var d := BrickPools.depth_at(x, z)
	return l - d if is_finite(l) else _ground(x, z)


## A column on the beach: generated dry, within `lo`..`hi` metres above the
## sea, whose nearest sea in +x is exactly `gap` studs away, with dry sand
## between. Coarse rows find where the land meets the sea; a walk a stud at a
## time finds the waterline.
func _find_beach(gap: int, lo: float, hi: float) -> Vector2i:
	for z in range(-3000, 3000, 37):
		for x in range(-3000, 3000, 40):
			if _bare(x, z) < _sea or _bare(x + 40, z) >= _sea:
				continue
			var w := x
			while w < x + 40 and _bare(w + 1, z) >= _sea:
				w += 1
			# w is the last dry column; the sea starts at w + 1.
			var c := w + 1 - gap
			var g := _bare(c, z)
			if g < _sea + lo or g > _sea + hi:
				continue
			var ok := true
			for k in range(0, gap):
				for dz in [-2, 0, 2]:
					if _bare(c + k, z + dz) < _sea + 0.1:
						ok = false
			if ok and _bare(w + 3, z) < _sea - 0.3:
				return Vector2i(c, z)
	return Vector2i(1 << 30, 0)


## Dry land with no sea within `clear` studs, `lo`..`hi` above the sea.
func _find_inland(lo: float, hi: float, clear: int) -> Vector2i:
	for z in range(-1500, 1500, 23):
		for x in range(-1500, 1500, 23):
			var g := _bare(x, z)
			if g < _sea + lo or g > _sea + hi:
				continue
			var dry := true
			for dz in range(-clear, clear + 1, 4):
				for dx in range(-clear, clear + 1, 4):
					if _bare(x + dx, z + dz) < _sea + 0.5:
						dry = false
						break
				if not dry:
					break
			if dry:
				return Vector2i(x, z)
	return Vector2i(1 << 30, 0)


func _reset() -> void:
	BrickTerrain.clear_sculpt()
	BrickPools.clear()


func _run() -> void:
	print("pools probe")
	BrickTerrain.configure(20260919)
	BrickTerrain.set_flat_mode(true)
	_stud = BrickWorld.get_stud_metres()
	_plate = BrickWorld.get_plate_metres()
	_tile = BrickTerrain.get_tile_studs()
	_sea = TerrainWorldScript.settle_sea(TerrainWorldScript.DEFAULT_DROWNED)
	_reset()
	print("  sea level %.2f m" % _sea)

	# --- the breach --------------------------------------------------------
	var beach := _find_beach(1, 0.2, 1.2)
	_ok("found a beach next to the sea", beach.x < (1 << 29), str(beach))
	if beach.x >= (1 << 29):
		_finish()
		return
	# Six studs of beach, dug 2 m, the last column against the sea.
	var hole := Rect2i(beach.x - 5, beach.y - 2, 6, 5)
	_dig(hole, 2.0)
	_ok("the dug hole is below the sea", _ground(beach.x - 2, beach.y) < _sea - 0.5,
			"%.2f m vs sea %.2f" % [_ground(beach.x - 2, beach.y), _sea])
	_ok("a pool tile holds it", BrickPools.tile_count() > 0, "%d tiles" % BrickPools.tile_count())
	_ok("it is not sea: the sea tiers leave it dry",
			BrickPools.depth_at(beach.x - 2, beach.y) == 0.0
			and is_inf(BrickPools.level_at((beach.x - 1.5) * _stud, (beach.y + 0.5) * _stud)))
	var t_us := Time.get_ticks_usec()
	var ticked := _sim(0.25)
	var first: Vector2 = _mean_level(hole)
	_ok("after a quarter second it is still filling, not full",
			first.y < hole.get_area() or first.x < _sea - 0.1,
			"%d of %d wet, mean %.2f" % [int(first.y), hole.get_area(), first.x])
	var full_at := -1.0
	for i in 80:
		ticked += _sim(0.25)
		var m := _mean_level(hole)
		if m.y == hole.get_area() and absf(m.x - _sea) < 0.05:
			full_at = 0.25 * (i + 2)
			break
	var cost_ms := float(Time.get_ticks_usec() - t_us) / 1000.0
	_ok("it fills from the sea and ends level with it", full_at > 0.0,
			"full after %.2f s, level %.3f vs sea %.3f" % [full_at, _mean_level(hole).x, _sea])
	print("    %d column-steps in %.1f ms of sim (indicative only: not a timing pass)"
			% [ticked, cost_ms])
	var baked: Dictionary = BrickPools.build_mesh(floori(float(beach.x - 2) / _tile),
			floori(float(beach.y) / _tile))
	_ok("the pool is drawn", int(baked["triangle_count"]) > 0, "%d tris" % int(baked["triangle_count"]))
	var mask: PackedByteArray = BrickPools.sea_mask(hole.position.x, hole.position.y, 8)
	_ok("the sea is masked off the pool, stud by stud", mask[2 * 8 + 2] == 255
			and BrickPools.sea_mask(beach.x + 3, beach.y, 1)[0] == 0)
	var still_after := -1.0
	for q in 40:
		_sim(0.5)
		if BrickPools.active_count() == 0:
			still_after = 0.5 * (q + 1)
			break
	print("    still %.1f s after it was full" % still_after)
	_ok("a still pool stops being ticked", BrickPools.active_count() == 0,
			"%d active" % BrickPools.active_count())
	for c in BrickPools.active_columns(4):
		print("    still ticked: ", c)
	var field: PackedFloat32Array = BrickWave.build_shore_field(maxi(absi(beach.x), absi(beach.y)) + 8, 1)
	@warning_ignore("integer_division")
	var half: int = maxi(absi(beach.x), absi(beach.y)) + 8
	var n := 2 * half
	var k := ((beach.y + half) * n + (beach.x - 2 + half)) * 2
	_ok("the seabed reads the hole as dry ground, so the sea is not drawn in it",
			field[k] > _sea, "seabed %.2f vs sea %.2f" % [field[k], _sea])

	# --- seeping -----------------------------------------------------------
	_reset()
	var dune := _find_beach(6, 0.3, 1.5)
	_ok("found a beach six studs from the sea", dune.x < (1 << 29), str(dune))
	if dune.x < (1 << 29):
		var pit := Rect2i(dune.x - 2, dune.y - 1, 3, 3)
		_dig(pit, 1.5)
		_ok("sand stands between it and the sea", _ground(dune.x + 2, dune.y) > _sea)
		_sim(40.0)
		var m := _mean_level(pit)
		_ok("it seeps full to the sea's level", m.y == pit.get_area() and absf(m.x - _sea) < 0.06,
				"%d of %d wet, level %.2f vs sea %.2f" % [int(m.y), pit.get_area(), m.x, _sea])

	# --- inland ------------------------------------------------------------
	_reset()
	var hill := _find_inland(1.0, 2.0, 40)
	_ok("found dry ground far from the sea", hill.x < (1 << 29), str(hill))
	if hill.x < (1 << 29):
		var pit := Rect2i(hill.x - 1, hill.y - 1, 3, 3)
		_dig(pit, 3.5)
		_ok("dug below the sea", _ground(hill.x, hill.y) < _sea, "%.2f vs %.2f" % [_ground(hill.x, hill.y), _sea])
		_sim(10.0)
		_ok("and stays dry: the sea is not under everything", BrickPools.total_volume() < 0.001,
				"%.3f m3" % BrickPools.total_volume())

	# --- a basin, poured ---------------------------------------------------
	_reset()
	var high := _find_inland(4.0, 30.0, 12)
	_ok("found high ground", high.x < (1 << 29), str(high))
	if high.x < (1 << 29):
		var basin := Rect2i(high.x - 3, high.y - 3, 6, 6)
		_dig(basin, 1.5)
		var poured := 0.0
		for z in range(basin.position.y + 2, basin.position.y + 4):
			for x in range(basin.position.x + 2, basin.position.x + 4):
				BrickPools.add_water(x, z, 1.0)
				poured += 1.0 * _stud * _stud
		_sim(15.0)
		var vol := BrickPools.total_volume()
		_ok("poured water is all still there", absf(vol - poured) < poured * 0.01,
				"%.4f of %.4f m3" % [vol, poured])
		var lo := INF
		var hi := -INF
		for z in range(basin.position.y, basin.end.y):
			for x in range(basin.position.x, basin.end.x):
				var l := BrickPools.level_at((x + 0.5) * _stud, (z + 0.5) * _stud)
				if is_finite(l):
					lo = minf(lo, l)
					hi = maxf(hi, l)
		_ok("and has spread out flat", hi - lo < 0.03, "levels %.3f .. %.3f" % [lo, hi])

	# --- the sea, dug deeper -----------------------------------------------
	_reset()
	var deep := Vector2i(beach.x + 4, beach.y)
	if _bare(deep.x, deep.y) < _sea - 0.3:
		_dig(Rect2i(deep.x, deep.y, 2, 2), 1.0)
		_ok("ground dug under the sea is still sea, not a pool",
				is_nan(BrickPools.level_at((deep.x + 0.5) * _stud, (deep.y + 0.5) * _stud)))
	_reset()
	_finish()


func _finish() -> void:
	print("pools probe: %d passed, %d failed" % [_passed, _failed])
	quit(1 if _failed > 0 else 0)
