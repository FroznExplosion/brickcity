@tool
class_name BTPlayTravel
extends BTAction
## Order MOVE: the squad travels to a point in formation (Docs/AI.md 4.3, "squads
## path once"; mvs-c's formation rule; F.E.A.R.'s orderly advance in file).
##
## Only the LEADER asks for a path to the goal. The rest FOLLOW: each has a place
## in the file -- the point on the leader's own trail SPACING metres per rank
## behind it, stepped out to alternate sides where there is room -- and walks to
## that place as the squad moves it. A follower's place is a few metres off, so
## its path requests are a handful of nodes, where four soldiers each pathing the
## whole way cost four full searches and go four different ways.
##
## Done when the leader is there and the file has closed up on it. The leader
## lost, the next in line leads. Contact on the way ends the order ("contact"):
## a squad in file is not a squad in a fight, and what to do next is the
## commander's to say.

const SPACING := 2.2
const SIDE_STEP := 1.3
## A breadcrumb every this many metres the leader moves.
const CRUMB := 0.7
const CRUMBS_KEPT := 1000
## On arrival the file gathers in a ring this wide round the leader.
const GATHER := 2.0
## The file has closed up when everyone is this near their place.
const CLOSED := 3.0
const TIMEOUT := 120.0

var _leader: Soldier
var _trail: PackedVector3Array = PackedVector3Array()
var _started := 0.0
var _arrived_at := -1.0
## Set by _place: the last crumb before the place it just worked out.
var _place_index := 0

## This play's generation (Squad.begin_play).
var _gen := 0


func _enter() -> void:
	_gen = (agent as Squad).begin_play()
	var q := agent as Squad
	_started = q.services.now()
	_arrived_at = -1.0
	_trail = PackedVector3Array()
	_leader = null
	_lead(q)


func _tick(_delta: float) -> Status:
	var q := agent as Squad
	var s := q.services
	var now := s.now()
	q.play = "travel"
	blackboard.set_var(&"play", q.play)
	var o := q.order
	if o == null:
		return FAILURE
	var c := q.contact()
	if c != null and c.visible:
		q.say(null, "contact", "Contact!", true)
		q.finish(SquadMsg.ReportKind.FAILED, "contact")
		return FAILURE
	if _leader == null or not is_instance_valid(_leader) or _leader.is_dead():
		if not _lead(q):
			q.finish(SquadMsg.ReportKind.FAILED, "wiped out")
			return FAILURE
	var lf := _leader.pawn.feet()
	# Never trimmed: a follower counts crumbs by index, and cutting the front off
	# would move every index under it. A trip is bounded by TIMEOUT anyway.
	if (_trail.is_empty() or _trail[_trail.size() - 1].distance_to(lf) >= CRUMB) 			and _trail.size() < CRUMBS_KEPT:
		_trail.append(lf)
	# Places in the file.
	var heading := _heading()
	var yaw := atan2(-heading.x, -heading.z)
	var closed := true
	var rank := 0
	var alive_n := q.alive().size() - 1
	if _arrived_at < 0.0 and q.replied(_leader, SquadMsg.StatusKind.REACHED):
		_arrived_at = now
	for m in q.alive():
		if m == _leader:
			continue
		rank += 1
		if m.assignment == null or m.assignment.task != SquadMsg.Task.FOLLOW:
			var a := SquadMsg.Assignment.make(SquadMsg.Task.FOLLOW, lf)
			a.role = "file %d" % rank
			q.assign(m, a)
		var place := _place(q, rank) if _arrived_at < 0.0 else _gather(q, rank, alive_n)
		m.assignment.point = place
		m.assignment.yaw = yaw
		m.assignment.trail = _trail
		m.assignment.upto = _place_index if _arrived_at < 0.0 else _trail.size() - 1
		if m.pawn.feet().distance_to(place) > CLOSED:
			closed = false
	if q.replied(_leader, SquadMsg.StatusKind.BLOCKED):
		q.finish(SquadMsg.ReportKind.FAILED, "no way")
		return FAILURE
	if _arrived_at >= 0.0:
		if closed or now - _arrived_at > 8.0:
			q.events["travelled"] = now
			q.finish(SquadMsg.ReportKind.DONE)
			return SUCCESS
	if now - _started > TIMEOUT:
		q.finish(SquadMsg.ReportKind.FAILED, "too long")
		return FAILURE
	return RUNNING


## The member nearest the goal leads; it alone asks for the path there.
func _lead(q: Squad) -> bool:
	var alive := q.alive()
	if alive.is_empty() or q.order == null:
		return false
	var goal := q.order.point
	var best: Soldier = null
	for m in alive:
		if best == null or m.pawn.feet().distance_to(goal) < best.pawn.feet().distance_to(goal):
			best = m
	_leader = best
	var a := SquadMsg.Assignment.make(SquadMsg.Task.MOVE, q.services.ai_nav.snap(goal))
	a.role = "lead"
	q.assign(_leader, a)
	q.events["leader"] = _leader.get_instance_id()
	return true


## Where rank `k` stands: k * SPACING back along the leader's trail, stepped to
## alternate sides where a body stands there.
func _place(q: Squad, k: int) -> Vector3:
	var back := SPACING * k
	var p: Vector3 = _trail[_trail.size() - 1] if not _trail.is_empty() else _leader.pawn.feet()
	var dir := Vector3.ZERO
	_place_index = maxi(_trail.size() - 1, 0)
	for i in range(_trail.size() - 1, 0, -1):
		var a: Vector3 = _trail[i]
		var b: Vector3 = _trail[i - 1]
		var seg := a.distance_to(b)
		dir = a - b
		# The crumb before the place: the follower walks the trail up to here.
		_place_index = i - 1
		if seg >= back:
			p = a.lerp(b, back / maxf(seg, 0.001))
			back = 0.0
			break
		back -= seg
		p = b
	if dir.length() < 0.01:
		dir = _heading()
	var across := Vector3(-dir.z, 0.0, dir.x).normalized()
	var side := 1.0 if k % 2 == 1 else -1.0
	var stepped := q.services.ai_nav.snap(p + across * SIDE_STEP * side)
	if q.services.ai_nav.can_stand(stepped) and absf(stepped.y - p.y) < 0.5:
		return stepped
	return p


## There: rank `k` of `n` on a ring round the leader, where a body stands.
func _gather(q: Squad, k: int, n: int) -> Vector3:
	var c := _leader.pawn.feet()
	var a0 := atan2(_heading().z, _heading().x) + PI
	var a := a0 + (float(k) - (n + 1) * 0.5) * (PI / maxf(n, 1))
	var p := q.services.ai_nav.snap(c + Vector3(cos(a), 0.0, sin(a)) * GATHER)
	return p if q.services.ai_nav.can_stand(p) else c


func _heading() -> Vector3:
	if _trail.size() >= 2:
		var d := _trail[_trail.size() - 1] - _trail[maxi(_trail.size() - 4, 0)]
		d.y = 0.0
		if d.length() > 0.01:
			return d.normalized()
	var q := agent as Squad
	var to := q.order.point - _leader.pawn.feet() if q.order != null else Vector3.FORWARD
	to.y = 0.0
	return to.normalized() if to.length() > 0.01 else Vector3.FORWARD


func _exit() -> void:
	var q := agent as Squad
	if q != null:
		q.clear_assignments(_gen)
