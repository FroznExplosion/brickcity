extends SceneTree
## How far a floor reaches between its supports (BrickWorld.cut_spans;
## Docs/Structures.md 2.3).
##
##     godot --headless --path . --script res://tools/span_probe.gd
##
## Generated buildings, as the city lays them:
##
##   intact    a wide building and a tower whole: nothing past its reach; the
##             biggest tower in the big city too, and what the check costs it
##   shot out  the wide one's ground storey gone between its ends: the floors over
##             the gap give way where nothing is near enough under them, at a rim
##             round the middle, and the middle comes away as one piece
##   resting   the same as a piece lying level on the ground: the same rim; tipped,
##             not asked
##   metal     the same building in metal reaches four times as far: it holds

const REACH := 20.0

var _w: BrickWorld
var _palette: Dictionary
var _pass := 0
var _fail := 0


func _init() -> void:
	print("span probe: how far a floor reaches between its supports")
	_w = BrickWorld.new()
	_palette = TowerRecipe.bake_palette(_w)
	_run()
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
	return c


## Every block reaching into the ground storey between x0 and x1 (studs), killed.
func _shoot_ground_storey(c: int, x0: float, x1: float) -> int:
	var tps := float(BrickWorld.ticks_per_stud())
	var tpp := float(BrickWorld.ticks_per_plate())
	var y0 := float(TowerRecipe.SLAB_PLATES)
	var y1 := y0 + TowerRecipe.COURSES_PER_FLOOR * TowerRecipe.PLATES_PER_COURSE
	var list := PackedInt32Array()
	for id in _w.get_block_count(c):
		var t: Array = _w.get_block_ticks(c, id)
		if t.is_empty():
			continue
		var lo: Vector3i = t[0]
		var size: Vector3i = t[1]
		var bx0 := lo.x / tps
		var bx1 := (lo.x + size.x) / tps
		var by0 := lo.y / tpp
		var by1 := (lo.y + size.y) / tpp
		if bx1 > x0 and bx0 < x1 and by1 > y0 and by0 < y1:
			list.append(id)
	_w.kill_blocks(c, list)
	return list.size()


func _x_of(c: int, id: int) -> float:
	var t: Array = _w.get_block_ticks(c, id)
	var tps := float(BrickWorld.ticks_per_stud())
	return (float((t[0] as Vector3i).x) + float((t[1] as Vector3i).x) * 0.5) / tps


func _run() -> void:
	var wide := _tower(120, 40, 18)
	var tall := _tower(40, 30, 60)
	var t0 := Time.get_ticks_usec()
	var none_wide := _w.cut_spans(wide, REACH, false)
	var ms := float(Time.get_ticks_usec() - t0) / 1000.0
	var none_tall := _w.cut_spans(tall, REACH, false)
	var big := _tower(80, 60, 204)
	# Once to build its joint cache, as the solves have in the city; timed the second.
	_w.cut_spans(big, REACH, false)
	t0 = Time.get_ticks_usec()
	var none_big := _w.cut_spans(big, REACH, false)
	var big_ms := float(Time.get_ticks_usec() - t0) / 1000.0
	_ok("the biggest tower whole: nothing, and the check is a few milliseconds",
			none_big.is_empty() and big_ms < 25.0,
			"%d rim blocks; %d bricks in %.1f ms" % [none_big.size(), _w.get_alive_block_count(big), big_ms])
	_ok("whole, a wide building and a tower have nothing past their reach",
			none_wide.is_empty() and none_tall.is_empty(),
			"%d and %d rim blocks; %d bricks in %.1f ms" % [none_wide.size(), none_tall.size(),
				_w.get_alive_block_count(wide), ms])

	var shot := _shoot_ground_storey(wide, 15.0, 105.0)
	var dry := _w.cut_spans(wide, REACH, false)
	var lo := INF
	var hi := -INF
	for id in dry:
		var x := _x_of(wide, id)
		lo = minf(lo, x)
		hi = maxf(hi, x)
	_ok("its ground storey shot out between its ends: the floors over the gap give way, at a rim round the middle",
			not dry.is_empty() and lo > 25.0 and hi < 95.0,
			"%d blocks shot; rim of %d, x %.0f to %.0f studs" % [shot, dry.size(), lo, hi])
	var before := _w.get_components(wide).size()
	var cut := _w.cut_spans(wide, REACH, true)
	var comps: Array = _w.get_components(wide)
	# The biggest group off: the floors over the middle of the gap, between the
	# rims. Each side keeps what it reaches -- REACH studs out over the gap, two
	# floor panels (a panel's reach is from its middle).
	var second: PackedInt32Array = PackedInt32Array()
	for k in range(1, comps.size()):
		if (comps[k] as PackedInt32Array).size() > second.size():
			second = comps[k]
	var mid_lo := INF
	var mid_hi := -INF
	for id in second:
		var x := _x_of(wide, id)
		mid_lo = minf(mid_lo, x)
		mid_hi = maxf(mid_hi, x)
	_ok("and the middle comes away as one piece, between the rims",
			cut == dry and second.size() > 500 and mid_lo >= lo - 1.0 and mid_hi <= hi + 1.0,
			"%d group(s) before, %d after; the biggest off %d bricks, x %.0f to %.0f" % [
				before, comps.size(), second.size(), mid_lo, mid_hi])

	# The same shot-out building as a piece lying level on the ground: held where
	# it rests, as a building is by its foundation -- the same rim. Tipped over
	# it is not asked.
	var piece := _tower(120, 40, 18)
	_shoot_ground_storey(piece, 15.0, 105.0)
	var as_building := _w.cut_spans(piece, REACH, false)
	var lying := _w.cut_spans_resting(piece, Transform3D.IDENTITY, PackedInt32Array(), 0.05, REACH, false)
	var tipped := _w.cut_spans_resting(piece, Transform3D(Basis(Vector3(0, 0, 1), deg_to_rad(60.0)), Vector3.ZERO),
			PackedInt32Array(), 0.05, REACH, false)
	_ok("a piece lying level is held where it rests, as a building by its foundation; tipped over it is not asked",
			not lying.is_empty() and lying == as_building and tipped.is_empty(),
			"%d rim blocks lying, %d as a building, %d tipped" % [lying.size(), as_building.size(), tipped.size()])

	var metal := _tower(120, 40, 18)
	for id in _w.get_block_count(metal):
		_w.set_block_material(metal, id, 11)
	_shoot_ground_storey(metal, 15.0, 105.0)
	var held := _w.cut_spans(metal, REACH, false)
	_ok("the same building in metal reaches four times as far: it holds", held.is_empty(),
			"%d rim blocks (material %s)" % [held.size(), BrickWorld.get_material_name(11)])
