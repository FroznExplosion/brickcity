extends Node

## How the city's buildings are drawn: the bands a building's bricks are baked
## into (on workers, a budget a tick), the far view (boxes, a damage texture,
## coarse meshes from bricks), glass and panes in bricks, the sun's shadows and
## the shadow stand-ins of what is far.
##
## A part of the city scene, made by it (CityScene.drawing), and moved out of
## city_scene.gd so the drawing is in one place. It holds its own state; what
## it reads of the city's it reads through `city` -- typed against the city's
## script, so a name the city no longer has is a parse error here -- and a
## loop reads the city's members once, before it starts, never per pass.

const City := preload("res://scripts/city_scene.gd")

var city: City

var _band_cpp_ms := 0.0

var _band_upload_ms := 0.0

var _band_builds := 0

var _band_worst := 0.0

## How much band building a tick may do. A band of one of the big shapes is a
## few milliseconds; the point is that a building's worth of them is not one
## frame's problem. A count of 2 was for bands across the whole building; a
## tile (SECTION_STUDS) is a sixth of the big tower's band, and at 2 a tick its
## 96 tiles kept the shell up -- and the solve waiting -- 40 ticks after a hit
## (--breaklag --big). The time and the vertices below are what bound a tick.
const BANDS_PER_TICK := 12

const BAND_BUDGET_MS := 6.0

## And how many vertices of band meshes may be handed over in one tick. A mesh
## built on a worker is not free on this thread: the worker packs the arrays,
## but the renderer creates the buffers on the main thread, at the next call
## into it -- measured on a 62,000-vertex mesh, 3-4 ms built here against 1-1.5
## attached from a worker. So what the workers finish in one tick is paid in
## one tick, and this keeps that bounded. Lower than a piece's
## (IslandManager.UPLOAD_VERTS_PER_TICK): a band waiting still draws its old
## mesh, and a piece waiting draws nothing.
const BAND_VERTS_PER_TICK := 60000

## A band with at least this many vertices is uploaded on a worker, as a big
## piece's mesh is (IslandManager.THREAD_MESH_VERTS). Of what a band cost,
## four fifths was handing the arrays to the renderer -- 98 ms of 120 across a
## stress pass, a band of a big tower 3-7 ms, two a tick -- and the arrays
## themselves come out of the bake in a fraction of a millisecond. About two
## thirds of the handing-over moves to the worker (BAND_VERTS_PER_TICK says
## where the rest goes). The band's old mesh goes on drawing until the new one
## is attached, and a band waits behind a piece for a worker, since a piece
## without a mesh is a hole and a band without a new one is not.
## Now every band (2026-10-23): it was 4,000 vertices, and a band under it,
## a few hundred vertices, took 6-13 ms in the tick on a street walk -- handing
## arrays to the renderer here waits for whatever a worker is uploading, and
## something nearly always is (bands, pieces, the near tier, terrain, glass).
## It was the biggest part of most of the walk's long frames (PerfCaps.md 4).
const BAND_THREAD_VERTS := 0

const BAND_THREAD_VERTS_HEADLESS := 4000

var _band_verts_now := 0

## building id -> which rebuild of its bands is current. A job from an older
## pass is thrown away when it lands, not attached over a newer band.
var _band_pass := {}

var band_jobs_done := 0

var _full_rebuilds := 0

## The collision boxes of a shell, and the AI's proxies of them.
## A shell's windows -- panes with a room painted behind each -- are built
## apart from the shell: a tall tower's are 1-10 ms, as much again as its
## shell, and a city streaming in made four shells and their windows in one
## tick, 33 ms (2026-10-15). A shell stands a tick or two without its glass --
## solid bands where the panes go, at a shell's distance.
##
## Built on workers (BuildingShell.window_arrays), GLASS_JOBS at a time, the
## nearest owed first; the main thread only turns the arrays into a mesh and
## hangs it on the shell. On the main thread it was 2.7 ms every tick of a
## bench over an 800-building city, 10 ms at worst (2026-10-18), and most of
## it for shells the streamer was about to take back: so a shell past the
## line where its banded tier is swapped for the coarse one waits (kept owed,
## not built) until it is either replaced -- its successor owes its own -- or
## near again. A shell drawn from its bricks (`real`) asks the bricks about
## each pane: a copy of which cells stand (BuildingShell.standing_copy), so it is made on a
## worker as well (it was built here, 3-8 ms a tick; PerfCaps.md 4).
const GLASS_JOBS := 4

var glass_built := 0

## What the glass cost the main thread (the exit report's "[prof] glass"): a
## tick's _build_owed_glass, summed over every tick it ran and the worst one.
## On the main thread it was 2.7 ms a tick, 10 ms at worst (above).
var _glass_usec := 0

var _glass_ticks := 0

var _glass_worst_usec := 0

## Of it: the worst worker result turned into a mesh and hung, and the worst
## window built here from the live bricks (a shell drawn from its bricks).
var _glass_hang_worst_usec := 0

const BRICK_SHADOW_RANGE := 15.0

## Proxies built or rebuilt per pass: a profile and a shell are ~0.5 ms.
const SHADOW_PROXIES_PER_PASS := 2

## A piece of wreckage up to this radius is "small" (metres, BrickIsland.radius).
const SMALL_ISLAND_RADIUS := 2.5

const SMALL_SHADOW_RANGE := 30.0

## Directional shadows reach this far, so a tower's shadow does too. The splits
## keep the first cascades as tight as the 100 m default had them.
const SUN_SHADOW_DISTANCE := 400.0

var _shadow_proxy := {}       ## building id -> MeshInstance3D, shadows only

var _shadow_proxy_alive := {} ## building id -> chunk version when it was built

## A proxy is rebuilt once its building has stopped losing bricks -- the same
## chunk version two passes running -- or after SHADOW_STALE_PASSES of it going on.
## Rebuilt on every pass that saw a brick go, a building being taken apart
## rebuilt its proxy every eight ticks, and a proxy is not the 0.5 ms above for
## a big one: 10-28 ms (6,000-22,000 bricks), the worst tick of a collapse
## after the solve's. A shadow a second or two behind the bricks it is cast
## by, while they are still coming down, is not something anyone sees.
const SHADOW_STALE_PASSES := 8

var _shadow_seen := {}        ## building id -> chunk version at the last pass

var _shadow_stale := {}       ## building id -> passes it has been stale

var _shadow_stats := {"proxies": 0, "bricks_casting": 0, "small_quiet": 0}

## Room for this many far instances before the buffer has to grow.
const FAR_INITIAL_CAPACITY := 256

var _far_fade := {}   ## building id -> 1.0 while its box crossfades with a shell

## Rows of damage before the texture has to grow.
const FAR_DMG_INITIAL_ROWS := 16

var _far_slot := {}   ## building id -> its instance in the far MultiMesh

var _far_on := {}     ## building id -> true while its far box is drawn

var _far_dmg_row := {}                  ## building id -> its row of damage

var _far_dmg_free: Array[int] = []      ## rows given back

var _far_dmg_rows := 0                  ## rows handed out, ever

var _far_dmg_width := 0                 ## texels a row: four per band

var _far_dmg_height := 0

var _far_dmg_bytes := PackedByteArray()

var _far_dmg_tex: ImageTexture = null

var _far_dmg_dirty := false

var far_real_built := 0

## A building drawn in bricks has painted windows too, past the range its rooms
## are drawn in (Docs/DestructionLod.md 3.2): the shell's panes, each only
## where its window still stands in the bricks (`_cell_standing`, as a
## demeshed one's, Structures.md 4.2), hidden inside InteriorGroups'
## range by the shader's `near_hide` -- the rooms dither in as they dither out.
## Before, a building in bricks showed its rooms empty past INTERIOR_RANGE and
## a shot from mid range changed painted windows into drawn furniture.
## Made again once its bricks have changed and it is quiet (_interior_unsure),
## nearest first, one a pass.
var _brick_panes := {}    ## building id -> its pane node, a child of its brick node

var brick_panes_built := 0

var brick_panes_ms := 0.0

## A building in bricks far off is drawn as its coarse stand-in -- the live
## bricks' outer surface merged across bricks of a colour, brick outlines
## still drawn from its UV2 (BrickWorld.build_chunk_coarse_mesh, a far
## piece's stand-in) -- instead of its bands, every brick's faces. Looking down
## a street of twelve buildings in bricks the bands were 4.6M triangles and
## 16.7 ms of a 21.7 ms GPU frame; the four past 80 m drawn coarse, 1.7M
## triangles became 140k and the frame 12.7 ms, the picture the same
## (PerfCaps.md 5). Past FAR_COARSE_RANGE, quiet for FAR_COARSE_QUIET_MS; back
## to its bands inside FAR_COARSE_BACK, or the moment a band of it changes. The
## bands stay built underneath, only hidden: what a hit patches is them.
const FAR_COARSE_RANGE := 60.0

const FAR_COARSE_BACK := 50.0

const FAR_COARSE_QUIET_MS := 3000

var _far_coarse := {}        ## building id -> its stand-in node (bands hidden)

var far_coarse_built := 0


func _init(c: Node3D) -> void:
	city = c
	name = "Drawing"


func glass_note(usec: int) -> void:
	_glass_usec += usec
	_glass_ticks += 1
	_glass_worst_usec = maxi(_glass_worst_usec, usec)


func build_owed_glass() -> void:
	# Read once, not per pass of the loop below: the city never swaps these.
	var h_glass_jobs := city._glass_jobs
	var h_registry := city.registry
	# Land what the workers finished.
	for i in range(h_glass_jobs.size() - 1, -1, -1):
		var job: Array = h_glass_jobs[i]
		if not WorkerThreadPool.is_task_completed(int(job[0])):
			continue
		WorkerThreadPool.wait_for_task_completion(int(job[0]))
		h_glass_jobs.remove_at(i)
		var gm = job[1][0]
		if gm is Array:
			gm = BuildingShell.window_mesh_of(gm)   # headless: made here (worker_meshes)
		if gm == null or not is_instance_valid(job[2]) \
				or not city._is_shell_node(int(job[3]), job[2]):
			continue
		var t_hang := Time.get_ticks_usec()
		_hang_glass(job[2], gm, job[4])
		_glass_hang_worst_usec = maxi(_glass_hang_worst_usec, Time.get_ticks_usec() - t_hang)
	if city._glass_owed.is_empty():
		return
	# The owed, nearest first; the gone dropped, the about-to-go kept back.
	var here := city.camera.global_position if city.camera != null else Vector3.ZERO
	var swap_at := City.SHELL_DETAIL_RANGE + City.SHELL_HYSTERESIS
	var live: Array = []
	var due: Array = []   ## [distance, index into live]
	for owed in city._glass_owed:
		var mi = owed[0]
		var id: int = owed[1]
		# Replaced or freed since -- its successor owes its own.
		if not is_instance_valid(mi) or not city._is_shell_node(id, mi):
			continue
		var b := h_registry.get_building(id)
		if b == null:
			continue
		live.append(owed)
		var dist := b.xform.origin.distance_to(here)
		if dist <= swap_at:
			due.append([dist, live.size() - 1])
	city._glass_owed = live
	if due.is_empty():
		return
	due.sort_custom(func(a: Array, c: Array) -> bool: return float(a[0]) < float(c[0]))
	var taken := {}
	for r in due:
		var owed: Array = city._glass_owed[int(r[1])]
		if h_glass_jobs.size() < GLASS_JOBS:
			_submit_glass(owed)
			taken[int(r[1])] = true
	if not taken.is_empty():
		var left: Array = []
		for i in city._glass_owed.size():
			if not taken.has(i):
				left.append(city._glass_owed[i])
		city._glass_owed = left


func _submit_glass(owed: Array) -> void:
	var id: int = owed[1]
	var b := city.registry.get_building(id)
	var fx: int = b.recipe.footprint_x
	var fz: int = b.recipe.footprint_z
	var courses: int = b.recipe.courses
	var room_seed := city.registry.room_seed_of(id)
	# Made here, where the caches they come from are filled; the worker only
	# reads them. Its own copies of the rest, which this thread may change.
	var layout := TowerRecipe.layout(courses)
	var lattice := RoomManifest.lattice_for(fx, fz, courses)
	var damage: Dictionary = (owed[2] as Dictionary).duplicate(true)
	var program: Dictionary = (b.recipe.get("program", {}) as Dictionary).duplicate(true)
	# A window still in bricks asks the bricks which panes stand: a copy of
	# them, made here (it was the whole build here, 3-8 ms a tick, PerfCaps.md 4).
	var standing := Callable()
	if owed[4] and b.is_materialised():
		standing = BuildingShell.standing_copy(city.world, b.chunk,
				BuildingShell.window_rows(courses, layout, lattice))
	# The mesh is made there too: handed to the renderer here, it waited for
	# whatever else was being uploaded.
	var holder := [null]
	var on_worker := City.worker_meshes
	var task := WorkerThreadPool.add_task(func() -> void:
		var arrays := BuildingShell.window_arrays(fx, fz, courses, room_seed, layout,
				lattice, damage, program, standing)
		if not arrays.is_empty():
			holder[0] = BuildingShell.window_mesh_of(arrays) if on_worker else (arrays as Variant)
			UploadLedger.note("glass", UploadLedger.verts_of(arrays)),
			true, "shell glass")
	glass_built += 1
	city._glass_jobs.append([task, holder, owed[0], id, owed[3]])


func _hang_glass(mi: MeshInstance3D, panes: Mesh, fades: bool) -> void:
	# Read once, not per pass of the loop below: the city never swaps these.
	var h_retirer := city._retirer
	# One set a shell: a shell drawn from its bricks has its panes asked again
	# after a hit (_refresh_real_shell), and the old set goes as the new hangs.
	for c in mi.get_children():
		if c is MeshInstance3D and (c as MeshInstance3D).material_override == BuildingShell.window_material():
			h_retirer.retire((c as MeshInstance3D).mesh)
			c.queue_free()
	var glass := MeshInstance3D.new()
	glass.mesh = panes
	glass.material_override = BuildingShell.window_material()
	glass.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if fades:
		city._fade_out(glass)
	mi.add_child(glass)


## Build every band of a building's mesh from scratch.
##
## The expensive path, and the one bands exist to make cheaper: it is O(the
## building) and a promotion runs it. What bands change is that the NEXT one --
## a blast, a piece coming off -- is O(the band).
func rebuild_bands(id: int, chunk: int) -> void:
	# Read once, not per pass of the loop below: the city never swaps these.
	var h_retirer := city._retirer
	_full_rebuilds += 1
	var parent: MeshInstance3D = city._brick_nodes[id]
	var n := city.world.get_chunk_sections(chunk)
	# Slots first, bands afterwards, a few a tick. Building all of them here is
	# what the whole-mesh path did and it is the ~104 ms this exists to remove:
	# the total is the same, what changes is that it no longer lands in one
	# frame. The OLD band stays drawn in its slot until its replacement is
	# ready, so nothing flickers on the way through.
	var old: Array = city._brick_bands.get(id, [])
	var nodes: Array = []
	var meshes: Array = []
	var bytes: Array = []
	for si in n:
		nodes.append(old[si] if si < old.size() else null)
		meshes.append(null)
		bytes.append(0)
	for si in range(n, old.size()):
		if is_instance_valid(old[si]):
			h_retirer.retire((old[si] as MeshInstance3D).mesh)
			(old[si] as MeshInstance3D).queue_free()
	city._brick_bands[id] = nodes
	city._brick_band_meshes[id] = meshes
	city._brick_band_bytes[id] = bytes
	city._band_cursor[id] = 0
	_band_pass[id] = int(_band_pass.get(id, 0)) + 1
	# The parent draws nothing itself; it is the transform the bands hang off
	# and the node the furniture is parented to.
	h_retirer.retire(parent.mesh)
	parent.mesh = null
	city._brick_meshes[id] = null
	city._brick_index_bytes[id] = 0


## Build one band of a building's mesh. Returns false when there are none left.
func _build_one_band(id: int) -> bool:
	var pos: int = int(city._band_cursor.get(id, -1))
	if pos < 0:
		return false
	var b := city.registry.get_building(id)
	if b == null or not b.is_materialised() or not city._brick_nodes.has(id):
		city._band_cursor.erase(id)
		return false
	var nodes: Array = city._brick_bands.get(id, [])
	var at := pos
	if at >= nodes.size():
		city._band_cursor.erase(id)
		return false
	# A band built against a stale bake re-bakes the WHOLE chunk on this
	# thread -- measured at 55 ms against 2.6 for an ordinary band, and it
	# lands in one frame. Wait for the worker instead.
	# bake_ready, not has_bake: it is what adopts a finished job. Asking only
	# has_bake waited forever on a bake nobody else collected (a recolour).
	if not city.world.bake_ready(b.chunk):
		if not city.world.bake_pending(b.chunk):
			city.world.bake_chunk_async(b.chunk)
		return true
	var _t0 := Time.get_ticks_usec()
	var arrays: Array = city.world.build_chunk_mesh_section(b.chunk, at)
	var _t1 := Time.get_ticks_usec()
	var ok := not arrays.is_empty() \
			and IslandManager.mesh_arrays_ok(arrays, "building %d band %d" % [id, at])
	if ok:
		city._brick_index_width[id] = IslandManager.index_width(arrays)
		_band_verts_now += (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	if ok and (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() \
			>= (BAND_THREAD_VERTS if City.worker_meshes else BAND_THREAD_VERTS_HEADLESS):
		_submit_band_job(id, at, arrays)
	else:
		var mesh := ArrayMesh.new()
		if ok:
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		_apply_band(id, at, mesh, arrays)
	var _t2 := Time.get_ticks_usec()
	_band_cpp_ms += float(_t1 - _t0) / 1000.0
	_band_upload_ms += float(_t2 - _t1) / 1000.0
	city._prof["bd_cpp"] = float(city._prof.get("bd_cpp", 0.0)) + float(_t1 - _t0) / 1000.0
	city._prof["bd_upload"] = float(city._prof.get("bd_upload", 0.0)) + float(_t2 - _t1) / 1000.0
	_band_builds += 1
	_band_worst = maxf(_band_worst, float(_t2 - _t0) / 1000.0)
	city._band_cursor[id] = pos + 1
	if pos + 1 >= nodes.size():
		city._band_cursor.erase(id)
		return false
	return true


## Hang a finished band mesh in its slot.
func _apply_band(id: int, at: int, mesh: ArrayMesh, arrays: Array) -> void:
	# Its bricks changed: its far stand-in is out of date, and the bands are
	# what is right (_tend_far_coarse makes it again once it is quiet).
	far_coarse_drop(id)
	var nodes: Array = city._brick_bands.get(id, [])
	if at >= nodes.size() or not city._brick_nodes.has(id):
		city._retirer.retire(mesh)
		return
	var node: MeshInstance3D = nodes[at]
	if node == null or not is_instance_valid(node):
		node = MeshInstance3D.new()
		node.material_override = city.brick_material
		# It sways in the wind, a little (weather.gdshaderinc); a tree more.
		InstanceParams.put(node, &"weather_sway", city._sway_of(id))
		# A tree's crown takes a cap of snow; a building gets real cover.
		InstanceParams.put(node, &"weather_snowcap", 1.0 if city._is_tree(id) else 0.0)
		InstanceParams.put(node, &"grain_origin",
				InstanceParams.of(city._brick_nodes[id] as MeshInstance3D, &"grain_origin"))
		# In the parent's space, which already carries the chunk transform.
		node.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		# Casting as the building does: a shadow shell may be standing in
		# for its bricks (_stream_shadows).
		node.cast_shadow = (city._brick_nodes[id] as MeshInstance3D).cast_shadow
		(city._brick_nodes[id] as MeshInstance3D).add_child(node)
		nodes[at] = node
	else:
		city._retirer.retire(node.mesh)
	var live := mesh != null and mesh.get_surface_count() > 0
	node.mesh = mesh if live else null
	# Its chamfered mesh and studs, when the camera is near (and again: this is
	# a new mesh, from what may be a new bake).
	var band_of := city.registry.get_building(id)
	if live and band_of != null:
		city.brick_near.track(node, band_of.chunk, at)
	else:
		city.brick_near.untrack(node)
	(city._brick_band_meshes[id] as Array)[at] = mesh if live else null
	(city._brick_band_bytes[id] as Array)[at] = (IslandManager.index_patch_bytes(arrays) if live else 0)


## Upload a band's arrays on a worker (BAND_THREAD_VERTS). Attached by
## _harvest_band_jobs when it is done.
## Started at the end of the tick, as a piece's are (IslandManager.
## _submit_mesh_job says why).
func _submit_band_job(id: int, at: int, arrays: Array) -> void:
	var holder := [null]
	var work := func() -> void:
		var m := ArrayMesh.new()
		m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {},
				IslandManager.UPLOAD_COMPRESS)
		holder[0] = m
		UploadLedger.note("band", UploadLedger.verts_of(arrays))
	# The chunk's version when these arrays were made: a piece handed this
	# upload unfinished (take_bands) uses it only if that is still so.
	var b := city.registry.get_building(id)
	var alive := city.world.get_chunk_version(b.chunk) \
			if b != null and b.is_materialised() else -1
	city._band_jobs.append([id, at, IslandManager.JOB_NOT_STARTED, holder, arrays,
			int(_band_pass.get(id, 0)), work, alive])


func start_band_jobs() -> void:
	for job in city._band_jobs:
		if int(job[2]) == IslandManager.JOB_NOT_STARTED:
			job[2] = WorkerThreadPool.add_task(job[6] as Callable, false, "building band mesh")


## Whether a building's bands are still on their way: being built, or built
## and still being uploaded.
func bands_building(id: int) -> bool:
	if city._band_cursor.has(id):
		return true
	for job in city._band_jobs:
		if int(job[0]) == id:
			return true
	return false


## Attach the band meshes the workers have finished. `wait_for` >= 0 waits for
## that building's jobs instead of leaving them for the next tick -- for a
## building about to hand its bands on (_take_bands).
func _harvest_band_jobs(wait_for: int = -1) -> void:
	# Read once, not per pass of the loop below: the city never swaps these.
	var h_band_jobs := city._band_jobs
	var h_brick_bands := city._brick_bands
	var h_retirer := city._retirer
	var finished: Array[int] = []
	var k := 0
	while k < h_band_jobs.size():
		var job: Array = h_band_jobs[k]
		var id: int = job[0]
		var task: int = job[2]
		# Waiting for one building: only its jobs, the rest are next tick's.
		if (wait_for >= 0 and id != wait_for) \
				or (wait_for < 0 and (task < 0 or not WorkerThreadPool.is_task_completed(task))):
			k += 1
			continue
		if task < 0:
			# Waited for before it was started: done here and now.
			(job[6] as Callable).call()
		else:
			WorkerThreadPool.wait_for_task_completion(task)
		h_band_jobs.remove_at(k)
		var mesh: ArrayMesh = job[3][0]
		# A pass since superseded, or a building since gone: not attached.
		if int(job[5]) != int(_band_pass.get(id, 0)) or not h_brick_bands.has(id):
			h_retirer.retire(mesh)
			continue
		var ta := Time.get_ticks_usec()
		_apply_band(id, int(job[1]), mesh, job[4])
		city._part("bd_apply", ta)
		band_jobs_done += 1
		if not finished.has(id):
			finished.append(id)
	if wait_for >= 0:
		return
	var td := Time.get_ticks_usec()
	for id in finished:
		if not bands_building(id):
			_bands_done(id)
	city._part("bd_done", td)


## A building's bands are all built and attached.
func _bands_done(id: int) -> void:
	city._band_first.erase(id)
	if city._band_redo.has(id):
		# Something hit it on the way through. A band built after the hit was
		# built from the bricks as they are, and is right; only the ones built
		# before it are not, and only those are built again -- the old ones
		# drawn meanwhile. It was a whole second pass, with the shell kept up
		# for it: the first shot at a building still in its shell showed on it
		# 14 ticks after it was made bricks, the pieces it cut out drawn twice
		# all that time -- falling, and still in the wall.
		city._band_redo.erase(id)
		var rb := city.registry.get_building(id)
		if rb != null and rb.is_materialised():
			var nodes: Array = city._brick_bands.get(id, [])
			if nodes.size() != city.world.get_chunk_sections(rb.chunk):
				rebuild_bands(id, rb.chunk)
			else:
				# Every band is drawn now, and each wrote the index baseline it
				# was built with (BrickWorld.build_chunk_mesh_section): a patch
				# finds exactly the bands hit since and moves only those. The
				# second pass this was -- every band built before the last hit
				# built again, behind the shell -- kept a mega tower under fire
				# drawn whole by its shell for 30 ticks with its storey shot
				# through, and nothing could leave it until then (CityScene's
				# solve waits on the shell): the walls showed unbroken, then it
				# all came down at once (user, big city, 2026-10-16).
				city._free_shell(id)
				city._remesh(id)
	else:
		# Finished: the shell it was hiding behind can go.
		city._free_shell(id)


## Drain the band work, a budget at a time.
func advance_bands() -> void:
	# Read once, not per pass of the loop below: the city never swaps these.
	var h_band_cursor := city._band_cursor
	var h_band_first := city._band_first
	var th := Time.get_ticks_usec()
	_harvest_band_jobs()
	city._part("bd_harvest", th)
	if h_band_cursor.is_empty():
		return
	var until := TickClock.until(BAND_BUDGET_MS)
	var built := 0
	_band_verts_now = 0
	while built < BANDS_PER_TICK and not h_band_cursor.is_empty() \
			and _band_verts_now < BAND_VERTS_PER_TICK:
		var id: int = h_band_cursor.keys()[0]
		for first in h_band_first:
			if h_band_cursor.has(first):
				id = first
				break
		var at_before := int(h_band_cursor.get(id, -1))
		var verts_before := _band_verts_now
		_build_one_band(id)
		# An empty band is free, and a building laid a storey at a time is
		# mostly empty bands: only a band with something in it -- or a wait on
		# the bake -- counts against BANDS_PER_TICK.
		if _band_verts_now > verts_before or int(h_band_cursor.get(id, -1)) == at_before:
			built += 1
		if not bands_building(id):
			_bands_done(id)
		if Time.get_ticks_usec() >= until:
			break


## Drop a building's band nodes, returning them so a caller can hand them on.
## Its bands still being uploaded are not waited for (Docs/WhereWorkRuns.md
## 3.1): with `owed` given, each goes into it as slot -> [task, holder, arrays,
## alive] and its slot in what is returned is empty -- a hole, which the piece
## fills from that upload once it is done (IslandManager._fill_band_holes).
## Without, they are left to finish and thrown away (TaskReaper).
func take_bands(id: int, owed: Variant = null) -> Array:
	# Drawn again, wherever they are going (_far_coarse_drop).
	far_coarse_drop(id)
	var nodes: Array = city._brick_bands.get(id, [])
	var pass_now := int(_band_pass.get(id, 0))
	var k := 0
	while k < city._band_jobs.size():
		var job: Array = city._band_jobs[k]
		if int(job[0]) != id:
			k += 1
			continue
		city._band_jobs.remove_at(k)
		var at := int(job[1])
		var task := int(job[2])
		# A pass since superseded is wanted by nobody.
		if int(job[5]) != pass_now or at < 0:
			TaskReaper.drop(task)
			continue
		if not (owed is Dictionary) or (owed as Dictionary).has(at):
			# Nobody to hang it: left to finish and thrown away. A job not
			# started yet is simply never run (drop ignores it).
			TaskReaper.drop(task)
			continue
		if task == IslandManager.JOB_NOT_STARTED:
			# Submitted this tick and not started yet: started now, on a worker.
			task = WorkerThreadPool.add_task(job[6] as Callable, false, "building band mesh")
		(owed as Dictionary)[at] = [task, job[3], job[4], int(job[7])]
		# Not this node's mesh: the piece makes its own node for the slot.
		if at < nodes.size():
			nodes[at] = null
	_band_pass.erase(id)
	city._band_cursor.erase(id)
	city._band_redo.erase(id)
	city._brick_bands.erase(id)
	city._brick_band_meshes.erase(id)
	city._brick_band_bytes.erase(id)
	return nodes


func setup_sun_shadows(sun: DirectionalLight3D) -> void:
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.directional_shadow_max_distance = SUN_SHADOW_DISTANCE
	# Fractions of the distance: 10, 36 and 120 m, against 10, 20 and 50 m of
	# the default at 100 m. The first cascade, the one a figure's feet are
	# in, is exactly as sharp as it was.
	sun.directional_shadow_split_1 = 0.025
	sun.directional_shadow_split_2 = 0.09
	sun.directional_shadow_split_3 = 0.3
	sun.directional_shadow_blend_splits = true
	sun.directional_shadow_fade_start = 0.9
	# Options > Video: two slices, the near one as sharp as the four's, the
	# far one to the end (PerfCaps.md 2.2).
	if BrickcityMenuHost.sun_cascades == 2:
		sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
		sun.directional_shadow_split_1 = 0.025


## Every so often: who casts what. Cheap -- a distance per brick building and
## per island, and a proxy mesh only when one changes tier or is shot.
func stream_shadows() -> void:
	# Read once, not per pass of the loop below: the city never swaps these.
	var h_brick_nodes := city._brick_nodes
	var h_islands := city.islands
	var h_registry := city.registry
	var h_world := city.world
	var here := city.camera.global_position
	var built := 0
	var casting := 0
	# Proxies whose building has no bricks drawn any more.
	for id in _shadow_proxy.keys():
		if not h_brick_nodes.has(id):
			_drop_shadow_proxy(id)
	for id in h_brick_nodes:
		var b := h_registry.get_building(id)
		if b == null or not b.is_materialised():
			continue
		var alive := h_world.get_chunk_version(b.chunk)
		var stale: bool = not _shadow_proxy.has(id)
		if not stale and int(_shadow_proxy_alive.get(id, -1)) != alive:
			_shadow_stale[id] = int(_shadow_stale.get(id, 0)) + 1
			stale = alive == int(_shadow_seen.get(id, -1)) \
					or int(_shadow_stale[id]) >= SHADOW_STALE_PASSES
		_shadow_seen[id] = alive
		var t_sp := Time.get_ticks_usec()
		if stale and built < SHADOW_PROXIES_PER_PASS and _make_shadow_proxy(b):
			built += 1
			_shadow_stale.erase(id)
		t_sp = city._part("sp_make", t_sp)
		casting += _set_brick_shadows_near(id, here)
		city._part("sp_near", t_sp)
	var quiet := 0
	var proxied := 0
	for isl in h_islands.islands:
		if isl == null or not is_instance_valid(isl.mesh):
			continue
		var dist := isl.mesh.global_position.distance_to(here)
		var cast := isl.radius > SMALL_ISLAND_RADIUS \
				or dist < SMALL_SHADOW_RANGE + isl.radius
		# A big piece further off casts its coarse stand-in instead of its
		# bricks once it has one (IslandManager.want_shadow_proxy).
		var proxy := false
		if cast and not isl.coarse and isl.radius > SMALL_ISLAND_RADIUS \
				and dist > BRICK_SHADOW_RANGE + isl.radius:
			h_islands.want_shadow_proxy(isl)
			proxy = h_islands.has_shadow_proxy(isl)
		var mode := (GeometryInstance3D.SHADOW_CASTING_SETTING_ON if cast and not proxy
				else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)
		if isl.mesh.cast_shadow != mode:
			isl.mesh.cast_shadow = mode
		for band in isl.bands:
			if is_instance_valid(band) and (band as GeometryInstance3D).cast_shadow != mode:
				(band as GeometryInstance3D).cast_shadow = mode
		if is_instance_valid(isl.shadow_mesh) and isl.shadow_mesh.visible != proxy:
			isl.shadow_mesh.visible = proxy
		if proxy:
			proxied += 1
		if not cast:
			quiet += 1
	_shadow_stats = {"proxies": _shadow_proxy.size(), "bricks_casting": casting,
			"small_quiet": quiet, "pieces_proxied": proxied}


## Which of a building's bricks cast. Without a shadow shell, all of them.
## With one, only the bands (and extra frames) within BRICK_SHADOW_RANGE of the
## camera: a tower beside you is mostly far above you, and the part that is
## not is where a stud's shadow can be seen. Where both cast, the shadow is the
## same. Returns how many brick nodes cast.
func _set_brick_shadows_near(id: int, here: Vector3) -> int:
	var all: bool = not _shadow_proxy.has(id)
	var nodes: Array = []
	var mi = city._brick_nodes.get(id)
	if is_instance_valid(mi):
		nodes.append(mi)
		nodes.append_array((mi as Node).get_children())
	nodes.append_array(city._frame_nodes.get(id, []))
	var casting := 0
	for node in nodes:
		if not is_instance_valid(node) or not (node is GeometryInstance3D):
			continue
		var g := node as GeometryInstance3D
		var on := all
		if not on and g is MeshInstance3D and (g as MeshInstance3D).mesh != null:
			var box: AABB = g.global_transform * (g as MeshInstance3D).get_aabb()
			on = City._box_distance(box, here) < BRICK_SHADOW_RANGE
		# Only when it changes: every set is a renderer call, and this pass
		# set every node of every building in bricks every eighth tick
		# (PerfCaps.md 4).
		var mode := (GeometryInstance3D.SHADOW_CASTING_SETTING_ON if on
				else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)
		if g.cast_shadow != mode:
			g.cast_shadow = mode
		if on:
			casting += 1
	return casting


func _set_brick_shadows(id: int, on: bool) -> void:
	var mode := (GeometryInstance3D.SHADOW_CASTING_SETTING_ON if on
			else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)
	var mi = city._brick_nodes.get(id)
	if is_instance_valid(mi):
		(mi as MeshInstance3D).cast_shadow = mode
		for band in (mi as Node).get_children():
			if band is GeometryInstance3D:
				(band as GeometryInstance3D).cast_shadow = mode
	for node in city._frame_nodes.get(id, []):
		if is_instance_valid(node) and node is GeometryInstance3D:
			(node as GeometryInstance3D).cast_shadow = mode


## A shadow-only shell of a materialised building, from what is standing now.
func _make_shadow_proxy(b: BuildingRegistry.Building) -> bool:
	if city._shadow_jobs.has(b.id):
		return false  # one on its way already
	if b.is_build():
		# A build's shell reads the world's blocks: here, as it always was.
		var built: Mesh = BuildShell.build_mesh(city.world, b.build, city._dead_by_frame(b), false)
		if built == null:
			return false
		_attach_shadow_proxy(b, built, city.world.get_chunk_version(b.chunk))
		return true
	# A recipe building's shell is arithmetic on the recipe and the damage
	# masks, and nothing of the world: only the masks are worked out here (they
	# read the bricks), the rest on a worker. Built here it was 4-25 ms a proxy
	# -- the biggest thing left at the top of a collapse's worst ticks.
	var fx: int = b.recipe.footprint_x
	var fz: int = b.recipe.footprint_z
	var courses: int = b.recipe.courses
	var profile := city.registry.live_damage_profile(b.id)
	var layout: Array = TowerRecipe.layout(courses)
	var holder := [null]
	var work := func() -> void:
		holder[0] = BuildingShell.build_mesh(fx, fz, courses, profile, layout)
		UploadLedger.note("building shadow", -1)
	var task := WorkerThreadPool.add_task(work, false, "shadow proxy")
	city._shadow_jobs[b.id] = [task, holder, city.world.get_chunk_version(b.chunk), false]
	return true


## Hang the proxies the workers have finished. Every tick, and nothing to do
## on most of them.
func harvest_shadow_jobs() -> void:
	# Read once, not per pass of the loop below: the city never swaps these.
	var h_brick_nodes := city._brick_nodes
	var h_shadow_jobs := city._shadow_jobs
	var h_registry := city.registry
	for id in h_shadow_jobs.keys():
		var job: Array = h_shadow_jobs[id]
		if not WorkerThreadPool.is_task_completed(int(job[0])):
			continue
		WorkerThreadPool.wait_for_task_completion(int(job[0]))
		h_shadow_jobs.erase(id)
		var b := h_registry.get_building(int(id))
		# Dropped meanwhile (its bricks given back), or gone.
		if bool(job[3]) or b == null or not b.is_materialised() or not h_brick_nodes.has(id) \
				or job[1][0] == null:
			continue
		_attach_shadow_proxy(b, job[1][0], int(job[2]))


func _attach_shadow_proxy(b: BuildingRegistry.Building, mesh: Mesh, alive: int) -> void:
	var mi: MeshInstance3D = _shadow_proxy.get(b.id)
	if mi == null:
		mi = MeshInstance3D.new()
		mi.name = "ShadowProxy_%d" % b.id
		mi.material_override = city.brick_material
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
		mi.transform = b.xform
		city.add_child(mi)
		_shadow_proxy[b.id] = mi
	mi.mesh = mesh
	# What it was built from: bricks lost since then make it stale again.
	_shadow_proxy_alive[b.id] = alive


func _drop_shadow_proxy(id: int) -> void:
	if city._shadow_jobs.has(id):
		(city._shadow_jobs[id] as Array)[3] = true  # still waited for; never hung
	var mi = _shadow_proxy.get(id)
	if is_instance_valid(mi):
		(mi as Node).queue_free()
	_shadow_proxy.erase(id)
	_shadow_proxy_alive.erase(id)
	_shadow_seen.erase(id)
	_shadow_stale.erase(id)
	_set_brick_shadows(id, true)


## A building past SHELL_RANGE the far box would draw wrongly: it keeps a shell.
func needs_far_shell(b: BuildingRegistry.Building) -> bool:
	# An intact tree is drawn by its instanced set out there instead.
	return b.is_build() and not city._inst_ok(b)


## Can the far box stand in for this building's coarse shell (Stage 2)? A
## recipe building whose damage, if any, is in its profile: not a build, and
## not holding bricks, whose damage the profile does not have yet.
func far_draws_coarse(b: BuildingRegistry.Building) -> bool:
	return not b.is_build() and not b.is_materialised()


## Show or hide one building's far box to match what else draws it.
func far_sync(b: BuildingRegistry.Building) -> void:
	var want: bool
	if city._shell_box.has(b.id):
		# Its coarse shell is drawn by the far box. Kept while the shell is,
		# materialised or not: a building shot at range holds its shell until
		# its bricks are built, and hiding the box would leave nothing drawn.
		want = not b.toppled
	else:
		want = not (b.toppled or b.is_materialised() or city._shells.has(b.id)
				or b.is_build())
	# Under a banded shell that is fading (Stage 5), drawn too, flagged so it
	# sits just inside the shell for the shell to blend over.
	var fade := 0.0
	if not want and city._shells.has(b.id) and not b.is_build() and not b.is_materialised() \
			and not b.toppled and not city._shell_coarse.get(b.id, false):
		want = true
		fade = 1.0
	if want == _far_on.has(b.id) and fade == float(_far_fade.get(b.id, 0.0)):
		return
	if not want:
		far_hide(b.id)
		return
	var mm := _far_multimesh()
	var slot := _far_slot_of(b.id)
	var r: Dictionary = b.recipe
	# The cornice is left off: it is a row of black buttresses along one edge
	# (BuildingShell.build_arrays), a pixel at this range, and a box that
	# included its height would put the roof above the other three walls.
	var size := Vector3(int(r.footprint_x) * City.STUD,
			(TowerRecipe.total_plates(int(r.courses)) - TowerRecipe.PLATES_PER_COURSE) * City.PLATE,
			int(r.footprint_z) * City.STUD)
	mm.set_instance_transform(slot, b.xform * Transform3D(Basis.from_scale(size), Vector3.ZERO))
	if _far_dmg_row.has(b.id):
		_far_dmg_free.append(int(_far_dmg_row[b.id]))
		_far_dmg_row.erase(b.id)
	mm.set_instance_custom_data(slot, Color(float(r.courses), float(_far_dmg_write(b)),
			float(b.id), fade))
	_far_on[b.id] = true
	_far_fade[b.id] = fade


## Hide a building's far box, if it has one drawn. Zero scale rather than a
## compacted buffer: slots never move, so nothing else has to be rewritten.
func far_hide(id: int) -> void:
	if not _far_on.has(id):
		return
	_far_on.erase(id)
	_far_fade.erase(id)
	city._far.multimesh.set_instance_transform(int(_far_slot[id]),
			Transform3D(Basis.from_scale(Vector3.ZERO), Vector3.ZERO))
	if _far_dmg_row.has(id):
		_far_dmg_free.append(int(_far_dmg_row[id]))
		_far_dmg_row.erase(id)


func _far_slot_of(id: int) -> int:
	if _far_slot.has(id):
		return _far_slot[id]
	var mm := city._far.multimesh
	var slot := _far_slot.size()
	if slot >= mm.instance_count:
		_far_grow(mm.instance_count * 2)
	_far_slot[id] = slot
	mm.visible_instance_count = slot + 1
	return slot


## A bigger buffer with the same contents: setting instance_count clears it.
func _far_grow(capacity: int) -> void:
	var mm := city._far.multimesh
	var old := mm.buffer
	var used := mm.visible_instance_count
	mm.instance_count = capacity
	var buf := mm.buffer
	for i in old.size():
		buf[i] = old[i]
	mm.buffer = buf
	mm.visible_instance_count = used


## Write a building's damage into a row of the texture. -1 if it has none.
##
## Four texels a band, one per side in BuildingShell's SIDE_* order, whose
## RGBA bytes are that side's 32-bit segment mask, low byte first. A band the
## profile does not name is standing all round.
func _far_dmg_write(b: BuildingRegistry.Building) -> int:
	if b.damage_profile.is_empty():
		return -1
	var bands := TowerRecipe.layout(int(b.recipe.courses)).size()
	var row: int
	if not _far_dmg_free.is_empty():
		row = _far_dmg_free.pop_back()
	else:
		row = _far_dmg_rows
		_far_dmg_rows += 1
	_far_dmg_fit(bands * 4, row + 1)
	_far_dmg_row[b.id] = row
	var at := row * _far_dmg_width * 4
	for band in bands:
		var masks: PackedInt32Array = b.damage_profile.get(band, PackedInt32Array())
		for side in 4:
			var m: int = masks[side] if masks.size() == 4 else BuildingShell.ALL_STANDING
			_far_dmg_bytes[at] = m & 0xFF
			_far_dmg_bytes[at + 1] = (m >> 8) & 0xFF
			_far_dmg_bytes[at + 2] = (m >> 16) & 0xFF
			_far_dmg_bytes[at + 3] = (m >> 24) & 0xFF
			at += 4
	_far_dmg_dirty = true
	return row


## Make the damage texture at least this big, keeping what is in it.
func _far_dmg_fit(width: int, height: int) -> void:
	if width <= _far_dmg_width and height <= _far_dmg_height:
		return
	var w := maxi(width, _far_dmg_width)
	var h := maxi(_far_dmg_height, FAR_DMG_INITIAL_ROWS)
	while h < height:
		h *= 2
	var bytes := PackedByteArray()
	bytes.resize(w * h * 4)
	bytes.fill(0xFF)
	for y in _far_dmg_height:
		for x in _far_dmg_width * 4:
			bytes[(y * w) * 4 + x] = _far_dmg_bytes[(y * _far_dmg_width) * 4 + x]
	_far_dmg_bytes = bytes
	_far_dmg_width = w
	_far_dmg_height = h
	# A new size is a new texture; update() only takes the same size.
	_far_dmg_tex = null


## Upload the damage rows written this tick, once.
func far_dmg_upload() -> void:
	if not _far_dmg_dirty or city._far == null:
		return
	_far_dmg_dirty = false
	var img := Image.create_from_data(_far_dmg_width, _far_dmg_height, false,
			Image.FORMAT_RGBA8, _far_dmg_bytes)
	if _far_dmg_tex == null:
		_far_dmg_tex = ImageTexture.create_from_image(img)
		(city._far.material_override as ShaderMaterial).set_shader_parameter("damage_tex", _far_dmg_tex)
	else:
		_far_dmg_tex.update(img)


func _far_multimesh() -> MultiMesh:
	if city._far != null:
		return city._far.multimesh
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = _far_box_mesh()
	mm.instance_count = FAR_INITIAL_CAPACITY
	mm.visible_instance_count = 0
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/city_far.gdshader")
	WeatherFx.register(mat)
	# The colours the shell is built in (BuildingShell.build_arrays), so the
	# swap from a shell has no colour step.
	var courses := []
	for c in TowerRecipe.COURSE_COLOURS:
		courses.append(_far_rgb(c))
	mat.set_shader_parameter("course_colours", courses)
	mat.set_shader_parameter("base_colour", _far_rgb(TowerRecipe.BASE_COLOUR))
	mat.set_shader_parameter("slab_colour", _far_rgb(TowerRecipe.SLAB_COLOUR))
	city._far = MultiMeshInstance3D.new()
	city._far.name = "FarCity"
	# Not interpolated: a slot shown or hidden (a zero-scale transform) would
	# otherwise grow or shrink over a frame, and the buildings never move.
	city._far.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	city._far.multimesh = mm
	city._far.material_override = mat
	# Casts: a tower's shadow is long and seen from far off (section 7.2).
	# Ten triangles a building, and the cascades cut away what is out of reach.
	city._far.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	city.add_child(city._far)
	return mm


static func _far_rgb(filament: int) -> Vector3:
	var c := BrickWorld.get_filament_colour(filament)
	return Vector3(c.r, c.g, c.b)


## A box from (0,0,0) to (1,1,1), four walls and a roof, white. The instance
## transform scales it to the building; the underside is never seen.
static func _far_box_mesh() -> ArrayMesh:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	# Each face's corners run anticlockwise seen from outside.
	var faces := [
		[Vector3(0, 0, 1), [Vector3(0, 0, 1), Vector3(1, 0, 1), Vector3(1, 1, 1), Vector3(0, 1, 1)]],
		[Vector3(0, 0, -1), [Vector3(1, 0, 0), Vector3(0, 0, 0), Vector3(0, 1, 0), Vector3(1, 1, 0)]],
		[Vector3(1, 0, 0), [Vector3(1, 0, 1), Vector3(1, 0, 0), Vector3(1, 1, 0), Vector3(1, 1, 1)]],
		[Vector3(-1, 0, 0), [Vector3(0, 0, 0), Vector3(0, 0, 1), Vector3(0, 1, 1), Vector3(0, 1, 0)]],
		[Vector3(0, 1, 0), [Vector3(0, 1, 1), Vector3(1, 1, 1), Vector3(1, 1, 0), Vector3(0, 1, 0)]],
	]
	var indices := PackedInt32Array()
	for f in faces:
		var base := verts.size()
		for c in f[1]:
			verts.append(c)
			normals.append(f[0])
		# Godot's front face is clockwise, so the triangles run backwards.
		indices.append_array([base, base + 2, base + 1, base, base + 3, base + 2])
	var colours := PackedColorArray()
	colours.resize(verts.size())
	colours.fill(Color.WHITE)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colours
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func far_real(id: int, mi: MeshInstance3D) -> void:
	var b := city.registry.get_building(id)
	if city.world.get_alive_block_count(b.chunk) < IslandManager.COARSE_ASYNC_BLOCKS:
		_far_real_apply(id, mi, city.world.build_chunk_coarse_mesh(b.chunk))
		return
	if not city.world.coarse_pending(b.chunk):
		city.world.coarse_chunk_async(b.chunk)
	city._far_real_owed[id] = mi


func harvest_far_real() -> void:
	# Read once, not per pass of the loop below: the city never swaps these.
	var h_far_real_owed := city._far_real_owed
	var h_shells := city._shells
	var h_registry := city.registry
	var h_world := city.world
	for id in h_far_real_owed.keys():
		var mi = h_far_real_owed[id]
		var b := h_registry.get_building(id)
		if not is_instance_valid(mi) or h_shells.get(id) != mi or b == null or not b.is_materialised():
			h_far_real_owed.erase(id)
			continue
		if h_world.coarse_ready(b.chunk):
			h_far_real_owed.erase(id)
			_far_real_apply(id, mi, h_world.take_coarse_mesh(b.chunk))
		elif not h_world.coarse_pending(b.chunk):
			# Settled by an edit (BrickWorld.settle_coarse_job): asked again.
			h_world.coarse_chunk_async(b.chunk)


func _far_real_apply(id: int, mi: MeshInstance3D, arrays: Array) -> void:
	var m := ArrayMesh.new()
	if not arrays.is_empty() and IslandManager.mesh_arrays_ok(arrays, "far building"):
		m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	if mi.mesh != null:
		city._retirer.retire(mi.mesh)
	mi.mesh = m
	city._far_real_done[id] = mi
	far_real_built += 1


func tend_brick_panes() -> void:
	# Read once, not per pass of the loop below: the city never swaps these.
	var h_panes_owed := city._panes_owed
	var h_toppling := city._toppling
	var h_registry := city.registry
	if not _harvest_panes():
		return
	var here := city.camera.global_position
	var best := -1
	var best_d := INF
	for id in city._brick_nodes:
		var cand := h_registry.get_building(id)
		if cand == null or cand.is_build() or cand.toppled or h_toppling.has(id):
			continue
		var have = _brick_panes.get(id)
		if have != null and not is_instance_valid(have):
			_brick_panes.erase(id)
			have = null
		if have != null and not h_panes_owed.has(id):
			continue
		if city._interior_unsure(id):
			continue
		var d := cand.xform.origin.distance_to(here)
		if d < best_d:
			best_d = d
			best = id
	if best < 0:
		return
	var t0 := Time.get_ticks_usec()
	var b := h_registry.get_building(best)
	h_panes_owed.erase(best)
	# Made on a worker, from a copy of which cells stand: made here, the panes
	# of a big building were 6-15 ms in one tick, half of it handing the mesh to
	# the renderer while some other upload held it (PerfCaps.md 4). The old
	# panes stay up until the new ones are hung.
	var fx: int = b.recipe.footprint_x
	var fz: int = b.recipe.footprint_z
	var courses: int = b.recipe.courses
	var room_seed := h_registry.room_seed_of(best)
	var t_pp := Time.get_ticks_usec()
	var layout := TowerRecipe.layout(courses)
	var lattice := RoomManifest.lattice_for(fx, fz, courses)
	var program: Dictionary = (b.recipe.get("program", {}) as Dictionary).duplicate(true)
	t_pp = city._part("pn_prep", t_pp)
	var standing := BuildingShell.standing_copy(city.world, b.chunk,
			BuildingShell.window_rows(courses, layout, lattice))
	city._part("pn_copy", t_pp)
	var holder := [null]
	var on_worker := City.worker_meshes
	var task := WorkerThreadPool.add_task(func() -> void:
		var arrays := BuildingShell.window_arrays(fx, fz, courses, room_seed, layout, lattice,
				{}, program, standing)
		if not arrays.is_empty():
			holder[0] = BuildingShell.window_mesh_of(arrays) if on_worker else (arrays as Variant)
			UploadLedger.note("panes", UploadLedger.verts_of(arrays)),
			true, "brick panes")
	city._pane_job = [task, holder, best]
	brick_panes_built += 1
	brick_panes_ms += float(Time.get_ticks_usec() - t0) / 1000.0


func tend_far_coarse() -> void:
	# Read once, not per pass of the loop below: the city never swaps these.
	var h_brick_nodes := city._brick_nodes
	var h_far_coarse_jobs := city._far_coarse_jobs
	var h_retirer := city._retirer
	var h_toppling := city._toppling
	var h_registry := city.registry
	var h_world := city.world
	var here := city.camera.global_position
	# Stand-ins come in: arrays from the world's worker, then the mesh made on
	# one of ours (handed to the renderer here, it would wait as a band did).
	for id in h_far_coarse_jobs.keys():
		var job: Array = h_far_coarse_jobs[id]
		var b := h_registry.get_building(id)
		var gone: bool = b == null or not b.is_materialised() or not h_brick_nodes.has(id)
		if int(job[1]) >= 0:
			if not WorkerThreadPool.is_task_completed(int(job[1])):
				continue
			WorkerThreadPool.wait_for_task_completion(int(job[1]))
			h_far_coarse_jobs.erase(id)
			var mesh: ArrayMesh = (job[2] as Array)[0]
			if mesh != null and not gone and City.far_coarse_enabled \
					and h_world.get_chunk_version(b.chunk) == int(job[0]) \
					and not bands_building(id) and not h_toppling.has(id) \
					and City._box_distance(CityPlacer.box_of(b), here) > FAR_COARSE_BACK:
				_far_coarse_show(id, mesh)
			elif mesh != null:
				h_retirer.retire(mesh)
			continue
		if gone:
			if b == null or not h_world.coarse_pending(b.chunk):
				h_far_coarse_jobs.erase(id)
			continue
		if not h_world.coarse_ready(b.chunk):
			if not h_world.coarse_pending(b.chunk):
				h_far_coarse_jobs.erase(id)   # settled by a change to the chunk
			continue
		var arrays: Array = h_world.take_coarse_mesh(b.chunk)
		if arrays.is_empty():
			h_far_coarse_jobs.erase(id)
			continue
		var holder := [null]
		if not City.worker_meshes:
			# Headless: made here, and shown next pass (worker_meshes).
			var hm := ArrayMesh.new()
			hm.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
			holder[0] = hm
			job[1] = WorkerThreadPool.add_task(func() -> void: pass, false, "far coarse building")
		else:
			job[1] = WorkerThreadPool.add_task(func() -> void:
				var m := ArrayMesh.new()
				m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
				UploadLedger.note("far building", UploadLedger.verts_of(arrays))
				holder[0] = m, false, "far coarse building")
		job[2] = holder
	# Which go coarse, and which come back. At most one asked for a pass.
	var now := Time.get_ticks_msec()
	var asked := false
	for id in h_brick_nodes:
		var b := h_registry.get_building(id)
		if b == null or not b.is_materialised():
			continue
		var dist := City._box_distance(CityPlacer.box_of(b), here)
		if _far_coarse.has(id) and not is_instance_valid(_far_coarse[id]):
			_far_coarse.erase(id)   # its node went with its bricks' node
		if _far_coarse.has(id):
			if not City.far_coarse_enabled or dist < FAR_COARSE_BACK or h_toppling.has(id) \
					or b.toppled:
				far_coarse_drop(id)
			continue
		if asked or not City.far_coarse_enabled or h_far_coarse_jobs.has(id) \
				or dist <= FAR_COARSE_RANGE or now - b.materialised_at < FAR_COARSE_QUIET_MS \
				or bands_building(id) or h_toppling.has(id) or b.toppled \
				or h_world.coarse_pending(b.chunk):
			continue
		h_world.coarse_chunk_async(b.chunk)
		h_far_coarse_jobs[id] = [h_world.get_chunk_version(b.chunk), -1, []]
		asked = true


func _far_coarse_show(id: int, mesh: ArrayMesh) -> void:
	var parent = city._brick_nodes.get(id)
	if parent == null or not is_instance_valid(parent):
		city._retirer.retire(mesh)
		return
	var node := MeshInstance3D.new()
	node.name = "FarCoarse"
	node.mesh = mesh
	node.material_override = city.brick_material
	InstanceParams.put(node, &"weather_sway", city._sway_of(id))
	InstanceParams.put(node, &"weather_snowcap", 1.0 if city._is_tree(id) else 0.0)
	InstanceParams.put(node, &"grain_origin",
			InstanceParams.of(parent as MeshInstance3D, &"grain_origin"))
	node.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	node.cast_shadow = (parent as MeshInstance3D).cast_shadow
	(parent as Node3D).add_child(node)
	for band in city._brick_bands.get(id, []):
		if is_instance_valid(band):
			(band as Node3D).visible = false
	_far_coarse[id] = node
	far_coarse_built += 1


## Its bands drawn again, and its stand-in gone. Nothing if it has none.
func far_coarse_drop(id: int) -> void:
	if not _far_coarse.has(id):
		return
	var node = _far_coarse[id]
	_far_coarse.erase(id)
	for band in city._brick_bands.get(id, []):
		if is_instance_valid(band):
			(band as Node3D).visible = true
	if node != null and is_instance_valid(node):
		city._retirer.retire((node as MeshInstance3D).mesh)
		(node as Node).queue_free()


## Hang the panes a worker has finished. False while one is still being made.
func _harvest_panes() -> bool:
	if city._pane_job.is_empty():
		return true
	if not WorkerThreadPool.is_task_completed(int(city._pane_job[0])):
		return false
	WorkerThreadPool.wait_for_task_completion(int(city._pane_job[0]))
	var id: int = city._pane_job[2]
	var made = (city._pane_job[1] as Array)[0]
	if made is Array:
		made = BuildingShell.window_mesh_of(made)   # headless: made here (worker_meshes)
	var panes: ArrayMesh = made
	city._pane_job = []
	var parent = city._brick_nodes.get(id)
	if parent == null or not is_instance_valid(parent):
		return true
	var old = _brick_panes.get(id)
	if old != null and is_instance_valid(old):
		(old as Node).queue_free()
	_brick_panes.erase(id)
	if panes != null:
		var glass := MeshInstance3D.new()
		glass.mesh = panes
		glass.material_override = BuildingShell.window_material()
		glass.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		glass.set_instance_shader_parameter("near_hide", InteriorGroups.INTERIOR_RANGE)
		(parent as Node3D).add_child(glass)
		_brick_panes[id] = glass
	return true
