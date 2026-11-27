class_name SequencerPanel
extends PanelContainer
## The SEQUENCER's program editor (Docs/MineWiring.md 24): opened by RMB on a
## sequencer (whatever is in the hand but the wrench, whose RMB turns it).
## A row of steps -- ticks on, off, on, ... (a tick is 0.1 s) -- each a number
## box; + and - add or take the last step; the presets set one of PROGRAMS.
## Every change is the sequencer's at once (`MineWiring.set_program`, saved
## with the world). Escape or Done closes it.
##
## While open the mouse is free and the builder takes no clicks (the mine
## world's `inventory_open` says so); closing puts the mouse back as it was.

## The mine world (untyped: it holds this) and the sequencer edited.
var host: Node = null
var wiring: MineWiring = null
var cell := Vector3i.ZERO
var _layer: CanvasLayer = null
var _steps_box: HBoxContainer = null
var _title: Label = null
var _prev_mouse := Input.MOUSE_MODE_VISIBLE
var _cam_captured := false
var _walker_frozen := false


## Opens the panel on sequencer `c` over the host's screen. Returns it.
static func open_on(p_host: Node, p_wiring: MineWiring, c: Vector3i) -> SequencerPanel:
	var p := SequencerPanel.new()
	p.host = p_host
	p.wiring = p_wiring
	p.cell = c
	var layer := CanvasLayer.new()
	layer.name = "SequencerLayer"
	layer.layer = 70
	layer.process_mode = Node.PROCESS_MODE_ALWAYS
	p_host.add_child(layer)
	p._layer = layer
	p._build()
	layer.add_child(p)
	p._grab_mouse()
	return p


## The panel's controls (made before it enters the tree, so a probe without
## frames has them).
func _build() -> void:
	name = "SequencerPanel"
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_anchors_preset(Control.PRESET_CENTER)
	custom_minimum_size = Vector2(520, 0)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	add_child(box)
	_title = Label.new()
	_title.add_theme_font_size_override("font_size", 18)
	box.add_child(_title)
	var help := Label.new()
	help.text = "Ticks on, off, on, ... (10 ticks = 1 s). Runs once each time its back turns on."
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(help)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 76)
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(scroll)
	_steps_box = HBoxContainer.new()
	_steps_box.add_theme_constant_override("separation", 6)
	scroll.add_child(_steps_box)
	var row := HBoxContainer.new()
	box.add_child(row)
	_button(row, "+ step", func(): _add_step())
	_button(row, "- step", func(): _take_step())
	var presets := HBoxContainer.new()
	box.add_child(presets)
	var pl := Label.new()
	pl.text = "Presets:"
	presets.add_child(pl)
	for i in MineWiring.PROGRAMS.size():
		var prog: Array = MineWiring.PROGRAMS[i]
		var b := _button(presets, ",".join(prog.map(func(v): return str(v))), func(): _preset(i))
		b.tooltip_text = "ticks on, off, on, ..."
	var done := _button(box, "Done (Esc)", func(): close())
	done.size_flags_horizontal = Control.SIZE_SHRINK_END
	_fill()


func _ready() -> void:
	# Centred once its size is known.
	reset_size()
	position = (get_viewport_rect().size - size) * 0.5


func _button(parent: Control, text: String, f: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(f)
	parent.add_child(b)
	return b


## The steps as number boxes, from the sequencer's program.
func _fill() -> void:
	for ch in _steps_box.get_children():
		_steps_box.remove_child(ch)
		ch.free()
	var prog := wiring.program_of(cell)
	var own: bool = wiring.devices.has(cell) and wiring.devices[cell].has("program")
	_title.text = "Sequencer -- %s, %d steps, %.1f s" % ["its own program" if own else "a preset",
			prog.size(), prog.reduce(func(a, v): return a + int(v), 0) / 10.0]
	for i in prog.size():
		var col := VBoxContainer.new()
		var lab := Label.new()
		lab.text = "on" if i % 2 == 0 else "off"
		lab.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lab.modulate = Color(1.0, 0.55, 0.3) if i % 2 == 0 else Color(0.7, 0.7, 0.75)
		col.add_child(lab)
		var sb := SpinBox.new()
		sb.name = "Step%d" % i
		sb.min_value = 1
		sb.max_value = MineWiring.STEP_MAX
		sb.value = int(prog[i])
		sb.custom_minimum_size = Vector2(64, 0)
		sb.value_changed.connect(func(_v): _apply())
		col.add_child(sb)
		_steps_box.add_child(col)


## The boxes' numbers, in order.
func steps() -> Array:
	var out := []
	for col in _steps_box.get_children():
		for ch in col.get_children():
			if ch is SpinBox:
				out.append(int((ch as SpinBox).value))
	return out


func _apply() -> void:
	wiring.set_program(cell, steps())
	_fill_title()


func _fill_title() -> void:
	var prog := wiring.program_of(cell)
	_title.text = "Sequencer -- its own program, %d steps, %.1f s" % [prog.size(),
			prog.reduce(func(a, v): return a + int(v), 0) / 10.0]


func _add_step() -> void:
	var s := steps()
	if s.size() >= MineWiring.PROGRAM_STEPS:
		return
	s.append(5)
	wiring.set_program(cell, s)
	_fill()


func _take_step() -> void:
	var s := steps()
	if s.size() <= 1:
		return
	s.pop_back()
	wiring.set_program(cell, s)
	_fill()


func _preset(i: int) -> void:
	wiring.set_preset(cell, i)
	_fill()


## Gate and probe: the program set as if typed into the boxes.
func type_steps(values: Array) -> void:
	wiring.set_program(cell, values)
	_fill()


func _input(event: InputEvent) -> void:
	# Escape before the mine world's pause menu takes it.
	if event is InputEventKey and event.pressed and not event.echo and (event as InputEventKey).keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		close()


func _process(_delta: float) -> void:
	# The sequencer gone (shot, blown, taken): nothing to edit.
	if wiring == null or not is_instance_valid(wiring) or not wiring.devices.has(cell):
		close()


func _grab_mouse() -> void:
	_prev_mouse = Input.mouse_mode
	var cam = host.get("cam")
	_cam_captured = cam != null and bool(cam.get("_captured"))
	if cam != null and cam.has_method("_set_captured"):
		cam._set_captured(false)
	var walker = host.get("walker")
	if walker != null:
		_walker_frozen = bool(walker.frozen)
		if not bool(host.get("on_foot")):
			walker.frozen = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func is_open() -> bool:
	return is_inside_tree() and not is_queued_for_deletion()


func close() -> void:
	if not is_open():
		return
	var walker = host.get("walker") if host != null else null
	if walker != null:
		walker.frozen = _walker_frozen
	if host != null and host.has_method("sequencer_closed"):
		host.sequencer_closed(self)
	if not PlayerCamera.hands_off:
		var cam = host.get("cam") if host != null else null
		if _cam_captured and cam != null:
			cam._set_captured(true)
		elif _prev_mouse == Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if _layer != null:
		_layer.queue_free()
	else:
		queue_free()
