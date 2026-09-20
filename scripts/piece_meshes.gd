class_name PieceMeshes

## Small shared meshes, built once in code and reused by every MultiMesh.
##
## These are the GAME meshes, not the print meshes. Spec §3 gives the print
## dimensions (8 mm stud pitch, 4.8 mm stud contact diameter, 1.7 mm stud
## height) and spec §2 the house style (tapered, faceted, 8 or 16 sides, 2 mm
## centre hole). At 1:43.75 the hole is 0.0875 m and is never more than a pixel
## on screen, so the game stud drops it and the print part keeps it — which is
## exactly the "same authored part, differing only by decimation" split B3 asks
## for.

## Mirrors of the grid constants. `BrickWorld.get_stud_metres()` is the
## authority (D6) but a `const` cannot call it, so the probe asserts parity
## rather than trusting these.
const STUD := 0.35
const PLATE := 0.14

## 4.8 mm contact diameter on an 8 mm pitch, at 1:43.75.
const STUD_R := 0.105
const STUD_H := 0.074
## Spec §2: slightly tapered, so it reads as printed and grips.
const STUD_TAPER := 0.86

const SIDES := 8

static var _stud: ArrayMesh = null
static var _round_plate: ArrayMesh = null
static var _tuft: ArrayMesh = null
static var _pebble: ArrayMesh = null


## An 8-sided tapered stud with a fan cap and no bottom face. 22 triangles.
##
## No bottom because a stud is always sitting on something. That is a third of
## the triangles gone for nothing, and at 8.3k instances (Terrain §7.2) a third
## is 60k triangles a frame.
static func stud() -> ArrayMesh:
	if _stud != null:
		return _stud
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var top_r := STUD_R * STUD_TAPER
	for i in SIDES:
		var a0 := TAU * float(i) / float(SIDES)
		var a1 := TAU * float(i + 1) / float(SIDES)
		var c0 := Vector2(cos(a0), sin(a0))
		var c1 := Vector2(cos(a1), sin(a1))
		var n := (Vector3(c0.x + c1.x, 0.0, c0.y + c1.y)).normalized()
		var b0 := Vector3(c0.x * STUD_R, 0.0, c0.y * STUD_R)
		var b1 := Vector3(c1.x * STUD_R, 0.0, c1.y * STUD_R)
		var t0 := Vector3(c0.x * top_r, STUD_H, c0.y * top_r)
		var t1 := Vector3(c1.x * top_r, STUD_H, c1.y * top_r)
		_tri(st, n, b0, t0, t1)
		_tri(st, n, b0, t1, b1)
	# Cap, as a fan from the centre.
	var up := Vector3.UP
	for i in range(1, SIDES - 1):
		var a0 := TAU * 0.0
		var a1 := TAU * float(i) / float(SIDES)
		var a2 := TAU * float(i + 1) / float(SIDES)
		_tri(st, up,
			Vector3(cos(a0) * top_r, STUD_H, sin(a0) * top_r),
			Vector3(cos(a1) * top_r, STUD_H, sin(a1) * top_r),
			Vector3(cos(a2) * top_r, STUD_H, sin(a2) * top_r))
	_stud = st.commit()
	return _stud


## A 1x1 round plate: the water surface piece (spec §4). Octagonal skirt plus a
## cap, no bottom above water. The instance's Y scale is driven per-frame by the
## vertex shader to make the column down to the trough, so the skirt is built
## one unit tall and stretched.
static func round_plate() -> ArrayMesh:
	if _round_plate != null:
		return _round_plate
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var r := STUD * 0.5
	# Skirt hangs DOWN from y=0 by one unit, so a vertex-shader scale of `d`
	# gives a column `d` metres deep with the top face staying put.
	for i in SIDES:
		var a0 := TAU * float(i) / float(SIDES)
		var a1 := TAU * float(i + 1) / float(SIDES)
		var c0 := Vector2(cos(a0), sin(a0))
		var c1 := Vector2(cos(a1), sin(a1))
		var n := Vector3(c0.x + c1.x, 0.0, c0.y + c1.y).normalized()
		var t0 := Vector3(c0.x * r, 0.0, c0.y * r)
		var t1 := Vector3(c1.x * r, 0.0, c1.y * r)
		var b0 := Vector3(c0.x * r, -1.0, c0.y * r)
		var b1 := Vector3(c1.x * r, -1.0, c1.y * r)
		_tri(st, n, b0, t0, t1)
		_tri(st, n, b0, t1, b1)
	var up := Vector3.UP
	for i in range(1, SIDES - 1):
		var a0 := 0.0
		var a1 := TAU * float(i) / float(SIDES)
		var a2 := TAU * float(i + 1) / float(SIDES)
		_tri(st, up,
			Vector3(cos(a0) * r, 0.0, sin(a0) * r),
			Vector3(cos(a1) * r, 0.0, sin(a1) * r),
			Vector3(cos(a2) * r, 0.0, sin(a2) * r))
	_round_plate = st.commit()
	return _round_plate


## A unit water piece: a rectangular plate whose footprint is [0,1] x [0,1] in
## XZ with its origin at the MIN corner, and whose skirt hangs one unit below.
##
## Origin at the corner and a unit footprint is the whole trick: the water
## vertex shader scales X by the piece's run, Z by its depth and Y by its
## column, so one mesh covers every 1x1 through 2x4 the GPU packer produces
## ([Docs/Water.md](../Docs/Water.md) §3.5) without a mesh per size.
##
## 10 triangles — five quads, no bottom. Less than half the 8-sided round
## plate it replaces, which is how the piece count survives getting bigger.
static var _unit_plate: ArrayMesh = null

static func unit_plate() -> ArrayMesh:
	if _unit_plate != null:
		return _unit_plate
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var a := Vector3(0, 0, 0)
	var b := Vector3(1, 0, 0)
	var c := Vector3(1, 0, 1)
	var d := Vector3(0, 0, 1)
	_quad(st, Vector3.UP, a, b, c, d)
	var lo := Vector3(0, -1, 0)
	_quad(st, Vector3(0, 0, -1), a + lo, b + lo, b, a)
	_quad(st, Vector3(1, 0, 0), b + lo, c + lo, c, b)
	_quad(st, Vector3(0, 0, 1), c + lo, d + lo, d, c)
	_quad(st, Vector3(-1, 0, 0), d + lo, a + lo, a, d)
	_unit_plate = st.commit()
	return _unit_plate


static func _quad(st: SurfaceTool, n: Vector3, a: Vector3, b: Vector3,
		c: Vector3, d: Vector3) -> void:
	_tri(st, n, a, b, c)
	_tri(st, n, a, c, d)


## Scatter: a grass tuft as three crossed blades. Presentation only — no
## collision, no connectivity, destroyed without being simulated, the same call
## BuildMode §9.2 made for decorative fixtures.
static func tuft() -> ArrayMesh:
	if _tuft != null:
		return _tuft
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var h := 0.22
	var w := 0.07
	for i in 3:
		var a := TAU * float(i) / 3.0
		var dir := Vector3(cos(a), 0.0, sin(a))
		var side := Vector3(-dir.z, 0.0, dir.x) * w
		var tip := dir * 0.06 + Vector3(0.0, h, 0.0)
		var n := Vector3(0.0, 0.6, 0.0) + dir * 0.4
		_tri(st, n.normalized(), -side, side, tip)
		_tri(st, -n.normalized(), side, -side, tip)
	_tuft = st.commit()
	return _tuft


## Scatter: a boulder, as a stack of chamfered slabs — a rock built out of
## bricks rather than a rock-shaped blob, which is the only kind of rock this
## world can contain.
##
## Sized to ONE stud and scaled by the instance, so the same mesh serves the
## 1x1, 2x2 and 3x3 the packer picks between. Spec §2's 45-degree chamfer on
## the bottom edges is what stops it reading as a voxel.
static func pebble() -> ArrayMesh:
	if _pebble != null:
		return _pebble
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# Course HEIGHTS are in plates, not in fractions of a stud. Measuring them
	# against the stud made each one 0.06 m and the boulder read as a stack of
	# sheets of paper rather than as brick. Three plates is one brick tall,
	# which is what a rock this wide should be.
	var courses := [
		{"w": 0.94, "d": 0.82, "h": PLATE, "y": 0.0, "off": Vector2(0.0, 0.0)},
		{"w": 0.72, "d": 0.64, "h": PLATE, "y": PLATE, "off": Vector2(0.05, -0.04)},
		{"w": 0.44, "d": 0.40, "h": PLATE, "y": PLATE * 2.0, "off": Vector2(-0.03, 0.05)},
	]
	for c in courses:
		_slab(st, c["off"].x * STUD, c["y"], c["off"].y * STUD,
			c["w"] * STUD, c["h"], c["d"] * STUD)
	_pebble = st.commit()
	return _pebble


## One chamfered course: a box whose bottom is drawn in a touch, so the
## silhouette has the printed bevel rather than a hard voxel corner.
static func _slab(st: SurfaceTool, cx: float, y: float, cz: float,
		w: float, h: float, d: float) -> void:
	var hw := w * 0.5
	var hd := d * 0.5
	# Spec §2: 45-degree chamfer on the BOTTOM edges, small fillet on top. So
	# the course is widest at its base and draws IN going up. Inverting that
	# flared each slab outward and read as a stack of plates.
	var ch := 0.16   # taper, as a fraction of the half-width
	var tw := hw * (1.0 - ch)
	var td := hd * (1.0 - ch)
	var y1 := y + h
	var top := [
		Vector3(cx - tw, y1, cz - td), Vector3(cx + tw, y1, cz - td),
		Vector3(cx + tw, y1, cz + td), Vector3(cx - tw, y1, cz + td)]
	var bot := [
		Vector3(cx - hw, y, cz - hd), Vector3(cx + hw, y, cz - hd),
		Vector3(cx + hw, y, cz + hd), Vector3(cx - hw, y, cz + hd)]
	_tri(st, Vector3.UP, top[0], top[1], top[2])
	_tri(st, Vector3.UP, top[0], top[2], top[3])
	for i in 4:
		var j: int = (i + 1) % 4
		var n: Vector3 = (bot[i] - Vector3(cx, y, cz))
		n.y = 0.0
		n = (n.normalized() + Vector3(0, 0.3, 0)).normalized()
		_tri(st, n, bot[i], bot[j], top[j])
		_tri(st, n, bot[i], top[j], top[i])


static func _tri(st: SurfaceTool, n: Vector3, a: Vector3, b: Vector3, c: Vector3) -> void:
	st.set_normal(n)
	st.add_vertex(a)
	st.set_normal(n)
	st.add_vertex(b)
	st.set_normal(n)
	st.add_vertex(c)
