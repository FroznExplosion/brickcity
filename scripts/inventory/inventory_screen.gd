class_name InventoryScreen
extends MenuScreen
## The inventory screen (Docs/Inventory.md 4, redone Minecraft's way in 14),
## opened with E or Tab, by RMB on a chest or a crafting station. Two
## Minecraft panels side by side, Bedrock's layout:
##
##   left  (the recipe book; hidden at a chest or with the book tab off)
##     tabs: construction, equipment, items, nature | creative, spawn, farming | all
##     "Craftable recipes" / "All recipes", a search box, the "craftable
##     only" switch, and a grid of what can be made: grey can be made now,
##     red cannot. Click one to pick it. The Creative tab (creative only)
##     shows every item instead; the Spawn tab (creative only) one spawn
##     item per creature (Docs/MineCreatures.md 12); the Farming tab the
##     farming guide.
##   right
##     tabs: the recipe book on/off, this screen, close (X)
##     "Crafting" (the inventory), "Crafting Table", "Furnace" or another
##       station's name: the backpack slot, then the picked recipe -- its
##       ingredients in a grid (red where you lack some), an arrow (and the
##       furnace's flame), the result. Click the result to make one,
##       Shift-click as many as you can.
##     -- or at a chest: "Chest" and its slots
##     -- or at a furnace (Docs/Inventory.md 15): "Furnace" -- the input over
##       the flame over the fuel, the arrow filling as it smelts, the output;
##       the book lists what smelts, and a click puts what you carry of it in
##     "Inventory": the worn backpack's slots, then hotbar 2 and hotbar 1,
##       the two off-hand slots in a column left of them and the quick slot
##       right of hotbar 1 -- as the HUD has them (Docs/Inventory.md round
##       four; the user asked for them in the screen, 2026-11-26).
##
## No armour, no off-hand, no player figure (the user, 2026-11-25). Hover
## over anything that shows an item and its name pops up beside the mouse
## (McStyle.Tooltip), with what it needs or does in grey and red.
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
## the flight; every key goes here while open (the search box takes typing
## while it has the focus). E, Tab or Escape close it (Escape with a stack
## held puts the stack back first). The stack still held on close goes back
## into storage; if there is no room it is thrown in front of the player
## (DroppedItems). Q over a slot drops one, Shift+Q the stack.
##
## `setup(inv, host)` before adding it; `open_station(id)` for a crafting
## station; the host gets `inventory_closed()`, and is asked
## `stations_near()` and `drop_from_player(stack)`.

const MIN_SLOT := 22.0
const MAX_SLOT := 52.0
## The recipe book's grid, Bedrock's.
const BOOK_COLS := 7
## The off-hand / quick slot column beside the hotbars, with its gap, in slots.
const HAND_COL := 1.3
const TAB_ICONS := {
	"construction": [&"stone", &"sandstone", &"soil"],
	"equipment": [&"pickaxe", &"mega_pickaxe", &"bucket"],
	"items": [&"chest", &"workbench"],
	"nature": [&"wheat", &"wheat_seeds", &"leaves"],
	"farming": [&"hoe", &"wheat_seeds"],
	"spawn": [&"spawn_pig", &"spawn_zombie"],
}
const TAB_NAMES := {
	"construction": "Construction", "equipment": "Equipment", "items": "Items", "nature": "Nature",
	"all": "All recipes (search)", "creative": "Creative: every item", "spawn": "Creative: spawn creatures", "farming": "Farming guide",
}

## The recipe book shown (Bedrock's book tab) and its switch, kept between openings.
static var book_open := true
static var craftable_only := false

var inv: Inventory
var host: Node
## What the left panel shows: "recipes", "creative", "spawn" or "farming".
var page := "recipes"
## The crafting station the screen was opened at (&"workbench", &"furnace",
## ...), or &"" (the plain inventory: every recipe).
var station: StringName = &""
## The recipe book's tab: "all" or one of RecipeBook.CATEGORIES.
var book_tab := "all"
## The recipe picked in the book ({} for none).
var picked: Dictionary = {}

var _slots: Array[InvSlot] = []
var _slot_px := 36.0
var _unit := 2.0
var _font := 14
## Where the last mouse motion sent to the screen was (not the OS pointer).
var _mouse_at := Vector2(-1, -1)

var _row: HBoxContainer
var _left_col: VBoxContainer
var _left: McStyle.Box
var _left_tabs: HBoxContainer
var _tabs := {}
var _book_title: Label
var _search_row: HBoxContainer
var _search: LineEdit
var _toggle: McStyle.Toggle
var _book_scroll: ScrollContainer
var _book_grid: GridContainer
var _book_names: Array = []
var _creative_scroll: ScrollContainer
var _creative_grid: GridContainer
var _spawn_scroll: ScrollContainer
var _spawn_grid: GridContainer
var _farm_scroll: ScrollContainer

var _right_col: VBoxContainer
var _right: McStyle.Box
var _right_tabs: HBoxContainer
var _book_btn: McStyle.Tab
var _here_tab: McStyle.Tab
var _close: McStyle.Tab
var _chest_box: VBoxContainer
var _chest_title: Label
var _chest_grid: GridContainer
var _craft_box: VBoxContainer
var _furnace_box: VBoxContainer
var _fire: FireView
var _farrow: ArrowView
var _furnace_out: InvSlot
var _craft_title: Label
var _backpack_slot: InvSlot
var _ingredients: GridContainer
var _mid: Mid
var _result: InvSlot
var _craft_note: Label
var _inv_title: Label
var _no_pack: Label
var _hotbar_gap: Control
## Round four's hands: the off-hand column, the quick slot, and the gaps and
## pads that keep the storage over the hotbars.
var _off_slots: Array[InvSlot] = []
var _quick_slot: InvSlot
var _hand_gaps: Array[Control] = []
var _hand_pads: Array[Control] = []
## The storage: the worn backpack's slots (Docs/Inventory.md 8), rebuilt when
## the backpack changes.
var _storage_grid: GridContainer
var _storage_n := -1
var _tip: McStyle.Tooltip
var _cursor: CursorView


func setup(p_inv: Inventory, p_host: Node) -> void:
	inv = p_inv
	host = p_host
	screen_title = ""
	opaque_backdrop = false
	dim_backdrop = true


## Opened at a crafting station (RMB on it): its recipes, its name over the
## crafting area, the furnace's flame at a furnace.
func open_station(id: StringName) -> void:
	station = id
	page = "recipes"
	book_open = true
	if not picked.is_empty() and not _fits_station(picked):
		picked = {}
	_rebuild_left(true)
	_refresh()
	_relayout()


func _build_content() -> void:
	var center := CenterContainer.new()
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	center.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_child(center)
	_row = HBoxContainer.new()
	_row.alignment = BoxContainer.ALIGNMENT_CENTER
	center.add_child(_row)
	_build_left()
	_build_right()
	_tip = McStyle.Tooltip.new()
	add_child(_tip)
	_cursor = CursorView.new()
	_cursor.inv = inv
	add_child(_cursor)
	inv.changed.connect(_refresh)
	show_page("recipes")


# ---------------------------------------------------------------------------
# Building

func _build_left() -> void:
	_left_col = VBoxContainer.new()
	_left_col.add_theme_constant_override("separation", 0)
	_row.add_child(_left_col)
	_left_tabs = HBoxContainer.new()
	_left_col.add_child(_left_tabs)
	for key in RecipeBook.CATEGORIES + ["creative", "spawn", "farming", "", "all"]:
		if key == "":
			var gap := Control.new()
			gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
			_left_tabs.add_child(gap)
			continue
		var t := McStyle.Tab.new()
		t.name = "Tab_" + key
		t.tip = TAB_NAMES[key]
		if key == "all":
			t.glyph = "search"
		elif key == "creative":
			t.glyph = "grid"
		else:
			t.icon_id = _first_item(TAB_ICONS.get(key, []))
		t.pressed.connect(_on_left_tab.bind(key))
		_left_tabs.add_child(t)
		_tabs[key] = t
	_left = McStyle.Box.new()
	_left.name = "RecipeBook"
	_left.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_left_col.add_child(_left)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 4)
	_left.add_child(v)
	_book_title = Label.new()
	_book_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	v.add_child(_book_title)
	_search_row = HBoxContainer.new()
	v.add_child(_search_row)
	_search = LineEdit.new()
	_search.name = "Search"
	_search.placeholder_text = "Search"
	_search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_search.text_changed.connect(func(_t: String) -> void: _rebuild_left(true))
	_search_row.add_child(_search)
	_toggle = McStyle.Toggle.new()
	_toggle.name = "CraftableOnly"
	_toggle.tip = "Show craftable recipes only"
	_toggle.icon_id = _first_item([&"workbench"])
	_toggle.on = craftable_only
	_toggle.toggled.connect(func(on: bool) -> void:
		craftable_only = on
		_rebuild_left(true))
	_search_row.add_child(_toggle)
	_book_grid = _cell_grid(BOOK_COLS)
	_book_scroll = _scroll(_book_grid)
	v.add_child(_book_scroll)
	_creative_grid = _cell_grid(BOOK_COLS)
	for id in ItemCatalog.ids():
		if str(ItemCatalog.get_def(id).get("kind", "")) != "spawner":
			_add_slot(_creative_grid, InvSlot.make(inv, {}, id))
	_creative_scroll = _scroll(_creative_grid)
	v.add_child(_creative_scroll)
	_spawn_grid = _cell_grid(BOOK_COLS)
	for id in ItemCatalog.spawn_ids():
		_add_slot(_spawn_grid, InvSlot.make(inv, {}, id))
	_spawn_scroll = _scroll(_spawn_grid)
	v.add_child(_spawn_scroll)
	var guide := FarmGuide.build(_show_slot)
	guide.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_farm_scroll = _scroll(guide)
	v.add_child(_farm_scroll)


func _build_right() -> void:
	_right_col = VBoxContainer.new()
	_right_col.add_theme_constant_override("separation", 0)
	_row.add_child(_right_col)
	_right_tabs = HBoxContainer.new()
	_right_tabs.alignment = BoxContainer.ALIGNMENT_END
	_right_col.add_child(_right_tabs)
	_book_btn = McStyle.Tab.new()
	_book_btn.name = "BookTab"
	_book_btn.glyph = "book"
	_book_btn.tip = "Recipe book: show / hide"
	_book_btn.pressed.connect(func() -> void:
		book_open = not book_open
		_refresh()
		_relayout())
	_right_tabs.add_child(_book_btn)
	_here_tab = McStyle.Tab.new()
	_here_tab.on = true
	_right_tabs.add_child(_here_tab)
	var gap := Control.new()
	gap.custom_minimum_size.x = 6
	gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_right_tabs.add_child(gap)
	_close = McStyle.Tab.new()
	_close.name = "Close"
	_close.glyph = "close"
	_close.tip = "Close (E)"
	_close.pressed.connect(close_screen)
	_right_tabs.add_child(_close)

	_right = McStyle.Box.new()
	_right.name = "InventoryPanel"
	_right_col.add_child(_right)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 4)
	_right.add_child(v)

	_chest_box = VBoxContainer.new()
	_chest_box.add_theme_constant_override("separation", 2)
	_chest_title = Label.new()
	_chest_box.add_child(_chest_title)
	_chest_grid = _cell_grid(Inventory.HOTBAR_SIZE)
	for i in Inventory.CHEST_SIZE:
		_add_slot(_chest_grid, InvSlot.make(inv, Inventory.addr(&"chest", i)))
	_chest_box.add_child(_chest_grid)
	v.add_child(_chest_box)

	# A furnace, Minecraft's: input over the flame over the fuel; the arrow; the output.
	_furnace_box = VBoxContainer.new()
	_furnace_box.name = "Furnace"
	_furnace_box.add_theme_constant_override("separation", 2)
	var ft := Label.new()
	ft.text = "Furnace"
	ft.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_furnace_box.add_child(ft)
	var frow := HBoxContainer.new()
	frow.alignment = BoxContainer.ALIGNMENT_CENTER
	frow.add_theme_constant_override("separation", 0)
	_furnace_box.add_child(frow)
	var fcol := VBoxContainer.new()
	fcol.add_theme_constant_override("separation", 0)
	frow.add_child(fcol)
	_add_slot(fcol, InvSlot.make(inv, Inventory.addr(&"chest", Smelting.INPUT)))
	_fire = FireView.new()
	fcol.add_child(_fire)
	_add_slot(fcol, InvSlot.make(inv, Inventory.addr(&"chest", Smelting.FUEL)))
	_farrow = ArrowView.new()
	_farrow.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	frow.add_child(_farrow)
	var fout := CenterContainer.new()
	_furnace_out = InvSlot.make(inv, Inventory.addr(&"chest", Smelting.OUTPUT))
	_furnace_out.name = "FurnaceOutput"
	_add_slot(fout, _furnace_out)
	frow.add_child(fout)
	v.add_child(_furnace_box)

	_craft_box = VBoxContainer.new()
	_craft_box.add_theme_constant_override("separation", 2)
	_craft_title = Label.new()
	_craft_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_craft_box.add_child(_craft_title)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 0)
	_craft_box.add_child(row)
	# The backpack worn, where Minecraft has the armour (Docs/Inventory.md 8).
	var bp := CenterContainer.new()
	_backpack_slot = InvSlot.make(inv, Inventory.addr(&"backpack"))
	_add_slot(bp, _backpack_slot)
	row.add_child(bp)
	var mid_box := HBoxContainer.new()
	mid_box.alignment = BoxContainer.ALIGNMENT_CENTER
	mid_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mid_box.add_theme_constant_override("separation", 0)
	row.add_child(mid_box)
	var ing_box := CenterContainer.new()
	mid_box.add_child(ing_box)
	_ingredients = _cell_grid(2)
	ing_box.add_child(_ingredients)
	_mid = Mid.new()
	_mid.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	mid_box.add_child(_mid)
	var res_box := CenterContainer.new()
	mid_box.add_child(res_box)
	_result = InvSlot.make(null, {}, &"")
	_result.name = "Result"
	_result.mc = true
	_result.show_count = 1
	_result.pressed.connect(_on_result_pressed)
	res_box.add_child(_result)
	# Balances the backpack slot, so the recipe sits in the middle.
	var sp2 := Control.new()
	sp2.name = "Balance"
	sp2.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(sp2)
	_craft_note = Label.new()
	_craft_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_craft_note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_craft_box.add_child(_craft_note)
	v.add_child(_craft_box)

	_inv_title = Label.new()
	_inv_title.text = "Inventory"
	v.add_child(_inv_title)
	_no_pack = Label.new()
	_no_pack.text = "No backpack worn: put one in the backpack slot to carry more."
	_no_pack.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(_no_pack)
	_storage_grid = _cell_grid(Inventory.HOTBAR_SIZE)
	# The storage stands over the hotbars: padded as wide as the hand columns.
	var srow := HBoxContainer.new()
	srow.alignment = BoxContainer.ALIGNMENT_CENTER
	srow.add_theme_constant_override("separation", 0)
	srow.add_child(_pad())
	srow.add_child(_storage_grid)
	srow.add_child(_pad())
	v.add_child(srow)
	_rebuild_storage()
	_hotbar_gap = Control.new()
	_hotbar_gap.name = "HotbarGap"
	_hotbar_gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(_hotbar_gap)
	var hands := HBoxContainer.new()
	hands.name = "Hands"
	hands.alignment = BoxContainer.ALIGNMENT_CENTER
	hands.add_theme_constant_override("separation", 0)
	var offcol := VBoxContainer.new()
	offcol.name = "OffHand"
	offcol.add_theme_constant_override("separation", 3)
	for i in Inventory.OFFHAND_SIZE:
		var o := InvSlot.make(inv, Inventory.addr(&"offhand", i))
		_add_slot(offcol, o)
		_off_slots.append(o)
	hands.add_child(offcol)
	hands.add_child(_gap())
	var bars := VBoxContainer.new()
	bars.name = "Hotbars"
	bars.add_theme_constant_override("separation", 3)
	for area in [&"hotbar_1", &"hotbar_0"]:
		var g := _cell_grid(Inventory.HOTBAR_SIZE)
		for i in Inventory.HOTBAR_SIZE:
			_add_slot(g, InvSlot.make(inv, Inventory.addr(area, i)))
		bars.add_child(g)
	hands.add_child(bars)
	hands.add_child(_gap())
	var qcol := VBoxContainer.new()
	qcol.name = "Quick"
	qcol.add_theme_constant_override("separation", 3)
	qcol.alignment = BoxContainer.ALIGNMENT_END
	_quick_slot = InvSlot.make(inv, Inventory.addr(&"quick", 0))
	_add_slot(qcol, _quick_slot)
	hands.add_child(qcol)
	v.add_child(hands)


func _gap() -> Control:
	var g := Control.new()
	g.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hand_gaps.append(g)
	return g


func _pad() -> Control:
	var g := Control.new()
	g.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hand_pads.append(g)
	return g


func _cell_grid(cols: int) -> GridContainer:
	var g := GridContainer.new()
	g.columns = cols
	# Minecraft's slots touch: the bevel is the gap.
	g.add_theme_constant_override("h_separation", 0)
	g.add_theme_constant_override("v_separation", 0)
	return g


func _scroll(inner: Control) -> ScrollContainer:
	var sc := ScrollContainer.new()
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sc.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	sc.follow_focus = false
	# As tall as the inventory panel beside it (the row gives both its height).
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sc.add_child(inner)
	return sc


func _first_item(ids: Array) -> StringName:
	for id in ids:
		if id != &"" and ItemCatalog.has(id):
			return id
	return &""


## A clickable inventory (or creative catalog) slot.
func _add_slot(parent: Node, s: InvSlot) -> void:
	s.mc = true
	s.custom_minimum_size = Vector2(_slot_px, _slot_px)
	s.pressed.connect(_on_slot_pressed)
	s.hovered.connect(_on_slot_hovered)
	parent.add_child(s)
	_slots.append(s)


## A slot that only shows an item (the farming guide, the ingredients): no
## clicks, but its name on hover.
func _show_slot(id: StringName, n: int) -> InvSlot:
	var s := InvSlot.make(null, {}, id)
	s.mc = true
	s.unit = _unit
	s.show_count = maxi(n, 1)
	s.custom_minimum_size = Vector2(_slot_px, _slot_px)
	s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	s.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	return s


func _exit_tree() -> void:
	super._exit_tree()
	if inv != null and inv.changed.is_connected(_refresh):
		inv.changed.disconnect(_refresh)


## No control takes the focus on open: keys are the screen's (the search box
## takes it when clicked).
func _first_focus() -> Control:
	return null


# ---------------------------------------------------------------------------
# Pages

func show_page(p: String) -> void:
	match p:
		"creative":
			page = "creative" if inv.creative else "recipes"
		"spawn":
			page = "spawn" if inv.creative else "recipes"
		"farming":
			page = "farming"
		_:
			# "storage", "craft", "recipes": the recipe book.
			page = "recipes"
	if p == "craft":
		book_open = true
	_rebuild_left(true)
	_refresh()
	_relayout()


func _on_left_tab(key: String) -> void:
	if key == "creative" or key == "spawn" or key == "farming":
		show_page(key)
		return
	book_tab = key
	show_page("recipes")


## The left panel's contents for the page: the recipe cells (rebuilt when
## other recipes show, or `force`), the creative catalog filtered by the search.
func _rebuild_left(force := false) -> void:
	if _book_grid == null:
		return
	for key in _tabs:
		var t: McStyle.Tab = _tabs[key]
		t.on = (page == key) or (page == "recipes" and key == book_tab)
	(_tabs["creative"] as Control).visible = inv.creative
	(_tabs["spawn"] as Control).visible = inv.creative
	_book_scroll.visible = page == "recipes"
	_creative_scroll.visible = page == "creative"
	_spawn_scroll.visible = page == "spawn"
	_farm_scroll.visible = page == "farming"
	_search_row.visible = page != "farming"
	_toggle.visible = page == "recipes"
	match page:
		"creative":
			_book_title.text = "Creative items"
			var q := _search.text.strip_edges().to_lower()
			for s in _creative_grid.get_children():
				var slot := s as InvSlot
				slot.visible = q.is_empty() or str(ItemCatalog.get_def(slot.item_id).get("name", "")).to_lower().contains(q)
			return
		"spawn":
			_book_title.text = "Spawn creatures"
			var q2 := _search.text.strip_edges().to_lower()
			for s in _spawn_grid.get_children():
				var slot2 := s as InvSlot
				slot2.visible = q2.is_empty() or str(ItemCatalog.get_def(slot2.item_id).get("name", "")).to_lower().contains(q2)
			return
		"farming":
			_book_title.text = "Farming guide"
			return
	if _furnace_mode():
		_book_title.text = "Smeltable" if craftable_only else "Smelting recipes"
	else:
		_book_title.text = "Craftable recipes" if craftable_only else "All recipes"
	var near := _near()
	var list := _book_recipes(near)
	var names: Array = []
	for r in list:
		names.append(r.name)
	if not force and names == _book_names:
		for c in _book_grid.get_children():
			var cell := c as InvSlot
			var r: Dictionary = cell.get_meta("r")
			cell.bad = not _can(r, near)
			cell.picked = not picked.is_empty() and picked.name == r.name
			cell.queue_redraw()
		return
	_book_names = names
	for c in _book_grid.get_children():
		_book_grid.remove_child(c)
		c.queue_free()
	for r in list:
		var cell := InvSlot.make(null, {}, r.output)
		cell.name = "Recipe_" + str(r.name).validate_node_name()
		cell.mc = true
		cell.unit = _unit
		cell.show_count = int(r.count)
		cell.custom_minimum_size = Vector2(_slot_px, _slot_px)
		cell.bad = not _can(r, near)
		cell.picked = not picked.is_empty() and picked.name == r.name
		cell.set_meta("recipe", r.name)
		cell.set_meta("r", r)
		cell.pressed.connect(func(_s: InvSlot, _b: int, _sh: bool, _d: bool) -> void: _pick(r))
		_book_grid.add_child(cell)


## The recipes the book shows: those of this station (a crafting table: by
## hand and its own; another station: its own; the plain inventory: all),
## in the tab, matching the search, craftable only if the switch says so;
## what can be made first (Bedrock's).
func _book_recipes(near: Array) -> Array:
	var q := _search.text.strip_edges().to_lower()
	var can: Array = []
	var cannot: Array = []
	for r in (_smelt_recipes() if _furnace_mode() else RecipeBook.all()):
		if not _fits_station(r):
			continue
		if book_tab != "all" and r.category != book_tab:
			continue
		if not q.is_empty() and not str(r.name).to_lower().contains(q):
			continue
		var ok := _can(r, near)
		if craftable_only and not ok:
			continue
		(can if ok else cannot).append(r)
	return can + cannot


## The furnace's recipes in the book's shape: one input, its `take`.
func _smelt_recipes() -> Array:
	var out: Array = []
	for sr in Smelting.recipes():
		out.append({"name": sr.name, "inputs": [{"id": sr.input, "tag": "", "count": int(sr.take)}],
				"station": &"furnace", "output": sr.output, "count": int(sr.count),
				"category": RecipeBook.category_of_item(sr.output), "smelt": true, "time": float(sr.time)})
	return out


## Can `r` be made now: a smelting recipe if enough of its input is carried.
func _can(r: Dictionary, near: Array) -> bool:
	if r.get("smelt", false):
		return inv.count_of(r.inputs[0]) >= int(r.inputs[0].count)
	return inv.can_craft(r, near)


## The screen is a furnace's (its three slots are the borrowed chest's).
func _furnace_mode() -> bool:
	return not inv.chest_key.is_empty() and inv.chest_rules == "furnace"


func _fits_station(r: Dictionary) -> bool:
	if r.get("smelt", false):
		return true
	if station == &"":
		return true
	if station == &"workbench":
		return r.station == &"" or r.station == &"workbench"
	return r.station == station


func _near() -> Array:
	return host.stations_near() if host != null and host.has_method("stations_near") else []


## The recipe book cell of recipe `name` (the gate clicks it), or null.
func recipe_cell(name: String) -> InvSlot:
	for c in _book_grid.get_children():
		if c.has_meta("recipe") and str(c.get_meta("recipe")) == name and not c.is_queued_for_deletion():
			return c as InvSlot
	return null


func result_slot() -> InvSlot:
	return _result


func _pick(r: Dictionary) -> void:
	if r.get("smelt", false):
		# Bedrock's furnace book: what you carry of the input goes on top.
		inv.fill_slot(Inventory.addr(&"chest", Smelting.INPUT), r.inputs[0].id)
		return
	picked = r
	_rebuild_left()
	_show_picked()


# ---------------------------------------------------------------------------
# The crafting area

func _station_title() -> String:
	match station:
		&"":
			return "Crafting"
		&"workbench":
			return "Crafting Table"
	return str(ItemCatalog.get_def(station).get("name", station))


## The picked recipe in the crafting area: its ingredients in the grid, red
## where some are lacking; its result; what it still needs.
func _show_picked() -> void:
	var near := _near()
	var furnace := station == &"furnace"
	var cells := 4
	var cols := 2
	if furnace:
		cols = 1
		cells = 2
	elif station == &"workbench":
		cols = 3
		cells = 9
	var inputs: Array = picked.get("inputs", [])
	cells = maxi(cells, inputs.size())
	if _ingredients.columns != cols or _ingredients.get_child_count() != cells:
		_ingredients.columns = cols
		for c in _ingredients.get_children():
			_ingredients.remove_child(c)
			c.queue_free()
		for i in cells:
			var g := _show_slot(&"", 1)
			g.name = "Ingredient%d" % i
			_ingredients.add_child(g)
	for i in _ingredients.get_child_count():
		var g := _ingredients.get_child(i) as InvSlot
		g.unit = _unit
		g.custom_minimum_size = Vector2(_slot_px, _slot_px)
		if i < inputs.size():
			var inp: Dictionary = inputs[i]
			g.item_id = inp.id if inp.tag == "" else _tag_example(inp.tag)
			g.show_count = int(inp.count)
			g.bad = inv.count_of(inp) < int(inp.count)
			g.set_meta("input", inp)
		else:
			g.item_id = &""
			g.show_count = 1
			g.bad = false
			if g.has_meta("input"):
				g.remove_meta("input")
		g.queue_redraw()
	var ok := not picked.is_empty() and inv.can_craft(picked, near)
	_result.item_id = picked.get("output", &"")
	_result.show_count = int(picked.get("count", 1))
	_result.queue_redraw()
	_mid.furnace = furnace
	_mid.lit = ok
	_mid.queue_redraw()
	_craft_note.remove_theme_color_override("font_color")
	if picked.is_empty():
		_craft_note.text = "Pick a recipe in the book." if book_open else "Open the recipe book (the book tab) to craft."
	elif ok:
		_craft_note.text = "Click the result to craft  ·  Shift-click: as many as you can"
	else:
		_craft_note.text = "Needs " + ", ".join(inv.missing(picked, near))
		_craft_note.add_theme_color_override("font_color", Color("a02020"))


func _on_result_pressed(_s: InvSlot, button: int, shift: bool, _double: bool) -> void:
	if picked.is_empty() or button == MOUSE_BUTTON_MIDDLE:
		return
	craft(picked, shift)


## Make recipe `r` once (or `all`: as many as can be), what does not fit
## thrown in front of the player. How many were made.
func craft(r: Dictionary, all := false) -> int:
	var res := inv.craft(r, _near(), all)
	for s in res.left:
		if host != null and host.has_method("drop_from_player"):
			host.drop_from_player(s)
	return int(res.made)


## An item with tag `tag`, to draw for a "#tag" ingredient.
func _tag_example(tag: String) -> StringName:
	for id in ItemCatalog.ids():
		if PackedStringArray(ItemCatalog.get_def(id).get("tags", [])).has(tag):
			return id
	return &""


# ---------------------------------------------------------------------------
# Refresh

## The storage grid as big as the worn backpack (none: no slots).
func _rebuild_storage() -> void:
	var n := inv.area_size(&"main")
	if n == _storage_n:
		return
	_storage_n = n
	for c in _storage_grid.get_children():
		_slots.erase(c)
		_storage_grid.remove_child(c)
		c.queue_free()
	for i in n:
		_add_slot(_storage_grid, InvSlot.make(inv, Inventory.addr(&"main", i)))
	_set_slot_size()


func _refresh() -> void:
	if _cursor == null:
		return
	var n0 := _storage_n
	_rebuild_storage()
	var furnace := _furnace_mode()
	var chest := not inv.chest_key.is_empty() and not furnace
	_chest_box.visible = chest
	_furnace_box.visible = furnace
	_craft_box.visible = not chest and not furnace
	_left_col.visible = book_open and not chest
	_book_btn.visible = not chest
	_storage_grid.visible = _storage_n > 0
	_no_pack.visible = _storage_n <= 0
	_chest_title.text = inv.chest_title
	_craft_title.text = _station_title()
	if furnace:
		_here_tab.icon_id = _first_item([&"furnace"])
		_here_tab.tip = inv.chest_title
	elif chest:
		_here_tab.icon_id = _first_item([&"chest"])
		_here_tab.tip = inv.chest_title
	else:
		_here_tab.icon_id = _first_item([station, &"workbench"])
		_here_tab.tip = _craft_title.text
	_here_tab.queue_redraw()
	for s in _slots:
		if not s.addr.is_empty():
			var a: Dictionary = s.addr
			if a.area == &"chest":
				# A backpack put down has fewer slots than a chest.
				s.visible = int(a.index) < inv.area_size(&"chest")
			# The main hand's slot (the quick slot while it is out), the
			# active off-hand slot.
			match a.area:
				&"offhand":
					s.selected = int(a.index) == inv.active_offhand
					s.modulate = Color.WHITE if inv.offhand_up else Color(1, 1, 1, 0.7)
				&"quick":
					s.selected = inv.quick_out
				_:
					s.selected = a.area == inv.hotbar_area() and a.index == inv.active_slot and not inv.quick_out
		s.queue_redraw()
	if not chest:
		_rebuild_left()
	if not chest and not furnace:
		_show_picked()
	_cursor.visible = inv.cursor != null
	_cursor.queue_redraw()
	_update_tip()
	if n0 != _storage_n:
		_relayout()        # a backpack on or off: other rows, other slot size


# ---------------------------------------------------------------------------
# The name beside the mouse

func _process(_delta: float) -> void:
	_update_tip()
	if _furnace_mode() and host != null and host.has_method("furnace_state"):
		var pr := Smelting.progress(host.furnace_state(inv.chest_key), inv.chest_slots)
		if not is_equal_approx(pr.x, _farrow.frac) or not is_equal_approx(pr.y, _fire.frac):
			_farrow.frac = pr.x
			_fire.frac = pr.y
			_farrow.queue_redraw()
			_fire.queue_redraw()


func _update_tip() -> void:
	if _tip == null or get_viewport() == null:
		return
	var c: Control = get_viewport().gui_get_hovered_control()
	var lines: Array = [] if inv.cursor != null else tip_lines(c)
	var at := _mouse_at if _mouse_at.x >= 0.0 else get_viewport().get_mouse_position()
	_tip.font_size = _font
	_tip.show_lines(lines, at, get_viewport().get_visible_rect())


## What the tooltip says over control `c`: [[text, colour], ...]; [] for none.
func tip_lines(c: Control) -> Array:
	if c == null or not c.is_visible_in_tree() or not is_ancestor_of(c):
		return []
	if c is McStyle.Tab:
		var tb := c as McStyle.Tab
		return [] if tb.tip.is_empty() else [[tb.tip, McStyle.TIP_NAME]]
	if c is McStyle.Toggle:
		var tg := c as McStyle.Toggle
		return [[tg.tip, McStyle.TIP_NAME], ["On" if tg.on else "Off", McStyle.TIP_GREY]]
	if not (c is InvSlot):
		return []
	var s := c as InvSlot
	var near := _near()
	if s.has_meta("r") and (s.get_meta("r") as Dictionary).get("smelt", false):
		var sr: Dictionary = s.get_meta("r")
		var inp: Dictionary = sr.inputs[0]
		var nm := str(ItemCatalog.get_def(inp.id).get("name", inp.id))
		var have := inv.count_of(inp)
		var lines: Array = [[str(sr.name) + ("  x%d" % int(sr.count) if int(sr.count) > 1 else ""), McStyle.TIP_NAME],
				["Smelts %d %s in %s s" % [int(inp.count), nm, str(sr.time)], McStyle.TIP_GREY]]
		if have < int(inp.count):
			lines.append(["Needs %d more %s" % [int(inp.count) - have, nm], McStyle.TIP_RED])
		else:
			lines.append(["Click: put your %s in the furnace" % nm, Color("8080ff")])
		return lines
	if s.has_meta("r"):
		var r: Dictionary = s.get_meta("r")
		var out: Array = [[str(r.name) + ("  x%d" % int(r.count) if int(r.count) > 1 else ""), McStyle.TIP_NAME]]
		if r.station != &"":
			out.append(["Made " + RecipeBook.station_name(r), McStyle.TIP_GREY])
		for m in inv.missing(r, near):
			out.append(["Needs " + m, McStyle.TIP_RED])
		return out
	if s == _result:
		if picked.is_empty():
			return []
		var ok := inv.can_craft(picked, near)
		return [[str(picked.name) + ("  x%d" % int(picked.count) if int(picked.count) > 1 else ""), McStyle.TIP_NAME],
				["Click: craft one  ·  Shift-click: craft all" if ok else "Cannot be made yet",
						McStyle.TIP_GREY if ok else McStyle.TIP_RED]]
	if s.has_meta("input"):
		var inp: Dictionary = s.get_meta("input")
		var have := inv.count_of(inp)
		var nm: String = ("Any " + inp.tag) if inp.tag != "" else str(ItemCatalog.get_def(inp.id).get("name", inp.id))
		return [[nm, McStyle.TIP_NAME], ["Needs %d  ·  you have %d" % [int(inp.count), have],
				McStyle.TIP_GREY if have >= int(inp.count) else McStyle.TIP_RED]]
	var st := s.stack()
	if st == null:
		if s == _backpack_slot:
			return [["Backpack slot", McStyle.TIP_NAME], ["Wear a backpack here to carry more", McStyle.TIP_GREY]]
		if s in _off_slots:
			return [["Off-hand %d" % (int(s.addr.index) + 1), McStyle.TIP_NAME],
					["C over an item puts it here; C in play raises it", McStyle.TIP_GREY]]
		if s == _quick_slot:
			return [["Quick slot", McStyle.TIP_NAME],
					["B over an item puts it here; B in play takes it out", McStyle.TIP_GREY]]
		if _furnace_mode() and not s.addr.is_empty() and s.addr.area == &"chest":
			match int(s.addr.index):
				Smelting.INPUT:
					return [["Smelt", McStyle.TIP_NAME], ["Ore or sand: what goes in the fire", McStyle.TIP_GREY]]
				Smelting.FUEL:
					return [["Fuel", McStyle.TIP_NAME], ["Coal, wood or leaves", McStyle.TIP_GREY]]
				Smelting.OUTPUT:
					return [["Result", McStyle.TIP_NAME], ["What is smelted comes out here", McStyle.TIP_GREY]]
		return []
	var out2: Array = [[ItemCatalog.label(st), McStyle.TIP_NAME]]
	var d := ItemCatalog.get_def(st.id)
	for line in _wrap(str(d.get("description", "")), 40):
		out2.append([line, McStyle.TIP_GREY])
	if s.addr.is_empty() and s.show_count == 0 and inv.creative:
		out2.append(["Click: take a stack  ·  Shift: into the inventory", Color("8080ff")])
	return out2


static func _wrap(text: String, width: int) -> PackedStringArray:
	var out := PackedStringArray()
	var line := ""
	for w in text.split(" ", false):
		if not line.is_empty() and line.length() + 1 + w.length() > width:
			out.append(line)
			line = w
		else:
			line = w if line.is_empty() else line + " " + w
	if not line.is_empty():
		out.append(line)
	return out


# ---------------------------------------------------------------------------
# Mouse

func _on_slot_hovered(s: InvSlot) -> void:
	if inv.is_dragging() and not s.addr.is_empty():
		inv.drag_touch(s.addr)


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
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		_mouse_at = mb.position
		if mb.pressed and _search.has_focus() and not _search.get_global_rect().has_point(mb.position):
			_search.release_focus()
		if not mb.pressed and inv.is_dragging():
			inv.finish_drag()
		return
	if not (event is InputEventKey):
		return
	var k := event as InputEventKey
	if _search.has_focus():
		# Typing in the search box: the keys are its, but for leaving it.
		if k.pressed and (k.keycode == KEY_ESCAPE or k.keycode == KEY_ENTER or k.keycode == KEY_KP_ENTER):
			_search.release_focus()
			get_viewport().set_input_as_handled()
		return
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
		KEY_C, KEY_B:
			# The hands without slots in the screen (Docs/Inventory.md round
			# four, Minecraft's F): C over a slot swaps it with the active
			# off-hand slot, B with the quick slot -- over an empty slot, what
			# the hand held lands there.
			var s := _slot_at(_mouse_at)
			if s != null and not s.addr.is_empty():
				var hand_at := Inventory.addr(&"offhand", inv.active_offhand) if k.keycode == KEY_C else Inventory.addr(&"quick", 0)
				inv.swap_slots(s.addr, hand_at)


func close_screen() -> void:
	inv.cancel_drag()
	var thrown := []
	if not inv.return_cursor():
		# No room: it is thrown in front of the player, not lost.
		thrown.append(inv.cursor)
		inv.cursor = null
	# What is left in the old craft grid goes back too (Minecraft's).
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
	if _right == null or inv == null:
		return
	var furnace := _furnace_mode()
	var chest := not inv.chest_key.is_empty() and not furnace
	var book := book_open and not chest
	var pad_f := 0.36
	# Widths in slots: the right panel 9 + padding; the book 7 + its scroll bar.
	var w_slots := 9.0 + pad_f * 2.0 + 0.2 + 2.0 * HAND_COL
	if book:
		w_slots += BOOK_COLS + 0.5 + pad_f * 2.0 + 0.3
	# Heights in slots: tabs, padding, the top section, titles and notes,
	# the storage rows, the gap, two hotbars.
	var store_rows := ceilf(maxf(_storage_n, 0) / 9.0) if _storage_n > 0 else 0.8
	var top := 3.0 if station == &"workbench" else 2.0
	var text_rows := 4.0
	if chest:
		top = ceilf(inv.area_size(&"chest") / 9.0)
		text_rows = 2.0
	elif furnace:
		top = 3.0
		text_rows = 2.0
	var h_slots := 0.95 + pad_f * 2.0 + top + text_rows * 0.62 + store_rows + 0.3 + 2.1 + 0.25
	var avail_h := vp_size.y - 2.0 * MenuFit.page_padding(vp_size) - 8.0
	var by_w := (available_width(vp_size) - 4.0) / w_slots
	var by_h := avail_h / h_slots
	_slot_px = floorf(clampf(minf(by_w, by_h), MIN_SLOT, MAX_SLOT))
	_unit = maxf(1.0, roundf(_slot_px / 18.0))
	_font = clampi(int(roundf(_slot_px * 0.42)), 10, 20)
	var pad := int(roundf(_slot_px * pad_f))
	var th := McStyle.theme(_font)
	_right.theme = th
	_left.theme = th
	for b in [_left, _right]:
		(b as McStyle.Box).unit = _unit
		(b as McStyle.Box).set_pad(pad)
		(b as Control).queue_redraw()
	_row.add_theme_constant_override("separation", int(roundf(_slot_px * 0.3)))
	var tab := Vector2(roundf(_slot_px * 1.05), roundf(_slot_px * 0.95))
	for t in _tabs.values() + [_book_btn, _here_tab, _close]:
		(t as McStyle.Tab).custom_minimum_size = tab
		(t as McStyle.Tab).unit = _unit
	_left_tabs.add_theme_constant_override("separation", int(_unit))
	_right_tabs.add_theme_constant_override("separation", int(_unit))
	_toggle.custom_minimum_size = Vector2(roundf(_slot_px * 1.5), roundf(_slot_px * 0.75))
	_toggle.unit = _unit
	_search.custom_minimum_size.y = roundf(_slot_px * 0.75)
	var bar_w := 10.0
	var vb := _book_scroll.get_v_scroll_bar()
	if vb != null:
		bar_w = maxf(vb.get_combined_minimum_size().x, 10.0)
	var book_w := BOOK_COLS * _slot_px + bar_w + 2.0
	# At least three rows; it stretches to the inventory panel's height.
	for sc in [_book_scroll, _creative_scroll, _spawn_scroll, _farm_scroll]:
		(sc as ScrollContainer).custom_minimum_size = Vector2(book_w, _slot_px * 3.0)
	_mid.custom_minimum_size = Vector2(roundf(_slot_px * (1.9 if station == &"furnace" else 1.4)), _slot_px)
	_result.custom_minimum_size = Vector2(roundf(_slot_px * 1.35), roundf(_slot_px * 1.35))
	_result.unit = _unit
	_fire.custom_minimum_size = Vector2(_slot_px, _slot_px)
	_farrow.custom_minimum_size = Vector2(roundf(_slot_px * 1.6), _slot_px)
	(_right.find_child("Balance", true, false) as Control).custom_minimum_size.x = _slot_px
	_hotbar_gap.custom_minimum_size.y = roundf(_slot_px * 0.2)
	for g in _hand_gaps:
		g.custom_minimum_size.x = roundf(_slot_px * (HAND_COL - 1.0))
	for g in _hand_pads:
		g.custom_minimum_size.x = roundf(_slot_px * (HAND_COL - 1.0)) + _slot_px
	_craft_note.custom_minimum_size.x = 9.0 * _slot_px
	_no_pack.custom_minimum_size.x = 9.0 * _slot_px
	_set_slot_size()
	if _cursor != null:
		_cursor.size = Vector2(_slot_px, _slot_px)


func _set_slot_size() -> void:
	var sz := Vector2(_slot_px, _slot_px)
	for s in _slots:
		s.custom_minimum_size = sz
		s.unit = _unit
	if _furnace_out != null:
		_furnace_out.custom_minimum_size = (sz * 1.35).round()
	if _book_grid != null:
		for c in _book_grid.get_children() + _ingredients.get_children():
			(c as InvSlot).custom_minimum_size = sz
			(c as InvSlot).unit = _unit
	if _farm_scroll != null:
		for c in _farm_scroll.find_children("*", "InvSlot", true, false):
			(c as InvSlot).custom_minimum_size = sz
			(c as InvSlot).unit = _unit


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


## Between the ingredients and the result: the arrow, and at a furnace its
## flame, lit when the picked recipe can be made.
class Mid extends Control:
	var furnace := false
	var lit := false

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var h := size.y
		if furnace:
			McStyle.draw_flame(self, Rect2(Vector2(h * 0.05, h * 0.15), Vector2(h * 0.7, h * 0.7)), lit)
			McStyle.draw_arrow(self, Rect2(Vector2(h * 0.85, h * 0.3), Vector2(size.x - h * 1.0, h * 0.4)))
		else:
			McStyle.draw_arrow(self, Rect2(Vector2(size.x * 0.18, h * 0.3), Vector2(size.x * 0.64, h * 0.4)))


## The furnace's flame: grey when out, burning down from the top as the fuel
## is used (`frac`: what is left).
class FireView extends Control:
	var frac := 0.0

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var r := Rect2(Vector2(-size.x * 0.15, -size.y * 0.25), size * 1.3)
		McStyle.draw_flame(self, r, false)
		if frac > 0.0:
			# The lit part: the flame again, cut flat at what is left.
			McStyle.draw_flame(self, r, true, r.position.y + r.size.y * (1.0 - frac))


## The furnace's arrow, filling white left to right as the smelt goes (`frac`).
class ArrowView extends Control:
	var frac := 0.0

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var r := Rect2(Vector2(size.x * 0.12, size.y * 0.3), Vector2(size.x * 0.76, size.y * 0.4))
		McStyle.draw_arrow(self, r)
		if frac > 0.0:
			McStyle.draw_arrow(self, r, McStyle.LIGHT, frac)
