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
## Pieces asleep when the save was taken are saved as their records, archetypes
## by name (ChunkRecord.to_data), and come back asleep.
##
## What this does NOT restore, deliberately: furniture riding a piece (each
## machine's own, never in the log -- IslandManager.record_detach), small debris
## too insignificant to have been recorded, and anything a budgeted queue had not
## got to yet -- the caller flushes those before capturing. See
## Docs/AI.md section 12.3.

## DamageLog.to_data() of the whole area.
var commands: Array = []
## [{id, owner, xform (the chunk's), linear, angular, at_rest, disposable}]
var pieces: Array = []
## [{id, owner, record (ChunkRecord.to_data)}]
var dormant: Array = []

const VERSION := 1


## Take a snapshot of `history` and of every recorded piece `islands` holds.
static func capture(history: DamageLog, islands: IslandManager) -> AreaSnapshot:
	var s := AreaSnapshot.new()
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
	for d in islands.dormant:
		if d.piece_id < 0:
			continue
		s.dormant.append({"id": d.piece_id, "owner": d.owner,
				"record": d.record.to_data(islands.world)})
	return s


func to_bytes() -> PackedByteArray:
	return var_to_bytes({"version": VERSION, "commands": commands, "pieces": pieces,
			"dormant": dormant})


static func from_bytes(bytes: PackedByteArray) -> AreaSnapshot:
	var d: Variant = bytes_to_var(bytes)
	if typeof(d) != TYPE_DICTIONARY or int((d as Dictionary).get("version", 0)) != VERSION:
		return null
	var s := AreaSnapshot.new()
	s.commands = d.commands
	s.pieces = d.pieces
	s.dormant = d.dormant
	return s


## Build the area back. The world must hold the area's buildings as recipes, not
## yet damaged; `resolve(building id, frame) -> chunk` materialises one, and
## `on_toppled(building id)` is told when one came down whole, so the caller
## stops treating it as a building.
##
## Returns what happened: {commands, missed, pieces, pieces_missing, dormant,
## dormant_failed, released}.
func restore(world: BrickWorld, resolve: Callable, islands: IslandManager,
		on_toppled := Callable()) -> Dictionary:
	var history := DamageLog.from_data(commands)
	var rep := StructureReplayer.new(world, resolve)
	rep.on_toppled = on_toppled
	rep.apply_all(history.entries)

	var kept := {}
	var missing := 0
	for p in pieces:
		var id := int(p.id)
		var chunk := rep.piece_chunk(id)
		if chunk < 0:
			missing += 1
			continue
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

	return {"commands": history.size(), "missed": rep.missed, "pieces": kept.size(),
			"pieces_missing": missing, "dormant": slept, "dormant_failed": failed,
			"released": released}
