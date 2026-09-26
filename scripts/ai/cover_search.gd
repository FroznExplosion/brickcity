class_name CoverSearch
extends RefCounted
## Where to hide from a threat, found when it is needed (Docs/AI.md 3.7, 6.1).
##
## The plan was tactical points baked per recipe, with arcs. What a point's arc
## stands for -- "this hides you from THAT side" -- AIWorld answers directly:
## whether the bricks between the threat's eye and a spot cover a body there, and
## for how many seconds. So the search asks that of a ring of spots round the
## soldier, against the actual threat, in a destructible city where a baked arc
## would be wrong the moment the wall was shot. The search itself is C++
## (AINav.find_cover): written here first, it was 2.9 ms of GDScript a search,
## more than the whole AI budget.
##
##   LOW cover hides a crouched body and not a standing one: peek by standing.
##   HIGH cover hides a standing body: peek by stepping out to its side.

## Heights above the feet (Pawn): a crouched chest and eye, a standing eye.
const CROUCH_CHEST := 0.78
const CROUCH_EYE := 1.0
const STAND_EYE := 1.42
## What the threat is assumed to carry, when nobody knows: a rifle.
const THREAT_HP := 68
const THREAT_RATE := 7.5
## The range a soldier likes to fight at.
const IDEAL_RANGE := 18.0


## {"cover": Vector3, "kind": "low"|"high", "peek": Vector3, "life": float,
## "hug": float} or {}.
static func find(s: AIServices, from: Vector3, threat_eye: Vector3) -> Dictionary:
	return s.ai_nav.find_cover(from, threat_eye, THREAT_HP, THREAT_RATE, IDEAL_RANGE)


## Is `p` cover against a threat whose eye is at `threat_eye`, and how good.
static func rate(s: AIServices, p: Vector3, threat_eye: Vector3) -> Dictionary:
	return s.ai_nav.rate_cover(p, threat_eye, THREAT_HP, THREAT_RATE)


## Seconds the cover at `p` still has against the threat: what a soldier in it
## watches, and leaves before it runs out.
static func life_at(s: AIServices, p: Vector3, threat_eye: Vector3) -> float:
	return s.ai_world.cover_seconds(threat_eye, p + Vector3.UP * CROUCH_CHEST, THREAT_HP, THREAT_RATE)
