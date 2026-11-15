class_name AssetWorkshopUI
extends Node

## The asset workshop's frame (Docs/AssetWorkshop.md, "The asset workshop's frame"):
##
##   stage tabs     1 Block out -> 2 Bricks -> 3 Detail -> 4 Finish, top left. A stage shows
##                  only its own tools. "Make bricks" takes the block-out to bricks, "Bricks to
##                  clay" the other way.
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
		["!import", "Import", "", "Load a model file (.glb .gltf .obj .fbx .stl) as one item: its first piece is the body, the others its children in the outliner."],
		["measure", "Measure", "Alt M", "Click two points: the distance in studs and plates, print mm and real mm."],
	],
	"bricks": [
		["place", "Place", "Esc", "Click to put the brick in hand on the stud you aim at; RMB takes one away; R turns it; 1-9 and the wheel pick the brick."],
		["select", "Select", "L", "Drag a box over bricks to select them; Delete removes them."],
		["paint", "Paint", "B", "Click or drag over bricks to give them the colour in hand."],
		["sketch", "Sketch", "Alt D", "Draw a flat outline on the working plane; it fills with bricks of this part."],
		["shape", "Shapes", "K", "Drag out a box, wall or round of bricks, or brush them on."],
		["move", "Move", "Alt G", "Drag the current part's bricks to a new place."],
		["wand", "Fill", "F4", "Wand: click a colour patch on a reference photo; it fills with bricks of that colour."],
		["measure", "Measure", "Alt M", "Click two points: the distance in studs and plates, print mm and real mm."],
	],
	"detail": [
		["stud", "Studs", "Alt U", "Click a face to put a stud on it; RMB takes one off."],
		["!point", "Point", "", "Connection point: a mount or socket where the ghost is, for parts that join others."],
		["paint", "Paint", "B", "Click or drag over bricks to give them the colour in hand."],
		["measure", "Measure", "Alt M", "Click two points: the distance in studs and plates, print mm and real mm."],
	],
	"finish": [
		["!explode", "Explode", "Alt E", "Pull the parts apart to see how they join (again to put them back)."],
		["!hands", "Hands", "Alt H", "Show the hands holding it (guns)."],
		["!play", "Play", "Alt P", "Fire and reload: run the gun's fire and reload, to see the parts move."],
		["!export_game", "To game", "Alt X", "Export to the game: write the parts as game scenes the game assembles."],
		["!export_print", "To print", "Alt B", "Export to print: write print files for each part and the whole."],
		["!check", "Check", "F12", "Export and look at it in Blender: the part kit runs and shows its checks here."],
		["!save", "Save as", "Ctrl Shift S", "Save it under a name; furniture and items get their planet, type and room tags."],
	],
}
## What the status line says a tool does, short: stage:id (its whole story is in the rail's
## pop-up). Finish's are actions: nothing to say while they are not running.
const STATUS := {
	"blockout:select": "Click a model, a piece, a part or a guide   drag the gizmo   Enter lets go",
	"blockout:draw": "Drag adds clay to the part   RMB carves   Shift smooths",
	"blockout:shape": "Drag out a shape of clay (choose it in the pop-out)   RMB carves",
	"blockout:smooth": "Drag over the clay to round its edges",
	"place": "LMB lays the brick   RMB takes one away   R turns   1-9, Shift + wheel pick",
	"select": "Drag a box over bricks   Delete removes them",
	"paint": "LMB paints a brick (hold: a stroke)",
	"sketch": "Draw an outline on the working plane: it fills with bricks of the part",
	"shape": "Drag out a box, wall or round of bricks",
	"move": "Drag the part's bricks to a new place",
	"measure": "Click two points: the distance",
	"stud": "LMB puts a stud on a face   RMB takes it off",
}
## Buttons under the tools, every stage: [id, label, icon, pop-up] -- the panels and browsers
## the keys open, so each is a button on the screen (`_under_act`).
const UNDER_TOOLS := [
	["bricks", "Bricks   Tab", "place", "Bricks  (Tab)\nOpen or close the menu of every brick."],
	["parts", "Parts   F7", "parts", "Parts catalogue  (F7)\nEvery saved part, official and custom, to try on this build."],
	["photos", "Photos   F2", "photos", "Reference photos  (F2)\nLoad a photo, put it on a plane, calibrate its size."],
	["guides", "Guides   F3", "guides", "Guide models  (F3)\nAn existing model to build inside; never exported."],
	["help", "Help   F10", "help", "How to start, and the keys  (F10)"],
]
## Finish actions that only mean something for a gun.
const GUN_ONLY := ["!hands", "!play"]
## The bar's buttons this workshop has not: the layer (stage 4 makes it the tab), the room
## guide (rooms), Cancel (Esc is the Place tool here).
const BAR_SKIP := ["layer", "guide", "cancel"]
## The pop-out's width: the building workshop's (`WorkshopTools.POPOUT_W`).
const POPOUT_W := 204.0
## The rail's width: the building workshop's (`WorkshopTools.RAIL_W`).
const RAIL_W := 224.0


var ws    ## the AssetWorkshop
var stage := "blockout"

var _layer: CanvasLayer
## The band under the menus: the stage tabs, then the bar; a flow, so the bar takes a second row
## when the window is too narrow for one.
var _tabs: HFlowContainer
var _band: PanelContainer
var _tab_buttons := {}
var _stage_button: Button
var _bar_box: HBoxContainer
var _under := {}   ## id -> the button under the tools (`UNDER_TOOLS`)
var _tools_panel: WkRail
## Where the menu bar, the stage tabs, the rail and the outliner go (the kit's WkFrame): the
## tabs a band 8 under the bar, 30 high, the rail 8 under them, the outliner down the right.
var frame := WkFrame.new()
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
	_toast.add_theme_stylebox_override("normal", ws.bench.wk_ctx.panel_box())
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
	# The open tool's options go in the pop-out beside the rail, as in the building workshop
	# (Docs/BuildTools.md section 21, the frame), scrolling when taller than the window.
	ws._rail.get_parent().remove_child(ws._rail)
	ws._rail.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	_tools_panel.options.add_child(ws._rail)
	_tools_panel.pop_out(_layer, POPOUT_W)
	_fit_options(ws._rail)
	# The bar, the building workshop's own list (WorkshopBar), right of the stage tabs.
	_tabs.add_child(VSeparator.new())
	_bar_box = HBoxContainer.new()
	_bar_box.add_theme_constant_override("separation", 2)
	_tabs.add_child(_bar_box)
	_tools_panel.actions(WorkshopBar.without(BAR_SKIP), bar_act, _bar_box)
	var look: Button = _tools_panel.action_buttons.get("fps")
	if look != null:
		look.tooltip_text = "FPS  (Y)\nSwap the camera: FPS (the mouse looks; hold Alt for the cursor), or orbit (the cursor is free: MMB orbits, Shift MMB pans, the wheel zooms, RMB held looks round)."
	stage = "bricks" if ws.sculpt_state == "bricks" else "blockout"
	_fill_tools()
	sync_kind()


## A button under the tools (`UNDER_TOOLS`).
func _under_act(id: String) -> void:
	match id:
		"bricks": ws.bench._hotbar.toggle_browser()
		"parts": ws.toggle_catalog()
		"photos": ws._toggle_panel()
		"guides": ws._toggle_guide_panel()
		"help": ws.show_help(not ws._help.visible)


## Where the space right of the rail starts: right of its pop-out while that shows.
func rail_right() -> float:
	var r: float = _tools_panel.position.x + _tools_panel.size.x + 12.0
	var fly: Control = _tools_panel.flyout
	if fly != null and fly.visible:
		r = maxf(r, fly.position.x + fly.size.x + 12.0)
	return r


## A bar button: the camera and Redo are this workshop's, the rest the bench's.
func bar_act(id: String) -> void:
	match id:
		"fps": ws.toggle_look()
		"redo": ws.redo()
		"free": ws.set_free(not ws.free_place)
		"plane_back": ws.move_work_plane(-1)
		"plane_on": ws.move_work_plane(1)
		"view_3d": ws.set_view(0)
		"view_side": ws.set_view(1)
		"view_top": ws.set_view(2)
		"view_front": ws.set_view(3)
		"section": ws.set_section(not ws.section_on)
		"outlines": ws.set_outlines((ws.outlines + 1) % 3)
		"game_look": ws.set_game_view(not ws.game_view_on)
		_: ws.bench.bar_act(id)


## A rail icon (the shared rail's, `WkRail.ICONS`).
static func icon(id: String) -> Texture2D:
	return WkRail.icon(id)


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
	_band = PanelContainer.new()
	_band.name = "Band"
	_band.add_theme_stylebox_override("panel", ws.bench.wk_ctx.panel_box())   # the building's bar's look
	_layer.add_child(_band)
	_tabs = HFlowContainer.new()
	_tabs.add_theme_constant_override("h_separation", 4)
	_tabs.add_theme_constant_override("v_separation", 4)
	_band.add_child(_tabs)
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

## The frame's pieces: the menu bar, the stage tabs (a band 8 under the bar, its own width, 30
## high), the rail and the outliner. Set each frame: the menu comes and goes with the workshop.
func _frame_setup() -> void:
	frame.bar = ws.bench._menu.bar() if ws.bench._menu != null else null
	frame.band = _band
	frame.band_wide = true   # across the window, so the flow knows where to wrap
	frame.band_left = -1.0   # the building's: a margin from the edge and under the menus
	frame.band_gap = -1.0
	frame.band_space = -1.0   # its own height: one row or two
	frame.rail = _tools_panel
	frame.side = _outliner
	frame.side_under_band = true   # the tabs and the bar reach across


## The floating panels (photos, guides, the connection point, the parts catalogue): each on
## the rail's backdrop, between the rail and the outliner, under the readout when there is
## room, the open ones stacked. Called each frame after the workshop placed its own pieces.
## Until stage 1 makes them sections of Selected (section 21).
func place_floats(panels: Array) -> void:
	var vp: Vector2 = ws.get_viewport().get_visible_rect().size
	# Right of the rail; over the pop-out if they must, never over the rail or the outliner.
	var left: float = _tools_panel.position.x + _tools_panel.size.x + 12.0
	var right: float = _outliner.position.x - 12.0 if _outliner != null and _outliner.visible else vp.x - 12.0
	var top: float = frame.rail_top()
	var bottom: float = vp.y - ws.bench.STATUS_ROOM   # the status line and the hotbar
	# Under the readout and the toast while they show, if a panel fits there; else from the top.
	var under: float = top
	var hud: Control = ws.bench._hud
	if hud != null and hud.visible:
		under = maxf(under, hud.position.y + hud.size.y + 8.0)
	if _toast.visible:
		under = maxf(under, _toast.position.y + _toast.size.y + 8.0)
	var y: float = under
	var col_left := INF   # the left edge of the column being filled
	var room: float = right - left
	var covers: Array[Rect2] = []
	for p in panels:
		var c := p as Control
		if c == null or not c.visible:
			continue
		if not c.has_meta("wk_backdrop"):
			c.set_meta("wk_backdrop", true)
			c.add_theme_stylebox_override("panel", ws.bench.wk_ctx.panel_box())
		# A panel wider than the room (the parts catalogue asks 720) is held to it.
		if c.custom_minimum_size.x > room:
			c.custom_minimum_size.x = maxf(room, 240.0)
		c.size = Vector2.ZERO
		var s: Vector2 = c.get_combined_minimum_size()
		if y + s.y > bottom and y > under and col_left - 8.0 - s.x >= left:
			# This column is full: the next one goes left of it.
			right = col_left - 8.0
			col_left = INF
			y = under
		var at_y := y
		if at_y + s.y > bottom:
			at_y = maxf(top, bottom - s.y)
		var x := maxf(left, right - s.x)
		c.position = Vector2(x, at_y)
		col_left = minf(col_left, x)
		y = at_y + s.y + 8.0
		covers.append(Rect2(c.position, s))
	# The readouts draw over the panels: one a panel covers is hidden while it does.
	for r in [hud, ws._ruler, _toast]:
		var l := r as Control
		if l == null:
			continue
		var hit := false
		for q in covers:
			if (q as Rect2).intersects(Rect2(l.position, l.size)):
				hit = true
		l.modulate.a = 0.0 if hit else 1.0


func _build_tools() -> void:
	# The building workshop's rail: two columns, a tool's key in its pop-up (section 21).
	_tools_panel = WkRail.new(RAIL_W, true)
	ws.bench.wk_ctx.style_ui(_tools_panel)   # the game's look (GameUI, MenuTheme), through the kit's seam
	_tools_panel.restyle(ws.bench.wk_ctx.panel_box())
	_layer.add_child(_tools_panel)


func _fill_tools() -> void:
	var title := ""
	for s in STAGES:
		if s[0] == stage:
			title = String(s[1]).substr(2)
	_tools_panel.fill(title, TOOLS[stage], pick_tool, [] if ws.bench.recipe.kind == "gun" else GUN_ONLY, 2)
	_tool_buttons = _tools_panel.buttons
	_hint = _tools_panel.hint
	_under = {}
	for u in UNDER_TOOLS:
		_under[u[0]] = _tools_panel.add_under_tools(u[1], u[2], u[3], _under_act.bind(String(u[0])))
	_hint.visible = false   # what the tool does is the status line's first part (section 21)


## A stage's rail action from elsewhere (a menu): as if its button were pressed on that stage.
func pick_tool_in(on_stage: String, id: String) -> void:
	var was := stage
	stage = on_stage
	pick_tool(id)
	stage = was


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
			ws.bench._on_menu("save_as_ask", null)
		"finish:!check":
			ws.export_and_preview()
		"bricks:wand":
			ws.set_tool("" if ws.tool == "wand" else "wand")
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
	if ws.tool == "wand" and stage == "bricks":
		return "wand"
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
	var bits := PackedStringArray([ws.bench.recipe.kind, ws.bench.recipe.name, ws.sculpt_state, str(ws.part_sel),
			",".join(ws.part_names), str(ws.guides.size()), str(ws.photos.size()), str(ws.bench.recipe.size()),
			str(ws.bench.undo_stack.version)])
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
			ws.bench.recipe.kind, ws.bench.recipe.kind)
	top.set_text(0, "%s  (%s)" % [ws.bench.recipe.name if ws.bench.recipe.name != "untitled" else "New asset", kind_label])
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
			_action("Smooth / bricks", "This part leaves the workshop smooth (a custom piece) or as bricks (was N).",
					func() -> void:
						ws.select_part(pi)
						ws.toggle_smooth())
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


## The options under the tools kept to the rail's width, so the rail is one width whatever
## tool is open (it jumped from ~208 to ~330 px): labels and buttons wrap, choices clip,
## rows of buttons share the width. The building's pop-out does the same (`WorkshopTools._fit`).
## Run again when a control was added later (`process` checks the width).
func _fit_options(n: Node) -> void:
	var w: float = POPOUT_W - 26.0
	for c in n.get_children():
		if c is Label:
			var l := c as Label
			l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			if l.get_parent() is HBoxContainer:
				l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				l.custom_minimum_size.x = clampf(l.custom_minimum_size.x, 48.0, w)
			else:
				l.custom_minimum_size.x = w
		elif c is OptionButton:
			(c as OptionButton).clip_text = true
			(c as OptionButton).fit_to_longest_item = false
			(c as OptionButton).custom_minimum_size.x = minf((c as Control).custom_minimum_size.x, w) if (c as Control).custom_minimum_size.x > 0 else 0.0
		elif c is Button:
			# Alone on its line it wraps; in a row it keeps its width and the row wraps.
			var b := c as Button
			if not (b.get_parent() is HBoxContainer or b.get_parent() is HFlowContainer):
				b.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			b.custom_minimum_size.x = minf(b.custom_minimum_size.x, w)
		elif c is HBoxContainer and c.get_child_count() > 1 				and c.get_children().all(func(k: Node) -> bool: return k is Button and not k is OptionButton):
			# A row of buttons: they go into a flow inside the row, which wraps them; the
			# row stays (the workshop shows and hides it by name).
			var flow := HFlowContainer.new()
			flow.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			flow.add_theme_constant_override("h_separation", 2)
			flow.add_theme_constant_override("v_separation", 2)
			for k in c.get_children():
				c.remove_child(k)
				flow.add_child(k)
			c.add_child(flow)
		elif c is Range and not c is ScrollBar:
			(c as Control).custom_minimum_size.x = minf((c as Control).custom_minimum_size.x, w * 0.5)
		elif c is LineEdit:
			(c as Control).custom_minimum_size.x = minf((c as Control).custom_minimum_size.x, w)
		elif c is ScrollContainer or c is Container:
			if (c as Control).custom_minimum_size.x > w:
				(c as Control).custom_minimum_size.x = w
		_fit_options(c)


## The menus and the Finish tools a kind has: Gun only for a gun, Mech for a mech.
func sync_kind() -> void:
	if ws.bench._menu != null:
		for mb in ws.bench._menu.find_children("*", "MenuButton", true, false):
			var k: String = {"Gun": "gun", "Mech": "mech", "Figure": "figure", "Item": "item"}.get((mb as MenuButton).text, "")
			if k != "":
				(mb as MenuButton).visible = ws.bench.recipe.kind == k
	if _tools_panel != null:
		_fill_tools()
	_sig = ""


func process(dt: float) -> void:
	_frame_setup()
	frame.layout(ws.get_viewport().get_visible_rect().size)
	var top: float = frame.band_top()
	var clay: bool = ws.sculpt_state == "sdf"
	_stage_button.text = "Make bricks  >" if clay else "<  Bricks to clay"
	_stage_button.tooltip_text = ("Turn the clay into bricks and go on to stage 2. The clay that becomes bricks is used up; smooth-marked clay stays." if clay
			else "Turn the bricks into clay to reshape them, and go back to stage 1. Only this turns bricks into clay.")
	for id in _tab_buttons:
		(_tab_buttons[id] as Button).set_pressed_no_signal(id == stage)
	# The building workshop's readout (the brick in hand, its layer, its cell) means
	# nothing while shaping clay.
	if ws.bench._hud != null:
		ws.bench._hud.visible = stage != "blockout" and ws.bench.stats_on
	var vh: float = ws.get_viewport().get_visible_rect().size.y
	_tools_panel.fit_height(vh - frame.rail_top() - ws.bench.STATUS_ROOM)
	_tools_panel.size = Vector2.ZERO
	ws.rail_top = _tools_panel.position.y + _tools_panel.size.y + 6.0
	var on := active_tool()
	# The pop-out beside the tool in hand; the bar's toggles lit.
	var bt: Button = _tool_buttons.get(on)
	_tools_panel.place_flyout(bt.global_position.y if bt != null else frame.rail_top(), vh - ws.bench.STATUS_ROOM)
	var lit: Dictionary = ws.bench.bar_toggles()
	lit["fps"] = ws.cam_ctl.mode == "fps"
	lit["free"] = ws.free_place
	var open := {"bricks": ws.bench._hotbar.is_browsing(), "parts": ws._catalog_panel != null and ws._catalog_panel.visible,
			"photos": ws._panel.visible, "guides": ws._guide_panel.visible, "help": ws._help.visible}
	for id in _under:
		(_under[id] as Button).set_pressed_no_signal(bool(open.get(id, false)))
	lit["section"] = ws.section_on
	lit["outlines"] = ws.outlines > 0
	lit["game_look"] = ws.game_view_on
	for i in 4:
		lit[["view_3d", "view_side", "view_top", "view_front"][i]] = ws.view == i and not ws.game_view_on
	_tools_panel.show_toggles(lit)
	_tools_panel.set_action_text("mirror_axis", "across X" if ws.bench.mirror_axis == 0 else "across Z")
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
		# Between the rail and the outliner, under the readout (never on it), on a backdrop.
		var vw: float = ws.get_viewport().get_visible_rect().size.x
		var left: float = rail_right()
		var right: float = _outliner.position.x - 12.0 if _outliner != null and _outliner.visible else vw - 12.0
		_toast.custom_minimum_size.x = clampf(right - left, 240.0, 620.0)
		_toast.size = Vector2.ZERO
		var y: float = frame.rail_top()
		var hud: Control = ws.bench._hud
		if hud != null and hud.visible:
			y = maxf(y, hud.position.y + hud.size.y + 8.0)
		_toast.position = Vector2(left + maxf(right - left - _toast.custom_minimum_size.x, 0.0) * 0.5, y)
	# The status line: what the tool does, the part being built; the brick in hand off the clay.
	var says: String = STATUS.get(stage + ":" + on, STATUS.get(on, ""))
	if ws.part_sel < ws.part_names.size():
		says += ("   ·   " if says != "" else "") + "part: %s (%d of %d)" % [ws.part_names[ws.part_sel], ws.part_sel + 1, ws.part_names.size()]
	ws.bench.show_status(says, 12.0, ws.get_viewport().get_visible_rect().size.x - 12.0, stage != "blockout")
	_since += dt
	if _since >= 0.25:
		_since = 0.0
		if ws._rail.get_combined_minimum_size().x > POPOUT_W - 13.0:
			_fit_options(ws._rail)   # a control added since
		if _signature() != _sig:
			refresh()
