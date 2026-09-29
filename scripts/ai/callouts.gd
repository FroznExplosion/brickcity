class_name Callouts
extends RefCounted
## What agents say (Docs/AI.md 6.5, A18): every play start, state change and
## discovery is a line -- "stacking up", "flashbang out", "moving", "man down".
## F.E.A.R.'s cheapest intelligence: the player credits the squad with the plan
## the line describes, and the line tells the player what is coming.
##
## A line reaches a player only if they HEAR it -- the speaker inside the line's
## range of the listener. Then, per listener (each co-op player has their own):
##
##   heard, and the speaker can be SEEN   -> subtitle, attributed, and a talking
##     (in view, a sight ray reaches them,   marker over the speaker's head
##      no smoke in the way)
##   heard, unseen, an ENEMY              -> subtitle only, unattributed. No marker
##                                           through walls
##   heard, unseen, a FRIENDLY            -> subtitle, attributed, and the marker
##                                           drawn through walls
##   not heard                            -> nothing; the squad still acts on it
##
## Rate limits keep it readable: one line per squad every SQUAD_GAP seconds, the
## same line from the same squad not again within REPEAT_GAP, lines that wait too
## long dropped, urgent lines ("grenade!") to the front of the queue.

const SHOUT := 35.0
const TALK := 15.0
## How long a line stays up.
const LINE_SECONDS := 2.2
const SQUAD_GAP := 1.5
const REPEAT_GAP := 6.0
## A queued line older than this is stale and dropped.
const QUEUE_LIFE := 2.0
## Seen-ness is re-checked this often while a line is up.
const VIEW_HZ := 5.0

class Line:
	var squad := 0
	var speaker: Pawn
	var key := ""
	var text := ""
	var range_m := SHOUT
	var urgent := false
	var queued_at := 0.0
	var said_at := -1.0
	var until := 0.0


## One player's view of the lines being said.
class Listener:
	var camera: Camera3D
	var team := 0
	## The player's own body, left out of sight rays.
	var pawn: Pawn
	## What they are shown now.
	var views: Array[View] = []


class View:
	var line: Line
	## The subtitle names the speaker.
	var attributed := false
	## A talking marker over the speaker.
	var marker := false
	## Drawn through walls (friendlies).
	var through_walls := false


var listeners: Array[Listener] = []
## Lines being said now.
var live: Array[Line] = []
## Every line said, for gates and the log: [time, squad, key, text].
var said: Array = []
var _queues := {}      # squad -> Array[Line]
var _last_said := {}   # squad -> time
var _last_key := {}    # "squad:key" -> time
var _next_view := -INF


func listen(camera: Camera3D, team: int, pawn: Pawn = null) -> Listener:
	var l := Listener.new()
	l.camera = camera
	l.team = team
	l.pawn = pawn
	listeners.append(l)
	return l


## `speaker` says `text` for `squad`. `key` names the line for the repeat rule.
func say(squad: int, speaker: Pawn, key: String, text: String, now: float,
		urgent := false, range_m := SHOUT) -> void:
	if speaker == null or not is_instance_valid(speaker):
		return
	var rk := "%d:%s" % [squad, key]
	if now - float(_last_key.get(rk, -INF)) < REPEAT_GAP:
		return
	var q: Array = _queues.get(squad, [])
	for l: Line in q:
		if l.key == key:
			return
	var line := Line.new()
	line.squad = squad
	line.speaker = speaker
	line.key = key
	line.text = text
	line.urgent = urgent
	line.range_m = range_m
	line.queued_at = now
	if urgent:
		q.push_front(line)
	else:
		q.append(line)
	_queues[squad] = q


## Speak what is due, drop what has run out, and refresh each listener's view.
## Needs the physics space for sight rays and AIWorld for smoke.
func tick(now: float, world3d: World3D, ai_world: AIWorld) -> void:
	var changed := false
	for squad in _queues:
		var q: Array = _queues[squad]
		while not q.is_empty() and (now - (q[0] as Line).queued_at > QUEUE_LIFE
				or not is_instance_valid((q[0] as Line).speaker)):
			q.pop_front()
		if q.is_empty():
			continue
		var front: Line = q[0]
		var gap := SQUAD_GAP * (0.35 if front.urgent else 1.0)
		if now - float(_last_said.get(squad, -INF)) < gap:
			continue
		q.pop_front()
		front.said_at = now
		front.until = now + LINE_SECONDS
		_last_said[squad] = now
		_last_key["%d:%s" % [squad, front.key]] = now
		live.append(front)
		said.append([now, squad, front.key, front.text])
		changed = true
	for i in range(live.size() - 1, -1, -1):
		if now >= live[i].until or not is_instance_valid(live[i].speaker):
			live.remove_at(i)
			changed = true
	if changed or now >= _next_view:
		_next_view = now + 1.0 / VIEW_HZ
		for l in listeners:
			_view(l, world3d, ai_world)


func _view(l: Listener, world3d: World3D, ai_world: AIWorld) -> void:
	l.views.clear()
	if l.camera == null or not is_instance_valid(l.camera) or not l.camera.is_inside_tree():
		return
	var ear := l.camera.global_position
	for line in live:
		var head := line.speaker.eye.global_position + Vector3.UP * 0.3
		if ear.distance_to(head) > line.range_m:
			continue
		var v := View.new()
		v.line = line
		var friendly := line.speaker.team == l.team
		if friendly:
			# The player's own side is always locatable.
			v.attributed = true
			v.marker = true
			v.through_walls = true
		elif can_see(l, line.speaker, world3d, ai_world):
			v.attributed = true
			v.marker = true
		l.views.append(v)


## The listener's eye reaches the speaker: in the view, a sight ray on the
## hitscan mask (the same as perception's) gets there, and no smoke between.
static func can_see(l: Listener, speaker: Pawn, world3d: World3D, ai_world: AIWorld) -> bool:
	var cam := l.camera
	var head := speaker.eye.global_position
	if not cam.is_position_in_frustum(head) and not cam.is_position_in_frustum(speaker.chest()):
		return false
	var ex: Array[RID] = [speaker.body.get_rid()]
	if l.pawn != null and is_instance_valid(l.pawn):
		ex.append(l.pawn.body.get_rid())
	var from := cam.global_position
	for at in [head, speaker.chest()]:
		var q := PhysicsRayQueryParameters3D.create(from, at, Layers.HITSCAN_MASK, ex)
		if world3d.direct_space_state.intersect_ray(q).is_empty() \
				and (ai_world == null or not ai_world.smoke_blocks(from, at)):
			return true
	return false
