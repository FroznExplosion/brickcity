class_name WkMenuBar
extends PanelContainer

## An editor's menu bar (workshop_kit): menus built from rows the editor gives, a title on the
## right. What an item DOES is the editor's: each menu calls its handler with the item's id.
##
##     bar.add_menu("File", [["Open…", 1, KEY_MASK_CTRL | KEY_O], [], ["Quit", 2, 0]], _on_file)
##
## A row is [label, id, shortcut] -- the shortcut a keycode with KEY_MASK_CTRL / KEY_MASK_SHIFT
## / KEY_MASK_ALT, or 0 -- or [] for a separator. `add_menu` with a label already on the bar adds
## its rows to that menu, after a separator.

var _row: HBoxContainer
var _spacer: Control
var _title: Label


func _init() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.07, 0.08, 0.11, 0.86)
	sb.content_margin_left = 8
	sb.content_margin_right = 8
	sb.content_margin_top = 2
	sb.content_margin_bottom = 2
	add_theme_stylebox_override("panel", sb)
	_row = HBoxContainer.new()
	_row.add_theme_constant_override("separation", 4)
	add_child(_row)
	_spacer = Control.new()
	_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_row.add_child(_spacer)
	_title = Label.new()
	_title.add_theme_color_override("font_color", Color(0.84, 0.87, 0.93))
	_row.add_child(_title)


## The editor's look for the bar (null keeps its own).
func restyle(panel: StyleBox) -> void:
	if panel != null:
		add_theme_stylebox_override("panel", panel)


## A menu of `items` (rows as above), calling `handler(id)`. `checks`: the items are radio
## checks (the editor ticks one). Returns its button.
func add_menu(label: String, items: Array, handler: Callable, checks := false) -> MenuButton:
	var mb := menu(label)
	var p := mb.get_popup()
	if mb.get_meta(&"wk_new", true):
		mb.set_meta(&"wk_new", false)
	elif p.item_count > 0:
		p.add_separator()
	for it in items:
		if (it as Array).is_empty():
			p.add_separator()
			continue
		if checks:
			p.add_radio_check_item(String(it[0]), int(it[1]))
		else:
			p.add_item(String(it[0]), int(it[1]))
		var keys := int(it[2]) if (it as Array).size() > 2 else 0
		if keys != 0:
			var sc := Shortcut.new()
			var ev := InputEventKey.new()
			ev.keycode = keys & KEY_CODE_MASK
			ev.ctrl_pressed = (keys & KEY_MASK_CTRL) != 0
			ev.shift_pressed = (keys & KEY_MASK_SHIFT) != 0
			ev.alt_pressed = (keys & KEY_MASK_ALT) != 0
			sc.events = [ev]
			p.set_item_shortcut(p.get_item_count() - 1, sc, true)
	p.id_pressed.connect(handler)
	return mb


## The menu with this label, made (empty, before the title) if the bar has none.
func menu(label: String) -> MenuButton:
	for c in _row.get_children():
		if c is MenuButton and (c as MenuButton).text == label:
			return c
	var mb := MenuButton.new()
	mb.text = label
	mb.flat = true
	mb.switch_on_hover = true
	_row.add_child(mb)
	_row.move_child(mb, _spacer.get_index())
	return mb


## The menus' buttons, left to right.
func menus() -> Array:
	return _row.get_children().filter(func(c: Node) -> bool: return c is MenuButton)


## The menus' labels, left to right.
func labels() -> Array:
	var out := []
	for c in _row.get_children():
		if c is MenuButton:
			out.append((c as MenuButton).text)
	return out


func set_title(t: String) -> void:
	_title.text = t


func title() -> String:
	return _title.text


func bar_height() -> float:
	return size.y
