class_name PartMeshLib
extends RefCounted
## Geometry batch that emits skinned primitives into a SurfaceTool surface.
## The core idea: organic vs robotic is a SKIN-WEIGHT POLICY, not a different
## mesh system. Blended ring weights across a joint => smooth organic flesh.
## Hard 100%-one-bone segments with inset gaps + servo balls => machine.

## One ring "station" along a limb/body polyline.
class Station:
	var pos: Vector3
	var basis: Basis          # y = tube direction
	var radius: float
	var rx: float = 1.0       # lateral ellipse factor
	var bones: PackedInt32Array
	var weights: PackedFloat32Array
	var v: float = 0.0        # uv v

	static func make(p: Vector3, b: Basis, r: float, bn: PackedInt32Array, w: PackedFloat32Array, pv: float, prx := 1.0) -> Station:
		var s := Station.new()
		s.pos = p; s.basis = b; s.radius = r; s.bones = bn; s.weights = w; s.v = pv; s.rx = prx
		return s

## Backend selection: "auto" uses the native MeshForge GDExtension when the
## library is loaded and falls back to SurfaceTool otherwise. "gd"/"native"
## pin a path (tests, benchmarks).
static var backend := "auto"

static func native_available() -> bool:
	return ClassDB.class_exists(&"MeshForge") and ClassDB.can_instantiate(&"MeshForge")

var st: SurfaceTool
var smooth: bool
var _vcount: int = 0
var _n: Object = null   # native MeshForge, when in use

func _init(p_smooth: bool) -> void:
	smooth = p_smooth
	var use_native: bool = backend != "gd" and native_available()
	if backend == "native" and not native_available():
		push_warning("PartMeshLib: native backend requested but MeshForge missing; using GDScript")
	if use_native:
		_n = ClassDB.instantiate(&"MeshForge")
		_n.begin(smooth)
	else:
		st = SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)

static func _station_dict(s: Station) -> Dictionary:
	return {"pos": s.pos, "basis": s.basis, "radius": s.radius, "rx": s.rx,
		"v": s.v, "bones": s.bones, "weights": s.weights}

static func bw(b0: int, w0: float, b1: int = 0, w1: float = 0.0) -> Array:
	return [PackedInt32Array([b0, b1, 0, 0]), PackedFloat32Array([w0, w1, 0.0, 0.0])]

## Basis with local +Y aligned to dir.
static func basis_y_to(dir: Vector3) -> Basis:
	var y := dir.normalized()
	if y.length_squared() < 0.0001:
		y = Vector3.UP
	var hint := Vector3.RIGHT if absf(y.dot(Vector3.RIGHT)) < 0.98 else Vector3.FORWARD
	var z := hint.cross(y).normalized()
	var x := y.cross(z).normalized()
	return Basis(x, y, z)

func _emit(pos: Vector3, normal: Vector3, uv: Vector2, bones: PackedInt32Array, weights: PackedFloat32Array) -> int:
	st.set_smooth_group(0 if smooth else _vcount)  # unique group per vertex = flat after generate_normals
	st.set_normal(normal)
	st.set_uv(uv)
	st.set_bones(bones)
	st.set_weights(weights)
	st.add_vertex(pos)
	var i := _vcount
	_vcount += 1
	return i

func _ring(s: Station, n: int) -> int:
	var base := _vcount
	for k in n + 1:  # +1 duplicated seam vertex for clean UVs
		var a := TAU * float(k % n) / float(n)
		var off := s.basis.x * (cos(a) * s.radius * s.rx) + s.basis.z * (sin(a) * s.radius)
		_emit(s.pos + off, off.normalized(), Vector2(float(k) / float(n), s.v), s.bones, s.weights)
	return base

## Continuous smooth tube through stations (organic). Caps both ends.
func add_tube(stations: Array, ring_n: int = 8, cap_start := true, cap_end := true) -> void:
	if stations.size() < 2:
		return
	if _n:
		var arr: Array = []
		for s: Station in stations:
			arr.append(_station_dict(s))
		_n.add_tube(arr, ring_n, cap_start, cap_end)
		return
	var bases: Array[int] = []
	for s: Station in stations:
		bases.append(_ring(s, ring_n))
	for i in stations.size() - 1:
		var b0: int = bases[i]
		var b1: int = bases[i + 1]
		for k in ring_n:
			st.add_index(b0 + k); st.add_index(b1 + k); st.add_index(b0 + k + 1)
			st.add_index(b0 + k + 1); st.add_index(b1 + k); st.add_index(b1 + k + 1)
	if cap_start:
		var s0: Station = stations[0]
		_cap(bases[0], ring_n, s0.pos - s0.basis.y * s0.radius * 0.6, s0, true)
	if cap_end:
		var se: Station = stations[stations.size() - 1]
		_cap(bases[stations.size() - 1], ring_n, se.pos + se.basis.y * se.radius * 0.6, se, false)

func _cap(ring_base: int, ring_n: int, tip: Vector3, s: Station, flip: bool) -> void:
	var nrm := (-s.basis.y) if flip else s.basis.y
	var tip_i := _emit(tip, nrm, Vector2(0.5, s.v), s.bones, s.weights)
	for k in ring_n:
		if flip:
			st.add_index(ring_base + k + 1); st.add_index(tip_i); st.add_index(ring_base + k)
		else:
			st.add_index(ring_base + k); st.add_index(tip_i); st.add_index(ring_base + k + 1)

## Rigid machine tube: each segment hard-bound to one bone, inset gaps at joints.
func add_rigid_segment(p0: Vector3, p1: Vector3, r0: float, r1: float, bone: int, ring_n: int = 6, inset: float = 0.03) -> void:
	if _n:
		_n.add_rigid_segment(p0, p1, r0, r1, bone, ring_n, inset)
		return
	var dir := (p1 - p0).normalized()
	var b := basis_y_to(dir)
	var q0 := p0 + dir * inset
	var q1 := p1 - dir * inset
	var pair0 := bw(bone, 1.0)
	var s0 := Station.make(q0, b, r0, pair0[0], pair0[1], 0.0)
	var s1 := Station.make(q1, b, r1, pair0[0], pair0[1], 1.0)
	add_tube([s0, s1], ring_n, true, true)

## Lat/long sphere bound to (up to two) bones. Smooth-friendly.
func add_sphere(center: Vector3, r: float, bones: PackedInt32Array, weights: PackedFloat32Array, lat: int = 6, lon: int = 8, squash := Vector3.ONE) -> void:
	if _n:
		_n.add_sphere(center, r, bones, weights, lat, lon, squash)
		return
	var rows: Array[int] = []
	for i in lat + 1:
		var phi := PI * float(i) / float(lat)
		var y := cos(phi) * r * squash.y
		var rr := sin(phi) * r
		var base := _vcount
		for k in lon + 1:
			var a := TAU * float(k % lon) / float(lon)
			var off := Vector3(cos(a) * rr * squash.x, y, sin(a) * rr * squash.z)
			_emit(center + off, off.normalized() if off.length() > 0.001 else Vector3.UP,
				Vector2(float(k) / float(lon), float(i) / float(lat)), bones, weights)
		rows.append(base)
	for i in lat:
		var b0: int = rows[i]
		var b1: int = rows[i + 1]
		for k in lon:
			st.add_index(b0 + k); st.add_index(b0 + k + 1); st.add_index(b1 + k)
			st.add_index(b0 + k + 1); st.add_index(b1 + k + 1); st.add_index(b1 + k)

## Commit this batch as a new surface on `mesh`.
func commit(mesh: ArrayMesh, material: Material) -> void:
	if _n:
		if _n.get_vertex_count() > 0:
			_n.commit(mesh, material)
		return
	if _vcount == 0:
		return
	st.generate_normals()
	st.set_material(material)
	st.commit(mesh)

## Weight blend across a polyline of joints. joint_bones[i] owns segment i -> i+1.
## f in [0,1] along segment seg_i. Returns [bones, weights].
static func polyline_weights(seg_i: int, f: float, joint_bones: PackedInt32Array, organic: bool, blend_zone := 0.45) -> Array:
	var nseg := joint_bones.size() - 1
	var bone: int = joint_bones[mini(seg_i, joint_bones.size() - 1)]
	if not organic:
		return bw(bone, 1.0)
	if f < blend_zone and seg_i > 0:
		var t := 0.5 + 0.5 * smoothstep(0.0, 1.0, f / blend_zone)
		return bw(bone, t, joint_bones[seg_i - 1], 1.0 - t)
	if f > 1.0 - blend_zone and seg_i < nseg - 1:
		var t2 := 0.5 + 0.5 * smoothstep(0.0, 1.0, (1.0 - f) / blend_zone)
		return bw(bone, t2, joint_bones[seg_i + 1], 1.0 - t2)
	return bw(bone, 1.0)
