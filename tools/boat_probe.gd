extends SceneTree
## A boat (Docs/Hulls.md 7, step 7): BoatBuild's hull laid as a ship is, floated by
## buoyancy on the sea's wave function (Boat), its crew on its ghost.
##
##     godot --headless --path . --script res://tools/boat_probe.gd
##
##   built     laid in bricks, its hold sealed air, its mass under what its hull
##             displaces
##   level     dropped onto a calm sea: CALM seconds later level (under a degree),
##             at rest, its keel at the draft its weight asks for
##   crew      a pawn on its deck taken onto its ghost by the crossing every pawn uses
##   swell     the waves on for SWELL seconds: it rolls and pitches, stays afloat,
##             the crew standing on its deck all the while

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
			_finish()
			return true
	return false
