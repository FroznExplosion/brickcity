extends SceneTree

## Acceptance probe for the standard part palette.
##
##     godot --headless --path . --script tools/palette_probe.gd
##
## What it is for: every part in BrickPalette is described by three integers,
## and its real-world proportions are supposed to follow from the grid rather
## than from anything anybody typed. This asserts that -- that the game grid and
## the print grid are the same system at two sizes, that every named part has
## the footprint its name claims, and that mass is a pure function of cell
## count. No rendering, no physics.

var _pass := 0
var _fail := 0


func _init() -> void:
	print("palette probe")
	var w := BrickWorld.new()
	var palette := BrickPalette.bake(w)

	_check_scale()
	_check_names(palette)
	_check_footprints(w, palette)
	_check_mass(w, palette)
	_check_studs(w, palette)
	_check_tiles(w, palette)

	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s" % what)
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


# ---------------------------------------------------------------------------
# The grid itself. Print scale and game scale must be the same system.
# ---------------------------------------------------------------------------

func _check_scale() -> void:
	print("\nscale")
	var stud := BrickPalette.STUD_M
	var plate := BrickPalette.PLATE_M
	var brick := plate * BrickPalette.PLATES_PER_BRICK

	# GDScript cannot read brick_grid.h, so pin the constants against the
	# extension rather than trusting two copies to stay equal.
	var w := BrickWorld.new()
	var one_stud: Vector3 = w.grid_to_world(Vector3i(1, 1, 1))
	_ok("game stud matches the extension", is_equal_approx(one_stud.x, stud),
			"%.4f vs %.4f" % [one_stud.x, stud])
	_ok("game plate matches the extension", is_equal_approx(one_stud.y, plate),
			"%.4f vs %.4f" % [one_stud.y, plate])
	_ok("x and z are both studs", is_equal_approx(one_stud.x, one_stud.z))

	# The two ratios that make a brick a brick.
	_ok("plate / stud is 0.4", is_equal_approx(plate / stud, 0.4),
			"%.6f" % (plate / stud))
	_ok("brick / stud is 1.2", is_equal_approx(brick / stud, 1.2),
			"%.6f" % (brick / stud))

	# ... and the print system has to have exactly the same two.
	var stud_mm := BrickPalette.STUD_MM
	var plate_mm := BrickPalette.PLATE_MM
	var brick_mm := plate_mm * BrickPalette.PLATES_PER_BRICK
	_ok("print plate / stud is 0.4", is_equal_approx(plate_mm / stud_mm, 0.4),
			"%.6f" % (plate_mm / stud_mm))
	_ok("print brick / stud is 1.2", is_equal_approx(brick_mm / stud_mm, 1.2),
			"%.6f" % (brick_mm / stud_mm))

	# One scale factor, not two. If these ever disagree, a part is the right
	# height and the wrong width and nothing in game will look obviously wrong.
	var by_stud := stud / (stud_mm * 0.001)
	var by_plate := plate / (plate_mm * 0.001)
	_ok("one scale factor on every axis", is_equal_approx(by_stud, by_plate),
			"stud x%.4f vs plate x%.4f" % [by_stud, by_plate])
	_ok("and it is 43.75 (Plan D6)", is_equal_approx(by_stud, 43.75), "%.4f" % by_stud)


# ---------------------------------------------------------------------------
# Every name has to describe its own footprint.
# ---------------------------------------------------------------------------

func _check_names(palette: Dictionary) -> void:
	print("\nnaming")

	# A PART is canonical: W <= L, family decides height, no axis suffix.
	for part in BrickPalette.parts():
		var size: Vector3i = BrickPalette.part_size(part)
		var bits: PackedStringArray = part.split("_")
		_ok("%s: no axis suffix on a part" % part, bits.size() == 2)
		var wl: PackedStringArray = bits[1].split("x")
		var w := int(wl[0])
		var l := int(wl[1])
		_ok("%s: W <= L in the name" % part, w <= l, "%dx%d" % [w, l])
		_ok("%s: canonical size matches the name" % part,
				size.x == w and size.z == l, "%v" % size)
		# A plate is one, a brick is three, and a COLUMN is six bricks -- the
		# gap between one floor and the next, so it stands on the floor below
		# and the floor above stands on it.
		var expect_y := 1
		if bits[0] in ["brick", "bracket", "slope", "curve", "round", "arch"]:
			expect_y = 3
		elif bits[0] == "column":
			expect_y = TowerRecipe.COLUMN_PLATES   # one storey: six courses
		elif bits[0] == "spiral":
			expect_y = 4   # two steps of two plates
		_ok("%s: %s is %d plate(s) tall" % [part, bits[0], expect_y], size.y == expect_y,
				"y = %d" % size.y)

	# An ARCHETYPE is a part plus an ORIENTATION, generated not written. Four
	# grid-legal ones per part -- two yaw states x upright/inverted -- collapsing
	# to two when the footprint is square, because yawing a square changes
	# nothing, and growing to eight when the part has a FRONT (a slope), because
	# then all four yaws are different parts.
	for part in BrickPalette.parts():
		var vars_: Array = BrickPalette.variants_of(part)
		var square: bool = BrickPalette.is_square(part)
		var directional: bool = BrickPalette.is_directional(part)
		var expect := 8 if directional else (2 if square else 4)
		_ok("%s: %d archetypes" % [part, expect], vars_.size() == expect, "%s" % [vars_])

		# Every variant resolves back to the part it came from.
		for v in vars_:
			_ok("%s: %s belongs to it" % [part, v], BrickPalette.part_of(v) == part,
					"got '%s'" % BrickPalette.part_of(v))

		# A flip never changes an extent -- that is exactly why it is grid-legal
		# where a sideways rotation is not.
		for v in vars_:
			if BrickPalette.is_inverted(v):
				var upright: String = v.substr(0, v.length() - 2)
				_ok("%s: inverting does not change the footprint" % v,
						BrickPalette.size_of(v) == BrickPalette.size_of(upright),
						"%v vs %v" % [BrickPalette.size_of(v), BrickPalette.size_of(upright)])

		if directional:
			var y0: Vector3i = BrickPalette.size_of(part + "_y0")
			var y1: Vector3i = BrickPalette.size_of(part + "_y1")
			_ok("%s: a quarter turn swaps the stud axes" % part,
					y1 == Vector3i(y0.z, y0.y, y0.x), "%v vs %v" % [y0, y1])
			_ok("%s: a half turn keeps the footprint" % part,
					BrickPalette.size_of(part + "_y2") == y0
					and BrickPalette.size_of(part + "_y3") == y1)
			continue
		if square:
			continue
		var sx: Vector3i = BrickPalette.size_of(part + "_x")
		var sz: Vector3i = BrickPalette.size_of(part + "_z")
		_ok("%s_x: long side runs along X" % part, sx.x > sx.z, "%v" % sx)
		_ok("%s_z: long side runs along Z" % part, sz.z > sz.x, "%v" % sz)
		_ok("%s: the two are the same part rotated" % part,
				sx == Vector3i(sz.z, sz.y, sz.x))
		_ok("%s: rotating does not change mass" % part,
				is_equal_approx(BrickPalette.mass_of(sx), BrickPalette.mass_of(sz)))

	_ok("an axis suffix on a square part resolves to nothing",
			BrickPalette.size_of("plate_2x2_x") == Vector3i.ZERO)

	_ok("every variant name was baked",
			BrickPalette.names().size() == palette.size(),
			"%d vs %d" % [BrickPalette.names().size(), palette.size()])


# ---------------------------------------------------------------------------
# What the extension actually baked, and what it measures.
# ---------------------------------------------------------------------------

func _check_footprints(w: BrickWorld, palette: Dictionary) -> void:
	print("\nfootprints")
	for name in BrickPalette.names():
		var id: int = palette[name]
		_ok("%s baked" % name, id >= 0)
		_ok("%s: extension agrees on size" % name,
				w.get_archetype_size(id) == BrickPalette.size_of(name),
				"%v vs %v" % [w.get_archetype_size(id), BrickPalette.size_of(name)])

	# Spot-check the two the request named, in metres and in millimetres.
	var b14 := BrickPalette.size_of("brick_1x4_x")
	_ok("1x4 brick is 4 studs long", b14.x == 4 and b14.z == 1)
	_ok("1x4 brick is 1.40 m x 0.42 m x 0.35 m in game",
			BrickPalette.extents_m(b14).is_equal_approx(Vector3(1.40, 0.42, 0.35)),
			"%v" % BrickPalette.extents_m(b14))
	_ok("1x4 brick is 32.0 x 9.6 x 8.0 mm at print scale",
			BrickPalette.extents_mm(b14).is_equal_approx(Vector3(32.0, 9.6, 8.0)),
			"%v" % BrickPalette.extents_mm(b14))

	# Both orientations of a 1x4 exist and are the same brick lying the other way.
	var b14z := BrickPalette.size_of("brick_1x4_z")
	_ok("1x4 brick has a Z orientation too", b14z == Vector3i(1, 3, 4), "%v" % b14z)
	_ok("and it is 0.35 m x 0.42 m x 1.40 m",
			BrickPalette.extents_m(b14z).is_equal_approx(Vector3(0.35, 0.42, 1.40)),
			"%v" % BrickPalette.extents_m(b14z))

	var p11 := BrickPalette.size_of("plate_1x1")
	_ok("a single stud is one cell", p11 == Vector3i(1, 1, 1))
	_ok("a single stud is 8.0 x 3.2 x 8.0 mm",
			BrickPalette.extents_mm(p11).is_equal_approx(Vector3(8.0, 3.2, 8.0)),
			"%v" % BrickPalette.extents_mm(p11))

	var b11 := BrickPalette.size_of("brick_1x1")
	_ok("a 1x1 brick is three plates", b11 == Vector3i(1, 3, 1))
	_ok("a 1x1 brick is exactly three 1x1 plates tall",
			is_equal_approx(BrickPalette.extents_m(b11).y,
					BrickPalette.extents_m(p11).y * 3.0))


# ---------------------------------------------------------------------------
# Mass is a pure function of cell count, anchored on the real 2x4.
# ---------------------------------------------------------------------------

func _check_mass(w: BrickWorld, palette: Dictionary) -> void:
	print("\nmass")
	var m24 := BrickPalette.mass_of(BrickPalette.size_of("brick_2x4_x"))
	_ok("a 2x4 brick is 2.4 g, which is the real hollow figure",
			is_equal_approx(m24, 2.4), "%.3f" % m24)

	# Mass tracks SOLID cells. For a box that is its whole volume; a shaped part
	# weighs only the cells its shape mostly fills.
	for name in BrickPalette.names():
		var size: Vector3i = BrickPalette.size_of(name)
		var solid: int = w.get_archetype_solid_cells(palette[name])
		var part := BrickPalette.part_of(name)
		_ok("%s: mass tracks solid cells" % name,
				is_equal_approx(BrickPalette.mass_of_part(part), solid * BrickPalette.MASS_PER_CELL),
				"%.2f vs %d cells" % [BrickPalette.mass_of_part(part), solid])
		if not BrickPalette.is_shaped(part):
			_ok("%s: a box is all solid" % name, solid == size.x * size.y * size.z)

	# The relationships that have to hold for a collapse to look right.
	var brick := BrickPalette.mass_of(BrickPalette.size_of("brick_2x2"))
	var plate := BrickPalette.mass_of(BrickPalette.size_of("plate_2x2"))
	_ok("a brick weighs exactly three of its own plate",
			is_equal_approx(brick, plate * 3.0), "%.3f vs %.3f" % [brick, plate * 3.0])
	_ok("a 2x4 weighs twice a 2x2",
			is_equal_approx(m24, brick * 2.0))
	_ok("a 1x6 weighs one and a half times a 1x4",
			is_equal_approx(BrickPalette.mass_of(BrickPalette.size_of("brick_1x6_x")),
					BrickPalette.mass_of(BrickPalette.size_of("brick_1x4_x")) * 1.5))


# ---------------------------------------------------------------------------
# Studs. A plate or a brick can be built on; a tile cannot. That distinction is
# the only thing separating a tile from the plate of the same size, so it is
# the thing worth asserting.
# ---------------------------------------------------------------------------

func _check_studs(w: BrickWorld, palette: Dictionary) -> void:
	print("\nstuds")
	# Tall enough to stack two of the tallest part: a column is 18 plates. Two
	# rows, because the palette no longer fits in one.
	var chunk := w.create_chunk(Vector3i.ZERO, Vector3i(128, 40, 24))
	var x := 0
	var z := 0
	var studded := 0
	var smooth := 0
	for part in BrickPalette.parts():
		var name: String = BrickPalette.variants_of(part)[0]
		var size: Vector3i = BrickPalette.size_of(name)
		if x + size.x > 128:
			x = 0
			z = 12   # clear of the 10x10s in the first row
		var lower := w.place_block(chunk, Vector3i(x, 0, z), palette[name], 0)
		var upper := w.place_block(chunk, Vector3i(x, size.y, z), palette[name], 0)
		_ok("%s: two of them stack" % part, lower >= 0 and upper >= 0)
		var joined: bool = w.get_block_neighbours(chunk, lower).has(upper)
		if BrickPalette.has_studs(part):
			_ok("%s: has studs, so the two are JOINED" % part, joined)
			if joined:
				studded += 1
		else:
			_ok("%s: studless, so the two are NOT joined" % part, not joined)
			if not joined:
				smooth += 1
		x += size.x + 1

	var expect_smooth := 0
	for part in BrickPalette.parts():
		if not BrickPalette.has_studs(part):
			expect_smooth += 1
	_ok("every studded part can be built on",
			studded == BrickPalette.parts().size() - expect_smooth,
			"%d" % studded)
	_ok("every studless part refuses a clip", smooth == expect_smooth, "%d of %d" % [smooth, expect_smooth])


# ---------------------------------------------------------------------------
# A tile is a plate that nothing clips to. Same solid volume, same mass, same
# footprint -- one bit of difference, and it is structural.
# ---------------------------------------------------------------------------

func _check_tiles(w: BrickWorld, palette: Dictionary) -> void:
	print("\ntiles")
	for part in BrickPalette.parts():
		if not part.begins_with("tile_"):
			continue
		var twin: String = "plate" + part.substr(4)
		_ok("%s: there is a plate of the same size" % part, BrickPalette.parts().has(twin))
		_ok("%s: same footprint as %s" % [part, twin],
				BrickPalette.part_size(part) == BrickPalette.part_size(twin))
		var tn: String = BrickPalette.variants_of(part)[0]
		var pn: String = BrickPalette.variants_of(twin)[0]
		_ok("%s: same solid volume as %s" % [part, twin],
				w.get_archetype_solid_cells(palette[tn])
					== w.get_archetype_solid_cells(palette[pn]))
		_ok("%s: still fills its box" % part, w.is_archetype_full_box(palette[tn]))

	# A tile takes a clip from BELOW -- it has sockets. Otherwise it could not be
	# laid on anything and would be useless as a finishing part.
	var chunk := w.create_chunk(Vector3i(0, 0, 64), Vector3i(16, 8, 8))
	var below := w.place_block(chunk, Vector3i(0, 0, 64), palette["brick_2x2"], 0)
	var tile := w.place_block(chunk, Vector3i(0, 3, 64), palette["tile_2x2"], 0)
	_ok("both placed", below >= 0 and tile >= 0)
	_ok("a tile laid ON a brick IS joined to it -- sockets underneath",
			w.get_block_neighbours(chunk, below).has(tile))
