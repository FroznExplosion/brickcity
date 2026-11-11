extends SceneTree
## A boat (Docs/Hulls.md 7, step 7): BoatBuild's hull laid as a ship is, floated by
## buoyancy on the sea's wave function (Boat), its crew on its ghost.
##
##     godot --headless --path . --script res://tools/probes/boat_probe.gd
##
##   built     laid in bricks, its hold sealed air, its mass under what its hull
##             displaces
##   level     dropped onto a calm sea: CALM seconds later level (under a degree),
##             at rest, its keel at the draft its weight asks for
##   crew      a pawn on its deck taken onto its ghost by the crossing every pawn uses
##   swell     the waves on for SWELL seconds: it rolls and pitches, stays afloat,
##             the crew standing on its deck all the while
##   lists     calm again, a hole shot low in one side under the waterline: the hold
##             floods (HullWater) and it lists toward the hole
##   sinks     left open, the flooded hull settles until its deck is under
##   rises     patched (SpaceStation.restore) and pumped out: it comes back up

const CALM := 20.0
const SWELL := 12.0

var _pass := 0
var _fail := 0
var _ghosts: GhostHulls
var _boat: Boat
var _crew: Pawn
var _stage := 0
var _frames := 0
var _t := 0.0
var _gain := 1.0
var _worst_tilt := 0.0
var _worst_off := 0
var _min_sub := INF


func _ok(what: String, cond: bool, detail := "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _finish() -> void:
	BrickWave.set_wave_gain(_gain)
	ShipRays.ships.clear()
	if _crew != null:
		_crew.body.queue_free()
	if _boat != null:
		_boat.deactivate()
		_boat.queue_free()
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _tilt() -> float:
	return rad_to_deg(_boat.global_basis.y.normalized().angle_to(Vector3.UP))


func _keel_depth() -> float:
	# How far its keel's bottom is under the calm sea, metres.
	var lo := INF
	for c in _boat.columns:
		lo = minf(lo, (_boat.global_transform * (c[0] as Vector3)).y)
	return _boat.sea - lo


func _physics_process(delta: float) -> bool:
	_frames += 1
	match _stage:
		0:
			print("boat probe")
			_gain = 1.0
			# Calm (a gain of exactly 0 samples NaN: BrickWave's).
			BrickWave.set_wave_gain(0.0001)
			_ghosts = GhostHulls.new()
			var sea := BrickWave.get_sea_level()
			_boat = Boat.launch(root, 1, Transform3D(Basis(Vector3.UP, 0.4), Vector3(0, sea + 1.0, 0)), _ghosts)
			_stage = 1
		1:
			if not _boat.bricked:
				if _frames > 1800:
					_ok("its bricks laid", false)
					_finish()
					return true
				return false
			if _boat.columns.is_empty():
				return false
			var held := 0.0
			for c in _boat.columns:
				held += float(c[1]) * float(c[2])
			var inside := 0
			for comp in _boat.air.compartments():
				inside += int(comp.cells)
			_ok("built: laid in bricks, its hold sealed air, lighter than the water its hull holds off",
					inside > 0 and _boat.mass < held * Boat.WATER,
					"%d bricks, %.0f kg, hull %.1f m3 (%d cells of hold air), calm draft %.2f m" % [
					_boat.bricks.get_alive_block_count(_boat.chunk), _boat.mass, held, inside, _boat.calm_draft()])
			ShipRays.ships.clear()
			ShipRays.ships.append(_boat)
			_t = 0.0
			_stage = 2
		2:
			_t += delta
			if _t < CALM:
				return false
			var draft := _keel_depth()
			var want := _boat.calm_draft()
			_ok("level: on a calm sea, level and at rest at the draft its weight asks for",
					_tilt() < 1.0 and _boat.vel.length() < 0.05 and absf(draft - want) < maxf(0.1 * want, 0.03),
					"tilt %.2f deg, %.3f m/s, keel %.3f m under (wants %.3f)" % [_tilt(), _boat.vel.length(), draft, want])
			# Crew on its deck, amidships.
			var at := _boat.global_transform * _boat.cell_point(_boat.seat_cell) + Vector3.UP * 0.1
			_crew = Pawn.spawn(root, at, 0)
			var ships: Array = [_boat]
			var on := GhostHulls.tick(_crew, ships, _boat.get_world_3d().space)
			_ok("crew: a pawn on its deck onto its ghost (the crossing every pawn uses)", on == 1 and _crew.ghost == _boat)
			BrickWave.set_wave_gain(1.0)
			_t = 0.0
			_stage = 3
		3:
			_t += delta
			_worst_tilt = maxf(_worst_tilt, _tilt())
			_min_sub = minf(_min_sub, _boat.last_submerged)
			if not _boat.holds(_crew.feet()) or _crew.ghost != _boat:
				_worst_off += 1
			GhostHulls.tick(_crew, [_boat], _boat.get_world_3d().space)
			if _t < SWELL:
				return false
			_ok("swell: it rolls and pitches, stays afloat, the crew on its deck all the while",
					_worst_tilt > 0.3 and _min_sub > 0.0 and _worst_off == 0 and _crew.is_on_floor(),
					"worst tilt %.1f deg, least submerged %.1f m3, %d frame(s) the crew was off it, on the floor %s" % [
					_worst_tilt, _min_sub, _worst_off, _crew.is_on_floor()])
			_worker_check()
			BrickWave.set_wave_gain(0.0001)
			_crew.body.queue_free()
			_crew = null
			_t = 0.0
			_stage = 4
		4:
			# Calm, then the hole.
			_t += delta
			if _t < 8.0:
				return false
			if not _shoot():
				_finish()
				return true
			_t = 0.0
			_stage = 5
		5:
			_t += delta
			if _t < LIST:
				return false
			var side := _boat.global_transform * _hole_local - _boat.global_transform * _boat.com
			_ok("lists: the hold floods through the hole and it lists toward it",
					_boat.water_mass > 100.0 and side.y < _hole_drop0 - 0.05 and _tilt() > 1.0,
					"%.0f kg of water aboard, tilt %.1f deg, the hole's side %.2f m lower" % [
					_boat.water_mass, _tilt(), _hole_drop0 - side.y])
			_t = 0.0
			_stage = 6
		6:
			_t += delta
			var deck_under := _deck_under()
			if deck_under < 0.0 and _t < SINK:
				return false
			_ok("sinks: left open, the flooded hull goes down until its deck is under",
					deck_under >= 0.0, "%.0f kg of water aboard, the deck %.2f m under after %.0f s" % [
					_boat.water_mass, deck_under, _t])
			# Patched, and pumped.
			var at: Vector3 = _boat.global_transform * _hole_local
			_boat.restore(_boat.restorable(at, 6.0), at, 6.0)
			_sunk = _keel_depth()
			_t = 0.0
			_stage = 7
		7:
			_t += delta
			_boat.pump(delta, PUMP)
			if _t < RISE:
				return false
			_ok("rises: patched and pumped out, it comes back up", _boat.gone().is_empty()
					and _keel_depth() < _sunk - 0.3 and _boat.water_mass < 0.25 * _peak_water,
					"keel %.2f m under from %.2f, %.0f kg of water left, %d brick(s) still gone" % [
					_keel_depth(), _sunk, _boat.water_mass, _boat.gone().size()])
			_finish()
			return true
	_peak_water = maxf(_peak_water, _boat.water_mass if _boat != null else 0.0)
	return false


const LIST := 15.0
const SINK := 90.0
const RISE := 40.0
## Its pumps, cells of water a second.
const PUMP := 300.0
var _hole_local := Vector3.ZERO
var _hole_drop0 := 0.0
var _sunk := 0.0
var _peak_water := 0.0


## How far its deck is under the calm sea (below 0: over it).
## Its forces on a worker (Docs/Hulls.md 11 E6): the same snapshot worked out on a
## worker and here gives the same forces, and the float's jobs were ready in time
## on nearly every tick so far.
func _worker_check() -> void:
	var a := _boat._snapshot(_boat.wave_t)
	var b := a.duplicate()
	_boat._forces(a)
	var job := WorkerThreadPool.add_task(_boat._forces.bind(b))
	WorkerThreadPool.wait_for_task_completion(job)
	var same := (a.force as Vector3).is_equal_approx(b.force) and (a.torque as Vector3).is_equal_approx(b.torque)
	_ok("worker: buoyancy worked out off the main thread, the same forces, ready in time",
			_boat.threaded and same and _boat.late_ticks <= _frames / 20,
			"%d of %d ticks late, the job %.2f ms, the main thread's part %.2f ms (worst %.2f)" % [
			_boat.late_ticks, _frames, _boat.work_us / 1000.0, _boat.float_us / 1000.0,
			_boat.float_us_max / 1000.0])


func _deck_under() -> float:
	var deck_y: int = int(_boat.recipe.meta.boat.deck_y) - _boat.recipe.origin().y
	var lo := INF
	for z in [_boat.seat_cell.z - 3, _boat.seat_cell.z, _boat.seat_cell.z + 3]:
		var p := _boat.global_transform * _boat.cell_point(Vector3i(_boat.seat_cell.x, deck_y, z))
		lo = minf(lo, p.y)
	return _boat.sea - lo


## A hole low in one side, under the waterline: a blast at a side brick a plate
## or two over the keel, amidships.
func _shoot() -> bool:
	var air := _boat.air
	var best := -1
	var best_y := INF
	var zmin := 1 << 30
	for b in _boat.bricks.get_block_count(_boat.chunk):
		var cells := air._block_cells(b)
		if cells.is_empty():
			continue
		var out := false
		var ins := false
		for i in cells:
			# Its grid has no margin: a cell on its edge is beside the outside.
			out = out or air._on_edge(i)
			for j in air._neighbours(i):
				out = out or air.state[j] == HullAir.OUTSIDE
				ins = ins or air.state[j] == HullAir.INSIDE
		if not (out and ins):
			continue
		var c := air._cell(cells[0])
		# Its port side (low z), amidships, the lowest such brick.
		if absi(c.x - _boat.seat_cell.x) > 4:
			continue
		if c.z < zmin or (c.z == zmin and c.y < best_y):
			zmin = c.z
			best_y = c.y
			best = b
	if best < 0:
		_ok("a side brick to shoot", false)
		return false
	var c := air._cell(air._block_cells(best)[0])
	_hole_local = _boat.cell_point(c)
	var at: Vector3 = _boat.global_transform * _hole_local
	_hole_drop0 = (at - _boat.global_transform * _boat.com).y
	var under := _boat.sea - at.y
	_boat.damage(at, {"blast": true, "radius": 0.9, "hp": 0})
	print("  (shot a hole %.2f m under the water, %d brick(s) gone)" % [under, _boat.gone().size()])
	return true
