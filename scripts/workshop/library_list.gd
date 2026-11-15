class_name LibraryList
extends VBoxContainer

## A section of the workshop's library (Docs/BuildTools.md section 21, stage 5): the saved
## builds of one kind (`WorkshopMenu.library`), by name, filtered by the library's search.
## Picking one calls `picked(path)`.

signal picked(path: String)

var kind := "building"
var _list: ItemList
var _paths := PackedStringArray()
var _all := []   ## [path, name, summary, where]


func _init(p_kind: String = "building") -> void:
	kind = p_kind
	custom_minimum_size = Vector2(8 * 84, 2.5 * 104 + 120)
	_list = ItemList.new()
	_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_list.custom_minimum_size = Vector2(8 * 84, 2.5 * 104 + 110)
	_list.focus_mode = Control.FOCUS_NONE
	_list.item_activated.connect(_pick)
	_list.item_clicked.connect(func(i: int, _at: Vector2, button: int) -> void:
		if button == MOUSE_BUTTON_LEFT:
			_pick(i))
	add_child(_list)


## Read the library again (a build just saved is in it).
func reload() -> void:
	_all.clear()
	for path in WorkshopMenu.library(kind):
		var info := WorkshopMenu.describe(path)
		_all.append([path, String(info.name), String(info.summary), "shipped" if path.begins_with("res://") else "yours"])


func search(text: String) -> void:
	if _all.is_empty():
		reload()
	_list.clear()
	_paths = PackedStringArray()
	var q := text.strip_edges().to_lower()
	for e in _all:
		if q == "" or (e[1] as String).to_lower().contains(q) or (e[2] as String).to_lower().contains(q):
			_list.add_item("%s   --  %s, %s" % [e[1], e[2], e[3]])
			_paths.append(e[0])
	if _paths.is_empty():
		_list.add_item("(nothing saved yet)" if q == "" else "(nothing matches)")
		_list.set_item_disabled(0, true)


## The names shown now, for the probe.
func shown() -> PackedStringArray:
	return _paths


func _pick(i: int) -> void:
	if i >= 0 and i < _paths.size():
		picked.emit(_paths[i])
