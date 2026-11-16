class_name PiecePanes
extends RefCounted

## The painted windows of falling pieces of buildings.
##
## A building in bricks has its windows painted on it (CityDrawing.
## tend_brick_panes): glass with a room behind it, over the gaps its recipe
## leaves in the walls (BuildingShell.window_arrays). Only a STANDING building
## had them. A piece that left it -- a section breaking off, or the whole tower
## toppling -- drew its bricks and nothing else, so its windows were open holes
## all the way down; and the standing building's own panes are hidden while it
## comes apart and freed once it has come down (CityDrawing._hide_falling_panes,
## for "windows stay after a building collapses away"). User, 2026-11-16: a
## building that falls as an island loses its windows, and they do not come
## back however close the player gets while it moves.
##
## Here each piece of a recipe building gets panes of its own, made from ITS
## bricks, hung under its mesh node so they ride it down. A piece keeps the cells
## its bricks had in the building (BrickWorld.split_island) and its chunk starts
## at the corner of what it took, so the building's own window layout is asked of
## the piece's cells (BuildingShell.standing_copy's `origin`) and the panes hang
## that far back from the piece's origin. Each is made again when the piece's
## bricks change (its chunk version), the old ones drawn until the new ones are
## hung: a section that splits again shows glass over its new edge for the tick
## or two the worker takes, not for the seconds a standing building waits to be
## quiet.
##
## A building that topples whole hands its panes over as they are (hand_over):
## the piece is the building's own chunk, in the same space, so nothing moves.
## Shown only if its bricks have not changed since they were made; made again
## from the piece first either way.
##
## Made on a worker, one at a time, the stale ones first and then the nearest
## (as the standing buildings' are). A pane's room fades are left at their
## defaults: no room of a piece is streamed (RoomStreaming), so every window
## shows its painted room.

## Pieces past this far are given none (what they have they keep).
const RANGE := 120.0
## Fewer bricks than this cannot hold a window (sill, lintel, the floor behind).
const MIN_BLOCKS := 40
## What hanging a mesh may wait for on the tick's clock (CityDrawing.PANES_MS).
const PANES_MS := 1.0
## The room fades a pane node starts with (shaders/window_interior.gdshader).
const NO_FADE := Vector4(-1.0, 0.0, -1.0, 0.0)

var world: BrickWorld
var registry: BuildingRegistry
var islands: IslandManager
var retirer: MeshRetirer
## Meshes made on the worker, or their arrays handed back and made here
## (City.worker_meshes: off headless).
var worker_meshes := true

## BrickIsland -> [pane node or null, chunk version it was made from (-1: owed)]
var _have := {}
## [task, [mesh or arrays], BrickIsland, version, origin] while one is being made.
var _job: Array = []

var built := 0          ## pane meshes made for pieces, all told
var hung := 0           ## of those, hung on a piece with windows standing
var handed := 0         ## toppled buildings whose panes went over to their piece
var remade := 0         ## made again because the piece's bricks changed


## A building toppling whole: its painted windows (CityDrawing.take_panes) go to
## the piece it became. `owed`: its bricks changed since they were made
## (CityScene._panes_owed), so they are hidden until made again here.
func hand_over(isl: BrickIsland, node: MeshInstance3D, owed: bool) -> void:
	if node == null:
		return
	if isl == null or not isl.is_valid() or isl.mesh == null or not is_instance_valid(isl.mesh):
		node.queue_free()
		return
	isl.mesh.add_child(node)
	node.transform = Transform3D.IDENTITY
	node.visible = not owed
	for i in RoomStreaming.PANE_VECS:
		InstanceParams.put(node, StringName("room_fade%d" % i), NO_FADE)
	_have[isl] = [node, -1]
	handed += 1


## Once a tick: hang what a worker has made, and set the next one going.
func tend(here: Vector3) -> void:
	if not _harvest():
		return
	for isl in _have.keys():
		var entry: Array = _have[isl]
		if not (isl as BrickIsland).is_valid() \
				or (entry[0] != null and not is_instance_valid(entry[0])):
			_have.erase(isl)
	var best: BrickIsland = null
	var best_d := INF
	var best_stale := false
	for isl in islands.islands:
		if not _wants(isl):
			continue
		var entry = _have.get(isl)
		var stale := entry != null
		if stale and int(entry[1]) == world.get_chunk_version(isl.chunk):
			continue
		var d := isl.body.global_position.distance_to(here)
		if not stale and d > RANGE:
			continue
		if (stale and not best_stale) or (stale == best_stale and d < best_d):
			best = isl
			best_d = d
			best_stale = stale
	if best != null:
		_submit(best)


## A piece of a recipe building, drawn by a mesh of its own, big enough to hold
## a window, and not shrinking away.
func _wants(isl: BrickIsland) -> bool:
	if not isl.is_valid() or isl.mesh == null or not is_instance_valid(isl.mesh):
		return false
	if not isl.landmark or isl.fade_since != 0 or isl.owner < 0:
		return false
	var b := registry.get_building(isl.owner)
	if b == null or b.is_build() or not b.recipe.has("footprint_x"):
		return false
	return world.get_alive_block_count(isl.chunk) >= MIN_BLOCKS


func _submit(isl: BrickIsland) -> void:
	var b := registry.get_building(isl.owner)
	var fx: int = b.recipe.footprint_x
	var fz: int = b.recipe.footprint_z
	var courses: int = b.recipe.courses
	var room_seed := registry.room_seed_of(isl.owner)
	var layout := TowerRecipe.layout(courses)
	var lattice := RoomManifest.lattice_for(fx, fz, courses)
	var program: Dictionary = (b.recipe.get("program", {}) as Dictionary).duplicate(true)
	var origin: Vector3i = world.get_chunk_origin(isl.chunk)
	var standing := BuildingShell.standing_copy(world, isl.chunk,
			BuildingShell.window_rows(courses, layout, lattice), origin)
	var holder := [null]
	var on_worker := worker_meshes
	var task := WorkerThreadPool.add_task(func() -> void:
		var arrays := BuildingShell.window_arrays(fx, fz, courses, room_seed, layout, lattice,
				{}, program, standing)
		if not arrays.is_empty():
			holder[0] = BuildingShell.window_mesh_of(arrays) if on_worker else (arrays as Variant)
			UploadLedger.note("piece panes", UploadLedger.verts_of(arrays)),
			true, "piece panes")
	if _have.has(isl):
		remade += 1
	_job = [task, holder, isl, world.get_chunk_version(isl.chunk), origin]
	built += 1


## Hang the panes a worker has finished. False while one is still being made.
func _harvest() -> bool:
	if _job.is_empty():
		return true
	if not WorkerThreadPool.is_task_completed(int(_job[0])):
		return false
	if TickClock.skip(&"piece_panes", TickClock.until(PANES_MS)):
		return false
	WorkerThreadPool.wait_for_task_completion(int(_job[0]))
	var made = (_job[1] as Array)[0]
	var isl: BrickIsland = _job[2]
	var version: int = _job[3]
	var origin: Vector3i = _job[4]
	_job = []
	if made is Array:
		made = BuildingShell.window_mesh_of(made)   # headless: made here
	var panes: ArrayMesh = made
	if not isl.is_valid() or isl.mesh == null or not is_instance_valid(isl.mesh):
		if panes != null:
			retirer.retire(panes)
		return true
	var entry = _have.get(isl)
	var node: MeshInstance3D = entry[0] if entry != null and entry[0] != null \
			and is_instance_valid(entry[0]) else null
	if panes == null:
		# No window of it stands: what it had goes.
		if node != null:
			node.queue_free()
		_have[isl] = [null, version]
		return true
	if node == null:
		node = MeshInstance3D.new()
		node.material_override = BuildingShell.window_material()
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		isl.mesh.add_child(node)
	elif node.mesh != null:
		retirer.retire(node.mesh)
	node.mesh = panes
	# The building's grid starts `origin` cells behind the piece's.
	node.transform = Transform3D(Basis(), -Vector3(origin.x * BuildingShell.STUD,
			origin.y * BuildingShell.PLATE, origin.z * BuildingShell.STUD))
	node.visible = true
	_have[isl] = [node, version]
	hung += 1
	return true


## The piece's pane node, or null (passes).
func node_of(isl: BrickIsland) -> MeshInstance3D:
	var entry = _have.get(isl)
	if entry == null or entry[0] == null or not is_instance_valid(entry[0]):
		return null
	return entry[0]


func report() -> String:
	return "piece panes: %d made (%d again), %d hung, %d handed over by a toppling building, %d pieces have some" % [
			built, remade, hung, handed, _have.size()]
