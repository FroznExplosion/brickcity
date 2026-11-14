extends SceneTree
## A boat broken in two (Docs/Hulls.md 7.4): afloat nothing is its ground, so what
## is cut off from its largest part leaves it as a piece that floats or sinks by
## what it is itself (HullPiece), and the boat goes on floating on what it has left.
##
##     godot --headless --path . --script res://tools/probes/boat_break_probe.gd
##
##   built     whole, its bricks are one joined part: no column of the rim stands
##             clicked to nothing beside it
##   parts     cut clean across between two bulkheads: the smaller part leaves as a
##             piece, the boat's bricks are one joined part again
##   air       the boat's air is what it still shuts in: the stretch cut open and
##             the hold that left are the sea's, its whole stretches are rooms
##   floats    WAIT seconds on: the boat afloat on less, its deck over the water
##   piece     the part that left has a whole stretch of hold in it: it floats
##   sinks     a second cut takes an open end off: that piece shuts no air in, and
##             goes down and is gone
##
## The cuts kill a slab of bricks outright (BrickWorld.kill_blocks, then the hull's
## own _after_kill, as a hit's): what is tested is what follows a cut, not a blast.

const SETTLE := 8.0
const WAIT := 20.0
const SINK := 40.0

var _pass := 0
var _fail := 0
var _boat: Boat
var _stage := 0
var _frames := 0
var _t := 0.0
var _gain := 1.0
var _mass0 := 0.0
var _rooms0 := 0
var _bow: HullPiece
var _open: HullPiece
var _open_bricks := 0
var _open_buoyant := true
var _open_low := 0.0


func _ok(what: String, cond: bool, detail := "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _finish() -> void:
	BrickWave.set_wave_gain(_gain)
	if _boat != null:
		for p in _boat.pieces:
			if is_instance_valid(p):
				p.queue_free()
		_boat.deactivate()
		_boat.queue_free()
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


## Its rooms of a stretch's size (a void in a wall is not one).
func _rooms() -> int:
	var n := 0
	for comp in _boat.air.compartments():
		if int(comp.cells) >= 100:
			n += 1
	return n


## Every brick with a cell in rows `lo`..`hi` (chunk cells, along its length) gone.
func _cut(lo: int, hi: int) -> int:
	var ids := PackedInt32Array()
	var x0: int = _boat.recipe.origin().x
	var gone := {}
	for b in _boat.gone():
		gone[b] = true
	for b in _boat.bricks.get_block_count(_boat.chunk):
		var ri := _boat.air._block_recipe[b]
		var c: Vector3i = _boat.recipe.cell_of(ri)
		var sz := BuildRecipe.part_size(_boat.recipe.part_of(ri))
		if c.x - x0 + sz.x > lo and c.x - x0 <= hi and not gone.has(b):
			ids.append(b)
	_boat.bricks.kill_blocks(_boat.chunk, ids)
	_boat._after_kill(ids)
	return ids.size()


func _deck_over() -> float:
	var deck_y: int = int(_boat.recipe.meta.boat.deck_y) - _boat.recipe.origin().y
	var p := _boat.global_transform * _boat.cell_point(Vector3i(_boat.seat_cell.x, deck_y, _boat.seat_cell.z))
	return p.y - _boat.sea


## Inside-air cells in rows `lo` and up: none where the hull has gone.
func _air_past(lo: int) -> int:
	var n := 0
	var a := _boat.air
	for i in a.state.size():
		if a.state[i] == HullAir.INSIDE and a._cell(i).x >= lo:
			n += 1
	return n


func _physics_process(delta: float) -> bool:
	_frames += 1
	match _stage:
		0:
			print("boat break probe")
			_gain = 1.0
			BrickWave.set_wave_gain(0.0001)
			_boat = Boat.launch(root, 1, Transform3D(Basis(), Vector3(0, BrickWave.get_sea_level() + 0.4, 0)),
					GhostHulls.new())
			_stage = 1
		1:
			if not _boat.bricked or _boat.columns.is_empty():
				if _frames > 1800:
					_ok("its bricks laid", false)
					_finish()
					return true
				return false
			_t += delta
			if _t < SETTLE:
				return false
			_mass0 = _boat.mass
			_rooms0 = _rooms()
			var whole: Array = _boat.bricks.get_components(_boat.chunk)
			_ok("built: every brick of it clicked to the rest (one joined part)", whole.size() == 1,
					"%d part(s): %s" % [whole.size(), str(whole.map(func(g) -> int: return g.size()).slice(0, 12))])
			# Between its second and third bulkheads (rows 20 and 30).
			var walls: Array = _boat.recipe.meta.boat.bulkheads
			var x0: int = _boat.recipe.origin().x
			@warning_ignore("integer_division")
			var mid: int = (int(walls[1]) + int(walls[2])) / 2 - x0
			var cut := _cut(mid - 1, mid + 1)
			print("  (cut %d bricks out across rows %d-%d)" % [cut, mid - 1, mid + 1])
			_cut_at = mid
			_t = 0.0
			_stage = 2
		2:
			# The solve, a tick or two on.
			_t += delta
			if _t < 1.0:
				return false
			var comps: Array = _boat.bricks.get_components(_boat.chunk)
			var live: Array = _boat.pieces.filter(func(q) -> bool: return is_instance_valid(q))
			_bow = live[0] if live.size() > 0 else null
			_ok("parts: cut across, the smaller part leaves as a piece and the boat is one part again",
					live.size() == 1 and comps.size() == 1 and _bow.bricks > 100,
					"%d piece(s), %d bricks in it; the boat %d part(s), %d bricks" % [live.size(),
					_bow.bricks if _bow != null else 0, comps.size(), _boat.bricks.get_alive_block_count(_boat.chunk)])
			var past := _air_past(_cut_at - 1)
			_ok("air: the stretch cut open and the hold that left are the sea's, its whole stretches still rooms",
					_rooms() == _rooms0 - 2 and past == 0 and _boat.mass < _mass0 * 0.9,
					"%d room(s) from %d, %d cell(s) of inside air past the cut, %.0f kg from %.0f" % [
					_rooms(), _rooms0, past, _boat.mass, _mass0])
			if _bow == null:
				_finish()
				return true
			_t = 0.0
			_stage = 3
		3:
			_t += delta
			if _t < WAIT:
				return false
			_ok("floats: the boat afloat on what it has left, its deck over the water",
					_boat.last_submerged > 0.0 and _deck_over() > 0.1 and _boat.vel.length() < 0.2,
					"the deck %.2f m over, %.3f m/s, %.1f m3 under" % [_deck_over(), _boat.vel.length(),
					_boat.last_submerged])
			var ok_bow := is_instance_valid(_bow)
			_ok("piece: the part that left has a whole stretch of hold in it, and floats",
					ok_bow and _bow.buoyant() and _bow.last_submerged > 0.0
					and absf(_bow.global_position.y - _boat.sea) < 2.0 and _bow.vel.length() < 0.3,
					("keeps out %.1f m3 for %.0f kg, its middle %.2f m from the sea's level, %.3f m/s" % [
					_bow.floats.displaces(), _bow.floats.mass, _bow.global_position.y - _boat.sea,
					_bow.vel.length()]) if ok_bow else "gone")
			# Its stern's open end off: rows 4-6, short of its first bulkhead.
			var cut := _cut(4, 6)
			print("  (cut %d bricks out across rows 4-6)" % cut)
			_t = 0.0
			_stage = 4
		4:
			_t += delta
			if _open == null:
				for q in _boat.pieces:
					if is_instance_valid(q) and q != _bow:
						_open = q
						_open_bricks = q.bricks
						_open_buoyant = q.buoyant()
				if _open == null and _t < 2.0:
					return false
			if _open != null and is_instance_valid(_open):
				_open_low = maxf(_open_low, _boat.sea - _open.global_position.y)
				if _t < SINK:
					return false
			_ok("sinks: an open end cut off shuts no air in, goes down and is gone",
					_open_bricks > 20 and not _open_buoyant and not is_instance_valid(_open)
					and _open_low > HullPiece.SUNK * 0.9,
					"%d bricks, %.1f m under at the last, gone after %.0f s" % [_open_bricks, _open_low, _t])
			_finish()
			return true
	return false


var _cut_at := 0
