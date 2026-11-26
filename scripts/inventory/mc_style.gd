class_name McStyle
extends RefCounted
## Minecraft's menu look (Docs/Inventory.md 14): the light grey panel with a
## black edge, white top-left and dark bottom-right bevel; sunken grey slots;
## dark grey titles; Bedrock's tabs over the panels; the name tooltip beside
## the mouse (near-black box, purple edge). Shared by the inventory screen
## and anything else that shows items in a menu.
##
## Everything is drawn in `_draw` from plain colours: no textures, so it
## scales with the slot size (`unit` = one Minecraft pixel, a slot is 18).

const PANEL := Color("c6c6c6")
const LIGHT := Color("ffffff")
const SHADE := Color("555555")
const EDGE := Color("000000")
const SLOT := Color("8b8b8b")
const SLOT_DARK := Color("373737")
const SLOT_HOVER := Color("b4b4b4")
## Bedrock's red cell: a recipe that cannot be made, an ingredient lacking.
const BAD := Color("c8605d")
const BAD_HOVER := Color("db8380")
const TEXT := Color("3f3f3f")
const TAB_OFF := Color("8b8b8b")
const STRIP := Color("4a4a4a")
const TIP_BG := Color(0.063, 0.0, 0.063, 0.94)
const TIP_EDGE_TOP := Color(0.314, 0.0, 1.0, 0.45)
const TIP_EDGE_BOTTOM := Color(0.157, 0.0, 0.5, 0.45)
const TIP_NAME := Color("ffffff")
const TIP_GREY := Color("aaaaaa")
const TIP_RED := Color("ff5555")
const TIP_GREEN := Color("55ff55")


## A Minecraft panel in `r`: black edge (corners cut), white top-left and
## dark bottom-right bevel `u` wide, grey fill.
static func draw_panel(ci: CanvasItem, r: Rect2, u: float) -> void:
	u = maxf(1.0, roundf(u))
	ci.draw_rect(Rect2(r.position + Vector2(u, 0), Vector2(r.size.x - 2 * u, r.size.y)), EDGE)
	ci.draw_rect(Rect2(r.position + Vector2(0, u), Vector2(r.size.x, r.size.y - 2 * u)), EDGE)
	var inner := r.grow(-u)
	ci.draw_rect(inner, PANEL)
	ci.draw_rect(Rect2(inner.position, Vector2(inner.size.x - u, 2 * u)), LIGHT)
	ci.draw_rect(Rect2(inner.position, Vector2(2 * u, inner.size.y - u)), LIGHT)
	ci.draw_rect(Rect2(inner.position + Vector2(u, inner.size.y - 2 * u), Vector2(inner.size.x - u, 2 * u)), SHADE)
	ci.draw_rect(Rect2(inner.position + Vector2(inner.size.x - 2 * u, u), Vector2(2 * u, inner.size.y - u)), SHADE)


## A sunken slot in `r`: dark top-left, white bottom-right, `fill` inside.
static func draw_slot(ci: CanvasItem, r: Rect2, u: float, fill := SLOT) -> void:
	u = maxf(1.0, roundf(u))
	ci.draw_rect(r, SLOT_DARK)
	ci.draw_rect(Rect2(r.position + Vector2(u, u), r.size - Vector2(u, u)), LIGHT)
	ci.draw_rect(Rect2(r.position + Vector2(u, u), r.size - Vector2(2 * u, 2 * u)), fill)


## The grey arrow between the ingredients and the result.
static func draw_arrow(ci: CanvasItem, r: Rect2, col := SLOT) -> void:
	var c := r.get_center()
	var h := r.size.y * 0.5
	var w := r.size.x
	ci.draw_rect(Rect2(Vector2(r.position.x, c.y - h * 0.22), Vector2(w * 0.62, h * 0.44)), col)
	ci.draw_colored_polygon(PackedVector2Array([Vector2(r.position.x + w * 0.58, c.y - h * 0.62),
			Vector2(r.end.x, c.y), Vector2(r.position.x + w * 0.58, c.y + h * 0.62)]), col)


## The furnace's flame: grey when out, orange when what is picked can be made.
static func draw_flame(ci: CanvasItem, r: Rect2, lit: bool) -> void:
	var outer := Color("f08a1c") if lit else SLOT
	var inner := Color("ffe14a") if lit else Color("9d9d9d")
	var c := r.get_center()
	var s := minf(r.size.x, r.size.y) * 0.5
	var pts := PackedVector2Array()
	var pts2 := PackedVector2Array()
	for i in 24:
		var a := TAU * i / 24.0
		# A drop: round below, a point on top.
		var rr := s * 0.62
		var p := Vector2(cos(a) * rr * 0.8, sin(a) * rr * 0.62 + s * 0.3)
		if sin(a) < 0.0:
			p.y = lerpf(p.y, -s * 0.95, pow(-sin(a), 3.0))
			p.x *= 1.0 - 0.6 * pow(-sin(a), 2.0)
		pts.append(c + p)
		pts2.append(c + p * 0.55 + Vector2(0, s * 0.18))
	ci.draw_colored_polygon(pts, outer)
	ci.draw_colored_polygon(pts2, inner)


## Little pictures for tabs and buttons that have no item: "search" (a
## magnifier), "book" (the recipe book), "grid" (the creative catalog),
## "close" (an x).
static func draw_glyph(ci: CanvasItem, r: Rect2, glyph: String) -> void:
	var c := r.get_center()
	var s := minf(r.size.x, r.size.y)
	match glyph:
		"search":
			var rad := s * 0.24
			var at := c - Vector2(s * 0.08, s * 0.08)
			ci.draw_line(at + Vector2(rad, rad) * 0.7, c + Vector2(s * 0.34, s * 0.34), Color("6b4a2a"), s * 0.12)
			ci.draw_circle(at, rad, Color("dfe8f0"))
			ci.draw_arc(at, rad, 0.0, TAU, 24, Color("3a3a48"), s * 0.07)
		"book":
			var b := Rect2(c - Vector2(s * 0.3, s * 0.36), Vector2(s * 0.6, s * 0.72))
			ci.draw_rect(b, Color("2f8a3a"))
			ci.draw_rect(Rect2(b.position + Vector2(b.size.x * 0.12, b.size.y * 0.08),
					Vector2(b.size.x * 0.8, b.size.y * 0.84)), Color("eadfc0"))
			ci.draw_rect(Rect2(b.position, Vector2(b.size.x * 0.18, b.size.y)), Color("1f6a2a"))
			for k in 3:
				var y := b.position.y + b.size.y * (0.3 + 0.18 * k)
				ci.draw_line(Vector2(b.position.x + b.size.x * 0.32, y), Vector2(b.end.x - b.size.x * 0.12, y),
						Color("8a7a5a"), maxf(1.0, s * 0.04))
		"grid":
			var q := s * 0.26
			var cols := [Color("7fbf4d"), Color("8a5a2b"), Color("9a9aa0"), Color("e8c040")]
			for k in 4:
				var o := Vector2((k % 2) * (q + s * 0.04), (k / 2) * (q + s * 0.04))
				ci.draw_rect(Rect2(c - Vector2(q + s * 0.02, q + s * 0.02) + o, Vector2(q, q)), cols[k])
		"close":
			var d := s * 0.22
			ci.draw_line(c - Vector2(d, d), c + Vector2(d, d), LIGHT, maxf(2.0, s * 0.1))
			ci.draw_line(c + Vector2(-d, d), c + Vector2(d, -d), LIGHT, maxf(2.0, s * 0.1))


## The theme of a Minecraft panel's subtree: dark grey labels, the black
## search box, grey bevelled buttons and scroll bars.
static func theme(font_size: int) -> Theme:
	var t := Theme.new()
	t.default_font_size = font_size
	t.set_color("font_color", "Label", TEXT)
	t.set_color("font_outline_color", "Label", Color(0, 0, 0, 0))
	t.set_font_size("font_size", "Label", font_size)
	var edit := StyleBoxFlat.new()
	edit.bg_color = Color.BLACK
	edit.border_color = Color("a0a0a0")
	edit.set_border_width_all(2)
	edit.content_margin_left = 6
	edit.content_margin_right = 6
	edit.content_margin_top = 2
	edit.content_margin_bottom = 2
	t.set_stylebox("normal", "LineEdit", edit)
	var focus := edit.duplicate() as StyleBoxFlat
	focus.border_color = LIGHT
	t.set_stylebox("focus", "LineEdit", focus)
	t.set_color("font_color", "LineEdit", Color("e0e0e0"))
	t.set_color("font_placeholder_color", "LineEdit", Color("8a8a8a"))
	t.set_color("caret_color", "LineEdit", LIGHT)
	t.set_font_size("font_size", "LineEdit", font_size)
	var btn := StyleBoxFlat.new()
	btn.bg_color = Color("6f6f6f")
	btn.border_color = EDGE
	btn.set_border_width_all(2)
	btn.content_margin_left = 6
	btn.content_margin_right = 6
	for st in ["normal", "pressed", "hover", "disabled", "focus"]:
		var b := btn.duplicate() as StyleBoxFlat
		if st == "hover":
			b.bg_color = Color("7e8bb4")
		elif st == "pressed":
			b.bg_color = Color("5a5a5a")
		elif st == "focus":
			b.draw_center = false
			b.border_color = LIGHT
		t.set_stylebox(st, "Button", b)
	t.set_color("font_color", "Button", LIGHT)
	t.set_color("font_hover_color", "Button", Color("ffffa0"))
	t.set_font_size("font_size", "Button", font_size)
	var track := StyleBoxFlat.new()
	track.bg_color = SLOT_DARK
	track.content_margin_left = 2
	track.content_margin_right = 2
	var grab := StyleBoxFlat.new()
	grab.bg_color = PANEL
	grab.border_color = SHADE
	grab.border_width_right = 2
	grab.border_width_bottom = 2
	grab.content_margin_left = 6
	grab.content_margin_right = 6
	var grab_hi := grab.duplicate() as StyleBoxFlat
	grab_hi.bg_color = LIGHT
	t.set_stylebox("scroll", "VScrollBar", track)
	t.set_stylebox("grabber", "VScrollBar", grab)
	t.set_stylebox("grabber_highlight", "VScrollBar", grab_hi)
	t.set_stylebox("grabber_pressed", "VScrollBar", grab_hi)
	return t


## A panel container drawn the Minecraft way; `unit` is one Minecraft pixel.
class Box extends PanelContainer:
	var unit := 2.0

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP
		set_pad(8)

	func set_pad(pad: int) -> void:
		var sb := StyleBoxEmpty.new()
		sb.content_margin_left = pad
		sb.content_margin_right = pad
		sb.content_margin_top = pad
		sb.content_margin_bottom = pad
		add_theme_stylebox_override("panel", sb)

	func _draw() -> void:
		McStyle.draw_panel(self, Rect2(Vector2.ZERO, size), unit)


## A tab over a panel (Bedrock's): an item's icon or a glyph, raised and
## joined to the panel when `on`. `tip` is its tooltip.
class Tab extends Control:
	signal pressed
	var icon_id: StringName = &""
	var glyph := ""
	var tip := ""
	var on := false:
		set(v):
			on = v
			queue_redraw()
	var unit := 2.0
	var _hot := false

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP
		focus_mode = Control.FOCUS_NONE
		mouse_entered.connect(func() -> void:
			_hot = true
			queue_redraw())
		mouse_exited.connect(func() -> void:
			_hot = false
			queue_redraw())

	func _gui_input(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.pressed \
				and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
			pressed.emit()
			accept_event()

	func _draw() -> void:
		var u := maxf(1.0, roundf(unit))
		var r := Rect2(Vector2.ZERO, size)
		if not on:
			r = Rect2(Vector2(0, u * 2), size - Vector2(0, u * 2))
		# Black edge, corners cut; open at the bottom when on (it joins the panel).
		draw_rect(Rect2(r.position + Vector2(u, 0), Vector2(r.size.x - 2 * u, r.size.y)), McStyle.EDGE)
		draw_rect(Rect2(r.position + Vector2(0, u), Vector2(r.size.x, r.size.y - u)), McStyle.EDGE)
		var inner := Rect2(r.position + Vector2(u, u), r.size - Vector2(2 * u, u if on else 2 * u))
		var fill := McStyle.PANEL if on else (McStyle.SLOT_HOVER if _hot else McStyle.TAB_OFF)
		draw_rect(inner, fill)
		draw_rect(Rect2(inner.position, Vector2(inner.size.x, 2 * u)), McStyle.LIGHT)
		draw_rect(Rect2(inner.position, Vector2(2 * u, inner.size.y)), McStyle.LIGHT)
		if not on:
			draw_rect(Rect2(inner.position + Vector2(inner.size.x - 2 * u, 2 * u),
					Vector2(2 * u, inner.size.y - 2 * u)), McStyle.SHADE)
			draw_rect(Rect2(inner.position + Vector2(2 * u, inner.size.y - 2 * u),
					Vector2(inner.size.x - 2 * u, 2 * u)), McStyle.SHADE)
		var ir := inner.grow(-inner.size.y * 0.16)
		ir = Rect2(ir.get_center() - Vector2(ir.size.y, ir.size.y) * 0.5, Vector2(ir.size.y, ir.size.y))
		if icon_id != &"" and ItemIcons.draw_icon(self, ir, icon_id):
			return
		if not glyph.is_empty():
			McStyle.draw_glyph(self, ir, glyph)


## Bedrock's "craftable only" switch: a dark track, a bevelled knob that
## slides right (green track) when on.
class Toggle extends Control:
	signal toggled(on: bool)
	var on := false:
		set(v):
			on = v
			queue_redraw()
	var tip := ""
	var icon_id: StringName = &""
	var unit := 2.0

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP
		focus_mode = Control.FOCUS_NONE

	func _gui_input(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.pressed \
				and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
			on = not on
			toggled.emit(on)
			accept_event()

	func _draw() -> void:
		var u := maxf(1.0, roundf(unit))
		var r := Rect2(Vector2.ZERO, size)
		McStyle.draw_slot(self, r, u, Color("4f8a3c") if on else McStyle.SLOT_DARK)
		var k := Rect2(Vector2(size.x - size.y if on else 0.0, 0), Vector2(size.y, size.y))
		McStyle.draw_panel(self, k, u)
		var ir := k.grow(-k.size.x * 0.2)
		if icon_id == &"" or not ItemIcons.draw_icon(self, ir, icon_id):
			draw_rect(ir, McStyle.SLOT)


## The name box beside the mouse (Minecraft's tooltip): near-black, a purple
## edge, the name white and any lines after it grey (or red / green).
## `lines`: [[text, colour], ...]. Placed right of and above the mouse, kept
## on screen.
class Tooltip extends Control:
	var lines: Array = []
	var font_size := 16

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		top_level = true
		z_index = 20
		visible = false

	func show_lines(p_lines: Array, at: Vector2, screen: Rect2) -> void:
		lines = p_lines
		if lines.is_empty():
			visible = false
			return
		var font: Font = ThemeDB.fallback_font
		var w := 0.0
		for l in lines:
			w = maxf(w, font.get_string_size(str(l[0]), HORIZONTAL_ALIGNMENT_LEFT, -1, _size_of(l)).x)
		var pad := roundf(font_size * 0.35)
		var h := 0.0
		for i in lines.size():
			h += _line_h(i)
		size = Vector2(w + pad * 2.0 + 4.0, h + pad * 2.0 + 2.0)
		var p := at + Vector2(font_size * 0.9, -font_size * 1.1)
		if p.x + size.x > screen.end.x:
			p.x = at.x - size.x - font_size * 0.6
		p.y = clampf(p.y, screen.position.y, maxf(screen.position.y, screen.end.y - size.y))
		p.x = maxf(p.x, screen.position.x)
		position = p.round()
		visible = true
		queue_redraw()

	func _size_of(l: Array) -> int:
		return font_size if l == lines[0] else int(font_size * 0.86)

	func _line_h(i: int) -> float:
		var fs := font_size if i == 0 else int(font_size * 0.86)
		return fs * 1.25 + (font_size * 0.25 if i == 0 and lines.size() > 1 else 0.0)

	func _draw() -> void:
		var r := Rect2(Vector2.ZERO, size)
		draw_rect(Rect2(r.position + Vector2(1, 0), Vector2(r.size.x - 2, r.size.y)), McStyle.TIP_BG)
		draw_rect(Rect2(r.position + Vector2(0, 1), Vector2(r.size.x, r.size.y - 2)), McStyle.TIP_BG)
		var e := r.grow(-1.0)
		draw_rect(Rect2(e.position, Vector2(e.size.x, 1)), McStyle.TIP_EDGE_TOP)
		draw_rect(Rect2(Vector2(e.position.x, e.end.y - 1), Vector2(e.size.x, 1)), McStyle.TIP_EDGE_BOTTOM)
		draw_polyline_colors(PackedVector2Array([Vector2(e.position.x + 0.5, e.position.y),
				Vector2(e.position.x + 0.5, e.end.y)]),
				PackedColorArray([McStyle.TIP_EDGE_TOP, McStyle.TIP_EDGE_BOTTOM]), 1.0)
		draw_polyline_colors(PackedVector2Array([Vector2(e.end.x - 0.5, e.position.y),
				Vector2(e.end.x - 0.5, e.end.y)]),
				PackedColorArray([McStyle.TIP_EDGE_TOP, McStyle.TIP_EDGE_BOTTOM]), 1.0)
		var font: Font = ThemeDB.fallback_font
		var pad := roundf(font_size * 0.35)
		var y := pad + 1.0
		for i in lines.size():
			var l: Array = lines[i]
			var fs := font_size if i == 0 else int(font_size * 0.86)
			var base := Vector2(pad + 2.0, y + fs * 0.95)
			var col: Color = l[1]
			# Minecraft's text shadow: the colour at a quarter, one pixel down-right.
			draw_string(font, base + Vector2(1, 1), str(l[0]), HORIZONTAL_ALIGNMENT_LEFT, -1, fs,
					Color(col.r * 0.25, col.g * 0.25, col.b * 0.25, col.a))
			draw_string(font, base, str(l[0]), HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)
			y += _line_h(i)
