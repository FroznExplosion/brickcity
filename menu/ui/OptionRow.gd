class_name OptionRow
extends VBoxContainer
## One settings row, built from one `MenuSettings.DEFS` entry. The options screen never writes a
## row by hand — it iterates the table and calls `create()` — which is why adding a setting is a
## table edit and porting the module is a table deletion.
##
## Every row obeys the same two width rules, and between them they are why the options screen
## cannot overflow:
##
##   * the **label** expands and shrinks, wrapping then ellipsing; it can never push the row wider
##   * the **editor** has a small minimum and expands into whatever is left
##   * below `MenuFit.NARROW_WIDTH` the row **stacks** — label above, editor below, full width
##
## Reset appears on a row only while its value differs from the default, so the column is empty
## on a fresh install rather than a wall of buttons.

const MIN_EDITOR_WIDTH := 110

var def: Dictionary
var id: StringName

var _row: HBoxContainer
var _label: Label
var _hint: Label
var _editor: Control
var _value_label: Label
var _reset: Button
var _narrow := false
var _updating := false   ## guards the write-back while we are pushing a value INTO the editor

signal value_changed(id: StringName, value: Variant)


static func create(row_def: Dictionary) -> OptionRow:
	var r := OptionRow.new()
	r.def = row_def
	r.id = row_def["id"]
	return r


func _ready() -> void:
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 2)
	_build()
	refresh()


func _build() -> void:
	_row = HBoxContainer.new()
	_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_row.add_theme_constant_override("separation", 10)
	add_child(_row)

	_label = Label.new()
	_label.text = String(def.get("label", String(id)))
	MenuFit.fit_label(_label)
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_label.size_flags_stretch_ratio = 2.0
	_row.add_child(_label)

	_editor = _make_editor()
	_editor.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_editor.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_editor.custom_minimum_size = Vector2(MIN_EDITOR_WIDTH, 0)
	_editor.size_flags_stretch_ratio = 3.0
	_row.add_child(_editor)

	# Sliders show their number; dropdowns and switches already read as their value.
	var t := String(def.get("type", ""))
	if t == MenuSettings.T_SLIDER or t == MenuSettings.T_INT:
		_value_label = Label.new()
		_value_label.custom_minimum_size = Vector2(64, 0)
		_value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		_value_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		MenuFit.fit_label(_value_label, false)
		_value_label.size_flags_horizontal = Control.SIZE_SHRINK_END
		_row.add_child(_value_label)

	_reset = MenuFit.fit_button(Button.new())
	_reset.text = "Reset"
	_reset.tooltip_text = "Restore the default"
	_reset.add_theme_font_size_override("font_size", MenuTheme.font_size(0.8))
	_reset.size_flags_horizontal = Control.SIZE_SHRINK_END
	_reset.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_reset.pressed.connect(_on_reset)
	_row.add_child(_reset)

	var hint_text := String(def.get("hint", ""))
	if hint_text != "":
		_hint = Label.new()
		_hint.text = hint_text
		MenuFit.fit_label(_hint)
		_hint.add_theme_font_size_override("font_size", MenuTheme.font_size(0.82))
		_hint.add_theme_color_override("font_color", MenuTheme.text_dim)
		add_child(_hint)


## Note on `if` rather than `match`: the type tags are constants of the MenuSettings *autoload
## instance*, and GDScript resolves match patterns at parse time. Comparing with `==` is the form
## that actually works across a script boundary.
func _make_editor() -> Control:
	var t := _type()
	if t == MenuSettings.T_BOOL:
		var cb := CheckButton.new()
		cb.toggled.connect(_on_bool_toggled)
		return cb
	if t == MenuSettings.T_SLIDER:
		return _make_slider(float(def.get("min", 0.0)), float(def.get("max", 1.0)),
				float(def.get("step", 0.01)))
	if t == MenuSettings.T_INT:
		return _make_slider(float(def.get("min", 0.0)), float(def.get("max", 100.0)),
				maxf(float(def.get("step", 1.0)), 1.0))
	var ob := OptionButton.new()
	MenuFit.fit_button(ob)
	ob.fit_to_longest_item = false   # a long device name must not widen the row
	ob.item_selected.connect(_on_option_selected)
	return ob


func _type() -> String:
	return String(def.get("type", ""))


func _make_slider(lo: float, hi: float, step: float) -> HSlider:
	var s := HSlider.new()
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.value_changed.connect(_on_slider_changed)
	# Drag writes without touching the disk; the file is written once on release.
	s.drag_ended.connect(_on_slider_drag_ended)
	return s


# =====================================================================
# Dynamic choice lists
# =====================================================================
## Returns [display strings, matching values].
func _choices() -> Array:
	var t := _type()
	var names: Array = []
	var vals: Array = []
	if t == MenuSettings.T_ENUM:
		names = (def.get("choices", []) as Array).duplicate()
		for i in names.size():
			vals.append(i)
	elif t == MenuSettings.T_RESOLUTION:
		var screen := clampi(int(MenuSettings.get_value(&"monitor")), 0,
				maxi(DisplayServer.get_screen_count() - 1, 0))
		var usable := DisplayServer.screen_get_usable_rect(screen)
		for r in MenuSettings.RESOLUTION_CHOICES:
			if r.x <= usable.size.x and r.y <= usable.size.y:
				names.append("%d x %d" % [r.x, r.y])
				vals.append(r)
		var native: Vector2i = usable.size
		if not vals.has(native):
			names.append("%d x %d  (native)" % [native.x, native.y])
			vals.append(native)
		if vals.is_empty():
			names.append("1280 x 720")
			vals.append(Vector2i(1280, 720))
	elif t == MenuSettings.T_MONITOR:
		for i in maxi(DisplayServer.get_screen_count(), 1):
			var sz := DisplayServer.screen_get_size(i)
			names.append("Display %d  (%d x %d)" % [i + 1, sz.x, sz.y])
			vals.append(i)
	elif t == MenuSettings.T_AUDIO_DEVICE:
		for d in AudioServer.get_output_device_list():
			names.append(String(d))
			vals.append(String(d))
		if vals.is_empty():
			names.append("Default")
			vals.append("Default")
	elif t == MenuSettings.T_LOCALE:
		names.append("System Default")
		vals.append("")
		for loc in TranslationServer.get_loaded_locales():
			names.append(TranslationServer.get_locale_name(loc))
			vals.append(String(loc))
	return [names, vals]


# =====================================================================
# Read / write
# =====================================================================
## Pull the current value out of MenuSettings and show it. Safe to call any time.
func refresh() -> void:
	_updating = true
	var v: Variant = MenuSettings.get_value(id)
	var t := _type()
	if t == MenuSettings.T_BOOL:
		(_editor as CheckButton).button_pressed = MenuSettings.truthy(v)
	elif t == MenuSettings.T_SLIDER or t == MenuSettings.T_INT:
		(_editor as HSlider).value = float(v)
		_update_value_label(float(v))
	else:
		var ob := _editor as OptionButton
		var pair := _choices()
		var names: Array = pair[0]
		var vals: Array = pair[1]
		ob.clear()
		for i in names.size():
			ob.add_item(String(names[i]), i)
		var sel := vals.find(v)
		if sel < 0:
			sel = 0
		if not names.is_empty():
			ob.select(sel)
	_reset.visible = not _is_default()
	_updating = false


func _is_default() -> bool:
	var v: Variant = MenuSettings.get_value(id)
	var d: Variant = MenuSettings.default_of(id)
	if v is float and d is float:
		return is_equal_approx(v, d)
	return v == d


func _update_value_label(v: float) -> void:
	if _value_label == null:
		return
	var suffix := String(def.get("suffix", ""))
	match suffix:
		"%":
			_value_label.text = "%d%%" % int(round(v * 100.0))
		"x":
			_value_label.text = "%.2fx" % v
		"°":
			_value_label.text = "%d°" % int(round(v))
		" FPS":
			_value_label.text = "Off" if v <= 0.0 else "%d" % int(round(v))
		_:
			_value_label.text = "%d" % int(round(v)) if is_equal_approx(v, round(v)) else "%.2f" % v


func _push(value: Variant, save: bool = true) -> void:
	if _updating:
		return
	MenuSettings.set_value(id, value, save)
	_reset.visible = not _is_default()
	value_changed.emit(id, value)


func _on_bool_toggled(pressed: bool) -> void:
	_push(pressed)


func _on_slider_changed(v: float) -> void:
	_update_value_label(v)
	if _type() == MenuSettings.T_INT:
		_push(int(round(v)), false)
	else:
		_push(v, false)


## Dragging wrote the value but deliberately skipped the disk. Release is the one write.
func _on_slider_drag_ended(_changed: bool) -> void:
	MenuSettings.save_now()


func _on_option_selected(index: int) -> void:
	var pair := _choices()
	var vals: Array = pair[1]
	if index >= 0 and index < vals.size():
		_push(vals[index])


func _on_reset() -> void:
	MenuSettings.set_value(id, MenuSettings.default_of(id), true)
	refresh()
	value_changed.emit(id, MenuSettings.get_value(id))


# =====================================================================
# Responsive
# =====================================================================
## Stack the row vertically on narrow screens. Re-parenting rather than resizing is what keeps a
## 640px window readable instead of squeezing a 20-character label into 60 pixels.
func set_narrow(narrow: bool) -> void:
	if narrow == _narrow:
		return
	_narrow = narrow
	if narrow:
		_row.remove_child(_label)
		add_child(_label)
		move_child(_label, 0)
		_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	else:
		remove_child(_label)
		_row.add_child(_label)
		_row.move_child(_label, 0)
		_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_label.size_flags_stretch_ratio = 2.0


func set_row_enabled(on: bool) -> void:
	_editor.modulate = Color(1, 1, 1, 1.0 if on else 0.45)
	if _editor is BaseButton:
		(_editor as BaseButton).disabled = not on
	elif _editor is Range:
		(_editor as Range).editable = on
	_reset.disabled = not on
