extends MenuScreen
## The options screen. Renders `MenuSettings` — it holds no settings knowledge of its own, so a
## game that deletes half the table gets a half-size options screen with no edits here.
##
## One screen, two lives: pushed as a scene from the main menu, or added as a child overlay by
## the pause menu (`overlay_mode`). Both use the same instance and the same Back path, because
## an options screen that behaves differently mid-run is where "the sliders don't apply while
## paused" bugs come from.
##
## Categories are a `TabBar` on a wide screen and a dropdown on a narrow one. That is the one
## place a control genuinely cannot be made to fit by shrinking: eight tabs at 1.75x text on a
## 640px window would either clip or scroll horizontally, and a dropdown is neither.

## Set before adding to the tree: Back frees this node instead of changing scene.
var overlay_mode := false
## Optional override for what Back does. Takes precedence over `overlay_mode`.
var back_action: Callable = Callable()

var _tab_bar: TabBar
var _tab_picker: OptionButton
var _pages: Dictionary = {}      ## tab id -> VBoxContainer
var _rows: Dictionary = {}       ## setting id -> OptionRow
var _keybind_rows: Array[KeybindRow] = []
var _tab_ids: Array = []
var _current := 0
var _narrow := false


func _init() -> void:
	screen_title = "Options"


func _build_content() -> void:
	_tab_ids = MenuSettings.tabs()
	for extra in MenuHost.extra_option_tabs():
		_tab_ids.append(extra)

	# The category switcher lives in the header, next to the title, so it never scrolls away.
	var picker_host := HBoxContainer.new()
	picker_host.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	picker_host.alignment = BoxContainer.ALIGNMENT_END
	header.add_child(picker_host)

	_tab_bar = TabBar.new()
	# clip_tabs keeps the bar inside its box and gives scroll arrows instead of overflowing.
	_tab_bar.clip_tabs = true
	_tab_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tab_bar.tab_changed.connect(_show_tab)
	picker_host.add_child(_tab_bar)

	_tab_picker = MenuFit.fit_button(OptionButton.new()) as OptionButton
	_tab_picker.fit_to_longest_item = false
	_tab_picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tab_picker.item_selected.connect(_show_tab)
	_tab_picker.visible = false
	picker_host.add_child(_tab_picker)

	for i in _tab_ids.size():
		var title := _tab_title(_tab_ids[i])
		_tab_bar.add_tab(title)
		_tab_picker.add_item(title, i)

	for tab in _tab_ids:
		content.add_child(_build_page(tab))

	_build_footer()
	if not MenuSettings.changed.is_connected(_on_setting_changed_row):
		MenuSettings.changed.connect(_on_setting_changed_row)
	_show_tab(0)
	_refresh_dependencies()


## Freeing a node disconnects it automatically, so this is not a leak fix — it is a correctness
## one. Options can be closed while a slider is still settling, and a handler that runs against a
## half-freed row is a crash the player sees as "the game died when I hit Back".
func _exit_tree() -> void:
	super()
	if MenuSettings.changed.is_connected(_on_setting_changed_row):
		MenuSettings.changed.disconnect(_on_setting_changed_row)


func _tab_title(tab: Variant) -> String:
	if tab is Dictionary:
		return String((tab as Dictionary).get("title", "More"))
	return MenuSettings.tab_title(String(tab))


func _tab_key(tab: Variant) -> String:
	if tab is Dictionary:
		return "host_" + _tab_title(tab)
	return String(tab)


func _build_page(tab: Variant) -> VBoxContainer:
	var page := VBoxContainer.new()
	page.name = _tab_key(tab).validate_node_name()
	page.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	page.add_theme_constant_override("separation", 12)
	_pages[_tab_key(tab)] = page

	if tab is Dictionary:
		var build: Callable = (tab as Dictionary).get("build", Callable())
		if build.is_valid():
			build.call(page)
		return page

	var tab_id := String(tab)
	for d in MenuSettings.defs_for(tab_id):
		var row := OptionRow.create(d)
		page.add_child(row)
		_rows[(d as Dictionary)["id"]] = row

	if tab_id == "controls":
		_build_keybinds(page)
	return page


func _build_keybinds(page: VBoxContainer) -> void:
	page.add_child(HSeparator.new())
	var head := Label.new()
	head.text = "Key Bindings"
	head.add_theme_font_size_override("font_size", MenuTheme.font_size(1.2))
	MenuFit.fit_label(head, false)
	page.add_child(head)

	var note := Label.new()
	note.text = "Click a binding, then press the key or button. Right-click a binding to clear it."
	MenuFit.fit_label(note)
	note.add_theme_color_override("font_color", MenuTheme.text_dim)
	note.add_theme_font_size_override("font_size", MenuTheme.font_size(0.82))
	page.add_child(note)

	for action in MenuSettings.rebindable_actions():
		var row := KeybindRow.create(action)
		page.add_child(row)
		_keybind_rows.append(row)

	var reset_all := MenuFit.fit_button(Button.new())
	reset_all.text = "Reset All Bindings"
	reset_all.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	reset_all.pressed.connect(func() -> void:
		var m := MenuModal.ask(self, "Reset bindings?",
				"Every key and gamepad binding returns to the game's defaults.",
				"Reset", "Cancel", true)
		m.confirmed.connect(func() -> void:
			MenuSettings.reset_all_bindings()
			for r in _keybind_rows:
				r.refresh()))
	page.add_child(reset_all)


func _build_footer() -> void:
	var reset_tab := MenuFit.fit_button(Button.new())
	reset_tab.text = "Reset This Tab"
	reset_tab.pressed.connect(_on_reset_tab)
	footer.add_child(reset_tab)

	var reset_all := MenuFit.fit_button(Button.new())
	reset_all.text = "Reset Everything"
	reset_all.pressed.connect(_on_reset_all)
	footer.add_child(reset_all)

	var back := MenuFit.fit_button(Button.new())
	back.text = "Back"
	back.custom_minimum_size = Vector2(120, 42)
	back.add_theme_stylebox_override("normal", MenuTheme.primary_box())
	back.pressed.connect(func() -> void: _on_back())
	footer.add_child(back)


# =====================================================================
# Tabs
# =====================================================================
## `add_tab()` fires `tab_changed` while the bar is still being filled, so this runs once before
## any page exists. Bail until the pages are there rather than indexing an empty dictionary.
func _show_tab(index: int) -> void:
	if _tab_ids.is_empty() or _pages.size() < _tab_ids.size():
		return
	_current = clampi(index, 0, _tab_ids.size() - 1)
	for i in _tab_ids.size():
		var page: VBoxContainer = _pages[_tab_key(_tab_ids[i])]
		page.visible = (i == _current)
	if _tab_bar.current_tab != _current:
		_tab_bar.current_tab = _current
	if _tab_picker.selected != _current:
		_tab_picker.select(_current)
	# A tab switch starts at the top; carrying the previous tab's scroll offset lands the
	# player halfway down a shorter page with no visible reason why.
	body.scroll_vertical = 0


# =====================================================================
# Dependent rows — a control that cannot do anything is disabled, not silently inert
# =====================================================================
func _on_setting_changed_row(id: StringName, _value: Variant) -> void:
	if id == &"display_mode" or id == &"colorblind_mode" or id == &"render_scale" \
			or id == &"mute" or id == &"monitor":
		_refresh_dependencies()
	# Another surface (the pause menu's quick sliders) may have changed this — keep in sync.
	var row: OptionRow = _rows.get(id)
	if row != null:
		row.refresh()


func _refresh_dependencies() -> void:
	_set_enabled(&"resolution", int(MenuSettings.get_value(&"display_mode")) == 0)
	_set_enabled(&"filter_strength", int(MenuSettings.get_value(&"colorblind_mode")) != 0)
	_set_enabled(&"scaling_mode", float(MenuSettings.get_value(&"render_scale")) < 0.999)
	var unmuted := not MenuSettings.get_bool(&"mute")
	for bus_id in [&"vol_master", &"vol_music", &"vol_sfx", &"vol_ui", &"vol_voice"]:
		_set_enabled(bus_id, unmuted)
	if _rows.has(&"resolution"):
		(_rows[&"resolution"] as OptionRow).refresh()   # monitor change re-filters the list


func _set_enabled(id: StringName, on: bool) -> void:
	var row: OptionRow = _rows.get(id)
	if row != null:
		row.set_row_enabled(on)


# =====================================================================
# Footer actions
# =====================================================================
func _on_reset_tab() -> void:
	var tab: Variant = _tab_ids[_current]
	if tab is Dictionary:
		return
	var m := MenuModal.ask(self, "Reset %s?" % _tab_title(tab),
			"Every setting on this tab returns to its default.", "Reset", "Cancel", true)
	m.confirmed.connect(func() -> void:
		MenuSettings.reset_tab(String(tab))
		_refresh_all_rows())


func _on_reset_all() -> void:
	var m := MenuModal.ask(self, "Reset everything?",
			"Every option on every tab, plus all key bindings, returns to the game's defaults.",
			"Reset Everything", "Cancel", true)
	m.confirmed.connect(func() -> void:
		MenuSettings.reset_all()
		MenuSettings.reset_all_bindings()
		_refresh_all_rows())


func _refresh_all_rows() -> void:
	for r in _rows.values():
		(r as OptionRow).refresh()
	for k in _keybind_rows:
		k.refresh()
	_refresh_dependencies()


# =====================================================================
# Responsive + navigation
# =====================================================================
func _on_relayout(vp_size: Vector2) -> void:
	var narrow := MenuFit.is_narrow(vp_size)
	if _tab_bar != null:
		_tab_bar.visible = not narrow
		_tab_picker.visible = narrow
	if narrow == _narrow:
		return
	_narrow = narrow
	for r in _rows.values():
		(r as OptionRow).set_narrow(narrow)
	for k in _keybind_rows:
		k.set_narrow(narrow)


func _first_focus() -> Control:
	return _tab_bar if _tab_bar != null and _tab_bar.visible else _tab_picker


func _on_back() -> bool:
	MenuSettings.save_now()
	if back_action.is_valid():
		back_action.call()
		return true
	if overlay_mode:
		queue_free()
		return true
	get_tree().change_scene_to_file(MenuHost.main_menu_scene())
	return true
