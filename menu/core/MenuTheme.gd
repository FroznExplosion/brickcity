class_name MenuTheme
extends RefCounted
## The look, built in code. No `.tres`, no fonts, no textures — copying `menu/` into another
## project brings the entire visual identity with it and cannot arrive with broken resource
## paths. Re-skinning is the palette block below and nothing else.
##
## The theme is rebuilt (not merely re-tinted) whenever text scale or high-contrast changes,
## because both alter StyleBox metrics as well as colours. `MenuSettings` calls `invalidate()`.

# --------------------------------------------------------------------
# Palette — override these before the first `theme()` call to re-skin.
# --------------------------------------------------------------------
static var bg := Color("0d0e12")            ## page background
static var surface := Color("16181f")       ## panels, tab bodies
static var surface_high := Color("1e212a")  ## hovered rows, sliders' fill track
static var line := Color("2c3140")          ## borders and separators
static var text := Color("e6e8ee")
static var text_dim := Color("9aa1b2")      ## hints, disabled labels
static var accent := Color("d2762f")        ## kiln orange — focus, fill, primary action
static var accent_soft := Color("8a4f22")
static var danger := Color("d0483f")
static var ok := Color("5fbf7d")

const BASE_FONT_SIZE := 17
const RADIUS := 5
## Scrollbar thickness in pixels. Wide enough to grab with a mouse, thin enough that reserving
## room for it on a 640px window costs nothing that matters.
const SCROLLBAR_WIDTH := 10

static var _theme: Theme = null
static var _built_for := Vector2(-1, -1)   ## (text_scale, high_contrast) the cache was built for


## The shared theme instance. Cheap after the first call.
static func theme() -> Theme:
	var key := Vector2(_text_scale(), 1.0 if _high_contrast() else 0.0)
	if _theme != null and _built_for.is_equal_approx(key):
		return _theme
	_theme = _build()
	_built_for = key
	return _theme


## Drop the cache. The next `theme()` rebuilds; open screens re-apply on the settings signal.
static func invalidate() -> void:
	_theme = null
	_built_for = Vector2(-1, -1)


static func font_size(scale: float = 1.0) -> int:
	return maxi(int(round(BASE_FONT_SIZE * _text_scale() * scale)), 9)


# --------------------------------------------------------------------
# Settings access, guarded so the module works with no autoload registered
# --------------------------------------------------------------------
static func _settings() -> Node:
	var loop := Engine.get_main_loop() as SceneTree
	if loop == null or loop.root == null:
		return null
	return loop.root.get_node_or_null("MenuSettings")


static func _text_scale() -> float:
	var s := _settings()
	return float(s.get_value(&"text_scale")) if s != null else 1.0


static func _high_contrast() -> bool:
	var s := _settings()
	return s.get_bool(&"high_contrast") if s != null else false


# --------------------------------------------------------------------
# Build
# --------------------------------------------------------------------
static func _build() -> Theme:
	var hc := _high_contrast()
	var t := Theme.new()
	t.default_font_size = font_size()

	var body := text if not hc else Color.WHITE
	var dim := text_dim if not hc else Color("d5d9e2")
	var border_w := 1 if not hc else 2

	# ---- Button ----
	var btn_normal := _box(surface, line, border_w)
	var btn_hover := _box(surface_high, accent_soft, border_w)
	var btn_pressed := _box(accent_soft, accent, border_w)
	var btn_disabled := _box(Color(surface, 0.5), Color(line, 0.5), border_w)
	var btn_focus := _box(Color(0, 0, 0, 0), accent, maxi(border_w, 2))
	for cls in ["Button", "OptionButton", "MenuButton", "CheckBox", "CheckButton"]:
		t.set_stylebox("normal", cls, btn_normal)
		t.set_stylebox("hover", cls, btn_hover)
		t.set_stylebox("pressed", cls, btn_pressed)
		t.set_stylebox("disabled", cls, btn_disabled)
		t.set_stylebox("focus", cls, btn_focus)
		t.set_color("font_color", cls, body)
		t.set_color("font_hover_color", cls, Color.WHITE)
		t.set_color("font_pressed_color", cls, Color.WHITE)
		t.set_color("font_focus_color", cls, Color.WHITE)
		t.set_color("font_disabled_color", cls, Color(dim, 0.55))
		t.set_color("font_outline_color", cls, Color(0, 0, 0, 0.85))
		t.set_constant("outline_size", cls, 0 if not hc else 3)
		t.set_font_size("font_size", cls, font_size())

	# CheckBox/CheckButton read as rows, not as raised buttons.
	var flat := _box(Color(0, 0, 0, 0), Color(0, 0, 0, 0), 0)
	for cls in ["CheckBox", "CheckButton"]:
		t.set_stylebox("normal", cls, flat)
		t.set_stylebox("pressed", cls, flat)
		t.set_stylebox("hover", cls, _box(Color(surface_high, 0.6), Color(0, 0, 0, 0), 0))

	# ---- Panels ----
	t.set_stylebox("panel", "PanelContainer", _box(surface, line, border_w))
	t.set_stylebox("panel", "Panel", _box(surface, line, border_w))
	t.set_stylebox("panel", "PopupMenu", _box(surface, accent_soft, maxi(border_w, 1)))
	t.set_color("font_color", "PopupMenu", body)
	t.set_color("font_hover_color", "PopupMenu", Color.WHITE)
	t.set_font_size("font_size", "PopupMenu", font_size())

	# ---- Labels ----
	t.set_color("font_color", "Label", body)
	t.set_font_size("font_size", "Label", font_size())
	t.set_color("font_outline_color", "Label", Color(0, 0, 0, 0.85))
	t.set_constant("outline_size", "Label", 0 if not hc else 3)
	t.set_color("default_color", "RichTextLabel", body)
	t.set_font_size("normal_font_size", "RichTextLabel", font_size())

	# ---- LineEdit ----
	t.set_stylebox("normal", "LineEdit", _box(Color("0a0b0f"), line, border_w))
	t.set_stylebox("focus", "LineEdit", _box(Color("0a0b0f"), accent, maxi(border_w, 2)))
	t.set_color("font_color", "LineEdit", body)
	t.set_color("font_placeholder_color", "LineEdit", Color(dim, 0.7))
	t.set_color("caret_color", "LineEdit", accent)
	t.set_font_size("font_size", "LineEdit", font_size())

	# ---- Sliders ----
	var track := StyleBoxFlat.new()
	track.bg_color = surface_high
	track.set_corner_radius_all(3)
	track.content_margin_top = 4
	track.content_margin_bottom = 4
	var fill := StyleBoxFlat.new()
	fill.bg_color = accent
	fill.set_corner_radius_all(3)
	fill.content_margin_top = 4
	fill.content_margin_bottom = 4
	for cls in ["HSlider", "VSlider"]:
		t.set_stylebox("slider", cls, track)
		t.set_stylebox("grabber_area", cls, fill)
		t.set_stylebox("grabber_area_highlight", cls, fill)
	t.set_constant("center_grabber", "HSlider", 1)

	# ---- Scrollbars ----
	# NOT built from `_box`: its 12px content margins are what give a button breathing room, and
	# a scrollbar inherits them as WIDTH — a 24px bar that eats a chunk of every narrow screen.
	# The margins here are the bar's thickness, so `SCROLLBAR_WIDTH` is the number to change.
	for cls in ["VScrollBar", "HScrollBar"]:
		t.set_stylebox("scroll", cls, _bar_box(Color(0, 0, 0, 0.35)))
		t.set_stylebox("grabber", cls, _bar_box(Color(line, 0.95)))
		t.set_stylebox("grabber_highlight", cls, _bar_box(accent_soft))
		t.set_stylebox("grabber_pressed", cls, _bar_box(accent))

	# ---- Tabs ----
	t.set_stylebox("panel", "TabContainer", _box(surface, line, border_w))
	t.set_stylebox("tabbar_background", "TabContainer", flat)
	var tab_sel := _box(surface, accent, maxi(border_w, 1))
	tab_sel.border_width_bottom = 0
	var tab_un := _box(Color(bg, 0.6), Color(line, 0.6), border_w)
	tab_un.border_width_bottom = 0
	for cls in ["TabContainer", "TabBar"]:
		t.set_stylebox("tab_selected", cls, tab_sel)
		t.set_stylebox("tab_unselected", cls, tab_un)
		t.set_stylebox("tab_hovered", cls, _box(surface_high, Color(line, 0.8), border_w))
		t.set_color("font_selected_color", cls, Color.WHITE)
		t.set_color("font_unselected_color", cls, dim)
		t.set_color("font_hovered_color", cls, body)
		t.set_font_size("font_size", cls, font_size())

	# ---- Separator ----
	var sep := StyleBoxFlat.new()
	sep.bg_color = Color(line, 0.8)
	sep.content_margin_top = 1
	sep.content_margin_bottom = 1
	t.set_stylebox("separator", "HSeparator", sep)

	t.set_stylebox("panel", "AcceptDialog", _box(surface, accent_soft, maxi(border_w, 1)))
	return t


static func _box(bg_col: Color, border_col: Color, border: int) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg_col
	s.set_corner_radius_all(RADIUS)
	s.set_border_width_all(border)
	s.border_color = border_col
	s.content_margin_left = 12
	s.content_margin_right = 12
	s.content_margin_top = 7
	s.content_margin_bottom = 7
	return s


## Scrollbar stylebox. Its content margins ARE the bar's thickness — see the note at the
## scrollbar block above for why this is not `_box`.
static func _bar_box(col: Color) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = col
	var half := SCROLLBAR_WIDTH / 2.0
	s.set_corner_radius_all(int(half))
	s.content_margin_left = half
	s.content_margin_right = half
	s.content_margin_top = half
	s.content_margin_bottom = half
	return s


## A filled StyleBox for the one highlighted call-to-action per screen.
static func primary_box() -> StyleBoxFlat:
	return _box(accent_soft, accent, 2)
