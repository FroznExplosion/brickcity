class_name InventoryScreen
extends MenuScreen
## The inventory screen (Docs/Inventory.md 4, stage 3), opened with E or Tab
## from the items hands. A MenuScreen, so it fits any window: the slots size
## themselves to the room there is, and what still does not fit scrolls.
##
##   [Storage | Creative]          tabs (Creative only in creative)
##   chest  9 x 3                  when a chest is open (stage 5)
##   storage 9 x 3  -- or --  every catalog item (Creative)
##   off-hand | hotbar 2 / hotbar 1
##   what the mouse is over: name, what it is, what it does
##
## Mouse, Minecraft's (the rules are Inventory's):
##   left       take / put / merge / swap          right   half / one
##   shift+left the other side                      double  gather the same
##   drag       left: spread evenly, right: one each (press with a stack)
##   1-9 over a slot: swap it with that hotbar slot
## Creative: a catalog slot gives a full stack (shift: straight into the
## inventory); clicking one with a stack held throws the stack away (right: one).
##
## The world keeps running (Minecraft's): the host frees the mouse and holds
## the flight; every key goes here while open. E, Tab or Escape close it
## (Escape with a stack held puts the stack back first). The stack still held
## on close goes back into storage; if there is no room it is lost until
## there are dropped items (stage 5).
##
## `setup(inv, host)` before adding it; the host gets `inventory_closed()`.

const GAP := 4
const MIN_SLOT := 26.0
const MAX_SLOT := 52.0

var inv: Inventory
var host: Node
var page := "storage"

var _slots: Array[InvSlot] = []
var _hovered: InvSlot = null
var _chest_box: Control
var _storage_box: Control
var _creative_box: Control
var _creative_flow: HFlowContainer
var _info: Label
var _tab_storage: Button
var _tab_creative: Button
var _cursor: Control
var _slot_px := 44.0
## Where the last mouse motion sent to the screen was (not the OS pointer).
var _mouse_at := Vector2(-1, -1)


func setup(p_inv: Inventory, p_host: Node) -> void:
	inv = p_inv
	host = p_host
	screen_title = "Inventory"
	opaque_backdrop = false
	dim_backdrop = true


func _build_content() -> void:
	_tab_storage = Button.new()
	_tab_storage.text = "Storage"
	_tab_storage.toggle_mode = true
	_tab_storage.pressed.connect(func() -> void: show_page("storage"))
	header.add_child(_tab_storage)
	_tab_creative = Button.new()
	_tab_creative.text = "Creative"
	_tab_creative.toggle_mode = true
	_tab_creative.pressed.connect(func() -> void: show_page("creative"))
	header.add_child(_tab_creative)

	_chest_box = _section("Chest", _grid(&"chest", Inventory.CHEST_SIZE))
	content.add_child(_chest_box)
	_storage_box = _section("Storage", _grid(&"main", Inventory.MAIN_SIZE))
	content.add_child(_storage_box)
	_creative_flow = HFlowContainer.new()
	_creative_flow.add_theme_constant_override("h_separation", GAP)
	_creative_flow.add_theme_constant_override("v_separation", GAP)
	_creative_flow.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for id in ItemCatalog.ids():
		_add_slot(_creative_flow, InvSlot.make(inv, {}, id))
	_creative_box = _section("Creative: take any item (shift: into the inventory); a held stack clicked here is thrown away",
			_creative_flow)
	content.add_child(_creative_box)

	var hands := HBoxContainer.new()
	hands.add_theme_constant_override("separation", GAP * 3)
	var off := VBoxContainer.new()
	off.add_theme_constant_override("separation", GAP)
	for i in Inventory.OFFHAND_SIZE:
		_add_slot(off, InvSlot.make(inv, Inventory.addr(&"offhand", i)))
	hands.add_child(off)
	var bars := VBoxContainer.new()
	bars.add_theme_constant_override("separation", GAP)
	bars.add_child(_grid(&"hotbar_1", Inventory.HOTBAR_SIZE))
	bars.add_child(_grid(&"hotbar_0", Inventory.HOTBAR_SIZE))
	hands.add_child(bars)
	content.add_child(_section("Off-hand  |  hotbar 2 / hotbar 1", hands))

	_info = Label.new()
	MenuFit.fit_label(_info, true)
	_info.custom_minimum_size.y = MenuTheme.font_size() * 2.6
	_info.add_theme_color_override("font_color", MenuTheme.text_dim)
	content.add_child(_info)

	var close := Button.new()
	close.name = "Close"
	close.text = "Close (E)"
	close.pressed.connect(close_screen)
	footer.add_child(close)

	_cursor = CursorView.new()
	_cursor.inv = inv
	add_child(_cursor)

	inv.changed.connect(_refresh)
	show_page("storage")


func _exit_tree() -> void:
	super._exit_tree()
	if inv != null and inv.changed.is_connected(_refresh):
		inv.changed.disconnect(_refresh)


func _section(title: String, body_node: Control) -> VBoxContainer:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", GAP)
	var l := Label.new()
	l.text = title
	MenuFit.fit_label(l, true)
	l.add_theme_color_override("font_color", MenuTheme.text_dim)
	v.add_child(l)
	v.add_child(body_node)
	return v


func _grid(area: StringName, n: int) -> GridContainer:
	var g := GridContainer.new()
	g.columns = Inventory.HOTBAR_SIZE
	g.add_theme_constant_override("h_separation", GAP)
	g.add_theme_constant_override("v_separation", GAP)
	for i in n:
		_add_slot(g, InvSlot.make(inv, Inventory.addr(area, i)))
	return g


func _add_slot(parent: Node, s: InvSlot) -> void:
	s.custom_minimum_size = Vector2(_slot_px, _slot_px)
	s.pressed.connect(_on_slot_pressed)
	s.hovered.connect(_on_slot_hovered)
	parent.add_child(s)
	_slots.append(s)


func show_page(p: String) -> void:
	page = p if (p != "creative" or inv.creative) else "storage"
	_tab_creative.visible = inv.creative
	_tab_storage.button_pressed = page == "storage"
	_tab_creative.button_pressed = page == "creative"
	_storage_box.visible = page == "storage"
	_creative_box.visible = page == "creative"
	_refresh()


func _refresh() -> void:
	if _info == null:
		return
	_chest_box.visible = not inv.chest_key.is_empty()
	title_label.text = "Chest" if not inv.chest_key.is_empty() else "Inventory"
	for s in _slots:
		if not s.addr.is_empty():
			var a: Dictionary = s.addr
			s.selected = (a.area == inv.hotbar_area() and a.index == inv.active_slot) \
					or (a.area == &"offhand" and a.index == inv.active_offhand)
		s.queue_redraw()
	_cursor.visible = inv.cursor != null
	_cursor.queue_redraw()
	_show_info()


func _show_info() -> void:
	var s: ItemStack = _hovered.stack() if _hovered != null and is_instance_valid(_hovered) else null
	if s == null:
		_info.text = "Left: take / put   Right: half / one   Shift: the other side   Double: gather   Drag: spread   1-9 over a slot: to that hotbar slot   E: close"
		return
	var d := ItemCatalog.get_def(s.id)
	var line := "%s  (%s)" % [ItemCatalog.label(s), d.get("kind", "?")]
	if s.count > 1 and not (inv.creative and d.get("kind", "") == "block"):
		line += "  x%d" % s.count
	var desc := str(d.get("description", ""))
	_info.text = line + ("\n" + desc if not desc.is_empty() else "")


# ---------------------------------------------------------------------------
# Mouse

func _on_slot_hovered(s: InvSlot) -> void:
	_hovered = s
	if inv.is_dragging() and not s.addr.is_empty():
		inv.drag_touch(s.addr)
	_show_info()


func _on_slot_pressed(s: InvSlot, button: int, shift: bool, double: bool) -> void:
	if s.addr.is_empty():
		_creative_press(s, button, shift)
		return
	var a: Dictionary = s.addr
	if button == MOUSE_BUTTON_MIDDLE:
		if inv.creative and inv.cursor == null and s.stack() != null:
			var t := s.stack()
			inv.cursor = ItemStack.make(t.id, ItemCatalog.max_stack(t.id), t.data)
			inv.changed.emit()
		return
	if button == MOUSE_BUTTON_LEFT and shift:
		inv.shift_click(a)
	elif button == MOUSE_BUTTON_LEFT and double:
		inv.double_click(a)
	elif inv.cursor == null or (s.stack() != null and not s.stack().same_kind(inv.cursor)) \
			or not inv.slot_accepts(a, inv.cursor):
		# Nothing held, or a different item there: a plain click (pick up,
		# swap). Only a slot the held stack could go into starts a drag.
		if button == MOUSE_BUTTON_LEFT:
			inv.left_click(a)
		else:
			inv.right_click(a)
	else:
		inv.begin_drag(button)
		inv.drag_touch(a)


func _creative_press(s: InvSlot, button: int, shift: bool) -> void:
	if inv.cursor != null:
		if button == MOUSE_BUTTON_RIGHT:
			inv.cursor.count -= 1
			if inv.cursor.count <= 0:
				inv.cursor = null
		else:
			inv.cursor = null
		inv.changed.emit()
		return
	var id := s.item_id
	if shift:
		inv.add_item(ItemStack.make(id, ItemCatalog.max_stack(id)))
	else:
		inv.cursor = ItemStack.make(id, 1 if button == MOUSE_BUTTON_RIGHT else ItemCatalog.max_stack(id))
		inv.changed.emit()


func _slot_at(pos: Vector2) -> InvSlot:
	for s in _slots:
		if s.is_visible_in_tree() and s.get_global_rect().has_point(pos):
			return s
	return null


func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		# The held stack follows the motion the screen is sent (not the OS
		# pointer: a test window's events need not match it).
		_mouse_at = (event as InputEventMouseMotion).position
		_cursor.position = _mouse_at - _cursor.size * 0.5
		_cursor.queue_redraw()
		if inv.is_dragging():
			var s := _slot_at((event as InputEventMouseMotion).position)
			if s != null and not s.addr.is_empty():
				inv.drag_touch(s.addr)
		return
	if event is InputEventMouseButton and not event.pressed and inv.is_dragging():
		inv.finish_drag()
		return
	if not (event is InputEventKey):
		return
	var k := event as InputEventKey
	# Every key is the screen's while it is open: none walks, flies or fires.
	get_viewport().set_input_as_handled()
	if not k.pressed or k.echo:
		return
	match k.keycode:
		KEY_E, KEY_TAB:
			close_screen()
		KEY_ESCAPE:
			if inv.cursor != null:
				inv.return_cursor()
			else:
				close_screen()
		KEY_1, KEY_2, KEY_3, KEY_4, KEY_5, KEY_6, KEY_7, KEY_8, KEY_9:
			var i := k.keycode - KEY_1
			var s := _slot_at(_mouse_at)
			if s != null and not s.addr.is_empty():
				inv.swap_with_hotbar(s.addr, i)
			else:
				inv.select_slot(i)


func close_screen() -> void:
	inv.cancel_drag()
	if not inv.return_cursor():
		push_warning("[inventory] no room for the held stack: lost (dropped items are stage 5)")
		inv.cursor = null
	if host != null and host.has_method("inventory_closed"):
		host.inventory_closed()


func _on_back() -> bool:
	close_screen()
	return true


# ---------------------------------------------------------------------------
# Layout: the slots as big as the room allows

func _on_relayout(vp_size: Vector2) -> void:
	var w := available_width(vp_size)
	# 9 columns + the off-hand column beside the hotbars.
	var by_w := (w - GAP * 12.0) / 10.3
	var rows := 3.0 + 2.0 + (3.0 if inv != null and not inv.chest_key.is_empty() else 0.0)
	var by_h := (vp_size.y - 230.0) / (rows + 0.6)
	_slot_px = floorf(clampf(minf(by_w, by_h), MIN_SLOT, MAX_SLOT))
	for s in _slots:
		s.custom_minimum_size = Vector2(_slot_px, _slot_px)
	if _cursor != null:
		_cursor.size = Vector2(_slot_px, _slot_px)


## The held stack, drawn under the mouse over everything.
class CursorView extends Control:
	var inv: Inventory

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		top_level = true
		z_index = 10
		size = Vector2(44, 44)

	func _draw() -> void:
		if inv != null and inv.cursor != null:
			InvSlot.draw_stack(self, Rect2(Vector2.ZERO, size), inv.cursor, 0, false)
