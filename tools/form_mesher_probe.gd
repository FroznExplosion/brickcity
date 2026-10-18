extends SceneTree

## FormMesher (gdextension/brick/src/form_mesher.cpp), the asset workshop's shell
## surface: a smooth closed surface round a sampled solid (Docs/AssetWorkshop.md,
## "Shells"). Headless:
##
##     godot --headless --path . --script res://tools/form_mesher_probe.gd

var _passed := 0
var _failed := 0


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_passed += 1
		print("  ok   ", what)
	else:
		_failed += 1
		print("  FAIL ", what, "  ", detail)


## A ball of radius `r` samples in a cube `n` samples a side.
static func _ball(n: int, r: float) -> PackedByteArray:
	var f := PackedByteArray()
	f.resize(n * n * n)
	var c := (n - 1) * 0.5
	for z in n:
		for y in n:
			for x in n:
				if Vector3(x - c, y - c, z - c).length() <= r:
					f[x + n * (y + n * z)] = 1
	return f


## Every edge in exactly two triangles, once each way: closed and consistently wound.
## Corners that share a place are one vertex (a hard edge gives each its own normal).
static func _closed(index: PackedInt32Array, v: PackedVector3Array = PackedVector3Array()) -> bool:
	if not v.is_empty():
		index = _welded(index, v)
	var edges := {}
	for t in range(0, index.size(), 3):
		for k in 3:
			var a := index[t + k]
			var b := index[t + (k + 1) % 3]
			var key := Vector2i(a, b)
			if edges.has(key):
				return false
			edges[key] = true
	for key: Vector2i in edges:
		if not edges.has(Vector2i(key.y, key.x)):
			return false
	return true


## Indices with corners at one place made one vertex.
static func _welded(index: PackedInt32Array, v: PackedVector3Array) -> PackedInt32Array:
	var first := {}
	var out := PackedInt32Array()
	for i in index:
		var key := (v[i] * 1e5).round()
		if not first.has(key):
			first[key] = first.size()
		out.append(int(first[key]))
	return out


## Signed volume of a closed mesh, positive when wound as Godot's front faces from outside.
static func _volume(v: PackedVector3Array, index: PackedInt32Array) -> float:
	var vol := 0.0
	for t in range(0, index.size(), 3):
		vol -= v[index[t]].dot(v[index[t + 1]].cross(v[index[t + 2]])) / 6.0
	return vol


func _init() -> void:
	print("form mesher probe")
	_ok("an empty field has no surface", FormMesher.surface(PackedByteArray([0, 0, 0, 0, 0, 0, 0, 0]),
			Vector3i(2, 2, 2), Vector3.ONE, 0).is_empty())

	# One sample: a closed little octahedron.
	var one := FormMesher.surface(PackedByteArray([1]), Vector3i(1, 1, 1), Vector3.ONE, 0)
	var oi: PackedInt32Array = one[Mesh.ARRAY_INDEX]
	_ok("one solid sample: a closed cube", oi.size() == 12 * 3 and _closed(oi, one[Mesh.ARRAY_VERTEX]), "%d indices" % oi.size())

	# The winding the brick meshes use: a brick's triangle against its own normal.
	var world := BrickWorld.new()
	var palette := BrickPalette.bake(world)
	var ch := world.create_chunk(Vector3i.ZERO, Vector3i(4, 4, 4))
	world.place_block(ch, Vector3i(1, 0, 1), palette[BrickPalette.variant_name("brick_1x2", 0, false)], 0)
	var b: Array = world.build_chunk_mesh(ch)
	var bv: PackedVector3Array = b[Mesh.ARRAY_VERTEX]
	var bn: PackedVector3Array = b[Mesh.ARRAY_NORMAL]
	var bi: PackedInt32Array = b[Mesh.ARRAY_INDEX]
	var cross := (bv[bi[1]] - bv[bi[0]]).cross(bv[bi[2]] - bv[bi[0]])
	var brick_sign := signf(cross.dot(bn[bi[0]]))
	world.release_chunk(ch)

	var n := 24
	var r := 9.0
	var cell := Vector3(0.01, 0.01, 0.01)
	for smooth in [0, 4]:
		var s := FormMesher.surface(_ball(n, r), Vector3i(n, n, n), cell, smooth)
		var v: PackedVector3Array = s[Mesh.ARRAY_VERTEX]
		var nm: PackedVector3Array = s[Mesh.ARRAY_NORMAL]
		var idx: PackedInt32Array = s[Mesh.ARRAY_INDEX]
		_ok("a ball (smoothed %d): closed, every edge twice" % smooth, _closed(idx, v))
		var t_cross := (v[idx[1]] - v[idx[0]]).cross(v[idx[2]] - v[idx[0]])
		_ok("wound as the brick meshes are", signf(t_cross.dot(nm[idx[0]])) == brick_sign,
				"brick %.0f, this %.0f" % [brick_sign, signf(t_cross.dot(nm[idx[0]]))])
		var centre := Vector3(n, n, n) * 0.5 * cell
		var out := 0
		for i in v.size():
			if nm[i].dot(v[i] - centre) > 0.0:
				out += 1
		_ok("normals look out", out == v.size(), "%d of %d" % [out, v.size()])
		# The surface runs between the solid samples and the empty ones round them, so a
		# ball of samples within r comes out a ball of radius r (smoothing takes a few per
		# cent more off a curve, as any averaging does).
		var want := 4.0 / 3.0 * PI * pow(r * cell.x, 3)
		var got := absf(_volume(v, idx))
		_ok("its volume is the ball's (within 10%)", absf(got - want) / want < 0.10, "%.7f vs %.7f" % [got, want])
		var worst := 0.0
		for p in v:
			worst = maxf(worst, absf((p - centre).length() - r * cell.x))
		print("       smoothed %d: %d triangles, furthest off the sphere %.2f samples" % [smooth, idx.size() / 3, worst / cell.x])
		if smooth == 4:
			_ok("smoothed, it is round: within a sample of the sphere", worst < cell.x, "%.2f samples" % (worst / cell.x))
	# Erosion: what a shell's thickness leaves for the bricks inside it.
	var cube := PackedByteArray()
	cube.resize(1000)
	cube.fill(1)
	var left := FormMesher.erode(cube, Vector3i(10, 10, 10), Vector3i(2, 2, 2))
	var count := 0
	var inside := true
	for z in 10:
		for y in 10:
			for x in 10:
				if left[x + 10 * (y + 10 * z)] != 0:
					count += 1
					inside = inside and x >= 2 and x < 8 and y >= 2 and y < 8 and z >= 2 and z < 8
	_ok("a 10-cube eroded by 2 is the 6-cube in its middle", count == 216 and inside, "%d left" % count)
	var flat := FormMesher.erode(cube, Vector3i(10, 10, 10), Vector3i(0, 3, 0))
	var rows := 0
	for x in 10:
		rows += 1 if flat[x + 10 * (5 + 10 * 5)] != 0 else 0
	_ok("by 3 up and down only: a slab 4 high, all the way across", rows == 10
			and flat[5 + 10 * (2 + 10 * 5)] == 0 and flat[5 + 10 * (3 + 10 * 5)] != 0)
	_stairs()
	_decimated()
	print("form mesher probe: %d passed, %d failed" % [_passed, _failed])
	quit(1 if _failed > 0 else 0)


## A slab cut by a slant (z below 0.37 of x): sampled in or out it is a staircase. How
## far the slanted face's vertices stand off the true plane, blurred or not.
func _stairs() -> void:
	var n := 32
	var f := PackedByteArray()
	f.resize(n * n * n)
	for z in n:
		for y in n:
			for x in n:
				if x > 2 and x < n - 3 and y > 2 and y < n - 3 and z > 2 and z + 0.5 < 4.0 + 0.37 * (x + 0.5):
					f[x + n * (y + n * z)] = 1
	var worst := {}
	for blur in [0, 2]:
		var s := FormMesher.surface(f, Vector3i(n, n, n), Vector3.ONE, 4, blur)
		var v: PackedVector3Array = s[Mesh.ARRAY_VERTEX]
		var nm: PackedVector3Array = s[Mesh.ARRAY_NORMAL]
		var plane := Vector3(-0.37, 0.0, 1.0).normalized()
		var off := 0.0
		for i in v.size():
			var p := v[i]
			# On the slanted face, away from the slab's other faces.
			if nm[i].dot(plane) > 0.8 and p.x > 8 and p.x < n - 8 and p.y > 8 and p.y < n - 8:
				off = maxf(off, absf((p.z - (4.0 + 0.37 * p.x)) * plane.z))
		worst[blur] = off
	print("       slanted face, furthest off its plane: %.2f samples in or out, %.2f blurred" % [worst[0], worst[2]])
	_ok("blurred, a staircase is a slope: within a quarter of a sample of it", float(worst[2]) < 0.25
			and float(worst[2]) < float(worst[0]), str(worst))


## Decimated to a budget: still closed, still the shape, about that many triangles.
func _decimated() -> void:
	var n := 24
	var r := 9.0
	var full := FormMesher.surface(_ball(n, r), Vector3i(n, n, n), Vector3.ONE, 4, 1)
	var fi: PackedInt32Array = full[Mesh.ARRAY_INDEX]
	var vol_full := absf(_volume(full[Mesh.ARRAY_VERTEX], fi))
	for target in [1000, 300]:
		var s := FormMesher.surface(_ball(n, r), Vector3i(n, n, n), Vector3.ONE, 4, 1, target)
		var idx: PackedInt32Array = s[Mesh.ARRAY_INDEX]
		var v: PackedVector3Array = s[Mesh.ARRAY_VERTEX]
		var tris := idx.size() / 3
		var vol := absf(_volume(v, idx))
		_ok("decimated to %d: closed, about that many triangles (from %d)" % [target, fi.size() / 3], _closed(idx, v)
				and tris <= target + 4 and tris >= target * 0.8, "%d triangles" % tris)
		_ok("and the same ball (volume within 5%)", absf(vol - vol_full) / vol_full < 0.05, "%.1f vs %.1f" % [vol, vol_full])
	# A box: its flat sides go to almost nothing.
	var box := PackedByteArray()
	box.resize(20 * 20 * 20)
	for z in range(4, 16):
		for y in range(4, 16):
			for x in range(4, 16):
				box[x + 20 * (y + 20 * z)] = 1
	var b := FormMesher.surface(box, Vector3i(20, 20, 20), Vector3.ONE, 0, 0, 12)
	var bi: PackedInt32Array = b[Mesh.ARRAY_INDEX]
	_ok("a box decimated: its flat sides go first, still closed", _closed(bi, b[Mesh.ARRAY_VERTEX]) and bi.size() / 3 <= 40,
			"%d triangles" % (bi.size() / 3))
	# Pinned samples hold their vertices still: the face against something else stays put.
	var pinned := box.duplicate()
	for z in range(4, 16):
		for y in range(4, 16):
			pinned[4 + 20 * (y + 20 * z)] = 2
	var pb := FormMesher.surface(pinned, Vector3i(20, 20, 20), Vector3.ONE, 8, 1, 60)
	var pv: PackedVector3Array = pb[Mesh.ARRAY_VERTEX]
	var on_face := 0
	var lowest := INF
	for p in pv:
		lowest = minf(lowest, p.x)
		if absf(p.x - 4.0) < 1e-3:
			on_face += 1
	_ok("a pinned face stays on its plane", absf(lowest - 4.0) < 1e-3 and on_face > 0 and _closed(pb[Mesh.ARRAY_INDEX], pv),
			"lowest x %.3f, %d on it" % [lowest, on_face])
