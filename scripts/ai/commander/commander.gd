class_name Commander
extends Node
## The commander of one side in one encounter (Docs/AI.md 9, AIPlan P9; Red
## Dawn's CommanderAI). It is not in the fight: it never pathfinds and never
## aims. But it has a body and a radio in the world, if its host gives it an HQ
## (the arena puts an officer and a radio in a building): kill the officer and
## nothing more is decided; destroy the radio and it can call nobody -- no
## reinforcements, and orders only to squads within shouting distance of the
## HQ. Both, and the side has lost its coordination: its points count for 40 %
## less in any fight resolved off-screen (PointsBattle), as Red Dawn's did.
## It decides two things, from what its side knows:
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
## How long a squad asked for may take to arrive before the next is bought.
const WAIT_FOR_SPAWN := 45.0

var services: AIServices
var team := 1
## 0 easy .. 1 hard: the doctrine's base aggression (Red Dawn: 0.3 / 0.6 / 0.9).
var difficulty := 0.6
var budget := 12.0
var profile := ThreatProfile.new()
var doctrine := Doctrine.new()
var desperation := 0.0
var squads: Array[Squad] = []
## (kinds: Array[StringName], arrival: StringName) -> bool: spawn a squad of
## these, arriving on foot or by truck; false if it cannot now. The squad comes
## back through adopt().
var spawner := Callable()
## The host can bring a squad by truck (TransportTruck).
var can_truck := false
## SUPPORT it buys besides squads (Doctrine.support; AIRoster.md RO11): air --
## a flyer or hover craft of the roster -- or a tank. Every SUPPORT_GAP seconds
## it considers one purchase: each kind under its cap comes up at the doctrine's
## weight, and is bought if the points leave SUPPORT_RESERVE over. `support_spawner.call(kind, unit) -> bool` fields it;
## `support_up.call() -> {kind: how many up}` keeps it under SUPPORT_CAP. A host
## that sets neither buys none (a gate counting soldiers).
var support_spawner := Callable()
var support_up := Callable()
const SUPPORT_CAP := {&"air": 3, &"tank": 1}
const SUPPORT_RESERVE := 4.0
const SUPPORT_GAP := 20.0
var _support_at := 0.0
## Support bought: [kind, unit, points].
var support_bought: Array = []
## The FRIENDLY commander's reading of the players (R12, R13: they give it no
## orders): set, its squads support what the players do -- beside them and at
## their fight's flank, never in front of their guns -- instead of hunting the
## enemy on their own (_command_friendly). Null for an enemy commander.
var intent: PlayerIntent
## Squad id -> where it was last sent in support, and why.
var support_to := {}
## A squad still nearer the players' lane than this goes out to the side first.
const OUT_TO_SIDE := 6.0
## Re-sent when where it should be has moved this far.
const SUPPORT_MOVED := 6.0
## How many soldiers may be up at once (the host's cap), and how many are.
var alive_cap := 8
## Where the fight is, when nobody knows where the enemy is (the arena's focus).
var rally := Vector3.INF
## (point) -> {"room": RoomTactics, "opening": ...} or {}: the room a point is in,
## from the host (CityRooms.at in the city). Unset, no room is ever cleared.
var room_at := Callable()
## Rooms given up on: room id -> times a clear of it failed.
var _room_fails := {}
const ROOM_TRIES := 2
## A squad this strong, at least, is sent in to clear a room.
const CLEAR_WITH := 3
## The last few things it decided, newest last, for the HUD and gates.
# A public field, read by the probes and the HUD: the name stays.
@warning_ignore("shadowed_global_identifier")
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
var _force_arrival: StringName = &""
var _last_order_at := {}   # squad id -> time
var _clearing := {}        # CLEAR_ROOM order id -> room id
var rooms_cleared := 0
var _rng := RandomNumberGenerator.new()
## Where its own have died, where the enemy has been seen, how strong it is where
## (SectorGrid): the host asks it which spawn spot is safest.
var sectors := SectorGrid.new()
## Fights nobody is watching, resolved in points (PointsBattle.Front).
var fronts: Array = []
signal front_resolved(front)
## () -> Array[Vector3]: where the players are, for a front to go real-time.
var players_at := Callable()
## The HQ: whether its officer lives and its radio stands, and where it is.
var commander_up := true
var radio_up := true
var hq := Vector3.INF
## Radio down, a squad this near the HQ still hears an order shouted.
const SHOUT_RANGE := 40.0
## The share of its points a side without coordination fights with.
const LEADERLESS := 0.6


## The HQ's officer is dead: nothing more is decided. Squads fight on as they are.
func commander_killed() -> void:
	if not commander_up:
		return
	commander_up = false
	_note("the commander is dead -- no more orders, no more reinforcements")


## The radio is down: nobody can be called, and only squads near the HQ hear orders.
func radio_destroyed() -> void:
	if not radio_up:
		return
	radio_up = false
	_note("the radio is down -- no reinforcements; orders only within %d m of the HQ" % SHOUT_RANGE)


func coordinated() -> bool:
	return commander_up or radio_up


## Open a fight at `where` for PointsBattle to resolve if nobody comes near.
## `ours_attacking`: which of the two is this commander's side.
func open_front(where: Vector3, attacker: float, defender: float, fortified := false,
		ours_attacking := false) -> PointsBattle.Front:
	var f := PointsBattle.Front.new()
	f.where = where
	f.attacker = attacker
	f.defender = defender
	f.fortified = fortified
	f.ours_attacker = ours_attacking
	f.started = services.now() if services != null else 0.0
	fronts.append(f)
	return f


func setup(p_services: AIServices, p_team: int, p_seed := 0x0C0DE) -> void:
	services = p_services
	team = p_team
	_rng.seed = p_seed
	# What worked, across encounters (TacticsTally): the doctrine learns it.
	if services.tally != null:
		doctrine.learn(services.tally.get(&"data"))
		if not doctrine.learned_from.is_empty():
			_note("learnt from the tally: %s" % [doctrine.learned_from])
	doctrine.update(profile, desperation, difficulty)
	# Its side's plane runs are paid for from its budget (AirSupport.RUN_POINTS).
	services.air_of(team).payer = self


## Spend `points` on something its side used (a plane run): out of the budget,
## into what it has fielded.
func pay(points: float, what: String) -> void:
	budget -= points
	note_fielded(points)
	_note("%s (%.1f pts)" % [what, points])


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
func joined(_q: Squad, so: Soldier) -> void:
	_count_in(so)


func _count_in(so: Soldier) -> void:
	var pts := UnitCatalog.points(StringName(so.get_meta(&"unit", &"rifleman")))
	fielded_points += pts
	so.pawn.health.died.connect(_on_lost.bind(pts, so))


func _on_lost(pts: float, so: Soldier) -> void:
	lost_points += pts
	if is_instance_valid(so) and so.pawn != null and is_instance_valid(so.pawn):
		sectors.note_loss(so.pawn.feet(), pts)
	_update_desperation()


func _on_report(r: SquadMsg.Report, q: Squad) -> void:
	if r.kind == SquadMsg.ReportKind.ACCEPTED:
		return
	_note("squad %d: order %s%s" % [q.id, SquadMsg.ReportKind.keys()[r.kind],
			(" (" + r.reason + ")") if r.reason else ""])
	if _clearing.has(r.order_id):
		var rid: int = _clearing[r.order_id]
		_clearing.erase(r.order_id)
		if r.kind == SquadMsg.ReportKind.FAILED:
			_room_fails[rid] = int(_room_fails.get(rid, 0)) + 1
		else:
			rooms_cleared += 1
	# Think again soon: the squad is free.
	_next_think = minf(_next_think, services.now() + 0.25)


## No reinforcement before `t` (the arena's first seconds).
func hold_until(t: float) -> void:
	_hold_until = t


## The next reinforcement now, whatever the timing says (a key, a gate);
## `arrival` forces how it comes (&"foot", &"truck"), empty for the doctrine's.
func force_reinforce(arrival: StringName = &"") -> bool:
	_last_reinforce = -INF
	_force_arrival = arrival
	var ok := _reinforce(true)
	_force_arrival = &""
	return ok


## Something the host fielded for it that is not a soldier (a truck) is lost.
func note_loss(points: float, where: Vector3) -> void:
	lost_points += points
	sectors.note_loss(where, points)
	_update_desperation()


func note_fielded(points: float) -> void:
	fielded_points += points


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
	profile.decay(dt)
	sectors.decay(dt)
	squads = squads.filter(func(q): return is_instance_valid(q) and not q.alive().is_empty())
	# What the map says: where its own stand, where the enemy is in sight.
	var ours := []
	for q in squads:
		for m in q.alive():
			ours.append([m.pawn.feet(), UnitCatalog.points(StringName(m.get_meta(&"unit", &"rifleman")))])
	sectors.set_ours(ours)
	var now := services.now()
	var c := services.knowledge_of(team).best(now)
	if c != null and c.visible:
		sectors.note_threat(c.pos, dt)
	if intent != null:
		intent.observe()
	_step_fronts(now)
	if not commander_up:
		return   # nobody left to decide
	budget = minf(budget + INCOME * dt, BUDGET_CAP)
	_update_desperation()
	doctrine.update(profile, desperation, difficulty)
	services.aggro_of(team).bias["pilot"] = 1.0 + doctrine.pilot_focus
	for q in squads:
		if radio_up or hq == Vector3.INF or q.center().distance_to(hq) <= SHOUT_RANGE:
			_command(q)
	if radio_up:
		_reinforce(false)
		if now >= _support_at:
			_support_at = now + SUPPORT_GAP
			buy_support()


func _step_fronts(now: float) -> void:
	var players: Array = players_at.call() if players_at.is_valid() else []
	for f in fronts:
		var front: PointsBattle.Front = f
		if not front.result.is_empty():
			continue
		if not coordinated() and not front.get_meta(&"leaderless", false):
			# Coordination lost: its side fights with less, from now on.
			front.set_meta(&"leaderless", true)
			if front.ours_attacker:
				front.attacker *= LEADERLESS
			else:
				front.defender *= LEADERLESS
		if front.step(now, players):
			_note("front at %v: %s (%.1f vs %.1f left)" % [front.where, front.result.name,
					front.attacker, front.defender])
			front_resolved.emit(front)


func _update_desperation() -> void:
	desperation = clampf(lost_points / maxf(fielded_points, 1.0), 0.0, 1.0)


## One squad's order, if it needs one.
func _command(q: Squad) -> void:
	if q.broken:
		return   # it falls back on its own (SquadTree's first branch)
	if intent != null:
		_command_friendly(q)
		return
	var now := services.now()
	var c := services.knowledge_of(team).best(now)
	var busy := q.order != null
	if c != null and c.age(now) < FRESH:
		if busy:
			return
		if now - float(_last_order_at.get(q.id, -INF)) < ORDER_GAP:
			return
		# In a room: clear it (AI.md 6.2) -- stack, flash, enter, sweep. The
		# play makes its own door when there is none to walk through.
		if room_at.is_valid() and q.alive().size() >= CLEAR_WITH:
			var r: Dictionary = room_at.call(c.pos)
			# One squad to a room: two stacking on one door jam each other's
			# slots and neither gets in.
			if not r.is_empty() and int(_room_fails.get((r.room as RoomTactics).id, 0)) < ROOM_TRIES \
					and not _clearing.values().has((r.room as RoomTactics).id):
				var oc := SquadMsg.Order.make(SquadMsg.OrderKind.CLEAR_ROOM)
				oc.room = r.room
				oc.opening = r.opening
				oc.wall_thick = TowerRecipe.WALL_THICK * BrickWorld.get_stud_metres()
				_clearing[oc.id] = (r.room as RoomTactics).id
				_give(q, oc, "CLEAR_ROOM %s (%s)" % [r.room.id,
						"through the hole in its wall" if not (r.opening as Dictionary).is_empty()
						else "making a door"])
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


## A friendly squad: where the players' fight is (PlayerIntent.focus), at its
## flank while there is an enemy in hand -- bounding (ADVANCE) -- or beside the
## players on the way (MOVE). Sent again only when that place has moved
## SUPPORT_MOVED, so a squad is not re-ordered every second as a player walks.
func _command_friendly(q: Squad) -> void:
	var now := services.now()
	var f: Array = intent.focus()
	if f[0] == Vector3.INF:
		return
	var slot := maxi(squads.find(q), 0)
	var c := services.knowledge_of(team).best(now)
	var fighting := c != null and c.age(now) < FRESH
	services.lanes[team] = intent.in_lane
	var beside := intent.support_point(f[0], slot)
	var to := intent.flank_of(f[0], slot) if fighting else beside
	if to == Vector3.INF:
		return
	# Out to the side before going in: from behind the players, the straight way
	# to the fight's flank is past them and down their lane.
	var leg := "the flank of" if fighting else "beside"
	# Once going in at the flank, only a member back in the lane itself sends it
	# out again: one drifting a little would have it turn back and forth.
	var was: Dictionary = support_to.get(q.id, {})
	var going_in := str(was.get("leg", "")) == "the flank of"
	var out := PlayerIntent.LANE_CLEAR if going_in else OUT_TO_SIDE
	if fighting and beside != Vector3.INF and _off_lane(q, f[0], going_in) < out:
		to = beside
		leg = "out to the side of"
	if not was.is_empty() and (was.at as Vector3).distance_to(to) < SUPPORT_MOVED \
			and str(was.leg) == leg:
		return
	if now - float(_last_order_at.get(q.id, -INF)) < ORDER_GAP:
		return
	support_to[q.id] = {"at": to, "leg": leg, "why": f[1]}
	# With an enemy in hand a squad bounds (ADVANCE): a file on the march is no
	# play for a fight.
	var o := SquadMsg.Order.make(SquadMsg.OrderKind.ADVANCE if fighting else SquadMsg.OrderKind.MOVE)
	o.point = to
	o.to_point = true
	_give(q, o, "support: %s %s the players' fight, %s" % ["ADVANCE" if fighting else "MOVE", leg, f[1]])


## How far the squad's nearest member is to the side of the line from the
## nearest player to the players' fight: all of it is out, or it is not.
## Members behind the player count too -- from there the straight way in is past
## its gun -- unless `ahead_only`: going in already, only one actually in front
## of the player matters, not the covering half left behind.
func _off_lane(q: Squad, f: Vector3, ahead_only := false) -> float:
	var p := intent.nearest_player(f)
	if p == null:
		return INF
	var u := Vector3(f.x - p.feet().x, 0.0, f.z - p.feet().z)
	if u.length() < 1.0:
		return INF
	u = u.normalized()
	var least := INF
	var length := Vector2(f.x - p.feet().x, f.z - p.feet().z).length()
	for m in q.alive():
		var rel := m.pawn.feet() - p.feet()
		rel.y = 0.0
		var along := rel.dot(u)
		if along < length and (along > 0.0 or not ahead_only):
			least = minf(least, absf(rel.dot(Vector3(-u.z, 0.0, u.x))))
	return least


func _give(q: Squad, o: SquadMsg.Order, why: String) -> void:
	q.give(o)
	_last_order_at[q.id] = services.now()
	var k: String = SquadMsg.OrderKind.keys()[o.kind]
	orders_given[k] = int(orders_given.get(k, 0)) + 1
	_note("squad %d: %s" % [q.id, why])


## Buy and field a squad, if the side is short and can pay. `now_please`: the
## timing does not apply (the budget still does).
func _reinforce(now_please: bool) -> bool:
	# Nobody to decide it, or no radio to call it in.
	if not spawner.is_valid() or not commander_up or not radio_up:
		return false
	var now := services.now()
	# A squad asked for and not yet down -- unless it never came (a truck takes
	# its time on the road). Pressed, it does not wait on the last one.
	if _waiting_spawn and not now_please and now - _last_reinforce < WAIT_FOR_SPAWN:
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
	# How it comes: by truck, if it can pay and the doctrine likes it.
	var arrival: StringName = &"foot"
	var truck := UnitCatalog.points(&"truck")
	if can_truck and bool(UnitCatalog.get_unit(&"truck").built) and budget >= cost + truck \
			and _force_arrival != &"foot" \
			and (_force_arrival == &"truck" or _rng.randf() < doctrine.truck_share):
		arrival = &"truck"
		cost += truck
	# Waiting BEFORE the call: a host that hands the squad back at once
	# (adopt() inside the call) clears it again, and one that does not leaves
	# it set. Set after, it waited on a squad already here.
	_waiting_spawn = true
	if not spawner.call(kinds, arrival):
		_waiting_spawn = false
		return false
	budget -= cost
	_last_reinforce = now
	reinforcements += 1
	_note("reinforce: %s%s (%.1f pts), answering %s" % [", ".join(kinds),
			" by truck" if arrival == &"truck" else "", cost, doctrine.answering])
	return true


## With a reinforcement: support, if the doctrine wants it now and the points
## are there (see support_spawner). `force` buys `force`'s kind whatever the
## draw says, for gates. Returns what it bought, or &"".
func buy_support(force: StringName = &"") -> StringName:
	if not support_spawner.is_valid() or not commander_up or not radio_up:
		return &""
	var up: Dictionary = support_up.call() if support_up.is_valid() else {}
	for kind in doctrine.support:
		if force != &"" and kind != force:
			continue
		if int(up.get(kind, 0)) >= int(SUPPORT_CAP.get(kind, 1)):
			continue
		var unit := support_unit(kind)
		if unit == &"":
			continue
		var cost := UnitCatalog.points(unit)
		if budget < cost + (0.0 if force != &"" else SUPPORT_RESERVE):
			continue
		if force == &"" and _rng.randf() >= float(doctrine.support[kind]):
			continue
		if not support_spawner.call(kind, unit):
			continue
		budget -= cost
		note_fielded(cost)
		support_bought.append([kind, unit, cost])
		_note("support: %s (%.1f pts), answering %s / %s" % [unit, cost, doctrine.answering,
				doctrine.answering_armor])
		return kind
	return &""


## Which unit stands for a kind of support: the tank; for air, one of the
## roster's flyers and hover craft that can be fielded, drawn evenly.
func support_unit(kind: StringName) -> StringName:
	if kind == &"tank":
		return &"tank" if bool(UnitCatalog.get_unit(&"tank").built) else &""
	var r := Roster.shared()
	if r == null:
		return &""
	var air: Array[StringName] = []
	for rid in r.ids():
		var rc := r.recipe(rid)
		if str(rc.get("body", "")) in ["flyer", "hover"] and bool(rc.get("built", false)) and r.fit(rid):
			air.append(StringName(rid))
	air.sort()
	return air[_rng.randi() % air.size()] if not air.is_empty() else &""


## The strength the side wants up, in points: more the more aggressive, and a
## little more as the encounter goes on.
func want_strength() -> float:
	return 3.0 + 5.0 * doctrine.aggression + 0.5 * reinforcements


func _note(what: String) -> void:
	log.append("%5.1f  %s" % [services.now(), what])
	if log.size() > 40:
		log = log.slice(log.size() - 40)
	decided.emit(what)
