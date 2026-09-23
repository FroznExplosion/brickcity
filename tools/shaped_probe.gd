extends SceneTree

## Acceptance probe for the shaped parts: slopes, curved slopes, round bricks,
## arches (scripts/shaped_parts.gd, BrickPalette._SHAPED).
##
##     godot --headless --path . --script tools/shaped_probe.gd
##
## A shaped part is three things built from one description -- the cells it
## connects as, the triangles it is drawn as, the hulls it collides as -- and
## the risk is the three disagreeing. So this checks each against the others:
## the drawn surface encloses exactly the volume of the profile, the collision
## pieces tile that same volume, the cells give studs where the shape reaches
## the top and sockets where it reaches the floor, every orientation carries
## all of it round together, and in a real physics space the part is solid
## where it is drawn and empty where it is not.

var _pass := 0
var _fail := 0
var _frames := 0

var _w: BrickWorld
var _p: Dictionary
var _space: RID
var _bodies: Array[RID] = []

const S := BrickPalette.STUD_M
const P := BrickPalette.PLATE_M


func _init() -> void:
	print("shaped probe (slopes, curves, rounds, arches)")
	_w = BrickWorld.new()
	_p = BrickPalette.bake(_w)
	_check_geometry()
	_check_masks()
	_check_orientations()
	_check_connections()
	_check_spiral()
	_setup_space()
	physics_frame.connect(_tick)


func _tick() -> void:
	_frames += 1
	if _frames != 3:
		return
	_check_rays()
	for b in _bodies:
		PhysicsServer3D.free_rid(b)
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s" % what)
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _shaped() -> Array:
	var out := []
	for part in BrickPalette.parts():
		if BrickPalette.is_shaped(part):
			out.append(part)
	return out


func _build(part: String) -> Dictionary:
	var spec: Dictionary = BrickPalette._SHAPED[part]
	return ShapedParts.build(spec.kind, BrickPalette.part_size(part), spec.get("axis", "z"))


func _box_m(size: Vector3i) -> Vector3:
	return Vector3(size.x * S, size.y * P, size.z * S)


# ---------------------------------------------------------------------------
# One description, three things: do they describe the same solid?
# ---------------------------------------------------------------------------

## Volume enclosed by a triangle soup whose normals say which side is out
## (divergence theorem). T-junctions from the grid cuts do not matter to it.
func _mesh_volume(pos: PackedVector3Array, nrm: PackedVector3Array) -> float:
	var v := 0.0
	for i in range(0, pos.size(), 3):
		var a := pos[i]
		var b := pos[i + 1]
		var c := pos[i + 2]
		var n := nrm[i] + nrm[i + 1] + nrm[i + 2]
		if (b - a).cross(c - a).dot(n) < 0.0:
			var t := b
			b = c
			c = t
		v += a.dot(b.cross(c)) / 6.0
	return v


func _prism_volume(pr: Dictionary) -> float:
	return absf(ShapedParts._signed_area(pr.poly)) * (pr.hi - pr.lo)


func _check_geometry() -> void:
	print("\ngeometry: drawn, collided and sampled as one shape")
	for part in _shaped():
		var size := BrickPalette.part_size(part)
		var box := _box_m(size)
		var spec: Dictionary = BrickPalette._SHAPED[part]
		var shape: Dictionary = ShapedParts._shape(spec.kind, size, spec.get("axis", "z"))
		var sh := _build(part)
		var pos: PackedVector3Array = sh.positions
		var nrm: PackedVector3Array = sh.normals

		_ok("%s: whole triangles, a normal each corner" % part,
				pos.size() > 0 and pos.size() % 3 == 0 and nrm.size() == pos.size())
		var inside := true
		var unit := true
		for i in pos.size():
			var q := pos[i]
			inside = inside and q.x > -1e-4 and q.y > -1e-4 and q.z > -1e-4 \
					and q.x < box.x + 1e-4 and q.y < box.y + 1e-4 and q.z < box.z + 1e-4
			unit = unit and absf(nrm[i].length() - 1.0) < 1e-3
		_ok("%s: drawn inside its box" % part, inside)
		_ok("%s: unit normals" % part, unit)

		var drawn := 0.0
		for pr in shape.draw:
			drawn += _prism_volume(pr)
		var mv := _mesh_volume(pos, nrm)
		_ok("%s: the surface is closed and faces out -- it encloses the profile's volume" % part,
				absf(mv - drawn) < 1e-4, "%.5f vs %.5f" % [mv, drawn])

		var pieces := 0.0
		var convex := true
		for pr in shape.pieces:
			pieces += _prism_volume(pr)
			var poly: PackedVector2Array = pr.poly
			var sgn := 0.0
			for i in poly.size():
				var e0 := poly[(i + 1) % poly.size()] - poly[i]
				var e1 := poly[(i + 2) % poly.size()] - poly[(i + 1) % poly.size()]
				var c := e0.cross(e1)
				if absf(c) < 1e-9:
					continue
				if sgn == 0.0:
					sgn = signf(c)
				convex = convex and signf(c) == sgn
		_ok("%s: every collision piece is convex" % part, convex)
		# A shape made of pieces that overlap (the spiral's treads run into its
		# newel) draws and collides as those same pieces, so there is no
		# tiling to check -- its volume is their UNION, sampled.
		var overlapping: bool = shape.get("overlapping", false)
		if not overlapping:
			_ok("%s: the pieces fill exactly what is drawn, no gap, no overlap" % part,
					absf(pieces - drawn) < 1e-4, "%.5f vs %.5f" % [pieces, drawn])
		else:
			_ok("%s: draws and collides as the same pieces" % part, shape.draw == shape.pieces)
		_ok("%s: one hull per piece" % part, sh.hulls.size() == shape.pieces.size())
		var vol := drawn if not overlapping else _union_volume(shape.pieces, size)
		var slack := 1e-4 if not overlapping else 0.02 * vol

		# The cells are the shape, to the half-cell. Every solid cell is at least
		# half full and every empty one at most half, so the volume is pinned
		# between half the solid cells and all of them plus half the rest.
		var cell_v := S * P * S
		var solid: int = sh.solid
		var empty := size.x * size.y * size.z - solid
		_ok("%s: solid cells track the volume" % part,
				vol >= solid * cell_v * 0.5 - slack
				and vol <= (solid + empty * 0.5) * cell_v + slack,
				"%d cells = %.4f m3 vs %.4f" % [solid, solid * cell_v, vol])
		_ok("%s: and the solid volume is less than the box" % part,
				drawn < box.x * box.y * box.z - 1e-4)


## The volume of a union of convex prisms, sampled at 5 x 5 x 5 a cell.
func _union_volume(pieces: Array, size: Vector3i) -> float:
	var n := 5
	var hit := 0
	for z in size.z * n:
		for y in size.y * n:
			for x in size.x * n:
				var v := Vector3((x + 0.5) / n * S, (y + 0.5) / n * P, (z + 0.5) / n * S)
				for pr in pieces:
					if ShapedParts._prism_has(pr, v):
						hit += 1
						break
	return hit * (S * P * S) / float(n * n * n)


# ---------------------------------------------------------------------------
# Cells, studs and sockets -- derived, so check they came out as the real parts
# ---------------------------------------------------------------------------

func _cols(a: PackedByteArray) -> Array:
	var out := []
	for v in a:
		out.append(1 if v != 0 else 0)
	return out


func _check_masks() -> void:
	print("\nmasks: studs where the shape reaches the top, sockets where it reaches the floor")
	# Column index is x + W * z in the canonical orientation.
	var expect := {
		"slope_1x2": {"studs": [0, 1], "sockets": [1, 1]},
		"slope_2x2": {"studs": [0, 0, 1, 1], "sockets": [1, 1, 1, 1]},
		# Falls across its two studs along X: the stud strip is the x = 1 row.
		"slope_2x4": {"studs": [0, 1, 0, 1, 0, 1, 0, 1], "sockets": [1, 1, 1, 1, 1, 1, 1, 1]},
		"curve_1x2": {"studs": [0, 0], "sockets": [1, 1]},
		"curve_2x2": {"studs": [0, 0, 0, 0], "sockets": [1, 1, 1, 1]},
		"round_1x1": {"studs": [1], "sockets": [1]},
		"round_2x2": {"studs": [1, 1, 1, 1], "sockets": [1, 1, 1, 1]},
		"arch_1x4": {"studs": [1, 1, 1, 1], "sockets": [1, 0, 0, 1]},
		"arch_1x6": {"studs": [1, 1, 1, 1, 1, 1], "sockets": [1, 0, 0, 0, 0, 1]},
	}
	for part in _shaped():
		if not expect.has(part):
			continue  # the spiral has checks of its own (_check_spiral)
		var sh := _build(part)
		_ok("%s: studs %s" % [part, expect[part].studs], _cols(sh.studs) == expect[part].studs,
				"got %s" % [_cols(sh.studs)])
		_ok("%s: sockets %s" % [part, expect[part].sockets],
				_cols(sh.sockets) == expect[part].sockets, "got %s" % [_cols(sh.sockets)])

	# A slope's front column is solid only as high as its lip and the slope
	# over it; the top cell there is empty, so nothing stands on the front.
	var sl := _build("slope_1x2")
	_ok("slope_1x2: front column is two plates of solid, back column three",
			_cols(sl.cells) == [1, 1, 0, 1, 1, 1], "got %s" % [_cols(sl.cells)])
	# The arch's opening is empty at the floor: a part fits under it.
	var ar := _build("arch_1x4")
	_ok("arch_1x4: the floor of the opening is empty",
			ar.cells[0 + 3 * 1] == 0 and ar.cells[0 + 3 * 2] == 0)
	_ok("arch_1x4: the beam runs the whole length",
			ar.cells[2 + 3 * 0] != 0 and ar.cells[2 + 3 * 1] != 0 and ar.cells[2 + 3 * 2] != 0
			and ar.cells[2 + 3 * 3] != 0)
	var rd := _build("round_2x2")
	_ok("round_2x2: fills its cells, as a real round brick does its studs",
			_cols(rd.cells).count(1) == 12)


# ---------------------------------------------------------------------------
# Every orientation carries everything round with it
# ---------------------------------------------------------------------------

func _check_orientations() -> void:
	print("\norientations")
	for part in _shaped():
		var shape: Dictionary = ShapedParts._shape(BrickPalette._SHAPED[part].kind,
				BrickPalette.part_size(part), BrickPalette._SHAPED[part].get("axis", "z"))
		var base_tris: int = _w.get_archetype_mesh_triangles(_p[BrickPalette.variants_of(part)[0]])
		var ids := {}
		var all_drawn := true
		var all_hulled := true
		for v in BrickPalette.variants_of(part):
			var id: int = _p[v]
			ids[id] = true
			all_drawn = all_drawn and _w.get_archetype_mesh_triangles(id) == base_tris
			all_hulled = all_hulled and _w.get_archetype_hull_count(id) == shape.pieces.size()
		_ok("%s: every orientation is drawn as the shape" % part, all_drawn and base_tris > 0)
		_ok("%s: every orientation collides as the shape" % part, all_hulled)
		var n := BrickPalette.variants_of(part).size()
		_ok("%s: %d orientations, %d distinct parts" % [part, n, n], ids.size() == n,
				"%d distinct" % ids.size())

		# Turning: four quarter turns come home; a part with a front never
		# comes home sooner.
		var name: String = BrickPalette.variants_of(part)[0]
		var t := name
		var seen := [t]
		for i in 4:
			t = BrickPalette.turn(t)
			seen.append(t)
		_ok("%s: four turns come back round" % part, t == name, "%s" % [seen])
		if BrickPalette.is_directional(part):
			_ok("%s: and every turn on the way is a different part" % part,
					seen.slice(0, 4).duplicate().filter(func(s): return s == name).size() == 1)

	# front_of must agree with what the extension baked: the stud strip is at
	# the BACK, so every stud column lies further back than every bare one.
	print("\nthe front is where the bake put it")
	for part in _shaped():
		# Slopes only: a spiral's "front" is where its first step is, not a
		# low edge with the studs behind it.
		if not (BrickPalette._SHAPED[part] as Dictionary).has("axis") \
				or not BrickPalette.has_studs(part):
			continue
		for v in BrickPalette.variants_of(part):
			var id: int = _p[v]
			var f := BrickPalette.front_of(v)
			var size := _w.get_archetype_size(id)
			# Inverted, the studs are on the underside.
			var faces: PackedByteArray = _w.get_archetype_down_face(id) \
					if BrickPalette.is_inverted(v) else _w.get_archetype_up_face(id)
			var studs_front := -1e9
			var bare_back := 1e9
			for z in size.z:
				for x in size.x:
					var d := f.x * x + f.z * z
					if faces[x + size.x * z] == BrickPalette.FACE_STUD:
						studs_front = maxf(studs_front, d)
					else:
						bare_back = minf(bare_back, d)
			_ok("%s: front %v, studs behind it" % [v, f], f != Vector3i.ZERO
					and absf(f.y) == 0 and studs_front < bare_back,
					"studs reach %.0f, bare from %.0f" % [studs_front, bare_back])


# ---------------------------------------------------------------------------
# What stands on what
# ---------------------------------------------------------------------------

func _check_connections() -> void:
	print("\nconnections")
	var c := _w.create_chunk(Vector3i.ZERO, Vector3i(32, 16, 32))
	var slope := _w.place_block(c, Vector3i(0, 0, 0), _p["slope_1x2_y0"], 4)
	_ok("a slope placed", slope >= 0)
	_ok("a 1x1 brick on the slope's FRONT is not joined -- nothing up there to clip to",
			_w.would_connect(c, Vector3i(0, 3, 0), _p["brick_1x1"]) == 0)
	_ok("and one on its back strip is",
			_w.would_connect(c, Vector3i(0, 3, 1), _p["brick_1x1"]) == 1)
	_ok("a 1x1 plate fits in the empty cell over the slope's front",
			_w.can_place(c, Vector3i(0, 2, 0), _p["plate_1x1"]))

	var under := _w.place_block(c, Vector3i(4, 0, 0), _p["brick_1x4_z"], 4)
	_ok("an arch on a 1x4 brick joins at its two pillars only",
			under >= 0 and _w.would_connect(c, Vector3i(4, 3, 0), _p["arch_1x4_z"]) == 2)
	var arch := _w.place_block(c, Vector3i(8, 0, 0), _p["arch_1x4_z"], 4)
	_ok("a 1x4 brick on an arch joins along the whole beam",
			arch >= 0 and _w.would_connect(c, Vector3i(8, 3, 0), _p["brick_1x4_z"]) == 4)
	_ok("a 1x1 plate fits under the arch, in its opening",
			_w.can_place(c, Vector3i(8, 0, 1), _p["plate_1x1"]))

	var curve := _w.place_block(c, Vector3i(12, 0, 0), _p["curve_2x2_y0"], 4)
	_ok("nothing clips to a curved slope",
			curve >= 0 and _w.would_connect(c, Vector3i(12, 3, 0), _p["plate_2x2"]) == 0)
	var round := _w.place_block(c, Vector3i(16, 0, 0), _p["round_2x2"], 4)
	_ok("round bricks stack",
			round >= 0 and _w.would_connect(c, Vector3i(16, 3, 0), _p["round_2x2"]) == 4)

	# The stud buffer draws studs only where the part offers them.
	var studs: PackedFloat32Array = _w.get_chunk_studs(c)
	var on_slope := 0
	for i in range(0, studs.size(), 16):
		var at := Vector3(studs[i + 3], studs[i + 7], studs[i + 11])
		if at.x < S and at.z < 2 * S:
			on_slope += 1
	_ok("the slope shows one stud, on its back strip", on_slope == 1, "%d" % on_slope)


# ---------------------------------------------------------------------------
# A real physics space: solid where drawn, empty where not
# ---------------------------------------------------------------------------

func _body(chunk: int, at: Vector3) -> void:
	var ps := PhysicsServer3D
	var b := ps.body_create()
	ps.body_set_mode(b, PhysicsServer3D.BODY_MODE_STATIC)
	_w.add_chunk_shapes(b, chunk, Vector3.ZERO, false, false)
	ps.body_set_state(b, PhysicsServer3D.BODY_STATE_TRANSFORM, Transform3D(Basis(), at))
	ps.body_set_space(b, _space)
	_bodies.append(b)


# ---------------------------------------------------------------------------
# The spiral staircase piece
# ---------------------------------------------------------------------------

## The player is four bricks tall (like the real figure): the least clearance
## a stair may leave over any tread.
const PLAYER_PLATES := 12

## [part, ShapedParts kind, which way the next piece turns]. Clockwise seen
## from above climbs yaw + 1; its mirror climbs yaw - 1.
const SPIRALS := [
	["spiralcw_10x10", "spiral", 1],
	["spiralccw_10x10", "spiral_ccw", -1],
]

## part -> the chunk holding two revolutions of it.
var _spiral_chunks := {}


func _check_spiral() -> void:
	for sp in SPIRALS:
		_check_one_spiral(sp[0], sp[1], sp[2])

	# The two windings are one shape and its mirror: every cell of one is the
	# other's across the diagonal, and so are its studs.
	var cw := _build("spiralcw_10x10")
	var ccw := _build("spiralccw_10x10")
	var size := BrickPalette.part_size("spiralcw_10x10")
	var mirror := true
	for z in size.z:
		for x in size.x:
			mirror = mirror and cw.studs[x + size.x * z] == ccw.studs[z + size.x * x]
			for y in size.y:
				mirror = mirror and cw.cells[x + size.x * (y + size.y * z)] \
						== ccw.cells[z + size.x * (y + size.y * x)]
	_ok("the anticlockwise piece is exactly the clockwise one mirrored", mirror)


func _check_one_spiral(part: String, kind: String, winds: int) -> void:
	print("\n%s: a newel and two steps a piece, four pieces a turn" % part)
	var size := BrickPalette.part_size(part)
	var sh := _build(part)
	var studs := _cols(sh.studs)
	var sockets := _cols(sh.sockets)
	var W := size.x
	@warning_ignore("integer_division")
	var ctr := W / 2
	var newel_ok := true
	for dz in [-1, 0]:
		for dx in [-1, 0]:
			var i: int = (ctr + dx) + W * (ctr + dz)
			newel_ok = newel_ok and studs[i] == 1 and sockets[i] == 1
	_ok("the newel's four columns carry studs on top and sockets underneath", newel_ok)
	_ok("and both treads have studs (lower + upper)", studs.count(1) > 4 + 8,
			"%d studs" % studs.count(1))
	var nr := BrickPalette.newel_of(BrickPalette.variants_of(part)[0])
	_ok("the palette knows where its newel is", nr == Rect2i(ctr - 1, ctr - 1, 2, 2), "%s" % nr)

	# The newel is a round 2x2: the same octagon, in the same place in a cell.
	var shape: Dictionary = ShapedParts._shape(kind, size, "z")
	var newel: PackedVector2Array = (shape.pieces[0] as Dictionary).poly
	var round: PackedVector2Array = ShapedParts._round_prism(Vector3i(2, 3, 2)).poly
	var same := newel.size() == round.size()
	var shift := Vector2((ctr - 1) * S, (ctr - 1) * S)
	for i in mini(newel.size(), round.size()):
		same = same and newel[i].is_equal_approx(round[i] + shift)
	_ok("its newel is exactly a round_2x2's octagon", same)

	# Two revolutions: eight pieces, each a quarter turned the way it winds and
	# one piece up -- each the palette's next_in_flight of the one below.
	var c := _w.create_chunk(Vector3i.ZERO, Vector3i(W, 8 * size.y + 8, W))
	_spiral_chunks[part] = c
	var all := true
	var joints_ok := true
	var chain_ok := true
	var prev := ""
	for k in 8:
		var name := BrickPalette.variant_name(part, k * winds, false)
		if prev != "":
			chain_ok = chain_ok and BrickPalette.next_in_flight(prev) == name
		prev = name
		var arch: int = _p[name]
		var at := Vector3i(0, k * size.y, 0)
		if k > 0:
			joints_ok = joints_ok and _w.would_connect(c, at, arch) == 4
		all = all and _w.place_block(c, at, arch, 4) >= 0
	_ok("eight pieces, each turned a quarter, stack into two revolutions", all)
	_ok("each is next_in_flight of the one below", chain_ok)
	_ok("each held by the four newel studs of the one below", joints_ok)
	var r := _w.would_connect(c, Vector3i(ctr - 1, 8 * size.y, ctr - 1), _p["round_2x2"])
	_ok("and a round 2x2 stacks on the top of the newel", r == 4, "%d joints" % r)


func _setup_space() -> void:
	_space = root.get_world_3d().space
	var c1 := _w.create_chunk(Vector3i.ZERO, Vector3i(8, 8, 8))
	_w.place_block(c1, Vector3i.ZERO, _p["slope_2x2_y0"], 4)
	_body(c1, Vector3.ZERO)
	var c2 := _w.create_chunk(Vector3i.ZERO, Vector3i(8, 8, 8))
	_w.place_block(c2, Vector3i.ZERO, _p["arch_1x4_z"], 4)
	_body(c2, Vector3(10, 0, 0))
	var c3 := _w.create_chunk(Vector3i.ZERO, Vector3i(8, 8, 8))
	_w.place_block(c3, Vector3i.ZERO, _p["round_2x2"], 4)
	_body(c3, Vector3(20, 0, 0))
	for k in SPIRALS.size():
		_body(_spiral_chunks[SPIRALS[k][0]], Vector3(30 + 15 * k, 0, 0))


func _cast(from: Vector3, to: Vector3) -> Dictionary:
	var dss := PhysicsServer3D.space_get_direct_state(_space)
	return dss.intersect_ray(PhysicsRayQueryParameters3D.create(from, to))


func _check_rays() -> void:
	print("\nrays")
	# Down onto the slope's face, a little behind its lip. The cells there
	# stand two plates tall; the slope is lower.
	var zf := 0.1
	var face_y := P + (2.0 * P / S) * zf
	var hit := _cast(Vector3(S, 2.0, zf), Vector3(S, -1.0, zf))
	_ok("the slope's face is solid", not hit.is_empty())
	if not hit.is_empty():
		var y: float = (hit.position as Vector3).y
		_ok("at the slope's height, not its cells' (%.3f)" % face_y, absf(y - face_y) < 0.01,
				"hit y %.3f; the cells top out at %.3f" % [y, 2.0 * P])
		_ok("and its normal leans toward the front",
				(hit.normal as Vector3).z < -0.3, "%v" % hit.normal)

	# Along X through the arch's opening at mid-span, under the crown.
	var through := _cast(Vector3(9.0, P * 0.5, 2.0 * S), Vector3(11.0 + S, P * 0.5, 2.0 * S))
	_ok("a ray passes through the arch's opening", through.is_empty(),
			"hit at %v" % [through.get("position", Vector3.ZERO)])
	var pillar := _cast(Vector3(9.0, P * 0.5, 0.5 * S), Vector3(11.0 + S, P * 0.5, 0.5 * S))
	_ok("and one through its pillar does not", not pillar.is_empty())

	# Diagonally at the round brick's corner: the cells are square, it is not.
	var corner := Vector3(20.0 + 0.03, 1.0, 0.03)
	var miss := _cast(corner, corner - Vector3(0, 2, 0))
	_ok("the corner of a round brick's footprint is empty", miss.is_empty())
	var mid := Vector3(20.0 + S, 1.0, S)
	var on := _cast(mid, mid - Vector3(0, 2, 0))
	_ok("its middle is solid, at its top", not on.is_empty()
			and absf((on.position as Vector3).y - 3.0 * P) < 0.01)

	_check_spiral_rays()


func _check_spiral_rays() -> void:
	for k in SPIRALS.size():
		_check_one_spiral_rays(SPIRALS[k][0], SPIRALS[k][2], Vector3(30 + 15 * k, 0, 0))


func _check_one_spiral_rays(part: String, winds: int, o: Vector3) -> void:
	print("\n%s: rays" % part)
	var size := BrickPalette.part_size(part)
	var rise := size.y * 0.5 * P
	var ctr := size.x * 0.5 * S
	# Down onto the middle of each of the first eight treads, half way out.
	# Angles run from +X toward +Z clockwise, from +Z toward +X anticlockwise.
	var heights := []
	var up_ok := true
	var least := INF
	for k in 8:
		var a := (k + 0.5) * TAU / 8.0 if winds > 0 else TAU / 4.0 - (k + 0.5) * TAU / 8.0
		var q := o + Vector3(ctr + cos(a) * 3.2 * S, 0, ctr + sin(a) * 3.2 * S)
		# From the underside of the tread a revolution up, so the ray lands on
		# this one.
		var from := q + Vector3(0, (k + 1) * rise + 8 * rise - rise - 0.01, 0)
		var hit := _cast(from, q - Vector3(0, 1, 0))
		heights.append(snappedf((hit.position as Vector3).y, 0.001) if not hit.is_empty() else -1.0)
		# And up from the tread's top to the underside of the one above it.
		var top := q + Vector3(0, (k + 1) * rise + 0.01, 0)
		var above := _cast(top, top + Vector3(0, 10, 0))
		if above.is_empty():
			up_ok = false
		else:
			least = minf(least, (above.position as Vector3).y - (k + 1) * rise)
	var steps_ok := true
	for k in 8:
		steps_ok = steps_ok and absf(heights[k] - (k + 1) * rise) < 0.01
	_ok("eight treads, each one rise above the last, round the turn", steps_ok, "%s" % [heights])
	_ok("every tread has the one a revolution up over it", up_ok)
	_ok("and a player (4 bricks, %d plates) fits under it" % PLAYER_PLATES,
			least >= PLAYER_PLATES * P - 0.01, "%.2f plates" % (least / P))

	# No floating studs: under every drawn stud, the part is solid right to the
	# stud's edge.
	var studs: PackedFloat32Array = _w.get_chunk_studs(_spiral_chunks[part])
	var floating := 0
	var n := 0
	for i in range(0, studs.size(), 16):
		var at := o + Vector3(studs[i + 3], studs[i + 7], studs[i + 11])
		n += 1
		for d in [Vector3(0.1, 0, 0), Vector3(-0.1, 0, 0), Vector3(0, 0, 0.1), Vector3(0, 0, -0.1),
				Vector3.ZERO]:
			var hit := _cast(at + d + Vector3(0, 0.02, 0), at + d - Vector3(0, 0.2, 0))
			if hit.is_empty() or absf((hit.position as Vector3).y - at.y) > 0.01:
				floating += 1
				break
	_ok("studs are drawn (%d)" % n, n > 0)
	_ok("and none hangs off an edge: solid under every stud, out to its rim", floating == 0,
			"%d of %d float" % [floating, n])
