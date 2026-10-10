class_name SquadMsg
extends RefCounted
## The messages between the layers (Docs/AI.md 2): every downward message has an
## upward reply, and everything is addressed by id -- nothing holds a node across
## a tick.
##
##   Commander --Order-->      Squad --Assignment-->      Brain
##   Commander <--Report--     Squad <--Status--          Brain

## MOVE: travel to `point` in formation -- the leader paths, the rest follow.
## New kinds go on the END: saved orders and logs carry these as numbers.
enum OrderKind { CLEAR_ROOM, ADVANCE, HOLD, SEARCH, FALL_BACK, MOVE }
enum ReportKind { ACCEPTED, DONE, FAILED }
## What a member is told to do.
enum Task {
	MOVE,       ## go to `point`; `masked` = only while masked; `crouch` on arrival
	HOLD,       ## stay at `point` facing `yaw`; fire at what shows up
	SUPPRESS,   ## fire at `point` (the threat's cover) from where it stands
	SWEEP,      ## take `point` (a room corner) and sweep `yaw` +- SWEEP_HALF
	FLASH,      ## throw a flashbang to `point`
	BREACH,     ## set a charge at `point` and blow it
	FOLLOW,     ## keep to `point` as the squad moves it (a place in a file); no reply
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
	## ADVANCE: bound to `point` itself -- a flank, a place beside the players
	## (the friendly commander) -- still suppressing the enemy, instead of
	## closing on the enemy.
	var to_point := false
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
	## FOLLOW: the leader's trail, crumb by crumb, and how far along it this
	## member's place is. A line a body has already walked: followed without a
	## path search (BTPlayTravel).
	var trail := PackedVector3Array()
	var upto := -1
	## The squad's play generation it was handed out in (Squad.begin_play): a
	## play leaving clears only its own, never the next play's.
	var generation := 0

	static func make(p_task: int, p_point: Vector3) -> Assignment:
		var a := Assignment.new()
		a.id = SquadMsg.next_id()
		a.task = p_task
		a.point = p_point
		return a
