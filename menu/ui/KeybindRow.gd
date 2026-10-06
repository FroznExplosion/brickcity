class_name KeybindRow
extends VBoxContainer
## One rebindable action: its name and two binding slots (primary and alternate), each a button
## that captures the next thing you press.
##
## Two slots rather than a growable list, on purpose — it is the shape every player already
## knows, it maps cleanly onto "keyboard binding + gamepad binding", and it makes the row a
## fixed width, which is what lets the controls tab obey the same no-overflow rule as the rest.
##
## Keys are stored by PHYSICAL keycode. A binding made on AZERTY then stays under the same
## finger on QWERTY, which is what a player means by "W is forward".

const SLOTS := 2

var action: StringName
var _row: HBoxContainer
var _label: Label
var _slots: Array[Button] = []
var _reset: Button
var _capturing := -1          ## slot index being captured, -1 = idle
var _modal: MenuModal = null
var _narrow := false

signal rebound(action: StringName)


static func create(for_action: StringName) -> KeybindRow:
	var r := KeybindRow.new()
	r.action = for_action
	return r


func _ready() -> void:
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 2)
	set_process_input(false)
	_build()
	refresh()
	if not MenuSettings.bindings_changed.is_connected(refresh):
		MenuSettings.bindings_changed.connect(refresh)


func _exit_tree() -> void:
	if MenuSettings.bindings_changed.is_connected(refresh):
		MenuSettings.bindings_changed.disconnect(refresh)
	# A row torn down mid-capture would otherwise leave `_input` live on a freed node.
	if _capturing >= 0:
		_close_modal()
		_capturing = -1
		set_process_input(false)


func _build() -> void:
	_row = HBoxContainer.new()
	_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_row.add_theme_constant_override("separation", 10)
	add_child(_row)

	_label = Label.new()
	_label.text = MenuSettings.action_label(action)
	MenuFit.fit_label(_label)
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_label.size_flags_stretch_ratio = 2.0
	_row.add_child(_label)

	for i in SLOTS:
		var b := MenuFit.fit_button(Button.new())
		b.custom_minimum_size = Vector2(96, 34)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.size_flags_stretch_ratio = 1.5
		b.tooltip_text = "Click, then press the key or button to bind. Right-click to clear."
		b.pressed.connect(_begin_capture.bind(i))
		b.gui_input.connect(_slot_gui_input.bind(i))
		_row.add_child(b)
		_slots.append(b)

	_reset = MenuFit.fit_button(Button.new())
	_reset.text = "Reset"
	_reset.add_theme_font_size_override("font_size", MenuTheme.font_size(0.8))
	_reset.size_flags_horizontal = Control.SIZE_SHRINK_END
	_reset.pressed.connect(_on_reset)
	_row.add_child(_reset)


func refresh() -> void:
	var events := MenuSettings.events_for(action)
	for i in SLOTS:
		var text := "—"
		if i < events.size() and events[i] != null:
			text = describe_event(events[i])
		_slots[i].text = text
	_reset.visible = not _matches_default()


func _matches_default() -> bool:
	var current := MenuSettings.events_for(action)
	var defaults: Array = MenuSettings.default_events_for(action)
	if current.size() != defaults.size():
		return false
	for i in current.size():
		if not current[i].is_match(defaults[i], true):
			return false
	return true


## Short, player-facing name for a binding. `as_text()` alone yields things like
## "W (Physical)" and "Joypad Button 0 (Bottom Action, Sony Cross...)" — too long for a button.
static func describe_event(e: InputEvent) -> String:
	if e is InputEventKey:
		var k := e as InputEventKey
		var code := k.physical_keycode if k.physical_keycode != 0 else k.keycode
		# A physical binding is shown with the LABEL currently on that key, so a French
		# keyboard reads "Z" where a US one reads "W" for the same binding. The lookup needs a
		# real display server, so headless (and any platform without it) shows the raw key.
		if k.physical_keycode != 0 and DisplayServer.get_name() != "headless":
			var mapped := DisplayServer.keyboard_get_keycode_from_physical(code)
			var label := OS.get_keycode_string(mapped)
			if label != "":
				return label
		return OS.get_keycode_string(code)
	if e is InputEventMouseButton:
		var mb := e as InputEventMouseButton
		match mb.button_index:
			MOUSE_BUTTON_LEFT: return "Mouse Left"
			MOUSE_BUTTON_RIGHT: return "Mouse Right"
			MOUSE_BUTTON_MIDDLE: return "Mouse Middle"
			MOUSE_BUTTON_WHEEL_UP: return "Wheel Up"
			MOUSE_BUTTON_WHEEL_DOWN: return "Wheel Down"
			_: return "Mouse %d" % mb.button_index
	if e is InputEventJoypadButton:
		return "Pad %d" % (e as InputEventJoypadButton).button_index
	if e is InputEventJoypadMotion:
		var jm := e as InputEventJoypadMotion
		return "Axis %d%s" % [jm.axis, "+" if jm.axis_value > 0.0 else "-"]
	return e.as_text()


# =====================================================================
# Capture
# =====================================================================
func _begin_capture(slot: int) -> void:
	if _capturing >= 0:
		return
	_capturing = slot
	set_process_input(true)
	var screen := _owning_screen()
	if screen != null:
		_modal = MenuModal.prompt(screen, "Bind “%s”" % MenuSettings.action_label(action),
				"Press a key, mouse button or gamepad button.\nEscape cancels.")
		_modal.cancelled.connect(_cancel_capture)


func _cancel_capture() -> void:
	_capturing = -1
	set_process_input(false)
	_modal = null
	refresh()


func _slot_gui_input(event: InputEvent, slot: int) -> void:
	# Right-click clears a slot without opening the capture prompt.
	if event is InputEventMouseButton and event.pressed \
			and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_RIGHT:
		MenuSettings.unbind(action, slot)
		refresh()
		rebound.emit(action)
		accept_event()


## Runs at `_input` priority so the captured press never also fires the action it is bound to.
func _input(event: InputEvent) -> void:
	if _capturing < 0:
		return
	if event.is_echo() or not event.is_pressed():
		return
	if event is InputEventKey and (event as InputEventKey).keycode == KEY_ESCAPE:
		_close_modal()
		_cancel_capture()
		get_viewport().set_input_as_handled()
		return
	var clean := _normalise(event)
	if clean == null:
		return
	get_viewport().set_input_as_handled()
	var slot := _capturing
	_close_modal()
	_capturing = -1
	set_process_input(false)
	_apply_binding(slot, clean)


## Strip the runtime state off a captured event so what gets stored is the BINDING (which key)
## and not the moment (where the mouse was, which pad, whether it was a double click).
func _normalise(event: InputEvent) -> InputEvent:
	if event is InputEventKey:
		var src := event as InputEventKey
		var k := InputEventKey.new()
		k.physical_keycode = src.physical_keycode if src.physical_keycode != 0 else src.keycode
		k.keycode = 0
		k.alt_pressed = src.alt_pressed
		k.shift_pressed = src.shift_pressed
		k.ctrl_pressed = src.ctrl_pressed
		k.meta_pressed = src.meta_pressed
		return k
	if event is InputEventMouseButton:
		var src2 := event as InputEventMouseButton
		var m := InputEventMouseButton.new()
		m.button_index = src2.button_index
		return m
	if event is InputEventJoypadButton:
		var src3 := event as InputEventJoypadButton
		var j := InputEventJoypadButton.new()
		j.button_index = src3.button_index
		j.device = -1     # any pad
		return j
	if event is InputEventJoypadMotion:
		var src4 := event as InputEventJoypadMotion
		if absf(src4.axis_value) < 0.6:
			return null   # stick drift is not a binding
		var a := InputEventJoypadMotion.new()
		a.axis = src4.axis
		a.axis_value = 1.0 if src4.axis_value > 0.0 else -1.0
		a.device = -1
		return a
	return null


func _apply_binding(slot: int, event: InputEvent) -> void:
	var clashes := MenuSettings.conflicts_for(action, event)
	if clashes.is_empty():
		MenuSettings.rebind(action, event, slot)
		refresh()
		rebound.emit(action)
		return
	var names: Array[String] = []
	for c in clashes:
		names.append(MenuSettings.action_label(c))
	var screen := _owning_screen()
	if screen == null:
		return
	var m := MenuModal.ask(screen, "Already bound",
			"%s is already used by %s.\nBind it here and clear it there?"
					% [describe_event(event), ", ".join(names)],
			"Rebind", "Cancel")
	m.confirmed.connect(func() -> void:
		for c in clashes:
			MenuSettings.unbind_event(c, event)
		MenuSettings.rebind(action, event, slot)
		refresh()
		rebound.emit(action))
	m.cancelled.connect(refresh)


func _close_modal() -> void:
	if is_instance_valid(_modal):
		_modal.queue_free()
	_modal = null


func _on_reset() -> void:
	MenuSettings.reset_action(action)
	refresh()
	rebound.emit(action)


## Nearest MenuScreen ancestor — modals parent to it so they cover the whole screen and inherit
## its safe-area scaffold.
func _owning_screen() -> Node:
	var n: Node = get_parent()
	while n != null:
		if n is MenuScreen:
			return n
		n = n.get_parent()
	return get_tree().current_scene if get_tree() != null else null


func set_narrow(narrow: bool) -> void:
	if narrow == _narrow:
		return
	_narrow = narrow
	if narrow:
		_row.remove_child(_label)
		add_child(_label)
		move_child(_label, 0)
	else:
		remove_child(_label)
		_row.add_child(_label)
		_row.move_child(_label, 0)
	_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_label.size_flags_stretch_ratio = 2.0
