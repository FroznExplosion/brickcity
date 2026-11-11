extends SceneTree
## Colour from a model through the clay to bricks and back (Docs/AssetWorkshop.md,
## "Colour from model to bricks").
##
##     godot --headless --path . --script res://tools/probes/sdf_colour_probe.gd
##
##   oklab      ColourMatch: white is L 1, black L 0; pure red matches the filament red
##   model      a material's albedo and vertex colours reach the flattened mesh's COLOR
##   stamped    a box stamped with a red top and a blue bottom: the top cells vote red,
##              the bottom blue -- the colour seen, from the skin
##   deep       a box thicker than the band: its middle cells (no sample near a face) take
##              the nearest surface colour, not none
##   brush      clay drawn with no colour has none (its part's); with set_colour, that one
##   drawn      the surface mesh is drawn in the clay's colours, in its part's with them off
##   bricks     cells synced back with brick colours vote those colours again (Make bricks
##              after Bricks to clay keeps the colours)
##   palette    an area's palette: votes only among its colours
##   saves      to_bytes / from_bytes keep colours; an "SDF1" save (before colours) loads

var _pass := 0
var _fail := 0


func _initialize() -> void:
	print("sdf colour probe")
	_run()
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _ok(what: String, cond: bool, detail := "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


const RED := Color(0.9, 0.1, 0.1)
const BLUE := Color(0.1, 0.2, 0.85)


func _run() -> void:
	# --- ColourMatch
	var w := ColourMatch.oklab(Color.WHITE)
	var k := ColourMatch.oklab(Color.BLACK)
	_ok("oklab: white L 1, black L 0", absf(w.x - 1.0) < 0.01 and absf(k.x) < 0.01, "%s %s" % [w, k])
	var red_i := ColourMatch.nearest(RED)
	var blue_i := ColourMatch.nearest(BLUE)
	_ok("nearest filament: red and blue differ, each looks like itself",
			red_i != blue_i and ColourMatch.difference(BrickWorld.get_material_colour(0, red_i), RED) < 0.15
			and ColourMatch.difference(BrickWorld.get_material_colour(0, blue_i), BLUE) < 0.15,
			"red %d %s, blue %d %s" % [red_i, BrickWorld.get_material_colour_name(0, red_i), blue_i,
			BrickWorld.get_material_colour_name(0, blue_i)])

	# --- ModelMesh: material albedo x vertex colour into COLOR
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	var arr := bm.get_mesh_arrays()
	var vc := PackedColorArray()
	vc.resize((arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size())
	vc.fill(Color(0.5, 1.0, 1.0))
	arr[Mesh.ARRAY_COLOR] = vc
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.2, 0.2)
	mat.vertex_color_use_as_albedo = true
	am.surface_set_material(0, mat)
	mi.mesh = am
	var root := Node3D.new()
	root.add_child(mi)
	var flat := ModelMesh.flatten(root)
	var fc = flat.surface_get_arrays(0)[Mesh.ARRAY_COLOR] if flat != null else null
	var want := Color(0.5, 0.2, 0.2)
	_ok("model: albedo x vertex colour reach the mesh", fc != null and (fc as PackedColorArray).size() > 0
			and ColourMatch.difference((fc as PackedColorArray)[0], want) < 0.01,
			str((fc as PackedColorArray)[0]) if fc != null and (fc as PackedColorArray).size() > 0 else "no COLOR")
	root.free()

	# --- stamped: a box, top half red, bottom half blue (each face its own corners)
	var f := SdfForm.new()
	var soup := _box_soup(Vector3(5, 2, 5), Vector3(35, 22, 35))   # 6 x 10 x 6 cells
	f.stamp_mesh(SdfForm.ADD, soup[0], soup[1], 1, soup[2])
	var cells := f.cells()
	var pal := ColourMatch.colours(0, ColourMatch.indices(0))
	var cc := f.cell_colours(pal)
	var top_ok := 0
	var bot_ok := 0
	var top_n := 0
	var bot_n := 0
	var none := 0
	for i in cc.size():
		var y := cells[i * 5 + 1]
		if cc[i] < 0:
			none += 1
		if y >= 8:
			top_n += 1
			top_ok += int(cc[i] == red_i)
		elif y <= 2:
			bot_n += 1
			bot_ok += int(cc[i] == blue_i)
	_ok("stamped: top cells red, bottom blue", top_n > 0 and bot_n > 0 and top_ok == top_n and bot_ok == bot_n,
			"%d cells, top %d/%d red, bottom %d/%d blue" % [cells.size() / 5, top_ok, top_n, bot_ok, bot_n])

	# --- deep: a box much thicker than the band
	var g := SdfForm.new()
	var s2 := _box_soup(Vector3(0, 0, 0), Vector3(60, 40, 60), RED, RED)   # 12 x 20 x 12 cells
	g.stamp_mesh(SdfForm.ADD, s2[0], s2[1], 1, s2[2])
	var gc := g.cell_colours(pal)
	var g_cells := g.cells()
	var mid_red := false
	var all_col := true
	for i in gc.size():
		all_col = all_col and gc[i] == red_i
		if g_cells[i * 5] == 6 and g_cells[i * 5 + 1] == 10 and g_cells[i * 5 + 2] == 6:
			mid_red = gc[i] == red_i
	_ok("deep: the middle takes the surface's colour", mid_red and all_col, "%d cells" % gc.size())
	_ok("stamped: none left without a colour", none == 0, "%d without" % none)

	# --- brush
	var h := SdfForm.new()
	h.stroke(SdfForm.ADD, Vector3(20, 20, 20), Vector3(20, 20, 20), 8.0, 0.0, 1)
	var hc := h.cell_colours(pal)
	var hn := 0
	for v in hc:
		hn += int(v < 0)
	_ok("brush: no colour by default", hc.size() > 0 and hn == hc.size(), "%d/%d none" % [hn, hc.size()])
	h.set_colour(BLUE)
	h.stroke(SdfForm.ADD, Vector3(50, 20, 20), Vector3(50, 20, 20), 8.0, 0.0, 1)
	h.set_colour(Color(0, 0, 0, 0))
	var hcells := h.cells()
	hc = h.cell_colours(pal)
	var blue_n := 0
	var right_n := 0
	for i in hc.size():
		if hcells[i * 5] >= 8:
			right_n += 1
			blue_n += int(hc[i] == blue_i)
	_ok("brush: set_colour's colour", right_n > 0 and blue_n == right_n, "%d/%d blue" % [blue_n, right_n])
	h.set_colour(RED)
	h.stroke(SdfForm.COLOUR, Vector3(20, 20, 20), Vector3(20, 20, 20), 12.0, 0.0, 1)
	hc = h.cell_colours(pal)
	var painted := 0
	var left_n := 0
	for i in hc.size():
		if hcells[i * 5] < 8:
			left_n += 1
			painted += int(hc[i] == red_i)
	_ok("brush: COLOUR repaints", left_n > 0 and painted == left_n, "%d/%d red" % [painted, left_n])

	# --- drawn
	var drawn_red := false
	var drawn_part := false
	var ppal := PackedColorArray([Color.GRAY, Color.GREEN])
	for b in f.block_keys():
		var a: Array = f.mesh_block(b, ppal)
		if not a.is_empty():
			for c in (a[Mesh.ARRAY_COLOR] as PackedColorArray):
				drawn_red = drawn_red or ColourMatch.difference(c, RED) < 0.08
		var a2: Array = f.mesh_block(b, ppal, false)
		if not a2.is_empty():
			drawn_part = drawn_part or (a2[Mesh.ARRAY_COLOR] as PackedColorArray)[0].is_equal_approx(Color.GREEN)
	_ok("drawn: in the clay's colours, in its part's with them off", drawn_red and drawn_part)

	# --- bricks back: synced cells with brick colours
	var e := SdfForm.new()
	var list := PackedInt32Array()
	var cols := PackedColorArray()
	for x in 4:
		for y in 3:
			list.append_array([x, y, 0, 1, 0])
			cols.append(BrickWorld.get_material_colour(0, red_i if x < 2 else blue_i))
	e.sync_cells(PackedInt32Array(), list, cols)
	var ec := e.cell_colours(pal)
	var ecells := e.cells()
	var match_n := 0
	for i in ec.size():
		match_n += int(ec[i] == (red_i if ecells[i * 5] < 2 else blue_i))
	_ok("bricks: synced colours vote back the same", ec.size() == 12 and match_n == 12,
			"%d/%d of %d" % [match_n, ec.size(), 12])

	# --- palette: only an area's colours
	var area := PackedInt32Array([blue_i, 0])
	var ai := ColourMatch.indices(0, area)
	var ac := f.cell_colours(ColourMatch.colours(0, ai))
	var in_area := true
	for v in ac:
		in_area = in_area and v >= 0 and v < ai.size()
	_ok("palette: votes only among the area's", ai.size() == 2 and in_area, str(ai))

	# --- saves
	var bytes := f.to_bytes()
	var f2 := SdfForm.new()
	var loaded := f2.from_bytes(bytes)
	_ok("saves: colours kept", loaded and f2.cell_colours(pal) == cc)
	var v1 := _as_v1(bytes)
	var f3 := SdfForm.new()
	var old_ok := f3.from_bytes(v1)
	var c3 := f3.cell_colours(pal)
	var none3 := 0
	for v in c3:
		none3 += int(v < 0)
	_ok("saves: an SDF1 save loads, shape kept, no colours", old_ok and f3.cells() == cells and none3 == c3.size(),
			"%d bytes -> %d" % [bytes.size(), v1.size()])


## A box's twelve triangles, every face its own corners: faces above the middle `top`,
## below it `bottom` (the side faces split in two along the middle).
func _box_soup(lo: Vector3, hi: Vector3, top := RED, bottom := BLUE) -> Array:
	var v := PackedVector3Array()
	var c := PackedColorArray()
	var mid := (lo.y + hi.y) * 0.5
	var quads := []
	# Top and bottom.
	quads.append([Vector3(lo.x, hi.y, lo.z), Vector3(lo.x, hi.y, hi.z), Vector3(hi.x, hi.y, hi.z), Vector3(hi.x, hi.y, lo.z), top])
	quads.append([Vector3(lo.x, lo.y, lo.z), Vector3(hi.x, lo.y, lo.z), Vector3(hi.x, lo.y, hi.z), Vector3(lo.x, lo.y, hi.z), bottom])
	for half in [[mid, hi.y, top], [lo.y, mid, bottom]]:
		var y0: float = half[0]
		var y1: float = half[1]
		var col: Color = half[2]
		quads.append([Vector3(lo.x, y0, lo.z), Vector3(lo.x, y1, lo.z), Vector3(hi.x, y1, lo.z), Vector3(hi.x, y0, lo.z), col])
		quads.append([Vector3(lo.x, y0, hi.z), Vector3(hi.x, y0, hi.z), Vector3(hi.x, y1, hi.z), Vector3(lo.x, y1, hi.z), col])
		quads.append([Vector3(lo.x, y0, lo.z), Vector3(lo.x, y0, hi.z), Vector3(lo.x, y1, hi.z), Vector3(lo.x, y1, lo.z), col])
		quads.append([Vector3(hi.x, y0, lo.z), Vector3(hi.x, y1, lo.z), Vector3(hi.x, y1, hi.z), Vector3(hi.x, y0, hi.z), col])
	for q in quads:
		for t in [[0, 1, 2], [0, 2, 3]]:
			for j in t:
				v.append(q[j])
				c.append(q[4])
	var idx := PackedInt32Array()
	for i in v.size():
		idx.append(i)
	return [v, idx, c]


## The same save as an "SDF1" one: the magic, and every block without its colours.
func _as_v1(b: PackedByteArray) -> PackedByteArray:
	const B3 := 16 * 16 * 16
	const V1 := B3 * 6
	const V2 := B3 * 10
	var out := PackedByteArray()
	out.resize(8)
	out.encode_u32(0, 0x31464453)
	var n := b.decode_s32(4)
	out.encode_s32(4, n)
	var at := 8
	for e in n:
		out.append_array(b.slice(at, at + 8 + V1))
		at += 8 + V2
	return out
