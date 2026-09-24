class_name WorldAuthority
extends RefCounted

## The one door every structural change goes through. Docs/AIPlan.md P0, and
## Docs/AI.md A1: co-op comes first, so the seam goes in before there is anything
## to network rather than after twenty systems each decided for themselves.
##
## The rule it enforces is Docs/Multiplayer.md's: destruction travels as
## COMMANDS, and only the host decides which commands happen.
##
##   host     A local actor asks (request -> true). The caller applies the change
##            to its world and then commits it: the entry is recorded in the log,
##            given its place in the order, and published to every client.
##   client   A local actor asks (request -> false). Nothing is applied here; the
##            request goes to the host. The change arrives later as the host's
##            committed entry and is applied then, in the host's order.
##
## Single-player is a host with no clients, so the game runs exactly one path
## whether or not anybody else is connected. That is the whole point: a code
## path that only runs in co-op is a code path nobody tests.
##
## What does NOT come through here: anything a machine decides from its own
## physics. A collision that shears a building is the host's to decide, because
## two machines' rigid bodies never land in quite the same place (AIPlan R5); the
## caller asks `may_decide()` and a client simply does not.
##
## This knows nothing about transports. "Send to the host" and "deliver to a
## client" are Callables the owner fills in -- a socket, a test harness
## (tools/loopback_probe.gd), or nothing at all.

## A change has been committed (host) or received and applied (client).
signal committed(entry: DamageLog.Entry)

## Every committed command, in the host's order. On a client it is the host's log,
## entry for entry.
var commands := DamageLog.new()
var is_host := true

## Client: how a request reaches the host. Called with the entry's wire form.
var send_to_host := Callable()
## Host: turns a client's request into a local one. Called with the Entry; it
## should do exactly what the game does when a local actor asks, and commit.
var handle_request := Callable()
## Client: applies a committed entry to this machine's world. Called with the
## Entry; returns false if it could not (the target is not here).
var apply_entry := Callable()

var _clients: Array[Callable] = []
## Client: the next `seq` expected from the host.
var _next_seq := 0
## Client: entries that arrived ahead of one still missing, keyed by seq.
var _held := {}

var requests_forwarded := 0
var requests_handled := 0
var entries_applied := 0
var gaps_seen := 0


## Host: deliver every committed entry to this client from now on. Called with
## the entry's wire form, so a real transport and a test see the same thing.
func add_client(deliver: Callable) -> void:
	_clients.append(deliver)


## May this machine decide a structural change on its own evidence -- a
## collision, a stress failure, a landing? Only the host may.
func may_decide() -> bool:
	return is_host


## A local actor wants a change. On the host this returns true and the caller
## applies it and then calls commit(). On a client it is forwarded and returns
## false: the caller must NOT apply it.
func request(kind: DamageLog.Kind, target: int, point: Vector3, radius: float,
		normal := Vector3.ZERO, limit := 0) -> bool:
	if is_host:
		return true
	var e := DamageLog.Entry.new()
	e.kind = kind
	e.target = target
	e.point = point
	e.radius = radius
	e.normal = normal
	e.limit = limit
	requests_forwarded += 1
	if send_to_host.is_valid():
		send_to_host.call(e.to_array())
	return false


## Host: a change has been applied to this world. Record it and publish it.
## Only the host commits; a client's world changes through receive().
func commit(tick: int, kind: DamageLog.Kind, target: int, point: Vector3,
		radius: float, normal := Vector3.ZERO, limit := 0) -> DamageLog.Entry:
	var e := DamageLog.Entry.new()
	e.tick = tick
	e.kind = kind
	e.target = target
	e.point = point
	e.radius = radius
	e.normal = normal
	e.limit = limit
	return commit_entry(e)


## Host: commit an entry that is already built -- the piece commands, a
## detachment's block list, a multi-frame hit's frame.
func commit_entry(e: DamageLog.Entry) -> DamageLog.Entry:
	if not is_host:
		push_error("WorldAuthority: a client tried to commit a structural change")
		return null
	if commands.add(e) == null:
		return null
	var wire := e.to_array()
	for deliver in _clients:
		deliver.call(wire)
	committed.emit(e)
	return e


## Host: a client's request arrived.
func receive_request(wire: Array) -> void:
	if not is_host:
		return
	requests_handled += 1
	if handle_request.is_valid():
		handle_request.call(DamageLog.Entry.from_array(wire))


## Client: a committed entry arrived from the host. Applied strictly in the
## host's order; anything that arrives early waits for the one before it.
func receive(wire: Array) -> void:
	if is_host:
		return
	var e := DamageLog.Entry.from_array(wire)
	if e.seq < _next_seq:
		return  # already have it
	if e.seq > _next_seq:
		gaps_seen += 1
		_held[e.seq] = e
		return
	_apply(e)
	while _held.has(_next_seq):
		var next: DamageLog.Entry = _held[_next_seq]
		_held.erase(_next_seq)
		_apply(next)


## Client: how many committed entries are waiting on an earlier one.
func held_count() -> int:
	return _held.size()


func _apply(e: DamageLog.Entry) -> void:
	if apply_entry.is_valid():
		apply_entry.call(e)
	# The client's log is the host's log, entry for entry, so it can be saved or
	# handed to a later joiner exactly like the host's.
	commands.entries.append(e)
	_next_seq = e.seq + 1
	entries_applied += 1
	committed.emit(e)
