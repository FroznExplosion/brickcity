extends SceneTree

## A piece snapped across X or Z cracks along its bond (Docs/CollapseNext.md 0,
## item 18).
##
##     godot --headless --path . --script tools/crack_probe.gd
##
## Joints run along a piece's own Y only, so a slab or a wall lying flat, struck
## the long way, has no seam to part at. It tore a band of bricks across it
## into loose bricks -- the most single bricks a landing made. Now each brick
## goes with the side its middle is on, and the crack steps round them:
##
##   * BrickWorld.crack_studs counts, for each plane across the axis, the studs
##     between bricks whose middles are on opposite sides of it;
##   * IslandManager._weak_crack picks the plane in reach that lets go of the
##     fewest, and the piece keeps it as a crack (cracks_x / cracks_z);
##   * split_if_broken cuts the piece along it (BrickWorld.crack_components) --
##     what leaves goes as a DETACH, like anything a piece sheds.

var _pass := 0
var _fail := 0
var _started := false
var _w: BrickWorld
var _palette: Dictionary
var _m: IslandManager


func _init() -> void:
	print("a slab snapped across cracks along its bond")
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


func _run() -> void:
	if _started:
		return
	_started = true

	# --- three bricks ------------------------------------------------------------------
	print("\ntwo bricks side by side and one across them")
	var c := _w.create_chunk(Vector3i.ZERO, Vector3i(16, 8, 8))
	var brick: int = _palette["brick_2x4_x"]
	_w.place_block(c, Vector3i(0, 0, 0), brick, 4)
	_w.place_block(c, Vector3i(4, 0, 0), brick, 5)
	_w.place_block(c, Vector3i(2, 3, 0), brick, 6)
	var studs: PackedInt32Array = _w.crack_studs(c, 0, 0, 8)
	_ok("a crack holds by the studs of the brick across it, on the side its middle is not",
			studs == PackedInt32Array([0, 0, 4, 4, 4, 4, 0, 0, 0]), str(studs))
	var parts: Array = _w.crack_components(c, PackedInt32Array([4]), PackedInt32Array())
	_ok("cracked at the joint of the two below, the brick across goes with the left one",
			parts.size() == 2 and (parts[0] as PackedInt32Array).size() == 2
			and (parts[1] as PackedInt32Array).size() == 1, str(parts))
	_ok("and with no crack it is one piece",
			_w.crack_components(c, PackedInt32Array(), PackedInt32Array()).size() == 1)

	# --- a slab ---------------------------------------------------------------------------
	print("\na slab of the city's kind, lying flat, landing across something")
	var slab := _w.create_chunk(Vector3i.ZERO, TowerRecipe.chunk_dims(28, 12, 2))
	TowerRecipe.build(_w, slab, _palette, 28, 12, 2)
	_w.set_chunk_transform(slab, Transform3D(Basis(), Vector3(0.0, 0.05, 0.0)))
	var ids := PackedInt32Array()
	for id in _w.get_block_count(slab):
		ids.append(id)
	var piece := _m.spawn(slab, ids, Vector3.ZERO, Vector3.ZERO, -1, -1)
	await physics_frame
	var bricks0 := _w.get_alive_block_count(piece.chunk)
	# A slab of the city's kind has a brick or two joined to nothing already:
	# what any split sheds, crack or no crack.
	var loose0 := _w.get_components(piece.chunk).size() - 1
	var local := _m._island_aabb(piece)
	_ok("it is long along X and short along its own Y: a snap across it has no seam",
			local.size.x > IslandManager.BREAK_MIN_LENGTH and local.size.y < IslandManager.BREAK_MIN_LENGTH,
			"%v" % local.size)
	var origin_x: int = _w.get_chunk_origin(piece.chunk).x
	var struck: Vector3 = piece.chunk_transform() * local.get_center()
	var torn: PackedInt32Array = _m._snap_across(piece, [{"point": struck, "collider": RID()}], 100.0)
	_ok("snapped: a crack, no brick loosened, no band torn",
			torn.is_empty() and piece.cracks_x.size() == 1 and _m.crack_breaks == 1
			and _m.band_breaks == 0, "cracks %s, %d loosened" % [piece.cracks_x, torn.size()])
	var k := piece.cracks_x[0] if not piece.cracks_x.is_empty() else -1
	# In reach of where it was struck (CRACK_REACH either side).
	var cell := BrickWorld.get_cell_size().x
	var k_at := roundi(local.get_center().x / cell)
	var reach := ceili(IslandManager.CRACK_REACH / cell)
	var along: PackedInt32Array = _w.crack_studs(piece.chunk, 0, k_at - reach, k_at + reach)
	var weakest := k >= k_at - reach and k <= k_at + reach
	for s in along:
		if weakest and s > 0 and s < along[k - (k_at - reach)]:
			weakest = false
	_ok("at the plane in reach of the blow that lets go of the fewest studs", weakest,
			"plane %d, struck at %d: %s" % [k, k_at, along])
	piece.shed_cause = "landing: crack"
	# What the crack will cut off, asked before it does: the side away from the
	# piece's bulk, in the building's grid.
	var parts0: Array = _w.crack_components(piece.chunk, piece.cracks_x, PackedInt32Array())
	var shed0: int = _m.spawn_census.shed[1]
	for pass_i in 4:
		_m.split_if_broken(piece)
	var left := _w.get_alive_block_count(piece.chunk)
	var went: int = int(_m.spawn_census.shed[1]) - shed0
	_ok("split along it into two (and what was loose already), every brick on one side or the other",
			parts0.size() == 2 + loose0 and left == (parts0[0] as PackedInt32Array).size()
			and left + went == bricks0 and piece.cracks_x.is_empty(),
			"%d part(s), %d of them loose already: %d kept, %d cut off, of %d" % [
				parts0.size(), loose0, left, went, bricks0])
	var row: Array = _m.shed_census.get("landing: crack", [0, 0, 0, 0])
	_ok("and no single brick came off it but what was loose already: one side, and those",
			int(row[0]) + int(row[1]) == loose0 and int(row[2]) + int(row[3]) == 1,
			"groups of 1 / 2-8 / 9-48 / more: %s; %d loose already" % [row, loose0])

	# --- nothing across ----------------------------------------------------------------------
	print("\nwhere nothing is joined across")
	var c2 := _w.create_chunk(Vector3i.ZERO, Vector3i(40, 8, 8))
	for x in range(0, 36, 4):
		_w.place_block(c2, Vector3i(x, 0, 0), brick, 4)
	_ok("a row of bricks side by side holds nothing across any plane",
			_w.crack_studs(c2, 0, 0, 36).count(0) == 37)

	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
