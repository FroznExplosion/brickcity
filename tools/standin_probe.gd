extends SceneTree

## A piece is drawn while its mesh is made (IslandStandins;
## Docs/DestructionFirstPrinciples.md B10).
##
##     godot --headless --path . --script tools/standin_probe.gd
##
## A big piece (a recipe tower, 982 bricks: over SYNC_MESH_MAX_BLOCKS, so its
## mesh goes to a worker) is spawned. Checked:
##   * the frames it has no mesh, it has a stand-in: one box per live brick, in
##     the piece's own brick material, under its mesh node (so it moves with it);
##   * a box's colour carries the block's material and grain as its mesh would
##     (alpha), and its place is the block's centre in the chunk's own metres;
##   * when the mesh is up, the stand-in is gone -- and never both drawing;
##   * with stand-ins off, the piece is blind those frames, as before (the A/B).

var _pass := 0
var _fail := 0
var _w: BrickWorld
var _palette: Dictionary
var _m: IslandManager
var _started := false


func _init() -> void:
	print("a piece is drawn while its mesh is made")
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


func _tower_piece(at: Vector3) -> BrickIsland:
	var c := _w.create_chunk(Vector3i.ZERO, TowerRecipe.chunk_dims(28, 16, 30))
	TowerRecipe.build(_w, c, _palette, 28, 16, 30)
	_w.set_chunk_transform(c, Transform3D(Basis(), at))
	var ids := PackedInt32Array()
	for id in _w.get_block_count(c):
		ids.append(id)
	return _m.spawn(c, ids, Vector3.ZERO, Vector3.ZERO, -1, -1)


func _standin_of(isl: BrickIsland) -> Node3D:
	if isl.mesh == null:
		return null
	for ch in isl.mesh.get_children():
		if ch.name.begins_with("StandIn") and not ch.is_queued_for_deletion():
			return ch
	return null


func _instances(holder: Node3D) -> int:
	var n := 0
	for mmi in holder.get_children():
		n += (mmi as MultiMeshInstance3D).multimesh.instance_count
	return n


func _run() -> void:
	if _started:
		return
	_started = true

	print("\na big piece, its mesh on a worker")
	var piece := _tower_piece(Vector3(0.0, 0.05, 0.0))
	var alive := _w.get_alive_block_count(piece.chunk)
	_ok("it is over the bake-it-here limit, so it waits on a worker",
			alive > IslandManager.SYNC_MESH_MAX_BLOCKS and _m._mesh_queue.has(piece),
			"%d bricks" % alive)
	await process_frame
	await process_frame
	var blind_frames := 0
	var stood_frames := 0
	var both := 0
	var first_holder: Node3D = null
	var seen := {}   ## what the first stand-in was, read the frame it was there
	for f in 240:
		var blind := _m.is_blind(piece)
		var holder := _standin_of(piece)
		if blind:
			blind_frames += 1
			if holder != null:
				stood_frames += 1
				if first_holder == null:
					first_holder = holder
					var mmi0 := holder.get_child(0) as MultiMeshInstance3D
					seen = {"boxes": _instances(holder), "same_material":
							mmi0.material_override == piece.mesh.material_override,
							"parent_is_mesh": holder.get_parent() == piece.mesh}
		elif holder != null:
			both += 1
		if not blind and f > 2:
			break
		_m.tick()   # the city ticks the manager; it drains the mesh queue
		await process_frame
	_ok("every frame it had no mesh, a stand-in drew it", blind_frames > 0 and stood_frames == blind_frames,
			"%d frame(s) without a mesh, %d stood in" % [blind_frames, stood_frames])
	_ok("and never both at once", both == 0, "%d frame(s) both" % both)
	_ok("one box per live brick", int(seen.get("boxes", -1)) == alive,
			"%d boxes, %d bricks" % [int(seen.get("boxes", -1)), alive])
	# (A probe's manager has no brick material set: null on both.)
	_ok("in the piece's own brick material", bool(seen.get("same_material", false)))
	_ok("under its mesh node, so it moves with it", bool(seen.get("parent_is_mesh", false)))
	print("    %s" % _m.standins.census_line())
	_ok("gone once the mesh is up", _standin_of(piece) == null and not _m.is_blind(piece))

	print("\nwhat a box carries")
	var c := _w.create_chunk(Vector3i.ZERO, Vector3i(8, 8, 8))
	var b := _w.place_block(c, Vector3i(2, 3, 1), _palette["brick_2x4_x"], 4)
	_w.set_block_material(c, b, 2)
	var bufs: Dictionary = _w.get_standin_buffers(c)
	var cs := BrickWorld.get_cell_size()
	var size := Vector3(4, 3, 2) * cs
	var buf: PackedFloat32Array = bufs.get(size, PackedFloat32Array())
	_ok("one buffer for the one size, sixteen floats", bufs.size() == 1 and buf.size() == 16,
			"%s" % [bufs.keys()])
	if buf.size() == 16:
		var centre := Vector3(buf[3], buf[7], buf[11])
		var want := Vector3(2, 3, 1) * cs + size * 0.5
		_ok("its place is the block's centre in the chunk's own metres", centre.is_equal_approx(want),
				"%v vs %v" % [centre, want])
		var code := roundi((1.0 - buf[15]) * 255.0 + 0.25)
		_ok("its alpha is the mesher's: material 2, grain along X (the long side)", code & 31 == 2
				and (code >> 5) == 0, "code %d" % code)

	print("\nwith stand-ins off")
	_m.standins.enabled = false
	var other := _tower_piece(Vector3(30.0, 0.05, 0.0))
	await process_frame
	await process_frame
	var blind_off := 0
	var drawn_off := 0
	for f in 240:
		if _m.is_blind(other):
			blind_off += 1
			if _standin_of(other) != null:
				drawn_off += 1
		elif f > 2:
			break
		_m.tick()
		await process_frame
	_ok("blind as before, nothing standing in", drawn_off == 0,
			"%d frame(s) blind, %d stood in" % [blind_off, drawn_off])

	print("\nstandin_probe: %d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
