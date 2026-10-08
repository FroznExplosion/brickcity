class_name BrickNear
extends RefCounted

## The near tier of brick chunks: real 45-degree chamfers and stud geometry on
## the bands of mesh close to the camera (Docs/BrickBevel.md).
##
## Whoever draws a chunk goes on drawing it exactly as before -- a flat band of
## mesh per drawing section, patched when a brick dies -- and tells this about
## each band (`track`). From there it is this class's business:
##
##   * a band within `radius` of the camera gets its chamfered mesh, built on a
##     worker (BrickWorld.chamfer_section_async) and uploaded on another, and
##     is drawn with it INSTEAD of the flat one. A switch, never a fade: a fade
##     is per object, and the object is a storey of a building (Terrain.md
##     22.15 found out what that looks like).
##   * a band within `stud_radius` gets its exposed studs as a MultiMesh
##     (BrickWorld.get_chunk_studs_section: the workshop's rule -- none where a
##     brick covers it, none on a smooth plate), bevelled inside `radius` and
##     plain past it.
##   * `damaged` patches the chamfered bands of a chunk as the owner patches
##     its flat ones, and has the studs counted again.
##
## The flat band is never hidden by `visible`: the chamfered mesh and the studs
## are its CHILDREN, so they go where it goes (a building's bands are handed to
## the piece it falls as) and are freed with it. Its render layers are taken
## away instead, and given back.

const BEVEL := 0.013

## Off: no chamfered bands are built and the ones held are given back. Studs
## stay, plain.
static var enabled := true
## Metres from the camera to the nearest point of a band, inside which it is
## drawn chamfered. At 14 m a 13 mm bevel is a little over a pixel at 1080p
## (17.8 / distance, Terrain.md 17.12): past that the drawn seam is the edge.
static var radius := 14.0
## And inside which its studs are geometry: the terrain's STUD_RANGE.
static var stud_radius := 18.0
## A band goes back to flat this much further out than it came in.
const MARGIN := 2.0
## A band is left alone this long after it was last (re)built: one being
## rebuilt band by band, or a piece still breaking up, changes again at once.
const SETTLE_MS := 350
## Chamfer builds in flight at once, bands looked at a step (the ones being
## built are looked at every step), stud buffers made a step.
const IN_FLIGHT := 2
const SLICE := 48
const STUD_BUILDS := 2

enum { FLAT, PENDING, UPLOADING, NEAR }


class Band:
	var key := 0
	var node: MeshInstance3D
	var tris := 0
	var chunk := -1
	var section := -1
	var box := AABB()
	var state := FLAT
	var since := 0
	var layers := 1
	var near: MeshInstance3D
	var mesh: ArrayMesh
	var task := -1
	var holder: Array
	var discard := false
	var studs: MultiMeshInstance3D
	var stud_tier := 0
	var studs_dirty := true


var world: BrickWorld
## Whether this draws studs at all (a caller that draws its own says no).
var studs_on := true
var chamfered_bands := 0      ## held now
var chamfered_tris := 0       ## drawn by them
var stud_instances := 0       ## in the stud MultiMeshes held now
var builds := 0               ## chamfered bands built, ever
var worst_step_ms := 0.0

var _bands := {}              ## flat node's instance id -> Band
var _order: Array[int] = []
var _cursor := 0
var _busy: Array[int] = []    ## keys PENDING or UPLOADING
var _by_chunk := {}           ## chunk -> Array[int] of keys
var _blocked := 0             ## bands that want their chamfered mesh and wait


func _init(w: BrickWorld) -> void:
	world = w


## A band of `chunk` is drawn by `node` from here on (again: its mesh was
## replaced). `section` is the chunk's drawing section the mesh is of, or -1
## for a mesh of the whole chunk (BrickWorld.build_chunk_mesh).
func track(node: MeshInstance3D, chunk: int, section: int = -1) -> void:
	if node == null or not is_instance_valid(node):
		return
	var key := node.get_instance_id()
	var band: Band = _bands.get(key)
	if band == null:
		# The node this section was drawn by before, if it is another one.
		for other_key in (_by_chunk.get(chunk, []) as Array).duplicate():
			var other: Band = _bands.get(other_key)
			if other != null and other.section == section:
				_forget(other_key)
		band = Band.new()
		band.key = key
		band.node = node
		_bands[key] = band
		_order.append(key)
	else:
		_to_flat(band)
		_unlink(key, band.chunk)
	band.chunk = chunk
	band.section = section
	band.box = node.mesh.get_aabb() if node.mesh != null else AABB()
	band.since = Time.get_ticks_msec()
	band.studs_dirty = true
	if not _by_chunk.has(chunk):
		_by_chunk[chunk] = []
	(_by_chunk[chunk] as Array).append(key)


## Stop: the node is going, or is no longer a band of anything.
func untrack(node: MeshInstance3D) -> void:
	if node != null:
		_forget(node.get_instance_id())


## Bricks of `chunk` died (or came back): the owner has patched its flat
## bands, and this patches the chamfered ones the same way.
func damaged(chunk: int) -> void:
	if not _by_chunk.has(chunk):
		return
	var by_section := {}
	for key in _by_chunk[chunk]:
		var band: Band = _bands.get(key)
		if band != null:
			by_section[band.section] = band
			band.studs_dirty = true
	for entry in world.update_chamfer_regions(chunk):
		var d: Dictionary = entry
		var band: Band = by_section.get(int(d.section))
		if band == null:
			world.drop_chamfer(chunk, int(d.section))
			continue
		if band.state == UPLOADING:
			# Built from the bricks as they were: not worth chasing. It is
			# thrown away when it lands and asked for again.
			band.discard = true
		elif band.state == NEAR:
			if d.get("stale", false):
				_to_flat(band)
			else:
				RenderingServer.mesh_surface_update_index_region(band.mesh.get_rid(), 0,
						int(d.offset), d.data)


## Every frame, with the camera's position.
func step(eye: Vector3) -> void:
	if _order.is_empty():
		return
	var t0 := Time.get_ticks_usec()
	var now := Time.get_ticks_msec()
	var stud_budget := [STUD_BUILDS]
	for key in _busy.duplicate():
		_visit(key, eye, now, stud_budget)
	var n := mini(SLICE, _order.size())
	for i in n:
		if _order.is_empty():
			break
		_cursor = (_cursor + 1) % _order.size()
		_visit(_order[_cursor], eye, now, stud_budget)
	worst_step_ms = maxf(worst_step_ms, float(Time.get_ticks_usec() - t0) / 1000.0)


## Everything the camera wants, now, blocking: for a capture or a gate.
func settle(eye: Vector3, rounds := 4000) -> void:
	for band in _bands.values():
		(band as Band).since = 0
	for i in rounds:
		_blocked = 0
		var now := Time.get_ticks_msec()
		for key in _order.duplicate():
			_visit(key, eye, now, [1 << 20])
		if _busy.is_empty() and _blocked == 0:
			return
		OS.delay_msec(1)


## For a gate: over the chamfered bands held, the triangles their index
## buffers DRAW (read back from the renderer) and the triangles the bricks
## alive now call for. A patch that went wrong shows as the two apart -- a
## dead brick still drawn, or a live one not.
func audit() -> Dictionary:
	var drawn := 0
	var wanted := 0
	var bands := 0
	for b in _bands.values():
		var band: Band = b
		if band.state != NEAR or band.mesh == null:
			continue
		bands += 1
		var idx: PackedInt32Array = band.mesh.surface_get_arrays(0)[Mesh.ARRAY_INDEX]
		for i in range(0, idx.size() - 2, 3):
			if idx[i] != idx[i + 1] or idx[i + 1] != idx[i + 2]:
				drawn += 1
		wanted += maxi(world.get_chamfer_expected_triangles(band.chunk, band.section), 0)
	return {"bands": bands, "drawn": drawn, "wanted": wanted}


## Give everything back (the scene is closing, or `enabled` went off).
func clear() -> void:
	for key in _order.duplicate():
		_forget(key)


func _visit(key: int, eye: Vector3, now: int, stud_budget: Array) -> void:
	var band: Band = _bands.get(key)
	if band == null:
		return
	if not is_instance_valid(band.node):
		_forget(key)
		return
	var node := band.node
	if not node.is_inside_tree() or node.mesh == null:
		if band.state != FLAT:
			_to_flat(band)
		return
	var local := node.global_transform.affine_inverse() * eye
	var nearest := local.clamp(band.box.position, band.box.end)
	var dist := local.distance_to(nearest)

	var want := enabled and dist < radius + (MARGIN if band.state != FLAT else 0.0)
	match band.state:
		FLAT:
			if want and world.has_bake(band.chunk):
				if now - band.since < SETTLE_MS or _busy.size() >= IN_FLIGHT:
					_blocked += 1   # its turn will come (settle waits for it)
				else:
					world.chamfer_section_async(band.chunk, band.section, BEVEL)
					if world.chamfer_pending(band.chunk, band.section):
						band.state = PENDING
						_busy.append(key)
		PENDING:
			if not want:
				world.drop_chamfer(band.chunk, band.section)
				_idle(key, band, now)
			elif world.chamfer_ready(band.chunk, band.section):
				var arrays: Array = world.take_chamfer_section(band.chunk, band.section)
				if arrays.is_empty():
					_idle(key, band, now)   # its bake went from under it
				else:
					_upload(band, arrays)
		UPLOADING:
			if WorkerThreadPool.is_task_completed(band.task):
				WorkerThreadPool.wait_for_task_completion(band.task)
				band.task = -1
				_busy.erase(key)
				var mesh: ArrayMesh = band.holder[0]
				band.holder = []
				if band.discard or not want:
					world.drop_chamfer(band.chunk, band.section)
					band.state = FLAT
					band.since = now
				else:
					_show_near(band, mesh)
		NEAR:
			if not want:
				_to_flat(band)
			elif band.near.cast_shadow != node.cast_shadow:
				band.near.cast_shadow = node.cast_shadow

	if studs_on:
		_studs(band, dist, stud_budget)


func _idle(key: int, band: Band, now: int) -> void:
	band.state = FLAT
	band.since = now
	_busy.erase(key)


func _upload(band: Band, arrays: Array) -> void:
	var holder := [null]
	band.holder = holder
	band.discard = false
	band.state = UPLOADING
	band.task = WorkerThreadPool.add_task(func() -> void:
		var m := ArrayMesh.new()
		m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		holder[0] = m
	, false, "chamfered band mesh")


func _show_near(band: Band, mesh: ArrayMesh) -> void:
	var node := band.node
	var near := MeshInstance3D.new()
	near.name = "Chamfered"
	near.mesh = mesh
	near.material_override = node.material_override
	near.cast_shadow = node.cast_shadow
	near.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	near.set_instance_shader_parameter("geo_bevel", 1.0)
	for param in [&"weather_sway", &"weather_snowcap"]:
		var v: Variant = node.get_instance_shader_parameter(param)
		if v != null:
			near.set_instance_shader_parameter(param, v)
	band.layers = node.layers
	near.layers = band.layers
	node.add_child(near)
	node.layers = 0
	band.near = near
	band.mesh = mesh
	band.state = NEAR
	band.tris = mesh.surface_get_array_index_len(0) / 3
	chamfered_bands += 1
	chamfered_tris += band.tris
	builds += 1


func _to_flat(band: Band) -> void:
	match band.state:
		PENDING:
			world.drop_chamfer(band.chunk, band.section)
			_busy.erase(band.key)
		UPLOADING:
			# Let it land; it is thrown away there.
			band.discard = true
			return
		NEAR:
			world.drop_chamfer(band.chunk, band.section)
			if is_instance_valid(band.node):
				band.node.layers = band.layers
			if is_instance_valid(band.near):
				band.near.queue_free()
			band.near = null
			band.mesh = null
			chamfered_bands -= 1
			chamfered_tris -= band.tris
	band.state = FLAT
	band.since = Time.get_ticks_msec()


func _studs(band: Band, dist: float, budget: Array) -> void:
	var tier := 0
	if dist < stud_radius + (MARGIN if band.stud_tier > 0 else 0.0):
		tier = 2 if (enabled and dist < radius + (MARGIN if band.stud_tier == 2 else 0.0)) else 1
	if tier == 0:
		if band.studs != null:
			if is_instance_valid(band.studs):
				stud_instances -= band.studs.multimesh.instance_count
				band.studs.queue_free()
			band.studs = null
			band.stud_tier = 0
			band.studs_dirty = true
		return
	if band.studs == null or band.studs_dirty:
		if int(budget[0]) <= 0:
			return
		budget[0] = int(budget[0]) - 1
		_build_studs(band)
	if tier != band.stud_tier and band.studs != null:
		band.studs.multimesh.mesh = PieceMeshes.stud() if tier == 2 else PieceMeshes.stud_plain()
		band.stud_tier = tier


func _build_studs(band: Band) -> void:
	band.studs_dirty = false
	var buffer: PackedFloat32Array = world.get_chunk_studs_section(band.chunk, band.section)
	@warning_ignore("integer_division")
	var count := buffer.size() / 16
	if band.studs == null:
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "Studs"
		mmi.material_override = TerrainTile.stud_material()
		# Studs never cast (Terrain.md 7.4).
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mmi.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		mmi.layers = band.layers if band.state == NEAR else band.node.layers
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.mesh = PieceMeshes.stud_plain()
		mmi.multimesh = mm
		band.node.add_child(mmi)
		band.studs = mmi
		band.stud_tier = 1
	var mm := band.studs.multimesh
	stud_instances += count - mm.instance_count
	mm.instance_count = count
	if count > 0:
		mm.set_buffer(buffer)


func _unlink(key: int, chunk: int) -> void:
	if _by_chunk.has(chunk):
		(_by_chunk[chunk] as Array).erase(key)
		if (_by_chunk[chunk] as Array).is_empty():
			_by_chunk.erase(chunk)


func _forget(key: int) -> void:
	var band: Band = _bands.get(key)
	if band == null:
		return
	if band.state == UPLOADING:
		WorkerThreadPool.wait_for_task_completion(band.task)
		band.holder = []
		world.drop_chamfer(band.chunk, band.section)
	elif band.state == PENDING:
		world.drop_chamfer(band.chunk, band.section)
	elif band.state == NEAR:
		world.drop_chamfer(band.chunk, band.section)
		chamfered_bands -= 1
		chamfered_tris -= band.tris
		if is_instance_valid(band.node):
			band.node.layers = band.layers
		if is_instance_valid(band.near):
			band.near.queue_free()
	if band.studs != null and is_instance_valid(band.studs):
		stud_instances -= band.studs.multimesh.instance_count
		band.studs.queue_free()
	_busy.erase(key)
	_unlink(key, band.chunk)
	_bands.erase(key)
	_order.erase(key)
