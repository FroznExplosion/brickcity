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
## Of a brick cell's volume, the part that keeps water out once the hull floods:
## its plastic (the rest of a brick is hollow under it and fills). So a hull
## flooded through floats only by this, and sinks.
const SOLID_DISPLACE := 0.33
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
	# Its holes flood from its sea (Docs/Hulls.md 5).
	b.water_depth = b._sea_depth
	return b


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
	wave_t = float(wave_clock.call()) if wave_clock.is_valid() else wave_t + delta
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
	var cells_of := {}
	for x in air.dims.x:
		for z in air.dims.z:
			var lo := -1
			var cells := 0
			var disp := 0.0
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
					disp += SOLID_DISPLACE if st == HullAir.SOLID else 1.0
					if lo < 0:
						lo = y
			if cells == 0:
				continue
			@warning_ignore("integer_division")
			var key := Vector2i(x / COLUMN, z / COLUMN)
			var g: Array = groups.get(key, [0.0, 0, Vector3.ZERO, 0, 0.0, PackedFloat32Array(), 1 << 30])
			g[0] = float(g[0]) + cells * plate * stud * stud
			g[4] = float(g[4]) + disp * plate * stud * stud
			# Its displacement plate by plate: what each level of the column keeps out.
			var lv: PackedFloat32Array = g[5]
			if lv.is_empty():
				lv.resize(air.dims.y)
			for y in air.dims.y:
				var st2 := air.state[air._idx(Vector3i(x, y, z))]
				if st2 == HullAir.SOLID:
					lv[y] += SOLID_DISPLACE * cell_v
				elif st2 == HullAir.INSIDE:
					lv[y] += cell_v
			g[5] = lv
			g[6] = mini(int(g[6]), lo)
			g[1] = int(g[1]) + 1
			g[2] = (g[2] as Vector3) + cell_point(Vector3i(x, lo, z))
			g[3] = maxi(int(g[3]), cells)
			groups[key] = g
			var wet: PackedInt32Array = cells_of.get(key, PackedInt32Array())
			for y in air.dims.y:
				var ii := air._idx(Vector3i(x, y, z))
				if air.state[ii] != HullAir.SOLID:
					wet.append(ii)
			cells_of[key] = wet
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
	column_cells.clear()
	for key in groups:
		var g: Array = groups[key]
		var area := float(g[1]) * stud * stud
		# [bottom, envelope height, area, the share of it that keeps water out,
		#  the displacement under each level from its bottom (cumulative, m^3)].
		var lv: PackedFloat32Array = g[5]
		var lo_y: int = g[6]
		var cum := PackedFloat32Array([0.0])
		for y in range(lo_y, air.dims.y):
			cum.append(cum[-1] + lv[y])
		columns.append([(g[2] as Vector3) / float(g[1]), float(g[0]) / area, area,
				float(g[4]) / maxf(float(g[0]), 1e-6), cum])
		column_cells.append(cells_of.get(key, PackedInt32Array()))
	_cell_v = cell_v


## Where its keel would ride on a calm sea, metres under the surface: its mass's
## worth of water over the area its columns float on.
func calm_draft() -> float:
	var want := mass / WATER
	var lo := 0.0
	var hi := 0.0
	for c in columns:
		hi = maxf(hi, float(c[1]))
	for k in 40:
		var mid := (lo + hi) * 0.5
		var v := 0.0
		for c in columns:
			v += _kept_out(c, mid)
		if v < want:
			lo = mid
		else:
			hi = mid
	return (lo + hi) * 0.5


## What column `c` keeps out of the water `sub` metres up from its bottom, m^3.
func _kept_out(c: Array, sub: float) -> float:
	var cum: PackedFloat32Array = c[4]
	var k := sub / BrickWorld.get_plate_metres()
	var i := clampi(int(floor(k)), 0, cum.size() - 1)
	if i >= cum.size() - 1:
		return cum[-1]
	return lerpf(cum[i], cum[i + 1], k - float(i))


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
	var aboard := 0.0
	for k in columns.size():
		var c: Array = columns[k]
		var p := bottoms[k]
		# The water in this column weighs on it, where it is (Docs/Hulls.md 7: a
		# flooded side lists it, enough sinks it).
		if hull_water != null and hull_water.any():
			var wsum := _column_water(k)
			if wsum > 0.0:
				var wm := wsum * _cell_v * WATER
				aboard += wm
				var down := Vector3(0.0, -wm * G, 0.0)
				var rw := p + up * 0.5 - c_w
				force += down
				torque += rw.cross(down)
		# The surface's height there (absolute: the sea level and the wave). NaN at a
		# wave gain of exactly 0 (BrickWave's): the calm sea.
		var h := waves[k] if waves.size() > k and not is_nan(waves[k]) else sea
		var depth := (h - p.y) / maxf(up.y, 0.3)
		var sub := clampf(depth, 0.0, float(c[1]))
		if sub <= 0.0:
			continue
		sub_total += sub * float(c[2])
		var at_p := p + up * sub * 0.5
		var lift := Vector3(0.0, WATER * G * _kept_out(c, sub), 0.0)
		var r := at_p - c_w
		var v_p := vel + ang.cross(r)
		# A wet column's drag: its share of the boat's mass, damped at DRAG.
		var share := mass * float(c[2]) * sub / _wet_ref()
		var drag := -v_p * share * DRAG
		force += lift + drag
		torque += r.cross(lift + drag)
	last_submerged = sub_total
	water_mass = aboard
	afloat = sub_total > 0.0
	vel += force / (mass + aboard) * dt
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


## The submerged volume its drag is measured against: its calm draft's (worked
## out once: the draft is a search over every column).
var _wet_ref_v := -1.0


func _wet_ref() -> float:
	if _wet_ref_v < 0.0:
		var area := 0.0
		for c in columns:
			area += float(c[2])
		_wet_ref_v = maxf(1.0, area * calm_draft())
	return _wet_ref_v
