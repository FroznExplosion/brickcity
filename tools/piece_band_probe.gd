extends SceneTree

## Big pieces drawn in bands (IslandManager._advance_slices; Docs/HandoffPerf.md
## 6.2): a piece whose mesh would be SLICE_VERTS or more is cut into sections,
## and its bands are built a few a tick -- cut out of the bake on the main
## thread, their meshes made on a worker -- and swapped in whole.
##
##     godot --headless --path . --script res://tools/piece_band_probe.gd
##
## A whole tower is spawned as one piece, as a toppled building is. Checked:
## it is cut into sections; no band shows before they are all up; at the swap
## each section has its band and the one mesh is gone; the meshes were made on
## workers; no tick's cutting runs much past SLICE_TICK_MS; a bake dropped
## half way begins again and the meshes still on a worker are thrown away; and
## a hit afterwards is patched into its band, not a rebuild. Big collapses are
## rare since the strength tree (2026-11-07), so the city passes may not make
## one; this does every time. What a band DRAWS is the renderer's and is not
## read here (headless); city.tscn -- --chamfer checks a patched band's bricks.

const MAX_TICKS := 600

var _pass := 0
var _fail := 0
var _started := false
var _w: BrickWorld
var _m: IslandManager
var _camera: Camera3D


func _init() -> void:
	print("big pieces in bands")
	_w = BrickWorld.new()
	var ground := StaticBody3D.new()
	ground.collision_layer = Layers.WORLD
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(400.0, 1.0, 400.0)
	shape.shape = box
	shape.position = Vector3(0.0, -0.5, 0.0)
	ground.add_child(shape)
	root.add_child(ground)
	_camera = Camera3D.new()
	root.add_child(_camera)
	_m = IslandManager.new()
	root.add_child(_m)
	_m.setup(_w, null, _camera)
	_m.interest = func() -> PackedVector3Array: return PackedVector3Array([Vector3(0, 1, 0)])
	physics_frame.connect(_run)


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _tick() -> void:
	await physics_frame
	_m.tick()


## A tower as one piece, lying in the street beside the camera.
func _piece(at: Vector3) -> BrickIsland:
	var palette := TowerRecipe.bake_palette(_w)
	var c := _w.create_chunk(Vector3i.ZERO, TowerRecipe.chunk_dims(40, 40, 100))
	TowerRecipe.build(_w, c, palette, 40, 40, 100)
	_w.set_chunk_transform(c, Transform3D(Basis(), at))
	var ids := PackedInt32Array()
	for id in _w.get_block_count(c):
		ids.append(id)
	_camera.position = at + Vector3(0.0, 4.0, 14.0)
	return _m.spawn(c, ids, Vector3.ZERO, Vector3.ZERO, -1, -1)


func _shown(nodes: Array) -> int:
	var n := 0
	for node in nodes:
		if is_instance_valid(node) and (node as MeshInstance3D).visible:
			n += 1
	return n


## Ticks until the piece has swapped to its bands (or MAX_TICKS). Returns the
## ticks taken, and the most bands seen drawing before the swap.
func _until_swapped(isl: BrickIsland, swaps0: int) -> Array:
	var early := 0
	var t := 0
	while _m.slice_swaps == swaps0 and t < MAX_TICKS:
		await _tick()
		t += 1
		if isl.slicing:
			early = maxi(early, _shown(isl.slices))
	return [t, early]


func _run() -> void:
	if _started:
		return
	_started = true
	UploadLedger.take()

	print("\na tower spawned whole as one piece")
	var isl := _piece(Vector3(0.0, 0.05, 0.0))
	var sections := _w.get_chunk_sections(isl.chunk)
	_ok("it is cut into sections", sections > 1,
			"%d bricks, %d section(s)" % [_w.get_block_count(isl.chunk), sections])
	var res: Array = await _until_swapped(isl, 0)
	_ok("its bands are built and swapped in", _m.slice_swaps == 1, "after %d tick(s)" % res[0])
	_ok("no band draws before they are all up", int(res[1]) == 0, "%d shown early" % res[1])
	_ok("over more than one tick", int(res[0]) > 1, "%d tick(s)" % res[0])
	var meshes := 0
	for node in isl.bands:
		if is_instance_valid(node) and (node as MeshInstance3D).mesh != null:
			meshes += 1
	_ok("each section has its band, and they draw", isl.bands.size() == sections
			and _shown(isl.bands) == sections and meshes > 0,
			"%d band(s), %d shown, %d with a mesh" % [isl.bands.size(), _shown(isl.bands), meshes])
	_ok("the one mesh is gone", isl.mesh.mesh == null and not isl.slicing)
	var made: Dictionary = UploadLedger.take()
	var on_workers: int = (made.get("piece band", [0, 0]) as Array)[0]
	_ok("the band meshes were made on workers", on_workers == meshes,
			"%d made there, %d with a mesh" % [on_workers, meshes])
	_ok("a tick's cutting stops near its budget",
			_m.slice_tick_worst_ms <= IslandManager.SLICE_TICK_MS + _m.slice_cut_worst_ms + 1.0,
			"worst tick %.1f ms, worst band cut %.1f, worst mesh (worker) %.1f" % [
			_m.slice_tick_worst_ms, _m.slice_cut_worst_ms, _m.slice_mesh_worst_ms])

	print("\na hit on it afterwards")
	var bands_before := isl.bands.duplicate()
	var kill := PackedInt32Array()
	for id in _w.get_block_count(isl.chunk):
		if id % 97 == 0 and _w.get_block_hp(isl.chunk, id) > 0:
			kill.append(id)
	_w.kill_blocks(isl.chunk, kill)
	_m.rebuild_mesh(isl)
	var same := isl.bands.size() == bands_before.size()
	for k in mini(isl.bands.size(), bands_before.size()):
		same = same and isl.bands[k] == bands_before[k]
	_ok("is patched into its bands: the same nodes, nothing rebuilt", same
			and isl.retiring_bands.is_empty() and not isl.slicing and isl.mesh_job == -1,
			"%d brick(s) killed" % kill.size())

	print("\na bake dropped half way through")
	var isl2 := _piece(Vector3(60.0, 0.05, 0.0))
	var restarts0 := _m.slice_restarts
	var swaps0 := _m.slice_swaps
	var t := 0
	while not (isl2.slicing and isl2.slices.size() >= 2) and t < MAX_TICKS:
		await _tick()
		t += 1
	var pending := isl2.slice_pending
	_w.drop_chunk_bake(isl2.chunk)
	var res2: Array = await _until_swapped(isl2, swaps0)
	_ok("begins again, and still swaps in whole", _m.slice_restarts > restarts0
			and _m.slice_swaps == swaps0 + 1 and int(res2[1]) == 0,
			"%d restart(s), %d mesh(es) on a worker when dropped, %d tick(s) after" % [
			_m.slice_restarts - restarts0, pending, res2[0]])
	var orphans := 0
	for node in isl2.mesh.get_children():
		if node is MeshInstance3D and not isl2.bands.has(node) and not (node as Node).is_queued_for_deletion():
			orphans += 1
	_ok("nothing from before the drop is left hanging", orphans == 0 and isl2.bands.size()
			== _w.get_chunk_sections(isl2.chunk), "%d stray node(s)" % orphans)

	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
