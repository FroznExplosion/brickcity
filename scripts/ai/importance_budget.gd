class_name ImportanceBudget
extends RefCounted
## Who is smart (Docs/AI.md 10.2, A2; AIPlan P8, R23).
##
## Every agent gets an IMPORTANCE a couple of times a second: how close it is to a
## player, whether that player is looking at it, whether it is shooting, hurt,
## leading, a mech -- the MAX over the players, so one player standing in the
## fight never starves the other's side of smart agents (R23). The budget is
## filled best first:
##
##   the top SMART_CAP              SMART: the full tree at full rate
##   the next DIRECTED_CAP          DIRECTED: the reduced tree, slower
##   born of the swarm, not smart,  back to a swarm row (SwarmSide.demote): it is
##   and far from every player      nobody's business any more, and nobody sees
##                                  it go
##   beyond, otherwise              DIRECTED still: a soldier is not a row
##
## HYSTERESIS: an agent already smart counts HYSTERESIS times its importance for
## keeping its place, so two agents a hair apart do not swap every tick; and no
## more than PROMOTIONS_PER_TICK are promoted at once (the swarm plan's rule).
##
## An agent is any object with: `tier_hsm` (AgentTier), `budget_pos()`,
## `budget_bonus(now)`, `is_dead()`, and `swarm_born`.

const SMART_CAP := 10
const DIRECTED_CAP := 40
const HZ := 2.0
const HYSTERESIS := 1.25
const PROMOTIONS_PER_TICK := 3
## A swarm-born agent goes back to a row only this far from every player.
const DEMOTE_RANGE := 45.0
## Distance halves an agent's importance every this many metres, roughly.
const FALLOFF := 10.0
## A player looking at it (within this half-angle) counts it this much more.
const SEEN_CONE_DEG := 35.0
const SEEN_MUL := 1.5

var agents: Array = []
## () -> Array: the players' bodies (Pawns; a mech's pilot counts through its pawn).
var players: Array = []
## (agent) -> bool: back to a swarm row. Null: never.
var demote_to_swarm := Callable()
## For gates: counts at the last tick, promotions and demotions so far.
var counts := {"smart": 0, "directed": 0}
var promotions := 0
var demotions := 0
var to_swarm := 0
var last_ms := 0.0
## The last tick's [importance, agent], best first: for gates and the overlay.
var last_scores: Array = []
## Set on each tick; a gate clears it once it has looked.
var ticked := false
## Promotions the last tick held back for PROMOTIONS_PER_TICK.
var deferred_last := 0
var _next := -INF


func add(a: Object) -> void:
	if not agents.has(a):
		agents.append(a)


func remove(a: Object) -> void:
	agents.erase(a)


func importance(a: Object, now: float) -> float:
	var p: Vector3 = a.budget_pos()
	var best := 0.0
	for pl in players:
		if not is_instance_valid(pl):
			continue
		var feet: Vector3 = pl.feet()
		var d := p.distance_to(feet)
		var s := 100.0 / (1.0 + d / FALLOFF)
		var look: Vector3 = -Basis.from_euler(Vector3(pl.intents.look_pitch, pl.intents.look_yaw, 0.0)).z
		var to: Vector3 = p - (pl.eye.global_position as Vector3)
		if to.length() > 0.5 and rad_to_deg(look.angle_to(to.normalized())) <= SEEN_CONE_DEG:
			s *= SEEN_MUL
		best = maxf(best, s)
	return best + float(a.budget_bonus(now))


func tick(now: float) -> void:
	if now < _next:
		return
	_next = now + 1.0 / HZ
	var t0 := Time.get_ticks_usec()
	var live: Array = []
	for a in agents:
		if is_instance_valid(a) and not a.is_dead():
			live.append(a)
	agents = live
	var scored: Array = []
	for a in live:
		var imp := importance(a, now)
		var smart_now: bool = a.tier_hsm.tier() == AgentTier.SMART
		scored.append([imp * (HYSTERESIS if smart_now else 1.0), imp, a])
	scored.sort_custom(func(x, y): return x[0] > y[0])
	var promoted := 0
	var deferred := 0
	var held_back := 0
	var n_smart := 0
	var n_directed := 0
	for i in scored.size():
		var a: Object = scored[i][2]
		var hsm: AgentTier = a.tier_hsm
		if i < SMART_CAP:
			if hsm.tier() != AgentTier.SMART:
				if promoted >= PROMOTIONS_PER_TICK:
					# Its promotion waits; one it would have displaced keeps its
					# place meanwhile, so there are still SMART_CAP smart.
					deferred += 1
					held_back += 1
					n_directed += 1
					continue
				hsm.promote()
				promoted += 1
				promotions += 1
			n_smart += 1
			continue
		if hsm.tier() == AgentTier.SMART:
			if deferred > 0:
				deferred -= 1
				n_smart += 1
				continue
			hsm.demote()
			demotions += 1
		if bool(a.swarm_born) and demote_to_swarm.is_valid() and _far_from_players(a.budget_pos()):
			if demote_to_swarm.call(a):
				to_swarm += 1
				continue
		n_directed += 1
	counts = {"smart": n_smart, "directed": n_directed}
	last_scores = scored.map(func(x): return [x[1], x[2]])
	deferred_last = held_back
	ticked = true
	last_ms = (Time.get_ticks_usec() - t0) / 1000.0


func _far_from_players(p: Vector3) -> bool:
	for pl in players:
		if is_instance_valid(pl) and (pl.feet() as Vector3).distance_to(p) < DEMOTE_RANGE:
			return false
	return true
