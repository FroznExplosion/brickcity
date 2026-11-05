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

const WATER := 1000.0
const G := 9.8
## A cubic metre of brick weighs this much: hollow ABS, about a third solid.
const HULL_DENSITY := 350.0
const COLUMN := 2
## Water's drag on a wet column's motion, per second (a share of its own mass),
## and on the whole boat's turning.
const DRAG := 0.8
const ANG_DRAG := 1.5

var vel := Vector3.ZERO
var ang := Vector3.ZERO
var mass := 1.0
var com := Vector3.ZERO          ## its own frame
var inertia := Vector3.ONE       ## its own frame's axes, about com
## Each column under it: [bottom (its frame), envelope height (m), area (m^2)].
var columns: Array = []
## The sea's clock, seconds: what the wave function is evaluated at.
var wave_t := 0.0
## Where the sea is when calm: the wave function's datum.
var sea := 0.0
var afloat := true
var last_submerged := 0.0


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
	parent.add_child(b)
	b.setup(d)
	b.global_transform = at
	b.prepare()
	b.activate()
	b.sea = BrickWave.get_sea_level()
	return b


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
	wave_t += delta
	_float(delta)


## Its mass, centre and inertia from its bricks, and its columns from its hull's
## envelope (solid cells and inside air), once.
func _measure() -> void:
	var stud := BrickWorld.get_stud_metres()
	var plate := BrickWorld.get_plate_metres()
	var cell_v := stud * stud * plate
	var n := 0
	var sum := Vector3.ZERO
	var pts: Array[Vector3] = []
	var groups := {}
	for x in air.dims.x:
		for z in air.dims.z:
			var lo := -1
			var cells := 0
			for y in air.dims.y:
				var i := air._idx(Vector3i(x, y, z))
				var st := air.state[i]
				if st == HullAir.SOLID:
					var p := cell_point(Vector3i(x, y, z)) + frame.basis * Vector3(0, plate * 0.5, 0)
					sum += p
					pts.append(p)
					n += 1
				if st == HullAir.SOLID or st == HullAir.INSIDE:
					cells += 1
					if lo < 0:
						lo = y
			if cells == 0:
				continue
			@warning_ignore("integer_division")
			var key := Vector2i(x / COLUMN, z / COLUMN)
			var g: Array = groups.get(key, [0.0, 0, Vector3.ZERO, 0])
			g[0] = float(g[0]) + cells * plate * stud * stud
			g[1] = int(g[1]) + 1
			g[2] = (g[2] as Vector3) + cell_point(Vector3i(x, lo, z))
			g[3] = maxi(int(g[3]), cells)
			groups[key] = g
	mass = maxf(1.0, n * cell_v * HULL_DENSITY)
	com = sum / maxf(1.0, float(n))
	var ixx := 0.0
	var iyy := 0.0
	var izz := 0.0
	var m1 := cell_v * HULL_DENSITY
	var inv := frame.basis.inverse()
	for p in pts:
		var r := inv * (p - com)
		ixx += m1 * (r.y * r.y + r.z * r.z)
		iyy += m1 * (r.x * r.x + r.z * r.z)
		izz += m1 * (r.x * r.x + r.y * r.y)
	inertia = Vector3(maxf(ixx, 1.0), maxf(iyy, 1.0), maxf(izz, 1.0))
	columns.clear()
	for key in groups:
		var g: Array = groups[key]
		var area := float(g[1]) * stud * stud
		columns.append([(g[2] as Vector3) / float(g[1]), float(g[0]) / area, area])


## Where its keel would ride on a calm sea, metres under the surface: its mass's
## worth of water over the area its columns float on.
func calm_draft() -> float:
	var area := 0.0
	for c in columns:
		area += float(c[2])
	return mass / (WATER * maxf(area, 0.01))


## One tick afloat: the swell's lift at each column, gravity at its centre, the
## water's drag; its motion integrated (semi-implicit), its transform set.
func _float(dt: float) -> void:
	var xf := global_transform
	var up := xf.basis.y.normalized()
	var at := PackedVector2Array()
	var bottoms: Array[Vector3] = []
	for c in columns:
		var p: Vector3 = xf * (c[0] as Vector3)
		bottoms.append(p)
		at.append(Vector2(p.x, p.z))
	var waves := BrickWave.sample_heights(at, wave_t)
	var c_w := xf * com
	var force := Vector3(0.0, -mass * G, 0.0)
	var torque := Vector3.ZERO
	var sub_total := 0.0
	for k in columns.size():
		var c: Array = columns[k]
		var p := bottoms[k]
		# The surface's height there (absolute: the sea level and the wave). NaN at a
		# wave gain of exactly 0 (BrickWave's): the calm sea.
		var h := waves[k] if waves.size() > k and not is_nan(waves[k]) else sea
		var depth := (h - p.y) / maxf(up.y, 0.3)
		var sub := clampf(depth, 0.0, float(c[1]))
		if sub <= 0.0:
			continue
		sub_total += sub * float(c[2])
		var at_p := p + up * sub * 0.5
		var lift := Vector3(0.0, WATER * G * float(c[2]) * sub, 0.0)
		var r := at_p - c_w
		var v_p := vel + ang.cross(r)
		# A wet column's drag: its share of the boat's mass, damped at DRAG.
		var share := mass * float(c[2]) * sub / maxf(1.0, _wet_ref())
		var drag := -v_p * share * DRAG
		force += lift + drag
		torque += r.cross(lift + drag)
	last_submerged = sub_total
	afloat = sub_total > 0.0
	vel += force / mass * dt
	# Angular: in its own axes, its inertia's diagonal.
	var b := xf.basis.orthonormalized()
	var t_l := b.inverse() * torque
	var a_l := Vector3(t_l.x / inertia.x, t_l.y / inertia.y, t_l.z / inertia.z)
	if afloat:
		ang *= exp(-ANG_DRAG * dt)
	ang += b * a_l * dt
	var origin := c_w + vel * dt
	var nb := b
	if ang.length_squared() > 1e-12:
		nb = (Basis(ang.normalized(), ang.length() * dt) * b).orthonormalized()
	# Turned about its centre, not its node's origin.
	var com_off := nb * com
	global_transform = Transform3D(nb, origin - (com_off - Vector3.ZERO))


## The submerged volume its drag is measured against: its calm draft's.
func _wet_ref() -> float:
	var area := 0.0
	for c in columns:
		area += float(c[2])
	return area * calm_draft()
