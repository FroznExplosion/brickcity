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

	func to_array() -> Array:
		return [tick, kind, target, point, radius, normal, limit]

	static func from_array(a: Array) -> Entry:
		var e := Entry.new()
		e.tick = int(a[0])
		e.kind = int(a[1]) as Kind
		e.target = int(a[2])
		e.point = a[3]
		e.radius = float(a[4])
		e.normal = a[5]
		e.limit = int(a[6])
		return e


var entries: Array[Entry] = []
## Off by default. Recording costs an allocation per hit, and a single-player
## session that will never save has no use for it.
var recording := false


func record(tick: int, kind: Kind, target: int, point: Vector3, radius: float,
		normal := Vector3.ZERO, limit := 0) -> void:
	if not recording:
		return
	var e := Entry.new()
	e.tick = tick
	e.kind = kind
	e.target = target
	e.point = point
	e.radius = radius
	e.normal = normal
	e.limit = limit
	entries.append(e)


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
		match e.kind:
			Kind.BLAST:
				world.apply_hit(chunk, e.point, e.radius)
			Kind.SHEAR:
				# peel, matching every site that records a SHEAR -- a replay that
				# sheared differently would not reproduce the world.
				world.separate_near(chunk, e.point, e.radius, e.limit, true)
			Kind.SEVER:
				world.separate_plane(chunk, e.point, e.normal, e.radius)
		applied += 1
	return applied
