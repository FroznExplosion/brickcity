class_name ToolRail
extends PanelContainer

## The tool rail both workshops show down the left (Docs/BuildTools.md, "The rail"): each
## tool an icon, its name and its key, with a pop-up saying what it does; a line under them
## for the tool in hand; and under that a slot for the open tool's own options.
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
	"rooms": '<rect x="3" y="4" width="18" height="16"/><path d="M12 4v7M12 15v5M3 12h5"/>',
}
static var _icon_cache := {}

## Tool id -> its Button, for the rows `fill` was last given.
var buttons := {}
## The line under the tools: what the one in hand does.
var hint: Label
## The open tool's options go in here, under the hint.
var options: VBoxContainer
var _box: VBoxContainer
var _width := 184.0


func _init(width: float = 184.0) -> void:
	_width = width
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.11, 0.12, 0.15, 0.96)
	bg.set_content_margin_all(6)
	bg.set_corner_radius_all(4)
	add_theme_stylebox_override("panel", bg)
	custom_minimum_size.x = width
	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 3)
	add_child(outer)
	_box = VBoxContainer.new()
	_box.add_theme_constant_override("separation", 3)
	outer.add_child(_box)
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
## `skip`: ids not to show. A press calls `picked` with the id.
func fill(title_text: String, rows: Array, picked: Callable, skip: Array = []) -> void:
	for c in _box.get_children():
		_box.remove_child(c)
		c.queue_free()
	buttons.clear()
	var title := Label.new()
	title.add_theme_font_size_override("font_size", 13)
	title.add_theme_color_override("font_color", Color(0.75, 0.8, 0.88))
	title.text = title_text
	_box.add_child(title)
	var group := ButtonGroup.new()
	for t in rows:
		var id := String(t[0])
		if id in skip:
			continue
		var key := String(t[2])
		var b := Button.new()
		b.text = String(t[1]) + ("   " + key if key != "" else "")
		b.icon = icon(id)
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.focus_mode = Control.FOCUS_NONE
		b.tooltip_text = "%s%s\n%s" % [t[1], ("  (%s)" % key) if key != "" else "", t[3]]
		if not id.begins_with("!"):
			b.toggle_mode = true
			b.button_group = group
		b.pressed.connect(picked.bind(id))
		_box.add_child(b)
		buttons[id] = b
	hint = Label.new()
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size.x = _width - 16
	hint.add_theme_font_size_override("font_size", 11)
	hint.add_theme_color_override("font_color", Color(0.72, 0.76, 0.82))
	_box.add_child(hint)


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
