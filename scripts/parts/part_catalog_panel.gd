class_name PartCatalogPanel
extends PanelContainer
## The catalogue as a panel, the same one in the workshop and the inventory
## (Docs/ModularParts.md section 6, stage 3).
##
##   facets   tick any value of any facet: OR inside a facet, AND across facets. Each value
##            shows how many parts it would leave, counted against every OTHER facet's ticks,
##            so ticking "light" never hides the other classes' buttons.
##   search   words in the name, id, maker or creator.
##   sort     PartCatalog.SORTS, either way; ties on id.
##   group    by manufacturer, the default; off: one flat list.
##   Fits     only what fits the socket the panel is pointed at (set_fit_target), layers 1-2.
##
## Custom parts sit in the same list as official ones, marked "custom, by <creator>".
## Picking a part (double click or Enter) sends `part_picked`; what that does is the
## screen's business (the workshop swaps it on, stage 4; the inventory fits it, stage 7).

signal part_selected(r: PartRecord)
signal part_picked(r: PartRecord)

## The facets the panel offers, in the order shown. `scale` and `side` stay as filters a
## screen may set, but are rarely worth a row of buttons, so they come last.
const SHOWN_FACETS := ["source", "family", "manufacturer", "slot", "class", "weapon_class",
		"pod_kind", "length", "rarity", "creator", "tags", "scale", "side"]
const TITLES := {
	"source": "Source", "family": "Kind", "manufacturer": "Maker", "slot": "Part",
	"class": "Class", "weapon_class": "Gun class", "pod_kind": "Pod", "length": "Leg length",
	"rarity": "Rarity", "creator": "Creator", "tags": "Tags", "scale": "Scale", "side": "Side",
}

## A part's picture in the list, pixels across.
const ICON := 40

var catalog: PartCatalog
var _thumbs := {}   # dir -> Texture2D (or null: none)
## The parts the panel draws from (null: the whole catalogue). The inventory gives the
## parts a player owns.
var pool: Variant = null
## facet -> ticked values.
var query := {}
var search := ""
var sort_key := "name"
var descending := false
var group_by_maker := true
var fits_only := false

var _fit_host: PartRecord
var _fit_path := ""
var _fit_plan := ""
var _selected := ""

var _title: Label
var _search_edit: LineEdit
var _facet_box: VBoxContainer
var _tree: Tree
var _detail: Label
var _sort_list: OptionButton
var _desc_box: CheckBox
var _group_box: CheckBox
var _fits_box: CheckBox


func _init() -> void:
	custom_minimum_size = Vector2(720, 480)
	var box := VBoxContainer.new()
	add_child(box)
	var top := HBoxContainer.new()
	box.add_child(top)
	_title = Label.new()
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(_title)
	var clear := Button.new()
	clear.text = "Clear filters"
	clear.pressed.connect(clear_ticks)
	top.add_child(clear)

	_search_edit = LineEdit.new()
	_search_edit.placeholder_text = "search name, maker, creator"
	_search_edit.text_changed.connect(func(t: String) -> void:
		search = t
		refresh())
	box.add_child(_search_edit)

	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(split)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(260, 0)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	split.add_child(scroll)
	_facet_box = VBoxContainer.new()
	_facet_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_facet_box)
	_tree = Tree.new()
	_tree.hide_root = true
	_tree.columns = 3
	_tree.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tree.set_column_expand(0, true)
	_tree.set_column_expand(1, false)
	_tree.set_column_custom_minimum_width(1, 130)
	_tree.set_column_expand(2, false)
	_tree.set_column_custom_minimum_width(2, 150)
	_tree.set_column_expand_ratio(0, 3)
	_tree.item_selected.connect(_on_tree_selected)
	_tree.item_activated.connect(_on_tree_activated)
	split.add_child(_tree)

	_detail = Label.new()
	_detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_detail.custom_minimum_size = Vector2(0, 44)
	box.add_child(_detail)

	var bottom := HBoxContainer.new()
	box.add_child(bottom)
	var sort_label := Label.new()
	sort_label.text = "Sort"
	bottom.add_child(sort_label)
	_sort_list = OptionButton.new()
	for s in PartCatalog.SORTS:
		_sort_list.add_item(s)
	_sort_list.item_selected.connect(func(i: int) -> void:
		sort_key = PartCatalog.SORTS[i]
		refresh())
	bottom.add_child(_sort_list)
	_desc_box = _check(bottom, "reversed", func(on: bool) -> void: descending = on)
	_group_box = _check(bottom, "by maker", func(on: bool) -> void: group_by_maker = on)
	_group_box.set_pressed_no_signal(true)
	_fits_box = _check(bottom, "Fits", func(on: bool) -> void: fits_only = on)


func _check(row: HBoxContainer, text: String, set_it: Callable) -> CheckBox:
	var c := CheckBox.new()
	c.text = text
	c.toggled.connect(func(on: bool) -> void:
		set_it.call(on)
		refresh())
	row.add_child(c)
	return c


func set_catalog(cat: PartCatalog, parts: Variant = null) -> void:
	catalog = cat
	_thumbs.clear()   # read again: pictures may have been made since
	pool = parts
	refresh()


## Point the Fits toggle at a socket: the part at `path` in a `plan_name` build, hanging
## from `host`. A null host turns it off.
func set_fit_target(host: PartRecord, path: String, plan_name: String) -> void:
	_fit_host = host
	_fit_path = path
	_fit_plan = plan_name
	refresh()


func has_fit_target() -> bool:
	return _fit_host != null and _fit_path != ""


func tick(facet: String, value: Variant, on: bool = true) -> void:
	var vals: Array = query.get_or_add(facet, [])
	if on and not value in vals:
		vals.append(value)
	elif not on:
		vals.erase(value)
	if vals.is_empty():
		query.erase(facet)
	refresh()


func clear_ticks() -> void:
	query.clear()
	search = ""
	if _search_edit != null:
		_search_edit.text = ""
	refresh()


## The parts the panel lists, in the order it lists them.
func shown() -> Array[PartRecord]:
	if catalog == null:
		return []
	var list := _narrowed(query)
	if group_by_maker:
		var by_maker := {}
		for r in PartCatalog.sorted(list, sort_key, descending):
			(by_maker.get_or_add(r.manufacturer.to_lower(), []) as Array).append(r)
		var makers := by_maker.keys()
		makers.sort()
		var out: Array[PartRecord] = []
		for m in makers:
			out.append_array(by_maker[m])
		return out
	return PartCatalog.sorted(list, sort_key, descending)


## Each value of `facet` and how many parts ticking it would show: counted with every
## other facet's ticks, the search and Fits, but not this facet's own ticks.
func counts(facet: String) -> Dictionary:
	if catalog == null:
		return {}
	var others := query.duplicate()
	others.erase(facet)
	var c := catalog.values(facet, _narrowed(others))
	for v in query.get(facet, []):
		if not c.has(v):
			c[v] = 0   # ticked but none left: keep its button, to untick it
	return c


func _narrowed(q: Dictionary) -> Array[PartRecord]:
	var list := catalog.filter(q, pool)
	if search.strip_edges() != "":
		var words := search.to_lower().split(" ", false)
		var keep: Array[PartRecord] = []
		for r in list:
			var hay := " ".join([r.display_name, r.id, r.manufacturer,
					String(r.creator.get("name", ""))]).to_lower()
			var all_in := true
			for w in words:
				if not w in hay:
					all_in = false
					break
			if all_in:
				keep.append(r)
		list = keep
	if fits_only and has_fit_target():
		list = catalog.fitting(list, _fit_host, _fit_path, _fit_plan)
	return list


func refresh() -> void:
	if _tree == null:
		return
	_fits_box.disabled = not has_fit_target()
	_fits_box.tooltip_text = ("what fits %s on %s" % [_fit_path, _fit_host.id]) if has_fit_target() \
			else "nothing to fit to"
	_fill_facets()
	_fill_tree()


func _fill_facets() -> void:
	for c in _facet_box.get_children():
		_facet_box.remove_child(c)
		c.queue_free()
	for facet in SHOWN_FACETS:
		var c := counts(facet)
		# A facet with one value and nothing ticked tells nothing: every part has it.
		if c.size() < 2 and not query.has(facet):
			continue
		var title := Label.new()
		title.text = TITLES.get(facet, facet)
		title.add_theme_color_override("font_color", Color(1.0, 0.85, 0.45))
		_facet_box.add_child(title)
		var flow := HFlowContainer.new()
		_facet_box.add_child(flow)
		var ticked: Array = query.get(facet, [])
		for v in c:
			var b := Button.new()
			b.toggle_mode = true
			b.text = "%s %d" % [_value_text(facet, v), c[v]]
			b.button_pressed = v in ticked
			b.set_meta(&"facet", facet)
			b.set_meta(&"value", v)
			b.toggled.connect(func(on: bool) -> void: tick.call_deferred(facet, v, on))
			flow.add_child(b)


func _value_text(facet: String, v: Variant) -> String:
	match facet:
		"length":
			return "length %d" % v
		"rarity":
			return "rarity %d" % v
	var s := String(v)
	return s if s != "" else "(none)"


func _fill_tree() -> void:
	_tree.clear()
	var root := _tree.create_item()
	var list := shown()
	var total := 0
	if pool != null:
		total = (pool as Array).size()
	elif catalog != null:
		total = catalog.size()
	_title.text = "Parts (F7): %d of %d" % [list.size(), total]
	var group: TreeItem = null
	var group_maker := ""
	var keep: TreeItem = null
	for r in list:
		var parent := root
		if group_by_maker:
			if group == null or r.manufacturer.to_lower() != group_maker:
				group_maker = r.manufacturer.to_lower()
				group = _tree.create_item(root)
				group.set_text(0, r.manufacturer)
				group.set_selectable(0, false)
				group.set_selectable(1, false)
				group.set_selectable(2, false)
				group.set_custom_color(0, Color(1.0, 0.85, 0.45))
			parent = group
		var it := _tree.create_item(parent)
		it.set_text(0, r.display_name if r.display_name != "" else r.id)
		it.set_text(1, _kind_text(r))
		it.set_text(2, _source_text(r))
		it.set_metadata(0, r.id)
		it.set_tooltip_text(0, r.id)
		# Its picture, when it has one (PartThumbnail).
		var tex := _thumb(r)
		if tex != null:
			it.set_icon(0, tex)
			it.set_icon_max_width(0, ICON)
		if r.is_custom():
			it.set_custom_color(2, Color(0.55, 0.85, 1.0))
		if r.id == _selected:
			keep = it
	if keep != null:
		keep.select(0)
	_show_detail(catalog.get_part(_selected) if catalog != null and _selected != "" else null)


func _thumb(r: PartRecord) -> Texture2D:
	if r.dir == "":
		return null
	if not _thumbs.has(r.dir):
		_thumbs[r.dir] = PartThumbnail.texture_for(r.dir)
	return _thumbs[r.dir]


func _kind_text(r: PartRecord) -> String:
	var bits := PackedStringArray()
	if r.weight_class != "":
		bits.append(r.weight_class)
	if r.side != "any":
		bits.append(r.side)
	bits.append(r.slot)
	if r.param("length") != null:
		bits.append("len %d" % int(r.param("length")))
	return " ".join(bits)


func _source_text(r: PartRecord) -> String:
	if not r.is_custom():
		return "official"
	var who := String(r.creator.get("name", ""))
	return "custom, by %s" % who if who != "" else "custom"


func _show_detail(r: PartRecord) -> void:
	if r == null:
		_detail.text = "Tick any value to filter. Double click a part to pick it."
		return
	var lines := PackedStringArray(["%s  (%s, rev %d)" % [
			r.display_name if r.display_name != "" else r.id, r.id, r.rev]])
	var about := PackedStringArray([r.manufacturer, _kind_text(r), _source_text(r)])
	if r.interface() != "":
		about.append("mounts %s" % r.interface())
	lines.append(", ".join(about))
	if has_fit_target():
		var why := PartFit.why_not(r, _fit_host, _fit_path, _fit_plan)
		lines.append("fits %s" % _fit_path if why == "" else "does not fit %s: %s" % [_fit_path, why])
	_detail.text = "\n".join(lines)


func select_part(part_id: String) -> void:
	_selected = part_id
	refresh()


func selected() -> PartRecord:
	return catalog.get_part(_selected) if catalog != null else null


## Pick a part as a double click would.
func pick(part_id: String) -> void:
	var r := catalog.get_part(part_id) if catalog != null else null
	if r != null:
		_selected = part_id
		part_picked.emit(r)


func _on_tree_selected() -> void:
	var it := _tree.get_selected()
	if it == null or it.get_metadata(0) == null:
		return
	_selected = String(it.get_metadata(0))
	var r := catalog.get_part(_selected)
	_show_detail(r)
	part_selected.emit(r)


func _on_tree_activated() -> void:
	var it := _tree.get_selected()
	if it != null and it.get_metadata(0) != null:
		pick(String(it.get_metadata(0)))
