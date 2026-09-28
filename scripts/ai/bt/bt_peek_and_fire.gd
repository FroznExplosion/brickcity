@tool
class_name BTPeekAndFire
extends BTAction
## Into cover, then hide and peek in turn (F.E.A.R., Docs/AI.md 6.1). Nobody
## crouches (A21): cover hides a standing body, and a peek is a step out to its
## side to shoot and a step back to hide. Leaves when the cover is nearly shot
## through, or when the enemy has not been seen for a while -- the tree then
## searches.
##
## For the tactics that use cover (CombatPolicy): TAKE_COVER and FALL_BACK peek
## and fire; COVER_RELOAD hides, reloads, and when the magazine is full says the
## tactic is done so the next one is chosen. Whatever the tactic, a soldier
## reloading does not peek.

const HIDE := [0.8, 1.6]
const PEEK := [1.2, 2.0]
const LOST := 3.0
## Seconds of cover left against the threat's gun at which to go.
const LEAVE := 0.8
## Closer than this, a soldier running for cover shoots as it goes.
const FIRE_ON_THE_MOVE := 12.0

var _peeking := false
var _until := 0.0


func _enter() -> void:
	_peeking = false
	_until = 0.0


func _tick(_delta: float) -> Status:
	var so := SoldierTree.soldier_of(agent)
	var s := so.services
	var now := s.now()
	var cover: Dictionary = blackboard.get_var(&"cover", {}, false)
	var threat: Vector3 = blackboard.get_var(&"threat_eye", Vector3.ZERO, false)
	if cover.is_empty():
		so.tactic_done = true
		return FAILURE
	var c := so.contact()
	if c == null or now - c.seen_at > LOST:
		so.fire_ok = false
		return FAILURE
	var at: Vector3 = cover.cover
	var feet := so.pawn.feet()
	# Not there yet: run for it -- and with the enemy in sight and close, firing
	# on the move. Running nine metres past somebody three metres away without
	# a shot is the kind of thing the judge calls stupid (DecisionJudge); at
	# range, a run to cover is a run.
	if not _peeking and Vector2(feet.x - at.x, feet.z - at.z).length() > 0.5:
		so.state = "to cover"
		so.fire_ok = c.visible and feet.distance_to(c.pos) < FIRE_ON_THE_MOVE
		so.look_at_point(threat)
		var r := so.move_to(at, true)
		if r == -1 or so.stuck >= Soldier.MAX_STUCK:
			# No way there, or a way the body cannot follow: this cover is out.
			# Only the second is remembered as bad: "no way" can be the nav
			# re-reading ground a wreck just settled on, and blacklisting the
			# only cover there is for that left a soldier with none.
			if so.stuck >= Soldier.MAX_STUCK:
				so.mark_bad_cover(at)
			so.stuck = 0
			blackboard.set_var(&"cover", {})
			blackboard.set_var(&"cover_fail_at", now)
			so.tactic_done = true
			return FAILURE
		return RUNNING
	# In it. Is it still cover? Checked every think -- one DDA -- and left while
	# it still has LEAVE seconds in it: a soldier moves when its cover is being
	# shot away, not after it is gone (AI.md 6.1, AIPlan P5).
	if CoverSearch.life_at(s, at, threat) < LEAVE:
		so.fire_ok = false
		so.cover_left_with = CoverSearch.life_at(s, at, threat)
		so.relocations += 1
		so.mark_bad_cover(at)
		blackboard.set_var(&"cover", {})
		so.tactic_done = true
		return FAILURE
	var g := so.pawn.gun
	var reloading := g != null and g.is_reloading()
	if so.tactic == CombatPolicy.Tactic.COVER_RELOAD and g != null:
		if not reloading and g.ammo < g.mag_size():
			g.reload()
			reloading = g.is_reloading()
		elif not reloading:
			# Full again: what now is the policy's to say.
			so.tactic_done = true
	if reloading:
		_peeking = false
		_until = now + 0.3
	elif now >= _until:
		_peeking = not _peeking
		var span: Array = PEEK if _peeking else HIDE
		_until = now + s.rng.randf_range(span[0], span[1])
		if _peeking:
			so.peeks += 1
	so.look_at_point(threat)
	if _peeking:
		so.state = "peek"
		so.fire_ok = true
		if cover.kind == "high":
			so.move_to(cover.peek)
		else:
			so.stop()
	else:
		so.state = "reload in cover" if reloading else "hide"
		so.fire_ok = false
		if cover.kind == "high":
			so.move_to(at)
		else:
			so.stop()
	return RUNNING


func _exit() -> void:
	var so := SoldierTree.soldier_of(agent)
	if so != null:
		so.fire_ok = false
