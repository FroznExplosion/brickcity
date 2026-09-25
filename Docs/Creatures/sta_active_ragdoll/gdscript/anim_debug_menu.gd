extends CanvasLayer
class_name AnimDebugMenu
## In-game tuning panel for the ActiveRagdoll animation/physics parameters.
## Toggle with F3. Sliders/checkboxes write straight to the ragdoll each change, so you can
## dial the physics from "hugs the clip" (high anim_authority) to floppy while playing.

# name, min, max — ranges for the sliders (ActiveRagdoll float properties).
# Velocity drive (default): track_* = the only knobs that matter (1 = clip-exact, lower =
# looser physics). max_* clamp correction speed = how violently it recovers. Torque-PD gains
# below only apply with use_velocity_drive OFF (legacy fallback).
const FLOATS := [
	{"n": "track_position", "lo": 0.0, "hi": 1.0},
	{"n": "track_rotation", "lo": 0.0, "hi": 1.0},
	{"n": "max_lin_speed", "lo": 0.0, "hi": 30.0},
	{"n": "max_ang_speed", "lo": 0.0, "hi": 100.0},
	{"n": "snap_distance", "lo": 0.1, "hi": 3.0},
	{"n": "anim_authority", "lo": 0.0, "hi": 3.0},   # torque mode: master stiffness
	{"n": "limb_rot_kp", "lo": 0.0, "hi": 600.0},    # torque mode: limb pose stiffness
	{"n": "limb_rot_kd", "lo": 0.0, "hi": 80.0},
	{"n": "root_pos_kp", "lo": 0.0, "hi": 20000.0},
	{"n": "root_pos_kd", "lo": 0.0, "hi": 600.0},
	{"n": "root_rot_kp", "lo": 0.0, "hi": 2000.0},
	{"n": "root_rot_kd", "lo": 0.0, "hi": 150.0},
]
const BOOLS := ["simulating", "pd_enabled", "use_velocity_drive", "foot_ik_enabled", "use_procedural_walk"]

var ragdoll: Node


func setup(rag: Node) -> void:
	ragdoll = rag
	layer = 10
	visible = false
	_build()


func _build() -> void:
	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	panel.position = Vector2(8, 8)
	panel.custom_minimum_size = Vector2(360, 640)
	add_child(panel)

	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 10)
	panel.add_child(margin)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(340, 620)
	margin.add_child(scroll)

	var vb := VBoxContainer.new()
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(vb)

	var title := Label.new()
	title.text = "ANIM / RAGDOLL PARAMS   —   F3 to close"
	vb.add_child(title)

	var print_btn := Button.new()
	print_btn.text = "Print Values -> Output Log"
	print_btn.pressed.connect(_print_values)
	vb.add_child(print_btn)

	for bn in BOOLS:
		vb.add_child(_make_bool(bn))

	for f in FLOATS:
		vb.add_child(_make_slider(f["n"], f["lo"], f["hi"]))


func _make_bool(bn: String) -> CheckButton:
	var cb := CheckButton.new()
	cb.text = bn
	# `== true` instead of bool(): get() returns null when the property doesn't exist yet
	# (e.g. DLL older than this menu), and bool(null) is a nonexistent-constructor error.
	cb.button_pressed = ragdoll.get(bn) == true
	cb.toggled.connect(_on_bool.bind(bn))
	return cb


func _make_slider(pname: String, lo: float, hi: float) -> VBoxContainer:
	var row := VBoxContainer.new()
	var lbl := Label.new()
	var cur := float(ragdoll.get(pname))
	lbl.text = "%s = %.2f" % [pname, cur]
	row.add_child(lbl)

	var s := HSlider.new()
	s.min_value = lo
	s.max_value = hi
	s.step = (hi - lo) / 400.0
	s.value = cur
	s.custom_minimum_size = Vector2(330, 0)
	s.value_changed.connect(_on_float.bind(pname, lbl))
	row.add_child(s)
	return row


func _on_bool(pressed: bool, bn: String) -> void:
	if ragdoll != null:
		ragdoll.set(bn, pressed)


func _on_float(v: float, pname: String, lbl: Label) -> void:
	if ragdoll != null:
		ragdoll.set(pname, v)
	lbl.text = "%s = %.2f" % [pname, v]


func _print_values() -> void:
	if ragdoll == null:
		return
	var lines := ["=== ActiveRagdoll values ==="]
	for bn in BOOLS:
		lines.append("%s = %s" % [bn, str(ragdoll.get(bn))])
	for f in FLOATS:
		lines.append("%s = %.3f" % [f["n"], float(ragdoll.get(f["n"]))])
	print("\n".join(lines))


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F3:
		visible = not visible
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if visible else Input.MOUSE_MODE_CAPTURED
		get_viewport().set_input_as_handled()
