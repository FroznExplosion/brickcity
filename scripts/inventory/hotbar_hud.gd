class_name HotbarHud
extends Control
## The items hands' HUD (Docs/Inventory.md 2): two hotbars of 9 at the bottom
## middle -- hotbar 1 under hotbar 2, the active one bright, its selected slot
## outlined -- the two off-hand slots in a column to their left, and the
## hand's name over them (`caption`). Drawn from an Inventory; `redraw` after
## it changes (the builder does, on `changed`).
##
## Icons are a swatch of the item's colour with its glyph for now; stage 4
## puts the rendered icons in.

const SLOT := 44
const GAP := 4
const BOTTOM := 64

var caption := ""
var inv: Inventory

var _rows: Array = [[], []]
var _off: Array = []
var _bars: Array[Control] = []
var _label: Label


func _init() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var w := Inventory.HOTBAR_SIZE * SLOT + (Inventory.HOTBAR_SIZE - 1) * GAP
	var h := 2 * SLOT + GAP
	var box := Control.new()
	box.anchor_left = 0.5
	box.anchor_right = 0.5
	box.anchor_top = 1.0
	box.anchor_bottom = 1.0
	box.offset_left = -w / 2.0
	box.offset_right = w / 2.0
	box.offset_top = -BOTTOM - h
	box.offset_bottom = -BOTTOM
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(box)
	for bar in 2:
		var row := Control.new()
		row.position = Vector2(0, (SLOT + GAP) * (1 - bar))
		row.size = Vector2(w, SLOT)
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(row)
		_bars.append(row)
		for i in Inventory.HOTBAR_SIZE:
			var p := _slot("%d" % (i + 1))
			p.position = Vector2(i * (SLOT + GAP), 0)
			row.add_child(p)
			_rows[bar].append(p)
	for i in Inventory.OFFHAND_SIZE:
		var p := _slot("")
		p.position = Vector2(-SLOT - 3 * GAP, (SLOT + GAP) * i)
		box.add_child(p)
		_off.append(p)
	_label = Label.new()
	_label.anchor_left = 0.5
	_label.anchor_right = 0.5
	_label.anchor_top = 1.0
	_label.anchor_bottom = 1.0
	_label.offset_left = -360
	_label.offset_right = 360
	_label.offset_top = -BOTTOM - h - 28
	_label.offset_bottom = -BOTTOM - h - 4
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_label.add_theme_constant_override("outline_size", 4)
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_label)


func bind(p_inv: Inventory) -> void:
	inv = p_inv
	redraw()


static func _small_label(text: String, font_px: int) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", font_px)
	l.add_theme_color_override("font_outline_color", Color.BLACK)
	l.add_theme_constant_override("outline_size", 3)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


func _slot(num: String) -> Panel:
	var p := Panel.new()
	p.size = Vector2(SLOT, SLOT)
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var swatch := ColorRect.new()
	swatch.name = "Swatch"
	swatch.position = Vector2(8, 8)
	swatch.size = Vector2(SLOT - 16, SLOT - 16)
	swatch.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_child(swatch)
	var glyph := _small_label("", 16)
	glyph.name = "Glyph"
	glyph.position = Vector2(8, 8)
	glyph.size = Vector2(SLOT - 16, SLOT - 16)
	glyph.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	glyph.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	p.add_child(glyph)
	var n := _small_label(num, 10)
	n.name = "Num"
	n.position = Vector2(3, 0)
	p.add_child(n)
	var count := _small_label("", 11)
	count.name = "Count"
	count.position = Vector2(0, SLOT - 18)
	count.size = Vector2(SLOT - 4, 16)
	count.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	p.add_child(count)
	return p


func redraw() -> void:
	if inv == null:
		return
	for bar in 2:
		var on := bar == inv.active_hotbar
		(_bars[bar] as Control).modulate = Color(1, 1, 1, 1.0 if on else 0.55)
		for i in Inventory.HOTBAR_SIZE:
			_fill(_rows[bar][i], inv.hotbars[bar][i], on and i == inv.active_slot, on)
	for i in Inventory.OFFHAND_SIZE:
		_fill(_off[i], inv.offhands[i], i == inv.active_offhand, true)
	_label.text = caption


func _fill(p: Panel, s: ItemStack, selected: bool, show_num: bool) -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.08, 0.1, 0.75)
	sb.set_border_width_all(3 if selected else 1)
	sb.border_color = Color(1, 1, 1) if selected else Color(0.35, 0.35, 0.4)
	p.add_theme_stylebox_override("panel", sb)
	var d := ItemCatalog.get_def(s.id) if s != null else {}
	var swatch := p.get_node("Swatch") as ColorRect
	swatch.visible = s != null
	if s != null:
		swatch.color = d.get("colour", Color.WHITE)
	(p.get_node("Glyph") as Label).text = str(d.get("glyph", "")) if s != null else ""
	(p.get_node("Num") as Label).visible = show_num
	var count := ""
	if s != null and (s.count > 1 or d.get("kind", "") == "bucket"):
		count = str(s.count) if d.get("kind", "") != "bucket" else "%d" % int(s.data.get("tiles", 0))
	if inv.creative and s != null and d.get("kind", "") == "block":
		count = ""          # creative: a block never runs out
	(p.get_node("Count") as Label).text = count
