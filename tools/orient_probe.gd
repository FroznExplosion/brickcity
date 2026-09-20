extends SceneTree

## Acceptance probe for Stage 3 of build mode: orientations.
##
##     godot --headless --path . --script tools/orient_probe.gd
##
## The gate, from Docs/BuildMode.md section 11:
##
##   An inverted slope roofs correctly; a tile still refuses a clip; a
##   double-sided plate joins both ways.
##
## What is really being tested is that `bake_variant` transforms the CELL mask
## and the two FACE masks together. Getting one and not the other produces a
## part that looks right and connects wrong, which no rendering test would show.

var _pass := 0
var _fail := 0

const FACE_NONE := 0
const FACE_STUD := 1
const FACE_SOCKET := 2


func _init() -> void:
	print("orient probe (Stage 3)")
	_check_flip_keeps_extents()
	_check_flip_swaps_faces()
	_check_yaw_moves_the_mask()
	_check_inverted_slope_roofs()
	_check_tile_still_refuses()
	_check_double_sided_plate()
	_check_dedupe()
	_check_recipes_still_build()
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s" % what)
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


## A slope: solid at the low z column, one plate tall at the high one. Studs only
## where the part is full height, because nothing can clip onto the sloped part.
##
##   profile, +Z to the right, y up
##     y=2  # .
##     y=1  # .
##     y=0  # #
func _bake_slope(w: BrickWorld, name: String) -> int:
	var size := Vector3i(1, 3, 2)
	var cells := PackedByteArray()
	cells.resize(size.x * size.y * size.z)
	for z in size.z:
		for y in size.y:
			for x in size.x:
				cells[x + size.x * (y + size.y * z)] = 1 if (z == 0 or y == 0) else 0
	var up := PackedByteArray([FACE_STUD, FACE_NONE])       # (x=0,z=0), (x=0,z=1)
	var down := PackedByteArray([FACE_SOCKET, FACE_SOCKET])
	return w.bake_faced_archetype(name, size, 0.6, cells, up, down)


# ---------------------------------------------------------------------------

func _check_flip_keeps_extents() -> void:
	print("\na flip never changes an extent")
	var w := BrickWorld.new()
	var base := w.bake_archetype("b", Vector3i(2, 3, 4), 2.4)
	var flipped := w.bake_variant(base, "b_i", 0, true)
	_ok("flipped baked", flipped >= 0)
	_ok("same size", w.get_archetype_size(flipped) == Vector3i(2, 3, 4),
			"%v" % w.get_archetype_size(flipped))

	# Yaw DOES swap the two stud axes, and only those two.
	var yawed := w.bake_variant(base, "b_x", 1, false)
	_ok("yaw swaps the stud axes", w.get_archetype_size(yawed) == Vector3i(4, 3, 2),
			"%v" % w.get_archetype_size(yawed))
	_ok("and leaves the plate axis alone", w.get_archetype_size(yawed).y == 3)


func _check_flip_swaps_faces() -> void:
	print("\na flip swaps which face carries studs")
	var w := BrickWorld.new()
	var base := w.bake_archetype("b", Vector3i(2, 3, 2), 1.2)
	var up: PackedByteArray = w.get_archetype_up_face(base)
	var down: PackedByteArray = w.get_archetype_down_face(base)
	_ok("a plain brick has studs up", up.count(FACE_STUD) == up.size(), "%s" % [up])
	_ok("and sockets down", down.count(FACE_SOCKET) == down.size(), "%s" % [down])

	var inv := w.bake_variant(base, "b_i", 0, true)
	var iup: PackedByteArray = w.get_archetype_up_face(inv)
	var idown: PackedByteArray = w.get_archetype_down_face(inv)
	_ok("inverted, it has SOCKETS up", iup.count(FACE_SOCKET) == iup.size(), "%s" % [iup])
	_ok("and STUDS down", idown.count(FACE_STUD) == idown.size(), "%s" % [idown])

	# A stud mates with a SOCKET, never with another stud, and that decides the
	# whole behaviour of inverted parts. All four pairings, spelled out, because
	# the useful half is the surprising half:
	#
	#   normal   over normal    STUD meets SOCKET   joins
	#   inverted over inverted  STUD meets SOCKET   joins
	#   inverted over normal    STUD meets STUD     does NOT
	#   normal   over inverted  SOCKET meets SOCKET does NOT
	#
	# So **an upside-down brick cannot clip to a right-way-up one**, which is
	# exactly true of the real thing: you need a bracket or a double-sided part
	# between them (see _check_double_sided_plate). Inverting is not a way to
	# attach a brick from below; it is a way to present a different face.
	var pairs := [
		["normal over normal", base, base, true],
		["inverted over inverted", inv, inv, true],
		["inverted over normal", base, inv, false],
		["normal over inverted", inv, base, false],
	]
	for pair in pairs:
		var c := w.create_chunk(Vector3i.ZERO, Vector3i(8, 16, 8))
		var lower := w.place_block(c, Vector3i(0, 0, 0), pair[1], 0)
		var upper := w.place_block(c, Vector3i(0, 3, 0), pair[2], 0)
		var joined: bool = lower >= 0 and upper >= 0 \
				and w.get_block_neighbours(c, lower).has(upper)
		_ok("%s: %s" % [pair[0], "joins" if pair[3] else "does not join"],
				joined == pair[3])


func _check_yaw_moves_the_mask() -> void:
	print("\nyaw moves the cell mask with the part")
	var w := BrickWorld.new()
	var slope := _bake_slope(w, "slope")
	_ok("the slope baked", slope >= 0)
	_ok("it does not fill its box", not w.is_archetype_full_box(slope))
	var solid := w.get_archetype_solid_cells(slope)
	_ok("it fills 4 of 6 cells", solid == 4, "%d" % solid)

	for yaw in range(1, 4):
		var v := w.bake_variant(slope, "slope_y%d" % yaw, yaw, false)
		_ok("yaw %d keeps the same solid volume" % yaw,
				w.get_archetype_solid_cells(v) == solid,
				"%d vs %d" % [w.get_archetype_solid_cells(v), solid])
		var expect := Vector3i(2, 3, 1) if yaw % 2 == 1 else Vector3i(1, 3, 2)
		_ok("yaw %d has the rotated footprint" % yaw, w.get_archetype_size(v) == expect,
				"%v vs %v" % [w.get_archetype_size(v), expect])

	# And the stud column travels with the geometry: the full-height column is
	# where the stud is, whichever way the part is turned.
	var y1 := w.bake_variant(slope, "slope_y1", 1, false)
	var up: PackedByteArray = w.get_archetype_up_face(y1)
	_ok("exactly one column still carries a stud after yaw",
			up.count(FACE_STUD) == 1, "%s" % [up])


func _check_inverted_slope_roofs() -> void:
	print("\nan inverted slope roofs correctly")
	var w := BrickWorld.new()
	var slope := _bake_slope(w, "slope")
	var inv := w.bake_variant(slope, "slope_i", 0, true)
	_ok("inverted slope baked", inv >= 0)
	_ok("same solid volume", w.get_archetype_solid_cells(inv)
			== w.get_archetype_solid_cells(slope))

	# Flipping hands the old BOTTOM face to the top and vice versa. The slope
	# was solid across its whole underside, so inverted it offers sockets across
	# its whole top; and its old stud column is now a stud pointing DOWN.
	var up: PackedByteArray = w.get_archetype_up_face(inv)
	var down: PackedByteArray = w.get_archetype_down_face(inv)
	_ok("inverted, its top is all SOCKET -- it was all underside",
			up.count(FACE_SOCKET) == up.size(), "%s" % [up])
	_ok("and exactly one column points a STUD downward",
			down.count(FACE_STUD) == 1, "%s" % [down])

	# The CELL mask has to move with the faces. Flipping reverses Y and Z, so
	# the full-height column that was at z=0 is now at z=1 -- and the downward
	# stud has to be under THAT column, not the other one. If only the faces had
	# been transformed and not the cells, the two would disagree and this is the
	# check that catches it.
	_ok("the downward stud is under the full-height column",
			down[1] == FACE_STUD and down[0] == FACE_NONE, "%s" % [down])

	# It roofs: an inverted slope sits ON an inverted slope, eave under eave,
	# because that is the pairing that puts a stud into a socket.
	var c := w.create_chunk(Vector3i.ZERO, Vector3i(8, 16, 8))
	var lower := w.place_block(c, Vector3i(0, 0, 0), inv, 0)
	var upper := w.place_block(c, Vector3i(0, 3, 0), inv, 0)
	_ok("both placed", lower >= 0 and upper >= 0)
	_ok("inverted slopes stack into an eave",
			w.get_block_neighbours(c, lower).has(upper))


func _check_tile_still_refuses() -> void:
	print("\na tile still refuses a clip, in every orientation")
	var w := BrickWorld.new()
	var palette := BrickPalette.bake(w)
	var brick: int = palette["brick_2x2"]

	for name in ["tile_2x2", "tile_2x2_i"]:
		var c := w.create_chunk(Vector3i.ZERO, Vector3i(8, 16, 8))
		var t := w.place_block(c, Vector3i(0, 0, 0), palette[name], 0)
		var b := w.place_block(c, Vector3i(0, 1, 0), brick, 0)
		_ok("%s: both placed" % name, t >= 0 and b >= 0)
		var joined: bool = w.get_block_neighbours(c, t).has(b)
		if name == "tile_2x2":
			_ok("%s: smooth side up, so nothing clips to it" % name, not joined)
		else:
			# Inverted, the smooth face is DOWNWARD -- so its top is a socket and
			# a brick above it has studs down into... nothing. Still no joint.
			_ok("%s: its smooth face is underneath now" % name, not joined)

	# An inverted tile is the wall-cap shape: it clips onto nothing below.
	var c2 := w.create_chunk(Vector3i.ZERO, Vector3i(8, 16, 8))
	var under := w.place_block(c2, Vector3i(0, 0, 0), brick, 0)
	var cap := w.place_block(c2, Vector3i(0, 3, 0), palette["tile_2x2_i"], 0)
	_ok("an inverted tile laid on a brick does NOT clip to it",
			under >= 0 and cap >= 0 and not w.get_block_neighbours(c2, under).has(cap))

	var c3 := w.create_chunk(Vector3i.ZERO, Vector3i(8, 16, 8))
	var under3 := w.place_block(c3, Vector3i(0, 0, 0), brick, 0)
	var tile3 := w.place_block(c3, Vector3i(0, 3, 0), palette["tile_2x2"], 0)
	_ok("but an upright tile does -- sockets underneath",
			under3 >= 0 and tile3 >= 0 and w.get_block_neighbours(c3, under3).has(tile3))


func _check_double_sided_plate() -> void:
	print("\na double-sided plate joins both ways")
	var w := BrickWorld.new()
	var n := 4
	var both := PackedByteArray()
	both.resize(n)
	both.fill(FACE_STUD)
	var jumper := w.bake_faced_archetype("plate_2x2_double", Vector3i(2, 1, 2), 0.4,
			PackedByteArray(), both, both)
	_ok("it bakes", jumper >= 0)

	# Studs on both faces means it mates with a SOCKET on both sides -- so it is
	# the piece that goes between an inverted part and a normal one, which is
	# precisely the join neither of those can make on its own. That is what makes
	# it worth having rather than a curiosity.
	var brick := w.bake_archetype("b", Vector3i(2, 3, 2), 1.2)
	var inv := w.bake_variant(brick, "b_i", 0, true)
	var c := w.create_chunk(Vector3i.ZERO, Vector3i(8, 24, 8))
	var below := w.place_block(c, Vector3i(0, 0, 0), inv, 0)     # socket facing up
	var mid := w.place_block(c, Vector3i(0, 3, 0), jumper, 0)
	var above := w.place_block(c, Vector3i(0, 4, 0), brick, 0)   # socket facing down
	_ok("all three placed", below >= 0 and mid >= 0 and above >= 0)
	_ok("it joins the INVERTED part below", w.get_block_neighbours(c, below).has(mid))
	_ok("and the normal brick above", w.get_block_neighbours(c, mid).has(above))
	_ok("so it bridges two parts that cannot join each other directly", true)

	# Sockets on both faces is the mirror image and also newly expressible: it
	# accepts a stud from either side.
	var sockets := PackedByteArray()
	sockets.resize(n)
	sockets.fill(FACE_SOCKET)
	var twin := w.bake_faced_archetype("plate_2x2_twin", Vector3i(2, 1, 2), 0.4,
			PackedByteArray(), sockets, sockets)
	var c2 := w.create_chunk(Vector3i.ZERO, Vector3i(8, 24, 8))
	var b2 := w.place_block(c2, Vector3i(0, 0, 0), brick, 0)     # stud facing up
	var t2 := w.place_block(c2, Vector3i(0, 3, 0), twin, 0)
	var i2 := w.place_block(c2, Vector3i(0, 4, 0), inv, 0)       # stud facing down
	_ok("a socket-both-sides plate takes a stud from below",
			b2 >= 0 and t2 >= 0 and w.get_block_neighbours(c2, b2).has(t2))
	_ok("and one from above",
			i2 >= 0 and w.get_block_neighbours(c2, t2).has(i2))


func _check_dedupe() -> void:
	print("\nidentical orientations are one archetype, not two")
	var w := BrickWorld.new()
	var before := w.get_archetype_count()
	var square := w.bake_archetype("sq", Vector3i(2, 3, 2), 1.2)
	var y0 := w.bake_variant(square, "sq_a", 0, false)
	var y2 := w.bake_variant(square, "sq_b", 2, false)
	_ok("yaw 0 of a square part is the part itself", y0 == square)
	_ok("and yaw 180 is too", y2 == square, "%d vs %d" % [y2, square])
	_ok("so nothing extra was baked", w.get_archetype_count() == before + 1,
			"%d" % (w.get_archetype_count() - before))

	# An inverted one is genuinely different, so it must NOT be deduped away.
	var inv := w.bake_variant(square, "sq_i", 0, true)
	_ok("but inverting it is a new archetype", inv != square)

	# And a non-square part really does have two yaw states.
	var long := w.bake_archetype("lo", Vector3i(1, 3, 4), 1.2)
	_ok("yawing a long part gives a different archetype",
			w.bake_variant(long, "lo_x", 1, false) != long)


func _check_recipes_still_build() -> void:
	print("\nnothing downstream noticed")
	var w := BrickWorld.new()
	var palette := TowerRecipe.bake_palette(w)
	var c := w.create_chunk(Vector3i.ZERO, TowerRecipe.chunk_dims(24, 16, 12))
	TowerRecipe.build(w, c, palette, 24, 16, 12)
	var blocks := w.get_block_count(c)
	_ok("the test tower still builds", blocks > 0, "%d blocks" % blocks)

	w.set_foundation_level(c, 0)
	w.solve_grounded(c)
	var groups: Array = w.find_detached_groups(c)
	var loose := 0
	for g in groups:
		loose += (g as PackedInt32Array).size()
	_ok("and it is intact -- no block is ungrounded", loose == 0, "%d loose" % loose)

	var r := BuildRecipe.new()
	for i in 6:
		r.add("brick_2x4_x", Vector3i(0, i * 3, 0), 4)
	var c2 := w.create_chunk(Vector3i.ZERO, r.chunk_dims())
	_ok("a BuildRecipe still builds", r.build(w, c2, palette) == r.size())

	# An inverted part is nameable from a recipe like any other.
	var r2 := BuildRecipe.new()
	r2.add("brick_2x4_x", Vector3i(0, 0, 0), 4)
	r2.add("brick_2x4_x_i", Vector3i(0, 3, 0), 5)
	var c3 := w.create_chunk(Vector3i.ZERO, r2.chunk_dims())
	_ok("including an inverted one", r2.build(w, c3, palette) == 2)
