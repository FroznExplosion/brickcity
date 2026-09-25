class_name StructureReplayer
extends RefCounted

## Turns a stream of structural commands back into structure. Docs/AIPlan.md P0.
##
## Three things are this, and it is one class so they cannot disagree:
##
##   * a co-op client -- it never decides what breaks, it applies the host's
##     commands in the host's order;
##   * a save being loaded (AreaSnapshot) -- the log replayed into freshly built
##     buildings, then the pieces given their bodies back;
##   * the probes' model of both.
##
## It works on a BrickWorld and nothing else: no bodies, no meshes, no scene.
## Whoever owns those listens to `on_piece` and `on_toppled`.
##
## Pieces are tracked by id (DamageLog.piece_id): the seq of the DETACH or TOPPLE
## that made them. That is the same number on every machine because every
## machine applies those commands in the same order.

var world: BrickWorld
## (building id, frame) -> chunk, or -1 when that building is not here. The
## caller owns materialisation.
var resolve: Callable
## (building id): it toppled; its chunks are pieces now. Stop resolving it.
var on_toppled := Callable()
## (piece id, chunk, owner): a piece has come into being.
var on_piece := Callable()

## piece id -> chunk
var pieces := {}
## piece id -> the building it came from
var owners := {}

var applied := 0
## Commands whose building or piece is not here. A client that skipped a small
## piece its camera deleted sees these; anything else seeing them is a bug.
var missed := 0
## The first few misses, for whoever has to find out why: [kind, target, seq, why].
var miss_log: Array = []
const MISS_LOG_MAX := 24


func _miss(e: DamageLog.Entry, why: String) -> bool:
	missed += 1
	if miss_log.size() < MISS_LOG_MAX:
		miss_log.append([DamageLog.Kind.keys()[e.kind], e.target, e.seq, why])
	return false


func _init(p_world: BrickWorld = null, p_resolve := Callable()) -> void:
	world = p_world
	resolve = p_resolve


func piece_chunk(id: int) -> int:
	var c: int = int(pieces.get(id, -1))
	return c if c >= 0 and world.is_chunk_alive(c) else -1


## Apply one committed command. Returns false if its target was not here.
func apply(e: DamageLog.Entry) -> bool:
	match e.kind:
		DamageLog.Kind.BLAST, DamageLog.Kind.SHEAR, DamageLog.Kind.SEVER, \
				DamageLog.Kind.SOLVE, DamageLog.Kind.CHIP:
			var chunk := _building_chunk(e.target, e.frame)
			if chunk < 0:
				return _miss(e, "no building")
			DamageLog.apply_entry(world, chunk, e)
		DamageLog.Kind.TOPPLE:
			var frame := 0
			var any := false
			while true:
				var chunk := _building_chunk(e.target, frame)
				if chunk < 0:
					break
				world.set_chunk_anchored(chunk, false)
				_add_piece(DamageLog.piece_id(e.seq, frame), chunk, e.target)
				any = true
				frame += 1
			if not any:
				return _miss(e, "no building to topple")
			if on_toppled.is_valid():
				on_toppled.call(e.target)
		DamageLog.Kind.DETACH:
			var from_piece := bool(e.flags & DamageLog.FLAG_FROM_PIECE)
			var source := piece_chunk(e.target) if from_piece \
					else _building_chunk(e.target, e.frame)
			if source < 0:
				return _miss(e, "no source")
			# A building's blocks are named by id; a piece's by local cell, because
			# its ids are renumbered whenever it sleeps (IslandManager.record_detach).
			var ids := e.blocks
			if from_piece:
				ids = PackedInt32Array()
				# Absolute cells, in the building's grid (DamageLog on grid space).
				for p in e.points:
					var id := world.block_at(source, Vector3i(p))
					if id >= 0:
						ids.append(id)
			var cut: Dictionary = world.split_island(source, ids)
			if cut.is_empty():
				var dead := 0
				for id in ids:
					if not world.is_solid(source, world.get_chunk_origin(source)
							+ _cell_of(source, id)):
						dead += 1
				return _miss(e, "split found nothing: %d named, %d found, %d of those not standing, source has %d alive of %d, origin %s" % [
					maxi(e.blocks.size(), e.points.size()), ids.size(), dead,
					world.get_alive_block_count(source), world.get_block_count(source),
					world.get_chunk_origin(source)])
			if e.flags & DamageLog.FLAG_GONE:
				# Cut out, as on the host, and not kept (IslandManager.MAX_MOVING).
				world.release_chunk(int(cut.chunk))
			else:
				_add_piece(DamageLog.piece_id(e.seq), int(cut.chunk), e.owner)
		_:
			var chunk := piece_chunk(e.target)
			if chunk < 0:
				return _miss(e, "no piece" if not pieces.has(e.target) else "piece released")
			DamageLog.apply_entry(world, chunk, e)
	applied += 1
	return true


## Apply a whole log, in order.
func apply_all(entries: Array) -> void:
	for e in entries:
		apply(e as DamageLog.Entry)


const NO_CELL := Vector3i(-99999, -99999, -99999)


## A cell this block actually fills, relative to its chunk's grid origin -- add
## get_chunk_origin for the absolute cell. How a piece's blocks are named, because
## their ids do not survive the piece going to sleep (IslandManager.record_detach).
##
## Not simply the corner of the block's box: a shaped part -- a wedge, a stair
## step -- need not fill its own corner, and a whole flight of stairs coming loose
## is exactly what named every block by an empty cell the first time this ran.
## So the box is walked in a fixed order (y, z, x) and the first cell that holds
## this block is the answer, on every machine alike.
static func block_cell(w: BrickWorld, chunk: int, id: int) -> Vector3i:
	var ticks: Array = w.get_block_ticks(chunk, id)
	if ticks.is_empty():
		return NO_CELL
	var t := BrickWorld.ticks_per_stud()
	var pt := BrickWorld.ticks_per_plate()
	var at: Vector3i = ticks[0]
	var size: Vector3i = ticks[1]
	@warning_ignore("integer_division")
	var lo := Vector3i(at.x / t, at.y / pt, at.z / t)
	@warning_ignore("integer_division")
	var n := Vector3i(maxi(size.x / t, 1), maxi(size.y / pt, 1), maxi(size.z / t, 1))
	var origin := w.get_chunk_origin(chunk)
	for y in n.y:
		for z in n.z:
			for x in n.x:
				var cell := lo + Vector3i(x, y, z)
				if w.block_at(chunk, origin + cell) == id:
					return cell
	return NO_CELL


func _cell_of(chunk: int, id: int) -> Vector3i:
	return block_cell(world, chunk, id)


func _building_chunk(id: int, frame: int) -> int:
	if not resolve.is_valid():
		return -1
	var c: int = int(resolve.call(id, frame))
	return c if c >= 0 and world.is_chunk_alive(c) else -1


func _add_piece(id: int, chunk: int, owner: int) -> void:
	pieces[id] = chunk
	owners[id] = owner
	if on_piece.is_valid():
		on_piece.call(id, chunk, owner)
