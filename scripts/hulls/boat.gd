class_name Boat
extends SpaceStation
## A boat (Docs/Hulls.md 7, step 7): a generated ship's bricks, air and ghost
## (SpaceStation, laid from BoatBuild), floated by buoyancy on the sea's one wave
## function (BrickWave.sample_heights, Docs/Water.md 1) -- no Jolt body: its own
## rigid motion, integrated here a physics tick at a time.
##
## What floats it, column by column under its keel (COLUMN studs square): the
## part of the column's hull below the surface there -- its bricks and its dry
## INSIDE air (HullAir), the envelope of the hull -- times the water's weight,
## pushed up at the column's middle. What sinks it: its bricks' mass
## (HULL_DENSITY a cubic metre of brick) at their centre. So it rides at the
## waterline its weight asks for, level when its weight is even, and rocks and
## pitches on the swell. Flooding (Hulls.md 5) will take INSIDE cells out of the
## envelope and add their water's weight; nothing floods yet.
##
## Always `riding` once afloat: its bricks drawn on it, their collision its ghost's
## (Hulls.md 7b), whoever stands on its deck walking that, its down the world's
## turned into its frame (`ghost_up`) -- so the crew feel it roll.

const WATER := HullFloat.WATER
const G := HullFloat.G
const HULL_DENSITY := HullFloat.HULL_DENSITY
const SOLID_DISPLACE := HullFloat.SOLID_DISPLACE
const COLUMN := HullFloat.COLUMN
const DRAG := HullFloat.DRAG
const ANG_DRAG := HullFloat.ANG_DRAG
## Air out of a trapped pocket at its seams, cells a second (HullWater.air_leak):
## INF, none held. Measured (boat_probe, 2026-11-07): at 40 a holed hold took 90 s
## and did not sink; at 150 it sank in 28 s but no longer listed toward the hole in
## its first 15 s (27 t aboard against 61 t). A boat that keeps afloat on a pocket
## is a design call; the airtight hulls (spaceships, stations) hold theirs.
const SEAM_LEAK := INF

var vel := Vector3.ZERO
var ang := Vector3.ZERO
var mass := 1.0
var com := Vector3.ZERO          ## its own frame
var inertia := Vector3.ONE       ## its own frame's axes, about com
## Each column under it: [bottom (its frame), envelope height (m), area (m^2)].
var columns: Array = []
## Each column's water cells (HullAir indices: its non-brick cells): what the water
## in it weighs, pressing down there.
var column_cells: Array = []
## The sea's clock, seconds: what the wave function is evaluated at. With
## `wave_clock` (the drawn sea's, WaterSurface._time) it rides the waves you see.
var wave_t := 0.0
var wave_clock := Callable()
## Where the sea is when calm: the wave function's datum.
var sea := 0.0
var afloat := true
var last_submerged := 0.0
## Water aboard, kg, last tick.
var water_mass := 0.0
var _cell_v := 0.0
## Its sums (HullFloat.measure): what the fields above are read from, and what
## works out its forces.
var floats: HullFloat
## A tick afloat on the main thread, microseconds: smoothed, and the worst.
var float_us := 0.0
var float_us_max := 0.0
## Its forces worked out on a worker (Docs/Hulls.md 11 E6): after each tick's motion
## the next tick's forces start on the WorkerThreadPool from where it now is; the
## next tick takes them if done (never waited on), else the last ones again.
var threaded := true
## The forces' job and the snapshot it fills; the forces in use.
var _job := -1
var _snap := {}
var _have := {}
## Ticks that took the last forces again (the job not done), and the job's own time.
var late_ticks := 0
var work_us := 0.0


## A boat of seed `sd` at `at`, its ghost in `ghost_hulls` (a GhostHulls).
static func launch(parent: Node, sd: int, at: Transform3D, ghost_hulls) -> Boat:
	var d := OrbitalData.new()
	d.kind = "boat"
	d.layout = "generated"
	d.orbital_name = "boat %d" % sd
	d.orbital_seed = sd
	d.gravity_on = false
	var b := Boat.new()
	b.ghosts = ghost_hulls
	# A brick hull is not airtight: the air a hole under the water would trap goes
	# out at its seams (Docs/Hulls.md 5.2), so a holed hold floods, lists and sinks.
	b.air_leak = SEAM_LEAK
	# On a world's sea, in its air: a hole lets no air out, nothing is pulled to it
	# (Docs/Hulls.md 4.1; a PlanetSystem sets its ships', nothing set a boat's).
	b.outside_pressure = 1.0
	parent.add_child(b)
	b.setup(d)
	b.global_transform = at
	b.prepare()
	b.activate()
	b.sea = BrickWave.get_sea_level()
	# Its holes flood from its sea (Docs/Hulls.md 5).
	b.water_depth = b._sea_depth
	b.drifted.connect(b._on_piece)
	return b


## Nothing is its ground: what is cut off from its largest part leaves it.
func floats_free() -> bool:
	return true


## Every part not joined to its largest leaves: a boat has no furniture.
func part_min() -> int:
	return 0


## Part of it left: its air from the bricks it has now (the hold that went, and a
## stretch cut open, are the sea's), its water kept where there is still a room
## for it, and what floats it measured again.
func _parted(_killed: PackedInt32Array) -> void:
	air.rebuild(bricks, chunk)
	if hull_water != null:
		hull_water.grid_rebuilt()
	if not columns.is_empty():
		_measure()
		_have = {}


## Bricks laid back (the restore tool): what floats it is measured again, soon --
## not a brick at a time, the tool lays eight a second.
func _after_restore(back: PackedInt32Array) -> void:
	super(back)
	_measure_in = MEASURE_AFTER


const MEASURE_AFTER := 0.5
var _measure_in := -1.0


## The parts that have left it and are still afloat or sinking (HullPiece).
var pieces: Array = []


## A part of it sent off (`drifted`): a piece floating by what it is itself.
func _on_piece(arrays: Array, at: Transform3D, local_com: Vector3, count: int, material: Material) -> void:
	if drift_chunk < 0 or not is_inside_tree():
		return
	var p := HullPiece.make(self, drift_chunk, arrays, at, local_com, count, material)
	get_parent().add_child(p)
	p.global_transform = at
	pieces = pieces.filter(func(q) -> bool: return is_instance_valid(q))
	pieces.append(p)


## How far world point `p` is under its sea's surface (the wave there), metres.
func _sea_depth(p: Vector3) -> float:
	var h := BrickWave.sample_heights(PackedVector2Array([Vector2(p.x, p.z)]), wave_t)
	var y: float = h[0] if h.size() > 0 and not is_nan(h[0]) else sea
	return y - p.y


## Its water's down: the world's, turned into its frame (it rolls; the water runs
## to the low side).
func water_down() -> Vector3:
	var b := (global_transform * frame).basis.orthonormalized()
	return (b.inverse() * Vector3.DOWN).normalized()


## The world's up, in its ghost's frame: the crew stand up from the sea, not from
## the deck, and feel it roll.
func ghost_up() -> Vector3:
	return (global_transform.basis.inverse() * Vector3.UP).normalized()


func ghost_pulls() -> bool:
	return true


func _physics_process(delta: float) -> void:
	if chunk < 0 or not bricked or air == null:
		return
	if columns.is_empty():
		_measure()
	if not riding:
		ride()
	if _measure_in >= 0.0:
		_measure_in -= delta
		if _measure_in < 0.0:
			_measure()
			_have = {}
	wave_t = float(wave_clock.call()) if wave_clock.is_valid() else wave_t + delta
	var t0 := Time.get_ticks_usec()
	if threaded:
		_float_threaded(delta)
	else:
		_float(delta)
	# What a tick afloat costs (Docs/Hulls.md 11 E6: is a thread worth it?).
	var us := float(Time.get_ticks_usec() - t0)
	float_us_max = maxf(float_us_max, us)
	float_us = us if float_us <= 0.0 else lerpf(float_us, us, 0.05)


## Its mass, centre and inertia from its bricks, and its columns from its hull's
## envelope (solid cells and inside air): HullFloat's sums of its air grid as it
## is now. Once, and again when part of it has left (`_parted`).
func _measure() -> void:
	floats = HullFloat.measure(air.dims, air.state, frame)
	mass = floats.mass
	com = floats.com
	inertia = floats.inertia
	columns = floats.columns
	column_cells = floats.column_cells
	_cell_v = floats.cell_v
	_cw_step = -1


## Where its keel would ride on a calm sea, metres under the surface.
func calm_draft() -> float:
	return floats.calm_draft() if floats != null else 0.0


## One tick afloat: the swell's lift at each column, gravity at its centre, the
## water's drag; its motion integrated (semi-implicit), its transform set. All on
## this thread.
func _float(dt: float) -> void:
	var sn := _snapshot(wave_t)
	floats.forces(sn)
	_integrate(dt, sn)


## A tick afloat with its forces from the worker (E6): the job started at the end
## of the last tick, from where the boat then was -- so, done in time, the same
## forces `_float` would work out now. Not done: the last ones once more. Moved by
## anything else since (a launch, a probe): worked out here instead.
func _float_threaded(dt: float) -> void:
	if _job >= 0 and WorkerThreadPool.is_task_completed(_job):
		WorkerThreadPool.wait_for_task_completion(_job)
		_job = -1
		_have = _snap
		work_us = float(_have.get("us", 0.0))
	elif _job >= 0:
		late_ticks += 1
	if _have.is_empty() or not (_have.xf as Transform3D).is_equal_approx(global_transform):
		if _job < 0 or _have.is_empty():
			_have = _snapshot(wave_t)
			floats.forces(_have)
	_integrate(dt, _have)
	if _job < 0:
		_snap = _snapshot(wave_t + dt)
		# The sums it was started with: a boat that parts measures anew, and a job
		# still running keeps the ones it has.
		_job = WorkerThreadPool.add_task(floats.forces.bind(_snap), true, "boat float")


func _exit_tree() -> void:
	# Its job reads this boat: let it finish before the boat goes (teardown, not play).
	if _job >= 0:
		WorkerThreadPool.wait_for_task_completion(_job)
		_job = -1


## Where it is and how it moves, for `_forces`: everything that reads the scene
## tree or the water is read here, on the main thread.
func _snapshot(t: float) -> Dictionary:
	var water := PackedFloat32Array()
	if hull_water != null and hull_water.any():
		_column_water(0)
		water = _cw.duplicate()
	return {"xf": global_transform, "vel": vel, "ang": ang, "t": t, "sea": sea, "water": water}


## The forces on it at snapshot `sn` (HullFloat.forces), here: the probe's check
## of the worker's against this thread's.
func _forces(sn: Dictionary) -> void:
	floats.forces(sn)


## Its motion one tick on under forces `f` (a `forces` snapshot's).
func _integrate(dt: float, f: Dictionary) -> void:
	last_submerged = float(f.sub)
	water_mass = float(f.aboard)
	afloat = last_submerged > 0.0
	var next := floats.integrate(dt, f, global_transform, vel, ang)
	global_transform = next[0]
	vel = next[1]
	ang = next[2]


var _cw := PackedFloat32Array()
var _cw_step := -1


## The water in column `k`, cells' worth -- summed again only when the water has
## moved (HullWater.steps).
func _column_water(k: int) -> float:
	if _cw_step != hull_water.steps or _cw.size() != columns.size():
		_cw_step = hull_water.steps
		_cw.resize(columns.size())
		for c in columns.size():
			var t := 0.0
			for i: int in column_cells[c]:
				t += hull_water.level(i)
			_cw[c] = t
	return _cw[k]
