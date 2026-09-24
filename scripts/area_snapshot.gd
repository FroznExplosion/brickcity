class_name AreaSnapshot
extends RefCounted

## An area's destruction, saved. Docs/AIPlan.md P0 step 2; Docs/AI.md A14, A17.
##
## Two halves, because they are two different kinds of thing:
##
##   STRUCTURE  the command log (DamageLog). Replayed into freshly built
##              buildings it reproduces every building and every piece that came
##              off them, brick for brick -- the city's --shot pass checks exactly
##              that. It is the same log a joining co-op client receives.
##   PHYSICS    for each piece that exists: where it is and how it is moving, and
##              whether it is at rest. The log cannot hold that and should not;
##              a save needs it once.
##
## And three things that are neither, carried because a load without them is not
## the situation that was saved:
##
##   FURNITURE  what rides each piece: a spilled room, a toppled building's
##              contents. Never in the log -- which rooms are open is each
##              machine's own, so furniture is too (IslandManager.record_detach) --
##              but it is in the save, by absolute cell and part name.
##   PENDING    decisions queued and not made yet: a landing waiting to break a
##              piece, a piece waiting to be re-solved. The island manager's own
##              (pending_state), re-queued on load.
##   SCENE      the caller's own queue, opaque here: blasts not applied yet,
##              buildings waiting for their solve. Handed back by restore() for the
##              caller to queue again.
##
## Pieces asleep when the save was taken are saved as their records, archetypes
## by name (ChunkRecord.to_data), and come back asleep.
##
## Small debris is not restored: it is presentation, deleted within moments on
## any machine (IslandManager's class notes), and a load is the one time nobody is
## watching it fall.

## DamageLog.to_data() of the whole area.
var commands: Array = []
## [{id, owner, xform (the chunk's), linear, angular, at_rest, disposable}]
var pieces: Array = []
## [{id, owner, record (ChunkRecord.to_data)}]
var dormant: Array = []
## piece id -> [[absolute cell, part name, colour], ...]
var furniture := {}
## IslandManager.pending_state()
var pending := {}
## Whatever the caller passed to capture(); restore() hands it back.
var scene := {}

const VERSION := 2


## Take a snapshot of `history`, of every recorded piece `islands` holds and of
## what `islands` has queued. `scene_pending` is the caller's own queue.
static func capture(history: DamageLog, islands: IslandManager,
		scene_pending := {}) -> AreaSnapshot:
	var s := AreaSnapshot.new()
	var w := islands.world
	s.commands = history.to_data()
	for isl in islands.islands:
		# A piece nothing recorded -- furniture that fell on its own -- is not
		# in the log, so there is nothing to replay it from. It is presentation.
		if not isl.is_valid() or isl.piece_id < 0:
			continue
		s.pieces.append({
			"id": isl.piece_id,
			"owner": isl.owner,
			"xform": isl.chunk_transform(),
			"linear": isl.body.linear_velocity,
			"angular": isl.body.angular_velocity,
			"at_rest": isl.settled,
			"disposable": isl.disposable,
		})
		var riding := furniture_of(w, isl.chunk)
		if not riding.is_empty():
			s.furniture[isl.piece_id] = riding
	for d in islands.dormant:
		if d.piece_id < 0:
			continue
		s.dormant.append({"id": d.piece_id, "owner": d.owner,
				"record": d.record.to_data(w)})
	s.pending = islands.pending_state()
	s.scene = scene_pending
	return s


## The furniture in a chunk, as what place_block needs to lay it again: the
## block's absolute cell (its corner, in the building's grid -- see DamageLog on
## grid space), its part by NAME (part numbers are per session) and its colour.
static func furniture_of(w: BrickWorld, chunk: int) -> Array:
	var out := []
	var origin := w.get_chunk_origin(chunk)
	var t := BrickWorld.ticks_per_stud()
	var pt := BrickWorld.ticks_per_plate()
	for id in w.get_decorative_blocks(chunk):
		var ticks: Array = w.get_block_ticks(chunk, id)
		if ticks.is_empty():
			continue
		var at: Vector3i = ticks[0]
		@warning_ignore("integer_division")
		var cell := origin + Vector3i(at.x / t, at.y / pt, at.z / t)
		out.append([cell, w.get_archetype_name(w.get_block_archetype(chunk, id)),
				w.get_block_colour(chunk, id)])
	return out


func to_bytes() -> PackedByteArray:
	return var_to_bytes({"version": VERSION, "commands": commands, "pieces": pieces,
			"dormant": dormant, "furniture": furniture, "pending": pending, "scene": scene})


## Version 1 saves -- no furniture, nothing pending -- still load.
static func from_bytes(bytes: PackedByteArray) -> AreaSnapshot:
	var d: Variant = bytes_to_var(bytes)
	if typeof(d) != TYPE_DICTIONARY:
		return null
	var version := int((d as Dictionary).get("version", 0))
	if version < 1 or version > VERSION:
		return null
	var s := AreaSnapshot.new()
	s.commands = d.commands
	s.pieces = d.pieces
	s.dormant = d.dormant
	s.furniture = (d as Dictionary).get("furniture", {})
	s.pending = (d as Dictionary).get("pending", {})
	s.scene = (d as Dictionary).get("scene", {})
	return s


## Build the area back. The world must hold the area's buildings as recipes, not
## yet damaged; `resolve(building id, frame) -> chunk` materialises one, and
## `on_toppled(building id)` is told when one came down whole, so the caller
## stops treating it as a building.
##
## Returns what happened: {commands, missed, pieces, pieces_missing, dormant,
## dormant_failed, released, furniture, furniture_failed, pending, scene}. `scene`
## is what the caller passed to capture(): its own queue, to queue again.
func restore(world: BrickWorld, resolve: Callable, islands: IslandManager,
		on_toppled := Callable()) -> Dictionary:
	var history := DamageLog.from_data(commands)
	var rep := StructureReplayer.new(world, resolve)
	rep.on_toppled = on_toppled
	rep.apply_all(history.entries)

	var parts := {}
	for a in world.get_archetype_count():
		parts[world.get_archetype_name(a)] = a

	var kept := {}
	var missing := 0
	var laid := 0
	var refused := 0
	for p in pieces:
		var id := int(p.id)
		var chunk := rep.piece_chunk(id)
		if chunk < 0:
			missing += 1
			continue
		# Furniture first: it goes in as decorative blocks, which leave the
		# piece's structure -- and so the shapes and mesh built next -- alone.
		for f in furniture.get(id, []):
			var part: int = int(parts.get(str(f[1]), -1))
			if part >= 0 and world.place_block(chunk, f[0], part, int(f[2]), true) >= 0:
				laid += 1
			else:
				refused += 1
		if islands.restore_piece(chunk, id, int(p.owner), p.xform, p.linear, p.angular,
				bool(p.at_rest), bool(p.disposable)) != null:
			kept[id] = true
		else:
			missing += 1

	var slept := 0
	var failed := 0
	for d in dormant:
		var id := int(d.id)
		var record := ChunkRecord.from_data(world, d.record)
		if record == null:
			failed += 1
			continue
		islands.restore_dormant(record, id, int(d.owner))
		slept += 1

	# Everything else the replay made was deleted, swept up or put to sleep on
	# the machine that took the save; a sleeping one is back as its record
	# above. None of it may stay in the world as an invisible, bodiless chunk.
	var released := 0
	for id in rep.pieces:
		if kept.has(int(id)):
			continue
		var c := rep.piece_chunk(int(id))
		if c >= 0:
			world.release_chunk(c)
			released += 1

	# Last, once every piece it names is back.
	var queued := islands.restore_pending(pending)

	return {"commands": history.size(), "missed": rep.missed, "pieces": kept.size(),
			"pieces_missing": missing, "dormant": slept, "dormant_failed": failed,
			"released": released, "furniture": laid, "furniture_failed": refused,
			"pending": queued, "scene": scene}
