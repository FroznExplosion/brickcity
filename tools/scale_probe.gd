extends SceneTree

## Is everything measured on the same ruler, and is that ruler a real brick's?
##
##     godot --headless --path . --script tools/scale_probe.gd
##
## Three questions, in order:
##
##   1. ONE GRID. The extension owns the stud and plate (brick_grid.h); every
##      script that keeps its own copy -- because a GDScript `const` cannot call
##      into the extension -- must hold the same number. The city, the terrain,
##      the workshop and the walking figure all read one of these copies.
##   2. REAL BRICKS. That grid, divided by the game scale, is a real brick's
##      grid: 8.0 mm pitch, 3.2 mm plate, 9.6 mm brick, and the 1.6 mm unit
##      they are all whole multiples of. Numbers from a measured 3001 2x4
##      (Bartneck 2019) and the LEGO brand manual, 2013. Docs/Parts/README.md.
##   3. A FIGURE'S WORLD. What a person-sized figure needs from a building, at
##      the same scale: a real minifigure is 4 bricks tall without its head
##      stud, 2 studs wide and 1 deep. This is about SIZE only. The legal brief
##      rules out the minifigure's shape; nothing here models one.
##
## Parts 1 and 2 fail the run when they are wrong. Part 3 is a design choice
## that has not been made yet, so it reports and does not fail.

var _pass := 0
var _fail := 0

## Game metres per print millimetre: 0.35 m / 8.0 mm.
const SCALE := 43.75
const MM := 0.001


func _init() -> void:
	print("scale probe")
	_one_grid()
	_real_bricks()
	_figure()
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s" % what)
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _note(what: String) -> void:
	print("  NOTE %s" % what)


func _near(a: float, b: float, eps := 1e-5) -> bool:
	return absf(a - b) <= eps


func _one_grid() -> void:
	print("\n1. one grid, every copy of it the same")
	var stud := BrickWorld.get_stud_metres()
	var plate := BrickWorld.get_plate_metres()
	_ok("extension: stud 0.35 m, plate 0.14 m", _near(stud, 0.35) and _near(plate, 0.14),
			"%f / %f" % [stud, plate])
	var copies := {
		"BrickPalette": [BrickPalette.STUD_M, BrickPalette.PLATE_M],
		"PieceMeshes": [PieceMeshes.STUD, PieceMeshes.PLATE],
		"ShapedParts": [ShapedParts.S, ShapedParts.P],
	}
	for path in ["res://scripts/building_shell.gd", "res://scripts/build_shell.gd"]:
		var sc: GDScript = load(path)
		var k := sc.get_script_constant_map()
		copies[path.get_file()] = [k.get("STUD", -1.0), k.get("PLATE", -1.0)]
	var cam: GDScript = load("res://scripts/debug_camera.gd")
	var ck := cam.get_script_constant_map()
	copies["debug_camera.gd"] = [stud, ck.get("PLATE_M", -1.0)]
	for name in copies:
		var c: Array = copies[name]
		_ok("%s agrees" % name, _near(c[0], stud) and _near(c[1], plate), "%s" % [c])
	_ok("a brick is three plates", BrickPalette.PLATES_PER_BRICK == 3)
	_ok("the tick lattice: 5 a stud, 2 a plate", BrickWorld.ticks_per_stud() == 5
			and BrickWorld.ticks_per_plate() == 2)


func _real_bricks() -> void:
	print("\n2. the grid is a real brick's grid, x%s" % SCALE)
	var stud := BrickWorld.get_stud_metres()
	var plate := BrickWorld.get_plate_metres()
	_ok("stud pitch 8.0 mm", _near(stud / SCALE / MM, 8.0), "%.3f" % (stud / SCALE / MM))
	_ok("plate 3.2 mm", _near(plate / SCALE / MM, 3.2), "%.3f" % (plate / SCALE / MM))
	_ok("brick 9.6 mm", _near(plate * 3.0 / SCALE / MM, 9.6))
	_ok("the same scale on both axes (no squash)", _near(stud / 8.0, plate / 3.2))
	var tick := stud / BrickWorld.ticks_per_stud()
	_ok("one tick is the real 1.6 mm unit", _near(tick / SCALE / MM, 1.6),
			"%.3f mm" % (tick / SCALE / MM))
	_ok("print constants in the palette match", _near(BrickPalette.STUD_MM, 8.0)
			and _near(BrickPalette.PLATE_MM, 3.2))
	var d := PieceMeshes.STUD_R * 2.0 / SCALE / MM
	var h := PieceMeshes.STUD_H / SCALE / MM
	_ok("drawn stud: 4.8 mm across", absf(d - 4.8) < 0.05, "%.2f mm" % d)
	_ok("drawn stud: 1.7 mm tall", absf(h - 1.7) < 0.05, "%.2f mm" % h)


func _figure() -> void:
	print("\n3. a person-sized figure, at the same scale (size only, never the shape)")
	var cam: GDScript = load("res://scripts/debug_camera.gd")
	var k := cam.get_script_constant_map()
	var brick := BrickWorld.get_plate_metres() * 3.0
	var body: float = k.get("BODY_HEIGHT", 0.0)
	var radius: float = k.get("BODY_RADIUS", 0.0)
	# 4 bricks without the head stud (38.4 mm), 15.4 x 7.8 mm through the hips.
	var fig_h := 38.4 * MM * SCALE
	var fig_w := 15.4 * MM * SCALE
	print("         walking figure: %.2f m tall (%.2f bricks), %.2f m wide" % [
			body, body / brick, radius * 2.0])
	print("         minifig-sized:  %.2f m tall (4.00 bricks), %.2f m wide" % [fig_h, fig_w])
	var ok_spec := body / brick >= 3.0 - 1e-3 and body / brick <= 5.0 + 1e-3
	if ok_spec:
		_ok("figure is within the spec's 3-5 bricks", true)
	else:
		_note("figure is %.2f bricks; the spec (section 3) asks for 3-5" % (body / brick))
	var tower: GDScript = load("res://scripts/tower_recipe.gd")
	var tk := tower.get_script_constant_map()
	var storey: int = tk.get("COURSES_PER_FLOOR", 0)
	print("         storey: %d courses = %.2f m floor to floor" % [storey, storey * brick])
	if storey < 5:
		_note("a %d-course storey is under what a 4-brick figure needs (4 bricks clear + floor)"
				% storey)
