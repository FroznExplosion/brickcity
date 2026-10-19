extends SceneTree

## SdfForm (gdextension/brick/src/sdf_form.cpp), the asset workshop's SDF block-out:
## one signed distance field for the whole asset, a part label and a smooth flag on
## every sample (Docs/AssetWorkshop.md, "The SDF block-out"). Headless:
##
##     godot --headless --path . --script res://tools/sdf_form_probe.gd

var _passed := 0
var _failed := 0


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_passed += 1
		print("  ok   ", what)
	else:
		_failed += 1
		print("  FAIL ", what, "  ", detail)


## cells() as {Vector3i: part}.
static func _cell_map(c: PackedInt32Array) -> Dictionary:
	var out := {}
	for i in range(0, c.size(), 5):
		out[Vector3i(c[i], c[i + 1], c[i + 2])] = c[i + 3]
	return out


static func _cell_list(m: Dictionary) -> PackedInt32Array:
	var out := PackedInt32Array()
	for k in m:
		out.append_array([k.x, k.y, k.z, m[k], 0])
	return out


## Every block's surface as one mesh, corners in the same place welded.
static func _whole(f: SdfForm) -> Dictionary:
	var verts := PackedVector3Array()
	var index := PackedInt32Array()
	var normals := PackedVector3Array()
	var weld := {}
	var pal := PackedColorArray([Color.WHITE, Color.RED, Color.BLUE])
	for b in f.block_keys():
		var a: Array = f.mesh_block(b, pal)
		if a.is_empty():
			continue
		var v: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
		var n: PackedVector3Array = a[Mesh.ARRAY_NORMAL]
		var remap := PackedInt32Array()
		for i in v.size():
			var k := Vector3i((v[i] * 1024.0).round())
			if not weld.has(k):
				weld[k] = verts.size()
				verts.append(v[i])
				normals.append(n[i])
			remap.append(weld[k])
		for i in a[Mesh.ARRAY_INDEX]:
			index.append(remap[i])
	return {"v": verts, "n": normals, "i": index}


## Every edge in exactly two triangles, once each way.
static func _closed(index: PackedInt32Array) -> bool:
	var edges := {}
	for t in range(0, index.size(), 3):
		for k in 3:
			var e := Vector2i(index[t + k], index[t + (k + 1) % 3])
			if edges.has(e):
				return false
			edges[e] = true
	for e in edges:
		if not edges.has(Vector2i(e.y, e.x)):
			return false
	return true


## Round 3 (Docs/AssetWorkshop.md, "SDF tools, round 3"): catalogue pieces fitted to the
## field. A ramp at a slope's pitch gets slopes facing down it; a wall turned 45 degrees in
## plan gets wedges; a box on the grid gets nothing.
func _fit_checks() -> void:
	var kit := FitKit.kit(true)
	var tilt := atan2(4.0, 5.0)   # two plates a stud
	var f := SdfForm.new()
	f.shape(SdfForm.ADD, SdfForm.SHAPE_BOX, Transform3D(Basis(Vector3.BACK, tilt), Vector3(100, 60, 100)),
			Vector3(45, 14, 16), 0.0, 1)
	var got := _fit_names(f, kit)
	var down := 0
	for n in got:
		if String(n).begins_with("slope_") and not BrickPalette.is_inverted(n) 				and BrickPalette.front_of(n) == Vector3i(-1, 0, 0):
			down += 1
	_ok("a ramp at a slope's pitch gets slopes facing down it", down >= 3, "%d of %s" % [down, str(got)])
	f = SdfForm.new()
	f.shape(SdfForm.ADD, SdfForm.SHAPE_BOX, Transform3D(Basis(Vector3.UP, PI / 4), Vector3(100, 60, 100)),
			Vector3(21.213, 6, 21.213), 0.0, 1)
	got = _fit_names(f, kit)
	var wedges := got.filter(func(n: String) -> bool: return n.begins_with("wedge"))
	_ok("a wall turned 45 degrees in plan gets wedges", wedges.size() >= 4, str(got))
	f = SdfForm.new()
	f.box(SdfForm.ADD, Vector3(62.5, 56, 62.5), Vector3(12.5, 6, 12.5), 0.0, 1)
	got = _fit_names(f, kit)
	_ok("a box on the grid gets no pieces", got.is_empty(), str(got))


func _fit_names(f: SdfForm, kit: Dictionary) -> Array:
	var free := PackedInt32Array()
	var cs := f.cells()
	for i in range(0, cs.size(), 5):
		free.append_array([cs[i], cs[i + 1], cs[i + 2]])
	var fit := f.fit_pieces(free, kit.pieces, 0.08)
	var out := []
	for i in range(0, fit.size(), 4):
		out.append(kit.names[fit[i]])
	return out


## A lathe of a straight outline is the cylinder or cone a stamp makes.
func _lathe_checks() -> void:
	var at := Transform3D(Basis(), Vector3(60, 60, 60))
	var a := SdfForm.new()
	a.lathe(SdfForm.ADD, at, PackedVector2Array([Vector2(8, -10), Vector2(8, 10)]), 0.0, 1)
	var b := SdfForm.new()
	b.shape(SdfForm.ADD, SdfForm.SHAPE_CONE, at, Vector3(8, 10, 8), 0.0, 1)
	_ok("a lathe of a straight outline is a cylinder", _cell_map(a.cells()) == _cell_map(b.cells()),
			"%d vs %d cells" % [_cell_map(a.cells()).size(), _cell_map(b.cells()).size()])
	a = SdfForm.new()
	a.lathe(SdfForm.ADD, at, PackedVector2Array([Vector2(9, -10), Vector2(3, 10)]), 0.0, 1)
	b = SdfForm.new()
	b.shape(SdfForm.ADD, SdfForm.SHAPE_CONE, at, Vector3(9, 10, 3), 0.0, 1)
	_ok("and a slanted one a cone", _cell_map(a.cells()) == _cell_map(b.cells()),
			"%d vs %d cells" % [_cell_map(a.cells()).size(), _cell_map(b.cells()).size()])
	a.lathe(SdfForm.REMOVE, at, PackedVector2Array([Vector2(20, -20), Vector2(20, 20)]), 0.0, 1)
	_ok("a lathe carves", a.cells().is_empty())


func _init() -> void:
	print("sdf_form_probe")
	var c := Vector3(52.5, 51.0, 52.5) # the middle of cell (10, 25, 10)

	# A ball, across several blocks.
	var f := SdfForm.new()
	f.stroke(SdfForm.ADD, c, c, 12.0, 0.0, 1)
	var cells := _cell_map(f.cells())
	_ok("a ball's middle cell is solid, part 1", cells.get(Vector3i(10, 25, 10), -1) == 1)
	_ok("a ball 24 samples across is about 5 studs and 12 plates", cells.size() > 150 and cells.size() < 400, str(cells.size()))
	var bb := f.bounds()
	_ok("bounds are the ball's", absf(bb.size.x - 24.0) <= 1.0 and absf(bb.get_center().x - c.x) <= 1.0, str(bb))
	_ok("only blocks near it are stored", f.block_count() <= 27, str(f.block_count()))

	var m := _whole(f)
	_ok("the surface is closed across blocks", m.i.size() > 0 and _closed(m.i), str(m.i.size() / 3) + " tris")
	var out := 0
	var far := 0.0
	for i in m.v.size():
		var r: Vector3 = m.v[i] - c
		far = maxf(far, absf(r.length() - 12.0))
		if m.n[i].dot(r.normalized()) > 0.9:
			out += 1
	_ok("vertices on the sphere", far < 0.6, str(far))
	_ok("normals point out", out == m.v.size(), "%d/%d" % [out, m.v.size()])

	var hit = f.raycast(Vector3(c.x, c.y, 0.0), Vector3(0, 0, 1), 200.0)
	_ok("a ray hits the near side", hit != null and absf(hit.z - (c.z - 12.0)) < 0.2, str(hit))
	_ok("a ray past it misses", f.raycast(Vector3(c.x, c.y + 40.0, 0.0), Vector3(0, 0, 1), 200.0) == null)

	# Bricks back into the field: exactly the bricks synced come back out.
	var before := f.cells()
	var want := _cell_map(before)
	want.erase(Vector3i(10, 25, 10 - 2)) # a brick taken off the surface
	want.erase(Vector3i(10, 25, 10))     # one from the middle
	want[Vector3i(10, 25 + 13, 10)] = 2  # one stuck on top, another part
	want[Vector3i(18, 25, 10)] = 1       # one floating apart
	var some: Vector3i = want.keys()[3]
	want[some] = 2                       # one moved to part 2
	f.sync_cells(before, _cell_list(want))
	var got := _cell_map(f.cells())
	_ok("bricks -> field -> bricks is exact", got == want, "%d vs %d" % [got.size(), want.size()])
	var untouched := absf(f.sample(c + Vector3(0, 0, 12.0)))
	_ok("the smooth side not edited stays where it was", untouched < 0.3, str(untouched))

	# A bricks-only asset into an empty field.
	var g := SdfForm.new()
	g.sync_cells(PackedInt32Array(), _cell_list(want))
	_ok("a bricks-only asset goes in exactly", _cell_map(g.cells()) == want)

	# Undo and redo.
	var keep := f.cells()
	f.begin_edit()
	f.stroke(SdfForm.REMOVE, c, c + Vector3(0, 0, 20), 5.0, 2.0, 0)
	var undo := f.end_edit()
	_ok("a carve changes the bricks", f.cells() != keep)
	var carved := f.cells()
	var redo := f.swap_blocks(undo)
	_ok("undo puts them back", f.cells() == keep)
	f.swap_blocks(redo)
	_ok("redo carves again", f.cells() == carved)
	_ok("dirty blocks are reported", f.take_dirty().size() > 0 and f.take_dirty().is_empty())

	# Saved and loaded.
	var h := SdfForm.new()
	_ok("loads what it saved", h.from_bytes(f.to_bytes()) and h.cells() == f.cells())
	_ok("refuses junk", not h.from_bytes(PackedByteArray([1, 2, 3])))

	# A mesh as a solid: a box two cells each way, on the cells' lines.
	var bm := BoxMesh.new()
	bm.size = Vector3(10, 4, 10)
	var arr := bm.get_mesh_arrays()
	var bv: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	for i in bv.size():
		bv[i] += Vector3(25, 10, 25) # cells (4..5, 4..5, 4..5)
	var s := SdfForm.new()
	s.stamp_mesh(SdfForm.ADD, bv, arr[Mesh.ARRAY_INDEX], 3)
	var sc := _cell_map(s.cells())
	var box_ok := sc.size() == 8
	for k in sc:
		box_ok = box_ok and k.x in [4, 5] and k.y in [4, 5] and k.z in [4, 5] and sc[k] == 3
	_ok("a box mesh is its eight cells", box_ok, str(sc))

	# Scaled.
	var big := SdfForm.new()
	big.stroke(SdfForm.ADD, c, c, 12.0, 0.0, 1)
	var b0 := _cell_map(big.cells()).size()
	big.scale(2.0, c)
	var b1 := _cell_map(big.cells()).size()
	_ok("twice the size is about eight times the bricks", b1 > b0 * 6 and b1 < b0 * 10, "%d -> %d" % [b0, b1])
	big.blur(2)
	_ok("blurred stays about the same", absf(_cell_map(big.cells()).size() - b1) < b1 * 0.1)
	# Two balls apart apart, halved: no blocks in the empty space between (it once filled the
	# whole box round them, and ran out of memory on a long sculpt).
	var apart := SdfForm.new()
	apart.stroke(SdfForm.ADD, c, c, 6.0, 0.0, 1)
	apart.stroke(SdfForm.ADD, c + Vector3(0, 0, 2000), c + Vector3(0, 0, 2000), 6.0, 0.0, 1)
	var ab := apart.block_count()
	apart.scale(0.5, c)
	_ok("scaled down, empty space stays empty", apart.block_count() <= ab and apart.cells().size() > 0,
			"%d -> %d blocks" % [ab, apart.block_count()])

	# Shapes placed by a transform (stamps): a box like `box`, a cylinder, a cone.
	var sb := SdfForm.new()
	sb.shape(SdfForm.ADD, SdfForm.SHAPE_BOX, Transform3D(Basis(), c), Vector3(10, 4, 5), 0.0, 1)
	var bx := SdfForm.new()
	bx.box(SdfForm.ADD, c, Vector3(10, 4, 5), 0.0, 1)
	_ok("a placed box is the same as a box", sb.cells() == bx.cells() and sb.cells().size() > 0)
	var turned := SdfForm.new()
	turned.shape(SdfForm.ADD, SdfForm.SHAPE_BOX, Transform3D(Basis(Vector3.UP, PI / 2), c), Vector3(5, 4, 10), 0.0, 1)
	_ok("and turned a quarter, the same cells", _cell_map(turned.cells()) == _cell_map(bx.cells()))
	var cyl := SdfForm.new()
	cyl.shape(SdfForm.ADD, SdfForm.SHAPE_CONE, Transform3D(Basis(Vector3.BACK, PI / 2), c), Vector3(6, 20, 6), 0.0, 1)
	var cone := SdfForm.new()
	cone.shape(SdfForm.ADD, SdfForm.SHAPE_CONE, Transform3D(Basis(Vector3.BACK, PI / 2), c), Vector3(6, 20, 0), 0.0, 1)
	var nc := _cell_map(cyl.cells()).size()
	var nk := _cell_map(cone.cells()).size()
	var lying := cyl.sample(c + Vector3(18, 0, 0)) < 0.0 and cyl.sample(c + Vector3(0, 10, 0)) > 0.0
	_ok("a cylinder lies along its turned axis; a cone is about a third of it", lying and nk > nc / 5 and nk < nc / 2,
			"%d cylinder, %d cone cells" % [nc, nk])

	# Flatten: a ball's top cut flat at a plane through it.
	var fl := SdfForm.new()
	fl.stroke(SdfForm.ADD, c, c, 10.0, 0.0, 1)
	fl.flatten(c + Vector3(0, 6, 0), 8.0, Vector3.UP, c + Vector3(0, 5, 0), 1.0, 1)
	var flat_top := fl.sample(c + Vector3(0, 7, 0)) > 0.0 and fl.sample(c + Vector3(0, 4, 0)) < 0.0 \
			and absf(fl.sample(c + Vector3(1.5, 5, 0))) < 0.6
	_ok("flatten cuts the top flat at the plane", flat_top, "%.2f %.2f" % [fl.sample(c + Vector3(0, 7, 0)),
			fl.sample(c + Vector3(1.5, 5, 0))])

	# Grow and shrink.
	var gr := SdfForm.new()
	gr.stroke(SdfForm.ADD, c, c, 8.0, 0.0, 1)
	var g0 := _cell_map(gr.cells()).size()
	gr.stroke(SdfForm.GROW, c, c, 14.0, 2.0, 1)
	var g1 := _cell_map(gr.cells()).size()
	gr.stroke(SdfForm.GROW, c, c, 14.0, -2.0, 1)
	var g2 := _cell_map(gr.cells()).size()
	_ok("grow swells it, shrink takes it back", g1 > g0 and absi(g2 - g0) <= g0 / 10, "%d -> %d -> %d" % [g0, g1, g2])

	# Two parts joined: each part's field ends where its label does.
	var t := SdfForm.new()
	t.box(SdfForm.ADD, Vector3(20, 10, 10), Vector3(10, 4, 5), 0.0, 1)
	t.box(SdfForm.ADD, Vector3(40, 10, 10), Vector3(10, 4, 5), 0.0, 2)
	var pf := t.part_field(1, Vector3i(0, 0, 0), Vector3i(60, 20, 20))
	var at := func(x: int) -> float: return pf[x + 60 * (10 + 20 * 10)]
	_ok("part 1's field is inside on its side", at.call(20) < 0.0)
	_ok("and outside on part 2's", at.call(40) > 0.0)
	var parts := {}
	for v in _cell_map(t.cells()).values():
		parts[v] = true
	_ok("cells carry both parts", parts.has(1) and parts.has(2))

	# Paint and smooth marks.
	t.stroke(SdfForm.PAINT, Vector3(15, 10, 10), Vector3(15, 10, 10), 3.0, 0.0, 2)
	_ok("paint relabels", t.part_near(Vector3(15.5, 10.5, 10.5)) == 2)
	t.box(SdfForm.MARK, Vector3(40, 10, 10), Vector3(10, 4, 5), 0.0, 0)
	var flagged := 0
	var tc := t.cells()
	for i in range(0, tc.size(), 5):
		flagged += tc[i + 4]
	_ok("marked cells carry the smooth flag", flagged > 0 and flagged < tc.size() / 5)

	_fit_checks()
	_lathe_checks()
	print("sdf_form_probe: %d passed, %d failed" % [_passed, _failed])
	quit(1 if _failed > 0 else 0)
