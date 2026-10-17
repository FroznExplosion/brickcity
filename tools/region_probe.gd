extends SceneTree
## The load check by region (BrickWorld.gravity_check's region_ratio;
## Docs/Structures.md 2.3).
##
##     godot --headless --path . --script res://tools/region_probe.gd
##
##   intact    every shape the city builds, whole: no region near its limit (the
##             whole-boundary check never fired on them, nor may this)
##   tower     a tower on a wide base -- the 80 x 60 tower cut down to three
##             storeys but for one 32-stud corner -- with the columns of its
##             ground storey under the tower shot out: the boundary as a whole
##             hardly moves, the region under the tower fails
##   command   the SEVER that region's crush makes (DamageLog.region_crush) tears
##             loose that storey under that region and nothing else, and played
##             again from its wire form on a twin, cuts the same bricks

var _w: BrickWorld
var _palette: Dictionary
var _pass := 0
var _fail := 0


func _init() -> void:
	print("region probe: the load check, a region at a time")
	_w = BrickWorld.new()
	_palette = TowerRecipe.bake_palette(_w)
	_intact()
	_tower_on_base()
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _ok(what: String, cond: bool, detail := "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _tower(fx: int, fz: int, courses: int) -> int:
	var c := _w.create_chunk(Vector3i.ZERO, TowerRecipe.chunk_dims(fx, fz, courses))
	TowerRecipe.build(_w, c, _palette, fx, fz, courses)
	_w.set_tension_per_stud(c, BrickStrength.tension())
	return c


## As CityScene._gravity_fail asks it.
func _check(c: int) -> Dictionary:
	return _w.gravity_check(c, 20.0 * BrickStrength.SCALED / _w.get_tension_per_stud(c))


## [lo, hi] of a block in studs across and plates up.
func _box(c: int, id: int) -> Array:
	var t: Array = _w.get_block_ticks(c, id)
	if t.is_empty():
		return []
	var tps := float(BrickWorld.ticks_per_stud())
	var tpp := float(BrickWorld.ticks_per_plate())
	var lo: Vector3i = t[0]
	var size: Vector3i = t[1]
	return [Vector3(lo.x / tps, lo.y / tpp, lo.z / tps),
			Vector3((lo.x + size.x) / tps, (lo.y + size.y) / tpp, (lo.z + size.z) / tps)]


func _intact() -> void:
	var worst := 0.0
	var worst_of := ""
	var over_whole := 0.0
	for sh in [[30, 30, 18], [40, 30, 30], [30, 40, 60], [30, 30, 78], [40, 40, 120],
			[60, 40, 162], [50, 50, 102], [80, 60, 204], [30, 30, 246], [240, 50, 12],
			[160, 60, 18], [200, 80, 24], [120, 40, 12]]:
		var c := _tower(sh[0], sh[1], sh[2])
		var g := _check(c)
		if float(g.region_ratio) > worst:
			worst = float(g.region_ratio)
			worst_of = "%s, whole %.2f" % [str(sh), float(g.ratio)]
		over_whole = maxf(over_whole, float(g.region_ratio) - float(g.ratio))
		_w.release_chunk(c)
	# Measured 2026-10-17: 0.54 at the worst (the 246-course tower, whole 0.54),
	# a region at most 0.11 over its building's whole boundary.
	_ok("whole, no region of any city shape is near failing", worst < 0.7,
			"worst %.2f (%s); a region at most %.2f over the whole" % [worst, worst_of, over_whole])


## The 80 x 60 tower, everything over its third storey gone but a 32-stud
## corner: a tower on a wide base. `keep` says what of the ground storey under
## the tower is left: "all", or only the wall along x = 0.
func _sculpt(keep: String) -> int:
	var c := _tower(80, 60, 120)
	var storey := float(TowerRecipe.STOREY_PLATES)
	var y0 := float(TowerRecipe.SLAB_PLATES)
	var kill := PackedInt32Array()
	for id in _w.get_block_count(c):
		var bx := _box(c, id)
		if bx.is_empty():
			continue
		var lo: Vector3 = bx[0]
		var hi: Vector3 = bx[1]
		var mid := (lo + hi) * 0.5
		var under := mid.x < 32.0 and mid.z < 32.0
		if lo.y >= y0 + storey * 3.0 and not under:
			kill.append(id)
		elif keep != "all" and under and hi.y > y0 and lo.y < y0 + storey and lo.x >= 2.0:
			kill.append(id)
	_w.kill_blocks(c, kill)
	return c


func _tower_on_base() -> void:
	var c := _sculpt("all")
	var whole := _check(c)
	_ok("a tower on a wide base, whole: it stands", float(whole.ratio) < 1.0 and float(whole.region_ratio) < 1.0,
			"whole %.2f, worst region %.2f" % [float(whole.ratio), float(whole.region_ratio)])
	_w.release_chunk(c)

	c = _sculpt("wall")
	var g := _check(c)
	var area: Rect2i = g.get("region", Rect2i())
	_ok("the columns under the tower shot out: the boundary as a whole hardly moves",
			float(g.ratio) < 1.0, "whole %.2f (it was %.2f)" % [float(g.ratio), float(whole.ratio)])
	_ok("and the region under the tower cannot carry it", float(g.region_ratio) >= 1.0
			and area == Rect2i(0, 0, 32, 32),
			"region %.2f at %s, %.0f above" % [float(g.region_ratio), str(area), float(g.get("region_mass_above", 0.0))])

	# The command, as CityScene._region_fail makes it.
	var storey_m := float(TowerRecipe.STOREY_PLATES) * BrickPalette.PLATE_M
	var e := DamageLog.region_crush(_w, c, g, storey_m)
	var cut := DamageLog.apply_entry(_w, c, e)
	var level := float(int(g.region_level_cell))
	var storey := float(TowerRecipe.STOREY_PLATES)
	var outside := 0
	for id in cut:
		var bx := _box(c, id)
		var mid: Vector3 = ((bx[0] as Vector3) + (bx[1] as Vector3)) * 0.5
		if mid.x >= 32.0 or mid.z >= 32.0 or mid.y > level or mid.y < level - storey:
			outside += 1
	_ok("its crush tears loose the storey under that region, and nothing else", not cut.is_empty()
			and outside == 0, "%d bricks torn loose, %d outside the region's storey" % [cut.size(), outside])

	var twin := _sculpt("wall")
	var again := DamageLog.apply_entry(_w, twin, DamageLog.Entry.from_array(e.to_array()))
	_ok("played again from its wire form on a twin, it cuts the same bricks", again == cut,
			"%d and %d" % [cut.size(), again.size()])
	_w.release_chunk(c)
	_w.release_chunk(twin)
