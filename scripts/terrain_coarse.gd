class_name TerrainCoarse
extends Node3D

## The coarse ground around a FIXED detail square.
## [Docs/Terrain.md](../Docs/Terrain.md) §19.4.
##
## `heightfield_scene` has its own copy of this cascade and it is five times
## the size, because there the detail square MOVES: the coarse tier has to be
## hidden under a camera that can walk anywhere, and blocks bigger than the
## detail square have to be split when it walks into them. A CITY is an
## authored place — the detail tier covers the city and nothing else, and that
## square never moves — so the hole in the coarse tier is cut once at build
## time and never thought about again. No per-frame coverage test, no
## quadtree, no per-block visibility.
##
## Same cascade in both: the further out, the bigger the block and the coarser
## the samples inside it, so every ring costs what the ring inside it cost and
## the tier is logarithmic in view distance instead of quadratic.

## Tiles a side of the smallest coarse block.
const SPAN := 4
## Studs between samples inside the smallest block.
const STEP := 4
## Where the second level starts, in tiles from the origin.
const FIRST := 16
## How many doublings at most. Six takes a 4-tile block to 128.
const LEVELS := 6

var _tris := 0
var _blocks := 0
var _rings := 0


## Fill everything inside `reach_tiles` of the origin that `hole` does not
## cover. `hole` is in TILE coordinates and is inclusive of its edges, which
## is how a streamer's resident square is expressed.
func build(hole: Rect2i, reach_tiles: int, material: Material) -> void:
	if reach_tiles <= 0:
		return
	var levels := 1
	while (FIRST << (levels - 1)) < reach_tiles and levels < LEVELS:
		levels += 1
	var coarsest: int = SPAN << (levels - 1)
	# Rounded UP to the coarsest lattice: a block has to fit entirely inside
	# the reach or it is refused, and a reach that is not a multiple of the
	# biggest span frays the whole rim down to one-tile blocks.
	var reach: int = int(ceil(float(reach_tiles) / float(coarsest))) * coarsest

	var blocks: Array[Vector2i] = []
	var spans: Array[int] = []
	var steps: Array[int] = []
	var covered := {}

	var free_at := func(bx: int, bz: int, span: int) -> bool:
		if absi(bx) > reach or absi(bz) > reach:
			return false
		if absi(bx + span - 1) > reach or absi(bz + span - 1) > reach:
			return false
		# NOT over the detail. Where the two tiers overlap the ground is
		# drawn twice, and coarse samples poke through detail ground.
		if hole.intersects(Rect2i(bx, bz, span, span)):
			return false
		for dz in span:
			for dx in span:
				if covered.has(Vector2i(bx + dx, bz + dz)):
					return false
		return true

	# COARSEST FIRST, then fill in around them. Placing a block per uncovered
	# tile at that tile's own level fragments badly — a big block is refused
	# whenever any one of its cells was already taken by a small one.
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
					continue
				if not free_at.call(bx, bz, span):
					continue
				blocks.append(Vector2i(bx, bz))
				spans.append(span)
				steps.append(step)
				for dz in span:
					for dx in span:
						covered[Vector2i(bx + dx, bz + dz)] = true

	# Whatever is left, a tile at a time. There is always something: the hole
	# is not on the block lattice and neither is the world's edge. A fill that
	# always terminates at span 1 cannot leave a gap.
	for tz in range(-reach, reach + 1):
		for tx in range(-reach, reach + 1):
			var c := Vector2i(tx, tz)
			if covered.has(c) or hole.has_point(c):
				continue
			if absi(tx) > reach_tiles or absi(tz) > reach_tiles:
				continue
			blocks.append(c)
			spans.append(1)
			steps.append(STEP)
			covered[c] = true

	# Baked in parallel: `build_coarse` only reads the field.
	var baked: Array[Dictionary] = []
	baked.resize(blocks.size())
	if not blocks.is_empty():
		var task := WorkerThreadPool.add_group_task(
			func(i: int) -> void:
				baked[i] = BrickTerrain.build_coarse(blocks[i].x, blocks[i].y,
					spans[i], steps[i]),
			blocks.size(), -1, true, "city coarse")
		WorkerThreadPool.wait_for_group_task_completion(task)

	# ONE MESH A RING. These blocks are never hidden individually, so there is
	# nothing to gain from a node each and a great deal to lose: draw calls
	# grow linearly with view distance if every block is its own node.
	var tile_studs := BrickTerrain.get_tile_studs()
	var stud := BrickWorld.get_stud_metres()
	var meshes := {}          ## span -> ArrayMesh
	for i in blocks.size():
		var arrays: Array = baked[i]["mesh"]
		if arrays.is_empty():
			continue
		_tris += int(baked[i]["triangle_count"])
		_blocks += 1
		if not meshes.has(spans[i]):
			meshes[spans[i]] = ArrayMesh.new()
		var origin := Vector3(blocks[i].x * tile_studs * stud, 0.0,
				blocks[i].y * tile_studs * stud)
		(meshes[spans[i]] as ArrayMesh).add_surface_from_arrays(
			Mesh.PRIMITIVE_TRIANGLES, _offset(arrays, origin), [], {},
			TerrainTile.CUSTOM0_FLAGS)

	for span in meshes:
		var mi := MeshInstance3D.new()
		mi.name = "CoarseRing_%d" % span
		mi.mesh = meshes[span]
		mi.material_override = material
		# Far ground does not cast: the shadow of a hill 300 m away lands on
		# ground nobody can see, and the ground bakes its own sun shadow.
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)
		_rings += 1


func triangle_count() -> int:
	return _tris


func block_count() -> int:
	return _blocks


func ring_count() -> int:
	return _rings


## Blocks are baked in their own tile-local space, so a merged ring has to
## move each one to where it belongs.
static func _offset(arrays: Array, origin: Vector3) -> Array:
	var out := arrays.duplicate(true)
	var verts: PackedVector3Array = out[Mesh.ARRAY_VERTEX]
	for i in verts.size():
		verts[i] += origin
	out[Mesh.ARRAY_VERTEX] = verts
	return out
