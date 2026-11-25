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
## on close goes back into storage; if there is no room it is thrown in front
## of the player (DroppedItems). Q over a slot drops one, Shift+Q the stack.
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
## The storage: the worn backpack's slots (Docs/Inventory.md 8), rebuilt when
## the backpack changes; its label says which backpack.
var _storage_grid: GridContainer
var _storage_label: Label
var _storage_n := -1
## The Craft page (Docs/Inventory.md 12): every recipe, what can be made now
## first, then what is missing for the rest.
var _craft_box: Control
var _craft_list: VBoxContainer
var _craft_label: Label
var _tab_craft: Button
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
	_tab_craft = Button.new()
	_tab_craft.text = "Craft"
	_tab_craft.toggle_mode = true
	_tab_craft.pressed.connect(func() -> void: show_page("craft"))
	header.add_child(_tab_craft)

	_chest_box = _section("Chest", _grid(&"chest", Inventory.CHEST_SIZE))
	content.add_child(_chest_box)
	# The storage is the worn backpack's slots (its slot is with the hands,
	# below, so it shows on the Creative tab too).
	_storage_grid = GridContainer.new()
	_storage_grid.columns = Inventory.HOTBAR_SIZE
	_storage_grid.add_theme_constant_override("h_separation", GAP)
	_storage_grid.add_theme_constant_override("v_separation", GAP)
	_storage_box = _section("Storage", _storage_grid)
	_storage_label = _storage_box.get_child(0) as Label
	content.add_child(_storage_box)
	_rebuild_storage()
	# Crafting, Terraria's (Docs/Inventory.md 12): the Craft page lists the
	# recipes, what can be made first.
	_craft_list = VBoxContainer.new()
	_craft_list.add_theme_constant_override("separation", GAP * 2)
	_craft_box = _section("Craft  |  Make: one  ·  All: as many as you can  ·  stations count within 4 m",
			_craft_list)
	_craft_label = _craft_box.get_child(0) as Label
	content.add_child(_craft_box)
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
	var bp := VBoxContainer.new()
	bp.add_theme_constant_override("separation", GAP)
	_add_slot(bp, InvSlot.make(inv, Inventory.addr(&"backpack")))
	hands.add_child(bp)
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
	content.add_child(_section("Backpack  |  off-hand  |  hotbar 2 / hotbar 1", hands))

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


## The Craft page: one row a recipe -- what it makes (its icon), its name,
## what it takes and where -- with Make / All; the ones that can be made
## first, the rest after with what they lack. Rebuilt when the inventory
## changes while it shows (a few dozen rows).
func _rebuild_craft() -> void:
	for c in _craft_list.get_children():
		c.queue_free()
	var near: Array = host.stations_near() if host != null and host.has_method("stations_near") else []
	var names := PackedStringArray()
	for st in near:
		names.append(str(ItemCatalog.get_def(st).get("name", st)))
	_craft_label.text = "Craft  |  stations in reach: %s  ·  Make: one  ·  All: as many as you can" % (
			", ".join(names) if not names.is_empty() else "none (by hand only)")
	var can: Array = []
	var cannot: Array = []
	for r in RecipeBook.all():
		(can if inv.can_craft(r, near) else cannot).append(r)
	for r in can + cannot:
		var ok: bool = inv.can_craft(r, near)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", GAP * 3)
		row.modulate = Color(1, 1, 1, 1.0 if ok else 0.5)
		row.add_child(_show_slot(r.output, int(r.count)))
		var parts := PackedStringArray()
		for inp in r.inputs:
			parts.append("%s (%d)" % [RecipeBook.input_name(inp), inv.count_of(inp)])
		var l := Label.new()
		var lack := inv.missing(r, near)
		l.text = "%s%s  ·  %s\n%s%s" % [r.name, "  x%d" % r.count if int(r.count) > 1 else "",
				RecipeBook.station_name(r), " + ".join(parts),
				"" if ok else "   --  needs " + ", ".join(lack)]
		MenuFit.fit_label(l, true)
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(l)
		for all in [false, true]:
			var b := Button.new()
			b.text = "All" if all else "Make"
			b.disabled = not ok
			# No focus: a click must not scroll the page under the mouse.
			b.focus_mode = Control.FOCUS_NONE
			b.set_meta("recipe", r.name)
			b.set_meta("all", all)
			b.pressed.connect(_make.bind(r, all))
			row.add_child(b)
		_craft_list.add_child(row)


func _make(r: Dictionary, all: bool) -> void:
	var near: Array = host.stations_near() if host != null and host.has_method("stations_near") else []
	var res := inv.craft(r, near, all)
	for s in res.left:
		if host != null and host.has_method("drop_from_player"):
			host.drop_from_player(s)


## A slot that only shows (the Recipes list): no clicks.
func _show_slot(id: StringName, n: int) -> InvSlot:
	var s := InvSlot.make(null, {}, id)
	s.show_count = n
	s.mouse_filter = Control.MOUSE_FILTER_IGNORE
	s.custom_minimum_size = Vector2(_slot_px * 0.7, _slot_px * 0.7)
	s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	s.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	return s


## An item with tag `tag`, to draw for a "#tag" cell.
func _tag_example(tag: String) -> StringName:
	for id in ItemCatalog.ids():
		if PackedStringArray(ItemCatalog.get_def(id).get("tags", [])).has(tag):
			return id
	return &""


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
	_tab_craft.button_pressed = page == "craft"
	_storage_box.visible = page == "storage"
	_craft_box.visible = page == "craft"
	_creative_box.visible = page == "creative"
	_refresh()
	_relayout()            # the slot size depends on what the page shows


## The storage grid as big as the worn backpack (none: no slots).
func _rebuild_storage() -> void:
	var n := inv.area_size(&"main")
	if n == _storage_n:
		return
	_storage_n = n
	for c in _storage_grid.get_children():
		_slots.erase(c)
		c.queue_free()
	for i in n:
		_add_slot(_storage_grid, InvSlot.make(inv, Inventory.addr(&"main", i)))
	if inv.backpack == null:
		_storage_label.text = "Storage  |  no backpack worn: put one in the backpack slot"
	else:
		_storage_label.text = "Storage  |  %s, %d slots" % [ItemCatalog.get_def(inv.backpack.id).get("name", "?"), n]


func _refresh() -> void:
	if _info == null:
		return
	_rebuild_storage()
	if page == "craft":
		_rebuild_craft()
	_chest_box.visible = not inv.chest_key.is_empty()
	title_label.text = inv.chest_title if not inv.chest_key.is_empty() else "Inventory"
	(_chest_box.get_child(0) as Label).text = inv.chest_title
	for s in _slots:
		if not s.addr.is_empty() and s.addr.area == &"chest":
			# A backpack put down has fewer slots than a chest.
			s.visible = int(s.addr.index) < inv.area_size(&"chest")
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
		KEY_Q:
			# Drop one from the slot under the mouse (Shift: the stack) --
			# zylanntest's Q. The host throws it in front of the player.
			var s := _slot_at(_mouse_at)
			if s != null and not s.addr.is_empty() and host != null and host.has_method("drop_from_player"):
				var out := inv.take_from(s.addr, k.shift_pressed)
				if out != null:
					host.drop_from_player(out)
		KEY_1, KEY_2, KEY_3, KEY_4, KEY_5, KEY_6, KEY_7, KEY_8, KEY_9:
			var i := k.keycode - KEY_1
			var s := _slot_at(_mouse_at)
			if s != null and not s.addr.is_empty():
				inv.swap_with_hotbar(s.addr, i)
			else:
				inv.select_slot(i)


func close_screen() -> void:
	inv.cancel_drag()
	var thrown := []
	if not inv.return_cursor():
		# No room: it is thrown in front of the player, not lost.
		thrown.append(inv.cursor)
		inv.cursor = null
	# What is left in the craft grid goes back too (Minecraft's).
	thrown.append_array(inv.clear_craft())
	if host != null and host.has_method("drop_from_player"):
		for s in thrown:
			host.drop_from_player(s)
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
	var by_w := (w - GAP * 15.0) / 11.4
	# Rows of slots on the page, and the section titles over them: the hands
	# (the last section) should be on screen without scrolling where it can.
	var chest := inv != null and not inv.chest_key.is_empty()
	var rows := ceilf(maxf(_storage_n, 0) / 9.0) + 2.0
	var sections := 2.0
	if chest:
		rows += 3.0
		sections += 1.0
	var by_h := (vp_size.y - 220.0 - sections * 30.0) / (rows * 1.1)
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
