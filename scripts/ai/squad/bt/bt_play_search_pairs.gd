@tool
class_name BTPlaySearchPairs
extends BTAction
## Lost the enemy (Docs/AI.md 6.3, F.E.A.R.'s search in pairs): the squad goes to
## where it was last seen or heard in two pairs, one either side of it, each
## member covering its partner a couple of metres behind; there, each sweeps a
## half. Nothing found, and the contact is marked searched.

const SPREAD := 1.8
const TRAIL := 2.0
const TIMEOUT := 25.0

var _sweeping := false
var _started := 0.0


func _enter() -> void:
	var q := agent as Squad
	var s := q.services
	_sweeping = false
	_started = s.now()
	var c := q.contact()
	if c == null:
		return
	var lkp := c.pos
	var dir := lkp - q.center()
	dir.y = 0.0
	dir = dir.normalized() if dir.length() > 0.1 else Vector3.FORWARD
	var right := dir.cross(Vector3.UP)
	var alive := q.alive()
	for i in alive.size():
		var pair := i % 2
		var rank := i / 2
		var p := lkp + right * SPREAD * (1.0 if pair == 0 else -1.0) - dir * TRAIL * rank
		var a := SquadMsg.Assignment.make(SquadMsg.Task.MOVE, s.ai_nav.snap(p))
		a.yaw = atan2(-dir.x, -dir.z)
		a.role = "search %s" % ("right" if pair == 0 else "left")
		q.assign(alive[i], a)
	q.say(alive[0] if not alive.is_empty() else null, "search", "Lost him. Pairs -- check it out.")


func _tick(_delta: float) -> Status:
	var q := agent as Squad
	var s := q.services
	var now := s.now()
	q.play = "search pairs"
	blackboard.set_var(&"play", q.play)
	var c := q.contact()
	if c == null or c.visible:
		return FAILURE
	if not _sweeping and (q.all_replied(SquadMsg.StatusKind.REACHED) or now - _started > TIMEOUT):
		_sweeping = true
		var alive := q.alive()
		for i in alive.size():
			var m := alive[i]
			var to := c.pos - m.pawn.feet()
			var yaw := atan2(-to.x, -to.z) if to.length() > 0.5 else m.pawn.intents.look_yaw
			var a := SquadMsg.Assignment.make(SquadMsg.Task.SWEEP, m.pawn.feet())
			# Each pair sweeps its own half.
			a.yaw = yaw + (0.6 if i % 2 == 0 else -0.6)
			a.role = "sweep"
			q.assign(m, a)
	if _sweeping and q.all_replied(SquadMsg.StatusKind.DONE):
		c.searched = true
		q.events["searched"] = now
		q.say(null, "nothing", "Nothing here.")
		q.clear_assignments()
		return SUCCESS
	return RUNNING


func _exit() -> void:
	var q := agent as Squad
	if q != null:
		q.clear_assignments()
