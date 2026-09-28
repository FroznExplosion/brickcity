@tool
class_name BTFindCover
extends BTAction
## Cover against the threat (CoverSearch). Kept while it still is: re-searched
## when the threat has moved, the cover has worn, or a few seconds have passed.

const KEEP := 4.0
## After a search that found nothing, how long before looking again.
const RETRY := 1.5
## How much further from the threat a fall back looks for cover.
const FALL_BACK := 8.0


func _tick(_delta: float) -> Status:
	var so := SoldierTree.soldier_of(agent)
	var s := so.services
	var now := s.now()
	var threat: Vector3 = blackboard.get_var(&"threat_eye", Vector3.ZERO, false)
	var cover: Dictionary = blackboard.get_var(&"cover", {}, false)
	# Falling back: cover found from where it stands is the wrong cover. Look
	# again from FALL_BACK metres further from the threat, once per decision.
	if so.tactic == CombatPolicy.Tactic.FALL_BACK \
			and float(blackboard.get_var(&"fell_back_at", -INF, false)) < so.tactic_at:
		blackboard.set_var(&"fell_back_at", now)
		var feet := so.pawn.feet()
		var away := Vector3(feet.x - threat.x, 0.0, feet.z - threat.z)
		if away.length() > 0.01:
			var back := s.ai_nav.snap(feet + away.normalized() * FALL_BACK)
			var found := CoverSearch.find_for(so, back, threat)
			if not found.is_empty() and (found.cover as Vector3).distance_to(threat) \
					> feet.distance_to(threat) + 2.0:
				cover = found
				blackboard.set_var(&"cover", found)
				blackboard.set_var(&"cover_at", now)
				blackboard.set_var(&"cover_threat", threat)
				so.state = "fall back"
				return SUCCESS
		# Nowhere further back: whatever cover there is will do.
	if not cover.is_empty() and now - float(blackboard.get_var(&"cover_at", -INF, false)) < KEEP \
			and threat.distance_to(blackboard.get_var(&"cover_threat", threat, false)) < 3.0 \
			and not CoverSearch.rate(s, cover.cover, threat).is_empty():
		return SUCCESS
	# Nothing here a moment ago, against much the same threat: do not search the
	# same ring again every think.
	var failed_at := float(blackboard.get_var(&"cover_fail_at", -INF, false))
	if cover.is_empty() and now - failed_at < RETRY \
			and threat.distance_to(blackboard.get_var(&"cover_threat", threat, false)) < 3.0:
		return FAILURE
	so.state = "find cover"
	var found := CoverSearch.find_for(so, so.pawn.feet(), threat)
	if found.is_empty():
		blackboard.set_var(&"cover_fail_at", now)
		# A tactic that needs cover and has none: decide again.
		so.tactic_done = true
	blackboard.set_var(&"cover", found)
	blackboard.set_var(&"cover_at", now)
	blackboard.set_var(&"cover_threat", threat)
	return SUCCESS if not found.is_empty() else FAILURE
