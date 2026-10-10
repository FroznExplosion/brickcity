class_name AIServices
extends RefCounted
## What every agent shares (Docs/AI.md 4.1, 5.1): the view of the city, the paths
## through it, the one budget, what each side knows, and who is there to be seen.
## Built once by whatever owns the fight -- the city, a probe's arena -- and
## handed to every agent. Nothing in here is per agent.
##
## Since P6 it also keeps what is shared about the FIGHT: whose rounds are landing
## round whom (suppression, which masks a squad's moves), who may shoot at whom
## (attack tokens), each enemy side's attention (aggro) and what is being said
## (callouts). The owner calls tick() once a physics tick, after the scheduler.

## The players' side. Aggro is kept on it, by the other sides.
const PLAYER_SIDE := 0
## A round passing within this of a body suppresses it, for SUPPRESS_HOLD seconds.
const SUPPRESS_NEAR := 1.6
const SUPPRESS_HOLD := 0.8
## At most this many agents shoot one target at once (AI.md 5.1). A token lapses
## when not renewed for TOKEN_HOLD seconds.
const TOKENS := 2
const TOKEN_HOLD := 0.6
## How often aggro's seen/near gains and its fade are applied.
const AGGRO_HZ := 5.0

## A flashbang went off: where, how big, when. (Its effect on a player's view is
## the owner's to draw.)
signal flashed(point: Vector3, radius: float)

var ai_world: AIWorld
var ai_nav: AINav
var sched: AIScheduler
## The physics space sight rays are cast in.
var world3d: World3D
## The weather (Docs/Collapse.md 4.4): true while the sky is dangerous -- a
## lightning storm, a meteor shower, a tornado -- and a soldier with nothing to
## fight gets under a roof (BTShelter).
var storm := false
## What the weather does to eyes and hands (Docs/Collapse.md 4.4), set by the
## disaster that is running: SIGHT_MUL scales how far a soldier sees (a little:
## rain and dust do not blind anybody at fifty metres), AIM_MUL scales its
## error cone (a lot: wind, rain in the eyes and the ground moving are what
## spoil a shot).
var sight_mul := 1.0
var aim_mul := 1.0
## Everything that can be seen and shot at: players and agents alike.
var pawns: Array[Pawn] = []
## What a gun does to structure (StructuralDamage's shot): the city routes it
## through the WorldAuthority, an arena straight into the bricks.
var on_structure_hit := Callable()
## A breaching charge (mouse-holing, AI.md 6.2): (point, radius) -> void. The
## city commits a BLAST through the authority; an arena blasts its bricks.
var on_breach := Callable()
## Combat's seeded RNG (D9). Agents draw their own streams from it.
var rng := RandomNumberGenerator.new()
## The engage decision, shared by every soldier (CombatPolicy.create).
var policy: CombatPolicy = CombatPolicy.from_args()
const NAV_SIZE_USEC := 200
## A navigation map per SIZE of body (Roster's sizes, AIRoster.md 2.2): "person"
## is `ai_nav`; the others are made the first time a body of that size asks, with
## that size's numbers, and kept. The owner may put its own in (the city's mech
## map is "huge").
var navs := {}
## Counts of what the casebook chose, by moment (TacticsTally), when whoever
## owns the fight keeps them: the city does, a probe's arena does not. Untyped,
## so the services do not depend on the book's scripts.
var tally: RefCounted
## Every engage decision taken, for imitation data (CombatPolicy): {t, who,
## obs, tactic, policy}. The newest DECISIONS_KEPT.
var decisions: Array[Dictionary] = []
## What came of each one, and whether it was a stupid call (DecisionJudge).
## Null turns judging off.
var judge: DecisionJudge = DecisionJudge.new()
const DECISIONS_KEPT := 4000
## What agents say (Docs/AI.md 6.5): (speaker: Pawn, key, text, range) -> void.
## Whoever shows lines to a player sets it; nothing is said with it unset.
var on_say := Callable()
const SHOUT := 35.0
const TALK := 15.0
## A soldier with no squad speaks as a squad of one, numbered from here.
const LONE_SQUAD := 1000000
## Lines that jump the queue.
const URGENT_LINES := ["man_down", "stuck", "grenade"]
var callouts := Callouts.new()
## (shooter: Pawn, from: Vector3, to: Vector3, info: Dictionary) -> void, for
## every round any armed pawn fires: what is not a physics body and still stops
## rounds -- the swarm's rows (SwarmSide) -- hears it here.
var round_listeners: Array[Callable] = []
## Every flash: [point, radius, time], for gates.
var flashes: Array = []
var _knowledge := {}
var _air := {}
var _aggro := {}
var _suppressed := {}   # pawn instance id -> time a round last passed close
var _tokens := {}       # target instance id -> {holder instance id: expires}
var _next_aggro := -INF
var _last_aggro := -1.0


## Simulation time in seconds, from the physics tick -- never the wall clock, so
## a run is the same run however fast the machine is.
func now() -> float:
	return float(Engine.get_physics_frames()) / float(Engine.physics_ticks_per_second)


## Flow fields (Docs/AI.md 4.3): one per goal, shared by every agent closing on
## it. Keyed by the goal to FIELD_SNAP metres, so everybody after the same
## contact reads the same field; one nobody has read for FIELD_IDLE seconds goes.
const FIELD_SNAP := 3.0
const FIELD_RADIUS := 45.0
const FIELD_IDLE := 15.0
var _fields := {}   # Vector3i -> [field id, last read]
var fields_built := 0


## Which way to walk from `from` toward `goal`, on the shared field. Zero until
## the field is worked out (a few ticks), or outside it.
func field_dir(goal: Vector3, from: Vector3) -> Vector3:
	var key := Vector3i((goal / FIELD_SNAP).round())
	var t := now()
	var f: Array = _fields.get(key, [])
	if f.is_empty():
		f = [ai_nav.request_field(Vector3(key) * FIELD_SNAP, FIELD_RADIUS, 3.0), t]
		_fields[key] = f
		fields_built += 1
	f[1] = t
	return ai_nav.field_dir(int(f[0]), from)


func _drop_idle_fields(t: float) -> void:
	for key in _fields.keys():
		if t - float(_fields[key][1]) > FIELD_IDLE:
			ai_nav.release_field(int(_fields[key][0]))
			_fields.erase(key)


func field_count() -> int:
	return _fields.size()


## The side's fast planes (AirSupport): a run on call, when it has somewhere to
## put a plane (its `parent`).
func air_of(team: int) -> AirSupport:
	if not _air.has(team):
		_air[team] = AirSupport.new(self, team)
	return _air[team]


func knowledge_of(team: int) -> FactionKnowledge:
	if not _knowledge.has(team):
		var k := FactionKnowledge.new()
		if team != PLAYER_SIDE:
			k.aggro = aggro_of(team)
		_knowledge[team] = k
	return _knowledge[team]


## The side's aggro table over the players' side (AI.md 8).
func aggro_of(team: int) -> AggroTable:
	if not _aggro.has(team):
		_aggro[team] = AggroTable.new()
	return _aggro[team]


## Wildlife is on no side (a negative team): nobody's enemy, and it has none --
## it runs from noise (AnimalPack) rather than fighting.
func hostiles_of(team: int) -> Array[Pawn]:
	var out: Array[Pawn] = []
	if team < 0:
		return out
	for p in pawns:
		if is_instance_valid(p) and p.team != team and p.team >= 0 and p.health != null \
				and not p.health.is_dead():
			out.append(p)
	return out


## A line spoken by `speaker` (AI.md 6.5), heard out to `range_m`: through
## Callouts, under its squad's rate limits -- or, for a soldier with no squad,
## under its own. `on_say` hears every line too, for whoever wants them.
func say(speaker: Pawn, key: String, text: String, range_m: float = TALK) -> void:
	if speaker == null or not is_instance_valid(speaker):
		return
	var so := speaker.body.get_node_or_null(^"Soldier") as Soldier
	var squad_id: int = so.squad.id if so != null and so.squad != null \
			else LONE_SQUAD + int(speaker.get_instance_id() % 1000000)
	callouts.say(squad_id, speaker, key, text, now(), key in URGENT_LINES, range_m)
	if on_say.is_valid():
		on_say.call(speaker, key, text, range_m)


## The map a body of `size` walks: where it fits is the map's to say, so a large
## body is simply not offered a door only a person fits.
func nav_for(size: String) -> AINav:
	if size == "person" or size == "":
		return ai_nav
	if navs.has(size):
		return navs[size]
	var roster := Roster.shared()
	var prof: Array = roster.size_nav(size) if roster != null else []
	if prof.size() < 6:
		return ai_nav
	var n := AINav.new()
	n.set_ai_world(ai_world)
	n.set_agent(int(prof[0]), int(prof[1]), int(prof[2]), int(prof[3]), int(prof[4]), int(prof[5]))
	# What changes the person's map changes this one.
	if ai_nav != null:
		ai_nav.nav_changed.connect(n.invalidate_box)
	navs[size] = n
	return n


## Log a decision; the judge fills in its reward and flags when it closes.
func log_decision(who: Node, obs: PackedFloat32Array, tactic: int) -> Dictionary:
	var d := {"t": now(), "who": who.get_instance_id(), "obs": obs,
			"tactic": tactic, "policy": policy.policy_name()}
	if who is Soldier and not (who as Soldier).book.is_empty():
		d["book"] = (who as Soldier).book.duplicate(true)
	decisions.append(d)
	if decisions.size() > DECISIONS_KEPT:
		decisions = decisions.slice(decisions.size() - DECISIONS_KEPT)
	return d
## A pawn that can be seen and shot at. If it holds a gun, its rounds suppress,
## make noise and earn aggro.
func add_pawn(p: Pawn) -> void:
	if not pawns.has(p):
		pawns.append(p)
	arm(p)


func arm(p: Pawn) -> void:
	if p.gun == null:
		return
	var cb := _on_fired.bind(p)
	if not p.gun.fired.is_connected(cb):
		p.gun.fired.connect(cb)
	if p.team == PLAYER_SIDE:
		for t in _aggro:
			(_aggro[t] as AggroTable).track(p, int(p.get_meta(&"player", 0)),
					String(p.get_meta(&"aggro_kind", "pilot")))


## A gunshot, an explosion, a collapse: everyone within `radius` of `point` on
## another side hears where it came from -- not who.
func noise(point: Vector3, radius: float, source: Pawn) -> void:
	for p in pawns:
		if not is_instance_valid(p) or p == source or (source != null and p.team == source.team):
			continue
		if p.feet().distance_to(point) <= radius:
			knowledge_of(p.team).heard(source, point, now())


## A flashbang at `point`: said by whoever threw it; the owner draws the flash.
func flash(point: Vector3, radius: float) -> void:
	flashes.append([point, radius, now()])
	flashed.emit(point, radius)


# --- suppression --------------------------------------------------------------

## Rounds are landing round `p`: it has been near-missed within SUPPRESS_HOLD.
func is_suppressed(p: Pawn) -> bool:
	return p != null and now() - float(_suppressed.get(p.get_instance_id(), -INF)) <= SUPPRESS_HOLD


func _on_fired(info: Dictionary, shooter: Pawn) -> void:
	if not is_instance_valid(shooter) or shooter.gun == null or shooter.gun.aim == null:
		return
	var t := now()
	var aim := shooter.gun.aim
	var from := aim.global_position
	var to: Vector3 = info.point if info.has("point") else from - aim.global_transform.basis.z * 400.0
	noise(from, 40.0, shooter)
	for cb in round_listeners:
		cb.call(shooter, from, to, info)
	var victim: Pawn = null
	if info.get("collider") is Node:
		victim = (info.collider as Node).get_node_or_null(^"Pawn") as Pawn
	for p in pawns:
		if not is_instance_valid(p) or p.team == shooter.team:
			continue
		var c := p.chest()
		if p == victim or c.distance_to(Geometry3D.get_closest_point_to_segment(c, from, to)) <= SUPPRESS_NEAR:
			_suppressed[p.get_instance_id()] = t
	if shooter.team != PLAYER_SIDE:
		return
	# Aggro: the damage it did to a side, and the noise, to every side in earshot.
	var res = info.get("result")
	if victim != null and victim.team != PLAYER_SIDE and res != null and res.dealt > 0.0:
		aggro_of(victim.team).add(shooter, res.dealt * AggroTable.DAMAGE)
	for team in _aggro:
		(_aggro[team] as AggroTable).add(shooter, AggroTable.FIRE)


# --- attack tokens -------------------------------------------------------------

## May `holder` shoot at `target` now? At most TOKENS hold one target at once; a
## holder keeps its token by asking again before it lapses.
func token(target: Pawn, holder: Object) -> bool:
	var t := now()
	var tid := target.get_instance_id()
	var held: Dictionary = _tokens.get(tid, {})
	for k in held.keys():
		if float(held[k]) < t or not is_instance_id_valid(k):
			held.erase(k)
	var hid := holder.get_instance_id()
	if held.has(hid) or held.size() < TOKENS:
		held[hid] = t + TOKEN_HOLD
		_tokens[tid] = held
		return true
	_tokens[tid] = held
	return false


func release_token(target: Pawn, holder: Object) -> void:
	if target == null:
		return
	var held: Dictionary = _tokens.get(target.get_instance_id(), {})
	held.erase(holder.get_instance_id())


## How many hold `target` now.
func tokens_on(target: Pawn) -> int:
	var t := now()
	var n := 0
	for k in _tokens.get(target.get_instance_id(), {}):
		if float(_tokens[target.get_instance_id()][k]) >= t:
			n += 1
	return n


# --- the tick ------------------------------------------------------------------

func tick() -> void:
	var t := now()
	if Engine.get_physics_frames() % 30 == 0:
		_drop_idle_fields(t)
	if t >= _next_aggro:
		_next_aggro = t + 1.0 / AGGRO_HZ
		var dt := t - _last_aggro if _last_aggro >= 0.0 else 1.0 / AGGRO_HZ
		_last_aggro = t
		for team in _aggro:
			_aggro_tick(team, _aggro[team], dt)
	callouts.tick(t, world3d, ai_world)
	# The maps of the other sizes of body are served here, a little each.
	for size in navs:
		(navs[size] as AINav).service(NAV_SIZE_USEC)


func _aggro_tick(team: int, table: AggroTable, dt: float) -> void:
	var k := knowledge_of(team)
	for p in pawns:
		if not is_instance_valid(p) or p.team != PLAYER_SIDE or p.health == null or p.health.is_dead():
			continue
		var kind := String(p.get_meta(&"aggro_kind", "pilot"))
		table.track(p, int(p.get_meta(&"player", 0)), kind)
		# A rider on one of this side's mechs nobody has noticed yet draws
		# nothing (G5); noticed, it has had its spike (Rodeo).
		if p.has_meta(&"riding"):
			var ridden := p.get_meta(&"riding") as Mech
			if ridden != null and is_instance_valid(ridden) and ridden.team == team \
					and not ridden.rodeo.is_noticed:
				continue
		var c := k.of(p)
		var seen := c != null and c.visible
		# What merely being there is worth: a mech's presence (G1), more with its
		# hatch off (G6); a pilot in sight while a mech holds the focus, little
		# (G4) -- and then a pilot nobody sees, nothing at all, however near.
		# With no mech holding the focus, being near counts seen or not, as it
		# always has: that is what keeps a side on a player who has gone indoors.
		var presence := 1.0
		var behind_mech := false
		if kind == "mech":
			presence = AggroTable.MECH_PRESENCE
			var ml := MechLayers.of(p.body)
			if ml != null and ml.hatch_off and ml.piloted:
				presence *= AggroTable.EXPOSED
		elif table.kind_of(table.focus()) == "mech":
			presence = AggroTable.PILOT_BEHIND_MECH
			behind_mech = true
		if seen:
			table.add(p, AggroTable.SEEN * presence * dt)
		if seen or not behind_mech:
			for a in pawns:
				if is_instance_valid(a) and a.team == team \
						and a.feet().distance_to(p.feet()) <= AggroTable.NEAR_RANGE:
					table.add(p, AggroTable.NEAR * presence * dt)
					break
	table.decay(dt)
