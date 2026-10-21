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
## more than the whole AI budget. Spots an author marked as cover in a build
## (BuildingMarks) are rated the same way first, and taken when they are good.
##
##   LOW cover hides a crouched body and not a standing one: peek by standing.
##   HIGH cover hides a standing body: peek by stepping out to its side.

## Heights above the feet (Pawn): a crouched chest and eye, a standing eye.
const CROUCH_CHEST := 0.78
const CROUCH_EYE := 1.0
const STAND_EYE := 1.42
## A standing chest: what cover has to hide when nobody crouches (A21).
const STAND_CHEST := 1.1
## What the threat is assumed to carry, when nobody knows: a rifle.
const THREAT_HP := 68
const THREAT_RATE := 7.5
## The range a soldier likes to fight at.
const IDEAL_RANGE := 18.0


## {"cover": Vector3, "kind": "low"|"high", "peek": Vector3, "life": float,
## "hug": float} or {}.
static func find(s: AIServices, from: Vector3, threat_eye: Vector3) -> Dictionary:
	var mark := marked(s, from, threat_eye)
	if not mark.is_empty():
		return mark
	return s.ai_nav.find_cover(from, threat_eye, THREAT_HP, THREAT_RATE, IDEAL_RANGE)


## The best spot marked as cover (BuildingMarks) within BuildingMarks.REACH of
## `from` that hides a body from this threat, or {}. Any that does is taken over
## the ring search -- the author's say -- and of several, the best by the ring's
## own score (ai_nav.cpp, _cover_spot). Docs/AI.md 3.3.1: a mark is rated against
## the bricks as they are now, like any other spot; it is never cover because
## somebody said so.
static func marked(s: AIServices, from: Vector3, threat_eye: Vector3) -> Dictionary:
	if not s.marks.is_valid():
		return {}
	var best := {}
	var best_score := -INF
	var rated := 0
	for p: Vector3 in s.marks.call(from, BuildingMarks.REACH, "cover"):
		# The ring's own rule: cover on the floor the soldier is on.
		if absf(p.y - from.y) > 1.0:
			continue
		if rated >= BuildingMarks.MAX_RATED:
			break
		rated += 1
		var spot := rate(s, p, threat_eye)
		if spot.is_empty():
			continue
		var score := minf(float(spot.life), 10.0) - from.distance_to(p) * 0.5 \
				- absf(p.distance_to(threat_eye) - IDEAL_RANGE) * 0.1 \
				- maxf(float(spot.hug) - 1.0, 0.0) * 1.5
		# Marked or not, nobody is sent into a danger volume.
		if s.ai_world.danger_distance(p) < 2.0:
			continue
		if score > best_score:
			best_score = score
			best = spot
	return best


## find(), for one soldier: cover it has lately given up on (Soldier.bad_cover)
## is no cover. The search itself cannot leave spots out, and without this it
## handed back the spot the soldier had just abandoned, a second and a half on.
static func find_for(so: Soldier, from: Vector3, threat_eye: Vector3) -> Dictionary:
	var found := find(so.services, from, threat_eye)
	if not found.is_empty() and so.is_bad_cover(found.cover):
		return {}
	return found


## find() through the nav queue (AINav.request_cover): null while it is being
## looked for, then the answer, {} for none. One search per soldier per `slot`
## (Soldier.cover_jobs); asked from more than `moved` metres off, or against a
## threat that has moved, it starts over. A soldier asking from its own feet
## moves while it waits: QUEUED_MOVE lets it -- restarting on every metre, one
## on the run never got an answer. A squad asking for a fixed point passes less. Served a slice a tick by AIServices.tick,
## the soldier the player is looking at, or nearest, first -- and by every
## asker, so it moves wherever soldiers think (a probe runs no AIServices.tick). `skip_bad`: as
## find_for, cover the soldier lately gave up on is none.
static func find_queued(so: Soldier, slot: StringName, from: Vector3, threat_eye: Vector3,
		skip_bad := true, moved := QUEUED_MOVE) -> Variant:
	var nav := so.services.ai_nav
	var job: Dictionary = so.cover_jobs.get(slot, {})
	if not job.is_empty() and (from.distance_to(job.from) > moved
			or threat_eye.distance_to(job.threat) > 3.0
			or nav.get_cover_status(int(job.id)) == AINav.UNKNOWN):
		nav.release_cover(int(job.id))
		job = {}
	if job.is_empty():
		# A marked spot is a few rays: no queue for it.
		var mark := marked(so.services, from, threat_eye)
		if not mark.is_empty() and not (skip_bad and so.is_bad_cover(mark.cover)):
			return mark
		job = {"from": from, "threat": threat_eye,
				"id": nav.request_cover(from, threat_eye, THREAT_HP, THREAT_RATE, IDEAL_RANGE, so.importance)}
		so.cover_jobs[slot] = job
	if nav.get_cover_status(int(job.id)) == AINav.PENDING:
		serve(nav)
	if nav.get_cover_status(int(job.id)) != AINav.DONE:
		return null
	var found := nav.get_cover(int(job.id))
	nav.release_cover(int(job.id))
	so.cover_jobs.erase(slot)
	if skip_bad and not found.is_empty() and so.is_bad_cover(found.cover):
		return {}
	return found


## How far a soldier may have moved while its search was queued and still take
## the answer.
const QUEUED_MOVE := 6.0
## A fixed point asked about (a squad's bound or rally spot): another point.
const POINT_MOVE := 1.0
## Cover searching a physics tick, however many ask: a dense block's whole
## search, 3-22 ms at once, is spread over a few ticks.
const SERVE_USEC := 3000
static var _serve_frame := -1
static var _serve_usec := 0


## Move the queued cover searches on, inside this tick's SERVE_USEC.
static func serve(nav: AINav) -> void:
	if nav.cover_pending() == 0:
		return
	var f := Engine.get_physics_frames()
	if f != _serve_frame:
		_serve_frame = f
		_serve_usec = 0
	if _serve_usec >= SERVE_USEC:
		return
	var t := Time.get_ticks_usec()
	nav.service_cover(SERVE_USEC - _serve_usec)
	_serve_usec += Time.get_ticks_usec() - t


## Is `p` cover against a threat whose eye is at `threat_eye`, and how good.
static func rate(s: AIServices, p: Vector3, threat_eye: Vector3) -> Dictionary:
	return s.ai_nav.rate_cover(p, threat_eye, THREAT_HP, THREAT_RATE)


## Seconds the cover at `p` still has against the threat: what a soldier in it
## watches, and leaves before it runs out.
static func life_at(s: AIServices, p: Vector3, threat_eye: Vector3) -> float:
	var chest := STAND_CHEST if s.ai_nav.get_stand_only() else CROUCH_CHEST
	return s.ai_world.cover_seconds(threat_eye, p + Vector3.UP * chest, THREAT_HP, THREAT_RATE)
