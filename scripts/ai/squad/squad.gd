class_name Squad
extends Node
## A squad (Docs/AI.md 2, 6.3, AIPlan P6): a few soldiers and the one brain that
## runs their PLAYS. It takes Orders (from the commander, P9 -- today a gate or
## the city's keys) and answers each with Reports; it gives its members
## Assignments and hears back their Status. It runs its own LimboAI tree
## (SquadTree) at TICK_HZ as a TACTICAL job, and its blackboard is the parent of
## every member's: the play and the target live one level up.
##
## MORALE falls with every member lost and every second the squad is pinned
## under fire, and climbs back slowly; broken, the squad falls back (the tree's
## first branch), and it takes a real recovery -- past RALLY -- to stop.

const TICK_HZ := 4.0
const LOSS := 0.35
const PINNED_PER_S := 0.04
const RECOVER_PER_S := 0.03
const BROKEN := 0.3
const RALLY := 0.6

signal reported(report: SquadMsg.Report)

var id := 0
var team := 1
var services: AIServices
var members: Array[Soldier] = []
var brain: BTPlayer
## The order being carried out, or null.
var order: SquadMsg.Order
## Every report sent, for gates and the commander.
var reports: Array[SquadMsg.Report] = []
var morale := 1.0
## Which play's assignments are current (begin_play).
var generation := 0
var broken := false
## What the tree is doing, for overlays and gates.
var play := "idle"
## Room id -> when it was cleared.
var cleared := {}
## When each step of the current play happened ("stacked", "breached", ...),
## for gates and the overlay.
var events := {}
## member index -> {assignment id: [StatusKind, time]}
var _status := {}
var _next := -INF
var _last := -1.0
var _queued := false

static var _next_squad := 1


static func make(s: AIServices, parent: Node, soldiers: Array[Soldier], p_team := 1) -> Squad:
	var q := Squad.new()
	q.id = _next_squad
	_next_squad += 1
	q.name = "Squad%d" % q.id
	q.services = s
	q.team = p_team
	q.brain = BTPlayer.new()
	q.brain.name = "Brain"
	q.brain.update_mode = BTPlayer.MANUAL
	q.brain.behavior_tree = SquadTree.build()
	parent.add_child(q)
	# The hint before it enters the tree: built in code, there is no owner to
	# find the scene root from.
	q.brain.set_scene_root_hint(q)
	q.add_child(q.brain)
	for so in soldiers:
		q.add(so)
	return q


func add(so: Soldier) -> void:
	members.append(so)
	so.squad = self
	so.brain.blackboard.set_parent(brain.blackboard)
	so.pawn.health.died.connect(_on_member_down.bind(so))


func alive() -> Array[Soldier]:
	var out: Array[Soldier] = []
	for m in members:
		if is_instance_valid(m) and not m.is_dead():
			out.append(m)
	return out


func index_of(so: Soldier) -> int:
	return members.find(so)


## The contact the squad fights: its side's best.
func contact() -> FactionKnowledge.Contact:
	return services.knowledge_of(team).best(services.now())


## Where the alive members are, on average.
func center() -> Vector3:
	var a := alive()
	var c := Vector3.ZERO
	for m in a:
		c += m.pawn.feet()
	return c / maxf(a.size(), 1)


# --- orders and reports ------------------------------------------------------------

## Take an order. Answered at once with ACCEPTED; the one it replaces, if any,
## with FAILED(superseded).
func give(o: SquadMsg.Order) -> int:
	if order != null:
		_report(order.id, SquadMsg.ReportKind.FAILED, "superseded")
	order = o
	_report(o.id, SquadMsg.ReportKind.ACCEPTED)
	return o.id


## The order is done, or cannot be: report it and let the members go.
func finish(kind: int, reason := "") -> void:
	if order == null:
		return
	var oid := order.id
	order = null
	clear_assignments()
	_report(oid, kind, reason)


func _report(oid: int, kind: int, reason := "") -> void:
	var r := SquadMsg.Report.new()
	r.order_id = oid
	r.kind = kind
	r.reason = reason
	r.strength = alive().size()
	reports.append(r)
	reported.emit(r)


# --- assignments and status ---------------------------------------------------------

func assign(so: Soldier, a: SquadMsg.Assignment) -> void:
	if so == null or so.is_dead():
		return
	a.generation = generation
	so.set_assignment(a)


## A play starts: its assignments are this generation's.
func begin_play() -> int:
	generation += 1
	return generation


## Let the members go. With `gen`, only from what that play gave them: when the
## tree switches plays the new one starts before the old one exits, and the old
## one clearing everything wiped the new one's orders (a CLEAR_ROOM straight
## after a MOVE stacked nobody).
func clear_assignments(gen := -1) -> void:
	for m in members:
		if is_instance_valid(m) and m.assignment != null \
				and (gen < 0 or m.assignment.generation == gen):
			m.set_assignment(null)


## A member's reply to its assignment.
func on_status(so: Soldier, assignment_id: int, kind: int) -> void:
	var i := index_of(so)
	if i < 0:
		return
	var per: Dictionary = _status.get(i, {})
	per[assignment_id] = [kind, services.now()]
	_status[i] = per


## Has `so` replied `kind` to its CURRENT assignment? A dead member counts as
## having replied: a barrier does not wait on the dead.
##
## Untyped on purpose: a play may still hold a member whose node has been freed
## since it died, and a typed parameter refuses the freed object before this can
## say so. Freed counts as dead: nothing more to wait for.
func replied(so, kind: int) -> bool:
	if not is_instance_valid(so) or so.is_dead():
		return true
	if so.assignment == null:
		return false
	var per: Dictionary = _status.get(index_of(so), {})
	var st: Array = per.get(so.assignment.id, [])
	return not st.is_empty() and (st[0] == kind or (kind == SquadMsg.StatusKind.REACHED
			and st[0] == SquadMsg.StatusKind.DONE))


## Every alive member has replied `kind` (the reply barrier of AI.md 6.2).
func all_replied(kind: int, who: Array[Soldier] = []) -> bool:
	for m in (who if not who.is_empty() else alive()):
		if not replied(m, kind):
			return false
	return true


## A member says something, for the squad (Callouts' rate limits apply).
func say(so: Soldier, key: String, text: String, urgent := false) -> void:
	if so == null or not is_instance_valid(so) or so.is_dead():
		var a := alive()
		if a.is_empty():
			return
		so = a[0]
	services.callouts.say(id, so.pawn, key, text, services.now(), urgent)


# --- the tick ------------------------------------------------------------------------

func _physics_process(_delta: float) -> void:
	var now := services.now()
	if now >= _next and not _queued:
		_queued = true
		services.sched.submit(AIScheduler.TACTICAL, 6.0, _think)


func _think() -> void:
	_queued = false
	var now := services.now()
	_next = now + 1.0 / (TICK_HZ * services.sched.rate_scale(AIScheduler.TACTICAL))
	var dt := now - _last if _last >= 0.0 else 1.0 / TICK_HZ
	_last = now
	_morale(dt)
	if alive().is_empty():
		if order != null:
			finish(SquadMsg.ReportKind.FAILED, "wiped out")
		play = "wiped out"
		return
	brain.update(dt)


func _morale(dt: float) -> void:
	var pinned := 0
	for m in alive():
		if services.is_suppressed(m.pawn):
			pinned += 1
	if pinned > 0:
		morale -= PINNED_PER_S * pinned * dt
	elif not _enemy_in_sight():
		# Nerve comes back out of the enemy's sight, not while it stands there
		# watching: a broken squad recovered in its face in twelve seconds.
		morale += RECOVER_PER_S * dt
	morale = clampf(morale, 0.0, 1.0)
	if not broken and morale < BROKEN:
		broken = true
	elif broken and morale > RALLY:
		broken = false


func _enemy_in_sight() -> bool:
	var c := contact()
	return c != null and c.visible


func _on_member_down(so: Soldier) -> void:
	morale = maxf(0.0, morale - LOSS)
	# Half the squad gone breaks it, whatever the running number says: two
	# losses of four land morale on BROKEN to the last decimal (0.3000...04),
	# and a rule that depends on rounding is not a rule.
	if alive().size() * 2 <= members.size():
		morale = minf(morale, BROKEN - 0.05)
	if morale < BROKEN:
		broken = true
	var a := alive()
	if not a.is_empty():
		services.callouts.say(id, a[0].pawn, "down", "Man down!", services.now(), true)
