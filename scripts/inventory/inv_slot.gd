class_name InvSlot
extends Control
## One slot of the inventory screen (Docs/Inventory.md 4, stage 3): draws the
## stack at `addr` in `inv` (or, a creative slot, the catalog item `item_id`)
## and says when it is pressed or hovered. The screen does the rules.
##
## The icon (ItemIcons) spins while the mouse is on the slot, grows 1.18x,
## and eases home when it leaves -- zylanntest's SlotHoverFx. `spin_always`
## (the HUD's hand slot) keeps it turning.
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
## Spin whether hovered or not (the HUD's hand slot).
var spin_always := false:
	set(v):
		spin_always = v
		if v:
			set_process(true)
## The slot's number, drawn top left (the HUD), or "".
var number := ""
## A slot that only shows an item (the Recipes list): this many, counted
## even for blocks. 0: a creative slot (a full stack, no count on blocks).
var show_count := 0
## Minecraft's look (McStyle): a sunken grey slot instead of the HUD's dark one.
var mc := false
## Bedrock's red cell: a recipe that cannot be made, an ingredient lacking.
var bad := false
## Framed white: the recipe picked in the recipe book.
var picked := false
## The size of one Minecraft pixel for the bevel (the screen sets it).
var unit := 2.0
## Drawn faint in an empty slot: what the picked recipe wants there.
var ghost: StringName = &"" 
var _hot := false
var _angle := 0.0
var _grow := 1.0

const SPIN := 2.4
const SETTLE := 9.0
const HOVER_SCALE := 1.18


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
	set_process(spin_always)
	mouse_entered.connect(func() -> void:
		_hot = true
		set_process(true)
		hovered.emit(self)
		queue_redraw())
	mouse_exited.connect(func() -> void:
		_hot = false
		queue_redraw())


## What the slot shows: the inventory's stack, or a full stack of the catalog item.
func stack() -> ItemStack:
	if addr.is_empty():
		if item_id == &"":
			return null
		return ItemStack.make(item_id, show_count if show_count > 0 else ItemCatalog.max_stack(item_id))
	return inv.get_slot(addr) if inv != null else null


func _process(delta: float) -> void:
	var on := _hot or spin_always
	if on:
		_angle = fposmod(_angle + SPIN * delta, TAU)
	else:
		_angle = lerp_angle(_angle, 0.0, clampf(SETTLE * delta, 0.0, 1.0))
	var want := HOVER_SCALE if _hot else 1.0
	_grow = lerpf(_grow, want, clampf(10.0 * delta, 0.0, 1.0))
	if not on and absf(wrapf(_angle, -PI, PI)) < 0.02 and absf(_grow - 1.0) < 0.003:
		_angle = 0.0
		_grow = 1.0
		set_process(false)
	queue_redraw()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		var mb := event as InputEventMouseButton
		if mb.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE]:
			pressed.emit(self, mb.button_index, mb.shift_pressed, mb.double_click)
			accept_event()


func _draw() -> void:
	var r := Rect2(Vector2.ZERO, size)
	if mc:
		var fill := McStyle.SLOT
		if bad:
			fill = McStyle.BAD_HOVER if _hot else McStyle.BAD
		elif _hot and mouse_filter != Control.MOUSE_FILTER_IGNORE:
			fill = McStyle.SLOT_HOVER
		McStyle.draw_slot(self, r, unit, fill)
		if selected or picked:
			draw_rect(r.grow(-maxf(1.0, unit)), McStyle.LIGHT, false, maxf(2.0, roundf(unit * 1.5)))
	else:
		draw_rect(r, Color(0.07, 0.075, 0.09, 0.92) if not _hot else Color(0.16, 0.17, 0.2, 0.95))
		var border := Color(1, 1, 1) if selected else Color(0.32, 0.34, 0.4)
		draw_rect(r.grow(-1.0), border, false, 3.0 if selected else 1.0)
	var s := stack()
	if s == null and ghost != &"":
		ItemIcons.draw_icon(self, r.grow(-r.size.x * 0.12), ghost, 0.0, Color(1, 1, 1, 0.35))
	var extra := 0
	if not addr.is_empty() and inv != null and inv.is_dragging():
		extra = inv.drag_amount_for(addr)
		if s == null and extra > 0:
			s = ItemStack.make(inv.cursor.id, 0, inv.cursor.data)
	var endless := (addr.is_empty() and show_count == 0) or (inv != null and inv.creative and not addr.is_empty())
	draw_stack(self, r, s, extra, endless, _angle, _grow)
	if not number.is_empty():
		var font: Font = ThemeDB.fallback_font
		var fs := int(size.y * 0.24)
		draw_string_outline(font, Vector2(3, fs + 1), number, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, 3, Color.BLACK)
		draw_string(font, Vector2(3, fs + 1), number, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color.WHITE)


## A stack's icon in `r`: its rendered icon turned `angle` and grown `grow`
## (ItemIcons), or without icons a swatch of its colour and its glyph; then
## its count (plus `extra` a drag would add, shown gold). Shared with the
## cursor and the HUD. `endless`: a creative block, no count.
static func draw_stack(ci: CanvasItem, r: Rect2, s: ItemStack, extra := 0, endless := false,
		angle := 0.0, grow := 1.0) -> void:
	if s == null or s.id == &"":
		return
	var d := ItemCatalog.get_def(s.id)
	var font: Font = ThemeDB.fallback_font
	var tint := Color(1, 1, 1, 0.45 if s.count <= 0 else 1.0)
	var icon := r.grow(-r.size.x * 0.06)
	icon = Rect2(icon.get_center() - icon.size * grow * 0.5, icon.size * grow)
	var g := str(d.get("glyph", ""))
	if ItemIcons.draw_icon(ci, icon, s.id, angle, tint):
		g = ""
	else:
		var inner := r.grow(-r.size.x * 0.2)
		var col: Color = d.get("colour", Color.WHITE)
		col.a = tint.a
		ci.draw_rect(inner, col)
		ci.draw_rect(inner, col.darkened(0.45), false, 1.0)
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
