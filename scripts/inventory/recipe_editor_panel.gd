class_name RecipeEditorPanel
extends VBoxContainer
## The recipe editor (Docs/Inventory.md 16.3), zylanntest's recipe builder in
## the inventory screen's look: a 2x2 / 3x3 / 4x4 grid whose cells each hold
## an item and how many of it, the output and its count, a name, a station
## and a book tab; New, Load, Save, Delete. Creative only (the screen shows it
## on its Editor tab, the creative palette beside it).
##
## Cells take what the mouse holds (the palette's stack on the cursor):
##   left        that item here, 1 (again: +1)      right   -1 (0: empty)
##   shift+left  +12 (one brick of a material)      shift+right  -12
##   middle      empty
## With nothing held, left/right on a filled cell is +1 / -1. The output the
## same way. Save trims the shape, refuses a shape another recipe has, and
## writes our JSON (RecipeBook.save_custom); Load fills the grid from a recipe.
##
## Knows nothing of the screen (it types this; not the other way).

signal saved(name: String)

var inv: Inventory
var n := 3
var cells: Array = []
var out_id: StringName = &""
var out_count := 1
var slot_px := 40.0
var unit := 2.0

var _grid: GridContainer
var _out: InvSlot
var _name: LineEdit
var _station: OptionButton
var _tab: OptionButton
var _load: OptionButton
var _status: Label
var _sizes: Array[Button] = []
var _stations: Array = [&""]


func setup(p_inv: Inventory) -> void:
	inv = p_inv
	cells = []
	cells.resize(RecipeBook.MAX_GRID * RecipeBook.MAX_GRID)


func _ready() -> void:
	add_theme_constant_override("separation", 4)
	var title := Label.new()
	title.text = "Recipe editor"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(title)
	var sizes := HBoxContainer.new()
	sizes.alignment = BoxContainer.ALIGNMENT_CENTER
	for k in [2, 3, 4]:
		var b := Button.new()
		b.text = "%dx%d" % [k, k]
		b.toggle_mode = true
		b.focus_mode = Control.FOCUS_NONE
		b.pressed.connect(set_grid.bind(k))
		sizes.add_child(b)
		_sizes.append(b)
	add_child(sizes)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 8)
	var gbox := CenterContainer.new()
	_grid = GridContainer.new()
	_grid.add_theme_constant_override("h_separation", 0)
	_grid.add_theme_constant_override("v_separation", 0)
	gbox.add_child(_grid)
	row.add_child(gbox)
	var arrow := Arrow.new()
	arrow.custom_minimum_size = Vector2(40, 30)
	arrow.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(arrow)
	var obox := CenterContainer.new()
	_out = _cell_slot()
	_out.name = "EditorOutput"
	_out.pressed.connect(_on_out)
	obox.add_child(_out)
	row.add_child(obox)
	add_child(row)
	_name = LineEdit.new()
	_name.name = "RecipeName"
	_name.placeholder_text = "Recipe name (the output's if empty)"
	add_child(_name)
	var opts := HBoxContainer.new()
	_station = OptionButton.new()
	_station.focus_mode = Control.FOCUS_NONE
	_station.add_item("By hand")
	for id in ItemCatalog.ids():
		if ItemCatalog.kind(id) == "station":
			_stations.append(id)
			_station.add_item("At: " + str(ItemCatalog.get_def(id).get("name", id)))
	_station.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	opts.add_child(_station)
	_tab = OptionButton.new()
	_tab.focus_mode = Control.FOCUS_NONE
	_tab.add_item("Tab: by output")
	for c in RecipeBook.CATEGORIES:
		_tab.add_item("Tab: " + str(c).capitalize())
	_tab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	opts.add_child(_tab)
	add_child(opts)
	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	for pair in [["New", clear_all], ["Save", save], ["Delete", delete]]:
		var b := Button.new()
		b.name = "Editor" + str(pair[0])
		b.text = pair[0]
		b.focus_mode = Control.FOCUS_NONE
		b.pressed.connect(pair[1])
		buttons.add_child(b)
	_load = OptionButton.new()
	_load.name = "EditorLoad"
	_load.focus_mode = Control.FOCUS_NONE
	_load.item_selected.connect(func(i: int) -> void:
		if i > 0:
			load_recipe(RecipeBook.by_name(_load.get_item_text(i))))
	buttons.add_child(_load)
	add_child(buttons)
	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_status)
	_fill_load_list()
	set_grid(n)


func _cell_slot() -> InvSlot:
	var s := InvSlot.make(null, {}, &"")
	s.mc = true
	s.show_count = 1
	s.custom_minimum_size = Vector2(slot_px, slot_px)
	return s


func _fill_load_list() -> void:
	_load.clear()
	_load.add_item("Load a recipe...")
	var names: Array = []
	for r in RecipeBook.all():
		names.append(str(r.name))
	names.sort()
	for nm in names:
		_load.add_item(nm)


## The grid made `k` x `k`; cells outside it are emptied.
func set_grid(k: int) -> void:
	n = clampi(k, 2, RecipeBook.MAX_GRID)
	for i in _sizes.size():
		_sizes[i].button_pressed = (i + 2) == n
	_grid.columns = n
	for c in _grid.get_children():
		_grid.remove_child(c)
		c.queue_free()
	var keep := cells.duplicate()
	cells.fill(null)
	for y in n:
		for x in n:
			# Cells keep their place when the grid grows or shrinks (4 wide rows).
			cells[y * RecipeBook.MAX_GRID + x] = keep[y * RecipeBook.MAX_GRID + x]
	for y in n:
		for x in n:
			var s := _cell_slot()
			s.name = "EditorCell%d" % (y * n + x)
			s.set_meta("cell", y * RecipeBook.MAX_GRID + x)
			s.pressed.connect(_on_cell)
			_grid.add_child(s)
	_redraw()


func resize_slots(px: float, u: float) -> void:
	slot_px = px
	unit = u
	for s in _grid.get_children() + [_out]:
		(s as InvSlot).custom_minimum_size = Vector2(px, px)
		(s as InvSlot).unit = u


func _redraw() -> void:
	for s in _grid.get_children():
		var slot := s as InvSlot
		var c = cells[int(slot.get_meta("cell"))]
		slot.item_id = &"" if c == null else c.id
		slot.show_count = 1 if c == null else int(c.count)
		slot.queue_redraw()
	_out.item_id = out_id
	_out.show_count = out_count
	_out.queue_redraw()


func _on_cell(s: InvSlot, button: int, shift: bool, _double: bool) -> void:
	var k: int = s.get_meta("cell")
	var c = cells[k]
	var held: ItemStack = inv.cursor if inv != null else null
	var step := 12 if shift else 1
	match button:
		MOUSE_BUTTON_MIDDLE:
			cells[k] = null
		MOUSE_BUTTON_LEFT:
			if held != null and (c == null or c.id != held.id):
				cells[k] = {"id": held.id, "tag": "", "count": step}
			elif c != null:
				c.count = int(c.count) + step
		MOUSE_BUTTON_RIGHT:
			if c != null:
				c.count = int(c.count) - step
				if int(c.count) <= 0:
					cells[k] = null
	_redraw()


func _on_out(_s: InvSlot, button: int, shift: bool, _double: bool) -> void:
	var held: ItemStack = inv.cursor if inv != null else null
	var step := 12 if shift else 1
	match button:
		MOUSE_BUTTON_MIDDLE:
			out_id = &""
			out_count = 1
		MOUSE_BUTTON_LEFT:
			if held != null and held.id != out_id:
				out_id = held.id
				out_count = 1
			elif out_id != &"":
				out_count += step
		MOUSE_BUTTON_RIGHT:
			out_count = maxi(1, out_count - step)
	_redraw()


func clear_all() -> void:
	cells.fill(null)
	out_id = &""
	out_count = 1
	_name.text = ""
	_station.select(0)
	_tab.select(0)
	_say("New recipe: put items in the grid and the output.")
	_redraw()


## The grid, output and fields from recipe `r` (a shapeless one is laid one
## input a cell).
func load_recipe(r: Dictionary) -> void:
	if r.is_empty():
		return
	cells.fill(null)
	var sh: Dictionary = r.get("shape", {})
	var place := []
	if not sh.is_empty():
		for y in int(sh.h):
			for x in int(sh.w):
				place.append([y * RecipeBook.MAX_GRID + x, sh.cells[y * int(sh.w) + x]])
	else:
		for i in r.inputs.size():
			place.append([(i / 2) * RecipeBook.MAX_GRID + i % 2, r.inputs[i]])
	for pc in place:
		var c = pc[1]
		if c != null:
			cells[pc[0]] = {"id": c.id if str(c.tag) == "" else _tag_item(c.tag), "tag": c.tag,
					"count": int(c.count)}
	out_id = r.output
	out_count = int(r.count)
	_name.text = r.name
	_station.select(maxi(0, _stations.find(r.station)))
	_tab.select(RecipeBook.CATEGORIES.find(r.category) + 1 if r.category != RecipeBook.category_of_item(r.output) else 0)
	set_grid(maxi(int(r.grid), 2))
	_say("Loaded \"%s\"%s." % [r.name, "" if not sh.is_empty() else " (shapeless: saved with a shape now)"])


func _tag_item(tag: String) -> StringName:
	for id in ItemCatalog.ids():
		if PackedStringArray(ItemCatalog.get_def(id).get("tags", [])).has(tag):
			return id
	return &""


## The recipe the editor shows, as RecipeBook keeps them; {} with `why`.
func current() -> Dictionary:
	if out_id == &"":
		return {"why": "Set the output: hold an item and click the slot right of the arrow."}
	var flat := []
	for y in n:
		for x in n:
			var c = cells[y * RecipeBook.MAX_GRID + x]
			flat.append(null if c == null else {"id": c.id, "tag": c.tag, "count": int(c.count)})
	var sh := RecipeBook.trim_shape(n, n, flat)
	if sh.is_empty():
		return {"why": "Put at least one item in the grid."}
	var inputs := []
	for c in sh.cells:
		if c != null:
			RecipeBook._add_total(inputs, c)
	var nm := _name.text.strip_edges()
	if nm.is_empty():
		nm = str(ItemCatalog.get_def(out_id).get("name", out_id))
	var cat: String = RecipeBook.category_of_item(out_id) if _tab.selected <= 0 else RecipeBook.CATEGORIES[_tab.selected - 1]
	return {"name": nm, "inputs": inputs, "station": _stations[maxi(0, _station.selected)], "output": out_id,
			"count": out_count, "keep_contents": false, "category": cat,
			"grid": maxi(2, maxi(int(sh.w), int(sh.h))), "shape": sh}


func save() -> String:
	var r := current()
	if r.has("why"):
		_say(r.why)
		return r.why
	var why := RecipeBook.save_custom(r)
	if why.is_empty():
		_say("Saved \"%s\" (%s) to %s." % [r.name, r.shape.signature, RecipeBook.custom_path()])
		_fill_load_list()
		saved.emit(r.name)
	else:
		_say("Not saved: " + why)
	return why


func delete() -> String:
	var nm := _name.text.strip_edges()
	var why := RecipeBook.delete_custom(nm)
	_say("Deleted \"%s\"." % nm if why.is_empty() else "Not deleted: " + why)
	if why.is_empty():
		_fill_load_list()
	return why


func _say(t: String) -> void:
	if _status != null:
		_status.text = t


class Arrow extends Control:
	func _draw() -> void:
		McStyle.draw_arrow(self, Rect2(Vector2.ZERO, size))
