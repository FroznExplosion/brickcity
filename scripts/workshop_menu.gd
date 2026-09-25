class_name WorkshopMenu
extends Control

## The workshop's menu bar and its dialogs. Docs/Workshop.md, Stage A.
##
## This file draws and asks; it does not build. Every choice comes out as one
## `action` signal with a name and an argument, and the workshop does the work,
## so the keys and the menus cannot disagree about what "save" means -- both
## end up in the same function over there.
##
## The bar is always on screen. With the mouse captured to look it cannot be
## clicked, which is fine: ESC frees the mouse, and the bar is where the
## cursor goes.

signal action(name: String, arg: Variant)

## Library folders by build kind. `building` is the city placer's library
## (CityPlacer.LIBRARY_DIRS) so every building saved here can be placed with P.
## Rooms and items live apart: they are what the GENERATOR builds from
## (Docs/Workshop.md, Stage E), not things a player drops into the city whole.
const DIRS := {
	"building": ["res://builds/", "user://builds/"],
	"room": ["res://rooms/", "user://rooms/"],
	"item": ["res://items/", "user://items/"],
}
const KIND_LABELS := {
	"building": "Building",
	"room": "Room template",
	"item": "Item",
	"mech": "Mech",
	"gun": "Gun",
	"vehicle": "Vehicle",
	"aircraft": "Aircraft",
}
const ROLE_LABELS := ["Structure", "Interior", "Detail"]

var _bar: PanelContainer
var _title: Label
var _file: MenuButton
var _insert: MenuButton
var _type: MenuButton
var _layer: MenuButton
var _gen: MenuButton

var _open_dialog: ConfirmationDialog
var _open_list: ItemList
var _open_filter: OptionButton
var _open_mode := "open"      ## "open" or "insert"
var _open_paths := PackedStringArray()

var _save_dialog: ConfirmationDialog
var _save_name: LineEdit
var _save_room_kind: OptionButton
var _save_room_row: HBoxContainer

var _clear_dialog: ConfirmationDialog

var _program_dialog: ConfirmationDialog
var _program_spins := {}    ## room kind -> SpinBox

var _kind := "building"
var _role := 0

## Ids inside each PopupMenu. Separate numbers per menu; the id is what comes
## back from id_pressed.
enum { F_NEW, F_OPEN, F_SAVE, F_SAVE_AS, F_QUICK_SAVE, F_QUICK_LOAD, F_CITY }
enum { I_BUILD, I_TOWER, I_BAKE, I_REMOVE_TOWER }
enum { G_ROOMS, G_STAIRS, G_WINDOWS, G_FURNISH, G_PROGRAM, G_REROLL }


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_bar()
	_build_open_dialog()
	_build_save_dialog()
	_build_clear_dialog()
	_build_program_dialog()


## Is any dialog up? The workshop builds nothing through one.
func is_modal() -> bool:
	for d in [_open_dialog, _save_dialog, _clear_dialog, _program_dialog]:
		if d != null and d.visible:
			return true
	for m in [_file, _insert, _type, _layer, _gen]:
		if m != null and m.get_popup().visible:
			return true
	return false


## Height of the bar in pixels, so the HUD can sit under it.
func bar_height() -> float:
	return _bar.size.y if _bar != null else 0.0


func set_title(t: String) -> void:
	if _title != null:
		_title.text = t


func set_kind(k: String) -> void:
	_kind = k
	var p := _type.get_popup()
	for i in p.item_count:
		p.set_item_checked(i, BuildRecipe.KINDS[p.get_item_id(i)] == k)


func set_role(r: int) -> void:
	_role = r
	var p := _layer.get_popup()
	for i in p.item_count:
		p.set_item_checked(i, p.get_item_id(i) == r)


## Tick the generated-building options to match the one in the build.
func set_tower_options(has_tower: bool, rooms: bool, stairs: bool, windows: bool,
		furnish: bool = false) -> void:
	var p := _gen.get_popup()
	_gen.disabled = not has_tower
	p.set_item_checked(p.get_item_index(G_ROOMS), rooms)
	p.set_item_checked(p.get_item_index(G_STAIRS), stairs)
	p.set_item_checked(p.get_item_index(G_WINDOWS), windows)
	p.set_item_checked(p.get_item_index(G_FURNISH), furnish)
	var ip := _insert.get_popup()
	ip.set_item_disabled(ip.get_item_index(I_BAKE), not has_tower)
	ip.set_item_disabled(ip.get_item_index(I_REMOVE_TOWER), not has_tower)


# ---------------------------------------------------------------------------
# The bar
# ---------------------------------------------------------------------------

func _build_bar() -> void:
	_bar = PanelContainer.new()
	_bar.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.07, 0.08, 0.11, 0.86)
	sb.content_margin_left = 8
	sb.content_margin_right = 8
	sb.content_margin_top = 2
	sb.content_margin_bottom = 2
	_bar.add_theme_stylebox_override("panel", sb)
	add_child(_bar)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	_bar.add_child(row)

	_file = _menu(row, "File", [
		["New (clear)", F_NEW, KEY_MASK_CTRL | KEY_N],
		["Open…", F_OPEN, KEY_MASK_CTRL | KEY_O],
		["Save", F_SAVE, KEY_MASK_CTRL | KEY_S],
		["Save As…", F_SAVE_AS, KEY_MASK_CTRL | KEY_MASK_SHIFT | KEY_S],
		[],
		["Quick save (F5)", F_QUICK_SAVE, 0],
		["Quick load (F9)", F_QUICK_LOAD, 0],
		[],
		["Test in city (Enter)", F_CITY, 0],
	], _on_file)

	_insert = _menu(row, "Insert", [
		["Build from library…", I_BUILD, KEY_MASK_CTRL | KEY_I],
		["Generated building", I_TOWER, KEY_MASK_CTRL | KEY_G],
		[],
		["Bake generated building to bricks", I_BAKE, 0],
		["Remove generated building", I_REMOVE_TOWER, 0],
	], _on_insert)

	var kinds := []
	for i in BuildRecipe.KINDS.size():
		var k: String = BuildRecipe.KINDS[i]
		var label: String = KIND_LABELS.get(k, k)
		if not BuildRecipe.KINDS_ENABLED.has(k):
			label += "  (later)"
		kinds.append([label, i, 0])
		if k == "item":
			kinds.append([])
	_type = _menu(row, "Type", kinds, _on_type, true)
	var tp := _type.get_popup()
	for i in tp.item_count:
		var id := tp.get_item_id(i)
		if id >= 0 and id < BuildRecipe.KINDS.size():
			tp.set_item_disabled(i, not BuildRecipe.KINDS_ENABLED.has(BuildRecipe.KINDS[id]))

	var roles := []
	for i in ROLE_LABELS.size():
		roles.append([ROLE_LABELS[i], i, 0])
	_layer = _menu(row, "Layer", roles, func(id: int) -> void:
		action.emit("role", id), true)

	_gen = _menu(row, "Generated", [
		["Interior walls", G_ROOMS, 0],
		["Stairs", G_STAIRS, 0],
		["Windows", G_WINDOWS, 0],
		["Furnish rooms", G_FURNISH, 0],
		[],
		["Room mix…", G_PROGRAM, 0],
		["Reroll furniture", G_REROLL, 0],
	], _on_gen, true)
	# The last two are actions, not options: no tick.
	var gp := _gen.get_popup()
	gp.set_item_as_radio_checkable(gp.get_item_index(G_PROGRAM), false)
	gp.set_item_as_radio_checkable(gp.get_item_index(G_REROLL), false)
	_gen.disabled = true

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)
	_title = Label.new()
	_title.add_theme_color_override("font_color", Color(0.84, 0.87, 0.93))
	row.add_child(_title)

	set_kind(_kind)
	set_role(_role)


## One menu. `items` rows are [label, id, shortcut keycode or 0], or [] for a
## separator.
func _menu(parent: Control, label: String, items: Array, handler: Callable,
		checks: bool = false) -> MenuButton:
	var mb := MenuButton.new()
	mb.text = label
	mb.flat = true
	mb.switch_on_hover = true
	parent.add_child(mb)
	var p := mb.get_popup()
	for it in items:
		if (it as Array).is_empty():
			p.add_separator()
			continue
		if checks:
			p.add_radio_check_item(it[0], it[1])
		else:
			p.add_item(it[0], it[1])
		if int(it[2]) != 0:
			var sc := Shortcut.new()
			var ev := InputEventKey.new()
			ev.keycode = int(it[2]) & KEY_CODE_MASK
			ev.ctrl_pressed = (int(it[2]) & KEY_MASK_CTRL) != 0
			ev.shift_pressed = (int(it[2]) & KEY_MASK_SHIFT) != 0
			sc.events = [ev]
			p.set_item_shortcut(p.get_item_count() - 1, sc, true)
	p.id_pressed.connect(handler)
	return mb


func _on_file(id: int) -> void:
	match id:
		F_NEW: _clear_dialog.popup_centered()
		F_OPEN: show_open("open")
		F_SAVE: action.emit("save", null)
		F_SAVE_AS: show_save_as("")
		F_QUICK_SAVE: action.emit("quick_save", null)
		F_QUICK_LOAD: action.emit("quick_load", null)
		F_CITY: action.emit("city", null)


func _on_insert(id: int) -> void:
	match id:
		I_BUILD: show_open("insert")
		I_TOWER: action.emit("tower", null)
		I_BAKE: action.emit("bake_tower", null)
		I_REMOVE_TOWER: action.emit("remove_tower", null)


func _on_type(id: int) -> void:
	if id >= 0 and id < BuildRecipe.KINDS.size():
		action.emit("kind", BuildRecipe.KINDS[id])


func _on_gen(id: int) -> void:
	if id == G_PROGRAM:
		action.emit("program_dialog", null)
		return
	if id == G_REROLL:
		action.emit("reroll", null)
		return
	var p := _gen.get_popup()
	var i := p.get_item_index(id)
	var on := not p.is_item_checked(i)
	p.set_item_checked(i, on)
	match id:
		G_ROOMS: action.emit("tower_option", ["rooms", on])
		G_STAIRS: action.emit("tower_option", ["stairs", on])
		G_WINDOWS: action.emit("tower_option", ["windows", on])
		G_FURNISH: action.emit("tower_option", ["furnish", on])


# ---------------------------------------------------------------------------
# Open / insert
# ---------------------------------------------------------------------------

func _build_open_dialog() -> void:
	_open_dialog = ConfirmationDialog.new()
	_open_dialog.title = "Open a build"
	_open_dialog.min_size = Vector2i(520, 420)
	add_child(_open_dialog)
	var box := VBoxContainer.new()
	_open_dialog.add_child(box)
	var row := HBoxContainer.new()
	box.add_child(row)
	var l := Label.new()
	l.text = "Show:"
	row.add_child(l)
	_open_filter = OptionButton.new()
	for k in DIRS:
		_open_filter.add_item(KIND_LABELS[k])
		_open_filter.set_item_metadata(_open_filter.item_count - 1, k)
	_open_filter.item_selected.connect(func(_i: int) -> void: _fill_open())
	row.add_child(_open_filter)
	_open_list = ItemList.new()
	_open_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_open_list.custom_minimum_size = Vector2(480, 320)
	_open_list.item_activated.connect(func(_i: int) -> void: _open_chosen())
	box.add_child(_open_list)
	_open_dialog.confirmed.connect(_open_chosen)


func show_open(mode: String) -> void:
	_open_mode = mode
	_open_dialog.title = "Open a build" if mode == "open" else "Insert a build into this one"
	_open_dialog.ok_button_text = "Open" if mode == "open" else "Pick up"
	# Opening defaults to the kind being authored; inserting is usually a building.
	var want := _kind if mode == "open" and DIRS.has(_kind) else "building"
	for i in _open_filter.item_count:
		if _open_filter.get_item_metadata(i) == want:
			_open_filter.select(i)
	_fill_open()
	_open_dialog.popup_centered()
	_open_list.grab_focus()


func _fill_open() -> void:
	_open_list.clear()
	var kind: String = _open_filter.get_item_metadata(_open_filter.selected)
	_open_paths = library(kind)
	for path in _open_paths:
		var info := describe(path)
		var where := "shipped" if path.begins_with("res://") else "yours"
		_open_list.add_item("%s   —  %s, %s" % [info.name, info.summary, where])
	if _open_paths.is_empty():
		_open_list.add_item("(nothing saved yet)")
		_open_list.set_item_disabled(0, true)
	elif _open_list.item_count > 0:
		_open_list.select(0)


func _open_chosen() -> void:
	var sel := _open_list.get_selected_items()
	if sel.is_empty() or sel[0] >= _open_paths.size():
		return
	var path := _open_paths[sel[0]]
	_open_dialog.hide()
	action.emit("open" if _open_mode == "open" else "insert", path)


## Every .json under the folders for `kind`, recursively (rooms are filed by
## room kind), in name order.
static func library(kind: String) -> PackedStringArray:
	var out := PackedStringArray()
	for dir in (DIRS.get(kind, []) as Array):
		_collect(dir, out)
	return out


static func _collect(dir: String, out: PackedStringArray) -> void:
	if not DirAccess.dir_exists_absolute(dir):
		return
	var files := DirAccess.get_files_at(dir)
	files.sort()
	for f in files:
		if f.ends_with(".json"):
			out.append(dir + f)
	var subs := DirAccess.get_directories_at(dir)
	subs.sort()
	for s in subs:
		_collect(dir + s + "/", out)


## A line about a saved build without building it: name and what is in it.
static func describe(path: String) -> Dictionary:
	var r := BuildRecipe.load_from(path)
	var n := r.name if r.name != "" and r.name != "untitled" else path.get_file().get_basename()
	var bits := PackedStringArray()
	bits.append("%d bricks" % r.size())
	if r.interior_count() > 0:
		bits.append("%d interior" % r.interior_count())
	if r.frame_count() > 1:
		bits.append("%d frames" % r.frame_count())
	if r.fixture_count() > 0:
		bits.append("%d fixture(s)" % r.fixture_count())
	if r.kind == "room" and r.meta.has("room_kind"):
		bits.append(str(r.meta.room_kind))
	return {"name": n, "summary": ", ".join(bits), "recipe": r}


# ---------------------------------------------------------------------------
# Save as
# ---------------------------------------------------------------------------

func _build_save_dialog() -> void:
	_save_dialog = ConfirmationDialog.new()
	_save_dialog.title = "Save as"
	_save_dialog.ok_button_text = "Save"
	_save_dialog.min_size = Vector2i(420, 140)
	add_child(_save_dialog)
	var box := VBoxContainer.new()
	_save_dialog.add_child(box)
	var l := Label.new()
	l.text = "Name:"
	box.add_child(l)
	_save_name = LineEdit.new()
	_save_name.placeholder_text = "my building"
	_save_name.text_submitted.connect(func(_t: String) -> void:
		_save_dialog.hide()
		_save_chosen())
	box.add_child(_save_name)
	_save_room_row = HBoxContainer.new()
	box.add_child(_save_room_row)
	var rl := Label.new()
	rl.text = "Room kind:"
	_save_room_row.add_child(rl)
	_save_room_kind = OptionButton.new()
	for k in Room.KINDS:
		_save_room_kind.add_item(k)
	_save_room_kind.add_item("any")   # items only: every kind of room
	_save_room_row.add_child(_save_room_kind)
	_save_dialog.confirmed.connect(_save_chosen)


func show_save_as(current_name: String, room_kind: String = "") -> void:
	_save_name.text = current_name
	_save_room_row.visible = _kind == "room" or _kind == "item"
	# "any" is for an item; a room template IS one kind of room.
	_save_room_kind.set_item_disabled(_save_room_kind.item_count - 1, _kind == "room")
	if _kind == "item" and room_kind == "":
		room_kind = "any"
	for i in _save_room_kind.item_count:
		if _save_room_kind.get_item_text(i) == room_kind:
			_save_room_kind.select(i)
	_save_dialog.title = "Save %s as" % (KIND_LABELS.get(_kind, _kind) as String).to_lower()
	_save_dialog.popup_centered()
	_save_name.grab_focus()
	_save_name.select_all()


func _save_chosen() -> void:
	var n := _save_name.text.strip_edges()
	if n == "":
		return
	var arg := {"name": n}
	if _kind == "room" or _kind == "item":
		arg["room_kind"] = _save_room_kind.get_item_text(_save_room_kind.selected)
	action.emit("save_as", arg)


# ---------------------------------------------------------------------------
# Clear
# ---------------------------------------------------------------------------

func _build_clear_dialog() -> void:
	_clear_dialog = ConfirmationDialog.new()
	_clear_dialog.title = "New build"
	_clear_dialog.dialog_text = "Clear the build space? Anything not saved is lost."
	_clear_dialog.ok_button_text = "Clear"
	add_child(_clear_dialog)
	_clear_dialog.confirmed.connect(func() -> void: action.emit("new", null))


# ---------------------------------------------------------------------------
# Room mix (Docs/Workshop.md, Stage F)
# ---------------------------------------------------------------------------

func _build_program_dialog() -> void:
	_program_dialog = ConfirmationDialog.new()
	_program_dialog.title = "Room mix"
	_program_dialog.ok_button_text = "Apply"
	add_child(_program_dialog)
	var box := VBoxContainer.new()
	_program_dialog.add_child(box)
	var l := Label.new()
	l.text = "How often each kind of room comes up (0 = never).\nAll zero is every kind alike."
	box.add_child(l)
	var grid := GridContainer.new()
	grid.columns = 2
	box.add_child(grid)
	for k in Room.KINDS:
		var kl := Label.new()
		kl.text = k
		grid.add_child(kl)
		var sp := SpinBox.new()
		sp.min_value = 0
		sp.max_value = 20
		sp.step = 1
		grid.add_child(sp)
		_program_spins[k] = sp
	_program_dialog.confirmed.connect(func() -> void:
		var prog := {}
		for k in _program_spins:
			var v := int((_program_spins[k] as SpinBox).value)
			if v > 0:
				prog[k] = v
		action.emit("tower_program", prog))


func show_program(program: Dictionary) -> void:
	for k in _program_spins:
		(_program_spins[k] as SpinBox).value = int(program.get(k, 0 if not program.is_empty() else 1))
	_program_dialog.popup_centered()
