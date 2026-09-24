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
## What is deliberately NOT here: anything about islands, debris, transforms or
## velocities. Those are physics state, they are allowed to differ between
## machines, and replicating them is the thing both sources warn against.

enum Kind {
	BLAST,     ## a weapon: destroys brick
	SHEAR,     ## a collision: severs joints in a ball, destroys nothing
	SEVER,     ## a collision: severs joints across a plane
}

## One command. Plain data on purpose -- this has to survive being serialised.
class Entry extends RefCounted:
	var tick := 0
	var kind := Kind.BLAST
	var target := -1        ## building id, or -1 for "whatever is at the point"
	var point := Vector3.ZERO
	var radius := 0.0
	var normal := Vector3.ZERO  ## SEVER only: the plane's normal
	var limit := 0          ## SHEAR only: max blocks, 0 for no cap
	## Position in the host's log, 0-based; -1 until the host commits it. A client
	## applies entries in this order and a gap means one went missing on the way.
	var seq := -1

	func to_array() -> Array:
		return [tick, kind, target, point, radius, normal, limit, seq]

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
		return e


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
	if not recording:
		return null
	var e := Entry.new()
	e.tick = tick
	e.kind = kind
	e.target = target
	e.point = point
	e.radius = radius
	e.normal = normal
	e.limit = limit
	e.seq = entries.size()
	entries.append(e)
	return e


## Apply one command to one chunk. The single definition of what each kind DOES
## to a world -- replay, a client receiving the host's entries and the loopback
## probe all come through here, so they cannot drift apart.
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
	return PackedInt32Array()


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


## Apply the whole log to a world, in recorded order.
##
## `resolve` maps a recorded target id to a live chunk id -- the caller owns
## that, because a replaying client materialises buildings on its own schedule.
## Returns how many commands were applied.
func replay(world: BrickWorld, resolve: Callable) -> int:
	var applied := 0
	for e in entries:
		var chunk: int = resolve.call(e.target)
		if chunk < 0 or not world.is_chunk_alive(chunk):
			continue
		apply_entry(world, chunk, e)
		applied += 1
	return applied
