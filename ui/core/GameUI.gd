class_name GameUI
extends RefCounted
## The in-game UI kit: what every HUD and in-game screen draws with, so they
## share one look with the menus and all follow the player's text scale and
## high contrast (Options > Accessibility). Built on `menu/`'s MenuTheme --
## the same palette and the same Theme -- and nothing of the game's: copy
## `ui/` with `menu/` into another project and it works (ui/docs/README.md).
##
## Two kinds of screen use it:
##   * DRAWN, in a Control's _draw (a crosshair, bars, numbers over the world):
##     `draw_text`, `draw_box`, `draw_bar`, `px`, `text_width`, the HUD colours.
##   * BUILT from Controls (a card, a menu, a catalogue): `style` on the root,
##     `panel_box` for a panel, `label`, `px` for an explicit size.
## A designed size in pixels goes through `px` (or `draw_text` does it), so a
## player who has turned the text up gets it bigger everywhere.

# --------------------------------------------------------------------
# HUD colours: text and chrome over the 3D view. What a colour MEANS in the
# game (a rarity, a team, a damage type) is the game's, not here.
# --------------------------------------------------------------------
static var hud_text := Color(1, 1, 1, 0.9)
static var hud_dim := Color(1, 1, 1, 0.7)
## The dark plate under a bar or a line of text.
static var hud_back := Color(0, 0, 0, 0.55)
## Low, empty, hurt: the warning colour on the HUD.
static var hud_warn := Color(1.0, 0.35, 0.3)
## Ready, charged: the go colour on the HUD.
static var hud_ready := Color(0.4, 0.85, 1.0, 0.9)
## Text outline thickness, in pixels at text scale 1.
const OUTLINE := 4


## The font every screen draws with: the engine's, as the menus' theme uses
## (MenuTheme ships no font files). One place to change it.
static func font() -> Font:
	return ThemeDB.fallback_font


## A designed pixel size at the player's text scale (never under 8).
static func px(size: float) -> int:
	return maxi(int(round(size * MenuTheme.text_scale())), 8)


## How wide `text` is at designed size `size`.
static func text_width(text: String, size: float) -> float:
	return font().get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, px(size)).x


## `text` on `ci` with its baseline at `at`, at designed size `size`, outlined so
## it reads over anything. `align`: HORIZONTAL_ALIGNMENT_LEFT puts `at` at its
## left, _CENTER at its middle, _RIGHT at its right. In high contrast the
## outline is solid.
static func draw_text(ci: CanvasItem, text: String, at: Vector2, size: float, col: Color,
		align := HORIZONTAL_ALIGNMENT_LEFT, outline := true) -> void:
	var f := font()
	var s := px(size)
	var p := at
	if align != HORIZONTAL_ALIGNMENT_LEFT:
		var w := f.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, s).x
		p.x -= w * (0.5 if align == HORIZONTAL_ALIGNMENT_CENTER else 1.0)
	if outline:
		var oa := col.a * (1.0 if MenuTheme.high_contrast() else 0.8)
		ci.draw_string_outline(f, p, text, HORIZONTAL_ALIGNMENT_LEFT, -1, s, OUTLINE, Color(0, 0, 0, oa))
	ci.draw_string(f, p, text, HORIZONTAL_ALIGNMENT_LEFT, -1, s, col)


## A dark plate: `rect` grown by `pad` all round, in `col` (the HUD back by default;
## more opaque in high contrast).
static func draw_box(ci: CanvasItem, rect: Rect2, pad := 2.0, col := Color(-1, 0, 0, 0)) -> void:
	var c := hud_back if col.r < 0.0 else col
	if MenuTheme.high_contrast():
		c.a = maxf(c.a, 0.85)
	ci.draw_rect(rect.grow(pad), c)


## A bar: its plate, and `frac` (0..1) of `rect` filled with `fill` from the left.
static func draw_bar(ci: CanvasItem, rect: Rect2, frac: float, fill: Color, pad := 2.0) -> void:
	draw_box(ci, rect, pad)
	ci.draw_rect(Rect2(rect.position, Vector2(rect.size.x * clampf(frac, 0.0, 1.0), rect.size.y)), fill)


# --------------------------------------------------------------------
# Built screens
# --------------------------------------------------------------------

## The menus' Theme on `root` and everything under it, kept current: when the
## player changes text scale or high contrast, it is put on again.
static func style(root: Control) -> void:
	root.theme = MenuTheme.theme()
	var s := _settings()
	if s == null or not s.has_signal(&"changed"):
		return
	var again := func(id: StringName, _v: Variant) -> void:
		if id in [&"text_scale", &"high_contrast"] and is_instance_valid(root):
			MenuTheme.invalidate()
			root.theme = MenuTheme.theme()
	s.changed.connect(again)
	root.tree_exiting.connect(func() -> void:
		if s.changed.is_connected(again):
			s.changed.disconnect(again))


## A panel's box: the menus' surface and border, at `alpha` so the world shows
## through a little (opaque in high contrast).
static func panel_box(alpha := 0.92) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = MenuTheme.surface
	sb.bg_color.a = 1.0 if MenuTheme.high_contrast() else alpha
	sb.border_color = MenuTheme.accent if MenuTheme.high_contrast() else MenuTheme.line
	sb.set_border_width_all(2 if MenuTheme.high_contrast() else 1)
	sb.set_corner_radius_all(MenuTheme.RADIUS)
	sb.content_margin_left = 10
	sb.content_margin_right = 10
	sb.content_margin_top = 8
	sb.content_margin_bottom = 8
	return sb


## A Label: `size` a designed pixel size (0: the theme's), `col` its colour
## (alpha 0: the theme's text colour).
static func label(text: String, size := 0.0, col := Color(0, 0, 0, 0)) -> Label:
	var l := Label.new()
	l.text = text
	if size > 0.0:
		l.add_theme_font_size_override(&"font_size", px(size))
	if col.a > 0.0:
		l.add_theme_color_override(&"font_color", col)
	return l


static func _settings() -> Node:
	var loop := Engine.get_main_loop() as SceneTree
	if loop == null or loop.root == null:
		return null
	return loop.root.get_node_or_null("MenuSettings")
