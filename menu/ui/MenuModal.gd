class_name MenuModal
extends MenuScreen
## Confirmations, warnings and the key-capture prompt. Deliberately NOT a `Window`/`AcceptDialog`:
## an OS popup is positioned in desktop coordinates, so it ignores the safe area, ignores the
## interface scale, and on a small display can open partly off-screen — the exact failure this
## module is built to prevent. A modal here is just another `MenuScreen`, so it inherits the
## same scaffold, the same scroll escape valve and the same fit guarantee.
##
##     var m := MenuModal.ask(self, "Quit?", "Unsaved progress is lost.", "Quit", "Stay")
##     m.confirmed.connect(_do_quit)

signal confirmed
signal cancelled

var message: String = ""
var ok_text: String = "OK"
var cancel_text: String = "Cancel"
## Style the confirm button as destructive (red).
var destructive: bool = false
## Hide the confirm button entirely — a prompt that can only be dismissed (key capture).
var prompt_only: bool = false

var _panel: PanelContainer
var _message_label: Label
var _ok: Button
var _cancel: Button


## Build, parent and show a confirmation. `parent` is normally the screen that raised it.
static func ask(parent: Node, title: String, msg: String, ok: String = "OK",
		cancel: String = "Cancel", destructive_action: bool = false) -> MenuModal:
	var m := MenuModal.new()
	m.screen_title = ""
	m.dim_backdrop = true
	m.opaque_backdrop = false
	m.message = msg
	m.ok_text = ok
	m.cancel_text = cancel
	m.destructive = destructive_action
	m.set_meta("heading", title)
	parent.add_child(m)
	return m


## A prompt with no confirm button — dismissed by the caller or by Escape.
static func prompt(parent: Node, title: String, msg: String, cancel: String = "Cancel") -> MenuModal:
	var m := ask(parent, title, msg, "", cancel)
	m.prompt_only = true
	return m


func _build_content() -> void:
	var center := CenterContainer.new()
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	center.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_child(center)

	_panel = PanelContainer.new()
	# A cap, not a fixed width: the panel shrinks below this on a narrow screen.
	_panel.custom_minimum_size = Vector2(0, 0)
	center.add_child(_panel)

	var pad := MarginContainer.new()
	for side in ["left", "right"]:
		pad.add_theme_constant_override("margin_" + side, 22)
	for side in ["top", "bottom"]:
		pad.add_theme_constant_override("margin_" + side, 18)
	_panel.add_child(pad)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 14)
	pad.add_child(col)

	var heading := Label.new()
	heading.text = String(get_meta("heading", ""))
	heading.add_theme_font_size_override("font_size", MenuTheme.font_size(1.35))
	MenuFit.fit_label(heading)
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(heading)

	_message_label = Label.new()
	_message_label.text = message
	MenuFit.fit_label(_message_label)
	_message_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(_message_label)

	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	buttons.add_theme_constant_override("separation", 12)
	col.add_child(buttons)

	if not prompt_only and ok_text != "":
		_ok = MenuFit.fit_button(Button.new())
		_ok.text = ok_text
		_ok.custom_minimum_size = Vector2(110, 40)
		if destructive:
			var box := MenuTheme.primary_box()
			box.bg_color = MenuTheme.danger.darkened(0.45)
			box.border_color = MenuTheme.danger
			_ok.add_theme_stylebox_override("normal", box)
		_ok.pressed.connect(_accept)
		buttons.add_child(_ok)

	if cancel_text != "":
		_cancel = MenuFit.fit_button(Button.new())
		_cancel.text = cancel_text
		_cancel.custom_minimum_size = Vector2(110, 40)
		_cancel.pressed.connect(_reject)
		buttons.add_child(_cancel)


func _on_relayout(vp_size: Vector2) -> void:
	if _panel != null:
		# Wide enough to read, never wider than the space actually available.
		_panel.custom_minimum_size = Vector2(minf(560.0, available_width(vp_size)), 0)


func _first_focus() -> Control:
	if _cancel != null:
		return _cancel
	return _ok


## Escape cancels — and is consumed, so it does not also close the screen underneath.
func _on_back() -> bool:
	_reject()
	return true


func set_message(text: String) -> void:
	message = text
	if _message_label != null:
		_message_label.text = text


func _accept() -> void:
	confirmed.emit()
	queue_free()


func _reject() -> void:
	cancelled.emit()
	queue_free()
