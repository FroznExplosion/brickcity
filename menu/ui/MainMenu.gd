extends MenuScreen
## The front end. Everything on it above Options comes from `MenuHost.main_menu_entries()`, so
## this file knows nothing about the game it is fronting and ports unchanged.
##
## Options opens as an OVERLAY (a child of this screen), not a scene change. Two reasons: the
## main menu keeps its state and its music, and the exact same code path is what the pause menu
## uses mid-run — one options screen with one behaviour, rather than two that drift.

const COLUMN_WIDTH := 380.0

var _column: VBoxContainer
var _hero: VBoxContainer
var _columns: HBoxContainer
var _subtitle: Label
var _options: Node = null


func _init() -> void:
	screen_title = ""   # the brand is drawn in the body, larger than a header title


func _build_content() -> void:
	_columns = HBoxContainer.new()
	_columns.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_columns.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_columns.add_theme_constant_override("separation", 32)
	content.add_child(_columns)

	# ---- Left: brand + buttons ----
	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left.add_theme_constant_override("separation", 10)
	_columns.add_child(left)

	_hero = VBoxContainer.new()
	_hero.add_theme_constant_override("separation", 2)
	left.add_child(_hero)

	var brand := Label.new()
	brand.name = "Brand"
	brand.text = MenuHost.game_title()
	MenuFit.fit_label(brand, false)
	brand.add_theme_font_size_override("font_size", MenuTheme.font_size(3.0))
	_hero.add_child(brand)

	_subtitle = Label.new()
	_subtitle.text = MenuHost.game_subtitle()
	MenuFit.fit_label(_subtitle)
	_subtitle.add_theme_color_override("font_color", MenuTheme.text_dim)
	_subtitle.visible = _subtitle.text != ""
	_hero.add_child(_subtitle)

	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 18)
	left.add_child(gap)

	_column = VBoxContainer.new()
	_column.name = "Buttons"
	_column.add_theme_constant_override("separation", 8)
	_column.size_flags_horizontal = Control.SIZE_FILL
	left.add_child(_column)
	_build_buttons()

	# ---- Right: empty on purpose. A game drops key art or a rotating 3D scene in here; an
	# empty expanding spacer is what makes the column layout responsive without one.
	var right := Control.new()
	right.name = "ArtSlot"
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_columns.add_child(right)

	var version := Label.new()
	version.text = MenuHost.game_version()
	version.add_theme_color_override("font_color", MenuTheme.text_dim)
	version.add_theme_font_size_override("font_size", MenuTheme.font_size(0.85))
	MenuFit.fit_label(version, false)
	version.visible = version.text != ""
	footer.add_child(version)


func _build_buttons() -> void:
	for c in _column.get_children():
		c.queue_free()

	if MenuHost.has_continue():
		_add_button("Continue", func() -> void: MenuHost.continue_game(), true)

	for e in MenuHost.main_menu_entries():
		var entry: Dictionary = e
		var b := _add_button(String(entry.get("label", "?")),
				entry.get("action", Callable()), bool(entry.get("primary", false)))
		b.disabled = bool(entry.get("disabled", false))
		b.tooltip_text = String(entry.get("tooltip", ""))

	_add_button("Options", _open_options)
	if not OS.has_feature("web"):
		_add_button("Quit", _confirm_quit)


func _add_button(text: String, action: Callable, primary: bool = false) -> Button:
	var b := MenuFit.fit_button(Button.new())
	b.text = text
	b.custom_minimum_size = Vector2(0, 46)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.add_theme_font_size_override("font_size", MenuTheme.font_size(1.1))
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
	o.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(o)
	_options = o
	o.tree_exited.connect(func() -> void:
		_options = null
		# Entries can change while Options is open (a mod approved, a save appeared).
		_build_buttons()
		_grab_initial_focus())


func _confirm_quit() -> void:
	var m := MenuModal.ask(self, "Quit to desktop?", "", "Quit", "Stay", true)
	m.confirmed.connect(func() -> void: get_tree().quit())


# =====================================================================
# Responsive
# =====================================================================
func _on_relayout(vp_size: Vector2) -> void:
	if _column == null:
		return
	var narrow := MenuFit.is_narrow(vp_size)
	# The art slot only earns its space when there is space; below that the buttons take the
	# full width rather than being squeezed into a third of a small window.
	_columns.get_node("ArtSlot").visible = not narrow
	_column.custom_minimum_size = Vector2(
			0.0 if narrow else minf(COLUMN_WIDTH, vp_size.x * 0.5), 0.0)
	_hero.visible = not MenuFit.is_short(vp_size) or vp_size.y > 400.0
	var brand := _hero.get_node_or_null("Brand") as Label
	if brand != null:
		brand.add_theme_font_size_override("font_size",
				MenuTheme.font_size(2.0 if MenuFit.is_short(vp_size) else 3.0))


func _first_focus() -> Control:
	for c in _column.get_children():
		if c is Button and not (c as Button).disabled:
			return c
	return null


func _on_back() -> bool:
	if is_instance_valid(_options):
		return false   # the overlay handles its own Back
	_confirm_quit()
	return true
