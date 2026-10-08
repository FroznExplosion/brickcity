class_name TerrainCoarse
extends Node3D

## THE COARSE GROUND: everything past the detailed tiles, out to the horizon.
## [Docs/Terrain.md](../Docs/Terrain.md) §19.4, §19.19, §22.16.
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

## Print how many blocks each span got (the heightfield bench).
var verbose := false

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


## Lay the tier out to `reach_tiles` of the origin and bake it.
##
## `hole`, in TILE coordinates and inclusive of its edges (how a streamer's
## resident square is expressed), is left empty: the fixed kind. `split_to`
## is the biggest block, in tiles, that is kept as a node of its own so it can
## be hidden: the following kind, and then `cover` every frame.
func build(reach_tiles: int, material: Material, hole := Rect2i(), split_to := 0) -> void:
	_reach_tiles = reach_tiles
	_material = material
	_hole = hole
	_split_to = split_to
	if reach_tiles <= 0:
		return
	var has_hole := hole.size.x > 0 and hole.size.y > 0

	# The placement is a greedy fill rather than a lattice sweep: lay the
	# LARGEST aligned block that fits each ring, then fill round them. Two
	# attempts at "place blocks ring by ring and skip the ones that overlap"
	# both left bands a whole block wide -- a tile exactly on a ring boundary
	# belongs to neither sweep -- and 2,500 one-tile fills with it. A fill
	# that always terminates at span 1 cannot leave a hole.
	var blocks: Array[Vector2i] = []
	var spans: Array[int] = []
	var steps: Array[int] = []
	var covered := {}

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
		if has_hole and hole.intersects(Rect2i(bx, bz, span, span)):
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
		var step: int = STEP << level
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

	# Whatever is left, one tile at a time. There is always something: a hole
	# is not on the block lattice, and the world's edge is not either.
	for tz in range(-reach, reach + 1):
		for tx in range(-reach, reach + 1):
			var c := Vector2i(tx, tz)
			if covered.has(c) or (has_hole and hole.has_point(c)):
				continue
			if absi(tx) > reach_tiles or absi(tz) > reach_tiles:
				continue
			blocks.append(c)
			spans.append(1)
			steps.append(STEP)
			covered[c] = true

	for i in blocks.size():
		for dz in spans[i]:
			for dx in spans[i]:
				_tile_step[blocks[i] + Vector2i(dx, dz)] = steps[i]

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
	if not blocks.is_empty():
		var task := WorkerThreadPool.add_group_task(
			func(i: int) -> void:
				baked[i] = BrickTerrain.build_coarse(blocks[i].x, blocks[i].y,
					spans[i], steps[i]),
			blocks.size(), -1, true, "terrain coarse")
		WorkerThreadPool.wait_for_group_task_completion(task)

	var tile_studs := BrickTerrain.get_tile_studs()
	var stud := BrickWorld.get_stud_metres()
	# The blocks the detail can ever cover (`split_to` and smaller) stay
	# separate, because hiding is per node. Everything bigger -- and with a
	# fixed hole, everything -- is merged into ONE mesh a ring: those blocks
	# never need to be hidden individually.
	#
	# Draw calls were growing linearly with view distance -- 1,157 at 9 km --
	# and this is where they were going.
	var merged := {}          ## span -> the bakes of that ring's blocks, in member order
	for i in blocks.size():
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
		var mi := _block_node(arrays, steps[i], "Coarse_%d_%d" % [blocks[i].x, blocks[i].y])
		_all_node[_all_rects.size() - 1] = mi
		mi.position = origin
		_far_nodes.append(mi)
		_far_rects.append(Rect2i(blocks[i], Vector2i(spans[i], spans[i])))
		_far_blocks += 1

	for span in merged:
		_rebuild_ring(span, merged[span])
		_far_rings += 1
		_far_blocks += merged[span].size()


## Everything again, as `build` was last asked: after the smooth step changed
## (the dev menu), or to see a border as the build lays it out.
func rebuild() -> void:
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
	_tile_step.clear()
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
func _rebuild_ring(span: int, have: Array[Dictionary] = []) -> void:
	var members: Array[int] = _ring_members.get(span, [] as Array[int])
	var live: Array[int] = []
	for i in members:
		if _all_owner[i] != -2:
			live.append(i)
	var baked: Array[Dictionary] = have
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
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,
			_offset_surface(arrays, Vector3(_all_rects[live[k]].position.x * tile_studs * stud,
				0.0, _all_rects[live[k]].position.y * tile_studs * stud)),
			[], {}, TerrainTile.CUSTOM0_FLAGS)
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
func cover(streamer: TerrainStreamer) -> void:
	if _far_nodes.is_empty():
		return
	_refine_for(streamer.current_region())
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
					if absi(c.x) > _reach_tiles or absi(c.y) > _reach_tiles:
						continue
					if not streamer.has_tile(c):
						covered = false
						break
				if not covered:
					break
		_far_nodes[i].visible = not covered
		if covered:
			_far_hidden += 1


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
	var dirty_rings := {}
	for i in todo:
		_split(_all_rects[i], detail, new_rects)
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
		else:
			dirty_rings[_all_rects[i].size.x] = true
	for span in dirty_rings:
		_rebuild_ring(span)
	if new_rects.is_empty():
		return

	# Bake the children in parallel, like everything else that reads the
	# field and nothing else.
	var baked: Array[Dictionary] = []
	baked.resize(new_rects.size())
	var task := WorkerThreadPool.add_group_task(
		func(k: int) -> void:
			@warning_ignore("integer_division")
			baked[k] = BrickTerrain.build_coarse(new_rects[k].position.x,
				new_rects[k].position.y, new_rects[k].size.x,
				STEP * (new_rects[k].size.x / SPAN)),
		new_rects.size(), -1, true, "coarse refine")
	WorkerThreadPool.wait_for_group_task_completion(task)

	var tile_studs := BrickTerrain.get_tile_studs()
	var stud := BrickWorld.get_stud_metres()
	for k in new_rects.size():
		var arrays: Array = baked[k]["mesh"]
		if arrays.is_empty():
			continue
		@warning_ignore("integer_division")
		var step: int = STEP * (new_rects[k].size.x / SPAN)
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
func relod(at: Vector3) -> void:
	var tile_m := float(BrickTerrain.get_tile_studs()) * BrickWorld.get_stud_metres()
	var c := Vector2i(floori(at.x / tile_m), floori(at.z / tile_m))
	if c == _relod_at:
		return
	_relod_at = c
	var redo: Array[int] = []
	var want: Array[int] = []
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
		var step: int = maxi(STEP << level, 1)
		step = mini(step, r.size.x * BrickTerrain.get_tile_studs())
		if step != _all_steps[i]:
			redo.append(i)
			want.append(step)
	if redo.is_empty():
		return
	var baked: Array[Dictionary] = []
	baked.resize(redo.size())
	var task := WorkerThreadPool.add_group_task(
		func(k: int) -> void:
			var r: Rect2i = _all_rects[redo[k]]
			baked[k] = BrickTerrain.build_coarse(r.position.x, r.position.y, r.size.x, want[k]),
		redo.size(), -1, true, "coarse relod")
	WorkerThreadPool.wait_for_group_task_completion(task)
	for k in redo.size():
		var i: int = redo[k]
		var mi := _all_node[i] as MeshInstance3D
		var arrays: Array = baked[k]["mesh"]
		if not is_instance_valid(mi) or arrays.is_empty():
			continue
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {},
				TerrainTile.CUSTOM0_FLAGS)
		mi.mesh = mesh
		mi.set_instance_shader_parameter("lod_level", lod_of_step(want[k]))
		_all_steps[i] = want[k]


# ---------------------------------------------------------------------------

## The field changed over these TILES (an edit, a pad cut for a placed
## build): bake the blocks over them again, each at the step it was built
## with -- a merged ring as a whole, since a ring is one mesh.
func field_changed(tiles: Rect2i) -> void:
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
