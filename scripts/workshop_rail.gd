class_name ToolRail
extends PanelContainer

## The tool rail both workshops show down the left (Docs/BuildTools.md, "The rail"): each
## tool an icon, its name and its key, with a pop-up saying what it does; a line under them
## for the tool in hand; under that, buttons for actions (a rotate, a toggle: every key has
## one, Docs/BuildTools.md section 7); and a slot for the open tool's own options.
##
## It keeps no state of its own that matters: `fill` is given the rows and what a press
## calls, and the owner lights the tool in hand each frame (`show_active`), so a key pressed
## instead of a button shows the same.

## The icons: 24 x 24 line drawings, drawn by Godot from these (Image.load_svg_from_string).
const ICONS := {
	"select": '<path d="M5 3l14 8-6 2-3 6z"/>',
	"draw": '<path d="M4 20c3 0 5-2 5-5"/><path d="M9 15L19 5l2 2-10 10z"/>',
	"shape": '<path d="M12 3l8 4.5v9L12 21l-8-4.5v-9z"/><path d="M12 12l8-4.5M12 12v9M12 12L4 7.5"/>',
	"smooth": '<path d="M3 9c3-3 6 3 9 0s6 3 9 0"/><path d="M3 15c3-3 6 3 9 0s6 3 9 0"/>',
	"!import": '<path d="M12 3v12"/><path d="M7 10l5 5 5-5"/><path d="M4 19h16"/>',
	"measure": '<rect x="2" y="8" width="20" height="8" rx="1"/><path d="M6 8v3M10 8v4M14 8v3M18 8v4"/>',
	"place": '<rect x="3" y="10" width="18" height="9" rx="1"/><rect x="6" y="6" width="4" height="4"/><rect x="14" y="6" width="4" height="4"/>',
	"paint": '<path d="M12 3c4 5 6 8 6 11a6 6 0 0 1-12 0c0-3 2-6 6-11z"/>',
	"sketch": '<path d="M4 20l1-5L16 4l4 4L9 19z"/><path d="M14 6l4 4"/>',
	"move": '<path d="M12 3v18M3 12h18M9 6l3-3 3 3M9 18l3 3 3-3M6 9l-3 3 3 3M18 9l3 3-3 3"/>',
	"stud": '<ellipse cx="12" cy="9" rx="7" ry="3"/><path d="M5 9v6c0 1.7 3.1 3 7 3s7-1.3 7-3V9"/>',
	"!point": '<circle cx="12" cy="12" r="8"/><circle cx="12" cy="12" r="3"/>',
	"!explode": '<path d="M12 2v5M12 17v5M2 12h5M17 12h5M5 5l3 3M16 16l3 3M19 5l-3 3M8 16l-3 3"/>',
	"!hands": '<path d="M8 13V5a1.5 1.5 0 0 1 3 0v6M11 11V4a1.5 1.5 0 0 1 3 0v7M14 11V6a1.5 1.5 0 0 1 3 0v8c0 4-3 7-6 7s-5-2-6-4l-2-4a1.5 1.5 0 0 1 2.5-1.5L8 14"/>',
	"!play": '<path d="M7 4l13 8-13 8z"/>',
	"!export_game": '<path d="M12 21V9"/><path d="M7 14l5-5 5 5"/><path d="M4 4h16"/>',
	"!export_print": '<path d="M7 9V3h10v6"/><rect x="3" y="9" width="18" height="8" rx="1"/><path d="M7 14h10v7H7z"/>',
	"!save": '<path d="M4 4h13l3 3v13H4z"/><path d="M8 4v5h7V4M8 20v-6h8v6"/>',
	"wall": '<rect x="3" y="5" width="18" height="14"/><path d="M3 9.7h18M3 14.3h18M9 5v4.7M15 5v4.7M6 9.7v4.6M12 9.7v4.6M18 9.7v4.6M9 14.3V19M15 14.3V19"/>',
	"cut": '<path d="M6 20V9a6 6 0 0 1 12 0v11"/><path d="M3 20h18"/>',
	"repeat": '<rect x="4" y="13" width="16" height="7"/><rect x="4" y="4" width="16" height="7" stroke-dasharray="3 2"/>',
	"pick": '<path d="M14 4l6 6-9 9H5v-6z"/><path d="M12 6l6 6"/>',
	"walls": '<path d="M4 20V8h8v6h8v6"/><path d="M4 8V4M12 8V4"/>',
	"floor": '<path d="M3 15l9-5 9 5-9 5z"/><path d="M3 15v2l9 5 9-5v-2"/>',
	"roof": '<path d="M2 13L12 4l10 9"/><path d="M5 11v9h14v-9"/>',
	"stairs": '<path d="M3 20h5v-5h5v-5h5V5h3"/>',
	"builds": '<rect x="3" y="3" width="8" height="8"/><rect x="13" y="13" width="8" height="8"/><path d="M11 7h4v4M13 17H9v-4"/>',
	"rooms": '<rect x="3" y="4" width="18" height="16"/><path d="M12 4v7M12 15v5M3 12h5"/>',
}
static var _icon_cache := {}

## Tool id -> its Button, for the rows `fill` was last given.
var buttons := {}
## The line under the tools: what the one in hand does.
var hint: Label
## The open tool's options go in here, under the hint.
var options: VBoxContainer
## Action id -> its Button, for the sections `actions` was given.
var action_buttons := {}
var _box: VBoxContainer
var _actions: VBoxContainer
var _outer: VBoxContainer
var _scroll: ScrollContainer
var _width := 184.0


## `scroll`: the rail scrolls when taller than `fit_height` allows (the owner calls it).
func _init(width: float = 184.0, scroll: bool = false) -> void:
	_width = width
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.11, 0.12, 0.15, 0.96)
	bg.set_content_margin_all(6)
	bg.set_corner_radius_all(4)
	add_theme_stylebox_override("panel", bg)
	custom_minimum_size.x = width
	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 3)
	_outer = outer
	if scroll:
		_scroll = ScrollContainer.new()
		_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		add_child(_scroll)
		outer.custom_minimum_size.x = width - 14
		_scroll.add_child(outer)
	else:
		add_child(outer)
	_box = VBoxContainer.new()
	_box.add_theme_constant_override("separation", 3)
	outer.add_child(_box)
	_actions = VBoxContainer.new()
	_actions.add_theme_constant_override("separation", 2)
	_actions.visible = false
	outer.add_child(_actions)
	# Hidden until an owner puts options in it: an empty box still takes a gap.
	options = VBoxContainer.new()
	options.add_theme_constant_override("separation", 2)
	options.visible = false
	outer.add_child(options)


## An icon, drawn once.
static func icon(id: String) -> Texture2D:
	if not ICONS.has(id):
		return null
	if not _icon_cache.has(id):
		var svg := ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="24" height="24" '
				+ 'fill="none" stroke="#e8ecf2" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">'
				+ String(ICONS[id]) + '</svg>')
		var img := Image.new()
		if img.load_svg_from_string(svg, 0.8) != OK:
			return null
		_icon_cache[id] = ImageTexture.create_from_image(img)
	return _icon_cache[id]


## The rail's buttons: a title, then a row each -- [id, label, key, what it does]. An id
## starting "!" is an action (a plain button), the rest are tools (one lit at a time).
## `skip`: ids not to show. A press calls `picked` with the id. `columns` above 1: the tools
## in a grid, icon and name (the key in the pop-up), so more fit.
func fill(title_text: String, rows: Array, picked: Callable, skip: Array = [], columns: int = 1) -> void:
	for c in _box.get_children():
		_box.remove_child(c)
		c.queue_free()
	buttons.clear()
	var title := Label.new()
	title.add_theme_font_size_override("font_size", 13)
	title.add_theme_color_override("font_color", Color(0.75, 0.8, 0.88))
	title.text = title_text
	_box.add_child(title)
	var into: Container = _box
	if columns > 1:
		var grid := GridContainer.new()
		grid.columns = columns
		grid.add_theme_constant_override("h_separation", 3)
		grid.add_theme_constant_override("v_separation", 3)
		_box.add_child(grid)
		into = grid
	var group := ButtonGroup.new()
	for t in rows:
		var id := String(t[0])
		if id in skip:
			continue
		var key := String(t[2])
		var b := Button.new()
		b.text = String(t[1]) + ("   " + key if key != "" and columns <= 1 else "")
		b.icon = icon(id)
		if columns > 1:
			b.add_theme_font_size_override("font_size", 12)
			b.custom_minimum_size.x = (_width - 18.0) / columns - 2.0
			b.clip_text = true
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.focus_mode = Control.FOCUS_NONE
		b.tooltip_text = "%s%s\n%s" % [t[1], ("  (%s)" % key) if key != "" else "", t[3]]
		if not id.begins_with("!"):
			b.toggle_mode = true
			b.button_group = group
		b.pressed.connect(picked.bind(id))
		into.add_child(b)
		buttons[id] = b
	hint = Label.new()
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size.x = _width - 16
	hint.add_theme_font_size_override("font_size", 11)
	hint.add_theme_color_override("font_color", Color(0.72, 0.76, 0.82))
	_box.add_child(hint)


## Buttons for actions, under the tools: `sections` is [[title, rows], ...], a row [id,
## label, key, what it does, toggle?]. A toggle stays lit while its thing is on
## (`show_toggles`). A press calls `picked` with the id. Three to a row, small.
func actions(sections: Array, picked: Callable) -> void:
	for c in _actions.get_children():
		_actions.remove_child(c)
		c.queue_free()
	action_buttons.clear()
	_actions.visible = not sections.is_empty()
	for sec in sections:
		var l := Label.new()
		l.text = String(sec[0])
		l.add_theme_font_size_override("font_size", 11)
		l.add_theme_color_override("font_color", Color(0.62, 0.68, 0.76))
		_actions.add_child(l)
		var grid := GridContainer.new()
		grid.columns = 3
		grid.add_theme_constant_override("h_separation", 2)
		grid.add_theme_constant_override("v_separation", 2)
		_actions.add_child(grid)
		for t in sec[1]:
			var id := String(t[0])
			var key := String(t[2])
			var b := Button.new()
			b.text = String(t[1])
			b.add_theme_font_size_override("font_size", 11)
			b.custom_minimum_size.x = (_width - 18.0) / 3.0 - 2.0
			b.clip_text = true
			b.focus_mode = Control.FOCUS_NONE
			b.toggle_mode = t.size() > 4 and bool(t[4])
			b.tooltip_text = "%s%s\n%s" % [t[1], ("  (%s)" % key) if key != "" else "", t[3]]
			b.pressed.connect(picked.bind(id))
			grid.add_child(b)
			action_buttons[id] = b


## Light the toggles that are on: id -> bool.
func show_toggles(states: Dictionary) -> void:
	for id in states:
		if action_buttons.has(id):
			(action_buttons[id] as Button).set_pressed_no_signal(bool(states[id]))


## An action button's text now (the layer it is on, the way the mirror goes).
func set_action_text(id: String, text: String) -> void:
	if action_buttons.has(id) and (action_buttons[id] as Button).text != text:
		(action_buttons[id] as Button).text = text


## A scrolling rail: no taller than `max_h`, its content scrolling inside.
func fit_height(max_h: float) -> void:
	if _scroll == null:
		return
	_scroll.custom_minimum_size = Vector2(_width - 12.0, minf(_outer.get_combined_minimum_size().y, maxf(120.0, max_h)))


## Light the tool in hand ("" for none) and say what it does from `rows`.
func show_active(on: String, rows: Array = []) -> void:
	for id in buttons:
		var b: Button = buttons[id]
		if b.toggle_mode:
			b.set_pressed_no_signal(id == on)
	if hint != null and not rows.is_empty():
		var text := ""
		for t in rows:
			if t[0] == on:
				text = t[3]
		hint.text = text


## True while the cursor is over the rail: the wheel there scrolls nothing else.
func has_mouse() -> bool:
	return is_visible_in_tree() and get_global_rect().has_point(get_global_mouse_position())
