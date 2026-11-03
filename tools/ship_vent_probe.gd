extends SceneTree
## Venting in a flying ship (Docs/Hulls.md 4): a generated ship's air baked with it,
## a hit through its hull followed, and the air let out.
##
##     godot --headless --path . --script res://tools/ship_vent_probe.gd
##
##   baked     prepare bakes its air: every room full, hits followed
##   doors     its doors' open states line up with the air's doors
##   shot      a hole of hull bricks killed by the hit path (_after_kill): its room
##             breached, after a second its pressure down, the rush toward the hole,
##             the HUD's "venting"; crumbs on its floor drawn out; a far room untouched
##   sealed    the hole's brick back: the room stops losing air and fills again

var _pass := 0
var _fail := 0
var _st: SpaceStation
var _frames := 0
var _stage := 0
var _room := -1
var _far := -1
var _inside := Vector3.ZERO
var _hole := Vector3.ZERO
var _block := -1
var _t := 0.0


func _ok(what: String, cond: bool, detail := "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _finish() -> void:
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _process(delta: float) -> bool:
	_frames += 1
	match _stage:
		0:
			print("ship vent probe")
			var d := OrbitalData.new()
			d.kind = "ship"
			d.layout = "generated"
			d.orbital_name = "probe ship"
			d.orbital_seed = 1
			_st = SpaceStation.new()
			root.add_child(_st)
			_st.setup(d)
			_st.prepare()
			var air := _st.air
			var full := air != null
			if air != null:
				for c in air.compartments():
					full = full and absf(float(c.pressure) - 1.0) < 1e-5
			_ok("prepare bakes its air: every room full, hits followed", full and air.follows_hits(),
					"%d cells, %d rooms, %.0f ms" % [air.inside_cells(), air.compartments().size(), air.bake_ms]
					if air != null else "no air")
			if air == null:
				_finish()
				return true
			_st.activate()
			_stage = 1
		1:
			if not _st.bricked:
				if _frames > 900:
					_ok("its bricks laid", false)
					_finish()
					return true
				return false
			_st.doors.resync()
			var st := _st.doors.open_states(0)
			_ok("its doors' states line up with the air's", st.size() == _st.air.doors.size() and st.size() > 0,
					"%d / %d" % [st.size(), _st.air.doors.size()])
			_shoot()
			_stage = 2
			_t = 0.0
		2:
			_t += delta
			if _t < 1.0:
				return false
			var air := _st.air
			var a := _st.air_at(_inside)
			var p := air.pressure(_room)
			var far_p := air.pressure(_far) if _far >= 0 else 1.0
			_ok("shot: its room breached, the air going", air.is_breached(_room) and p < 0.999 and p > 0.0,
					"%d brick(s) shot out: %.3f after %.2f s" % [_holes, p, _t])
			_ok("air_at inside it: its pressure, breached, the rush toward the hole", not a.is_empty()
					and bool(a.breached) and bool(a.venting) and absf(float(a.pressure) - p) < 1e-4
					and (a.pull as Vector3).dot(_hole - _inside) > 0.0,
					"%s, pull %.2f m/s2" % [str(a.get("pressure")), (a.get("pull", Vector3.ZERO) as Vector3).length()])
			_ok("a room away from it untouched", _far >= 0 and absf(far_p - 1.0) < 1e-4, "%.4f" % far_p)
			var d1 := _crumb_dist()
			var out := _crumbs_out()
			_ok("crumbs inside drawn to the hole, or out of it", _crumbs > 0 and (d1 < _crumb_d0 - 0.1 or out > 0),
					"%d crumb(s): %.2f m -> %.2f m from it, %d out of the hull" % [_crumbs, _crumb_d0, d1, out])
			# Sealed: the hole's bricks laid back.
			var r := _st.recipe
			var nb := 0
			var cells: Array[Vector3i] = []
			for b in _hole_ids:
				var ri: int = air._block_recipe[b]
				_st.bricks.remove_block(_st.chunk, b)
				if _st.bricks.place_block(_st.chunk, r.cell_of(ri) - r.origin(), _st._palette[r.part_of(ri)], r.colour_of(ri)) < 0:
					nb = -1
				for i in air._block_cells(b):
					cells.append(air._cell(i))
			air.cells_added(_st.bricks, _st.chunk, cells)
			_ok("the brick back: sealed", nb >= 0 and not air.is_breached(_room))
			# Parked on a world with air: a hole lets nothing out.
			var lab := HullAir.new()
			lab.dims = Vector3i(3, 3, 3)
			lab._parent = PackedInt32Array([0])
			lab._cells = PackedInt32Array([10])
			lab._air = PackedFloat32Array([10.0])
			lab._rate = PackedFloat32Array([0.0])
			lab._breach = [{0: true}]
			lab.step(1.0, 1.0)
			_ok("in a world's air a hole lets nothing out", absf(lab.pressure(0) - 1.0) < 1e-5 and lab.vent_rate(0) == 0.0)
			_t = 0.0
			_room_p = p
			_stage = 3
		3:
			_t += delta
			if _t < 0.5:
				return false
			var p2 := _st.air.pressure(_room)
			_ok("sealed: no more goes, the supply fills it again", _st.air.vent_rate(_room) == 0.0 and p2 > _room_p,
					"%.3f -> %.3f" % [_room_p, p2])
			_finish()
			return true
	return false


var _room_p := 0.0
var _crumbs := 0
var _holes := 0
var _hole_ids := PackedInt32Array()
## How far round the first brick the hole reaches, cells.
const HOLE := 6.0
var _crumb_d0 := 0.0


## Crumbs out in the open: past the ship's box, or in its outside air.
func _crumbs_out() -> int:
	var n := 0
	var pxf := _st.crumbs.planet.global_transform
	for key in _st.crumbs._sets:
		for q in _st.crumbs._sets[key].pos:
			var wp: Vector3 = pxf * q
			var c := Vector3i(_st.cell_at(wp).floor())
			if not _st.holds(wp) or (_st.air._in(c) and _st.air.state[_st.air._idx(c)] == HullAir.OUTSIDE):
				n += 1
	return n


## The crumbs' mean distance from the hole, metres.
func _crumb_dist() -> float:
	var sum := 0.0
	var n := 0
	var pxf := _st.crumbs.planet.global_transform
	for key in _st.crumbs._sets:
		var st = _st.crumbs._sets[key]
		for q in st.pos:
			sum += (pxf * q).distance_to(_hole)
			n += 1
	return sum / n if n > 0 else 0.0


## A hull brick (beside a room -- a real one, not a gap in a wall -- and the outside)
## killed through the hit path.
func _shoot() -> void:
	var air := _st.air
	for b in _st.bricks.get_block_count(_st.chunk):
		var ins := {}
		var out := false
		for i in air._block_cells(b):
			for j in air._neighbours(i):
				if air.state[j] == HullAir.INSIDE:
					ins[air._root(air.comp[j])] = j
				elif air.state[j] == HullAir.OUTSIDE:
					out = true
		if out and ins.size() == 1 and air._cells[air._root(ins.keys()[0])] > 1000:
			_block = b
			_room = ins.keys()[0]
			var cell := air._cell(ins[_room])
			_inside = _st.global_transform * _st.frame * ((Vector3(cell) + Vector3(0.5, 0.5, 0.5)) * BrickWorld.get_cell_size())
			var hc := air._cell(air._block_cells(b)[0])
			_hole = _st.global_transform * _st.frame * ((Vector3(hc) + Vector3(0.5, 0.5, 0.5)) * BrickWorld.get_cell_size())
			break
	# A room far from it.
	for c in air.compartments():
		if c.id != air._root(_room) and int(c.cells) > 50 and int(c.breaches) == 0:
			_far = c.id
	_ok("a hull brick to shoot", _block >= 0)
	# Crumbs of a brick of the room's floor near the hole, thrown as a hit would.
	var near_b := -1
	var nd := INF
	var hc := Vector3(air._cell(air._block_cells(_block)[0]))
	for b in _st.bricks.get_block_count(_st.chunk):
		if b == _block:
			continue
		var cs := air._block_cells(b)
		if cs.is_empty():
			continue
		# A floor brick: the room's air right over it.
		var under_room := false
		for i in cs:
			var c := air._cell(i) + Vector3i(0, 1, 0)
			under_room = under_room or (air._in(c) and air.state[air._idx(c)] == HullAir.INSIDE
					and air._root(air.comp[air._idx(c)]) == air._root(_room))
		if under_room:
			var d := (Vector3(air._cell(cs[0])) - hc).length()
			if d < nd:
				nd = d
				near_b = b
	_crumbs = _st.crumbs.throw(_st.bricks, _st.chunk, PackedInt32Array([near_b])) if near_b >= 0 else 0
	_crumb_d0 = _crumb_dist()
	# A real hole: every hull brick of that room within HOLE cells of the first.
	var hole := PackedInt32Array([_block])
	for b in _st.bricks.get_block_count(_st.chunk):
		if b == _block or b == near_b:
			continue
		var cs := air._block_cells(b)
		if cs.is_empty() or (Vector3(air._cell(cs[0])) - hc).length() > HOLE:
			continue
		var by_room := false
		var by_out := false
		for i in cs:
			for j in air._neighbours(i):
				by_room = by_room or (air.state[j] == HullAir.INSIDE and air._root(air.comp[j]) == air._root(_room))
				by_out = by_out or air.state[j] == HullAir.OUTSIDE
		if by_room and by_out:
			hole.append(b)
	_holes = hole.size()
	_hole_ids = hole
	_st.bricks.kill_blocks(_st.chunk, hole)
	_st._after_kill(hole)
