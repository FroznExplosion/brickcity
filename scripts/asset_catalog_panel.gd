class_name AssetCatalogPanel
extends PanelContainer

## The catalogue: furniture and items, filtered by the AssetTags levels (planet,
## then type, then room), searched by name, picked to place. One panel for the
## workshop and the game worlds. Docs/AssetWorkshop.md, "Furniture and items".
##
## Each level is a row of chips: "All", then each value with how many assets it
## would leave. Within a row, chips add (kitchen OR bedroom); a single-choice
## level (type) takes one. Rows narrow each other. A chip that would leave none
## is greyed. The filter is remembered between sessions (`save_path`).

## An asset was picked from the list.
signal picked(id: String)

const SAVE := "user://asset_catalog.json"
## Where the filter is remembered. A probe points it elsewhere.
var save_path := SAVE

## level id -> [value ids]; empty is All.
var filter := {}
var search := ""
var selected_id := ""

var _search_box: LineEdit
var _chips := {}          ## level id -> {"all": Button, "values": {value id: Button}}
var _list: ItemList
var _shown: Array = []    ## entries in the list, in order
var _count_label: Label


func _ready() -> void:
	custom_minimum_size = Vector2(380, 0)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.1, 0.11, 0.13, 0.94)
	sb.set_content_margin_all(10)
	sb.set_corner_radius_all(6)
	add_theme_stylebox_override("panel", sb)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	add_child(box)
	var title := Label.new()
	title.text = "Furniture and items"
	title.add_theme_font_size_override("font_size", 18)
	box.add_child(title)
	_search_box = LineEdit.new()
	_search_box.placeholder_text = "search by name"
	_search_box.clear_button_enabled = true
	_search_box.text_changed.connect(func(t: String) -> void:
		search = t
		refresh())
	box.add_child(_search_box)
	for l: Dictionary in AssetTags.levels():
		var head := Label.new()
		head.text = l.label
		head.add_theme_color_override("font_color", Color(0.7, 0.75, 0.8))
		box.add_child(head)
		var flow := HFlowContainer.new()
		box.add_child(flow)
		var row := {"all": _chip(flow, "All"), "values": {}}
		(row.all as Button).pressed.connect(func() -> void: set_level(l.id, []))
		for v: Dictionary in (l.values as Array):
			var b := _chip(flow, v.label)
			b.set_meta("label", v.label)
			b.pressed.connect(func() -> void: _toggle(l, v.id))
			row.values[v.id] = b
		_chips[l.id] = row
		filter[l.id] = []
	_count_label = Label.new()
	box.add_child(_count_label)
	_list = ItemList.new()
	_list.custom_minimum_size = Vector2(0, 220)
	_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_list.item_selected.connect(func(i: int) -> void:
		if i < _shown.size():
			selected_id = _shown[i].id
			picked.emit(selected_id))
	box.add_child(_list)
	_restore()
	refresh()


func _chip(parent: Control, text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.toggle_mode = true
	b.focus_mode = Control.FOCUS_NONE
	parent.add_child(b)
	return b


func _toggle(l: Dictionary, value: String) -> void:
	var on: Array = (filter.get(l.id, []) as Array).duplicate()
	if on.has(value):
		on.erase(value)
	elif l.multi:
		on.append(value)
	else:
		on = [value]
	set_level(l.id, on)


## Set one level of the filter (e.g. the planet underfoot) and redraw.
func set_level(level_id: String, values: Array) -> void:
	filter[level_id] = values.duplicate()
	refresh()
	_remember()


## Read the library again (a piece was just saved) and redraw.
func reload() -> void:
	AssetCatalog.reload()
	refresh()


## Redraw the chips' states and counts and the list.
func refresh() -> void:
	if _list == null:
		return
	for id in _chips:
		var row: Dictionary = _chips[id]
		var on: Array = filter.get(id, [])
		(row.all as Button).set_pressed_no_signal(on.is_empty())
		for v in (row.values as Dictionary):
			var b: Button = row.values[v]
			var n := AssetCatalog.count_with(filter, id, v, search)
			b.text = "%s  %d" % [b.get_meta("label"), n]
			b.set_pressed_no_signal(on.has(v))
			b.disabled = n == 0 and not on.has(v)
	_shown = AssetCatalog.find(filter, search)
	_list.clear()
	for e: Dictionary in _shown:
		var rooms: Array = e.tags.get("room", [])
		_list.add_item("%s   —  %s, %s" % [e.name, AssetTags.type_of(e.tags),
				"any room" if rooms.is_empty() else ", ".join(rooms)])
		if e.id == selected_id:
			_list.select(_list.item_count - 1)
	_count_label.text = "%d shown" % _shown.size() if not _shown.is_empty() \
			else "nothing fits -- save furniture or items from the asset workshop"


## The ids now listed, in order.
func shown_ids() -> Array:
	var out := []
	for e: Dictionary in _shown:
		out.append(e.id)
	return out


func _remember() -> void:
	var f := FileAccess.open(save_path, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify({"filter": filter}))


func _restore() -> void:
	if not FileAccess.file_exists(save_path):
		return
	var data = JSON.parse_string(FileAccess.get_file_as_string(save_path))
	if data is Dictionary and data.get("filter") is Dictionary:
		var clean := AssetTags.clean(data.filter)
		for id in filter:
			filter[id] = clean.get(id, [])
		# clean() always sets a type; a remembered All stays All.
		if (data.filter.get("type", []) as Array).is_empty():
			filter["type"] = []
