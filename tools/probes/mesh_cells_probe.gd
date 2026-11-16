extends SceneTree

## `SdfForm.mesh_cells`: a closed mesh straight to brick cells (Docs/BuildTools.md section 21,
## stage 7c). A box and a ball, solid and as a skin, against the counts they should have; a
## hollow building model (as model_scale_probe's) at 100, 200 and 400 studs, timed -- cells
## only, no clay, so the big sizes are cheap.
##
##     godot --headless --path . --script res://tools/probes/mesh_cells_probe.gd

var _ok := 0
var _bad := 0


func _check(what: String, good: bool) -> void:
	if good:
		_ok += 1
	else:
		_bad += 1
		print("  FAIL ", what)


## A mesh's triangles: verts and index, each vertex through `f`.
func _tris(m: PrimitiveMesh, xf: Transform3D, flip := false) -> Array:
	var arr := m.get_mesh_arrays()
	var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
	var out := PackedVector3Array()
	for p in v:
		out.append(xf * p)
	if flip:
		for i in range(0, idx.size(), 3):
			var t := idx[i + 1]
			idx[i + 1] = idx[i + 2]
			idx[i + 2] = t
	return [out, idx]


func _join(a: Array, b: Array) -> Array:
	var v: PackedVector3Array = (a[0] as PackedVector3Array).duplicate()
	var idx: PackedInt32Array = (a[1] as PackedInt32Array).duplicate()
	var off := v.size()
	v.append_array(b[0])
	for i in b[1]:
		idx.append(i + off)
	return [v, idx]


func _count(cells: PackedInt32Array) -> int:
	return cells.size() / 3


func _init() -> void:
	print("mesh_cells probe")
	# A box 10 x 4 x 6 cells, its faces on whole cells: 240 solid, its skin a cell thick 240
	# less the 8 x 2 x 4 inside.
	var box := BoxMesh.new()
	box.size = Vector3(10, 4, 6)
	var b := _tris(box, Transform3D(Basis(), Vector3(7, 2, -3)))
	var solid := SdfForm.mesh_cells(b[0], b[1], Vector3i.ZERO)
	_check("box solid 240 (got %d)" % _count(solid), _count(solid) == 240)
	var lo := Vector3i(1 << 20, 1 << 20, 1 << 20)
	var hi := -lo
	for i in range(0, solid.size(), 3):
		var c := Vector3i(solid[i], solid[i + 1], solid[i + 2])
		lo = lo.min(c)
		hi = hi.max(c)
	_check("box cells from (2,0,-6) to (11,3,-1) (got %s %s)" % [lo, hi], lo == Vector3i(2, 0, -6) and hi == Vector3i(11, 3, -1))
	_check("lowest layer first", solid[1] == 0 and solid[solid.size() - 2] == 3)
	var skin := SdfForm.mesh_cells(b[0], b[1], Vector3i.ONE)
	_check("box skin 176 (got %d)" % _count(skin), _count(skin) == 240 - 64)
	var thick := SdfForm.mesh_cells(b[0], b[1], Vector3i(2, 1, 2))
	_check("box skin 2 x 1 x 2: 240 - 6 x 2 x 2 (got %d)" % _count(thick), _count(thick) == 240 - 24)
	# A ball radius 8: about 4/3 pi 8^3 cells.
	var ball := SphereMesh.new()
	ball.radius = 8.0
	ball.height = 16.0
	ball.radial_segments = 64
	ball.rings = 32
	var s := _tris(ball, Transform3D(Basis(), Vector3(0.3, 20.2, 0.1)))
	var bc := _count(SdfForm.mesh_cells(s[0], s[1], Vector3i.ZERO))
	var want := 4.0 / 3.0 * PI * 512.0
	_check("ball %d cells, about %d" % [bc, int(want)], absf(bc - want) < want * 0.04)
	var bs := _count(SdfForm.mesh_cells(s[0], s[1], Vector3i.ONE))
	_check("ball skin %d, less than its solid and more than a shell's area" % bs, bs < bc and bs > 4.0 * PI * 49.0)
	_check("nothing for no mesh", SdfForm.mesh_cells(PackedVector3Array(), PackedInt32Array(), Vector3i.ZERO).is_empty())
	# A hollow building (walls a stud thick, s long, s/2 tall, 0.4 s deep), in cells: x and z
	# studs, y plates (2.5 a stud).
	print("  studs   cells (skin 1 stud)   ms")
	for st in [100.0, 200.0, 400.0]:
		var o := BoxMesh.new()
		o.size = Vector3(st, st * 0.5, st * 0.4)
		var inn := BoxMesh.new()
		inn.size = Vector3(st - 2.0, st * 0.5 - 2.0, st * 0.4 - 2.0)
		var xf := Transform3D(Basis.from_scale(Vector3(1.0, 2.5, 1.0)), Vector3(0.0, st * 0.5 * 2.5 * 0.5 + 0.01, 0.0))
		var m := _join(_tris(o, xf), _tris(inn, xf, true))
		var t0 := Time.get_ticks_usec()
		var hollow := SdfForm.mesh_cells(m[0], m[1], Vector3i.ZERO)
		var ms := (Time.get_ticks_usec() - t0) / 1000.0
		var skin1 := SdfForm.mesh_cells(o_tris(o, xf)[0], o_tris(o, xf)[1], Vector3i(1, 2, 1))
		print("  %5d   %8d (%8d)   %.0f" % [int(st), _count(hollow), _count(skin1), ms])
		# The hollow model and the solid one's skin are the same walls, give or take the plates
		# a stud rounds to (2 of 2.5).
		var r := float(_count(hollow)) / maxf(_count(skin1), 1.0)
		_check("%d studs: hollow model ~ solid's skin (%.2f)" % [int(st), r], r > 0.85 and r < 1.25)
	print("mesh_cells probe: %d ok, %d FAIL" % [_ok, _bad])
	quit(0 if _bad == 0 else 1)


func o_tris(m: PrimitiveMesh, xf: Transform3D) -> Array:
	return _tris(m, xf)
