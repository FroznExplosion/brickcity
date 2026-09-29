class_name Commander
extends Node
## The commander of one side in one encounter (Docs/AI.md 9, AIPlan P9; Red
## Dawn's CommanderAI). Not a soldier: nobody sees it and nothing shoots it
## (its radio and a killable commander are later). It never pathfinds and never
## aims. It decides two things, from what its side knows:
##
##   WHAT THE SQUADS DO -- Orders, answered by Reports (SquadMsg). A squad with
##     the enemy in sight is sent to ADVANCE on it (bounding overwatch) as
##     readily as the doctrine's aggression says, or left to fight where it
##     stands; one that has lost it and is far off is sent to MOVE there in
##     file; a broken squad falls back on its own and is left be.
##   WHAT COMES -- reinforcements, bought with points. The budget grows with
##     time; the side wants a strength the doctrine sets, and when it is short
##     and can pay, it draws a squad's roster from the doctrine's weights (only
##     units the game has: UnitCatalog.built) and asks its host to spawn it.
##     The host (WaveDirector in the arena) says where, and gives the squad back.
##
## The doctrine comes from the player's ThreatProfile, the commander's own
## DESPERATION (points lost against points fielded, as Red Dawn's) and the
## difficulty. Event-driven where it can be -- a squad's report, a loss -- and
## otherwise a slow tick, THINK_EVERY.

signal decided(what: String)

const THINK_EVERY := 1.0
## Income, points a second, and what can be banked.
const INCOME := 0.35
const BUDGET_CAP := 30.0
## A squad is this many.
const SQUAD_SIZE := 4
## Seconds between reinforcements, at least.
const REINFORCE_GAP := 8.0
## A contact this old is still a fight; older, and it is a place to go and look.
const FRESH := 8.0
const STALE := 45.0
## Further than this from a stale contact, a squad travels there in file.
const TRAVEL_FAR := 22.0
## A squad nearer its contact than this is not sent to advance on it: an
## advance stops at 12 m (BTPlayAdvance.STOP).
const ADVANCE_FROM := 16.0
## Seconds between orders to one squad, at least.
const ORDER_GAP := 6.0

var services: AIServices
var team := 1
## 0 easy .. 1 hard: the doctrine's base aggression (Red Dawn: 0.3 / 0.6 / 0.9).
var difficulty := 0.6
var budget := 12.0
var profile := ThreatProfile.new()
var doctrine := Doctrine.new()
var desperation := 0.0
var squads: Array[Squad] = []
## (kinds: Array[StringName]) -> bool: spawn a squad of these; false if it
## cannot now. The squad comes back through adopt().
var spawner := Callable()
## How many soldiers may be up at once (the host's cap), and how many are.
var alive_cap := 8
## Where the fight is, when nobody knows where the enemy is (the arena's focus).
var rally := Vector3.INF
## The last few things it decided, newest last, for the HUD and gates.
var log: Array[String] = []
var orders_given := {}   # OrderKind name -> count
var reinforcements := 0
var fielded_points := 0.0
var lost_points := 0.0
var _next_think := 0.0
var _last_think := -1.0
var _last_reinforce := -INF
var _waiting_spawn := false
var _hold_until := -INF
var _last_order_at := {}   # squad id -> time
var _rng := RandomNumberGenerator.new()


func setup(p_services: AIServices, p_team: int, seed := 0x0C0DE) -> void:
	services = p_services
	team = p_team
	_rng.seed = seed
	doctrine.update(profile, desperation, difficulty)


# --- events -----------------------------------------------------------------

## A squad the host has made for it: take command.
func adopt(q: Squad) -> void:
	if squads.has(q):
		return
	squads.append(q)
	_waiting_spawn = false
	q.reported.connect(_on_report.bind(q))
	for m in q.members:
		_count_in(m)
	_note("squad %d fielded (%d)" % [q.id, q.members.size()])


## A member joined a squad after adoption (spawned one by one).
func joined(q: Squad, so: Soldier) -> void:
	_count_in(so)


func _count_in(so: Soldier) -> void:
	var pts := UnitCatalog.points(StringName(so.get_meta(&"unit", &"rifleman")))
	fielded_points += pts
	if not so.pawn.health.died.is_connected(_on_lost):
		so.pawn.health.died.connect(_on_lost.bind(pts))


func _on_lost(pts: float) -> void:
	lost_points += pts
	_update_desperation()


func _on_report(r: SquadMsg.Report, q: Squad) -> void:
	if r.kind == SquadMsg.ReportKind.ACCEPTED:
		return
	_note("squad %d: order %s%s" % [q.id, SquadMsg.ReportKind.keys()[r.kind],
			(" (" + r.reason + ")") if r.reason else ""])
	# Think again soon: the squad is free.
	_next_think = minf(_next_think, services.now() + 0.25)


## No reinforcement before `t` (the arena's first seconds).
func hold_until(t: float) -> void:
	_hold_until = t


## The next reinforcement now, whatever the timing says (a key, a gate).
func force_reinforce() -> bool:
	_last_reinforce = -INF
	return _reinforce(true)


# --- the tick ------------------------------------------------------------------

func _physics_process(_delta: float) -> void:
	if services == null:
		return
	var now := services.now()
	if now < _next_think:
		return
	_next_think = now + THINK_EVERY
	var dt := now - _last_think if _last_think >= 0.0 else THINK_EVERY
	_last_think = now
	think(dt)


func think(dt: float) -> void:
	budget = minf(budget + INCOME * dt, BUDGET_CAP)
	profile.decay(dt)
	_update_desperation()
	doctrine.update(profile, desperation, difficulty)
	squads = squads.filter(func(q): return is_instance_valid(q) and not q.alive().is_empty())
	for q in squads:
		_command(q)
	_reinforce(false)


func _update_desperation() -> void:
	desperation = clampf(lost_points / maxf(fielded_points, 1.0), 0.0, 1.0)


## One squad's order, if it needs one.
func _command(q: Squad) -> void:
	if q.broken:
		return   # it falls back on its own (SquadTree's first branch)
	var now := services.now()
	var c := services.knowledge_of(team).best(now)
	var busy := q.order != null
	if c != null and c.age(now) < FRESH:
		if busy:
			return
		# Already as close as an advance goes (BTPlayAdvance.STOP), or told
		# lately: leave it to fight. Re-ordering a squad that is already there
		# was an order and a DONE every second.
		if q.center().distance_to(c.pos) < ADVANCE_FROM \
				or now - float(_last_order_at.get(q.id, -INF)) < ORDER_GAP:
			return
		# In a fight: advance on it, or leave the squad to fight where it is.
		var strength := float(q.alive().size()) / float(SQUAD_SIZE)
		var go := doctrine.aggression * (0.5 + 0.5 * strength)
		if q.alive().size() >= 2 and _rng.randf() < go * 0.6:
			var o := SquadMsg.Order.make(SquadMsg.OrderKind.ADVANCE)
			o.point = c.pos
			_give(q, o, "ADVANCE on the contact")
		return
	# No fight in hand. Somewhere to go?
	var target := Vector3.INF
	if c != null and c.age(now) < STALE:
		target = c.pos
	elif rally != Vector3.INF:
		target = rally
	if target == Vector3.INF or busy:
		return
	if q.center().distance_to(target) > TRAVEL_FAR:
		var o := SquadMsg.Order.make(SquadMsg.OrderKind.MOVE)
		o.point = target
		_give(q, o, "MOVE in file to %s" % ("the last contact" if target != rally else "the fight"))


func _give(q: Squad, o: SquadMsg.Order, why: String) -> void:
	q.give(o)
	_last_order_at[q.id] = services.now()
	var k: String = SquadMsg.OrderKind.keys()[o.kind]
	orders_given[k] = int(orders_given.get(k, 0)) + 1
	_note("squad %d: %s" % [q.id, why])


## Buy and field a squad, if the side is short and can pay. `now_please`: the
## timing does not apply (the budget still does).
func _reinforce(now_please: bool) -> bool:
	if not spawner.is_valid():
		return false
	var now := services.now()
	# A squad asked for and not yet down -- unless it never came.
	if _waiting_spawn and now - _last_reinforce < 20.0:
		return false
	_waiting_spawn = false
	if not now_please and (now - _last_reinforce < REINFORCE_GAP or now < _hold_until):
		return false
	var up := 0
	var up_points := 0.0
	for q in squads:
		for m in q.alive():
			up += 1
			up_points += UnitCatalog.points(StringName(m.get_meta(&"unit", &"rifleman")))
	if up + SQUAD_SIZE > alive_cap and not (now_please and up == 0):
		return false
	if not now_please and up_points >= want_strength():
		return false
	var kinds := doctrine.draw(SQUAD_SIZE, budget, _rng)
	if kinds.size() < 2:
		return false
	var cost := 0.0
	for k in kinds:
		cost += UnitCatalog.points(k)
	if not spawner.call(kinds):
		return false
	budget -= cost
	_last_reinforce = now
	_waiting_spawn = true
	reinforcements += 1
	_note("reinforce: %s (%.1f pts), answering %s" % [", ".join(kinds), cost, doctrine.answering])
	return true


## The strength the side wants up, in points: more the more aggressive, and a
## little more as the encounter goes on.
func want_strength() -> float:
	return 3.0 + 5.0 * doctrine.aggression + 0.5 * reinforcements


func _note(what: String) -> void:
	log.append("%5.1f  %s" % [services.now(), what])
	if log.size() > 40:
		log = log.slice(log.size() - 40)
	decided.emit(what)
