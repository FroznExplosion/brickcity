class_name AssetWorkshopUI
extends Node

## The asset workshop's frame (Docs/AssetWorkshop.md, "The asset workshop's frame"):
##
##   stage tabs     1 Block out -> 2 Bricks -> 3 Detail -> 4 Finish, top left. A stage shows
##                  only its own tools. "Make bricks" takes the block-out to bricks, "Back to
##                  clay" the other way (Convert and Edit as SDF).
##   tool rail      under the tabs: a few tools a stage, each an icon and a name, with a
##                  pop-up saying what it does and its key, and a line under them for the
##                  tool in hand.
##   options        under the rail: the old rail, its tool list hidden -- what is left is
##                  the open tool's own options (brush size, shape, strength...).
##   outliner       top right: the asset; imported models, each one item (its first piece
##                  the main body) with its other pieces as children, in groups of the
##                  user's; the parts; guides; photos. Click to select, double-click a name
##                  to rename it (models, groups, and a furniture item's parts), tick to
##                  show or hide, drag a piece onto a part to give it that part, a model
##                  onto a group or another model to group them. Under it, what the
##                  selection can do -- a part's own "Make bricks" while it is clay.
##
## It owns no state of its own that matters: every button calls the workshop's own
## functions (the menus' and the keys'), and what is lit is read back from the workshop
## each frame, so a key pressed instead of a button shows the same.

const STAGES := [
	["blockout", "1 Block out", "Shape it in clay (SDF): draw, stamp shapes, import models. Nothing is bricks yet."],
	["bricks", "2 Bricks", "The clay made bricks: place, paint, sketch, select and move bricks."],
	["detail", "3 Detail", "Studs, connection points and colour: the small things that make it a part."],
	["finish", "4 Finish", "Look it over and send it out: explode, hands, export, save."],
]

## id, label, key, what it does. Tools with an "!" id are actions, not modes.
const TOOLS := {
	"blockout": [
		["select", "Select", "", "Click a model, one of its pieces, a part of the clay or a guide to pick it. Drag the gizmo: arrows move it, rings turn it, the cube resizes it. Enter or Esc lets go."],
		["draw", "Draw", "Alt V", "Drag to add clay to the part in the outliner; RMB carves it away; Shift smooths."],
		["shape", "Shape", "", "Drag out a box, ball, cylinder, cone, line or lathe of clay (choose it below). RMB carves."],
		["smooth", "Smooth", "", "Drag over the clay to round off its edges."],
		["!import", "Import model", "", "Load a model file (.glb .gltf .obj .fbx .stl) as one item: its first piece is the body, the others its children in the outliner."],
		["measure", "Measure", "Alt M", "Click two points: the distance in studs and plates, print mm and real mm."],
	],
	"bricks": [
		["place", "Place", "Esc", "Click to put the brick in hand on the stud you aim at; RMB takes one away; R turns it; 1-9 and the wheel pick the brick."],
		["select", "Select", "L", "Drag a box over bricks to select them; Delete removes them."],
		["paint", "Paint", "B", "Click or drag over bricks to give them the colour in hand."],
		["sketch", "Sketch", "Alt D", "Draw a flat outline on the working plane; it fills with bricks of this part."],
		["shape", "Shapes", "K", "Drag out a box, wall or round of bricks, or brush them on."],
		["move", "Move part", "Alt G", "Drag the current part's bricks to a new place."],
		["measure", "Measure", "Alt M", "Click two points: the distance in studs and plates, print mm and real mm."],
	],
	"detail": [
		["stud", "Studs", "Alt U", "Click a face to put a stud on it; RMB takes one off."],
		["!point", "Connection point", "J", "A mount or socket where the ghost is, for parts that join others."],
		["paint", "Paint", "B", "Click or drag over bricks to give them the colour in hand."],
		["measure", "Measure", "Alt M", "Click two points: the distance in studs and plates, print mm and real mm."],
	],
	"finish": [
		["!explode", "Explode", "Alt E", "Pull the parts apart to see how they join (again to put them back)."],
		["!hands", "Hands", "Alt H", "Show the hands holding it (guns)."],
		["!play", "Play: fire, reload", "Alt P", "Run the gun's fire and reload, to see the parts move."],
		["!export_game", "Export to game", "Alt X", "Write the parts as game scenes the game assembles."],
		["!export_print", "Export to print", "Alt B", "Write print files for each part and the whole."],
		["!save", "Save as...", "Ctrl Shift S", "Save it under a name; furniture and items get their planet, type and room tags."],
	],
}
## Finish actions that only mean something for a gun.
const GUN_ONLY := ["!hands", "!play"]


var ws    ## the AssetWorkshop
var stage := "blockout"

var _layer: CanvasLayer
var _tabs: HBoxContainer
var _tab_buttons := {}
var _stage_button: Button
var _tools_panel: ToolRail
var _tool_buttons := {}
var _hint: Label
var _outliner: PanelContainer
var _tree: Tree
var _actions: HFlowContainer
var _sig := ""
var _syncing := false
var _since := 0.0
## What the workshop last said (its sculpt note), shown big at the top for a few seconds:
## a refused Convert must not hide in a corner.
var _toast: Label
var _said := ""
var _toast_left := 0.0
var _ask: ConfirmationDialog
var _ask_line: LineEdit
var _ask_then := Callable()


func setup(workshop, layer: CanvasLayer) -> void:
	ws = workshop
	_layer = layer
	_build_tabs()
	_build_tools()
	_build_outliner()
	_toast = Label.new()
	_toast.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast.custom_minimum_size.x = 620
	_toast.add_theme_font_size_override("font_size", 16)
	_toast.add_theme_color_override("font_color", Color(1.0, 0.88, 0.5))
	_toast.add_theme_color_override("font_outline_color", Color.BLACK)
	_toast.add_theme_constant_override("outline_size", 6)
	_toast.visible = false
	_layer.add_child(_toast)
	if ws._sculpt_note != null:
		_said = ws._sculpt_note.text
	_ask = ConfirmationDialog.new()
	_ask_line = LineEdit.new()
	_ask.add_child(_ask_line)
	_ask.register_text_enter(_ask_line)
	_ask.confirmed.connect(func() -> void:
		if _ask_then.is_valid():
			_ask_then.call(_ask_line.text))
	_layer.add_child(_ask)
	_slim_old_rail()
	stage = "bricks" if ws.sculpt_state == "bricks" else "blockout"
	_fill_tools()
	sync_kind()


## A rail icon (the shared rail's, `ToolRail.ICONS`).
static func icon(id: String) -> Texture2D:
	return ToolRail.icon(id)


## Ask for a name: `then` gets it.
func ask(title: String, start: String, then: Callable) -> void:
	_ask.title = title
	_ask_line.text = start
	_ask_then = then
	_ask.popup_centered(Vector2i(360, 90))
	_ask_line.grab_focus()
	_ask_line.select_all()


# ---------------------------------------------------------------------------
# Stage tabs
# ---------------------------------------------------------------------------

func _build_tabs() -> void:
	_tabs = HBoxContainer.new()
	_tabs.add_theme_constant_override("separation", 4)
	_layer.add_child(_tabs)
	var group := ButtonGroup.new()
	for s in STAGES:
		var b := Button.new()
		b.text = s[1]
		b.toggle_mode = true
		b.button_group = group
		b.focus_mode = Control.FOCUS_NONE
		b.tooltip_text = s[2]
		b.pressed.connect(set_stage.bind(String(s[0])))
		_tabs.add_child(b)
		_tab_buttons[s[0]] = b
	_stage_button = Button.new()
	_stage_button.focus_mode = Control.FOCUS_NONE
	_stage_button.pressed.connect(_stage_step)
	_tabs.add_child(_stage_button)


## Show a stage's tools and pick its first. Moving between Block out and the rest does not
## convert by itself: the stage button does, so nothing is turned into bricks by a tab.
func set_stage(id: String) -> void:
	stage = id
	# Block out shows the clay, the others hide it; nothing is converted by a tab.
	ws.set_clay_view(id == "blockout")
	_fill_tools()
	match id:
		"blockout":
			if ws.sculpt_state == "sdf":
				pick_tool("draw")
		"bricks":
			pick_tool("place")
		"detail":
			pick_tool("stud")
		"finish":
			ws.rail_pick("place")
	print("[asset workshop] stage: %s" % id)


## The button beside the tabs: "Make bricks" while the block-out is clay, "Back to
## clay" once it is bricks.
func _stage_step() -> void:
	if ws.sculpt_state == "sdf":
		ws.sculpt_convert()
		if ws.sculpt_state == "bricks":
			set_stage("bricks")
	else:
		ws.sculpt_to_sdf()
		set_stage("blockout")


# ---------------------------------------------------------------------------
# The tool rail
# ---------------------------------------------------------------------------

func _build_tools() -> void:
	_tools_panel = ToolRail.new(ws.RAIL_W)
	_layer.add_child(_tools_panel)


func _fill_tools() -> void:
	var title := ""
	for s in STAGES:
		if s[0] == stage:
			title = String(s[1]).substr(2)
	_tools_panel.fill(title, TOOLS[stage], pick_tool, [] if ws.recipe.kind == "gun" else GUN_ONLY)
	_tool_buttons = _tools_panel.buttons
	_hint = _tools_panel.hint


## A rail button: the workshop's own tool for it, or the action.
func pick_tool(id: String) -> void:
	match stage + ":" + id:
		"blockout:select":
			_sculpt("models")
		"blockout:draw":
			_sculpt("shape")
		"blockout:shape":
			_sculpt("stamp")
		"blockout:smooth":
			_sculpt("smooth")
		"blockout:!import":
			ws._guide_into_sdf = true
			ws._guide_dialog.popup_centered_ratio(0.6)
		"detail:!point":
			ws.toggle_point_here()
		"finish:!explode":
			ws.set_exploded(not ws.exploded)
		"finish:!hands":
			ws.set_hands(not ws.hands_on)
		"finish:!play":
			ws.play_cycle()
		"finish:!export_game":
			ws.export_game()
		"finish:!export_print":
			ws.export_print()
		"finish:!save":
			ws._on_menu("save_as_ask", null)
		_:
			ws.rail_pick(id)


func _sculpt(mode: String) -> void:
	if ws.sculpt_state == "bricks":
		return   # clay tools on bricks: the stage button brings the clay back
	ws.rail_pick("sculpt")
	ws.set_sculpt_mode(mode)


## The rail's tool for the workshop's state now, "" for none of this stage's.
func active_tool() -> String:
	if ws.measure_on:
		return "measure"
	if stage == "blockout":
		if ws.tool == "sketch" and ws.sketch_draw == "sculpt":
			match String(ws.sculpt_mode):
				"models": return "select"
				"stamp": return "shape"
				"smooth": return "smooth"
			return "draw"
		return ""
	var on: String = ws.rail_active()
	return on if _tool_buttons.has(on) else ""


# ---------------------------------------------------------------------------
# The outliner
# ---------------------------------------------------------------------------

func _build_outliner() -> void:
	_outliner = PanelContainer.new()
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.1, 0.11, 0.14, 0.95)
	bg.set_content_margin_all(6)
	bg.set_corner_radius_all(4)
	_outliner.add_theme_stylebox_override("panel", bg)
	_outliner.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_outliner.offset_left = -370
	_outliner.offset_right = -10
	_layer.add_child(_outliner)
	var box := VBoxContainer.new()
	_outliner.add_child(box)
	var title := Label.new()
	title.text = "Outliner"
	title.tooltip_text = ("Click to select. Double-click a name to rename it. Tick to show or hide. "
			+ "Drag a piece onto a part to give it that part; a model onto a group, or onto another "
			+ "model, to group them; a model onto the asset to take it out of its group.")
	title.mouse_filter = Control.MOUSE_FILTER_PASS
	title.add_theme_font_size_override("font_size", 13)
	box.add_child(title)
	_tree = Tree.new()
	_tree.columns = 3
	_tree.hide_root = true
	_tree.custom_minimum_size = Vector2(350, 260)
	_tree.set_column_expand(0, true)
	_tree.set_column_expand(1, false)
	_tree.set_column_custom_minimum_width(1, 132)
	_tree.set_column_expand(2, false)
	_tree.set_column_custom_minimum_width(2, 28)
	_tree.focus_mode = Control.FOCUS_CLICK
	_tree.item_selected.connect(_on_select)
	_tree.item_edited.connect(_on_edit)
	_tree.set_drag_forwarding(_drag_data, _can_drop, _drop)
	box.add_child(_tree)
	_actions = HFlowContainer.new()
	box.add_child(_actions)


## What the tree shows, as a string: rebuilt only when it changes.
func _signature() -> String:
	var bits := PackedStringArray([ws.recipe.kind, ws.recipe.name, ws.sculpt_state, str(ws.part_sel),
			",".join(ws.part_names), str(ws.guides.size()), str(ws.photos.size()), str(ws.recipe.size()),
			str(ws._edits.size())])
	for m in ws.models:
		bits.append("%d:%s:%s:%s:%s:%s:%s" % [int(m.id), String(m.path), str(m.parts),
				str((m.node as Node3D).visible), str(int(m.op)), String(m.get("name", "")), String(m.get("group", ""))])
	var held: Dictionary = ws._placed
	bits.append("%s:%s:%s:%s" % [held.get("kind", "model" if not held.is_empty() else ""),
			str(held.get("id", -2)), str(held.get("piece", -1)), str(held.get("label", -1))])
	for g in ws.guides:
		bits.append(str((g.node as Node3D).visible))
	for p in ws.photos:
		bits.append(str(p.shown))
	return "|".join(bits)


func refresh() -> void:
	_sig = _signature()
	_syncing = true
	var keep := _selected_meta()
	_tree.clear()
	var root := _tree.create_item()
	var clay: bool = ws.sculpt_state == "sdf"
	var top := _tree.create_item(root)
	var kind_label: String = {"gun": "gun", "mech": "mech", "figure": "figure", "item": "furniture or item"}.get(
			ws.recipe.kind, ws.recipe.kind)
	top.set_text(0, "%s  (%s)" % [ws.recipe.name if ws.recipe.name != "untitled" else "New asset", kind_label])
	top.set_text(1, "clay" if clay else "bricks")
	top.set_custom_color(1, _state_colour(clay))
	top.set_metadata(0, {"t": "asset"})
	top.set_selectable(1, false)
	top.set_selectable(2, false)
	var held: Dictionary = ws._placed
	# Imported models: in their groups, then the rest; one item each, its first piece the
	# item, the rest its children.
	var group_rows := {}
	for g in ws.model_groups():
		var gr := _tree.create_item(top)
		gr.set_text(0, g)
		gr.set_text(1, "group")
		gr.set_editable(0, true)
		gr.set_metadata(0, {"t": "group", "g": g})
		gr.set_selectable(1, false)
		group_rows[g] = gr
	for m in ws.models:
		var under: TreeItem = group_rows.get(String(m.get("group", "")), top)
		var pieces: Array = m.pieces
		var it := _tree.create_item(under)
		it.set_text(0, ws.model_name(m))
		it.set_editable(0, true)
		it.set_tooltip_text(0, "%s  --  its body: %s%s" % [String(m.path).get_file(),
				String(pieces[0].name) if pieces.size() > 0 else "?",
				"  (carves)" if int(m.op) == SdfForm.REMOVE else ""])
		it.set_text(1, "carving model" if int(m.op) == SdfForm.REMOVE else "clay model")
		it.set_custom_color(1, _state_colour(true))
		it.set_metadata(0, {"t": "model", "m": m})
		_check(it, (m.node as Node3D).visible)
		for k in range(1, pieces.size()):
			var c := _tree.create_item(it)
			c.set_text(0, String(pieces[k].name))
			# Its part, chosen here (or dragged onto a part).
			var names := PackedStringArray(["(as the body)"])
			names.append_array(ws.part_names)
			c.set_cell_mode(1, TreeItem.CELL_MODE_RANGE)
			c.set_text(1, ",".join(names))
			c.set_range(1, int(m.parts[k]) + 1)
			c.set_editable(1, true)
			c.set_metadata(0, {"t": "piece", "m": m, "k": k})
	# The parts: what each brick and each cell of clay belongs to.
	var parts := _tree.create_item(top)
	parts.set_text(0, "Parts")
	parts.set_metadata(0, {"t": "parts"})
	parts.set_selectable(1, false)
	parts.set_selectable(2, false)
	var counts := {}
	for i in ws.part_of.size():
		counts[int(ws.part_of[i])] = int(counts.get(int(ws.part_of[i]), 0)) + 1
	var cells: Dictionary = ws.clay_counts()
	for i in ws.part_names.size():
		var p := _tree.create_item(parts)
		p.set_text(0, ws.part_names[i])
		p.set_editable(0, ws.can_name_parts())
		var n_clay := int(cells.get(i + 1, 0))
		var n_bricks := int(counts.get(i, 0))
		var state := "clay" if n_bricks == 0 else ("%d bricks" % n_bricks)
		if n_clay > 0 and n_bricks > 0:
			state = "clay + %d bricks" % n_bricks
		elif n_clay == 0 and n_bricks == 0:
			state = "empty"
		p.set_text(1, state)
		p.set_custom_color(1, _state_colour(n_bricks == 0))
		p.set_metadata(0, {"t": "part", "i": i})
		p.set_selectable(2, false)
	if not ws.guides.is_empty():
		var gs := _tree.create_item(top)
		gs.set_text(0, "Guide models")
		gs.set_selectable(0, false)
		for i in ws.guides.size():
			var g := _tree.create_item(gs)
			g.set_text(0, String(ws.guides[i].path).get_file())
			g.set_text(1, "guide")
			g.set_metadata(0, {"t": "guide", "i": i})
			_check(g, (ws.guides[i].node as Node3D).visible)
	if not ws.photos.is_empty():
		var ps := _tree.create_item(top)
		ps.set_text(0, "Photos")
		ps.set_selectable(0, false)
		for i in ws.photos.size():
			var p := _tree.create_item(ps)
			p.set_text(0, String(ws.photos[i].path).get_file())
			p.set_text(1, String(ws.photos[i].plane))
			p.set_metadata(0, {"t": "photo", "i": i})
			_check(p, bool(ws.photos[i].shown))
	_select_current(root, held, keep)
	_syncing = false
	_fill_actions()


## Light the row of what the workshop has picked; else the row lit before.
func _select_current(root: TreeItem, held: Dictionary, keep: Dictionary) -> void:
	var want := {}
	if not held.is_empty() and held.get("kind", "model") == "model":
		var k := int(held.get("piece", -1))
		want = {"t": "piece", "m": held, "k": k} if k >= 1 else {"t": "model", "m": held}
	elif held.is_empty() and not keep.is_empty():
		want = keep
	else:
		want = {"t": "part", "i": ws.part_sel}
	var it := root.get_first_child()
	while it != null:
		var d: Variant = it.get_metadata(0)
		if d is Dictionary and _same(d, want):
			it.select(0)
			it.get_parent().collapsed = false
			return
		it = it.get_next_in_tree()


func _same(a: Dictionary, b: Dictionary) -> bool:
	if a.get("t") != b.get("t"):
		return false
	match String(a.t):
		"model": return is_same(a.m, b.m)
		"piece": return is_same(a.m, b.m) and int(a.k) == int(b.k)
		"part", "guide", "photo": return int(a.i) == int(b.i)
		"group": return String(a.g) == String(b.g)
	return true


func _selected_meta() -> Dictionary:
	var it := _tree.get_selected() if _tree != null else null
	if it != null and it.get_metadata(0) is Dictionary:
		return it.get_metadata(0)
	return {}


func _check(it: TreeItem, on: bool) -> void:
	it.set_cell_mode(2, TreeItem.CELL_MODE_CHECK)
	it.set_checked(2, on)
	it.set_editable(2, true)
	it.set_tooltip_text(2, "shown")


func _state_colour(clay: bool) -> Color:
	return Color(0.95, 0.75, 0.45) if clay else Color(0.55, 0.85, 1.0)


func _on_select() -> void:
	if _syncing:
		return
	var it := _tree.get_selected()
	if it == null:
		return
	var d: Dictionary = it.get_metadata(0) if it.get_metadata(0) is Dictionary else {}
	match String(d.get("t", "")):
		"model":
			_to_select()
			ws.select_model(d.m)
			ws.pick_piece(-1)
		"piece":
			_to_select()
			ws.select_model(d.m)
			ws.pick_piece(int(d.k))
		"part":
			if not ws._placed.is_empty() and ws._placed.get("kind") != "part":
				ws.select_model(null)
			ws.select_part(int(d.i))
		"guide":
			_to_select()
			ws.select_guide(int(d.i))
		"photo":
			ws.photo_sel = int(d.i)
			ws._refresh_panel()
		"asset", "group", "parts":
			ws.select_model(null)
	ws._centre_on_selection()
	_fill_actions()


## Picking something to move it: Block out's Select, where the gizmo is.
func _to_select() -> void:
	if stage == "blockout" and ws.sculpt_state == "sdf":
		pick_tool("select")


func _on_edit() -> void:
	if _syncing:
		return
	edited(_tree.get_edited(), _tree.get_edited_column())


## A cell of a row changed: a name, a piece's part, or a tick. Public for the probe.
func edited(it: TreeItem, col: int) -> void:
	var d: Dictionary = it.get_metadata(0) if it.get_metadata(0) is Dictionary else {}
	var t := String(d.get("t", ""))
	if col == 0:
		var n := it.get_text(0).strip_edges()
		match t:
			"model":
				ws.set_model_name(d.m, n)
			"group":
				for m in ws.models:
					if String(m.get("group", "")) == String(d.g):
						ws.set_model_group(m, n)
			"part":
				if not ws.rename_part(int(d.i), n):
					_sig = ""   # refused: the tree shows the name again
		return
	if col == 1 and t == "piece":
		ws.select_model(d.m)
		ws.set_piece_part(int(d.k), int(it.get_range(1)) - 1)
	elif col == 2:
		var on := it.is_checked(2)
		match t:
			"model":
				(d.m.node as Node3D).visible = on
			"guide":
				(ws.guides[int(d.i)].node as Node3D).visible = on
			"photo":
				ws.set_photo_shown(int(d.i), on)


# ---------------------------------------------------------------------------
# Drag and drop in the outliner
# ---------------------------------------------------------------------------

func _drag_data(at: Vector2) -> Variant:
	var it := _tree.get_item_at_position(at)
	if it == null or not it.get_metadata(0) is Dictionary:
		return null
	var d: Dictionary = it.get_metadata(0)
	if not String(d.get("t", "")) in ["piece", "model"]:
		return null
	var l := Label.new()
	l.text = it.get_text(0)
	_tree.set_drag_preview(l)
	_tree.drop_mode_flags = Tree.DROP_MODE_ON_ITEM
	return {"outliner": d}


func _can_drop(at: Vector2, data: Variant) -> bool:
	return not drop_on(_tree.get_item_at_position(at), data, false).is_empty()


func _drop(at: Vector2, data: Variant) -> void:
	drop_on(_tree.get_item_at_position(at), data, true)
	_tree.drop_mode_flags = Tree.DROP_MODE_DISABLED


## What dropping `data` on row `it` does ("" for nothing), and with `apply` does it:
##   a piece on a part    the piece takes that part;
##   a model on a group   into that group; on another model: grouped with it (a new group
##                        if that one has none); on the asset row: out of its group.
func drop_on(it: TreeItem, data: Variant, apply: bool) -> String:
	if it == null or not data is Dictionary or not (data as Dictionary).has("outliner"):
		return ""
	var src: Dictionary = data.outliner
	if not it.get_metadata(0) is Dictionary:
		return ""
	var dst: Dictionary = it.get_metadata(0)
	var st := String(src.get("t", ""))
	var dt := String(dst.get("t", ""))
	if st == "piece" and dt == "part":
		if apply:
			ws.select_model(src.m)
			ws.set_piece_part(int(src.k), int(dst.i))
		return "part"
	if st == "model" and dt == "group":
		if apply:
			ws.set_model_group(src.m, String(dst.g))
		return "group"
	if st == "model" and dt == "model" and not is_same(src.m, dst.m):
		if apply:
			var g := String(dst.m.get("group", ""))
			if g == "":
				g = _new_group_name()
				ws.set_model_group(dst.m, g)
			ws.set_model_group(src.m, g)
		return "group"
	if st == "model" and dt == "asset" and String(src.m.get("group", "")) != "":
		if apply:
			ws.set_model_group(src.m, "")
		return "ungroup"
	return ""


func _new_group_name() -> String:
	var n := 1
	while ws.model_groups().has("group %d" % n):
		n += 1
	return "group %d" % n


## What the selection can do, as buttons under the tree.
func _fill_actions() -> void:
	for c in _actions.get_children():
		_actions.remove_child(c)
		c.queue_free()
	var clay: bool = ws.sculpt_state == "sdf"
	var held: Dictionary = ws._placed
	var d := _selected_meta()
	var t := String(d.get("t", ""))
	if t == "part" and clay:
		var i := int(d.i)
		var cells: Dictionary = ws.clay_counts()
		# A part's own: gone once it has no clay; back again while it has bricks.
		if int(cells.get(i + 1, 0)) > 0:
			_action("Make bricks of this part", "Only this part's clay into bricks; the rest stays clay.",
					func() -> void: ws.convert_part(i))
		if ws.part_of.has(i):
			_action("This part back to clay", "This part's bricks back into clay; the rest as it is.",
					func() -> void: ws.clay_part(i))
	if clay:
		_action("Make bricks (all)", "Turn all the clay into bricks: the block-out and the models.",
				func() -> void: _stage_step())
	else:
		_action("Bricks to clay", "Turn the bricks into clay to reshape them.", func() -> void: _stage_step())
	if t == "model" and not held.is_empty():
		var m: Dictionary = d.m
		_action("Rename", "Give this model a name of your own.", func() -> void:
			ask("Rename the model", ws.model_name(m), func(n: String) -> void: ws.set_model_name(m, n)))
		_action("Group", "Put it in a group (a new name makes a new group).", func() -> void:
			ask("Group it as", String(m.get("group", "")) if String(m.get("group", "")) != "" else _new_group_name(),
					func(n: String) -> void: ws.set_model_group(m, n)))
		if String(m.get("group", "")) != "":
			_action("Ungroup", "Take it out of its group.", func() -> void: ws.set_model_group(m, ""))
	if t in ["model", "piece"] and held.get("kind", "model") == "model" and not held.is_empty():
		_action("Remove", "Take this model out.", func() -> void: ws.drop_model())
		_action("Bake into clay", "Join this model into the block-out for good.", func() -> void: ws.bake_model())
	if t in ["part", "parts"] and ws.can_name_parts():
		_action("Add part", "A new part of this item, with its own colour.", func() -> void:
			ask("New part", "part %d" % (ws.part_names.size() + 1), func(n: String) -> void:
				var i: int = ws.add_part(n)
				if i >= 0:
					ws.select_part(i)))
		if t == "part":
			var pi := int(d.i)
			_action("Rename part", "Give this part a name of your own.", func() -> void:
				ask("Rename the part", ws.part_names[pi], func(n: String) -> void: ws.rename_part(pi, n)))
	if not held.is_empty() or t == "part":
		_action("Mirror through it", "Put the mirror plane through the middle of the selection.",
				func() -> void: ws.mirror_through_selection())
	_action("Frame it", "Point the view and the grid at the selection.", func() -> void: ws._centre_on_selection(true))
	if t == "asset":
		_action("Clean up strays", "Take away the block-out outside the build area, and lone bricks far from the build. One undo.",
				func() -> void: ws.clean_strays())


func _action(text: String, tip: String, f: Callable) -> void:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(f)
	_actions.add_child(b)


## The action buttons now, by text: for the probe.
func action_names() -> Array:
	var out := []
	for c in _actions.get_children():
		out.append((c as Button).text)
	return out


func press_action(text: String) -> bool:
	for c in _actions.get_children():
		if (c as Button).text == text:
			(c as Button).pressed.emit()
			return true
	return false


# ---------------------------------------------------------------------------
# The old rail as the options panel; the kind's menus
# ---------------------------------------------------------------------------

## The old rail keeps its part picker and the open tool's options; its tool list and the
## finish buttons are the new rail's and the Finish stage's now.
func _slim_old_rail() -> void:
	var box: VBoxContainer = ws._rail_box
	var seps := 0
	for i in box.get_child_count():
		var c := box.get_child(i)
		if i == 0:
			continue   # the part picker
		if seps >= 2:
			break
		if c is HSeparator:
			seps += 1
		(c as Control).visible = false
		c.set_meta("slimmed", true)
	# The long how-to paragraphs: the rail's pop-ups and its hint line say it now.
	for l in [ws._sketch_title, ws._sketch_how]:
		if l != null:
			(l as Label).visible = false
	for c in ws._sculpt_box.get_children():
		if c is Label and String((c as Label).text).begins_with("Sculpt in 3D:"):
			(c as Label).visible = false


## The menus and the Finish tools a kind has: Gun only for a gun, Mech for a mech.
func sync_kind() -> void:
	if ws._menu != null:
		for mb in ws._menu.find_children("*", "MenuButton", true, false):
			match (mb as MenuButton).text:
				"Gun":
					(mb as MenuButton).visible = ws.recipe.kind == "gun"
				"Mech":
					(mb as MenuButton).visible = ws.recipe.kind == "mech"
	if _tools_panel != null:
		_fill_tools()
	_sig = ""


func process(dt: float) -> void:
	var top: float = 8.0 + (ws._menu.bar_height() if ws._menu != null else 0.0)
	_tabs.position = Vector2(12, top)
	var clay: bool = ws.sculpt_state == "sdf"
	_stage_button.text = "Make bricks  >" if clay else "<  Bricks to clay"
	_stage_button.tooltip_text = ("Turn the clay into bricks and go on to stage 2. The clay that becomes bricks is used up; smooth-marked clay stays." if clay
			else "Turn the bricks into clay to reshape them, and go back to stage 1. Only this turns bricks into clay.")
	for id in _tab_buttons:
		(_tab_buttons[id] as Button).set_pressed_no_signal(id == stage)
	# The building workshop's readout (the brick in hand, its layer, its cell) means
	# nothing while shaping clay.
	if ws._hud != null:
		ws._hud.visible = stage != "blockout"
	_tools_panel.position = Vector2(12, top + 38)
	_tools_panel.size = Vector2.ZERO
	ws.rail_top = _tools_panel.position.y + _tools_panel.size.y + 6.0
	_outliner.offset_top = top
	var on := active_tool()
	for id in _tool_buttons:
		var b: Button = _tool_buttons[id]
		if b.toggle_mode:
			b.set_pressed_no_signal(id == on)
	if _hint != null:
		var text := ""
		for t in TOOLS[stage]:
			if t[0] == on:
				text = t[3]
		_hint.text = text
	if ws._sculpt_note != null and ws._sculpt_note.text != _said:
		_said = ws._sculpt_note.text
		_toast.text = _said
		_toast.visible = true
		_toast_left = 7.0
	if _toast.visible:
		_toast_left -= dt
		_toast.visible = _toast_left > 0.0
		var vw: float = ws.get_viewport().get_visible_rect().size.x
		_toast.position = Vector2((vw - _toast.custom_minimum_size.x) * 0.5, top + 44)
	_since += dt
	if _since >= 0.25:
		_since = 0.0
		if _signature() != _sig:
			refresh()
