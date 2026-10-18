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
static func _closed(index: PackedInt32Array) -> bool:
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
	_ok("one solid sample: a closed cube", oi.size() == 12 * 3 and _closed(oi), "%d indices" % oi.size())

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
		_ok("a ball (smoothed %d): closed, every edge twice" % smooth, _closed(idx))
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
	print("form mesher probe: %d passed, %d failed" % [_passed, _failed])
	quit(1 if _failed > 0 else 0)
