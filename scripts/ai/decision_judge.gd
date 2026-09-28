class_name DecisionJudge
extends RefCounted
## Was that a good call or a stupid one? (CombatPolicy)
##
## Every engage decision opens an EPISODE that runs until the soldier decides
## again, dies, or leaves the fight. While it runs the judge watches what the
## soldier does and what happens to it; when it closes, the episode is scored
## two ways, because they answer different questions:
##
##   REWARD -- what came of it, in hit points: damage dealt, minus damage taken,
##     minus DEATH for dying, minus a little for every second wasted (stuck, or
##     reloading where it could be seen). Nobody's opinion: it is what happened,
##     and it is what a reinforcement-learned policy is trained on. It is noisy
##     one decision at a time -- a good call can end badly, a bad one get lucky
##     -- and only means something averaged over many (summary()).
##
##   FLAGS -- a designer's checklist, judged on what the soldier KNEW when it
##     chose (the observation) and what it then did. A BLUNDER is stupid
##     whatever the dice said: reloading in the open with cover to hand,
##     standing still under fire, holding fire with the enemy point blank. A
##     GOOD flag is a play worth copying. Blunders are what to filter out of
##     imitation data, and what points at the rule to retune.
##
## The scoring is a pure function of the episode (score()), so it is tested on
## made-up episodes (tools/combat_policy_probe.gd) as well as live ones.

## What dying costs, in hit points -- more than any exchange of fire earns.
const DEATH := 60.0
## Per second of each waste.
const STUCK_COST := 2.0
const EXPOSED_RELOAD_COST := 4.0
## Blunder thresholds, seconds.
const EXPOSED_RELOAD_S := 0.8
const HELD_FIRE_S := 1.5
const POINT_BLANK := 12.0
const STUCK_S := 4.0
const DANGER_S := 0.5
const STILL_UNDER_FIRE_S := 2.0

## The blunders, and the good plays.
const BLUNDERS := ["reloaded_exposed", "held_fire_point_blank", "pushed_hurt_or_alone",
		"stood_in_open_under_fire", "stuck", "stood_in_danger", "died_reloading_in_open"]
const GOOD := ["kill", "flank_paid_off", "reloaded_in_cover", "traded_up"]

## Closed episodes, the newest KEPT.
var episodes: Array[Dictionary] = []
const KEPT := 4000
var _open := {}   # soldier instance id -> episode
## While paused nothing is judged, and what was open is dropped unscored: a
## test that blows a building down or kills a wave by hand is not the
## soldiers' doing, and scoring it as their decisions skews every mean.
var paused := false
var dropped := 0


func pause() -> void:
	paused = true
	dropped += _open.size()
	_open.clear()


func resume() -> void:
	paused = false


## A decision was taken: close the soldier's last episode and open the next.
func open(so: Soldier, obs: PackedFloat32Array, tactic: int, decision: Dictionary) -> void:
	if paused:
		return
	close(so, "decided again")
	var c := so.contact()
	_open[so.get_instance_id()] = {
		"tactic": tactic, "obs": obs, "decision": decision,
		"t0": so.services.now(), "hp0": so.pawn.health.total_current(), "dealt0": so.dealt,
		"threat_hp0": _threat_hp(c),
		"seconds": 0.0, "stuck_s": 0.0, "danger_s": 0.0, "exposed_reload_s": 0.0,
		"reloaded_in_cover": false, "held_fire_s": 0.0, "still_hit_s": 0.0,
		"reloading_in_open_at_end": false, "kill": false,
	}


## Once a think: what the soldier is doing, against its open episode.
func watch(so: Soldier, dt: float) -> void:
	var ep: Dictionary = _open.get(so.get_instance_id(), {})
	if ep.is_empty():
		return
	var s := so.services
	var now := s.now()
	ep.seconds = float(ep.seconds) + dt
	var c := so.contact()
	if c == null or c.age(now) > 2.5:
		close(so, "left the fight")
		return
	var sees := c != null and c.seen_by.has(so.get_instance_id())
	var g := so.pawn.gun
	var reloading := g != null and g.is_reloading()
	var in_cover := so.state in ["hide", "reload in cover"]
	# Stuck is trying to go somewhere and not going: legs asked to move, body
	# not moving. Not a counter that may be left over from a move given up.
	var v := so.pawn.body.velocity
	if so.pawn.intents.move.length() > 0.1 and Vector2(v.x, v.z).length() < 0.2:
		ep.stuck_s = float(ep.stuck_s) + dt
	if s.ai_world.in_danger(so.pawn.feet() + Vector3.UP * 0.9):
		ep.danger_s = float(ep.danger_s) + dt
	# It can see the enemy, so the enemy can see it.
	if reloading and sees and not in_cover:
		ep.exposed_reload_s = float(ep.exposed_reload_s) + dt
	if reloading and in_cover:
		ep.reloaded_in_cover = true
	ep.reloading_in_open_at_end = reloading and not in_cover
	if sees and c.pos.distance_to(so.pawn.feet()) < POINT_BLANK and g != null \
			and g.ammo > 0 and not reloading and now - so.last_shot_at > 0.5:
		ep.held_fire_s = float(ep.held_fire_s) + dt
	if now - so.hurt_at < 0.5 and so.pawn.body.velocity.length() < 0.3 and not in_cover:
		ep.still_hit_s = float(ep.still_hit_s) + dt
	if c != null and c.pawn != null and is_instance_valid(c.pawn) and c.pawn.health.is_dead():
		ep.kill = so.dealt > float(ep.dealt0)


## The episode ends: `why` is "decided again", "died" or "left the fight".
func close(so: Soldier, why: String) -> Dictionary:
	var id := so.get_instance_id()
	if not _open.has(id):
		return {}
	var ep: Dictionary = _open[id]
	_open.erase(id)
	ep.why = why
	ep.died = why == "died"
	ep.dealt = so.dealt - float(ep.dealt0)
	ep.taken = maxf(float(ep.hp0) - so.pawn.health.total_current(), 0.0) if not ep.died \
			else float(ep.hp0)
	var verdict := score(ep)
	ep.merge(verdict)
	# The decision log carries its outcome: imitation and RL data both.
	var d: Dictionary = ep.decision
	if not d.is_empty():
		d.reward = verdict.reward
		d.flags = verdict.flags
		d.outcome = {"dealt": ep.dealt, "taken": ep.taken, "died": ep.died,
				"seconds": ep.seconds}
	ep.erase("decision")
	episodes.append(ep)
	if episodes.size() > KEPT:
		episodes = episodes.slice(episodes.size() - KEPT)
	return ep


## Reward and flags for a closed episode. Pure: everything it needs is in `ep`.
static func score(ep: Dictionary) -> Dictionary:
	var o: PackedFloat32Array = ep.obs
	var t: int = ep.tactic
	var T := CombatPolicy.Tactic
	var O := CombatPolicy.Obs
	var reward := float(ep.dealt) - float(ep.taken) - (DEATH if bool(ep.died) else 0.0) \
			- float(ep.stuck_s) * STUCK_COST - float(ep.exposed_reload_s) * EXPOSED_RELOAD_COST
	var flags: Array[String] = []
	var had_cover := o[O.HAS_COVER] > 0.5
	if float(ep.exposed_reload_s) > EXPOSED_RELOAD_S and had_cover:
		flags.append("reloaded_exposed")
	if float(ep.held_fire_s) > HELD_FIRE_S:
		flags.append("held_fire_point_blank")
	if (t == T.PUSH or t == T.FLANK) and (o[O.HEALTH] < 0.35 or o[O.ALONE] > 0.5):
		flags.append("pushed_hurt_or_alone")
	if float(ep.still_hit_s) > STILL_UNDER_FIRE_S and had_cover:
		flags.append("stood_in_open_under_fire")
	if float(ep.stuck_s) > STUCK_S:
		flags.append("stuck")
	if float(ep.danger_s) > DANGER_S:
		flags.append("stood_in_danger")
	if bool(ep.died) and bool(ep.reloading_in_open_at_end):
		flags.append("died_reloading_in_open")
	if bool(ep.kill):
		flags.append("kill")
	if t == T.FLANK and float(ep.dealt) > 0.0 and not bool(ep.died):
		flags.append("flank_paid_off")
	if bool(ep.reloaded_in_cover) and float(ep.taken) == 0.0:
		flags.append("reloaded_in_cover")
	if float(ep.dealt) > float(ep.taken) * 2.0 and float(ep.dealt) > 0.0 and not bool(ep.died):
		flags.append("traded_up")
	var blunders := flags.filter(func(f): return f in BLUNDERS)
	return {"reward": reward, "flags": flags, "blunder": not blunders.is_empty(),
			"verdict": "stupid" if not blunders.is_empty()
			else ("good" if not flags.is_empty() or reward > 0.0 else "neutral")}


## Per tactic: {decisions, mean reward, stupid, good} and every flag's count.
func summary() -> Dictionary:
	var by := {}
	var flags := {}
	for ep in episodes:
		var n: String = CombatPolicy.TACTIC_NAMES[int(ep.tactic)]
		if not by.has(n):
			by[n] = {"n": 0, "reward": 0.0, "stupid": 0, "good": 0}
		var b: Dictionary = by[n]
		b.n += 1
		b.reward += float(ep.reward)
		if ep.verdict == "stupid":
			b.stupid += 1
		elif ep.verdict == "good":
			b.good += 1
		for f in ep.flags:
			flags[f] = int(flags.get(f, 0)) + 1
	for n in by:
		by[n].mean = float(by[n].reward) / maxf(float(by[n].n), 1.0)
	return {"tactics": by, "flags": flags, "episodes": episodes.size()}


func _threat_hp(c: FactionKnowledge.Contact) -> float:
	if c == null or c.pawn == null or not is_instance_valid(c.pawn) or c.pawn.health == null:
		return 0.0
	return c.pawn.health.total_current()
