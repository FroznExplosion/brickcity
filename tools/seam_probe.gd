extends SceneTree

## A piece snaps at the weakest seam near where it is struck
## (Docs/CollapseNext.md 1.10 (5)).
##
##     godot --headless --path . --script tools/seam_probe.gd
##
## A brick model goes where the fewest studs hold it: a tower that comes down
## across something parts along a row of windows before it parts at a floor.
## Three things make that:
##
##   * BrickWorld.seam_studs counts, for each course boundary of a chunk, the
##     studs meeting there and the blocks that run through it (with the studs
##     at their feet);
##   * BrickWorld.sever_seams with `through` cuts those blocks too, at their
##     feet -- a column a storey tall pulls off its studs and goes with the
##     upper side, where without it the column held the two sides together
##     and nothing parted;
##   * IslandManager._weak_seam picks the boundary in reach that lets go of
##     the fewest, a storey line before anything not clearly weaker.
##
## And a snap recorded before any of this (no DamageLog.FLAG_STEP) replays as
## it was made.

var _pass := 0
var _fail := 0
var _started := false
var _w: BrickWorld
var _palette: Dictionary
var _m: IslandManager



## Floors every `per` plates, from the ground up, as a recipe tower has them.
func _every(per: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	for k in 40:
		out.append(k * per)
	return out

func _init() -> void:
	print("a piece snaps at the weakest seam near where it is struck")
	_w = BrickWorld.new()
	_palette = TowerRecipe.bake_palette(_w)
	var ground := StaticBody3D.new()
	ground.collision_layer = Layers.WORLD
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(400.0, 1.0, 400.0)
	shape.shape = box
	shape.position = Vector3(0.0, -0.5, 0.0)
	ground.add_child(shape)
	root.add_child(ground)
	_m = IslandManager.new()
	root.add_child(_m)
	_m.setup(_w, null, null)
	_m.interest = func() -> PackedVector3Array: return PackedVector3Array([Vector3(0, 1, 0)])
	physics_frame.connect(_run)


func _ok(what: String, cond: bool, detail := "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


## [studs, through, through_studs] at boundary `k` of `chunk`.
func _seam(chunk: int, k: int) -> Array:
	var s: PackedInt32Array = _w.seam_studs(chunk, k, k)
	return [s[0], s[1], s[2]]


## A world point on boundary `k` of `chunk`, in the middle of its grid.
func _on_boundary(chunk: int, k: int) -> Vector3:
	var cs: Vector3 = BrickWorld.get_cell_size()
	var dims: Vector3 = Vector3(_w.get_chunk_dims(chunk)) * cs
	return _w.get_chunk_transform(chunk) * Vector3(dims.x * 0.5, float(k) * cs.y, dims.z * 0.5)


## How many parts of more than `min_blocks` a chunk is in.
func _big_parts(chunk: int, min_blocks := 100) -> int:
	var n := 0
	for g in _w.get_components(chunk):
		if (g as PackedInt32Array).size() > min_blocks:
			n += 1
	return n


func _tower(at: Vector3) -> int:
	var c := _w.create_chunk(Vector3i.ZERO, TowerRecipe.chunk_dims(28, 16, 30))
	TowerRecipe.build(_w, c, _palette, 28, 16, 30)
	_w.set_chunk_transform(c, Transform3D(Basis(), at))
	return c


## A 2x4 on the ground; on one half of it a column six bricks tall, on the
## other a stack of six 2x2 bricks; a 2x4 across the tops of both. The column
## joins the bottom brick to the top one by itself.
func _column_and_stack(at: Vector3) -> int:
	var c := _w.create_chunk(Vector3i.ZERO, Vector3i(8, 30, 8))
	_w.place_block(c, Vector3i(0, 0, 0), _palette["brick_2x4_x"], 4)
	_w.place_block(c, Vector3i(0, 3, 0), _palette["column_2x2"], 5)
	for course in 6:
		_w.place_block(c, Vector3i(2, 3 + course * 3, 0), _palette["brick_2x2"], 6)
	_w.place_block(c, Vector3i(0, 21, 0), _palette["brick_2x4_x"], 4)
	_w.set_chunk_transform(c, Transform3D(Basis(), at))
	return c


func _run() -> void:
	if _started:
		return
	_started = true
	var per: int = TowerRecipe.STOREY_PLATES
	var cy: float = BrickWorld.get_cell_size().y

	# --- the count ---------------------------------------------------------------
	print("\nwhat holds two bricks together")
	var c := _w.create_chunk(Vector3i.ZERO, Vector3i(16, 16, 16))
	var brick: int = _palette["brick_2x4_x"]
	_w.place_block(c, Vector3i(0, 0, 0), brick, 4)
	_w.place_block(c, Vector3i(0, 3, 0), brick, 5)
	_ok("a 2x4 square on a 2x4 meets it with eight studs", _seam(c, 3) == [8, 0, 0],
			str(_seam(c, 3)))
	_ok("the middle of the lower brick is no boundary: it runs through, standing on nothing",
			_seam(c, 1) == [0, 1, 0], str(_seam(c, 1)))
	_ok("the middle of the upper one has it running through, on its eight studs",
			_seam(c, 4) == [0, 1, 8], str(_seam(c, 4)))
	_ok("above them nothing meets and nothing runs through", _seam(c, 6) == [0, 0, 0])
	var c2 := _w.create_chunk(Vector3i.ZERO, Vector3i(16, 16, 16))
	_w.place_block(c2, Vector3i(0, 0, 0), brick, 4)
	_w.place_block(c2, Vector3i(2, 3, 0), brick, 5)
	_ok("half over the edge, four", _seam(c2, 3) == [4, 0, 0], str(_seam(c2, 3)))
	_w.sever_seams(c, PackedVector3Array([_on_boundary(c, 3)]), Vector3.UP)
	_ok("and once the seam is severed, none", _seam(c, 3) == [0, 0, 0], str(_seam(c, 3)))

	# --- a column through the seam -------------------------------------------------
	print("\na column through the seam")
	var cs1 := _column_and_stack(Vector3(-60.0, 0.0, 0.0))
	_ok("the column runs through the stack's seams, on four studs of its own",
			_seam(cs1, 12) == [4, 1, 4], str(_seam(cs1, 12)))
	_w.sever_seams(cs1, PackedVector3Array([_on_boundary(cs1, 12)]), Vector3.UP)
	_ok("severed the old way, the column holds the two sides together: one piece",
			_w.get_components(cs1).size() == 1, "%d" % _w.get_components(cs1).size())
	var cs2 := _column_and_stack(Vector3(-80.0, 0.0, 0.0))
	_w.sever_seams(cs2, PackedVector3Array([_on_boundary(cs2, 12)]), Vector3.UP, true)
	var halves: Array = _w.get_components(cs2)
	_ok("pulled off its foot as well, it parts in two", halves.size() == 2,
			"%d part(s)" % halves.size())
	if halves.size() == 2:
		var with_column := -1
		for i in 2:
			for id in halves[i] as PackedInt32Array:
				if _w.get_archetype_name(_w.get_block_archetype(cs2, id)).begins_with("column"):
					with_column = i
		var other: PackedInt32Array = halves[1 - with_column] if with_column >= 0 else PackedInt32Array()
		var low := true
		for id in other:
			low = low and StructureReplayer.block_cell(_w, cs2, id).y < 12
		_ok("and the column goes with the upper side", with_column >= 0 and low)

	# --- a recipe tower ------------------------------------------------------------
	print("\na tower of the city's kind")
	var t := _tower(Vector3(40.0, 0.0, 0.0))
	var line := _seam(t, per)
	# The second storey's slab tops out SLAB_PLATES over its storey line; three
	# courses up from there is the middle of its windows.
	var window_k := per + TowerRecipe.SLAB_PLATES + 3 * 3
	var windows := _seam(t, window_k)
	_ok("its storey line is a clean seam: studs all round, nothing through it",
			int(line[0]) > 0 and int(line[1]) == 0, str(line))
	_ok("a row of its windows meets with fewer studs", int(windows[0]) > 0
			and int(windows[0]) < int(line[0]), str(windows))
	_ok("and lets go of clearly less than the storey line, counting what runs through it",
			float(int(windows[0]) + int(windows[2])) < float(line[0]) * IslandManager.SEAM_PREFERS_FLOOR,
			"%d against %d" % [int(windows[0]) + int(windows[2]), int(line[0])])
	_ok("whole, its walls and floors are one part", _big_parts(t) == 1, "%d" % _big_parts(t))
	_w.sever_seams(t, PackedVector3Array([_on_boundary(t, window_k)]), Vector3.UP, true)
	_ok("severed along its windows, two", _big_parts(t) == 2, "%d" % _big_parts(t))

	# --- where a piece snaps ----------------------------------------------------------
	print("\nwhere a piece of it snaps")
	_m.floor_lines = func(_id: int) -> PackedInt32Array: return _every(per)
	var src := _tower(Vector3(0.0, 0.05, 0.0))
	var ids := PackedInt32Array()
	for id in _w.get_block_count(src):
		ids.append(id)
	var piece := _m.spawn(src, ids, Vector3.ZERO, Vector3.ZERO, -1, -1)
	await physics_frame
	var local := _m._island_aabb(piece)
	var origin_y: int = _w.get_chunk_origin(piece.chunk).y
	# Struck a course above a storey line: the line is the nearest seam, the
	# windows over it the weakest.
	var struck := float(2 * per + 3 - origin_y) * cy
	var at: float = _m._weak_seam(piece, struck, local.position.y, local.end.y)
	var k := roundi(at / cy)
	_ok("struck just over a storey line, it goes at the windows above, not the line",
			at != INF and posmod(k + origin_y, per) != 0 and k + origin_y > 2 * per + 1
			and k + origin_y < 3 * per, "boundary %d, storey lines every %d" % [k + origin_y, per])
	var chosen := _seam(piece.chunk, k)
	var beside := _seam(piece.chunk, 2 * per - origin_y)
	_ok("which lets go of fewer studs than the line beside it",
			int(chosen[0]) + int(chosen[2]) < int(beside[0]),
			"%d against %d" % [int(chosen[0]) + int(chosen[2]), int(beside[0])])
	_ok("counted, for the pass to print", _m.seam_studs_chosen == int(chosen[0]) + int(chosen[2])
			and _m.seam_studs_floor == int(beside[0]),
			"%d, %d" % [_m.seam_studs_chosen, _m.seam_studs_floor])

	var before := _big_parts(piece.chunk)
	var world_point: Vector3 = piece.chunk_transform() \
			* Vector3(local.get_center().x, struck, local.get_center().z)
	var torn: PackedInt32Array = _m._snap_across(piece,
			[{"point": world_point, "collider": RID()}], 100.0)
	var after := _big_parts(piece.chunk)
	_ok("and landing there snaps it in two, along that row", before == 1 and after == 2
			and not torn.is_empty() and _m.seam_breaks == 1 and _m.band_breaks == 0,
			"%d part(s) -> %d, %d joint(s) let go; %s" % [before, after, torn.size(), _m.snap_census_line()])

	# --- a storey line holds its own against an equal ---------------------------------
	print("\na wall with no windows")
	var wall := _w.create_chunk(Vector3i.ZERO, Vector3i(8, 60, 4))
	for course in 18:
		# Running bond: every other course shifted two studs.
		var shift := 2 if course % 2 == 1 else 0
		for x in range(shift, 8 - 3, 4):
			_w.place_block(wall, Vector3i(x, course * 3, 0), brick, 4 + course % 3)
	_w.set_chunk_transform(wall, Transform3D(Basis(), Vector3(-40.0, 0.05, 0.0)))
	ids = PackedInt32Array()
	for id in _w.get_block_count(wall):
		ids.append(id)
	_m.floor_lines = func(_id: int) -> PackedInt32Array: return _every(9)
	var wall_piece := _m.spawn(wall, ids, Vector3.ZERO, Vector3.ZERO, -1, -1)
	await physics_frame
	local = _m._island_aabb(wall_piece)
	origin_y = _w.get_chunk_origin(wall_piece.chunk).y
	# Struck a course off a storey line, every course about as strong as the next.
	at = _m._weak_seam(wall_piece, float(27 + 3 - origin_y) * cy, local.position.y, local.end.y)
	k = roundi(at / cy)
	_ok("struck a course off a storey line, it goes at the line: nothing near is clearly weaker",
			at != INF and posmod(k + origin_y, 9) == 0, "boundary %d" % (k + origin_y))
	# Floors where the building's record says, not every so many plates
	# (Docs/DestructionLod.md 4): a mezzanine at 30, between floors at 27 and 45.
	_m.floor_lines = func(_id: int) -> PackedInt32Array: return PackedInt32Array([0, 9, 18, 30, 45])
	at = _m._weak_seam(wall_piece, float(31 - origin_y) * cy, local.position.y, local.end.y)
	k = roundi(at / cy)
	var line_at: float = _m._floor_line(wall_piece, float(31 - origin_y) * cy,
			local.position.y, local.end.y)
	_ok("floors where the record names them: struck by one off the beat, it goes at that floor",
			at != INF and k + origin_y == 30 and roundi(line_at / cy) + origin_y == 30
			and _m._is_floor_line(wall_piece, line_at)
			and not _m._is_floor_line(wall_piece, float(27 - origin_y) * cy),
			"boundary %d, nearest floor %d" % [k + origin_y, roundi(line_at / cy) + origin_y])

	# --- an old command -----------------------------------------------------------------
	print("\na snap recorded before columns were pulled off")
	for flagged in [false, true]:
		var chunk := _column_and_stack(Vector3(-100.0 - (20.0 if flagged else 0.0), 0.0, 0.0))
		var e := DamageLog.Entry.new()
		e.kind = DamageLog.Kind.PIECE_SNAP
		e.points = PackedVector3Array([DamageLog.grid_frame(_w, chunk) * Vector3(0.5, 12.0 * cy, 0.5)])
		e.normal = Vector3.UP
		e.radius = IslandManager.BREAK_THICKNESS
		e.flags = DamageLog.FLAG_STEP if flagged else 0
		DamageLog.apply_entry(_w, chunk, e)
		var n: int = _w.get_components(chunk).size()
		if flagged:
			_ok("and the same command with the flag parts it in two", n == 2, "%d" % n)
		else:
			_ok("replays as it was made: the stack severed, the column holding, one piece", n == 1,
					"%d" % n)

	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
