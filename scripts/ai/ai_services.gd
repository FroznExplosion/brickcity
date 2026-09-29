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
var policy: CombatPolicy = CombatPolicy.create()
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
var callouts := Callouts.new()
## Every flash: [point, radius, time], for gates.
var flashes: Array = []
var _knowledge := {}
var _aggro := {}
var _suppressed := {}   # pawn instance id -> time a round last passed close
var _tokens := {}       # target instance id -> {holder instance id: expires}
var _next_aggro := -INF
var _last_aggro := -1.0


## Simulation time in seconds, from the physics tick -- never the wall clock, so
## a run is the same run however fast the machine is.
func now() -> float:
	return float(Engine.get_physics_frames()) / float(Engine.physics_ticks_per_second)


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


func hostiles_of(team: int) -> Array[Pawn]:
	var out: Array[Pawn] = []
	for p in pawns:
		if is_instance_valid(p) and p.team != team and p.health != null and not p.health.is_dead():
			out.append(p)
	return out


## A line spoken by `speaker` (AI.md 6.5), heard out to `range_m`.
func say(speaker: Pawn, key: String, text: String, range_m: float = TALK) -> void:
	if on_say.is_valid():
		on_say.call(speaker, key, text, range_m)


## Log a decision; the judge fills in its reward and flags when it closes.
func log_decision(who: Node, obs: PackedFloat32Array, tactic: int) -> Dictionary:
	var d := {"t": now(), "who": who.get_instance_id(), "obs": obs,
			"tactic": tactic, "policy": policy.policy_name()}
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
	if t >= _next_aggro:
		_next_aggro = t + 1.0 / AGGRO_HZ
		var dt := t - _last_aggro if _last_aggro >= 0.0 else 1.0 / AGGRO_HZ
		_last_aggro = t
		for team in _aggro:
			_aggro_tick(team, _aggro[team], dt)
	callouts.tick(t, world3d, ai_world)


func _aggro_tick(team: int, table: AggroTable, dt: float) -> void:
	var k := knowledge_of(team)
	for p in pawns:
		if not is_instance_valid(p) or p.team != PLAYER_SIDE or p.health == null or p.health.is_dead():
			continue
		table.track(p, int(p.get_meta(&"player", 0)), String(p.get_meta(&"aggro_kind", "pilot")))
		var c := k.of(p)
		if c != null and c.visible:
			table.add(p, AggroTable.SEEN * dt)
		for a in pawns:
			if is_instance_valid(a) and a.team == team \
					and a.feet().distance_to(p.feet()) <= AggroTable.NEAR_RANGE:
				table.add(p, AggroTable.NEAR * dt)
				break
	table.decay(dt)
