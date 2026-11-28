class_name TerrainCoarse
extends Node3D

## THE COARSE GROUND: everything past the detailed tiles, out to the horizon.
## [Docs/Terrain.md](../../Docs/Terrain.md) §19.4, §19.19, §22.16.
##
## CASCADED BLOCKS: the further out, the bigger the block and the coarser the
## samples inside it. One coarse level at a fixed 1.4 m sample does not scale,
## and the numbers said so plainly: 560 m held 2.9M triangles, 1.1 km held
## 10.7M, and 2.2 km held 40.9M and drew at 80 ms. Constant density over a
## disc is quadratic in the radius, and no amount of culling fixes quadratic.
## Doubling the sample spacing every time the radius doubles makes each ring
## cost the SAME as the one inside it -- a block always holds the same
## (span x TILE / step)^2 cells -- so the tier is linear in the NUMBER of
## rings, which is logarithmic in distance.
##
## ONE CLASS, TWO KINDS OF WORLD. There were two copies of this cascade, one
## in `heightfield_scene` and a smaller one here for the city, and they had
## begun to differ (only one told the shader a block's LOD level). What a
## world chooses is how the tier meets the detail:
##
##   A FIXED HOLE (`build`'s `hole`). An authored place -- a city -- has a
##   detail tier that covers it and never moves, so the hole is cut once at
##   build time and never thought about again. Every block is merged into one
##   mesh a ring: no per-frame coverage test, no quadtree, no per-block node.
##
##   NO HOLE, FOLLOWING (`split_to` > 0, then `cover` and `relod` every
##   frame). The detail square MOVES, so the tier covers the whole world,
##   including under the detail, and blocks are HIDDEN where detail covers
##   them. A build-time hole is the obvious saving and it is wrong there: the
##   detail moves and the hole does not, so walking away from the origin left
##   a black pit behind. Blocks no bigger than `split_to` tiles (the
##   streamer's `align`) are a node each, because hiding is per node; bigger
##   ones are split when the detail walks into them.

## Tiles a side of the smallest coarse block.
const SPAN := 4
## Studs between samples inside the smallest block. Both DOUBLE with every
## ring outward, which is the whole reason distance is affordable.
const STEP := 4
## Where ring 0 ends, in tiles from the origin. Each ring after it reaches
## twice as far.
const FIRST := 16
## How many doublings at most. Six takes a 4-tile block to 128 (5.6 km).
const LEVELS := 6

## DISTANT GROUND DETAIL (the Video setting, Docs/MineWorld.md 21 item 6):
## 0 High (as laid out), 1 Medium, 2 Low -- every block sampled 2x or 4x
## coarser, a quarter or a sixteenth of the triangles. Read when a tier is
## built; the mine world builds a fresh one when it changes.
static var detail := 0
## The `detail` this tier was built at.
var built_detail := 0


## A block's sample step at the current detail, never coarser than it is wide.
static func detail_step(step: int, span_tiles: int) -> int:
	return mini(step << clampi(detail, 0, 2), span_tiles * BrickTerrain.get_tile_studs())


## Print how many blocks each span got (the heightfield bench).
var verbose := false
## The tile the rings are laid out round. The origin for a world that stays
## put; an endless one (Docs/MineWorld.md 3) builds a fresh tier round the
## player's tile now and then and swaps it in (`build_begin`/`build_poll`).
var anchor := Vector2i.ZERO
## A build in flight (`build_begin`): the layout and the group task.
var _build_job := {}
## Edits during play (`field_changed_soon`): the tiles waiting, and the
## re-bake in flight.
var _edit_dirty := Rect2i()
var _edit_job := {}

## What `build` was last asked for: `rebuild` asks again.
var _reach_tiles := 0
var _material: Material = null
var _hole := Rect2i()
var _split_to := 0

## The blocks that are a node each, and each one's tile rect. An entry is
## null once a later split retired its block.
var _far_nodes: Array[MeshInstance3D] = []
var _far_rects: Array[Rect2i] = []
var _far_hidden := 0
var _far_tris := 0
var _far_blocks := 0
var _far_rings := 0
## Every coarse block's tile rect, and which node draws it: an index into
## `_far_nodes`, -1 for a merged ring (always drawn), -2 once it was split.
var _all_rects: Array[Rect2i] = []
var _all_owner: Array[int] = []
## Each block's sample step, beside its rect: an edit re-bakes a block at the
## step it was built with.
var _all_steps: Array[int] = []
## Block index -> its own node, for blocks that have one.
var _all_node := {}
## span -> the block indices in that ring, and the ring's mesh node.
var _ring_members := {}
var _ring_nodes := {}
## The camera tile the small blocks were last re-LODded for.
var _relod_at := Vector2i(1 << 30, 0)
## Tile -> the sample step of the block covering it AS BUILT, for `height_at`.
var _tile_step := {}
## Where _tile_step's origin is (its keys are round it: the layout is shared).
var _tile_step_at := Vector2i.ZERO
## Layouts made, by reach and detail (build_begin): shared by every tier.
static var _layouts := {}
## What the last build_poll spent its time on (a gate's line).
var last_poll_note := ""

## FOLLOWING NEVER WAITS (Terrain.md 22.19). `relod` and `_refine_for` used to
## start their bakes on the worker threads and then WAIT for them, on the main
## thread, every time the camera entered a new tile -- the hitch when walking.
## Now each starts its bakes and returns; a later frame swaps the results in,
## under APPLY_BUDGET_MS. Until then the old blocks keep drawing. One job of
## each kind at a time; the camera having moved on meanwhile is caught by the
## next call. An edit (`field_changed`), a `rebuild` and leaving the tree
## finish a job in flight first, blocking -- they are rare.
const APPLY_BUDGET_MS := 1.5
## {task, redo, want, baked, nodes, next}: a relod in flight, or empty.
var _relod_job := {}
## {task, todo, new_rects, baked, spans, ring_live, ring_baked}: a split in
## flight, or empty.
var _refine_job := {}
## The longest a frame spent on this tier's main-thread work (swapping meshes
## in), for the bench and the probe.
var worst_main_ms := 0.0
## HELD (moving fast, Docs/MineWorld.md 14): no new refine or relod starts; a
## job in flight still lands. The blocks drawn stay as they are.
var hold := false


## Lay the tier out to `reach_tiles` of the origin and bake it.
##
## `hole`, in TILE coordinates and inclusive of its edges (how a streamer's
## resident square is expressed), is left empty: the fixed kind. `split_to`
## is the biggest block, in tiles, that is kept as a node of its own so it can
## be hidden: the following kind, and then `cover` every frame.
func build(reach_tiles: int, material: Material, hole := Rect2i(), split_to := 0) -> void:
	_job_wait_all(_build_job)
	_build_job = {}
	if not build_begin(reach_tiles, material, hole, split_to):
		return
	_job_wait(_build_job)
	while not build_poll():
		_job_wait_all(_build_job)


## `build`, without waiting: lays the tier out and starts the bakes on the
## worker pool. Call `build_poll` each frame until it says true; the tier is
## empty until then. False when there is nothing to build.
func build_begin(reach_tiles: int, material: Material, hole := Rect2i(), split_to := 0) -> bool:
	_reach_tiles = reach_tiles
	_material = material
	_hole = hole
	_split_to = split_to
	built_detail = detail
	if reach_tiles <= 0:
		return false
	var has_hole := hole.size.x > 0 and hole.size.y > 0
	var a := anchor

	# The placement is a greedy fill rather than a lattice sweep: lay the
	# LARGEST aligned block that fits each ring, then fill round them. Two
	# attempts at "place blocks ring by ring and skip the ones that overlap"
	# both left bands a whole block wide -- a tile exactly on a ring boundary
	# belongs to neither sweep -- and 2,500 one-tile fills with it. A fill
	# that always terminates at span 1 cannot leave a hole.
	# THE LAYOUT IS THE SAME at every re-anchor of an endless world (no hole:
	# the same reach and detail, laid out round the origin): made once and
	# kept. Made each time it was 14-18 ms of GDScript on the main thread at
	# every re-anchor, the flight's worst frame (--gate=stop, 2026-11-27).
	var cache_key := "%d|%d" % [reach_tiles, detail]
	var cached: Dictionary = {} if has_hole else _layouts.get(cache_key, {})
	var blocks: Array[Vector2i] = []
	var spans: Array[int] = []
	var steps: Array[int] = []
	var covered := {}

	if cached.is_empty():
		# Only as many doublings as the reach actually needs: rounding a 560 m
		# field up to the six-level lattice drew 1.4 km of ground nobody asked for.
		var levels := 1
		while (FIRST << (levels - 1)) < reach_tiles and levels < LEVELS:
			levels += 1
		var coarsest: int = SPAN << (levels - 1)
		# The edge of the field, rounded UP to the coarsest lattice. A block has
		# to fit entirely inside the reach or it is refused and the fill falls
		# back a level, so a reach that is not a multiple of the biggest span
		# frays the whole rim down to one-tile blocks: at 9 km that was 3,212 of
		# them. Rounding up draws a little more ground than asked for, which costs
		# one row of blocks and nothing else.
		var reach: int = int(ceil(float(reach_tiles) / float(coarsest))) * coarsest

		var free_at := func(bx: int, bz: int, span: int) -> bool:
			if absi(bx) > reach or absi(bz) > reach:
				return false
			if absi(bx + span - 1) > reach or absi(bz + span - 1) > reach:
				return false
			# NOT over a fixed detail square. Where the two tiers overlap the
			# ground is drawn twice, and coarse samples poke through detail ground.
			if has_hole and hole.intersects(Rect2i(bx + a.x, bz + a.y, span, span)):
				return false
			for dz in span:
				for dx in span:
					if covered.has(Vector2i(bx + dx, bz + dz)):
						return false
			return true

		# COARSEST FIRST, then fill in.
		#
		# Placing a block per uncovered tile, at that tile's own level, fragments
		# badly: a big block is refused whenever any of its cells was already
		# taken by a smaller one, so the scan produced 471 blocks where the ring
		# arithmetic says about 140. Laying the big ones first and letting the
		# small ones fill around them is the same greedy idea with the order that
		# actually works.
		#
		# Ring 0 starts at the origin, not at some fixed near square: with no hole
		# the detail moves, so the tier has to be able to draw anywhere the detail
		# is not. Excluding the origin square left 21 tiles drawn by nothing the
		# moment the camera walked away from it.
		for level in range(levels - 1, -1, -1):
			var span: int = SPAN << level
			var step: int = detail_step(STEP << level, SPAN << level)
			var inner: int = 0 if level == 0 else (FIRST << (level - 1))
			for bz in range(-reach, reach, span):
				for bx in range(-reach, reach, span):
					# The block's NEAREST corner, in Chebyshev radius: a block may
					# sit in its own ring or further out, never closer, or its
					# samples would be visible.
					var nx: int = 0 if bx <= 0 and bx + span - 1 >= 0 else mini(absi(bx), absi(bx + span - 1))
					var nz: int = 0 if bz <= 0 and bz + span - 1 >= 0 else mini(absi(bz), absi(bz + span - 1))
					if maxi(nx, nz) < inner:
						continue        # too close for this level of detail
					if not free_at.call(bx, bz, span):
						continue
					blocks.append(Vector2i(bx, bz))
					spans.append(span)
					steps.append(step)
					for dz in span:
						for dx in span:
							covered[Vector2i(bx + dx, bz + dz)] = true

		# Whatever is left, one tile at a time: round a hole, which is not on the
		# block lattice. Inside the blocks' own square [-reach, reach): one more
		# row and column (to reach, inclusive) was 257 one-tile blocks along the
		# far rim, a node and a draw each at the finest sample step, ground at the
		# horizon nobody asked for (--gate=gpu: the far tier 335 meshes, 257 of
		# them these; Docs/MineWorld.md 21, item 6).
		for tz in range(-reach, reach):
			for tx in range(-reach, reach):
				var c := Vector2i(tx, tz)
				if covered.has(c) or (has_hole and hole.has_point(c + a)):
					continue
				if absi(tx) > reach_tiles or absi(tz) > reach_tiles:
					continue
				blocks.append(c)
				spans.append(1)
				steps.append(detail_step(STEP, 1))
				covered[c] = true

		# Each tile's sample step, round the origin (height_at reads it from the anchor).
		var ts := {}
		for i in blocks.size():
			for dz in spans[i]:
				for dx in spans[i]:
					ts[blocks[i] + Vector2i(dx, dz)] = steps[i]
		cached = {"blocks": blocks, "spans": spans, "steps": steps, "tile_step": ts}
		if not has_hole:
			_layouts[cache_key] = cached
	blocks = (cached.blocks as Array[Vector2i]).duplicate()
	spans = (cached.spans as Array[int]).duplicate()
	steps = (cached.steps as Array[int]).duplicate()
	_tile_step = cached.tile_step
	_tile_step_at = a

	# Laid out round the origin; placed round the anchor.
	for i in blocks.size():
		blocks[i] += a

	if verbose:
		var by_span := {}
		for v in spans:
			by_span[v] = int(by_span.get(v, 0)) + 1
		var keys := by_span.keys()
		keys.sort()
		for k in keys:
			print("[bench]   span %2d: %d blocks" % [k, by_span[k]])

	# Baked in parallel, like the near tier and for the same reason: it is
	# C++ that only reads the field.
	var baked: Array[Dictionary] = []
	baked.resize(blocks.size())
	if blocks.is_empty():
		return false
	# A block that goes into a merged ring is moved to its place HERE, on the
	# worker: done in _assemble it was a GDScript loop over every vertex of
	# every ring block on the main thread -- most of the 40-50 ms an endless
	# world's tier swap took (Docs/MineWorld.md 14).
	var ring_from := split_to
	var tile_m := float(BrickTerrain.get_tile_studs()) * BrickWorld.get_stud_metres()
	var task := WorkerThreadPool.add_group_task(
		func(i: int) -> void:
			var d: Dictionary = BrickTerrain.build_coarse(blocks[i].x, blocks[i].y,
				spans[i], steps[i])
			if spans[i] > ring_from and not (d.get("mesh", []) as Array).is_empty():
				d["mesh"] = _offset_surface(d["mesh"], Vector3(blocks[i].x * tile_m, 0.0,
						blocks[i].y * tile_m))
				d["offset"] = true
			baked[i] = d,
		blocks.size(), -1, true, "terrain coarse")
	_build_job = {"task": task, "blocks": blocks, "spans": spans, "steps": steps,
			"baked": baked}
	return true


## The build `build_begin` started: true once it is baked and in the tree.
## Never blocks on the bakes. `budget_ms` > 0 puts the meshes in a slice a
## call, that long at most (a block, or a ring, is the smallest piece): for a
## tier that is hidden until it is done (the mine world's re-anchor); <= 0
## puts them all in at once.
func build_poll(budget_ms := -1.0) -> bool:
	if _build_job.is_empty():
		return true
	var w0 := Time.get_ticks_usec()
	if not _job_done(_build_job):
		return false
	var w1 := Time.get_ticks_usec()
	var job := _build_job
	if not job.has("next"):
		job["next"] = 0
		job["merged"] = {}
		job["rings"] = []
	var t0 := Time.get_ticks_usec()
	last_poll_note = " wait %.1f" % ((w1 - w0) / 1000.0)
	if not _assemble(job, budget_ms, t0):
		last_poll_note += " assemble %.1f (%d of %d)" % [(Time.get_ticks_usec() - t0) / 1000.0, int(job.next), (job.blocks as Array).size()]
		return false
	# The bakes' arrays (every block's mesh, ~360k triangles) let go on a
	# worker: dropped here they were ~9 ms of freeing in the swap's frame.
	_build_job = {}
	if budget_ms > 0.0:
		var dead := [job]
		job = {}
		WorkerThreadPool.add_task(func() -> void: dead.clear(), false, "coarse build freed")
	return true


## Put a finished build's meshes in, from where the last call stopped. True
## when everything is in.
func _assemble(job: Dictionary, budget_ms: float, t0: int) -> bool:
	var blocks: Array[Vector2i] = job.blocks
	var spans: Array[int] = job.spans
	var steps: Array[int] = job.steps
	var baked: Array[Dictionary] = job.baked
	var split_to := _split_to
	var tile_studs := BrickTerrain.get_tile_studs()
	var stud := BrickWorld.get_stud_metres()
	var out_of_time := func() -> bool:
		return budget_ms > 0.0 and float(Time.get_ticks_usec() - t0) / 1000.0 >= budget_ms
	# The blocks the detail can ever cover (`split_to` and smaller) stay
	# separate, because hiding is per node. Everything bigger -- and with a
	# fixed hole, everything -- is merged into ONE mesh a ring: those blocks
	# never need to be hidden individually.
	#
	# Draw calls were growing linearly with view distance -- 1,157 at 9 km --
	# and this is where they were going.
	var merged: Dictionary = job.merged   ## span -> the bakes of that ring's blocks, in member order
	while int(job.next) < blocks.size():
		if out_of_time.call():
			return false
		var i: int = job.next
		job.next = i + 1
		var arrays: Array = baked[i]["mesh"]
		if arrays.is_empty():
			continue
		_far_tris += int(baked[i]["triangle_count"])
		var origin := Vector3(blocks[i].x * tile_studs * stud, 0.0,
				blocks[i].y * tile_studs * stud)
		_all_rects.append(Rect2i(blocks[i], Vector2i(spans[i], spans[i])))
		_all_steps.append(steps[i])
		if spans[i] > split_to:
			# -1: lives in a merged ring and is therefore always drawn. A
			# block like this cannot be hidden on its own -- splitting is the
			# only way to get the detail's ground back off it -- so the ring
			# it belongs to keeps a HOLE where a split has retired a block.
			_all_owner.append(-1)
			if not merged.has(spans[i]):
				merged[spans[i]] = [] as Array[Dictionary]
				_ring_members[spans[i]] = [] as Array[int]
			merged[spans[i]].append(baked[i])
			_ring_members[spans[i]].append(_all_rects.size() - 1)
			continue
		_all_owner.append(_far_nodes.size())
		var bt0 := Time.get_ticks_usec()
		var mi := _block_node(arrays, steps[i], "Coarse_%d_%d" % [blocks[i].x, blocks[i].y])
		last_poll_note += " b%.1f" % ((Time.get_ticks_usec() - bt0) / 1000.0) if Time.get_ticks_usec() - bt0 > 1000 else ""
		_all_node[_all_rects.size() - 1] = mi
		mi.position = origin
		_far_nodes.append(mi)
		_far_rects.append(Rect2i(blocks[i], Vector2i(spans[i], spans[i])))
		_far_blocks += 1

	if merged.is_empty():
		return true
	# The rings' meshes are made on a worker; here they are only attached.
	if not job.has("ring_job"):
		job["ring_job"] = _start_ring_meshes(merged)
		if budget_ms > 0.0:
			return false
	var rj: Dictionary = job.ring_job
	if budget_ms <= 0.0:
		_job_wait(rj)
	elif not _job_done(rj):
		return false
	var rt0 := Time.get_ticks_usec()
	for j in (rj.spans as Array).size():
		var span: int = rj.spans[j]
		_rebuild_ring(span, merged[span], rj.meshes[j])
		_far_rings += 1
		_far_blocks += merged[span].size()
	last_poll_note += " rings %.1f ms" % ((Time.get_ticks_usec() - rt0) / 1000.0)
	merged.clear()
	return true


## Leaving the tree with bakes in flight: wait for them. A worker still
## inside BrickTerrain when the scene goes away crashed the engine on the way
## out (TerrainStreamer._exit_tree, Terrain.md 22.15).
func _exit_tree() -> void:
	_wait_jobs()
	_job_wait_all(_build_job)
	_build_job = {}
	_job_wait(_edit_job)
	_edit_job = {}
	_relod_job = {}
	_refine_job = {}


## Finish whatever is in flight now, blocking: before something that changes
## the blocks under it.
func _wait_jobs() -> void:
	_job_wait(_relod_job)
	_job_wait_all(_refine_job)


## A group task may be waited on ONCE: its id is gone after. So a job
## remembers that it was, and asks `is_group_task_completed` (not
## `is_task_completed`, which knows nothing of group ids) until then.
static func _job_wait(job: Dictionary) -> void:
	if job.is_empty() or job.get("waited", false):
		return
	WorkerThreadPool.wait_for_group_task_completion(job.task)
	job["waited"] = true


## A job and the ring meshes it started after its bakes (`ring_job`).
static func _job_wait_all(job: Dictionary) -> void:
	_job_wait(job)
	if job.has("ring_job"):
		_job_wait(job.ring_job)


## The rings' meshes for `rings` (span -> its members' bakes, offset
## already), made on a worker: the main thread only attaches them. Made
## there, a ring (~48 blocks, ~200k vertices) took 6-9 ms of
## add_surface_from_arrays in one frame, the walk's worst frame
## (Docs/MineWorld.md 14; Docs/WhereWorkRuns.md: meshes are built on workers).
static func _start_ring_meshes(rings: Dictionary) -> Dictionary:
	var spans: Array = rings.keys()
	var bakes: Array = []
	for span in spans:
		bakes.append(rings[span])
	var meshes: Array = []
	meshes.resize(spans.size())
	var task := WorkerThreadPool.add_group_task(
		func(j: int) -> void:
			meshes[j] = _ring_mesh(bakes[j]),
		spans.size(), -1, true, "coarse ring meshes")
	return {"task": task, "spans": spans, "meshes": meshes}


## One ring's mesh from its members' bakes (offset already). Worker-safe.
static func _ring_mesh(baked: Array) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	for d: Dictionary in baked:
		var arrays: Array = d["mesh"]
		if arrays.is_empty():
			continue
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays,
			[], {}, TerrainTile.CUSTOM0_FLAGS)
	return mesh


static func _job_done(job: Dictionary) -> bool:
	if job.get("waited", false):
		return true
	if not WorkerThreadPool.is_group_task_completed(job.task):
		return false
	_job_wait(job)
	return true


## Everything again, as `build` was last asked: after the smooth step changed
## (the dev menu), or to see a border as the build lays it out.
func rebuild() -> void:
	_wait_jobs()
	_relod_job = {}
	_refine_job = {}
	for child in get_children():
		remove_child(child)
		child.queue_free()
	_far_nodes.clear()
	_far_rects.clear()
	_all_rects.clear()
	_all_steps.clear()
	_all_owner.clear()
	_all_node.clear()
	_ring_members.clear()
	_ring_nodes.clear()
	_tile_step = {}
	_far_hidden = 0
	_far_tris = 0
	_far_blocks = 0
	_far_rings = 0
	_relod_at = Vector2i(1 << 30, 0)
	build(_reach_tiles, _material, _hole, _split_to)


## One block as a node of its own.
func _block_node(arrays: Array, step: int, node_name: String) -> MeshInstance3D:
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {},
			TerrainTile.CUSTOM0_FLAGS)
	var mi := MeshInstance3D.new()
	mi.name = node_name
	mi.mesh = mesh
	mi.material_override = _material
	mi.set_instance_shader_parameter("lod_level", lod_of_step(step))
	# Far ground does not cast: the shadow of a hill 300 m away lands on
	# ground the player cannot see, and the shadow pass was 183k triangles
	# before anything was added to it (§19.1).
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	return mi


## Build, or rebuild, one ring's mesh from the blocks still belonging to it.
##
## A ring is one mesh holding blocks from all over the world, which is what
## takes the draw calls from 832 to 371 at 4.5 km -- and it means a block
## cannot be removed from the world without rebuilding the ring around it.
## That happens when the detail walks into a block and it has to be split.
## Rare, and a ring is ~48 blocks, so it re-bakes in parallel in a few
## milliseconds. `build` hands over the bakes it already has (`have`, one a
## member, in order) rather than baking the ring twice.
func _rebuild_ring(span: int, have: Array[Dictionary] = [], made: ArrayMesh = null) -> void:
	var members: Array[int] = _ring_members.get(span, [] as Array[int])
	var live: Array[int] = []
	for i in members:
		if _all_owner[i] != -2:
			live.append(i)
	var baked: Array[Dictionary] = have
	if made != null and baked.size() != live.size():
		made = null      # members changed since: make it here, as before
	if made != null:
		_attach_ring(span, made)
		return
	if baked.size() != live.size():
		baked = []
		baked.resize(live.size())
		if not live.is_empty():
			var task := WorkerThreadPool.add_group_task(
				func(k: int) -> void:
					baked[k] = BrickTerrain.build_coarse(_all_rects[live[k]].position.x,
						_all_rects[live[k]].position.y, span,
						_all_steps[live[k]]),
				live.size(), -1, true, "coarse ring")
			WorkerThreadPool.wait_for_group_task_completion(task)

	var tile_studs := BrickTerrain.get_tile_studs()
	var stud := BrickWorld.get_stud_metres()
	var mesh := ArrayMesh.new()
	for k in live.size():
		var arrays: Array = baked[k]["mesh"]
		if arrays.is_empty():
			continue
		# A bake from a following job was offset on its worker already.
		if not baked[k].get("offset", false):
			arrays = _offset_surface(arrays, Vector3(_all_rects[live[k]].position.x
					* tile_studs * stud, 0.0, _all_rects[live[k]].position.y * tile_studs * stud))
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays,
			[], {}, TerrainTile.CUSTOM0_FLAGS)
	_attach_ring(span, mesh)


func _attach_ring(span: int, mesh: ArrayMesh) -> void:
	if _ring_nodes.has(span):
		(_ring_nodes[span] as MeshInstance3D).queue_free()
	var mi := MeshInstance3D.new()
	mi.name = "CoarseRing_%d" % span
	mi.mesh = mesh
	mi.material_override = _material
	@warning_ignore("integer_division")
	mi.set_instance_shader_parameter("lod_level", lod_of_step(STEP * span / SPAN))
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	_ring_nodes[span] = mi


## The same surface, moved. A merged ring holds blocks from all over the
## world in one mesh, so their vertices have to carry the offset the node
## transform used to.
static func _offset_surface(arrays: Array, origin: Vector3) -> Array:
	var out := arrays.duplicate(true)
	var verts: PackedVector3Array = out[Mesh.ARRAY_VERTEX]
	for i in verts.size():
		verts[i] += origin
	out[Mesh.ARRAY_VERTEX] = verts
	return out


## A coarse block's LOD level from its sample step: the detailed tiles are 0,
## a block sampled every STEP studs is 1, and each doubling one more.
## A float, because the shader's `lod_level` is one: an int handed to a float
## instance uniform is dropped without a word, and every block read as 0.
static func lod_of_step(step: int) -> float:
	return float(1 + maxi(0, roundi(log(float(step) / float(STEP)) / log(2.0))))


# ---------------------------------------------------------------------------
# Following a detail square that moves.

## A coarse block under the detailed tier is hidden. Every frame, for a world
## built with `split_to`.
##
## The tier is built once for the whole world, so without this the detail
## simply streams in ON TOP of it -- two surfaces in the same place, the
## coarse one poking through wherever its max-of-cell height beats the real
## ground. Reported as "the LOD never goes away when you walk up to it",
## which is exactly what it was.
##
## Both tiers are on the same lattice (`split_to` is the streamer's `align`),
## so a block is covered or it is not; there is no partial case to get wrong.
##
## `wait` false (the per-frame call) never blocks: a split the detail needs
## lands a few frames later. True (the default: a build, a capture, a bench)
## finishes every split now, so what is drawn is exact when it returns.
func cover(streamer: TerrainStreamer, wait := true) -> void:
	if _far_nodes.is_empty():
		return
	_edit_step()
	_refine_for(streamer.current_region())
	while wait and not _refine_job.is_empty():
		_job_wait_all(_refine_job)
		_refine_for(streamer.current_region())    # lands it
		_refine_for(streamer.current_region())    # and starts any further split
	_far_hidden = 0
	for i in _far_nodes.size():
		if _far_nodes[i] == null:
			continue                      # retired by a later split
		var rect := _far_rects[i]
		# Only the smallest blocks can ever be covered -- anything bigger is
		# further out than the detail reaches -- so only they are checked,
		# and a 128-tile block never walks its tiles.
		var covered := rect.size.x <= _split_to
		if covered:
			for dz in rect.size.y:
				for dx in rect.size.x:
					var c := rect.position + Vector2i(dx, dz)
					# Outside the authored world counts as covered: there is
					# nothing there for the detail to build, and a block
					# waiting for tiles that will never exist stayed visible
					# under real detail at the world's rim.
					# Measured from the anchor the tier was laid out round:
					# from the origin, every tile of an endless world's rings
					# laid out 100 tiles away counted as "outside" and its
					# block hid with nothing under it (Docs/MineWorld.md 3).
					if absi(c.x - anchor.x) > _reach_tiles or absi(c.y - anchor.y) > _reach_tiles:
						continue
					if not streamer.has_tile(c):
						covered = false
						break
				if not covered:
					break
		_far_nodes[i].visible = not covered
		if covered:
			_far_hidden += 1


## A split on the workers, or done and not yet put in (the next `cover`
## does): the mine world shows a re-anchored tier only when there is none.
func refining() -> bool:
	return not _refine_job.is_empty()


## Split any coarse block the detail has walked into, down to the lattice
## the detail is aligned on.
##
## The rings are laid out from the ORIGIN, so a block far out is 16, 64 or
## 128 tiles across -- and the detail square is 12. Wherever the camera walks
## far from the origin it lands INSIDE a block that is too big to hide, and
## the two tiers draw the same ground. The coverage check found 121 tiles
## like that; before the check existed, nobody found them at all.
##
## A quadtree split is the answer and it is cheap because it is local: only
## the children that actually touch the detail recurse, so a 128-tile block
## becomes about fifteen smaller ones rather than a thousand. Refined blocks
## are kept -- walking back and forth over the same ground bakes once.
func _refine_for(detail: Rect2i) -> void:
	if not _refine_job.is_empty():
		if _job_done(_refine_job):
			# Bakes in: the shrunk rings' meshes next, on a worker; then land.
			if not _refine_job.has("ring_job") and not (_refine_job.spans as Dictionary).is_empty():
				_refine_job["ring_job"] = _start_ring_meshes(_refine_job.ring_baked)
			elif not _refine_job.has("ring_job") or _job_done(_refine_job.ring_job):
				_apply_refine()
		return           # one split at a time; the next call sees the rest
	if hold:
		return
	var todo: Array[int] = []
	for i in _all_rects.size():
		if _all_rects[i].size.x <= _split_to:
			continue
		if _all_owner[i] == -2:
			continue                      # already split
		if _all_rects[i].intersects(detail):
			todo.append(i)
	if todo.is_empty():
		return

	var new_rects: Array[Rect2i] = []
	var spans := {}
	for i in todo:
		_split(_all_rects[i], detail, new_rects)
		if not _all_node.has(i):
			spans[_all_rects[i].size.x] = true
	# The rings that lose a member, baked as they will be once it is gone:
	# every live member except the ones being split.
	var ring_live := {}
	var jobs: Array = []     # [span or -1, index into new_rects or ring_live]
	for span in spans:
		var live: Array[int] = []
		for i in (_ring_members.get(span, [] as Array[int]) as Array[int]):
			if _all_owner[i] != -2 and not (i in todo):
				live.append(i)
		ring_live[span] = live
		for k in live.size():
			jobs.append([span, k])
	for k in new_rects.size():
		jobs.append([-1, k])
	var baked: Array[Dictionary] = []
	baked.resize(new_rects.size())
	var ring_baked := {}
	for span in spans:
		var b: Array[Dictionary] = []
		b.resize((ring_live[span] as Array).size())
		ring_baked[span] = b
	var tile_studs := BrickTerrain.get_tile_studs()
	var stud := BrickWorld.get_stud_metres()
	# Copies: the workers must not read arrays the main thread writes.
	var rects := _all_rects.duplicate()
	var steps := _all_steps.duplicate()
	# Bake the children and the shrunk rings in parallel, like everything else
	# that reads the field and nothing else -- and do not wait for them.
	var task := WorkerThreadPool.add_group_task(
		func(j: int) -> void:
			var span: int = jobs[j][0]
			var k: int = jobs[j][1]
			if span < 0:
				@warning_ignore("integer_division")
				baked[k] = BrickTerrain.build_coarse(new_rects[k].position.x,
					new_rects[k].position.y, new_rects[k].size.x,
					detail_step(STEP * (new_rects[k].size.x / SPAN), new_rects[k].size.x))
			else:
				var i: int = ring_live[span][k]
				var r: Rect2i = rects[i]
				var d: Dictionary = BrickTerrain.build_coarse(r.position.x, r.position.y,
					span, steps[i])
				var arrays: Array = d["mesh"]
				if not arrays.is_empty():
					d["mesh"] = _offset_surface(arrays, Vector3(r.position.x * tile_studs * stud,
						0.0, r.position.y * tile_studs * stud))
				d["offset"] = true
				ring_baked[span][k] = d,
		jobs.size(), -1, true, "coarse refine")
	_refine_job = {"task": task, "todo": todo, "new_rects": new_rects, "baked": baked,
			"spans": spans, "ring_baked": ring_baked}


## A split's bakes are in: retire the blocks that were split, swap in their
## children and the shrunk rings. All at once, so no frame draws the same
## ground twice or none at all.
## Jobs swapped in (refines and relods), for the passes.
var applies := 0


func _apply_refine() -> void:
	applies += 1
	var t0 := Time.get_ticks_usec()
	var job := _refine_job
	_refine_job = {}
	_job_wait(job)
	for i in (job.todo as Array[int]):
		# A block that came from an EARLIER split is in `_far_nodes` too, and
		# freeing it without letting go of it there left `cover` setting
		# `visible` on a freed node the next frame -- the crash flying out
		# over the far ground found.
		if _all_owner[i] >= 0:
			_far_nodes[_all_owner[i]] = null
		_all_owner[i] = -2                # retired; its children cover it
		if _all_node.has(i):
			(_all_node[i] as MeshInstance3D).queue_free()
			_all_node.erase(i)
	var rj: Dictionary = job.get("ring_job", {})
	for span in job.spans:
		var made: ArrayMesh = null
		if not rj.is_empty():
			made = rj.meshes[(rj.spans as Array).find(span)]
		_rebuild_ring(span, job.ring_baked[span], made)

	var new_rects: Array[Rect2i] = job.new_rects
	var baked: Array[Dictionary] = job.baked
	var tile_studs := BrickTerrain.get_tile_studs()
	var stud := BrickWorld.get_stud_metres()
	for k in new_rects.size():
		var arrays: Array = baked[k]["mesh"]
		if arrays.is_empty():
			continue
		@warning_ignore("integer_division")
		var step: int = detail_step(STEP * (new_rects[k].size.x / SPAN), new_rects[k].size.x)
		var mi := _block_node(arrays, step,
				"CoarseSplit_%d_%d" % [new_rects[k].position.x, new_rects[k].position.y])
		mi.position = Vector3(new_rects[k].position.x * tile_studs * stud, 0.0,
				new_rects[k].position.y * tile_studs * stud)
		_all_rects.append(new_rects[k])
		_all_steps.append(step)
		_all_owner.append(_far_nodes.size())
		_all_node[_all_rects.size() - 1] = mi
		_far_nodes.append(mi)
		_far_rects.append(new_rects[k])
		_far_tris += int(baked[k]["triangle_count"])
		_far_blocks += 1
	# A split child's step is its build step: the relod brings it to the
	# camera's on the next tile entered -- or now, if the camera has not moved.
	_relod_at = Vector2i(1 << 30, 0)
	worst_main_ms = maxf(worst_main_ms, float(Time.get_ticks_usec() - t0) / 1000.0)


## Four children, and only the ones that touch the detail split again.
func _split(rect: Rect2i, detail: Rect2i, out: Array[Rect2i]) -> void:
	@warning_ignore("integer_division")
	var h := rect.size.x / 2
	for dz in [0, h]:
		for dx in [0, h]:
			var child := Rect2i(rect.position + Vector2i(dx, dz), Vector2i(h, h))
			if h > _split_to and child.intersects(detail):
				_split(child, detail, out)
			else:
				out.append(child)


## THE SMALL BLOCKS FOLLOW THE CAMERA'S LOD (Terrain.md 19.19). Every frame,
## for a world built with `split_to`.
##
## Ring 0 is laid out round the world's ORIGIN, and blocks split to sit
## beside the detail are kept once split -- so the ground round the origin
## (where the sites are) and everywhere the camera had passed stayed LOD 1,
## blocky, however far away the camera went. Each such block is re-baked at
## the step its distance from the camera calls for -- the same rings the tier
## is laid out in, measured from the camera instead of the origin -- whenever
## the camera enters a new tile. Smooth past LOD 1, as the rest is.
##
## `wait` false (the per-frame call) never blocks; true finishes it now.
func relod(at: Vector3, wait := true) -> void:
	if wait:
		_wait_jobs_relod()
	if not _relod_job.is_empty():
		if _job_done(_relod_job):
			_apply_relod()
		return           # the camera's new tile is looked at once this is in
	if hold and not wait:
		return
	var tile_m := float(BrickTerrain.get_tile_studs()) * BrickWorld.get_stud_metres()
	var c := Vector2i(floori(at.x / tile_m), floori(at.z / tile_m))
	if c == _relod_at:
		return
	_relod_at = c
	var redo: Array[int] = []
	var want: Array[int] = []
	var nodes: Array = []
	for i in _all_rects.size():
		if _all_owner[i] < 0 or not _all_node.has(i):
			continue
		var r: Rect2i = _all_rects[i]
		var dx: int = maxi(0, maxi(r.position.x - c.x, c.x - (r.end.x - 1)))
		var dz: int = maxi(0, maxi(r.position.y - c.y, c.y - (r.end.y - 1)))
		var d: int = maxi(dx, dz)
		var level := 0
		while level < LEVELS - 1 and d >= (FIRST << level):
			level += 1
		# A block is never sampled coarser than it is wide.
		var step: int = detail_step(maxi(STEP << level, 1), r.size.x)
		if step != _all_steps[i]:
			redo.append(i)
			want.append(step)
			nodes.append(_all_node[i])
	if redo.is_empty():
		return
	var baked: Array[Dictionary] = []
	baked.resize(redo.size())
	var rects: Array[Rect2i] = []
	for i in redo:
		rects.append(_all_rects[i])
	var task := WorkerThreadPool.add_group_task(
		func(k: int) -> void:
			baked[k] = BrickTerrain.build_coarse(rects[k].position.x, rects[k].position.y,
				rects[k].size.x, want[k]),
		redo.size(), -1, true, "coarse relod")
	_relod_job = {"task": task, "redo": redo, "want": want, "baked": baked,
			"nodes": nodes, "next": 0}


## Land a relod in flight now, all of it.
func _wait_jobs_relod() -> void:
	if _relod_job.is_empty():
		return
	_job_wait(_relod_job)
	while not _relod_job.is_empty():
		_apply_relod(INF)


## Swap a relod's meshes in, as many as fit the frame's budget; the rest
## next frame. Each block is swapped whole, so a block is never half old.
func _apply_relod(budget_ms := APPLY_BUDGET_MS) -> void:
	applies += 1
	var t0 := Time.get_ticks_usec()
	var job := _relod_job
	_job_wait(job)
	var redo: Array[int] = job.redo
	var k: int = job.next
	while k < redo.size():
		var i: int = redo[k]
		var mi = job.nodes[k]
		var arrays: Array = job.baked[k]["mesh"]
		# Split or freed since the bake started: its children took over.
		if is_instance_valid(mi) and _all_owner[i] >= 0 and _all_node.get(i) == mi \
				and not arrays.is_empty():
			var mesh := ArrayMesh.new()
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {},
					TerrainTile.CUSTOM0_FLAGS)
			(mi as MeshInstance3D).mesh = mesh
			(mi as MeshInstance3D).set_instance_shader_parameter("lod_level",
					lod_of_step(job.want[k]))
			_all_steps[i] = job.want[k]
		k += 1
		if float(Time.get_ticks_usec() - t0) / 1000.0 >= budget_ms:
			break
	job.next = k
	if k >= redo.size():
		_relod_job = {}
	worst_main_ms = maxf(worst_main_ms, float(Time.get_ticks_usec() - t0) / 1000.0)


# ---------------------------------------------------------------------------

## The field changed over these TILES (an edit, a pad cut for a placed
## build): bake the blocks over them again, each at the step it was built
## with -- a merged ring as a whole, since a ring is one mesh.
## `field_changed` for play: a shot or a placed block. Nothing waits -- the
## blocks over the tiles are re-baked on the workers and swapped in when done
## (`cover` drives it each frame). `field_changed` lands every job and waits
## for its bake, which is right for an editor's stroke and was a hitch on
## every shot in the mine world (Docs/MineWorld.md 9). Only blocks that are a
## node of their own are re-baked: merged rings are far out, where a step of
## 8 studs or more cannot show a crater, and the next build bakes them fresh.
func field_changed_soon(tiles: Rect2i) -> void:
	_edit_dirty = tiles if not _edit_dirty.has_area() else _edit_dirty.merge(tiles)


func _edit_step() -> void:
	if not _edit_job.is_empty():
		if not _job_done(_edit_job):
			return
		var job := _edit_job
		_edit_job = {}
		for k in job.nodes.size():
			var arrays: Array = job.baked[k].get("mesh", [])
			var mi := job.mis[k] as MeshInstance3D
			if arrays.is_empty() or not is_instance_valid(mi) or _all_node.get(job.nodes[k]) != mi:
				continue
			var mesh := ArrayMesh.new()
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {},
					TerrainTile.CUSTOM0_FLAGS)
			mi.mesh = mesh
	if not _edit_dirty.has_area():
		return
	var tiles := _edit_dirty
	_edit_dirty = Rect2i()
	var nodes: Array[int] = []
	var mis: Array = []
	var rects: Array[Rect2i] = []
	var steps: Array[int] = []
	for i in _all_rects.size():
		if _all_owner[i] == -2 or not _all_node.has(i) or not _all_rects[i].intersects(tiles):
			continue
		nodes.append(i)
		mis.append(_all_node[i])
		rects.append(_all_rects[i])
		steps.append(_all_steps[i])
	if nodes.is_empty():
		return
	var baked: Array[Dictionary] = []
	baked.resize(nodes.size())
	var task := WorkerThreadPool.add_group_task(
		func(k: int) -> void:
			baked[k] = BrickTerrain.build_coarse(rects[k].position.x, rects[k].position.y,
				rects[k].size.x, steps[k]),
		nodes.size(), -1, true, "coarse edit")
	_edit_job = {"task": task, "nodes": nodes, "mis": mis, "baked": baked}


func field_changed(tiles: Rect2i) -> void:
	# A job in flight baked from the field as it was: land it first, then
	# this re-bakes over it from the field as it is.
	_wait_jobs()
	if not _refine_job.is_empty():
		_apply_refine()
	while not _relod_job.is_empty():
		_apply_relod(INF)
	var dirty_rings := {}
	var nodes: Array[int] = []
	for i in _all_rects.size():
		if _all_owner[i] == -2 or not _all_rects[i].intersects(tiles):
			continue
		if _all_node.has(i):
			nodes.append(i)
		else:
			dirty_rings[_all_rects[i].size.x] = true
	var baked: Array[Dictionary] = []
	baked.resize(nodes.size())
	if not nodes.is_empty():
		var task := WorkerThreadPool.add_group_task(
			func(k: int) -> void:
				var r: Rect2i = _all_rects[nodes[k]]
				baked[k] = BrickTerrain.build_coarse(r.position.x, r.position.y,
					r.size.x, _all_steps[nodes[k]]),
			nodes.size(), -1, true, "coarse edit")
		WorkerThreadPool.wait_for_group_task_completion(task)
	for k in nodes.size():
		var arrays: Array = baked[k]["mesh"]
		var mi := _all_node[nodes[k]] as MeshInstance3D
		if arrays.is_empty() or not is_instance_valid(mi):
			continue
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {},
				TerrainTile.CUSTOM0_FLAGS)
		mi.mesh = mesh
	for span in dirty_rings:
		_rebuild_ring(span)


## The blocks drawing ground over tile `c` right now, as indices: more than
## one (or one, where the detail has a tile) is ground drawn twice. For the
## coverage check; `describe` says which block an index is.
func drawing(c: Vector2i) -> Array[int]:
	var out: Array[int] = []
	for i in _all_rects.size():
		if not _all_rects[i].has_point(c):
			continue
		var owner_i := _all_owner[i]
		if owner_i == -2:
			continue            # retired by a split
		if owner_i < 0 or _far_nodes[owner_i].visible:
			out.append(i)
	return out


func describe(i: int) -> String:
	return "span %d at %s owner %d" % [_all_rects[i].size.x, _all_rects[i].position, _all_owner[i]]


func block_rect(i: int) -> Rect2i:
	return _all_rects[i]


## The height this tier DRAWS at a column (metres), or NAN where it draws
## nothing. Not the field's height: a coarse cell stands for step^2 columns.
## For something standing on it -- a tree past the detail square
## (Docs/Impostors.md 8.2) -- to stand on what is drawn rather than float
## over it or sink in. By the steps the tier was BUILT with: a block split or
## re-LODded since is not followed.
##
## Mirrors BrickTerrain::build_coarse: samples every `step` studs on a grid
## aligned to multiples of `step` (a block's origin always is); a blocky cell
## (step under the smooth step) is flat at the LOWEST of its four corners; a
## smooth block is a grid through them, read here bilinearly.
func height_at(x: int, z: int) -> float:
	var tile := BrickTerrain.get_tile_studs()
	var t := Vector2i(floori(float(x) / tile), floori(float(z) / tile))
	t -= _tile_step_at
	if not _tile_step.has(t):
		return NAN
	var step: int = _tile_step[t]
	var x0 := floori(float(x) / step) * step
	var z0 := floori(float(z) / step) * step
	var plate := BrickWorld.get_plate_metres()
	var a := float(BrickTerrain.surface_plate(x0, z0) + 1) * plate
	var b := float(BrickTerrain.surface_plate(x0 + step, z0) + 1) * plate
	var c := float(BrickTerrain.surface_plate(x0, z0 + step) + 1) * plate
	var d := float(BrickTerrain.surface_plate(x0 + step, z0 + step) + 1) * plate
	var smooth := BrickTerrain.get_coarse_smooth_step()
	if smooth <= 0 or step < smooth:
		return minf(minf(a, b), minf(c, d))
	var fx := (float(x) - x0) / step
	var fz := (float(z) - z0) / step
	return lerpf(lerpf(a, b, fx), lerpf(c, d, fx), fz)


func triangle_count() -> int:
	return _far_tris


func block_count() -> int:
	return _far_blocks


func ring_count() -> int:
	return _far_rings


## Blocks hidden under the detail, as of the last `cover`.
func hidden_count() -> int:
	return _far_hidden


## Meshes drawn at most: a node a small block, one a ring.
func mesh_count() -> int:
	return _far_nodes.size() + _far_rings
