extends MenuScreen
## The in-run pause menu. Owned and spawned by `MenuManager`, which is also what pauses the tree
## — this screen is only the panel, so a game that wants a different pause trigger replaces the
## manager and keeps the UI.
##
## The three quick settings at the bottom are the ones players actually reach for mid-run, and
## they are the same `OptionRow` widgets bound to the same `MenuSettings` values as the full
## Options screen. Changing volume here and opening Options shows the moved slider, because
## there is only ever one value.

const QUICK_SETTINGS: Array[StringName] = [&"vol_master", &"mouse_sensitivity", &"fov"]

var _column: VBoxContainer
var _panel: PanelContainer
var _options: Node = null
var _quick_rows: Array[OptionRow] = []


func _init() -> void:
	screen_title = ""
	dim_backdrop = true
	opaque_backdrop = false


func _build_content() -> void:
	var center := CenterContainer.new()
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	center.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_child(center)

	_panel = PanelContainer.new()
	center.add_child(_panel)

	var pad := MarginContainer.new()
	for side in ["left", "right"]:
		pad.add_theme_constant_override("margin_" + side, 26)
	for side in ["top", "bottom"]:
		pad.add_theme_constant_override("margin_" + side, 22)
	_panel.add_child(pad)

	_column = VBoxContainer.new()
	_column.add_theme_constant_override("separation", 8)
	pad.add_child(_column)

	var heading := Label.new()
	heading.text = "Paused"
	heading.add_theme_font_size_override("font_size", MenuTheme.font_size(1.9))
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	MenuFit.fit_label(heading, false)
	_column.add_child(heading)
	_column.add_child(HSeparator.new())

	_add_button("Resume", func() -> void: MenuManager.close_pause(), true)

	for e in MenuHost.pause_menu_entries():
		var entry: Dictionary = e
		var b := _add_button(String(entry.get("label", "?")), entry.get("action", Callable()))
		b.disabled = bool(entry.get("disabled", false))
		b.tooltip_text = String(entry.get("tooltip", ""))

	_add_button("Options", _open_options)
	_add_button("Quit to Main Menu", _confirm_to_menu)
	if not OS.has_feature("web"):
		_add_button("Quit to Desktop", _confirm_quit)

	_column.add_child(HSeparator.new())
	var quick_head := Label.new()
	quick_head.text = "Quick Settings"
	quick_head.add_theme_color_override("font_color", MenuTheme.text_dim)
	quick_head.add_theme_font_size_override("font_size", MenuTheme.font_size(0.85))
	MenuFit.fit_label(quick_head, false)
	_column.add_child(quick_head)

	for id in QUICK_SETTINGS:
		var d := MenuSettings.def_of(id)
		if d.is_empty():
			continue   # the host deleted that setting — skip rather than crash
		var row := OptionRow.create(d)
		_column.add_child(row)
		_quick_rows.append(row)


func _add_button(text: String, action: Callable, primary: bool = false) -> Button:
	var b := MenuFit.fit_button(Button.new())
	b.text = text
	b.custom_minimum_size = Vector2(0, 42)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if primary:
		b.add_theme_stylebox_override("normal", MenuTheme.primary_box())
	if action.is_valid():
		b.pressed.connect(action)
	_column.add_child(b)
	return b


func _open_options() -> void:
	if is_instance_valid(_options):
		return
	var scr := load("res://menu/ui/OptionsMenu.gd")
	var o := scr.new() as MenuScreen
	o.set("overlay_mode", true)
	o.opaque_backdrop = true    # opaque over a paused 3D scene: sliders must be readable
	o.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(o)
	_options = o
	o.tree_exited.connect(func() -> void:
		_options = null
		for r in _quick_rows:
			r.refresh()
		_grab_initial_focus())


func _confirm_to_menu() -> void:
	var m := MenuModal.ask(self, "Quit to main menu?",
			"Progress since the last checkpoint is lost.", "Quit", "Stay", true)
	m.confirmed.connect(func() -> void: MenuManager.quit_to_main_menu())


func _confirm_quit() -> void:
	var m := MenuModal.ask(self, "Quit to desktop?",
			"Progress since the last checkpoint is lost.", "Quit", "Stay", true)
	m.confirmed.connect(func() -> void:
		get_tree().paused = false
		get_tree().quit())


func _on_relayout(vp_size: Vector2) -> void:
	if _panel != null:
		_panel.custom_minimum_size = Vector2(minf(420.0, available_width(vp_size)), 0)


func _first_focus() -> Control:
	for c in _column.get_children():
		if c is Button and not (c as Button).disabled:
			return c
	return null


func _on_back() -> bool:
	if is_instance_valid(_options):
		return false
	MenuManager.close_pause()
	return true
