@tool
class_name BTChooseTactic
extends BTAction
## Face to face with the enemy: ask the policy what to do (CombatPolicy), and
## hold the answer for a few seconds -- a soldier that re-decided every think
## would twitch between tactics. Always SUCCESS; the tactic is on the soldier.
##
## Decided again when the hold runs out, when the tactic says it is done or
## could not be done, when the soldier is hurt after choosing, or when its
## magazine runs low in a tactic that did not plan for it.

## Seconds a tactic is held, drawn in this range.
const HOLD := [2.5, 4.5]
## Soonest a decision may be taken again, whatever happens.
const MIN_GAP := 0.8

const LINES := {
	CombatPolicy.Tactic.TAKE_COVER: ["Taking cover!", "Get down!", "Behind the wall!"],
	CombatPolicy.Tactic.COVER_RELOAD: ["Reloading!", "Changing mags, cover me!", "I'm out!"],
	CombatPolicy.Tactic.PUSH: ["Pushing up!", "Moving in!", "Go, go, go!"],
	CombatPolicy.Tactic.FLANK: ["Flanking!", "Going round the side!", "I'll get round him!"],
	CombatPolicy.Tactic.FALL_BACK: ["Falling back!", "Pull back!", "I'm hit, moving back!"],
	CombatPolicy.Tactic.FIGHT_OPEN: ["Light him up!", "Open fire!", "There he is!"],
	CombatPolicy.Tactic.RUSH: ["Rush him!", "Charge!", "Everybody go!"],
	CombatPolicy.Tactic.MELEE: ["I'll take him!", "Get over here!", "Hand to hand!"],
}


func _tick(_delta: float) -> Status:
	var so := SoldierTree.soldier_of(agent)
	var s := so.services
	var now := s.now()
	var c := so.contact()
	if c == null:
		return FAILURE
	if not _should_decide(so, now):
		return SUCCESS
	var threat := c.pos + Vector3.UP * CoverSearch.STAND_EYE
	# The cover search is the expensive part of the observation, and the cover
	# tactics use its answer: kept for them (BTFindCover reads it).
	# Cover it already has that still stands against much the same threat is
	# kept -- one rating, not a ring search -- so a soldier re-deciding does not
	# run off to new cover it did not need, and the decision stays in budget.
	var cover: Dictionary = blackboard.get_var(&"cover", {}, false)
	var kept := false
	if not cover.is_empty() and threat.distance_to(blackboard.get_var(&"cover_threat", threat, false)) < 3.0:
		var again := CoverSearch.rate(s, cover.cover, threat)
		if not again.is_empty():
			cover = again
			kept = true
	if not kept:
		cover = CoverSearch.find_for(so, so.pawn.feet(), threat)
		blackboard.set_var(&"cover_at", now)
		if cover.is_empty():
			blackboard.set_var(&"cover_fail_at", now)
	blackboard.set_var(&"cover", cover)
	blackboard.set_var(&"cover_threat", threat)
	var obs := CombatPolicy.observe(so, c, cover)
	var was := so.tactic
	so.tactic = s.policy.decide_in(so, c, cover, obs, s.rng)
	so.tactic_at = now
	so.tactic_until = now + s.rng.randf_range(HOLD[0], HOLD[1])
	so.tactic_done = false
	var logged := s.log_decision(so, obs, so.tactic)
	if s.judge != null:
		s.judge.open(so, obs, so.tactic, logged)
	if so.tactic != was and LINES.has(so.tactic) and s.rng.randf() < 0.7:
		var lines: Array = LINES[so.tactic]
		s.say(so.pawn, CombatPolicy.TACTIC_NAMES[so.tactic], lines[s.rng.randi() % lines.size()])
	return SUCCESS


func _should_decide(so: Soldier, now: float) -> bool:
	if so.tactic < 0:
		return true
	if now - so.tactic_at < MIN_GAP:
		return false
	if so.tactic_done or now >= so.tactic_until:
		return true
	if so.hurt_at > so.tactic_at:
		return true
	var g := so.pawn.gun
	if g != null and so.tactic != CombatPolicy.Tactic.COVER_RELOAD and so.tactic != CombatPolicy.Tactic.MELEE \
			and float(g.ammo) / float(maxi(g.mag_size(), 1)) < 0.2 and not g.is_reloading():
		return true
	return false
