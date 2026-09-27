@tool
class_name BTPeekAndFire
extends BTAction
## Into cover, then hide and peek in turn (F.E.A.R., Docs/AI.md 6.1): low cover,
## crouch to hide and stand to shoot; high cover, step out to its side to shoot
## and back to hide. Leaves when the cover is nearly shot through, or when the
## enemy has not been seen for a while -- the tree then searches.

const HIDE := [0.8, 1.6]
const PEEK := [1.2, 2.0]
const LOST := 3.0
## Seconds of cover left against the threat's gun at which to go.
const LEAVE := 0.8

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
		return FAILURE
	var c := so.contact()
	if c == null or now - c.seen_at > LOST:
		so.fire_ok = false
		so.pawn.intents.crouch = false
		return FAILURE
	var at: Vector3 = cover.cover
	var feet := so.pawn.feet()
	# Not there yet: run for it, not firing.
	if not _peeking and Vector2(feet.x - at.x, feet.z - at.z).length() > 0.5:
		so.state = "to cover"
		so.fire_ok = false
		so.pawn.intents.crouch = false
		so.look_at_point(threat)
		var r := so.move_to(at, true)
		return FAILURE if r == -1 else RUNNING
	# In it. Is it still cover? Checked every think -- one DDA -- and left while
	# it still has LEAVE seconds in it: a soldier moves when its cover is being
	# shot away, not after it is gone (AI.md 6.1, AIPlan P5).
	if CoverSearch.life_at(s, at, threat) < LEAVE:
		so.fire_ok = false
		so.cover_left_with = CoverSearch.life_at(s, at, threat)
		so.relocations += 1
		blackboard.set_var(&"cover", {})
		return FAILURE
	if now >= _until:
		_peeking = not _peeking
		var span: Array = PEEK if _peeking else HIDE
		_until = now + s.rng.randf_range(span[0], span[1])
		if _peeking:
			so.peeks += 1
	so.look_at_point(threat)
	if _peeking:
		so.state = "peek"
		so.fire_ok = true
		so.pawn.intents.crouch = false
		if cover.kind == "high":
			so.move_to(cover.peek)
		else:
			so.stop()
	else:
		so.state = "hide"
		so.fire_ok = false
		so.pawn.intents.crouch = cover.kind == "low"
		if cover.kind == "high":
			so.move_to(at)
		else:
			so.stop()
	return RUNNING


func _exit() -> void:
	var so := SoldierTree.soldier_of(agent)
	if so != null:
		so.fire_ok = false
		so.pawn.intents.crouch = false
