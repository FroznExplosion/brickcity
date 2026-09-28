class_name ArenaVoice
extends Node
## What the arena's soldiers say, shown to the player (Docs/AI.md 6.5, A18).
##
## A STAND-IN. The callout system of AI.md 6.5 -- squads, queues, co-op
## listeners -- is being built on the AI branch (P6). This is the smallest
## thing that follows the same rules, fed by AIServices.say, so that swapping
## it for the real one is one Callable (AIServices.on_say):
##
##   heard (speaker inside the line's range of the player) and SEEN (in view,
##     and a ray from the camera reaches its head)  -> subtitle, attributed, and
##                                                    a speech bubble over it
##   heard, not seen (an enemy)                     -> subtitle, unattributed.
##                                                    No bubble through walls
##   not heard                                      -> nothing
##
## Rate limits keep it readable: a speaker says one line every SPEAKER_GAP
## seconds, the same thing not again within REPEAT_GAP, and no more than
## MAX_LINES subtitles are up at once.

const LINE_SECONDS := 2.4
const SPEAKER_GAP := 2.0
const REPEAT_GAP := 6.0
const MAX_LINES := 4

var city: Node3D
## Lines said and shown, for gates: key -> count.
var said := {}
var shown := {}
var bubbles_shown := 0
var _subs: Array = []        # [text, until]
var _bubbles := {}           # speaker instance id -> [Label3D, until, Pawn]
var _last_by := {}           # speaker id -> time
var _last_key := {}          # "id:key" -> time
var _label: Label


func setup(p_city: Node3D) -> void:
	city = p_city
	var layer := CanvasLayer.new()
	layer.layer = 4
	add_child(layer)
	_label = Label.new()
	_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	_label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_label.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.offset_bottom = -70.0
	_label.add_theme_font_size_override("font_size", 20)
	_label.add_theme_color_override("font_color", Color(1.0, 0.9, 0.75))
	_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_label.add_theme_constant_override("outline_size", 6)
	layer.add_child(_label)


## AIServices.on_say.
func say(speaker: Pawn, key: String, text: String, range_m: float) -> void:
	if speaker == null or not is_instance_valid(speaker):
		return
	var now := _now()
	var id := speaker.get_instance_id()
	if now - float(_last_by.get(id, -INF)) < SPEAKER_GAP:
		return
	var rk := "%d:%s" % [id, key]
	if now - float(_last_key.get(rk, -INF)) < REPEAT_GAP:
		return
	_last_by[id] = now
	_last_key[rk] = now
	said[key] = int(said.get(key, 0)) + 1
	var cam: Camera3D = city.camera
	var ear: Vector3 = cam.global_position if cam != null else Vector3.ZERO
	var head := speaker.eye.global_position + Vector3.UP * 0.35
	if ear.distance_to(head) > range_m:
		return   # not heard: nothing shown, though the squad acts on it
	shown[key] = int(shown.get(key, 0)) + 1
	if _can_see(cam, speaker, head):
		_subs.append(["Soldier: " + text, now + LINE_SECONDS])
		_bubble(speaker, text, now)
	else:
		_subs.append(["(unseen) " + text, now + LINE_SECONDS])
	while _subs.size() > MAX_LINES:
		_subs.pop_front()


func _can_see(cam: Camera3D, speaker: Pawn, head: Vector3) -> bool:
	if cam == null or not cam.is_position_in_frustum(head):
		return false
	var skip: Array[RID] = [speaker.body.get_rid()]
	var mine: Pawn = city._player_pawn
	if mine != null and is_instance_valid(mine):
		skip.append(mine.body.get_rid())
	var q := PhysicsRayQueryParameters3D.create(cam.global_position, head, Layers.HITSCAN_MASK, skip)
	if not city.get_world_3d().direct_space_state.intersect_ray(q).is_empty():
		return false
	return not city.ai_world.smoke_blocks(cam.global_position, head)


func _bubble(speaker: Pawn, text: String, now: float) -> void:
	var id := speaker.get_instance_id()
	var l: Label3D
	if _bubbles.has(id) and is_instance_valid(_bubbles[id][0]):
		l = _bubbles[id][0]
	else:
		l = Label3D.new()
		l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		l.fixed_size = true
		l.pixel_size = 0.0011
		l.font_size = 30
		l.outline_size = 10
		l.modulate = Color(1.0, 0.95, 0.8)
		l.outline_modulate = Color(0.1, 0.05, 0.0, 0.9)
		l.render_priority = 2
		l.outline_render_priority = 1
		speaker.body.add_child(l)
		l.position = Vector3.UP * (Pawn.BODY_HEIGHT * 0.5 + 0.45)
	l.text = "“" + text + "”"
	bubbles_shown += 1
	_bubbles[id] = [l, now + LINE_SECONDS, speaker]


func _now() -> float:
	return float(Engine.get_physics_frames()) / float(Engine.physics_ticks_per_second)


func _process(_delta: float) -> void:
	var now := _now()
	for i in range(_subs.size() - 1, -1, -1):
		if now >= float(_subs[i][1]):
			_subs.remove_at(i)
	var lines := PackedStringArray()
	for e in _subs:
		lines.append(e[0])
	_label.text = "\n".join(lines)
	for id in _bubbles.keys():
		var e: Array = _bubbles[id]
		if not is_instance_valid(e[0]):
			_bubbles.erase(id)
		elif now >= float(e[1]):
			(e[0] as Label3D).queue_free()
			_bubbles.erase(id)
