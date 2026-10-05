@tool
class_name BTPlayClearRoom
extends BTAction
## Clear a room (Docs/AI.md 6.2):
##
##   STACK   either side of the opening; the play waits on every member's REACHED
##           -- the reply barrier string orders could not give;
##   BREACH  if the room has no door, or the defender is watching the one it has,
##           a door of the squad's own beside it: a charge set on the thinnest
##           bricks the defender is not covering (mouse-holing);
##   PREP    a flashbang in first;
##   ENTER   crisscross, staggered: the first through crosses to the far corner,
##           the second to the near one on the other side, the rest buttonhook;
##   SWEEP   each takes its corner and sweeps its sector, firing at what shows;
##   CLEAR   when every member has swept and nothing is in sight in the room: the
##           room is marked cleared, called, and the order reported DONE.

## A city tower's way in can be the far side of the building from a squad on
## its upper floors: out, round and up to the door is 40 s in the arena.
const STACK_TIMEOUT := 60.0
## Two stacked this long, the rest are not waited for.
const STRAGGLE := 10.0
var _stacked_from := -1.0
## Members that have been given a spare slot once.
var _retried := {}
const TIMEOUT := 90.0
const FUSE := 1.0
const FLASH_FUSE := 1.2
const FLASH_RADIUS := 5.0
const STAGGER := 0.6
## After the blast, time for the nav to see the hole.
const SETTLE := 0.5

var _phase := ""
var _opening := {}
var _breach := false
var _team: Array[Soldier] = []
var _slots: Array[Vector3] = []
var _started := 0.0
var _at := 0.0
var _flash_point := Vector3.ZERO

## This play's generation (Squad.begin_play).
var _gen := 0


func _enter() -> void:
	_gen = (agent as Squad).begin_play()
	_phase = "plan"
	_team.clear()
	_stacked_from = -1.0
	_retried.clear()


func _tick(_delta: float) -> Status:
	var q := agent as Squad
	var s := q.services
	var now := s.now()
	var o := q.order
	if o == null or o.room == null:
		return FAILURE
	var room := o.room
	q.play = "clear room: " + _phase
	blackboard.set_var(&"play", q.play)
	if _phase != "plan" and now - _started > TIMEOUT:
		q.finish(SquadMsg.ReportKind.FAILED, "timed out in " + _phase)
		return FAILURE
	match _phase:
		"plan":
			return _plan(q, room, o, now)
		"stack":
			# The dead are freed at once in the arena: out of the team first.
			_team.assign(_team.filter(func(m) -> bool: return is_instance_valid(m) and not m.is_dead()))
			if _team.is_empty():
				q.finish(SquadMsg.ReportKind.FAILED, "nobody left")
				return FAILURE
			# One that cannot reach its slot (BLOCKED) is left out of the entry:
			# it covers from where it is, and the rest go in. Waiting on its
			# REACHED waited out the stack's timeout.
			# First, though, a slot it cannot reach may just be the wrong slot: a
			# spare one (the stack has one per member it planned for) is tried.
			for m in _team.duplicate():
				if not q.replied(m, SquadMsg.StatusKind.BLOCKED) or _retried.has(m.get_instance_id()):
					continue
				var spare := _spare_slot(q)
				if spare >= 0:
					_retried[m.get_instance_id()] = true
					_stack_move(q, m, spare)
			for m in _team.duplicate():
				if not q.replied(m, SquadMsg.StatusKind.BLOCKED):
					continue
				if _team.size() <= 2:
					# Two would be one going in: not a clear. Say so now, not in a
					# minute, so the commander can send it round another way.
					q.finish(SquadMsg.ReportKind.FAILED, "could not stack")
					return FAILURE
				if _team.size() > 2:
					_team.erase(m)
					var hold := SquadMsg.Assignment.make(SquadMsg.Task.HOLD, m.pawn.feet())
					var inn: Vector3 = _opening.inward
					hold.yaw = atan2(-inn.x, -inn.z)
					hold.role = "cover the door"
					q.assign(m, hold)
			# Nor wait on a straggler: two stacked and waiting STRAGGLE seconds,
			# whoever is not there yet covers from where it is.
			var there := _team.filter(func(m: Soldier) -> bool:
				return q.replied(m, SquadMsg.StatusKind.REACHED))
			if there.size() >= 2 and _team.size() > there.size():
				if _stacked_from < 0.0:
					_stacked_from = now
				elif now - _stacked_from > STRAGGLE:
					for m in _team.duplicate():
						if not there.has(m):
							_team.erase(m)
							var cover := SquadMsg.Assignment.make(SquadMsg.Task.HOLD, m.pawn.feet())
							var inw: Vector3 = _opening.inward
							cover.yaw = atan2(-inw.x, -inw.z)
							cover.role = "cover the door"
							q.assign(m, cover)
			if q.all_replied(SquadMsg.StatusKind.REACHED, _team):
				q.events["stacked"] = now
				if _breach:
					_phase = "charge"
					var a := SquadMsg.Assignment.make(SquadMsg.Task.BREACH,
							(_opening.center as Vector3) - (_opening.inward as Vector3)
							* (float(_opening.thick) * 0.5 + 0.35))
					a.role = "breacher"
					q.assign(_lead(), a)
					q.say(_lead(), "charge", "Setting charge.")
				else:
					_prep(q, room, now)
			elif now - _started > STACK_TIMEOUT:
				q.finish(SquadMsg.ReportKind.FAILED, "could not stack")
				return FAILURE
		"charge":
			if q.replied(_lead(), SquadMsg.StatusKind.DONE):
				_phase = "charge_back"
				_stack_move(q, _lead(), 0)
		"charge_back":
			if q.replied(_lead(), SquadMsg.StatusKind.REACHED):
				q.say(_lead(), "breaching", "Breaching!", true)
				_at = now + FUSE
				_phase = "fuse"
		"fuse":
			if now >= _at:
				var at: Vector3 = (_opening.center as Vector3) + Vector3.UP * RoomTactics.BREACH_HEIGHT
				if s.on_breach.is_valid():
					s.on_breach.call(at, RoomTactics.BREACH_RADIUS)
				q.events["breached"] = now
				_at = now + SETTLE
				_phase = "settle"
		"settle":
			if now >= _at:
				_prep(q, room, now)
		"flash":
			var thrower := _thrower()
			if _at < 0.0 and q.replied(thrower, SquadMsg.StatusKind.DONE):
				_at = now + FLASH_FUSE
			if _at >= 0.0 and now >= _at:
				s.flash(_flash_point, FLASH_RADIUS)
				q.events["flashed"] = now
				_enter_room(q, room, now)
		"sweep":
			if q.all_replied(SquadMsg.StatusKind.DONE, _team):
				var c := q.contact()
				if c != null and c.visible and room.contains(c.pos):
					return RUNNING   # still somebody in here: keep at it
				q.cleared[room.id] = now
				q.events["cleared"] = now
				q.say(null, "clear", "Room clear!")
				q.finish(SquadMsg.ReportKind.DONE)
				return SUCCESS
	return RUNNING


func _plan(q: Squad, room: RoomTactics, o: SquadMsg.Order, now: float) -> Status:
	var s := q.services
	_started = now
	q.events.clear()
	_team = q.alive()
	if _team.is_empty():
		q.finish(SquadMsg.ReportKind.FAILED, "nobody left")
		return FAILURE
	# Someone known to be in there, and where they look from.
	var defender_eye := Vector3.INF
	var c := q.contact()
	if c != null and room.contains(c.pos) and c.age(now) < 15.0:
		defender_eye = c.pawn.eye.global_position if c.pawn != null and is_instance_valid(c.pawn) \
				else c.pos + Vector3.UP * CoverSearch.STAND_EYE
	var door := o.opening
	var watched := not door.is_empty() and defender_eye != Vector3.INF \
			and s.ai_world.bricks_between(defender_eye,
				RoomTactics.entry_point(door) + Vector3.UP * 1.1) == 0
	_breach = door.is_empty() or watched or o.breach
	_opening = door
	if _breach:
		var avoid := [door.center] if not door.is_empty() else []
		var hole := room.breach(s, q.center(), avoid, defender_eye, o.wall_thick)
		if not hole.is_empty():
			_opening = hole
		elif door.is_empty():
			q.finish(SquadMsg.ReportKind.FAILED, "no way in")
			return FAILURE
		else:
			_breach = false
	q.events["breach"] = _breach
	q.events["opening"] = _opening.center
	q.events["way_in"] = _opening
	# Stack slots, each to the nearest member still unplaced, nearest slot first.
	_slots = RoomTactics.stack_slots(_opening, _team.size())
	for i in _slots.size():
		_slots[i] = s.ai_nav.snap(_slots[i])
	var left := _team.duplicate()
	_team.clear()
	for slot in _slots:
		var bi := 0
		for k in left.size():
			if left[k].pawn.feet().distance_to(slot) < left[bi].pawn.feet().distance_to(slot):
				bi = k
		_team.append(left[bi])
		left.remove_at(bi)
	for i in _team.size():
		_stack_move(q, _team[i], i)
	if _breach:
		q.say(_team[0], "stack", "No door -- we make one. Stack up.")
	else:
		q.say(_team[0], "stack", "Stack up on the door.")
	_phase = "stack"
	return RUNNING


func _stack_move(q: Squad, so: Soldier, i: int) -> void:
	var a := SquadMsg.Assignment.make(SquadMsg.Task.MOVE, _slots[i])
	a.run = true
	a.crouch = true
	var inn: Vector3 = _opening.inward
	a.yaw = atan2(-inn.x, -inn.z)
	a.role = "stack %d" % i
	q.assign(so, a)


## A stack slot nobody in the team is heading for, or -1.
func _spare_slot(_q: Squad) -> int:
	var taken := {}
	for m in _team:
		if m.assignment != null and m.assignment.task == SquadMsg.Task.MOVE:
			for i in _slots.size():
				if m.assignment.point.distance_to(_slots[i]) < 0.3:
					taken[i] = true
	for i in _slots.size():
		if not taken.has(i):
			return i
	return -1


func _lead() -> Soldier:
	return _team[0]


func _thrower() -> Soldier:
	return _team[1] if _team.size() > 1 else _team[0]


func _prep(q: Squad, room: RoomTactics, _now: float) -> void:
	_phase = "flash"
	_at = -1.0
	_flash_point = room.center() + Vector3.UP * 1.0
	var a := SquadMsg.Assignment.make(SquadMsg.Task.FLASH, _flash_point)
	a.role = "flash"
	q.assign(_thrower(), a)
	q.say(_thrower(), "flash", "Flashbang out!", true)


func _enter_room(q: Squad, room: RoomTactics, now: float) -> void:
	_phase = "sweep"
	q.events["entered"] = now
	var corners := room.crisscross(_opening, _team.size())
	var entry := RoomTactics.entry_point(_opening)
	for i in _team.size():
		var a := SquadMsg.Assignment.make(SquadMsg.Task.SWEEP, q.services.ai_nav.snap(corners[i]))
		a.run = true
		a.yaw = room.sector_yaw(corners[i])
		a.go_at = now + i * STAGGER
		a.role = ["cross far", "cross near", "hook far", "hook near"][i % 4]
		# Through the opening first: a member does not go round to another way in.
		a.via = entry
		q.assign(_team[i], a)
	q.say(_team[0], "go", "Go, go, go!", true)


func _exit() -> void:
	var q := agent as Squad
	if q != null:
		q.clear_assignments(_gen)
