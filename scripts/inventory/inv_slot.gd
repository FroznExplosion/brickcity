class_name InvSlot
extends Control
## One slot of the inventory screen (Docs/Inventory.md 4, stage 3): draws the
## stack at `addr` in `inv` (or, a creative slot, the catalog item `item_id`)
## and says when it is pressed or hovered. The screen does the rules.
##
## Knows nothing of the screen (signals only): the screen types InvSlot, so
## this must not type the screen back (a class_name cycle leaks and crashes
## the quit, see memory "GDScript class cycle").

signal pressed(slot: InvSlot, button: int, shift: bool, double: bool)
signal hovered(slot: InvSlot)

var inv: Inventory
## The slot's address in the inventory, or {} for a creative slot.
var addr := {}
## A creative slot's item.
var item_id: StringName = &""
## Outlined: the hand's slot, or the active off-hand.
var selected := false


static func make(p_inv: Inventory, p_addr: Dictionary, p_item := &"") -> InvSlot:
	var s := InvSlot.new()
	s.inv = p_inv
	s.addr = p_addr
	s.item_id = p_item
	s.custom_minimum_size = Vector2(44, 44)
	s.mouse_filter = Control.MOUSE_FILTER_STOP
	s.focus_mode = Control.FOCUS_NONE
	return s


func _ready() -> void:
	mouse_entered.connect(func() -> void:
		hovered.emit(self)
		queue_redraw())
	mouse_exited.connect(queue_redraw)


## What the slot shows: the inventory's stack, or a full stack of the catalog item.
func stack() -> ItemStack:
	if addr.is_empty():
		return ItemStack.make(item_id, ItemCatalog.max_stack(item_id)) if item_id != &"" else null
	return inv.get_slot(addr) if inv != null else null


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		var mb := event as InputEventMouseButton
		if mb.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE]:
			pressed.emit(self, mb.button_index, mb.shift_pressed, mb.double_click)
			accept_event()


func _draw() -> void:
	var r := Rect2(Vector2.ZERO, size)
	var hot := get_global_rect().has_point(get_global_mouse_position())
	draw_rect(r, Color(0.07, 0.075, 0.09, 0.92) if not hot else Color(0.16, 0.17, 0.2, 0.95))
	var border := Color(1, 1, 1) if selected else Color(0.32, 0.34, 0.4)
	draw_rect(r.grow(-1.0), border, false, 3.0 if selected else 1.0)
	var s := stack()
	var extra := 0
	if not addr.is_empty() and inv != null and inv.is_dragging():
		extra = inv.drag_amount_for(addr)
		if s == null and extra > 0:
			s = ItemStack.make(inv.cursor.id, 0, inv.cursor.data)
	draw_stack(self, r, s, extra, addr.is_empty() or (inv != null and inv.creative))


## A stack's icon in `r`: a swatch of its colour, its glyph, its count (plus
## `extra` a drag would add, shown faint). Shared with the cursor.
## `endless`: a creative block, no count.
static func draw_stack(ci: CanvasItem, r: Rect2, s: ItemStack, extra := 0, endless := false) -> void:
	if s == null or s.id == &"":
		return
	var d := ItemCatalog.get_def(s.id)
	var inner := r.grow(-r.size.x * 0.2)
	var col: Color = d.get("colour", Color.WHITE)
	if s.count <= 0:
		col.a = 0.45
	ci.draw_rect(inner, col)
	ci.draw_rect(inner, col.darkened(0.45), false, 1.0)
	var font: Font = ThemeDB.fallback_font
	var g := str(d.get("glyph", ""))
	if not g.is_empty():
		var fs := int(r.size.y * 0.36)
		var gs := font.get_string_size(g, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
		var at := r.position + Vector2((r.size.x - gs.x) * 0.5, (r.size.y + fs * 0.7) * 0.5)
		ci.draw_string_outline(font, at, g, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, 3, Color.BLACK)
		ci.draw_string(font, at, g, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color.WHITE)
	var txt := ""
	var kind := str(d.get("kind", ""))
	if kind == "bucket":
		txt = str(int(s.data.get("tiles", 0)))
	elif not (endless and kind == "block") and s.count + extra > 1:
		txt = str(s.count + extra)
	if txt.is_empty():
		return
	var cs := int(r.size.y * 0.3)
	var w := font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, cs).x
	var p := r.position + Vector2(r.size.x - w - 3.0, r.size.y - 4.0)
	ci.draw_string_outline(font, p, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, cs, 3, Color.BLACK)
	ci.draw_string(font, p, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, cs,
			Color(1.0, 0.9, 0.5) if extra > 0 else Color.WHITE)
