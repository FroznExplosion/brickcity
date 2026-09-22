extends SceneTree

## Acceptance probe for drawn studs on brick chunks.
##
##     godot --headless --path . --script tools/stud_probe.gd
##
## `BrickWorld.get_chunk_studs` emits one instance per EXPOSED stud, in the same
## MultiMesh buffer layout BrickTerrain uses, so the workshop draws bricks' studs
## with terrain's stud mesh and material. The rule it keeps: a stud is drawn
## where a face offers one and the cell it would stand in is empty -- so a brick
## on top removes it, and destroying that brick brings it back.

var _pass := 0
var _fail := 0
const F := 16  ## floats per instance

var _ws
var _frames := 0


func _init() -> void:
	print("stud probe")
	_check_rule()
	_check_layout()
	_ws = load("res://scenes/workshop.tscn").instantiate()
	root.add_child(_ws)
	process_frame.connect(_tick)


func _tick() -> void:
	_frames += 1
	if _frames != 2:
		return
	_ws.set_process(false)
	_check_workshop()
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s" % what)
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _n(w: BrickWorld, c: int) -> int:
	@warning_ignore("integer_division")
	var n: int = w.get_chunk_studs(c).size() / F
	return n


func _check_rule() -> void:
	print("\nwhich studs are drawn")
	var w := BrickWorld.new()
	var p := BrickPalette.bake(w)
	var c := w.create_chunk(Vector3i.ZERO, Vector3i(16, 16, 16))
	_ok("an empty chunk draws none", _n(w, c) == 0)

	w.place_block(c, Vector3i(0, 0, 0), p["brick_2x4_x"], 4)
	_ok("a 2x4 draws eight", _n(w, c) == 8, "%d" % _n(w, c))

	var cover := w.place_block(c, Vector3i(0, 3, 0), p["brick_2x2"], 5)
	_ok("a 2x2 on half of it: four buried, four of its own -- still eight",
			_n(w, c) == 8, "%d" % _n(w, c))

	w.place_block(c, Vector3i(8, 0, 0), p["tile_2x2"], 5)
	_ok("a tile adds none", _n(w, c) == 8, "%d" % _n(w, c))

	w.place_block(c, Vector3i(8, 6, 8), p["brick_2x2_i"], 6)
	_ok("an inverted 2x2 in the air adds four, pointing down", _n(w, c) == 12,
			"%d" % _n(w, c))

	w.kill_block(c, Vector3i(0, 3, 0))
	_ok("destroying the covering brick brings the four under it back",
			_n(w, c) == 12, "%d" % _n(w, c))

	# An EDIT gives the cells back as well, so the same must hold for remove.
	var c2 := w.create_chunk(Vector3i.ZERO, Vector3i(16, 16, 16))
	w.place_block(c2, Vector3i(0, 0, 0), p["brick_2x2"], 4)
	var top := w.place_block(c2, Vector3i(0, 3, 0), p["plate_2x2"], 4)
	_ok("a plate on a 2x2: only the plate's four", _n(w, c2) == 4)
	w.remove_block(c2, top)
	_ok("removing it shows the 2x2's four again", _n(w, c2) == 4)
	_ok("and the plate's own are gone with it",
			(w.get_chunk_studs(c2) as PackedFloat32Array)[7] < 3.5 * BrickPalette.PLATE_M,
			"top y %.2f" % (w.get_chunk_studs(c2) as PackedFloat32Array)[7])
	var _unused := cover


func _check_layout() -> void:
	print("\nthe buffer is the engine's own layout")
	var w := BrickWorld.new()
	var p := BrickPalette.bake(w)
	var c := w.create_chunk(Vector3i.ZERO, Vector3i(8, 8, 8))
	w.place_block(c, Vector3i(2, 0, 3), p["brick_1x1"], 8)
	var b: PackedFloat32Array = w.get_chunk_studs(c)
	_ok("sixteen floats for one stud", b.size() == F, "%d" % b.size())
	# Origin is the 4th, 8th and 12th float: the centre of the cell's top face.
	_ok("x at the centre of its column", is_equal_approx(b[3], 2.5 * BrickPalette.STUD_M))
	_ok("y on the brick's top: three plates", is_equal_approx(b[7], 3.0 * BrickPalette.PLATE_M),
			"%.3f" % b[7])
	_ok("z at the centre of its column", is_equal_approx(b[11], 3.5 * BrickPalette.STUD_M))
	var col := BrickWorld.get_filament_colour(8)
	_ok("coloured like its brick", is_equal_approx(b[12], col.r) and is_equal_approx(b[13], col.g)
			and is_equal_approx(b[14], col.b))

	# A downward stud is turned 180 degrees about X -- a proper rotation, not a
	# mirror, or it renders inside out.
	var c2 := w.create_chunk(Vector3i.ZERO, Vector3i(8, 8, 8))
	w.place_block(c2, Vector3i(0, 3, 0), p["brick_1x1_i"], 8)
	var d: PackedFloat32Array = w.get_chunk_studs(c2)
	var basis := Basis(Vector3(d[0], d[4], d[8]), Vector3(d[1], d[5], d[9]), Vector3(d[2], d[6], d[10]))
	_ok("a downward stud points down", basis.y.is_equal_approx(Vector3(0, -1, 0)), "%v" % basis.y)
	_ok("and is a rotation, not a mirror", is_equal_approx(basis.determinant(), 1.0),
			"det %.2f" % basis.determinant())
	_ok("sitting on the underside", is_equal_approx(d[7], 3.0 * BrickPalette.PLATE_M), "%.3f" % d[7])


func _check_workshop() -> void:
	print("\nthe workshop draws them")
	var base: int = _ws._stud_count
	_ok("the baseplate alone has its full 48 x 48", base == 48 * 48, "%d" % base)

	_ws._part_index = BrickPalette.parts().find("brick_2x4")
	_ws._axis_z = false
	_ws._cell = Vector3i(10, 1, 10)
	_ws._update_ghost()
	_ws._place()
	_ok("a 2x4 on the baseplate buries eight and shows eight -- no change",
			_ws._stud_count == base, "%d vs %d" % [_ws._stud_count, base])

	_ws._part_index = BrickPalette.parts().find("tile_2x2")
	_ws._cell = Vector3i(20, 1, 20)
	_ws._update_ghost()
	_ws._place()
	_ok("a tile on the baseplate buries four and shows none",
			_ws._stud_count == base - 4, "%d vs %d" % [_ws._stud_count, base - 4])

	_ws._undo()
	_ok("undo puts them back", _ws._stud_count == base, "%d" % _ws._stud_count)

	var f0: int = _ws.asm.frames[0]
	var mmi: MultiMeshInstance3D = _ws._frame_studs.get(f0)
	_ok("they hang off the frame's own mesh, so a rotated frame turns them",
			mmi != null and mmi.get_parent() == _ws._frame_meshes.get(f0))
	_ok("and they cast no shadow",
			mmi != null and mmi.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)
