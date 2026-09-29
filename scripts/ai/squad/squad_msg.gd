class_name SquadMsg
extends RefCounted
## The messages between the layers (Docs/AI.md 2): every downward message has an
## upward reply, and everything is addressed by id -- nothing holds a node across
## a tick.
##
##   Commander --Order-->      Squad --Assignment-->      Brain
##   Commander <--Report--     Squad <--Status--          Brain

enum OrderKind { CLEAR_ROOM, ADVANCE, HOLD, SEARCH, FALL_BACK }
enum ReportKind { ACCEPTED, DONE, FAILED }
## What a member is told to do.
enum Task {
	MOVE,       ## go to `point`; `masked` = only while masked; `crouch` on arrival
	HOLD,       ## stay at `point` facing `yaw`; fire at what shows up
	SUPPRESS,   ## fire at `point` (the threat's cover) from where it stands
	SWEEP,      ## take `point` (a room corner) and sweep `yaw` +- SWEEP_HALF
	FLASH,      ## throw a flashbang to `point`
	BREACH,     ## set a charge at `point` and blow it
}
enum StatusKind { REACHED, BLOCKED, DONE, DOWN }

static var _next_id := 1


static func next_id() -> int:
	_next_id += 1
	return _next_id


class Order:
	var id := 0
	var kind := 0
	## CLEAR_ROOM: the RoomTactics and its opening ({} to make one).
	var room: RoomTactics
	var opening := {}
	## CLEAR_ROOM: its walls' thickness, m, for a door of the squad's own.
	var wall_thick := 0.35
	## CLEAR_ROOM: make a door of its own even when there is one.
	var breach := false
	## ADVANCE / SEARCH / HOLD / FALL_BACK: the point it is about.
	var point := Vector3.ZERO
	var priority := 1

	static func make(p_kind: int) -> Order:
		var o := Order.new()
		o.id = SquadMsg.next_id()
		o.kind = p_kind
		return o


class Report:
	var order_id := 0
	var kind := 0
	var reason := ""
	## Alive members, for the commander's strength count.
	var strength := 0

	func _to_string() -> String:
		return "Report(order %d, %s%s, %d strong)" % [order_id,
				SquadMsg.ReportKind.keys()[kind], (" " + reason) if reason else "", strength]


class Assignment:
	var id := 0
	var task := 0
	var point := Vector3.ZERO
	## Go through here first (an entry point), when set.
	var via := Vector3.INF
	var yaw := 0.0
	var run := false
	var crouch := false
	var masked := false
	## Not before this time (staggered entries).
	var go_at := -INF
	## Given up on after this time.
	var until := INF
	var role := ""

	static func make(p_task: int, p_point: Vector3) -> Assignment:
		var a := Assignment.new()
		a.id = SquadMsg.next_id()
		a.task = p_task
		a.point = p_point
		return a
