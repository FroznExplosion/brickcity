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
##   * a band within `stud_radius` gets its exposed studs as geometry
##     (BrickWorld.get_chunk_studs_section: the workshop's rule -- none where a
##     brick covers it, none on a smooth plate), each STUD by its own distance:
##     bevelled inside `stud_bevel_radius`, a plain octagon to
##     `stud_round_radius`, a square post to `stud_radius`, a flat card to
##     `stud_card_radius`, nothing past it.
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
## Studs are most of what the near tier draws (a 638-brick building: 8,734 of
## them to 50,274 chamfered triangles), so they come down in three steps of
## their own -- and by the STUD, not the band: a band is a storey, and with the
## camera at one end of it every stud on the floor was "within eight metres".
## A band's studs are sorted into three MultiMeshes by distance
## (BrickWorld.split_studs), again whenever the camera has moved STUD_RESORT:
##   inside `stud_bevel_radius`  PieceMeshes.stud, 38 triangles: the rim bevel
##       is 13 mm, three pixels at 8 m and under two past it;
##   to `stud_round_radius`      PieceMeshes.stud_plain, 22: still round;
##   to `stud_radius`            PieceMeshes.stud_square, 10: a stud is 0.21 m,
##       twenty pixels wide or less out here and mostly seen from the side.
## Set `stud_round_radius` to `stud_bevel_radius` to go straight to square.
static var stud_bevel_radius := 8.0
static var stud_round_radius := 13.0
## And past `stud_radius`, to here, a CARD: two triangles that turn to face the
## camera, sized to the stud's outline from there, flat colour, no print
## (PieceMeshes.stud_card). Past 18 m a stud is under fifteen pixels; what has
## to read is that the tops are studded, so a building across a square is not
## a stack of smooth boxes. Set it to `stud_radius` to turn the ring off.
##
## Only OPEN studs get a card (BrickWorld.get_chunk_studs_open): nothing over
## them in the chunk -- a roof, a ledge, a floor a blast opened. A storey's
## floor is under the slab above and is seen, if at all, through a window: in
## the big city those were 95% of the cards (200,657 studs held on a walk past
## every building, 9,827 without them), each band of them re-sent to the
## renderer every few metres the camera moved.
static var stud_card_radius := 70.0
## THE CAP (Options > Video, Near Detail Cap). Distance alone let the tier
## take on as many bands as stood inside its rings -- a street of storeys, a
## collapse's every piece -- and each one held is a build, an upload and its
## studs' MultiMeshes re-sorted as the camera walks. With the cap on, the
## bands chamfered hold at most `max_tris` triangles between them and the
## bands with stud geometry at most `max_studs` studs -- a BUDGET, not a count:
## a band is a storey, from a few hundred triangles to twenty thousand, and a
## count of them bounded nothing (a street walk held ten bands, 145k triangles,
## under a cap of 32). A band's cost before it is built is its flat mesh's
## triangles times what built bands came out at (`_ratio`); then its own. The
## budget can run over by OVER_SLACK before anything is given back, so a band
## that came out a little bigger than guessed is not built and dropped in turn;
## and one band is always let in, whatever it costs. The best placed first: by
## distance (through the zoom, as everything here)
## weighed by where the camera LOOKS -- straight ahead as it is, to the side
## FACING_SIDE times as far, behind FACING_BEHIND -- except within
## ALWAYS_NEAR, which is the player's own surroundings and comes first
## whichever way they face. A band better placed than the worst held, by
## SWAP_MARGIN, takes its place, one a step. Off: by distance alone, as before.
static var cap_enabled := true
static var max_tris := 120000
static var max_studs := 4000
const OVER_SLACK := 1.1
const FACING_SIDE := 1.75
const FACING_BEHIND := 2.5
const ALWAYS_NEAR := 2.0
const SWAP_MARGIN := 0.8
## Through a scope the world is as near as it looks: `step`'s zoom (the
## unzoomed field of view's tangent over the camera's now, 1 or more) divides
## every distance here, so a wall seen through 4x glass is chamfered and
## studded as one a quarter as far off. The shaders take the same factor
## (the lod_zoom global, its inverse).
var zoom := 1.0
## A band goes back to flat this much further out than it came in.
const MARGIN := 2.0
## A band is left alone this long after it was last (re)built: one being
## rebuilt band by band, or a piece still breaking up, changes again at once.
const SETTLE_MS := 350
## Chamfer builds in flight at once, bands looked at a step (the ones being
## built are looked at every step), stud buffers made a step.
const IN_FLIGHT := 2
const SLICE := 16
## A band that moved this far since it was last looked at is not still: a piece
## in the air is drawn flat until it has come to rest (and SETTLE_MS more).
const STILL := 0.02
const STUD_BUILDS := 2
## How far the camera moves, in a band's own space, before that band's studs
## are sorted into their rings again. The rings' edges move in steps this big.
const STUD_RESORT := 1.0
const STUD_RESORT_FAR := 4.0
## The rings a closed stud (one under a ceiling) is drawn in: all but the card.
const CLOSED_RINGS := 3

enum { FLAT, PENDING, UPLOADING, NEAR }


class Band:
	var key := 0
	var node: MeshInstance3D
	var tris := 0
	var chunk := -1
	var section := -1
	var box := AABB()
	var at := Vector3.ZERO   ## where the node was when last looked at
	var state := FLAT
	var since := 0
	var layers := 1
	var near: MeshInstance3D
	var mesh: ArrayMesh
	var task := -1
	var holder: Array
	var discard := false
	var studs: Array[MultiMeshInstance3D] = []   ## bevelled, plain, square, card
	var stud_buffer := PackedFloat32Array()      ## every stud of the band
	var stud_open := PackedByteArray()           ## ... and which have nothing over them
	var stud_eye := Vector3.INF                  ## where they were last sorted from
	var stud_zoom := 1.0                         ## ... and through what zoom
	var stud_bevelled := true                    ## ... and with `enabled` as it was
	var stud_count := 0                          ## drawn now, the three together
	var studs_dirty := true
	var score := INF                             ## where it stands for the cap; less is first
	var stud_geo := false                        ## has a place for stud GEOMETRY (the cap)
	var stud_geo_n := -1                         ## ... and how many of its studs that was


var world: BrickWorld
## Whether this draws studs at all (a caller that draws its own says no).
var studs_on := true
var chamfered_bands := 0      ## held now
var chamfered_tris := 0       ## drawn by them
var stud_instances := 0       ## in the stud MultiMeshes held now
var builds := 0               ## chamfered bands built, ever
var worst_step_ms := 0.0
var step_ms := 0.0            ## all of `step`, and how many
var steps := 0
var damage_ms := 0.0          ## all of `damaged`, how many, the worst one
var damage_calls := 0
var worst_damage_ms := 0.0
## The worst single take of a finished band's arrays, hanging of its mesh, and
## build of a band's studs: the three things `step` does that are not a glance.
var worst_take_ms := 0.0
var worst_show_ms := 0.0
var worst_studs_ms := 0.0
## Of a band's studs, the worst: fetch from the bricks (when they changed),
## split into rings, handing the rings to their MultiMeshes; and the most studs
## one band held. For the cap's timing pass (--chamfer --street).
var worst_fetch_ms := 0.0
var worst_split_ms := 0.0
var worst_set_ms := 0.0
var most_band_studs := 0
## Meshes being uploaded on worker threads right now, the owner's (set every
## frame, before `step`). While there are any -- or any of this class's own --
## band studs are left as they are: the first call that changes the renderer's
## instances or buffers waits for those uploads to finish, and measured walking
## the big city that was 9-20 ms a time, on the 5% of frames a building turning
## to bricks has its bands in flight. A frame or two later costs nothing seen.
var uploads := 0
var _held := false

var _bands := {}              ## flat node's instance id -> Band
var _order: Array[int] = []
var _cursor := 0
var _busy: Array[int] = []    ## keys PENDING or UPLOADING
var _by_chunk := {}           ## chunk -> Array[int] of keys
var _blocked := 0             ## bands that want their chamfered mesh and wait
var _forward := Vector3.ZERO  ## where the camera looks, this step (zero: no facing)
var _eye := Vector3.ZERO
## For the cap: the bands holding a chamfered mesh (or building one), and the
## ones with stud MultiMeshes -- key -> true -- and, this step, the best placed
## band of each kind left waiting for a place.
var _holding := {}
var _studded := {}
## ... their costs (key -> triangles, key -> studs), and the sums.
var _hold_cost := 0
var _stud_cost := 0
## Chamfered triangles over flat ones, as built bands came out: the guess at a
## band's cost before it is built.
var _ratio := 6.0
## What the best placed waiting band of each kind would cost.
var _wait_bevel_cost := 0
var _wait_studs_cost := 0
var _wait_bevel := INF
var _wait_studs := INF
## A place given up for a better band goes to a band placed at least that
## well, not to whichever band the round robin reaches first (which could be
## placed worse than the one that left, and the two would trade places).
var _admit_bevel := INF
var _admit_studs := INF
## Bands the cap has turned away, for a report.
var capped_bevel := 0
var capped_studs := 0


func _init(w: BrickWorld) -> void:
	world = w
	# The stud meshes and their material, made now: left to the first band
	# that wanted studs, they were 45 ms of its step (the material's shader,
	# mostly) -- the first time the player walked up to a building.
	PieceMeshes.stud()
	PieceMeshes.stud_plain()
	PieceMeshes.stud_square()
	PieceMeshes.stud_card()
	TerrainTile.stud_material()
	PieceMeshes.stud_card_material()


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
	band.at = node.global_position if node.is_inside_tree() else Vector3.ZERO
	band.studs_dirty = true
	if not _by_chunk.has(chunk):
		_by_chunk[chunk] = []
	(_by_chunk[chunk] as Array).append(key)


## Stop: the node is going, or is no longer a band of anything.
func untrack(node: MeshInstance3D) -> void:
	if node != null:
		_forget(node.get_instance_id())


## Bricks of `chunk` died (or came back): the owner has patched its flat
## bands, and this patches the chamfered ones the same way. `sections` is the
## bands the owner's patch moved, if it knows (BrickWorld.update_index_regions
## says): only those are looked at. Empty is all of them.
func damaged(chunk: int, sections := PackedInt32Array()) -> void:
	if not _by_chunk.has(chunk):
		return
	var t0 := Time.get_ticks_usec()
	var by_section := {}
	for key in _by_chunk[chunk]:
		var band: Band = _bands.get(key)
		if band != null:
			by_section[band.section] = band
			if sections.is_empty() or band.section < 0 or sections.has(band.section):
				band.studs_dirty = true
	_patch(chunk, by_section, sections)
	var ms := float(Time.get_ticks_usec() - t0) / 1000.0
	damage_ms += ms
	damage_calls += 1
	worst_damage_ms = maxf(worst_damage_ms, ms)


func _patch(chunk: int, by_section: Dictionary, sections: PackedInt32Array) -> void:
	if chamfered_bands == 0 and _busy.is_empty():
		return
	for entry in world.update_chamfer_regions(chunk, sections):
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


## Every frame, with the camera's position, how far it is zoomed in (see
## `zoom`) and where it looks (for the cap; zero ranks by distance alone).
func step(eye: Vector3, zoom_in := 1.0, forward := Vector3.ZERO) -> void:
	zoom = maxf(zoom_in, 1.0)
	_forward = forward.normalized() if forward.length_squared() > 1e-6 else Vector3.ZERO
	_eye = eye
	if _order.is_empty():
		return
	var t0 := Time.get_ticks_usec()
	var now := Time.get_ticks_msec()
	var stud_budget := [STUD_BUILDS]
	_wait_bevel = INF
	_wait_studs = INF
	# The held bands' places, fresh: the camera turns faster than the round
	# robin comes back to them.
	if cap_enabled:
		for key in _holding:
			var b: Band = _bands.get(key)
			if b != null:
				_rescore(b)
		for key in _studded:
			if not _holding.has(key):
				var b: Band = _bands.get(key)
				if b != null:
					_rescore(b)
	_held = uploads > 0
	for key in _busy:
		var b: Band = _bands.get(key)
		if b != null and b.state == UPLOADING:
			_held = true
	for key in _busy.duplicate():
		_visit(key, eye, now, stud_budget)
	var n := mini(SLICE, _order.size())
	for i in n:
		if _order.is_empty():
			break
		_cursor = (_cursor + 1) % _order.size()
		_visit(_order[_cursor], eye, now, stud_budget)
	if cap_enabled:
		_make_room()
	var ms := float(Time.get_ticks_usec() - t0) / 1000.0
	step_ms += ms
	steps += 1
	worst_step_ms = maxf(worst_step_ms, ms)


## For a gate: [bands holding a chamfered mesh or building one, bands with a
## place for stud geometry].
func held() -> Vector2i:
	return Vector2i(_holding.size(), _studded.size())


## For a gate and a report: [triangles the chamfered bands hold or are
## guessed at, studs drawn as geometry].
func held_cost() -> Vector2i:
	return Vector2i(_hold_cost, _stud_cost)


## For a gate: whether the band `node` draws is chamfered now.
func is_near(node: MeshInstance3D) -> bool:
	var band: Band = _bands.get(node.get_instance_id()) if node != null else null
	return band != null and band.state == NEAR


## One line for a pass's report.
func report() -> String:
	return ("%d chamfered band(s) built, %d held now (%d triangles), %d stud(s) in %d band(s); "
			+ "cap %s (%dk triangles of %dk, %d of %d studs), %d bevel and %d stud visits turned away; "
			+ "step %.3f ms mean, %.2f worst (take %.2f, hang %.2f, studs %.2f); "
			+ "a hit's patch %.3f ms mean over %d, %.2f worst") % [
			builds, chamfered_bands, chamfered_tris, stud_instances, _studded.size(),
			"on" if cap_enabled else "off", _hold_cost / 1000, max_tris / 1000, _stud_cost, max_studs,
			capped_bevel, capped_studs,
			step_ms / maxf(steps, 1.0), worst_step_ms, worst_take_ms, worst_show_ms,
			worst_studs_ms,
			damage_ms / maxf(damage_calls, 1.0), damage_calls, worst_damage_ms]


## Everything the camera wants, now, blocking: for a capture or a gate.
func settle(eye: Vector3, rounds := 4000) -> void:
	_held = false   # blocking anyway: the wait is the point
	for band in _bands.values():
		(band as Band).since = 0
	_eye = eye
	for i in rounds:
		_blocked = 0
		_wait_bevel = INF
		_wait_studs = INF
		var now := Time.get_ticks_msec()
		for key in _order.duplicate():
			_visit(key, eye, now, [1 << 20])
		var swapped := _holding.size() + _studded.size()
		if cap_enabled:
			_make_room()
		if _busy.is_empty() and _blocked == 0 and _wait_bevel == INF and _wait_studs == INF:
			return
		# Waiting for a place nobody will give up: as settled as it gets.
		if _busy.is_empty() and _blocked == 0 \
				and _holding.size() + _studded.size() == swapped and i > 2:
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


## For a gate: the studs held now (every band's last fetch, which is what its
## rings draw) with no live brick under them -- a stud left standing on a
## brick that died. [studs, of them stale, of the stale the chunks].
func stale_studs() -> Array:
	var cs := BrickWorld.get_cell_size()
	var n := 0
	var stale := 0
	var chunks := {}
	for b in _bands.values():
		var band: Band = b
		if band.studs.is_empty() or not is_instance_valid(band.node) 				or not band.node.is_inside_tree() or not world.is_chunk_alive(band.chunk):
			continue
		var xf: Transform3D = world.get_chunk_transform(band.chunk).affine_inverse() 				* band.node.global_transform
		var origin: Vector3i = world.get_chunk_origin(band.chunk)
		var buf := band.stud_buffer
		for i in range(0, buf.size(), 16):
			n += 1
			var up := Vector3(buf[i + 1], buf[i + 5], buf[i + 9]).normalized()
			var at: Vector3 = xf * (Vector3(buf[i + 3], buf[i + 7], buf[i + 11]) - up * 0.03)
			var cell := origin + Vector3i(floori(at.x / cs.x), floori(at.y / cs.y), floori(at.z / cs.z))
			if not world.is_solid(band.chunk, cell):
				stale += 1
				chunks[band.chunk] = int(chunks.get(band.chunk, 0)) + 1
	return [n, stale, chunks]


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
	var xf := node.global_transform
	# Falling, tumbling, sliding: nothing is built for it. A collapse is the
	# worst moment there is to start building meshes of what is coming down
	# (and it breaks into other pieces before they would be done).
	if band.state == FLAT and xf.origin.distance_squared_to(band.at) > STILL * STILL:
		band.since = now
	band.at = xf.origin
	var local := xf.affine_inverse() * eye
	var nearest := local.clamp(band.box.position, band.box.end)
	var dist := local.distance_to(nearest) / zoom
	band.score = _score(dist, xf * nearest)

	var want := enabled and dist < radius + (MARGIN if band.state != FLAT else 0.0)
	match band.state:
		FLAT:
			if want and cap_enabled and (not _fits(_hold_cost, _est_tris(band), max_tris, _holding)
					or band.score > _admit_bevel):
				# No room: it waits, and takes the worst held band's if it is
				# placed better (_make_room).
				if band.score < _wait_bevel:
					_wait_bevel = band.score
					_wait_bevel_cost = _est_tris(band)
				capped_bevel += 1
			elif want and world.has_bake(band.chunk):
				if now - band.since < SETTLE_MS or _busy.size() >= IN_FLIGHT:
					_blocked += 1   # its turn will come (settle waits for it)
				else:
					world.chamfer_section_async(band.chunk, band.section, BEVEL)
					if world.chamfer_pending(band.chunk, band.section):
						band.state = PENDING
						_busy.append(key)
						_hold_set(key, _est_tris(band))
						_admit_bevel = INF
		PENDING:
			if not want:
				world.drop_chamfer(band.chunk, band.section)
				_idle(key, band, now)
			elif world.chamfer_ready(band.chunk, band.section):
				var t_take := Time.get_ticks_usec()
				var arrays: Array = world.take_chamfer_section(band.chunk, band.section)
				worst_take_ms = maxf(worst_take_ms, float(Time.get_ticks_usec() - t_take) / 1000.0)
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
					_hold_erase(key)
				else:
					var t_show := Time.get_ticks_usec()
					_show_near(band, mesh)
					worst_show_ms = maxf(worst_show_ms,
							float(Time.get_ticks_usec() - t_show) / 1000.0)
		NEAR:
			if not want:
				_to_flat(band)
			elif band.near.cast_shadow != node.cast_shadow:
				band.near.cast_shadow = node.cast_shadow

	if studs_on:
		_studs(band, dist, local, stud_budget)


func _idle(key: int, band: Band, now: int) -> void:
	band.state = FLAT
	band.since = now
	_busy.erase(key)
	_hold_erase(key)


func _upload(band: Band, arrays: Array) -> void:
	var holder := [null]
	band.holder = holder
	band.discard = false
	band.state = UPLOADING
	# From now, in THIS step too: the worker holds the renderer while it
	# uploads, and a band's studs touched after it in the same step waited for
	# it -- 4-11 ms, the worst steps of a street walk (PerfCaps.md 3).
	_held = true
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
	band.layers = _layers_of(node)
	near.layers = band.layers
	node.add_child(near)
	_set_layers(node, 0)
	band.near = near
	band.mesh = mesh
	band.state = NEAR
	@warning_ignore("integer_division")
	band.tris = mesh.surface_get_array_index_len(0) / 3
	# Its own cost now, and what it says about the next guess.
	var flat := _flat_tris(band)
	if flat > 0:
		_ratio = lerpf(_ratio, float(band.tris) / float(flat), 0.25)
	if _holding.has(band.key):
		_hold_set(band.key, band.tris)
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
				_set_layers(band.node, band.layers)
			if is_instance_valid(band.near):
				band.near.queue_free()
			band.near = null
			band.mesh = null
			chamfered_bands -= 1
			chamfered_tris -= band.tris
	band.state = FLAT
	band.since = Time.get_ticks_msec()
	_hold_erase(band.key)


func _studs(band: Band, dist: float, local_eye: Vector3, budget: Array) -> void:
	# The band's box against the furthest ring; a stud's own distance decides
	# the rest (_sort_studs).
	var outer := maxf(stud_radius, stud_card_radius)
	if dist >= outer + (MARGIN if not band.studs.is_empty() else 0.0):
		if not band.studs.is_empty():
			_drop_studs(band)
		return
	# Studs as geometry take a place under the cap; a band without one has its
	# studs drawn as the far ring's cards, whatever its distance (the brick
	# shader paints none, so leaving them out would leave the tops smooth).
	var geo := dist < stud_radius + (MARGIN if band.stud_geo else 0.0)
	if geo and not band.stud_geo and cap_enabled \
			and (not _fits(_stud_cost, _est_studs(band), max_studs, _studded)
				or band.score > _admit_studs):
		if band.score < _wait_studs:
			_wait_studs = band.score
			_wait_studs_cost = _est_studs(band)
		capped_studs += 1
		geo = false
	if geo != band.stud_geo:
		band.stud_geo = geo
		if geo:
			_stud_set(band.key, _est_studs(band))
			_admit_studs = INF
		else:
			_stud_erase(band.key)
		band.stud_eye = Vector3.INF   # sorted again, into its new rings
	var fetch := band.studs.is_empty() or band.studs_dirty
	# Out among the cards only the outer ring's edge moves, and a card coming
	# or going a few metres late out there is not seen: sorted again less
	# often.
	var resort := (STUD_RESORT if dist < stud_radius + MARGIN else STUD_RESORT_FAR) * zoom
	if not fetch and band.stud_bevelled == enabled \
			and absf(band.stud_zoom - zoom) < 0.1 * zoom \
			and local_eye.distance_squared_to(band.stud_eye) < resort * resort:
		return
	if int(budget[0]) <= 0 or _held:
		return
	budget[0] = int(budget[0]) - 1
	var t_studs := Time.get_ticks_usec()
	if fetch:
		band.studs_dirty = false
		# One walk for both (they were two, each over every block of the chunk).
		var got: Array = world.get_chunk_studs_and_open(band.chunk, band.section)
		band.stud_buffer = got[0]
		band.stud_open = got[1]
		worst_fetch_ms = maxf(worst_fetch_ms, float(Time.get_ticks_usec() - t_studs) / 1000.0)
		@warning_ignore("integer_division")
		most_band_studs = maxi(most_band_studs, band.stud_buffer.size() / 16)
	_sort_studs(band, local_eye)
	worst_studs_ms = maxf(worst_studs_ms, float(Time.get_ticks_usec() - t_studs) / 1000.0)


## The band's studs into their three rings round the camera, each ring's
## MultiMesh given its own.
func _sort_studs(band: Band, local_eye: Vector3) -> void:
	if band.studs.is_empty():
		var layers := band.layers if band.state == NEAR else _layers_of(band.node)
		for mesh in [PieceMeshes.stud(), PieceMeshes.stud_plain(), PieceMeshes.stud_square(),
				PieceMeshes.stud_card()]:
			var mmi := MultiMeshInstance3D.new()
			mmi.name = "Studs"
			mmi.material_override = PieceMeshes.stud_card_material() \
					if mesh == PieceMeshes.stud_card() else TerrainTile.stud_material()
			# Studs never cast (Terrain.md 7.4).
			mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			mmi.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
			mmi.layers = layers
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.use_colors = true
			mm.mesh = mesh
			mmi.multimesh = mm
			band.node.add_child(mmi)
			band.studs.append(mmi)
	band.stud_eye = local_eye
	band.stud_zoom = zoom
	band.stud_bevelled = enabled
	# With the tier off there is no bevelled ring: its studs are plain.
	var rings := PackedFloat32Array([(stud_bevel_radius if enabled else 0.0) * zoom,
			maxf(stud_round_radius, stud_bevel_radius) * zoom, stud_radius * zoom,
			maxf(stud_card_radius, stud_radius) * zoom])
	if not band.stud_geo:
		# No place for geometry under the cap: cards only.
		rings[0] = 0.0
		rings[1] = 0.0
		rings[2] = 0.0
	var t_s := Time.get_ticks_usec()
	var parts: Array = BrickWorld.split_studs(band.stud_buffer, local_eye, rings,
			band.stud_open, CLOSED_RINGS)
	var t_b := Time.get_ticks_usec()
	worst_split_ms = maxf(worst_split_ms, float(t_b - t_s) / 1000.0)
	var drawn := 0
	for k in 4:
		var part: PackedFloat32Array = parts[k]
		var mm := band.studs[k].multimesh
		@warning_ignore("integer_division")
		var n := part.size() / 16
		mm.instance_count = n
		if n > 0:
			mm.set_buffer(part)
		band.studs[k].visible = n > 0
		drawn += n
	worst_set_ms = maxf(worst_set_ms, float(Time.get_ticks_usec() - t_b) / 1000.0)
	if band.stud_geo:
		# What its geometry rings came to: its cost from here.
		@warning_ignore("integer_division")
		var geo_n := ((parts[0] as PackedFloat32Array).size() + (parts[1] as PackedFloat32Array).size()
				+ (parts[2] as PackedFloat32Array).size()) / 16
		band.stud_geo_n = geo_n
		_stud_set(band.key, geo_n)
	stud_instances += drawn - band.stud_count
	band.stud_count = drawn


func _drop_studs(band: Band) -> void:
	for mmi in band.studs:
		if is_instance_valid(mmi):
			mmi.queue_free()
	band.studs.clear()
	_stud_erase(band.key)
	band.stud_geo = false
	band.stud_geo_n = -1
	band.stud_buffer = PackedFloat32Array()
	band.stud_open = PackedByteArray()
	band.stud_eye = Vector3.INF
	band.studs_dirty = true
	stud_instances -= band.stud_count
	band.stud_count = 0


## Where a band stands for the cap, its nearest point `at` (world) `dist` off
## (through the zoom): less is first.
func _score(dist: float, at: Vector3) -> float:
	if dist < ALWAYS_NEAR or _forward == Vector3.ZERO:
		return dist
	var to := at - _eye
	var l := to.length()
	if l < 1e-4:
		return dist
	var f := _forward.dot(to / l)
	# 1 straight ahead, FACING_SIDE square to the side, FACING_BEHIND behind.
	var k := lerpf(FACING_SIDE, 1.0, f) if f >= 0.0 else lerpf(FACING_SIDE, FACING_BEHIND, -f)
	return dist * k


func _rescore(band: Band) -> void:
	if not is_instance_valid(band.node) or not band.node.is_inside_tree():
		return
	var xf := band.node.global_transform
	var local := xf.affine_inverse() * _eye
	var nearest := local.clamp(band.box.position, band.box.end)
	band.score = _score(local.distance_to(nearest) / zoom, xf * nearest)


## The cap is full and a band placed better than the worst held is waiting:
## the worst gives its place up (one of each kind a step). The waiting band
## takes it when the round robin next comes to it.
func _make_room() -> void:
	# Room for more than a band again: nothing is being kept for anyone.
	if _hold_cost < max_tris * 0.75:
		_admit_bevel = INF
	if _stud_cost < max_studs * 0.75:
		_admit_studs = INF
	if _wait_bevel < INF and not _fits(_hold_cost, _wait_bevel_cost, max_tris, _holding):
		var worst: Band = _worst(_holding)
		if worst != null and _wait_bevel < worst.score * SWAP_MARGIN:
			_admit_bevel = worst.score * SWAP_MARGIN
			_to_flat(worst)
	if _wait_studs < INF and not _fits(_stud_cost, _wait_studs_cost, max_studs, _studded):
		var worst: Band = _worst(_studded)
		if worst != null and _wait_studs < worst.score * SWAP_MARGIN:
			_admit_studs = worst.score * SWAP_MARGIN
			_demote_studs(worst)
	# Over budget -- shrunk from the menu, or bands that came out bigger than
	# guessed: give back the worst until it fits, always keeping one.
	while _hold_cost > max_tris * OVER_SLACK and _holding.size() > 1:
		var w: Band = _worst(_holding)
		if w == null:
			break
		_to_flat(w)
	while _stud_cost > max_studs * OVER_SLACK and _studded.size() > 1:
		var w: Band = _worst(_studded)
		if w == null:
			break
		_demote_studs(w)


## Whether `cost` more fits a budget of `limit` already holding `used` over
## `held`'s bands. The first band always does.
static func _fits(used: int, cost: int, limit: int, held_: Dictionary) -> bool:
	return held_.is_empty() or used + cost <= limit


## The triangles a band's flat mesh draws.
func _flat_tris(band: Band) -> int:
	if not is_instance_valid(band.node):
		return 0
	var m := band.node.mesh as ArrayMesh
	if m == null:
		return 0
	var n := 0
	for i in m.get_surface_count():
		var idx: int = m.surface_get_array_index_len(i)
		@warning_ignore("integer_division")
		n += (idx if idx > 0 else m.surface_get_array_len(i)) / 3
	return n


## A band's chamfered triangles: its own once built, else the guess.
func _est_tris(band: Band) -> int:
	if band.state == NEAR and band.tris > 0:
		return band.tris
	return int(float(_flat_tris(band)) * _ratio)


## A band's studs as geometry: what they came to last time, else half of all
## it has (the far half of a storey is out past the geometry rings).
func _est_studs(band: Band) -> int:
	if band.stud_geo_n >= 0:
		return band.stud_geo_n
	@warning_ignore("integer_division")
	return band.stud_buffer.size() / 32


func _hold_set(key: int, cost: int) -> void:
	_hold_cost += cost - int(_holding.get(key, 0))
	_holding[key] = cost


func _hold_erase(key: int) -> void:
	_hold_cost -= int(_holding.get(key, 0))
	_holding.erase(key)


func _stud_set(key: int, cost: int) -> void:
	_stud_cost += cost - int(_studded.get(key, 0))
	_studded[key] = cost


func _stud_erase(key: int) -> void:
	_stud_cost -= int(_studded.get(key, 0))
	_studded.erase(key)


## A band's stud geometry given up for cards (its next visit sorts them).
func _demote_studs(band: Band) -> void:
	band.stud_geo = false
	_stud_erase(band.key)
	band.stud_eye = Vector3.INF


func _worst(of: Dictionary) -> Band:
	var worst: Band = null
	for key in of:
		var b: Band = _bands.get(key)
		if b != null and b.state != UPLOADING and (worst == null or b.score > worst.score):
			worst = b
	return worst


## A node's render layers, and setting them -- past DebugView, which hides a
## node the same way this hides a flat band (its layers swapped for a layer no
## camera draws, the real ones kept in a meta) and puts back what it kept. So
## while DebugView has a node hidden, its real layers are the meta's, and that
## is what is read and written: read from `layers`, a band shown chamfered
## during a hidden view would remember the hidden layer as its own, and its
## flat mesh would stay invisible for good once it went back to it.
static func _layers_of(node: VisualInstance3D) -> int:
	return int(node.get_meta(&"view_layers", node.layers))


static func _set_layers(node: VisualInstance3D, layers: int) -> void:
	if node.has_meta(&"view_layers"):
		node.set_meta(&"view_layers", layers)
	else:
		node.layers = layers


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
			_set_layers(band.node, band.layers)
		if is_instance_valid(band.near):
			band.near.queue_free()
	_drop_studs(band)
	_busy.erase(key)
	_hold_erase(key)
	_unlink(key, band.chunk)
	_bands.erase(key)
	_order.erase(key)
