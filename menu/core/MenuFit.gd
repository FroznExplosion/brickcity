class_name MenuFit
extends RefCounted
## The "nothing is ever cut off" checker, and the small layout helpers that make it pass.
##
## The rule the whole module is built to satisfy:
##
##     Every visible Control must lie inside its nearest CLIPPING ancestor.
##
## A clipping ancestor is a `ScrollContainer` (the player can reach the rest by scrolling), any
## Control with `clip_contents` on, or — for anything with neither above it — the viewport
## itself. Content that outgrows a scroll container is fine; content that outgrows the *screen*
## with no way to scroll to it is the bug, and `audit()` is what tells them apart.
##
## `audit()` is not a debug toy. `menu/tests/menu_fit_smoke.gd` runs it over every screen at a
## matrix of resolutions from 640x480 to 4K and ultrawide, and fails the build on any violation.

## Slack allowed before a rect counts as overflowing, in pixels. Rounding in container layout
## routinely lands half a pixel outside; a real clip is never this small.
const TOLERANCE := 1.5

## Below this viewport width, two-column layouts fold into one. Chosen so a 720p window at
## 1.75x interface scale (an effective 731px) still folds rather than crushing both columns.
const NARROW_WIDTH := 900.0
## Below this viewport height, screens drop decorative vertical padding and art.
const SHORT_HEIGHT := 560.0


## Walk `root` and return one Dictionary per overflowing Control:
##   { "path": String, "rect": Rect2, "clip": String, "clip_rect": Rect2, "overflow": Vector4 }
## `overflow` is how far out it pokes on each edge (left, top, right, bottom); only positive
## components are violations. An empty result means the screen fits.
static func audit(root: Node, viewport_rect: Rect2 = Rect2()) -> Array:
	var out: Array = []
	if root == null:
		return out
	var vp := viewport_rect
	if vp.size == Vector2.ZERO:
		var v := root.get_viewport() if root is Node else null
		vp = v.get_visible_rect() if v != null else Rect2(0, 0, 1920, 1080)
	_walk(root, vp, null, "viewport", vp, out, "")
	return out


## `clip_node` is the nearest clipping ANCESTOR — not the parent. A button three containers deep
## inside a ScrollContainer is still the scroll container's business, which is why this is
## threaded down the recursion rather than read from `node`.
static func _walk(node: Node, vp: Rect2, clip_node: Node, clip_name: String, clip_rect: Rect2,
		out: Array, path: String) -> void:
	for child in node.get_children():
		var p := path + "/" + String(child.name)
		var next_clip_node := clip_node
		var next_clip_name := clip_name
		var next_clip := clip_rect
		if child is Control:
			var c := child as Control
			if not c.is_visible_in_tree():
				continue
			# `top_level` Controls are positioned in viewport space on purpose (tooltips,
			# drag previews) — they are checked against the viewport, not their parent's clip.
			var top := c.top_level
			var against := vp if top else clip_rect
			var over := _overflow(c.get_global_rect(), against)
			if not top:
				over = _forgive_scrollable(over, clip_node)
			if over != Vector4.ZERO:
				out.append({
					"path": p,
					"class": c.get_class(),
					"rect": c.get_global_rect(),
					"clip": clip_name,
					"clip_rect": against,
					"overflow": over,
				})
			if _clips(c):
				next_clip_node = c
				next_clip_name = p
				next_clip = c.get_global_rect()
		_walk(child, vp, next_clip_node, next_clip_name, next_clip, out, p)


static func _clips(c: Control) -> bool:
	return c is ScrollContainer or c.clip_contents


## Overflowing a ScrollContainer along an axis it can actually scroll is not a violation — the
## player reaches it. Overflowing a `clip_contents` panel, or a scroll container with that axis
## disabled, is: that content is simply gone. This distinction is the whole point of the audit.
static func _forgive_scrollable(over: Vector4, container: Node) -> Vector4:
	var sc := container as ScrollContainer
	if sc == null:
		return over
	var out := over
	if sc.horizontal_scroll_mode != ScrollContainer.SCROLL_MODE_DISABLED:
		out.x = 0.0
		out.z = 0.0
	if sc.vertical_scroll_mode != ScrollContainer.SCROLL_MODE_DISABLED:
		out.y = 0.0
		out.w = 0.0
	return out if out.length_squared() > 0.0 else Vector4.ZERO


## Positive components = pixels sticking out past that edge. Zero vector = contained.
static func _overflow(r: Rect2, container: Rect2) -> Vector4:
	var v := Vector4(
		container.position.x - r.position.x,
		container.position.y - r.position.y,
		r.end.x - container.end.x,
		r.end.y - container.end.y)
	v.x = maxf(v.x - TOLERANCE, 0.0)
	v.y = maxf(v.y - TOLERANCE, 0.0)
	v.z = maxf(v.z - TOLERANCE, 0.0)
	v.w = maxf(v.w - TOLERANCE, 0.0)
	return v if v.length_squared() > 0.0 else Vector4.ZERO


## One-line-per-violation report, for test output and the F9 in-game overlay.
static func describe(violations: Array) -> String:
	if violations.is_empty():
		return "fits"
	var lines: Array[String] = []
	for v in violations:
		var d: Dictionary = v
		var o: Vector4 = d["overflow"]
		lines.append("  %s (%s) out by L%.0f T%.0f R%.0f B%.0f  of %s"
				% [d["path"], d["class"], o.x, o.y, o.z, o.w, d["clip"]])
	return "\n".join(lines)


# =====================================================================
# Layout helpers — the other half of the contract
# =====================================================================
## Page padding for a viewport of this size. Scales with the smaller dimension so a 4K screen
## does not get 12px gutters and a 480p one does not lose a third of its width to them.
static func page_padding(vp_size: Vector2) -> int:
	return int(clampf(minf(vp_size.x, vp_size.y) * 0.035, 10.0, 48.0))


static func is_narrow(vp_size: Vector2) -> bool:
	return vp_size.x < NARROW_WIDTH


static func is_short(vp_size: Vector2) -> bool:
	return vp_size.y < SHORT_HEIGHT


## Make a Label incapable of forcing a container wider than the screen — without making it
## incapable of being SEEN, which is the trap here.
##
## `Label.get_minimum_size()` drops the width to 1 if `clip_text` is on OR the overrun behaviour
## trims, which is the shrinking we want. But when autowrap is also on it drops the HEIGHT to 1
## as well, and `Label` defaults to `SIZE_SHRINK_CENTER` vertically — so its container hands it
## exactly one pixel of height, `get_visible_line_count()` becomes 0, and the label draws
## nothing at all. Every wrapping label in the module was invisible for this reason: option row
## labels, every hint line, the keybind instructions.
##
## Measured on 4.6.1, minimum size for a 156x23 string:
##
##     wrap  clip  trim -> min_size
##     off   off   off  -> (156, 23)   natural, can widen the row
##     off   any   any  -> (  1, 23)   shrinks, still draws        <- the no-wrap case
##     on    off   off  -> (  1, 23)   shrinks, wraps, still draws <- the wrap case
##     on    clip/trim  -> (  1,  1)   invisible                   <- what this used to do
##
## So the two modes need different flags, and neither needs both.
static func fit_label(l: Label, wrap_text: bool = true) -> Label:
	if wrap_text:
		# Autowrap alone already pins the minimum width at 1. Adding a trim on top buys nothing
		# and costs the height.
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.text_overrun_behavior = TextServer.OVERRUN_NO_TRIMMING
		l.clip_text = false
	else:
		# One line, never wider than its share: the ellipsis is what shrinks it, and with
		# autowrap off it only costs width.
		l.autowrap_mode = TextServer.AUTOWRAP_OFF
		l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		l.clip_text = true
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.size_flags_vertical = Control.SIZE_FILL
	return l


## Marks a button whose minimum width this file owns, so `refit_buttons` knows which ones it may
## re-measure and which ones a caller sized deliberately.
const BUTTON_AUTOWIDTH := &"menu_fit_autowidth"


## Same contract for buttons, and the same trap: `clip_text` takes a Button's minimum width down
## to its stylebox padding — 8px, an empty rounded box — and a Button in a BoxContainer defaults
## to `SIZE_FILL` without expand, so that is exactly what it gets. "Reset This Tab", "Reset
## Everything" and every per-row "Reset" rendered as blank boxes.
##
## Keep the ellipsis, then put the floor back: the text's natural width, capped against the
## window so a row of buttons still cannot outgrow a small screen. Sizing waits for `ready`
## because callers set `text` after calling this, and the theme font only resolves in the tree.
static func fit_button(b: Button) -> Button:
	b.clip_text = true
	b.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	b.autowrap_mode = TextServer.AUTOWRAP_OFF
	if b.is_node_ready():
		_auto_width(b)
	else:
		b.ready.connect(_auto_width.bind(b), CONNECT_ONE_SHOT)
	return b


## Re-measure every auto-width button under `root`. `MenuScreen` calls this on relayout, because
## the cap is a share of the window and the window changes.
static func refit_buttons(root: Node) -> void:
	if root == null:
		return
	for c in root.get_children():
		if c is Button and (c as Button).has_meta(BUTTON_AUTOWIDTH):
			_auto_width(c as Button)
		refit_buttons(c)


## The floor: the button's own text, never more than a share of the window. The cap is what
## keeps three buttons in one footer from demanding more than a 640px screen has, and it is why
## this is a share rather than a constant — a fixed 240px floor overflows exactly that case.
static func _auto_width(b: Button) -> void:
	if not is_instance_valid(b) or not b.is_inside_tree():
		return
	# A caller that set its own minimum before we ever ran meant it. Ours carries the meta.
	if b.custom_minimum_size.x > 0.0 and not b.has_meta(BUTTON_AUTOWIDTH):
		return
	var f := b.get_theme_font(&"font")
	if f == null:
		return
	b.set_meta(BUTTON_AUTOWIDTH, true)
	var pad := 0.0
	var box := b.get_theme_stylebox(&"normal")
	if box != null:
		pad = box.get_minimum_size().x
	var natural := f.get_string_size(b.text, HORIZONTAL_ALIGNMENT_LEFT, -1,
			b.get_theme_font_size(&"font_size")).x + pad
	b.custom_minimum_size.x = minf(natural, _button_cap(b))


static func _button_cap(c: Control) -> float:
	var vp := c.get_viewport()
	var w := vp.get_visible_rect().size.x if vp != null else 1280.0
	return clampf(w * 0.18, 56.0, 240.0)


# =====================================================================
# Collapse audit — the blind spot in `audit()`
# =====================================================================
## `audit()` proves nothing is CUT OFF. It cannot prove anything is VISIBLE: a label collapsed to
## one pixel of height fits inside its container perfectly and passes every overflow check ever
## written. That is not hypothetical — `fit_label` once set autowrap, `clip_text` and a trimming
## overrun together, which drops `Label.get_minimum_size()` to (1, 1), and every wrapping label
## in the module rendered nothing while the fit matrix stayed green.
##
## So this is the other half of the proof: a visible Control carrying text must be big enough for
## that text to appear. Returns one Dictionary per collapsed Control, same shape as `audit()`
## minus the overflow vector.
##
## Zero-size spacers and containers are ignored — only things with text to lose are checked.
static func audit_collapsed(root: Node) -> Array:
	var out: Array = []
	if root != null:
		_walk_collapsed(root, out, "")
	return out


static func _walk_collapsed(node: Node, out: Array, path: String) -> void:
	for child in node.get_children():
		var p := path + "/" + String(child.name)
		if child is Control:
			var c := child as Control
			if not c.is_visible_in_tree():
				continue
			var reason := _collapse_reason(c)
			if reason != "":
				out.append({"path": p, "class": c.get_class(), "rect": c.get_global_rect(),
						"reason": reason})
		_walk_collapsed(child, out, p)


## "" when the control is fine. Text-bearing controls only: a Label or Button with something to
## say needs at least one line of height and more than a sliver of width.
static func _collapse_reason(c: Control) -> String:
	var text := ""
	if c is Label:
		text = (c as Label).text
	elif c is Button:
		text = (c as Button).text
	if text.strip_edges() == "":
		return ""
	var size := c.get_global_rect().size
	# One line of the control's own font, less a pixel of rounding slack.
	var line := 8.0
	var f := c.get_theme_font(&"font")
	if f != null:
		line = f.get_height(c.get_theme_font_size(&"font_size")) - 1.0
	if size.y < line:
		return "height %.0f < one line (%.0f) — text cannot render" % [size.y, line]
	if size.x <= 2.0:
		return "width %.0f — nothing can be read" % size.x
	if c is Label and (c as Label).get_visible_line_count() <= 0:
		return "no visible lines"
	return ""


## One line per collapsed control, for test output.
static func describe_collapsed(violations: Array) -> String:
	if violations.is_empty():
		return "all visible"
	var lines: Array[String] = []
	for v in violations:
		var d: Dictionary = v
		lines.append("  %s (%s) %s" % [d["path"], d["class"], d["reason"]])
	return "\n".join(lines)
