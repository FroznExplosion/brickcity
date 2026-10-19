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

	print("sdf_form_probe: %d passed, %d failed" % [_passed, _failed])
	quit(1 if _failed > 0 else 0)
