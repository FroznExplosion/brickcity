class_name AIServices
extends RefCounted
## What every agent shares (Docs/AI.md 4.1, 5.1): the view of the city, the paths
## through it, the one budget, what each side knows, and who is there to be seen.
## Built once by whatever owns the fight -- the city, a probe's arena -- and
## handed to every agent. Nothing in here is per agent.

var ai_world: AIWorld
var ai_nav: AINav
var sched: AIScheduler
## The physics space sight rays are cast in.
var world3d: World3D
## Everything that can be seen and shot at: players and agents alike.
var pawns: Array[Pawn] = []
## What a gun does to structure (StructuralDamage's shot): the city routes it
## through the WorldAuthority, an arena straight into the bricks.
var on_structure_hit := Callable()
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
var _knowledge := {}


## Simulation time in seconds, from the physics tick -- never the wall clock, so
## a run is the same run however fast the machine is.
func now() -> float:
	return float(Engine.get_physics_frames()) / float(Engine.physics_ticks_per_second)


func knowledge_of(team: int) -> FactionKnowledge:
	if not _knowledge.has(team):
		_knowledge[team] = FactionKnowledge.new()
	return _knowledge[team]


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


## A gunshot, an explosion, a collapse: everyone within `radius` of `point` on
## another side hears where it came from -- not who.
func noise(point: Vector3, radius: float, source: Pawn) -> void:
	for p in pawns:
		if not is_instance_valid(p) or p == source or (source != null and p.team == source.team):
			continue
		if p.feet().distance_to(point) <= radius:
			knowledge_of(p.team).heard(source, point, now())
