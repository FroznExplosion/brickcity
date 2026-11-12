extends SceneTree
## Water inside a hull (Docs/Hulls.md 5, HullWater) on a generated ship held still,
## the outside water a level plane its holes see (SpaceStation.water_depth).
##
##     godot --headless --path . --script res://tools/hull_flood_probe.gd
##
##   fills     a hole low in its hull under the water: its room fills, to the
##             outside level and no higher
##   holds     a shut door holds the room next to it dry
##   door      opened, it lets the water on into the next room
##   inside    water only ever in inside cells and open doorways
##   mass      what came in less what went out is what the grid holds
##   drains    the water lowered under the hole: it runs back out

const FILL := 25.0
const DOOR := 10.0
const DRAIN := 20.0

var _pass := 0
var _fail := 0
var _st: SpaceStation
var _frames := 0
var _stage := 0
var _t := 0.0
var _room := -1
var _hole_y := 0.0
var _level := 0.0
var _door := -1
var _next_room := -1
var _vented := false
var _spray := -1


func air_root() -> int:
	return _st.air._root(_room)


func _ok(what: String, cond: bool, detail := "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _finish() -> void:
	if _st != null:
		_st.deactivate()
		_st.queue_free()
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _depth(p: Vector3) -> float:
	return _level - p.y


func _process(delta: float) -> bool:
	_frames += 1
	match _stage:
		0:
			print("hull flood probe")
			var d := OrbitalData.new()
			d.kind = "ship"
			d.layout = "generated"
			d.orbital_name = "flood ship"
			d.orbital_seed = 1
			_st = SpaceStation.new()
			root.add_child(_st)
			_st.setup(d)
			_st.prepare()
			_st.activate()
			_stage = 1
		1:
			if not _st.bricked:
				if _frames > 1800:
					_ok("its bricks laid", false)
					_finish()
					return true
				return false
			if not _hole():
				_finish()
				return true
			_st.water_depth = _depth
			_t = 0.0
			_stage = 2
		2:
			_t += delta
			if _spray < 0 and _t > 0.5 and not _vented:
				# The sea bursting in at the hole while the room fills (Docs/Hulls.md 8.2).
				_spray = 0
				for j in HullSpray.jets_of(_st):
					var c: Vector3 = _st.cell_at(j.at)
					var d: Vector3 = (_st.global_transform * _st.frame).basis.inverse() * (j.dir as Vector3)
					var into: Vector3 = c + d / BrickWorld.get_cell_size() * 1.5
					if _st.air.compartment_at(Vector3i(into.floor())) >= 0:
						_spray += 1
			if _t < FILL:
				return false
			var w := _st.hull_water
			if not _vented:
				# Sealed (an airtight hull, its one hole under the water): the water
				# squeezes the room's air and stops, the pocket held (Docs/Hulls.md 5.2).
				var r := air_root()
				var room := w.pocket_room(r, _st._hole_depth)
				var have := w.in_compartment(_room)
				var cells := float(_st.air._cells[r])
				_ok("trapped: sealed, the water stops where its air is squeezed to the water's pressure",
						w.trapped.has(r) and have > 0.5 and have <= room + 1.0 and have < 0.2 * cells,
						"%.1f cells of water in %d, room for %.1f (the hole %.2f m under)" % [
						have, int(cells), room, _level - _hole_y])
				_ok("spray: the sea bursting in at the hole, into the room, while it fills", _spray > 0,
						"%d jet(s) pointing in" % _spray)
				# A vent: its air may go, and it fills on.
				_vented = true
				w.air_leak = INF
				_t = 0.0
				return false
			var top := -INF
			for i: int in w.wet:
				if w.level(i) > 0.5:
					top = maxf(top, _cell_y(i) + BrickWorld.get_plate_metres() * 0.5)
			var in_room := w.in_compartment(_room)
			_ok("fills: its room fills from the hole, up to the outside level and no higher",
					in_room > 50.0 and top <= _level + 0.3 and top >= _level - 0.6,
					"%.0f cells of water, its top %.2f m against the water outside at %.2f (the hole at %.2f)" % [
					in_room, top, _level, _hole_y])
			# A head in the water, and one over it (SpaceStation.water_at; drowning).
			var deep := -1
			var dry := -1
			for i: int in w.wet:
				if w.level(i) >= 1.0 and (deep < 0 or _cell_y(i) < _cell_y(deep)):
					deep = i
			for i in w.air.state.size():
				if w.air.state[i] == HullAir.INSIDE and w.air._root(w.air.comp[i]) == w.air._root(_room) 						and w.fill_at(i) <= 0.0 and (dry < 0 or _cell_y(i) > _cell_y(dry)):
					dry = i
			var mid := Vector3(0.0, BrickWorld.get_plate_metres() * 0.5, 0.0)
			var wd := NAN if deep < 0 else _st.water_at(_st.global_transform * (_st.cell_point(w.air._cell(deep)) + _st.frame.basis * mid))
			var wu := NAN if dry < 0 else _st.water_at(_st.global_transform * (_st.cell_point(w.air._cell(dry)) + _st.frame.basis * mid))
			var wo := _st.water_at(_st.global_position + Vector3(0, 5000, 0))
			_ok("under: a head in the room's water is under it, one over it is not, outside the hull is not its to say",
					wd >= 1.0 and wu == 0.0 and is_nan(wo), "%.2f in the water, %.2f at the room's top, %s outside" % [wd, wu, wo])
			_ok("holds: a shut door keeps the room beside it dry", _next_room >= 0
					and w.in_compartment(_next_room) < 0.5, "%.2f cells in it" % (w.in_compartment(_next_room) if _next_room >= 0 else -1.0))
			_inside_check("after filling")
			_mesh_check(w, "a room filled")
			if _door >= 0:
				# Opened and kept open: its leaves' own sync would shut it again (nobody
				# is near it here).
				_st.doors = null
				_st.air.set_door(_door, true)
			_t = 0.0
			_stage = 3
		3:
			_t += delta
			if _t < DOOR:
				return false
			var w := _st.hull_water
			var got := w.in_compartment(_next_room) if _next_room >= 0 else 0.0
			# Opened, the two rooms are one compartment to the air: count by the door's far side.
			_ok("door: opened, the water goes on into the next room", _door >= 0 and _wet_beyond_door() > 5.0,
					"%.0f cells past the door" % _wet_beyond_door())
			_inside_check("through the door")
			var held := w.total()
			_ok("mass: what came in less what went out is what it holds",
					absf(w.came_in - w.went_out - w.dried - held) < maxf(0.5, held * 0.005),
					"in %.1f, out %.1f, dried %.2f, held %.1f" % [w.came_in, w.went_out, w.dried, held])
			# The water outside lowered under the hole.
			_level = _hole_y - 1.0
			_t = 0.0
			_stage = 4
			got = got
		4:
			_t += delta
			if _t < DRAIN:
				return false
			var w := _st.hull_water
			var top := -INF
			for i: int in w.wet:
				if w.level(i) > 0.5:
					top = maxf(top, _cell_y(i))
			_ok("drains: the water lowered under the hole, it runs back out of it",
					w.went_out > 20.0 and top < _hole_y + 0.4,
					"%.0f cells out, its top now %.2f (the hole at %.2f)" % [w.went_out, top, _hole_y])
			_finish()
			return true
	return false


func _cell_y(i: int) -> float:
	var c := _st.air._cell(i)
	return (_st.global_transform * _st.cell_point(c)).y


## Every wet cell an inside cell or an open doorway.
func _inside_check(when: String) -> void:
	var w := _st.hull_water
	var bad := 0
	for i: int in w.wet:
		if w.fill_at(i) > HullWater.DRY and not w.passable(i):
			bad += 1
	_ok("inside: water only in inside cells and open doorways (%s)" % when, bad == 0, "%d cell(s) not" % bad)


func _wet_beyond_door() -> float:
	var w := _st.hull_water
	var t := 0.0
	for i: int in w.wet:
		if _st.air.state[i] == HullAir.INSIDE and _st.air._root(_st.air.comp[i]) != _st.air._root(_room):
			t += w.fill_at(i)
	# Merged through the open door: the next room is the same compartment now.
	if t == 0.0 and _next_room >= 0:
		t = w.in_compartment(_next_room) - 0.0
	return t


## A hull brick low on a big room, beside the outside; the water a metre over it;
## a door out of that room to another.
func _hole() -> bool:
	var air := _st.air
	var best := -1
	var best_y := INF
	for b in _st.bricks.get_block_count(_st.chunk):
		var ins := {}
		var out := false
		var cells := air._block_cells(b)
		for i in cells:
			for j in air._neighbours(i):
				if air.state[j] == HullAir.INSIDE:
					ins[air._root(air.comp[j])] = true
				elif air.state[j] == HullAir.OUTSIDE:
					out = true
		if out and ins.size() == 1 and air._cells[air._root(ins.keys()[0])] > 400 and not cells.is_empty():
			var y := _cell_y(cells[0])
			if y < best_y - 0.01:
				# Not the floor: a side wall, a room's air beside it above the floor.
				best_y = y
				best = b
				_room = ins.keys()[0]
	if best < 0:
		_ok("a hull brick low on a room", false)
		return false
	# Its lowest door to another room (one the water will reach).
	var low := INF
	for di in air.doors.size():
		if bool(air.doors[di].outside):
			continue
		var rs: Array = air._door_rooms(air.doors[di])
		if rs.size() >= 2 and rs.has(air._root(_room)):
			var dy := INF
			for i: int in air.doors[di].cells:
				dy = minf(dy, _cell_y(i))
			if dy < low:
				low = dy
				_door = di
				_next_room = rs[0] if rs[1] == air._root(_room) else rs[1]
	var hole := PackedInt32Array([best])
	_st.bricks.kill_blocks(_st.chunk, hole)
	_st._after_kill(hole)
	_hole_y = best_y
	_level = best_y + 1.0
	_ok("a hole low in its hull, its room breached", air.is_breached(_room),
			"the hole at %.2f m, the water at %.2f, a door to another room %s" % [_hole_y, _level, str(_door >= 0)])
	return true


## The water's mesh as the script built it before HullFlow.mesh (C++) did
## (SpaceStation._draw_water, to 2026-11-11): what the C++ is held to.
func _mesh_ref(hw: HullWater) -> Array:
	var stud := BrickWorld.get_stud_metres()
	var plate := BrickWorld.get_plate_metres()
	var v := PackedVector3Array()
	var nrm := PackedVector3Array()
	var col := PackedColorArray()
	var dims := hw.air.dims
	var sy := dims.x
	# Cells beside a hole the sea comes in at: the most foam.
	# (HullWater.inflow: the holes water came in at, its last step.)
	var inflow := {}
	for b: int in hw.inflow:
		for j in hw.air._neighbours(b):
			inflow[j] = true
	for i: int in hw.wet:
		var w := hw.level(i)
		if w < 0.02:
			continue
		var c := hw.air._cell(i)
		var x0 := c.x * stud
		var z0 := c.z * stud
		var y0 := c.y * plate
		var y1 := y0 + w * plate
		var above := i + sy
		if c.y + 1 >= dims.y or hw.level(above) < 0.02:
			var walls := 0
			for o in [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]:
				var nc: Vector3i = c + o
				if not hw.air._in(nc) or not hw.passable(hw.air._idx(nc)):
					walls += 1
			var f := 1.0 if inflow.has(i) else (0.75 if walls > 0 else 0.0)
			v.append_array([Vector3(x0, y1, z0), Vector3(x0 + stud, y1, z0), Vector3(x0 + stud, y1, z0 + stud),
					Vector3(x0, y1, z0), Vector3(x0 + stud, y1, z0 + stud), Vector3(x0, y1, z0 + stud)])
			for k in 6:
				nrm.append(Vector3.UP)
				col.append(Color(f, 0.0, 0.0))
		for e: Array in [[Vector3i(1, 0, 0), x0 + stud, true], [Vector3i(-1, 0, 0), x0, true],
				[Vector3i(0, 0, 1), z0 + stud, false], [Vector3i(0, 0, -1), z0, false]]:
			var nc: Vector3i = c + (e[0] as Vector3i)
			if not hw.air._in(nc):
				continue
			var ni := hw.air._idx(nc)
			if not hw.passable(ni) or hw.level(ni) >= w - 0.02:
				continue
			var at: float = e[1]
			if bool(e[2]):
				v.append_array([Vector3(at, y0, z0), Vector3(at, y1, z0), Vector3(at, y1, z0 + stud),
						Vector3(at, y0, z0), Vector3(at, y1, z0 + stud), Vector3(at, y0, z0 + stud)])
			else:
				v.append_array([Vector3(x0, y0, at), Vector3(x0, y1, at), Vector3(x0 + stud, y1, at),
						Vector3(x0, y0, at), Vector3(x0 + stud, y1, at), Vector3(x0 + stud, y0, at)])
			# The lip foams at its top, clear below.
			var out := Vector3(e[0] as Vector3i)
			for f in [0.2, 0.8, 0.8, 0.2, 0.8, 0.2]:
				nrm.append(out)
				col.append(Color(f, 0.0, 0.0))
	return [v, nrm, col]


## HullFlow.mesh against the script it replaced, and what each costs.
func _mesh_check(w: HullWater, what: String) -> void:
	var inflow := PackedInt32Array()
	for b: int in w.inflow:
		inflow.append_array(w.air._neighbours(b))
	var t0 := Time.get_ticks_usec()
	var ref := _mesh_ref(w)
	var t1 := Time.get_ticks_usec()
	var got: Array = w.flow.mesh(BrickWorld.get_stud_metres(), BrickWorld.get_plate_metres(), inflow)
	var t2 := Time.get_ticks_usec()
	var gv: PackedVector3Array = got[0]
	var rv: PackedVector3Array = ref[0]
	var same := gv.size() == rv.size() and gv.size() > 0
	var worst := 0.0
	if same:
		for k in gv.size():
			worst = maxf(worst, gv[k].distance_to(rv[k]))
			worst = maxf(worst, (got[1][k] as Vector3).distance_to(ref[1][k]))
			worst = maxf(worst, absf((got[2][k] as Color).r - (ref[2][k] as Color).r))
	_ok("mesh: the water meshed in C++ is the script's, vertex for vertex (%s)" % what,
			same and worst < 1e-4, "%d vertices against %d, worst %.6f off; C++ %.2f ms, the script %.2f ms" % [
			gv.size(), rv.size(), worst, (t2 - t1) / 1000.0, (t1 - t0) / 1000.0])
