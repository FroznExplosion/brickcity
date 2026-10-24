class_name PlanetNavRegion
extends RefCounted

## One flat nav region on a planet (Docs/Planets.md 11.8, N1b): a tangent frame
## and the ground under it as a grid of heights in that frame -- what
## `AIWorld.set_ground_grid` will read in place of the flat terrain's field.
##
## The frame is planet-local (the planet's centre at the origin): world is
## `planet.global_transform * frame`. Its Y is the up at the region's centre,
## and its origin sits under the region's lowest ground (by FLOOR_MARGIN), so
## every height is >= 0 and the AI's plates count up from 0 as in the flat
## game. The grid's corners are on stud lines: `studs` across, a sample every
## `step` studs.

## Metres of ground under the lowest sample: a stud's centre between samples
## never reads under plate 0.
const FLOOR_MARGIN := 1.0

var data: PlanetData
## Region-local -> planet-local.
var frame := Transform3D.IDENTITY
var studs := 1024
var step := 4
## Samples along each side: studs / step + 1.
var size := 0
## Metres between samples, and the region's half width (its centre at x = z = 0).
var step_m := 0.0
var half := 0.0
## size * size heights, row by row along +X then +Z, from (-half, -half).
var heights := PackedFloat32Array()
## The sea's surface in the frame (NAN: no sea).
var sea_y := NAN
var build_ms := 0.0


## A region of `p_studs` x `p_studs` studs centred over unit `dir` (planet-local).
static func make(p_data: PlanetData, dir: Vector3, p_studs := 1024, p_step := 4) -> PlanetNavRegion:
	var r := PlanetNavRegion.new()
	r.data = p_data
	r.studs = p_studs
	r.step = p_step
	r._build(dir.normalized())
	return r


func _build(u: Vector3) -> void:
	var t0 := Time.get_ticks_usec()
	var stud := BrickWorld.get_stud_metres()
	step_m = step * stud
	half = studs * 0.5 * stud
	size = studs / step + 1
	# The same tangent axes as Gravity.tangent_basis, at the datum first.
	var ref := Vector3.FORWARD if absf(u.dot(Vector3.FORWARD)) < 0.9 else Vector3.RIGHT
	var x := ref.cross(u).normalized()
	frame = Transform3D(Basis(x, u, x.cross(u)), u * data.radius)
	heights.resize(size * size)
	var low := INF
	for j in size:
		for i in size:
			var h := _ground_y(-half + i * step_m, -half + j * step_m)
			heights[j * size + i] = h
			low = minf(low, h)
	# Down under the lowest ground: every height >= FLOOR_MARGIN.
	var drop := low - FLOOR_MARGIN
	frame.origin += u * drop
	for k in heights.size():
		heights[k] -= drop
	if not is_nan(data.sea_level):
		sea_y = _sea_y(drop)
	build_ms = float(Time.get_ticks_usec() - t0) / 1000.0


## The ground's height over the frame's plane along the frame's vertical
## through (lx, lz): where the line q(t) = frame * (lx, t, lz) meets the
## ground. Fixed-point on the direction (twice is enough: the ground's slope
## moves the direction by under a millimetre's worth on the second pass).
func _ground_y(lx: float, lz: float) -> float:
	var base := frame * Vector3(lx, 0.0, lz)
	var up := frame.basis.y
	var t := 0.0
	for k in 3:
		var d := (base + up * t).normalized()
		t = _t_at_radius(base, up, data.radius + data.height(d))
	return t


## The t at which base + up * t is `rho` from the centre (the far root).
static func _t_at_radius(base: Vector3, up: Vector3, rho: float) -> float:
	var b := base.dot(up)
	var c := base.length_squared() - rho * rho
	return -b + sqrt(maxf(b * b - c, 0.0))


## The sea's surface at the region's centre, in the frame after the drop.
func _sea_y(drop: float) -> float:
	return data.sea_level - drop


## The ground's height in the frame at region-local (lx, lz), bilinear between
## samples; INF outside the region (the AI's ground is a wall there).
func ground_at(lx: float, lz: float) -> float:
	var fx := (lx + half) / step_m
	var fz := (lz + half) / step_m
	if fx < 0.0 or fz < 0.0 or fx > size - 1 or fz > size - 1:
		return INF
	var i := mini(int(fx), size - 2)
	var j := mini(int(fz), size - 2)
	var sx := fx - i
	var sz := fz - j
	var a := lerpf(heights[j * size + i], heights[j * size + i + 1], sx)
	var b := lerpf(heights[(j + 1) * size + i], heights[(j + 1) * size + i + 1], sx)
	return lerpf(a, b, sz)


## Region-local -> world, for a planet node at `planet_xf`.
func world_frame(planet_xf: Transform3D) -> Transform3D:
	return planet_xf * frame
