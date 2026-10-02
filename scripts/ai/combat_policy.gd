class_name CombatPolicy
extends RefCounted
## What a soldier does when it comes face to face with an enemy: the one
## decision in the infantry tree that is meant to be LEARNED (Docs/AI.md 11).
##
## The tree keeps everything a designer clamps -- perception, paths, whether a
## line is clear, reaction and accuracy (AI.md 11.2). What it asks a policy is
## narrow: here is the situation as a fixed row of numbers (OBSERVATION); pick
## one of a fixed set of TACTICS. The tree then carries the tactic out, and asks
## again when it is done, when it fails, or when something happens.
##
## So the contract is these two lists, and it is versioned (AI.md 11.3: "models
## declare their contract ... a mismatch refuses to load and the scripted twin
## runs, loudly"). A policy is anything that turns an observation into a tactic:
##
##   ScriptedCombatPolicy  -- now: a scored, weighted-random choice. Its
##                            decisions are logged (AIServices.decisions) as
##                            the imitation data a model is first trained on.
##   an ONNX model         -- later, in its own GDExtension (AI.md 11.3). It has
##                            to accept CONTRACT exactly, or create() refuses it
##                            and hands back the scripted one.
##
## Change an observation or a tactic -- add, remove, reorder, rescale -- and
## SPEC_VERSION goes up. Every value is scaled to about 0..1.

const SPEC_VERSION := 1

enum Obs {
	HAS_COVER,        ## 1 if cover against the threat was found in reach
	COVER_DIST,       ## metres to it / 12, 1 with none
	COVER_LIFE,       ## seconds it lasts against the threat's gun / 10
	IN_COVER,         ## 1 if where it stands is already cover
	AMMO,             ## rounds in the magazine / magazine size
	RELOADING,        ## 1 while reloading
	HEALTH,           ## health / max health
	UNDER_FIRE,       ## 1 if hurt in the last UNDER_FIRE_SECONDS
	THREAT_DIST,      ## metres to the threat / 40, capped at 1
	THREAT_VISIBLE,   ## 1 if the side has it in sight now
	SINCE_SEEN,       ## seconds since the side last saw it / 5, capped at 1
	FRIENDS_SHOOTING, ## allies who fired at it in the last second and a half / 4
	FRIENDS_SEEING,   ## allies with it in sight / 4
	ALONE,            ## 1 if no ally within ALONE_METRES
	COUNT,
}
const OBS_NAMES: Array[String] = ["has_cover", "cover_dist", "cover_life", "in_cover",
		"ammo", "reloading", "health", "under_fire", "threat_dist", "threat_visible",
		"since_seen", "friends_shooting", "friends_seeing", "alone"]

enum Tactic {
	FIGHT_OPEN,    ## stand in the open and shoot, stepping across the line
	TAKE_COVER,    ## into cover, then step out to shoot and back
	COVER_RELOAD,  ## into cover, reload there, then decide again
	PUSH,          ## close in on the threat, firing
	FLANK,         ## go round to its side, firing when it can
	FALL_BACK,     ## to cover further from the threat
	COUNT,
}
const TACTIC_NAMES: Array[String] = ["fight_open", "take_cover", "cover_reload", "push",
		"flank", "fall_back"]

## What a model has to declare to be used in place of the scripted policy.
const CONTRACT := {
	"name": "infantry_engage",
	"version": SPEC_VERSION,
	"observations": OBS_NAMES,
	"actions": TACTIC_NAMES,
}

const UNDER_FIRE_SECONDS := 2.0
const ALONE_METRES := 20.0


## The tactic for this observation. `rng` is the agent's own stream (D9).
func decide(_obs: PackedFloat32Array, _rng: RandomNumberGenerator) -> int:
	return Tactic.TAKE_COVER


## The tactic, given the soldier itself (a policy that reads more of the world
## than the observation, as BookCombatPolicy does). By default, decide().
func decide_in(_so: Soldier, _c: FactionKnowledge.Contact, _cover: Dictionary,
		obs: PackedFloat32Array, rng: RandomNumberGenerator) -> int:
	return decide(obs, rng)


## For logs and overlays.
func policy_name() -> String:
	return "base"


## Does a model's declared contract match this one exactly?
static func accepts(contract: Dictionary) -> bool:
	return int(contract.get("version", -1)) == SPEC_VERSION \
			and str(contract.get("name", "")) == str(CONTRACT.name) \
			and Array(contract.get("observations", [])) == Array(OBS_NAMES) \
			and Array(contract.get("actions", [])) == Array(TACTIC_NAMES)


## The policy to run. With no model, or one whose contract does not match, the
## scripted one -- and a mismatch says so, because a policy silently swapped
## for its twin is a bug nobody finds.
static func create(model: CombatPolicy = null, contract: Dictionary = {}) -> CombatPolicy:
	if model != null:
		if accepts(contract):
			return model
		push_warning("[ai] combat policy %s refused: contract %s, need %s -- running the scripted one"
				% [model.policy_name(), contract, CONTRACT])
	return ScriptedCombatPolicy.new()


## The policy the command line asks for: `-- --tactics=book` runs the Tactics
## Casebook's (BookCombatPolicy, Docs/Tactics); anything else, create().
static func from_args() -> CombatPolicy:
	for a in OS.get_cmdline_args() + OS.get_cmdline_user_args():
		if a == "--tactics=book":
			var b := BookCombatPolicy.new()
			if b.book != null:
				return b
			push_warning("[ai] --tactics=book: no book at %s -- running the scripted policy" % TacticsBook.PATH)
	return create()


## The situation, as the policy sees it. `cover` is CoverSearch.find's answer
## against the threat ({} with none); `contact` the side's contact.
static func observe(so: Soldier, contact: FactionKnowledge.Contact, cover: Dictionary) -> PackedFloat32Array:
	var o := PackedFloat32Array()
	o.resize(Obs.COUNT)
	var s := so.services
	var now := s.now()
	var feet := so.pawn.feet()
	var threat := contact.pos
	o[Obs.HAS_COVER] = 0.0 if cover.is_empty() else 1.0
	o[Obs.COVER_DIST] = 1.0 if cover.is_empty() \
			else clampf(feet.distance_to(cover.cover) / 12.0, 0.0, 1.0)
	o[Obs.COVER_LIFE] = 0.0 if cover.is_empty() else clampf(float(cover.life) / 10.0, 0.0, 1.0)
	o[Obs.IN_COVER] = 0.0 if s.ai_nav.rate_cover(feet, threat + Vector3.UP * CoverSearch.STAND_EYE,
			CoverSearch.THREAT_HP, CoverSearch.THREAT_RATE).is_empty() else 1.0
	var g := so.pawn.gun
	o[Obs.AMMO] = float(g.ammo) / float(maxi(g.mag_size(), 1)) if g != null else 0.0
	o[Obs.RELOADING] = 1.0 if g != null and g.is_reloading() else 0.0
	var hp := so.pawn.health
	o[Obs.HEALTH] = clampf(hp.total_current() / maxf(so.max_health, 1.0), 0.0, 1.0)
	o[Obs.UNDER_FIRE] = 1.0 if now - so.hurt_at < UNDER_FIRE_SECONDS else 0.0
	o[Obs.THREAT_DIST] = clampf(feet.distance_to(threat) / 40.0, 0.0, 1.0)
	o[Obs.THREAT_VISIBLE] = 1.0 if contact.visible else 0.0
	o[Obs.SINCE_SEEN] = clampf((now - contact.seen_at) / 5.0, 0.0, 1.0)
	var shooting := 0
	var seeing := 0
	var near := 0
	for ally in so.allies():
		if now - ally.last_shot_at < 1.5:
			shooting += 1
		if contact.seen_by.has(ally.get_instance_id()):
			seeing += 1
		if ally.pawn.feet().distance_to(feet) < ALONE_METRES:
			near += 1
	o[Obs.FRIENDS_SHOOTING] = clampf(shooting / 4.0, 0.0, 1.0)
	o[Obs.FRIENDS_SEEING] = clampf(seeing / 4.0, 0.0, 1.0)
	o[Obs.ALONE] = 1.0 if near == 0 else 0.0
	return o
