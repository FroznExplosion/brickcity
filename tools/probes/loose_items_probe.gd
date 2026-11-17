extends SceneTree

## Items fall, furniture stays clicked on (Docs/Interiors.md 8.16).
##
##     godot --headless --path . --script tools/probes/loose_items_probe.gd
##
## A real LEGO room on its side: the furniture is joined to the floor it stood
## on (now a wall) and stays there; the cups and books are not joined to
## anything and slide down onto what is now the floor. So:
##   * an item's detail parts are marked loose when laid (RoomManifest.build_item
##     -> Block.loose), furniture's other parts not; split_island carries it;
##   * a piece standing upright drops its loose bricks onto its own floor --
##     where they were;
##   * a piece lying on its side drops them straight down, off the floor that
##     became a wall, onto what is below; its furniture stays in its chunk;
##   * what falls keeps its material: the colour a crumb or a heap brick is
##     given carries it (BrickWorld.get_block_rgba, IslandCrumbs.mat_of);
##   * a piece put to sleep and woken (ChunkRecord) keeps its blocks' materials
##     and its loose marks, and so does a save's furniture (AreaSnapshot).

var _pass := 0
var _fail := 0
var _w: BrickWorld
var _palette: Dictionary
var _m: IslandManager
var _started := false


func _init() -> void:
	print("items fall, furniture stays clicked on")
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


## A room's floor (a slab of 2x4s) with a "desk" on it: a brick that is
## furniture (Interior) carrying a brick that is an item (Detail), laid as a
## room lays it. Returns [chunk, furniture id, item id].
func _room(at: Vector3, desk_z := 2, wall := false) -> Array:
	var c := _w.create_chunk(Vector3i.ZERO, Vector3i(12, 16, 12))
	for x in 3:
		for z in 4:
			_w.place_block(c, Vector3i(x * 4, 0, z * 2), _palette["brick_2x4_x"], 4)
	if wall:
		# A wall along the room's low-Z side, three courses up from the floor.
		for course in 3:
			for x in 3:
				_w.place_block(c, Vector3i(x * 4, 3 + course * 3, 0), _palette["brick_2x4_x"], 5)
	RoomTemplates.parts("item:probe")   # loads the libraries, so ours stays
	RoomTemplates._parts["item:probe_desk@0"] = [
		["brick_2x2", Vector3i(0, 0, 0), 0, BuildRecipe.Role.INTERIOR],
		["brick_2x2", Vector3i(0, 3, 0), 0, BuildRecipe.Role.DETAIL],
	]
	var ids := RoomManifest.build_item(_w, c, _palette,
			{"type": "item:probe_desk@0", "cell": Vector3i(4, 3, desk_z), "yaw": 0}, 6)
	_w.set_chunk_transform(c, Transform3D(Basis(), at))
	return [c, ids[0] if ids.size() > 0 else -1, ids[1] if ids.size() > 1 else -1]


## Put a piece where it lies at rest, as the tick does (settle_now: frozen, on
## the settled layer the drop's ray looks for).
func _settle(isl: BrickIsland, xf: Transform3D) -> void:
	isl.body.freeze = true
	isl.body.global_transform = xf * Transform3D(Basis(), isl.local_com)
	_m.settle_now(isl)
	for i in 4:
		await physics_frame
	_w.set_chunk_transform(isl.chunk, isl.chunk_transform())


func _run() -> void:
	if _started:
		return
	_started = true

	print("\nlaid as a room lays it")
	var r := _room(Vector3(0.0, 0.0, 0.0))
	var c: int = r[0]
	var loose: PackedInt32Array = _w.get_loose_blocks(c)
	_ok("the desk's item part is loose, its furniture part is not",
			loose.size() == 1 and loose[0] == r[2] and not loose.has(r[1]), "%s" % [loose])
	_ok("both are decorative (laid like furniture while the building stands)",
			_w.is_block_decorative(c, r[1]) and _w.is_block_decorative(c, r[2]))

	print("\na piece standing upright")
	var ids := PackedInt32Array()
	for id in _w.get_block_count(c):
		ids.append(id)
	var up := _m.spawn(c, ids, Vector3.ZERO, Vector3.ZERO, -1, -1)
	_ok("the loose mark rides into the piece (split_island)", _w.get_loose_blocks(up.chunk).size() == 1)
	await _settle(up, Transform3D(Basis(), Vector3(0.0, 0.0, 0.0)))
	var heap0: int = _m.heap.laid
	var cs := BrickWorld.get_cell_size()
	var item_bottom: float = (up.chunk_transform() * (Vector3(4, 6, 2) * cs)).y
	var got: int = _m.crumbler.drop_loose(up.chunk, _w.get_loose_blocks(up.chunk))
	_ok("its item comes off the piece and lies on the heap", got == 1 and _m.heap.laid == heap0 + 1
			and _w.get_loose_blocks(up.chunk).is_empty(), "%d dropped, heap %d -> %d" % [got, heap0, _m.heap.laid])
	_ok("where it was: on the desk under it", _laid_near(item_bottom), "item bottom %.2f m, heap %s" % [
			item_bottom, _ground_list()])
	_ok("the desk stays in the piece", _w.get_alive_block_count(up.chunk) == ids.size() - 1)

	print("\na piece lying on its side")
	var r2 := _room(Vector3(30.0, 0.0, 0.0))
	var ids2 := PackedInt32Array()
	for id in _w.get_block_count(r2[0]):
		ids2.append(id)
	var side := _m.spawn(r2[0], ids2, Vector3.ZERO, Vector3.ZERO, -1, -1)
	# Turned a quarter about X, the floor standing up as a wall, its lowest
	# edge on the ground.
	await _settle(side, Transform3D(Basis(Vector3.RIGHT, -PI * 0.5), Vector3(30.0, 0.0, 3.0)))
	var start_y: float = (side.chunk_transform() * ((Vector3(4, 6, 2) + Vector3(1, 1.5, 1)) * cs)).y
	var heap1: int = _m.heap.laid
	var got2: int = _m.crumbler.drop_loose(side.chunk, _w.get_loose_blocks(side.chunk))
	_ok("its item comes off the wall its floor became", got2 == 1 and _m.heap.laid == heap1 + 1,
			"%d dropped" % got2)
	_ok("and lies lower, on what is below it now", _lowest_ground() < start_y - 0.3,
			"started at %.2f m, heap grounds %s" % [start_y, _ground_list()])
	_ok("the desk stays joined to the wall", _w.get_alive_block_count(side.chunk) == ids2.size() - 1
			and _w.get_loose_blocks(side.chunk).is_empty())

	print("\na room on its side, lying on its wall")
	# The desk three studs out from the wall; turned so that wall is down
	# (a quarter about X takes the room's low Z to the bottom).
	var r3 := _room(Vector3(60.0, 0.0, 0.0), 5, true)
	var ids3 := PackedInt32Array()
	for id in _w.get_block_count(r3[0]):
		ids3.append(id)
	var lying := _m.spawn(r3[0], ids3, Vector3.ZERO, Vector3.ZERO, -1, -1)
	await _settle(lying, Transform3D(Basis(Vector3.RIGHT, -PI * 0.5), Vector3(60.0, 0.0, 3.0)))
	var wall_face: float = (lying.chunk_transform() * Vector3(0.0, 0.0, 2.0 * cs.z)).y
	var g0 := _ground_list().size()
	var got3: int = _m.crumbler.drop_loose(lying.chunk, _w.get_loose_blocks(lying.chunk))
	var grounds := _ground_list()
	var new_ground: float = float(grounds[grounds.size() - 1]) if grounds.size() > g0 else -INF
	_ok("its item comes down on the wall, not through to the ground", got3 == 1
			and absf(new_ground - wall_face) < 0.06, "landed on %.2f m, the wall's face %.2f m" % [
			new_ground, wall_face])
	_ok("the desk stays joined to the floor, now standing up", _w.get_alive_block_count(lying.chunk) == ids3.size() - 1)

	print("\nwhat falls keeps its material")
	var c4 := _w.create_chunk(Vector3i.ZERO, Vector3i(8, 8, 8))
	var wood := _w.place_block(c4, Vector3i(0, 0, 0), _palette["brick_2x4_x"], 1)
	_w.set_block_material(c4, wood, 2)
	var col: Color = _m.crumbler._block_colour(_w, c4, wood)
	_ok("a falling brick's colour carries its material", _m.crumbler.mat_of(col) == 2,
			"material %d, alpha %.4f" % [_m.crumbler.mat_of(col), col.a])
	var plain := _w.place_block(c4, Vector3i(0, 3, 0), _palette["brick_2x4_x"], 1)
	_ok("and a filament brick's says filament", _m.crumbler.mat_of(_m.crumbler._block_colour(_w, c4, plain)) == 0)
	var cr4 = _m.crumbler.crumb_set(Vector3(1.4, 0.42, 0.7), 2)
	var cr0 = _m.crumbler.crumb_set(Vector3(1.4, 0.42, 0.7))
	_ok("crumbs of one size in two materials are two sets, each its size", cr4 != cr0
			and cr4.size == Vector3(1.4, 0.42, 0.7)
			and int(cr4.mmi.get_instance_shader_parameter(&"crumb_mat")) == 2)

	print("\nput to sleep and woken")
	var r5 := _room(Vector3(90.0, 0.0, 0.0))
	var c5: int = r5[0]
	_w.set_block_material(c5, r5[1], 3)
	var rec := ChunkRecord.capture(_w, c5)
	var woke := rec.restore(_w)
	var woke_loose: PackedInt32Array = _w.get_loose_blocks(woke)
	var mats_kept := 0
	for id in _w.get_block_count(woke):
		if _w.get_block_material(woke, id) == 3:
			mats_kept += 1
	_ok("the woken piece still knows its item is loose", woke_loose.size() == 1
			and _w.is_block_decorative(woke, woke_loose[0]), "%s" % [woke_loose])
	_ok("and its desk is still the material it was", mats_kept == 1, "%d of material 3" % mats_kept)
	var data := rec.to_data(_w)
	var back := ChunkRecord.from_data(_w, data)
	_ok("a save of the record keeps both", back != null and back.loose == rec.loose
			and back.materials == rec.materials, "loose %s, materials %s" % [rec.loose, rec.materials])
	var furn: Array = AreaSnapshot.furniture_of(_w, c5)
	var loose_entries := 0
	var mat_entries := 0
	for f in furn:
		if (f as Array).size() > 4 and bool(f[4]):
			loose_entries += 1
		if (f as Array).size() > 3 and int(f[3]) == 3:
			mat_entries += 1
	_ok("a save's furniture says which is loose and what it is made of", loose_entries == 1
			and mat_entries == 1, "%s" % [furn])

	print("\n%d loose bricks dropped" % _m.crumbler.loose_dropped)
	print("\nloose_items_probe: %d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


## The grounds the heap has laid bricks on (BrickHeap._tops: cell -> [[top, ground]]).
func _ground_list() -> Array:
	var out := []
	for k in _m.heap._tops:
		for e in _m.heap._tops[k]:
			out.append(snappedf(float(e[1]), 0.01))
	return out


func _laid_near(y: float) -> bool:
	for g in _ground_list():
		if absf(float(g) - y) < 0.06:
			return true
	return false


func _lowest_ground() -> float:
	var lo := INF
	for g in _ground_list():
		lo = minf(lo, float(g))
	return lo
