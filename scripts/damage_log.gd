class_name DamageLog
extends RefCounted

## Every structural change, recorded as a replayable command.
##
## This is the shape a networked game needs, built now because it is nearly free
## now and invasive later (Docs/Multiplayer.md §5). Both of the conclusions this
## project's prior art reached -- Red Dawn's and Teardown's -- are that
## destruction travels as **commands**, not as state: what crosses the wire is
## "a hit of this radius landed at this point on that building", and every
## machine applies the same commands in the same order and arrives at the same
## structure.
##
## The same recording is three things at once:
##
##   * the wire format -- one entry is a packet;
##   * the join-in-progress mechanism -- a client that arrives late replays the
##     log into a freshly generated city, which Teardown found beat serialising
##     the modified geometry;
##   * a save file, and a regression test (`tools/replay_probe.gd`) that proves
##     replaying a log reproduces the world it was recorded from.
##
## ## Every operation, not only the weapons
##
## The log used to hold hits and nothing else, on the theory that everything
## downstream of a hit -- the stress solve, what comes loose, what a landing
## breaks -- would follow deterministically on every machine. It does not,
## because WHEN each of those runs is decided by wall-clock budgets, and timing
## changes outcomes: a blast that lands before a piece has detached kills bricks
## that, on another machine, already left on the piece (Docs/AIPlan.md P0 step 4).
## So the host records every structural operation it performs, in the order it
## performs them, and a client -- or a save being loaded -- replays that stream
## exactly. See StructureReplayer.
##
## A PIECE is addressed by the command that created it: `piece_id(seq, frame)` of
## its DETACH or TOPPLE. Pieces are only ever created by those commands and every
## machine applies them in the same order, so the id is the same everywhere --
## unlike a chunk id, which depends on what else that machine allocated, and
## unlike a content hash, which a room's furniture changes (room contents are
## blocks in the building's own chunk, and which rooms are open is decided per
## machine). For the same reason a DETACH lists STRUCTURAL blocks only;
## furniture weighs nothing in a solve and each machine carries its own.
## Piece commands carry GRID coordinates -- metres in the grid the piece's bricks
## were laid in, which split_island copies unchanged into every piece cut from
## it. Not the world: a piece's transform is physics and differs between machines.
## And not chunk-local either: a piece's local frame starts at the corner of the
## group it was cut as, and on the host that group included furniture the replay
## never has, so the two local frames need not agree. BrickWorld.grid_to_world of a
## block's absolute cell is where it is in this space on every machine.
##
## What is still deliberately NOT here: transforms and velocities. Those are
## physics state; replicating them continuously is what both sources warn
## against. A save carries them once, for the pieces that exist (AreaSnapshot).

enum Kind {
	BLAST,        ## a weapon: destroys brick. A building, world space
	SHEAR,        ## a collision: severs joints in a ball, destroys nothing
	SEVER,        ## a collision: severs joints across a plane
	SOLVE,        ## a building's stress solve, run when it found failures
	TOPPLE,       ## a building came off its foundation whole and became a piece
	DETACH,       ## `blocks` left a building (or, with FLAG_FROM_PIECE, a piece)
	PIECE_BLAST,  ## a weapon, on a piece. Grid space
	PIECE_SHEAR,  ## joints severed in a ball on a piece. FLAG_PEEL for a landing
	PIECE_SNAP,   ## a piece snapped across `normal` at `points`
	PIECE_SOLVE,  ## a piece's stress solve, under gravity `normal` (integer)
	## A landmark piece came to rest here: its chunk transform, as `points` [origin,
	## x, y, z]. The one piece of physics the log carries, and only once per rest:
	## the AI hides behind wreckage and people stand on it, so every machine has to
	## have it in the same place (Docs/AI.md section 12.1), and a late joiner or a
	## replay gets it from the same stream as everything else.
	PIECE_REST,
}

## SHEAR / PIECE_SHEAR: sever only the underside of the struck region.
const FLAG_PEEL := 1
## DETACH: the source is piece `target`, not building `target`.
const FLAG_FROM_PIECE := 2
## PIECE_SNAP, informational: no seam ran that way, so a band was torn instead.
## Set by whoever applies it; changes nothing about how it applies.
const FLAG_BANDED := 4

## A piece's id: the seq of the command that created it, and for a toppled
## multi-frame build, which frame. The same on every machine.
static func piece_id(seq: int, frame: int = 0) -> int:
	return seq * 16 + frame

## One command. Plain data on purpose -- this has to survive being serialised.
class Entry extends RefCounted:
	var tick := 0
	var kind := Kind.BLAST
	## A building id; for a piece command, the piece's id (see piece_id).
	var target := -1
	var point := Vector3.ZERO
	var radius := 0.0
	var normal := Vector3.ZERO  ## SEVER / PIECE_SNAP: the axis. PIECE_SOLVE: gravity
	var limit := 0          ## SHEAR kinds: max blocks, 0 for no cap
	## Position in the host's log, 0-based; -1 until the host commits it. A client
	## applies entries in this order and a gap means one went missing on the way.
	var seq := -1
	var frame := 0          ## which frame of a multi-frame build
	var owner := -1         ## piece commands: the building a piece came from
	var flags := 0
	var points := PackedVector3Array()   ## PIECE_SNAP: where it snaps
	var blocks := PackedInt32Array()     ## DETACH: the blocks that left

	func to_array() -> Array:
		return [tick, kind, target, point, radius, normal, limit, seq,
				frame, owner, flags, points, blocks]

	static func from_array(a: Array) -> Entry:
		var e := Entry.new()
		e.tick = int(a[0])
		e.kind = int(a[1]) as Kind
		e.target = int(a[2])
		e.point = a[3]
		e.radius = float(a[4])
		e.normal = a[5]
		e.limit = int(a[6])
		e.seq = int(a[7]) if a.size() > 7 else -1
		if a.size() > 12:
			e.frame = int(a[8])
			e.owner = int(a[9])
			e.flags = int(a[10])
			e.points = a[11]
			e.blocks = a[12]
		return e

	func is_piece() -> bool:
		return kind >= Kind.PIECE_BLAST or (kind == Kind.DETACH and flags & FLAG_FROM_PIECE)


var entries: Array[Entry] = []
## On by default and meant to stay on. It used to be off to save an allocation
## per hit in a session that would never save, but co-op and save-anywhere both
## need it (Docs/AI.md A1, A17), and a log that only exists when somebody
## remembered to switch it on is a log that is missing the hit that mattered.
var recording := true


## Record a command. Returns the entry, with its `seq`, or null when not
## recording.
func record(tick: int, kind: Kind, target: int, point: Vector3, radius: float,
		normal := Vector3.ZERO, limit := 0) -> Entry:
	var e := Entry.new()
	e.tick = tick
	e.kind = kind
	e.target = target
	e.point = point
	e.radius = radius
	e.normal = normal
	e.limit = limit
	return add(e)


## Record a command that is already built. Gives it its place in the order.
func add(e: Entry) -> Entry:
	if not recording:
		return null
	e.seq = entries.size()
	entries.append(e)
	return e


## Apply one command to one chunk. The single definition of what each kind DOES
## to a world -- the host acting, a client receiving, a replay and the probes all
## come through here, so they cannot drift apart.
##
## DETACH and TOPPLE are not here: they create and hand over chunks, which is
## bookkeeping the caller owns (StructureReplayer, IslandManager).
static func apply_entry(world: BrickWorld, chunk: int, e: Entry) -> PackedInt32Array:
	match e.kind:
		Kind.BLAST:
			return world.apply_hit(chunk, e.point, e.radius)
		Kind.SHEAR:
			# peel, matching every site that records a SHEAR -- a replay that
			# sheared differently would not reproduce the world.
			return world.separate_near(chunk, e.point, e.radius, e.limit, true)
		Kind.SEVER:
			return world.separate_plane(chunk, e.point, e.normal, e.radius)
		Kind.SOLVE:
			world.solve_stress(chunk)
			return PackedInt32Array()
		Kind.PIECE_BLAST, Kind.PIECE_SHEAR, Kind.PIECE_SNAP, Kind.PIECE_SOLVE:
			return _apply_local(world, chunk, e)
		Kind.PIECE_REST:
			world.set_chunk_transform(chunk, rest_transform(e))
			return PackedInt32Array()
	return PackedInt32Array()


## A resting transform as PIECE_REST carries it, and back.
static func rest_points(xf: Transform3D) -> PackedVector3Array:
	return PackedVector3Array([xf.origin, xf.basis.x, xf.basis.y, xf.basis.z])


static func rest_transform(e: Entry) -> Transform3D:
	if e.points.size() < 4:
		return Transform3D()
	return Transform3D(Basis(e.points[1], e.points[2], e.points[3]), e.points[0])


## The transform that makes a chunk's local space the grid space piece commands
## are written in: its local origin sits at its grid origin's place in the grid.
static func grid_frame(world: BrickWorld, chunk: int) -> Transform3D:
	return Transform3D(Basis(), BrickWorld.grid_to_world(world.get_chunk_origin(chunk)))


## A piece command, applied in grid space (see the class notes). For the duration
## the chunk's transform is grid_frame, so the host and every client hand the
## extension the SAME numbers -- not the same point expressed through two
## transforms that agree only to the last bit or two.
static func _apply_local(world: BrickWorld, chunk: int, e: Entry) -> PackedInt32Array:
	var saved := world.get_chunk_transform(chunk)
	world.set_chunk_transform(chunk, grid_frame(world, chunk))
	var out := PackedInt32Array()
	match e.kind:
		Kind.PIECE_BLAST:
			out = world.apply_hit(chunk, e.point, e.radius)
		Kind.PIECE_SHEAR:
			out = world.separate_near(chunk, e.point, e.radius, e.limit,
					bool(e.flags & FLAG_PEEL))
		Kind.PIECE_SNAP:
			# A seam first, and a torn band only where there is no seam -- the
			# same order IslandManager._snap_across has always used.
			out = world.sever_seams(chunk, e.points, e.normal)
			if out.is_empty():
				out = world.separate_planes(chunk, e.points, e.normal, e.radius)
				e.flags |= FLAG_BANDED
		Kind.PIECE_SOLVE:
			world.set_chunk_gravity(chunk, Vector3i(
					roundi(e.normal.x), roundi(e.normal.y), roundi(e.normal.z)))
			var res: Dictionary = world.solve_stress(chunk)
			out = PackedInt32Array([int(res.get("failures", 0))])
	world.set_chunk_transform(chunk, saved)
	return out


func clear() -> void:
	entries.clear()


func size() -> int:
	return entries.size()


## Serialise to something a socket or a save file can take.
func to_data() -> Array:
	var out := []
	for e in entries:
		out.append(e.to_array())
	return out


static func from_data(data: Array) -> DamageLog:
	# Not `log`: that is a built-in function.
	var out := DamageLog.new()
	for a in data:
		out.entries.append(Entry.from_array(a))
	return out


## Apply the building commands of a log to a world, in recorded order.
##
## `resolve` maps a recorded target id to a live chunk id -- the caller owns
## that, because a replaying client materialises buildings on its own schedule.
## Piece commands, detachments and topples are skipped: replaying those needs
## StructureReplayer, which keeps track of the pieces. A resolver that takes a
## second argument is also given the frame, for multi-frame builds; one that
## does not is only asked about frame 0. Returns how many commands were applied.
func replay(world: BrickWorld, resolve: Callable) -> int:
	var applied := 0
	var framed := resolve.get_argument_count() >= 2
	for e in entries:
		if e.kind == Kind.DETACH or e.kind == Kind.TOPPLE or e.is_piece():
			continue
		if e.frame != 0 and not framed:
			continue
		var chunk: int = resolve.call(e.target, e.frame) if framed else resolve.call(e.target)
		if chunk < 0 or not world.is_chunk_alive(chunk):
			continue
		apply_entry(world, chunk, e)
		applied += 1
	return applied
