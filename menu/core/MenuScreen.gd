class_name MenuScreen
extends Control
## Base class for every screen in the module. Subclasses fill `content` and `footer`; the
## scaffold below is what guarantees they stay on screen.
##
## The scaffold, outermost first:
##
##     MenuScreen        full rect, so it is exactly the viewport
##     └ Backdrop        optional flat fill / dim
##     └ SafeMargin      page padding + safe-area inset
##       └ Frame         header · separator · body · footer
##         └ Body        ScrollContainer, follow_focus on   <- the escape valve
##           └ content   what the subclass builds
##
## Two rules do the actual work:
##
##   1. **The body is always a ScrollContainer.** Content that does not fit becomes scrollable
##      rather than clipped, so no arrangement of text scale, interface scale, translated
##      strings and window size can put a control out of reach.
##   2. **The safe margin is recomputed from the live viewport**, not baked at build time — on
##      resize, on interface-scale change, and on safe-area change.
##
## `MenuFit.audit(self)` returns the violations; `menu/tests/menu_fit_smoke.gd` asserts it is
## empty for every screen across a resolution matrix.
##
## Safe-area double-count: a game's UISafeArea autoload insets by transforming CanvasLayers. A
## `Control` main scene has no CanvasLayer above it and is therefore missed entirely, which is
## why this class applies the inset itself — but only when it is NOT already under a layer that
## got the transform, or the inset would be applied twice.

## Big text at the top. Empty hides the whole header.
@export var screen_title: String = ""
## Floor for the vertical-scrollbar reservation used when sizing fixed-width panels. The bar
## only appears when the page is long, but a panel sized as if it never will is a panel that
## overflows on the pages where it does. The real width is measured — this is the fallback.
const SCROLLBAR_ALLOWANCE := 10.0

## Draw the flat page background. Overlays (pause) turn this off and use `dim_backdrop`.
@export var opaque_backdrop: bool = true
## Darken whatever is behind instead of covering it. Used by the pause menu.
@export var dim_backdrop: bool = false

var backdrop: ColorRect
var safe_margin: MarginContainer
var frame: VBoxContainer
## Header and footer are FLOW containers, not boxes. A row of buttons whose minimum widths add
## up to more than the screen has nowhere to go in an HBoxContainer — it simply grows past the
## viewport, dragging the whole scaffold with it. A flow container wraps to a second line
## instead, which is the only arrangement that survives long labels on a small window.
var header: HFlowContainer
var title_label: Label
var body: ScrollContainer
## Subclasses put their rows here.
var content: VBoxContainer
## Subclasses put their bottom-row buttons here. Hidden while empty.
var footer: HFlowContainer

var _separator: HSeparator
var _built := false


func _ready() -> void:
	# Menus run while the tree is paused — that is the entire point of a pause menu.
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	theme = MenuTheme.theme()
	_build_scaffold()
	_built = true
	_build_content()
	_relayout()
	# Focus lands after the first layout pass, so gamepad and keyboard have somewhere to start.
	_grab_initial_focus.call_deferred()


## Signal wiring lives on the tree-entry pair, NOT in `_ready`. `_ready` runs once; `_exit_tree`
## runs on every removal. Connecting in one and disconnecting in the other means a screen that is
## removed and re-added comes back deaf to window resizes — it keeps whatever layout it had when
## it left. `_relayout` is safe this early because it returns until the scaffold exists.
func _enter_tree() -> void:
	var vp := get_viewport()
	if vp != null and not vp.size_changed.is_connected(_relayout):
		vp.size_changed.connect(_relayout)
	var s := _settings()
	if s != null and not s.changed.is_connected(_on_setting_changed):
		s.changed.connect(_on_setting_changed)


func _exit_tree() -> void:
	var vp := get_viewport()
	if vp != null and vp.size_changed.is_connected(_relayout):
		vp.size_changed.disconnect(_relayout)
	var s := _settings()
	if s != null and s.changed.is_connected(_on_setting_changed):
		s.changed.disconnect(_on_setting_changed)


# =====================================================================
# Scaffold
# =====================================================================
func _build_scaffold() -> void:
	backdrop = ColorRect.new()
	backdrop.name = "Backdrop"
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if dim_backdrop:
		backdrop.color = Color(0.02, 0.02, 0.03, 0.82)
	elif opaque_backdrop:
		backdrop.color = MenuTheme.bg
	else:
		backdrop.color = Color(0, 0, 0, 0)
	add_child(backdrop)

	safe_margin = MarginContainer.new()
	safe_margin.name = "SafeMargin"
	safe_margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(safe_margin)

	frame = VBoxContainer.new()
	frame.name = "Frame"
	frame.add_theme_constant_override("separation", 12)
	safe_margin.add_child(frame)

	header = HFlowContainer.new()
	header.name = "Header"
	header.add_theme_constant_override("separation", 12)
	frame.add_child(header)

	title_label = Label.new()
	title_label.name = "Title"
	title_label.text = screen_title
	MenuFit.fit_label(title_label, false)
	title_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	header.add_child(title_label)

	_separator = HSeparator.new()
	frame.add_child(_separator)

	body = ScrollContainer.new()
	body.name = "Body"
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# follow_focus is what makes gamepad and Tab navigation usable: moving focus to a row
	# below the fold scrolls it into view instead of leaving the player looking at nothing.
	body.follow_focus = true
	body.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	# Horizontal AUTO is the last-resort escape valve. Rows are built to never need it, and
	# the fit test asserts they do not — but if a translation or a 1.75x text scale ever wins,
	# the player gets a scrollbar rather than an unreachable button.
	body.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	frame.add_child(body)

	content = VBoxContainer.new()
	content.name = "Content"
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 8)
	body.add_child(content)

	footer = HFlowContainer.new()
	footer.name = "Footer"
	footer.alignment = FlowContainer.ALIGNMENT_END
	footer.add_theme_constant_override("separation", 10)
	frame.add_child(footer)


## Subclass hook — `content` and `footer` exist and are empty when this runs.
func _build_content() -> void:
	pass


# =====================================================================
# Layout
# =====================================================================
func _relayout() -> void:
	if not _built:
		return
	var vp_size := _viewport_size()
	var pad := MenuFit.page_padding(vp_size)
	var inset := _extra_inset(vp_size)
	safe_margin.add_theme_constant_override("margin_left", pad + int(inset.x))
	safe_margin.add_theme_constant_override("margin_right", pad + int(inset.y))
	safe_margin.add_theme_constant_override("margin_top", pad + int(inset.z))
	safe_margin.add_theme_constant_override("margin_bottom", pad + int(inset.w))

	var short := MenuFit.is_short(vp_size)
	frame.add_theme_constant_override("separation", 6 if short else 12)
	title_label.add_theme_font_size_override("font_size",
			MenuTheme.font_size(1.5 if short else 2.1))
	var has_title := screen_title != ""
	header.visible = has_title or header.get_child_count() > 1
	_separator.visible = header.visible
	footer.visible = footer.get_child_count() > 0
	# Button minimum widths are a share of the window, so they are stale the moment it changes.
	MenuFit.refit_buttons(self)
	_on_relayout(vp_size)


## Subclass hook for responsive reflow (fold two columns into one, hide art on short screens).
func _on_relayout(_vp_size: Vector2) -> void:
	pass


## Width actually available to `content` — the viewport MINUS page padding, the safe-area inset
## and room for a scrollbar. Any fixed-width panel must be capped by this and not by the raw
## viewport width: at 640px with a 15% safe area on both edges the two differ by more than 200
## pixels, which is the whole gap between "fits" and "scrolls sideways".
func available_width(vp_size: Vector2 = Vector2.ZERO) -> float:
	var vp := vp_size if vp_size != Vector2.ZERO else _viewport_size()
	var pad := float(MenuFit.page_padding(vp))
	var inset := _extra_inset(vp)
	return maxf(vp.x - pad * 2.0 - inset.x - inset.y - _scrollbar_allowance(), 120.0)


## Room to leave for the vertical scrollbar. MEASURED from the live bar rather than assumed:
## the bar's width comes from the theme, and a theme change that widened it used to silently
## turn "fits exactly" into "scrolls sideways by four pixels".
func _scrollbar_allowance() -> float:
	var measured := 0.0
	if body != null:
		var bar := body.get_v_scroll_bar()
		if bar != null:
			measured = bar.get_combined_minimum_size().x
	return maxf(measured, SCROLLBAR_ALLOWANCE) + 4.0


## Safe-area inset in pixels (left, right, top, bottom), or zero when a CanvasLayer above us has
## already been transformed by the game's UISafeArea — applying it twice would inset twice.
func _extra_inset(vp_size: Vector2) -> Vector4:
	if _under_transformed_layer():
		return Vector4.ZERO
	var s := _settings()
	if s == null:
		return Vector4.ZERO
	var f: Vector4 = s.safe_insets()
	return Vector4(vp_size.x * f.x, vp_size.x * f.y, vp_size.y * f.z, vp_size.y * f.w)


func _under_transformed_layer() -> bool:
	var s := _settings()
	if s == null or s.safe_area_node() == null:
		return false
	var n: Node = get_parent()
	while n != null:
		if n is CanvasLayer:
			# Mirrors UISafeArea's own opt-outs: a layer it skips did not get the transform,
			# so a screen inside it still has to inset itself.
			var cl := n as CanvasLayer
			if cl.is_in_group("ui_no_safe_area"):
				return false
			return not (cl.transform == Transform2D.IDENTITY and _insets_are_zero())
		n = n.get_parent()
	return false


func _insets_are_zero() -> bool:
	var s := _settings()
	if s == null:
		return true
	var f: Vector4 = s.safe_insets()
	return f.length_squared() < 0.000001


func _viewport_size() -> Vector2:
	var vp := get_viewport()
	return vp.get_visible_rect().size if vp != null else Vector2(1920, 1080)


func _on_setting_changed(id: StringName, _value: Variant) -> void:
	match id:
		&"text_scale", &"high_contrast":
			theme = MenuTheme.theme()
			_relayout()
		&"ui_scale", &"safe_left", &"safe_right", &"safe_top", &"safe_bottom":
			_relayout.call_deferred()


func _settings() -> Node:
	var tree := get_tree()
	if tree == null or tree.root == null:
		return null
	return tree.root.get_node_or_null("MenuSettings")


# =====================================================================
# Navigation
# =====================================================================
func _gui_input(_event: InputEvent) -> void:
	pass


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		if _on_back():
			get_viewport().set_input_as_handled()


## Return true when the screen consumed Back. Default: nothing to go back to.
func _on_back() -> bool:
	return false


## First control that should hold focus. Default: the first focusable in `content`, else footer.
func _first_focus() -> Control:
	var c := _find_focusable(content)
	return c if c != null else _find_focusable(footer)


func _grab_initial_focus() -> void:
	var c := _first_focus()
	if c != null and c.is_inside_tree():
		c.grab_focus()


func _find_focusable(root: Node) -> Control:
	if root == null:
		return null
	for child in root.get_children():
		if child is Control:
			var c := child as Control
			if c.focus_mode != Control.FOCUS_NONE and c.is_visible_in_tree() \
					and not (c is BaseButton and (c as BaseButton).disabled):
				return c
		var deeper := _find_focusable(child)
		if deeper != null:
			return deeper
	return null


# =====================================================================
# Self-check
# =====================================================================
## Controls currently sticking out of their clipping ancestor. Empty is the passing state.
func audit_fit() -> Array:
	return MenuFit.audit(self, Rect2(Vector2.ZERO, _viewport_size()))


## True when the body's horizontal escape valve is actually needed — the layout did NOT fit the
## width. Nothing is lost when it happens (the player gets a scrollbar), but it means a row
## refused to shrink, so the fit test treats it as a failure rather than a shrug.
func needs_horizontal_scroll() -> bool:
	if body == null:
		return false
	var bar := body.get_h_scroll_bar()
	return bar != null and bar.max_value > bar.page + 2.0
