class_name HullFloat
extends RefCounted
## What floats a hull of bricks (Docs/Hulls.md 7): the sums a Boat and a piece
## broken off one (HullPiece) share. A hull is its grid of cells (HullAir's
## states: SOLID a brick, INSIDE dry enclosed air); it weighs its bricks and is
## lifted, column by column under it, by the part of each column's envelope
## under the sea there.
##
## Nothing here reads the scene tree: `forces` runs on a worker from a snapshot.

const WATER := 1000.0
const G := 9.8
## A cubic metre of brick weighs this much: hollow ABS, about a third solid.
const HULL_DENSITY := 350.0
## Of a brick cell's volume, the part that keeps water out once the hull floods:
## its plastic (the rest of a brick is hollow under it and fills).
const SOLID_DISPLACE := 0.33
## Studs square a column.
const COLUMN := 2
## Water's drag on a wet column's motion, per second (a share of its own mass),
## and on the whole hull's turning.
const DRAG := 0.8
const ANG_DRAG := 1.5

var mass := 1.0
var com := Vector3.ZERO          ## the hull's own frame
var inertia := Vector3.ONE       ## its frame's axes, about com
## Each column under it: [bottom (its frame), envelope height (m), area (m^2),
## the share of it that keeps water out, the displacement under each level from
## its bottom (cumulative, m^3)].
var columns: Array = []
## Each column's cells that are not brick (grid indices): where water aboard
## stands, weighing there.
var column_cells: Array = []
var cell_v := 0.0
## The submerged volume its drag is measured against: its calm draft's.
var wet_ref := 1.0
var _basis_inv := Basis()


## A hull's sums from its grid: `state` a HullAir state a cell (x + dims.x *
## (y + dims.y * z)), `frame` taking grid metres (a cell's bottom middle at
## ((x + 0.5) stud, y plate, (z + 0.5) stud)) to the hull's own space.
static func measure(dims: Vector3i, state: PackedByteArray, frame: Transform3D) -> HullFloat:
	var f := HullFloat.new()
	var stud := BrickWorld.get_stud_metres()
	var plate := BrickWorld.get_plate_metres()
	var cv := stud * stud * plate
	var n := 0
	var sum := Vector3.ZERO
	var pts: Array[Vector3] = []
	var groups := {}
	var cells_of := {}
	var half := frame.basis * Vector3(0, plate * 0.5, 0)
	for x in dims.x:
		for z in dims.z:
			var lo := -1
			var hi := -1
			var cells := 0
			var disp := 0.0
			for y in dims.y:
				var st := state[x + dims.x * (y + dims.y * z)]
				if st == HullAir.SOLID:
					var p := frame * Vector3((x + 0.5) * stud, y * plate, (z + 0.5) * stud) + half
					sum += p
					pts.append(p)
					n += 1
				if st == HullAir.SOLID or st == HullAir.INSIDE:
					cells += 1
					disp += SOLID_DISPLACE if st == HullAir.SOLID else 1.0
					hi = y
					if lo < 0:
						lo = y
			if cells == 0:
				continue
			# Its envelope from its lowest cell to its highest, gaps and all: a part
			# broken open has columns of keel and deck with the sea between, and by
			# their cells alone such a column was sunk to its keel's top and no
			# further -- its deck kept nothing out, and the piece fell like a stone.
			cells = hi - lo + 1
			@warning_ignore("integer_division")
			var key := Vector2i(x / COLUMN, z / COLUMN)
			var g: Array = groups.get(key, [0.0, 0, Vector3.ZERO, 0, 0.0, PackedFloat32Array(), 1 << 30])
			g[0] = float(g[0]) + cells * cv
			g[4] = float(g[4]) + disp * cv
			# Its displacement plate by plate: what each level of the column keeps out.
			var lv: PackedFloat32Array = g[5]
			if lv.is_empty():
				lv.resize(dims.y)
			var wet: PackedInt32Array = cells_of.get(key, PackedInt32Array())
			for y in dims.y:
				var i := x + dims.x * (y + dims.y * z)
				var st2 := state[i]
				if st2 == HullAir.SOLID:
					lv[y] += SOLID_DISPLACE * cv
				else:
					wet.append(i)
					if st2 == HullAir.INSIDE:
						lv[y] += cv
			cells_of[key] = wet
			g[5] = lv
			g[6] = mini(int(g[6]), lo)
			g[1] = int(g[1]) + 1
			g[2] = (g[2] as Vector3) + frame * Vector3((x + 0.5) * stud, lo * plate, (z + 0.5) * stud)
			g[3] = maxi(int(g[3]), cells)
			groups[key] = g
	f.mass = maxf(1.0, n * cv * HULL_DENSITY)
	f.com = sum / maxf(1.0, float(n))
	var ixx := 0.0
	var iyy := 0.0
	var izz := 0.0
	var m1 := cv * HULL_DENSITY
	var inv := frame.basis.inverse()
	for p in pts:
		var r := inv * (p - f.com)
		ixx += m1 * (r.y * r.y + r.z * r.z)
		iyy += m1 * (r.x * r.x + r.z * r.z)
		izz += m1 * (r.x * r.x + r.y * r.y)
	f.inertia = Vector3(maxf(ixx, 1.0), maxf(iyy, 1.0), maxf(izz, 1.0))
	for key in groups:
		var g: Array = groups[key]
		var area := float(g[1]) * stud * stud
		var lv: PackedFloat32Array = g[5]
		var lo_y: int = g[6]
		var cum := PackedFloat32Array([0.0])
		for y in range(lo_y, dims.y):
			cum.append(cum[-1] + lv[y])
		f.columns.append([(g[2] as Vector3) / float(g[1]), float(g[0]) / area, area,
				float(g[4]) / maxf(float(g[0]), 1e-6), cum])
		f.column_cells.append(cells_of.get(key, PackedInt32Array()))
	f.cell_v = cv
	var area_all := 0.0
	for c in f.columns:
		area_all += float(c[2])
	f.wet_ref = maxf(1.0, area_all * f.calm_draft())
	return f


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
			v += kept_out(c, mid)
		if v < want:
			lo = mid
		else:
			hi = mid
	return (lo + hi) * 0.5


## Everything it keeps out of the water, sunk right under: m^3.
func displaces() -> float:
	var v := 0.0
	for c in columns:
		v += float((c[4] as PackedFloat32Array)[-1])
	return v


## What column `c` keeps out of the water `sub` metres up from its bottom, m^3.
static func kept_out(c: Array, sub: float) -> float:
	var cum: PackedFloat32Array = c[4]
	var k := sub / BrickWorld.get_plate_metres()
	var i := clampi(int(floor(k)), 0, cum.size() - 1)
	if i >= cum.size() - 1:
		return cum[-1]
	return lerpf(cum[i], cum[i + 1], k - float(i))


## The forces on it at snapshot `sn` {xf, vel, ang, t, sea, water (cells of water
## a column, or empty)}, written back into it: force, torque (world), sub (m^3
## under), aboard (kg of water), us. Reads only the snapshot and what `measure`
## set, so it runs on a worker (BrickWave.sample_heights is pure).
func forces(sn: Dictionary) -> void:
	var t0 := Time.get_ticks_usec()
	var xf: Transform3D = sn.xf
	var vel0: Vector3 = sn.vel
	var ang0: Vector3 = sn.ang
	var sea0: float = sn.sea
	var water: PackedFloat32Array = sn.water
	var up := xf.basis.y.normalized()
	var at := PackedVector2Array()
	var bottoms: Array[Vector3] = []
	for c in columns:
		var p: Vector3 = xf * (c[0] as Vector3)
		bottoms.append(p)
		at.append(Vector2(p.x, p.z))
	var waves := BrickWave.sample_heights(at, float(sn.t))
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
		if water.size() > k and water[k] > 0.0:
			var wm := water[k] * cell_v * WATER
			aboard += wm
			var down := Vector3(0.0, -wm * G, 0.0)
			var rw := p + up * 0.5 - c_w
			force += down
			torque += rw.cross(down)
		# The surface's height there (absolute: the sea level and the wave). NaN at a
		# wave gain of exactly 0 (BrickWave's): the calm sea.
		var h := waves[k] if waves.size() > k and not is_nan(waves[k]) else sea0
		var depth := (h - p.y) / maxf(up.y, 0.3)
		var sub := clampf(depth, 0.0, float(c[1]))
		if sub <= 0.0:
			continue
		sub_total += sub * float(c[2])
		var at_p := p + up * sub * 0.5
		var lift := Vector3(0.0, WATER * G * kept_out(c, sub), 0.0)
		var r := at_p - c_w
		var v_p := vel0 + ang0.cross(r)
		# A wet column's drag: its share of the hull's mass, damped at DRAG.
		var share := mass * float(c[2]) * sub / wet_ref
		var drag := -v_p * share * DRAG
		force += lift + drag
		torque += r.cross(lift + drag)
	sn.force = force
	sn.torque = torque
	sn.sub = sub_total
	sn.aboard = aboard
	sn.us = float(Time.get_ticks_usec() - t0)


## Its motion one tick on under forces `f` (a `forces` snapshot's), from `xf`,
## `vel` and `ang` as they are now (a late force pushes the hull as it moves, not
## as it was): [xf, vel, ang].
func integrate(dt: float, f: Dictionary, xf: Transform3D, vel: Vector3, ang: Vector3) -> Array:
	var force: Vector3 = f.force
	var torque: Vector3 = f.torque
	var aboard: float = f.aboard
	var c_w := xf * com
	vel += force / (mass + aboard) * dt
	# Angular: in its own axes, its inertia's diagonal.
	var b := xf.basis.orthonormalized()
	var t_l := b.inverse() * torque
	var a_l := Vector3(t_l.x / inertia.x, t_l.y / inertia.y, t_l.z / inertia.z)
	if float(f.sub) > 0.0:
		ang *= exp(-ANG_DRAG * dt)
	ang += b * a_l * dt
	var origin := c_w + vel * dt
	var nb := b
	if ang.length_squared() > 1e-12:
		nb = (Basis(ang.normalized(), ang.length() * dt) * b).orthonormalized()
	# Turned about its centre, not its node's origin.
	return [Transform3D(nb, origin - nb * com), vel, ang]
