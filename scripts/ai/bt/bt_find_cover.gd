@tool
class_name BTFindCover
extends BTAction
## Cover against the threat (CoverSearch). Kept while it still is: re-searched
## when the threat has moved, the cover has worn, or a few seconds have passed.

const KEEP := 4.0
## After a search that found nothing, how long before looking again.
const RETRY := 1.5


func _tick(_delta: float) -> Status:
	var so := SoldierTree.soldier_of(agent)
	var s := so.services
	var now := s.now()
	var threat: Vector3 = blackboard.get_var(&"threat_eye", Vector3.ZERO, false)
	var cover: Dictionary = blackboard.get_var(&"cover", {}, false)
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
	var found := CoverSearch.find(s, so.pawn.feet(), threat)
	if found.is_empty():
		blackboard.set_var(&"cover_fail_at", now)
	blackboard.set_var(&"cover", found)
	blackboard.set_var(&"cover_at", now)
	blackboard.set_var(&"cover_threat", threat)
	return SUCCESS if not found.is_empty() else FAILURE
