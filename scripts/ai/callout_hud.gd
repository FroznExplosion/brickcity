class_name CalloutHud
extends CanvasLayer
## One player's callouts on screen (Docs/AI.md 6.5, A18): the subtitles at the
## bottom, and a talking marker over each speaker the player may see -- a
## depth-tested one for an enemy in sight, one drawn through walls for a friendly.
## It shows what Callouts decided for its listener and decides nothing itself.

const MARKER_ABOVE := 0.55

## Subtitles on or off (the Options menu, through BrickcityMenuHost). Only the
## text: the talking markers over speakers stay.
static var shown := true

var callouts: Callouts
var listener: Callouts.Listener
var _box: VBoxContainer
var _labels: Array[Label] = []
var _markers := {}   # speaker instance id -> Label3D


func setup(p_callouts: Callouts, p_listener: Callouts.Listener) -> void:
	callouts = p_callouts
	listener = p_listener


func _ready() -> void:
	layer = 5
	_box = VBoxContainer.new()
	_box.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_box.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_box.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_box.offset_bottom = -90.0
	_box.alignment = BoxContainer.ALIGNMENT_END
	add_child(_box)


func _process(_delta: float) -> void:
	if _box != null:
		_box.visible = shown
	refresh()


## Make the screen match the listener's views. Public so a headless gate can
## call it without waiting for a drawn frame.
func refresh() -> void:
	if listener == null:
		return
	# A speaker can be gone between Callouts' tick and this frame -- a body is
	# freed the moment it dies (the combat arena): its line goes with it.
	var views := listener.views.filter(func(v: Callouts.View) -> bool:
		return v.line != null and is_instance_valid(v.line.speaker))
	while _labels.size() < views.size():
		var lb := Label.new()
		lb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lb.add_theme_font_size_override("font_size", 20)
		lb.add_theme_color_override("font_outline_color", Color.BLACK)
		lb.add_theme_constant_override("outline_size", 6)
		_box.add_child(lb)
		_labels.append(lb)
	var shown := {}
	for i in _labels.size():
		var lb := _labels[i]
		lb.visible = i < views.size()
		if not lb.visible:
			continue
		var v: Callouts.View = views[i]
		var friendly := v.line.speaker.team == listener.team
		var who := ("Squad" if friendly else "Enemy") if v.attributed else "?"
		lb.text = "%s: %s" % [who, v.line.text]
		lb.modulate = Color(0.6, 0.85, 1.0) if friendly else Color(1.0, 0.7, 0.6)
		if v.marker:
			var m := _marker(v.line.speaker)
			m.visible = true
			m.no_depth_test = v.through_walls
			m.modulate = lb.modulate
			shown[v.line.speaker.get_instance_id()] = true
	for id in _markers.keys():
		# Untyped first: a marker rides on its speaker's body, and a body freed
		# with it cannot be assigned to a typed variable at all.
		var held = _markers[id]
		if not is_instance_valid(held):
			_markers.erase(id)
		elif not shown.has(id):
			(held as Label3D).visible = false


## The marker over `speaker`, made the first time it talks.
func _marker(speaker: Pawn) -> Label3D:
	var id := speaker.get_instance_id()
	var held = _markers.get(id)
	var m: Label3D = held if held != null and is_instance_valid(held) else null
	if m == null:
		m = Label3D.new()
		m.name = "TalkMarker"
		m.text = "(( ))"
		m.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		m.fixed_size = true
		m.pixel_size = 0.0015
		m.font_size = 28
		m.outline_size = 8
		m.position = Vector3.UP * (Pawn.BODY_HEIGHT * 0.5 + MARKER_ABOVE)
		speaker.body.add_child(m)
		_markers[id] = m
	return m


## For gates: the marker over `speaker` is showing, and whether through walls.
## {} when there is none.
func marker_state(speaker: Pawn) -> Dictionary:
	var held = _markers.get(speaker.get_instance_id())
	if held == null or not is_instance_valid(held) or not (held as Label3D).visible:
		return {}
	var m: Label3D = held
	return {"through_walls": m.no_depth_test}


func subtitles() -> PackedStringArray:
	var out := PackedStringArray()
	for lb in _labels:
		if lb.visible:
			out.append(lb.text)
	return out
