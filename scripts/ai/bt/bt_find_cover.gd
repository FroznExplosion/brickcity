@tool
class_name BTFindCover
extends BTAction
## Cover against the threat (CoverSearch). Kept while it still is: re-searched
## when the threat has moved, the cover has worn, or a few seconds have passed.

const KEEP := 4.0


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
	so.state = "find cover"
	var found := CoverSearch.find(s, so.pawn.feet(), threat)
	blackboard.set_var(&"cover", found)
	blackboard.set_var(&"cover_at", now)
	blackboard.set_var(&"cover_threat", threat)
	return SUCCESS if not found.is_empty() else FAILURE
