class_name WorkshopOutliner
extends RefCounted

## The building workshop's right side (Docs/BuildTools.md section 21, the frame): the
## outliner -- what the build is made of: its kept shapes, inserted builds, generated
## buildings, rooms and placed furniture -- and under it **Selected**, what the picked thing
## can do (Select's options, which were its pop-out). The asset workshop's own outliner is
## `AssetWorkshopUI`; both sit down the right under the bar (`WkFrame.side`).
##
## A click on a shape, a build or a room picks it (the tool it belongs to comes up); the
## generated buildings and the furniture are listed. It holds no state that matters: the tree
## is read back from the workshop when what it shows changes.

const WIDTH := 360.0

var t   ## the WorkshopTools, untyped: it is the one that makes this
var panel: PanelContainer
var tree: Tree
## Selected: a title, a line when nothing is picked, then the tools' boxes (`hold`).
var selected_box: VBoxContainer
var _none: Label
var _held: Array[Control] = []
var _sig := ""
var _since := 0.0
var _syncing := false


func setup(tools, layer: CanvasLayer) -> void:
	t = tools
	panel = PanelContainer.new()
	panel.name = "Outliner"
	panel.add_theme_stylebox_override("panel", t.ws.wk_ctx.panel_box())
	panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	panel.offset_left = -WIDTH - 10.0
	panel.offset_right = -10.0
	layer.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	panel.add_child(box)
	box.add_child(_title("Outliner", "What the build is made of. Click a shape, an inserted build or a room to pick it."))
	tree = Tree.new()
	tree.columns = 2
	tree.hide_root = true
	tree.custom_minimum_size = Vector2(WIDTH - 12.0, 200)
	tree.set_column_expand(0, true)
	tree.set_column_expand(1, false)
	tree.set_column_custom_minimum_width(1, 110)
	tree.focus_mode = Control.FOCUS_NONE
	tree.item_selected.connect(_on_select)
	box.add_child(tree)
	box.add_child(HSeparator.new())
	box.add_child(_title("Selected", "What the picked thing can do."))
	selected_box = VBoxContainer.new()
	selected_box.add_theme_constant_override("separation", 2)
	box.add_child(selected_box)
	_none = Label.new()
	_none.text = "Nothing picked. Select (L) picks a shape or an inserted build; a row above does too."
	_none.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_none.custom_minimum_size.x = WIDTH - 16.0
	_none.add_theme_font_size_override("font_size", 12)
	_none.add_theme_color_override("font_color", Color(0.7, 0.74, 0.8))
	selected_box.add_child(_none)


func _title(text: String, tip: String) -> Label:
	var l := Label.new()
	l.text = text
	l.tooltip_text = tip
	l.mouse_filter = Control.MOUSE_FILTER_PASS
	l.add_theme_font_size_override("font_size", 13)
	l.add_theme_color_override("font_color", Color(0.75, 0.8, 0.88))
	return l


## Move a box of the tools' options into Selected (it keeps showing and hiding itself).
func hold(c: Control) -> void:
	if c.get_parent() != null:
		c.get_parent().remove_child(c)
	selected_box.add_child(c)
	_held.append(c)


## Each frame: "nothing picked" when no held box shows; the tree again when what it shows
## changed (looked at four times a second).
func process(dt: float) -> void:
	var any := false
	for c in _held:
		any = any or c.visible
	_none.visible = not any
	_since += dt
	if _since < 0.25:
		return
	_since = 0.0
	var sig := _signature()
	if sig != _sig:
		_sig = sig
		refresh()


func _signature() -> String:
	var r: BuildRecipe = t.ws.recipe
	var bits := PackedStringArray([str(t.shapes().size()), str(t._rev), str(t.selected), str(r.groups.size()),
			str(t.ws._selected), str(r.towers.size()), str(r.placements.size()), str(_rooms().size()),
			str(t.ws._spaces.selected if t.ws._spaces != null else -1)])
	for sh in t.shapes():
		bits.append("%d:%d" % [int(sh.id), (sh.bricks as Array).size()])
	return "|".join(bits)


func _rooms() -> Array:
	return (t.ws.recipe.meta.get("structure", {}) as Dictionary).get("spaces", [])


## The tree from the workshop: a heading a kind of thing, a row each.
func refresh() -> void:
	_syncing = true
	tree.clear()
	var root := tree.create_item()
	var r: BuildRecipe = t.ws.recipe
	var names := {}
	for k in BrickShapes.KINDS:
		names[k[0]] = k[1]
	var sec := _section(root, "Shapes", t.shapes().size())
	for sh in t.shapes():
		var it := _row(sec, "%s  (%s)" % [names.get(sh.kind, sh.kind), sh.part], "%d bricks" % (sh.bricks as Array).size(),
				{"shape": int(sh.id)})
		if int(sh.id) == t.selected:
			it.select(0)
	sec = _section(root, "Inserted builds", r.groups.size())
	for i in r.groups.size():
		var g: Dictionary = r.groups[i]
		var it := _row(sec, String(g.get("name", "a build")), "%d bricks" % int(g.get("count", 0)), {"group": i})
		if i == t.ws._selected:
			it.select(0)
	sec = _section(root, "Generated", r.towers.size())
	for i in r.towers.size():
		var p: Dictionary = r.towers[i].get("params", {})
		_row(sec, "building %d" % (i + 1), "%d x %d studs" % [int(p.get("x", 0)), int(p.get("z", 0))], {})
	var rooms := _rooms()
	sec = _section(root, "Rooms", rooms.size())
	for i in rooms.size():
		var it := _row(sec, String((rooms[i] as Dictionary).get("kind", "room")), "", {"room": i})
		if t.ws._spaces != null and i == t.ws._spaces.selected:
			it.select(0)
	sec = _section(root, "Furniture", r.placements.size())
	for q in r.placements:
		var c: Array = q.get("cell", [0, 0, 0])
		_row(sec, String(q.get("asset", "")).get_file(), "at %d, %d, %d" % [int(c[0]), int(c[1]), int(c[2])], {})
	_syncing = false


func _section(root: TreeItem, text: String, n: int) -> TreeItem:
	var it := tree.create_item(root)
	it.set_text(0, text)
	it.set_text(1, str(n) if n > 0 else "none")
	it.set_selectable(0, false)
	it.set_selectable(1, false)
	it.set_custom_color(0, Color(0.75, 0.8, 0.88))
	it.collapsed = n == 0
	return it


func _row(parent: TreeItem, text: String, info: String, what: Dictionary) -> TreeItem:
	var it := tree.create_item(parent)
	it.set_text(0, text)
	it.set_text(1, info)
	it.set_metadata(0, what)
	it.set_selectable(0, not what.is_empty())
	it.set_selectable(1, false)
	return it


func _on_select() -> void:
	if _syncing:
		return
	var it := tree.get_selected()
	if it == null:
		return
	var what: Dictionary = it.get_metadata(0) if it.get_metadata(0) is Dictionary else {}
	if what.has("shape"):
		t.pick("select")
		t.ws._select_group(-1)
		t.selected = int(what.shape)
		t._rev += 1
	elif what.has("group"):
		t.pick("select")
		t.selected = -1
		t.ws._select_group(int(what.group))
	elif what.has("room"):
		t.pick("rooms")
		if t.ws._spaces != null:
			t.ws._spaces.selected = int(what.room)
	_sig = ""   # lit as the workshop now says
