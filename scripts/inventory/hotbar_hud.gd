class_name HotbarHud
extends Control
## The items hands' HUD (Docs/Inventory.md 2): two hotbars of 9 at the bottom
## middle -- hotbar 1 under hotbar 2, the active one bright, its selected slot
## outlined -- the two off-hand slots in a column to their left, and the
## hand's name over them (`caption`). Drawn from an Inventory; `redraw` after
## it changes (the builder does, on `changed`).
##
## The slots are the inventory screen's InvSlot (mouse ignored), so they draw
## the same rendered icons (ItemIcons); the hand's slot spins (stage 4).
##
## Round four: the off-hand slots are dim while the off-hand is down (or
## lowered by a two-handed item); the quick slot sits right of the bars,
## outlined and spinning while it is out (it is the hand then).

const SLOT := 44
const GAP := 4
const BOTTOM := 64

var caption := ""
var inv: Inventory

var _rows: Array = [[], []]
var _off: Array[InvSlot] = []
var _quick: InvSlot
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
			var s := _slot(Inventory.addr(StringName("hotbar_%d" % bar), i))
			s.number = "%d" % (i + 1)
			s.position = Vector2(i * (SLOT + GAP), 0)
			row.add_child(s)
			_rows[bar].append(s)
	for i in Inventory.OFFHAND_SIZE:
		var s := _slot(Inventory.addr(&"offhand", i))
		s.position = Vector2(-SLOT - 3 * GAP, (SLOT + GAP) * i)
		box.add_child(s)
		_off.append(s)
	_quick = _slot(Inventory.addr(&"quick", 0))
	_quick.position = Vector2(w + 3 * GAP, SLOT + GAP)
	box.add_child(_quick)
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


func _slot(a: Dictionary) -> InvSlot:
	var s := InvSlot.make(null, a)
	s.mouse_filter = Control.MOUSE_FILTER_IGNORE
	s.size = Vector2(SLOT, SLOT)
	return s


func bind(p_inv: Inventory) -> void:
	inv = p_inv
	for bar in 2:
		for s in _rows[bar]:
			(s as InvSlot).inv = inv
	for s in _off:
		s.inv = inv
	_quick.inv = inv
	redraw()


func redraw() -> void:
	if inv == null:
		return
	for bar in 2:
		var on := bar == inv.active_hotbar
		_bars[bar].modulate = Color(1, 1, 1, 1.0 if on else 0.55)
		for i in Inventory.HOTBAR_SIZE:
			var s: InvSlot = _rows[bar][i]
			var hand := on and i == inv.active_slot and not inv.quick_out
			s.selected = hand
			s.spin_always = hand and visible
			s.number = "%d" % (i + 1) if on else ""
			s.queue_redraw()
	var off_on := inv.offhand_up and not inv.offhand_lowered()
	for i in Inventory.OFFHAND_SIZE:
		_off[i].selected = i == inv.active_offhand and off_on
		_off[i].modulate = Color(1, 1, 1, 1.0 if off_on else 0.4)
		_off[i].queue_redraw()
	_quick.selected = inv.quick_out
	_quick.spin_always = inv.quick_out and visible
	_quick.modulate = Color(1, 1, 1, 1.0 if inv.quick_out else 0.6)
	_quick.queue_redraw()
	_label.text = caption
