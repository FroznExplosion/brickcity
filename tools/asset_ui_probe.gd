extends SceneTree

## The asset workshop's frame (AssetWorkshopUI; Docs/AssetWorkshop.md, "The asset
## workshop's frame"): stage tabs, the tool rail, its icons and pop-ups, the outliner --
## names, groups, dragging a piece onto a part, a part's own Make bricks -- the stage
## button, the kind's menus, the selection as the centre.
##
##     godot --headless --path . --script tools/asset_ui_probe.gd

var _pass := 0
var _fail := 0
var _ws
var _frames := 0
const STUD := 0.35


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s" % what)
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _init() -> void:
	_ws = load("res://scenes/asset_workshop.tscn").instantiate()
	root.add_child(_ws)
	process_frame.connect(_tick)


func _tick() -> void:
	_frames += 1
	if _frames != 3:
		return
	_ws.set_process(false)
	_ws._hotbar.save_path = "user://_probe_asset_hotbar.json"
	_ws.toolbars_save = "user://_probe_asset_toolbars.json"
	var ui: AssetWorkshopUI = _ws._ui
	print("asset workshop frame probe")
	_ok("the frame is there", ui != null)
	ui.process(0.3)
	_frame(ui)
	_outliner(ui)
	_stages(ui)
	_parts(ui)
	_kinds(ui)
	_ws.set_asset_kind("gun")
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _frame(ui: AssetWorkshopUI) -> void:
	_ok("four stage tabs, Block out first", ui._tab_buttons.size() == 4 and ui.stage == "blockout")
	var tips := true
	var icons := true
	for id in ui._tool_buttons:
		tips = tips and String((ui._tool_buttons[id] as Button).tooltip_text).length() > 20
		icons = icons and (ui._tool_buttons[id] as Button).icon != null
	_ok("every tool says what it does in its pop-up", tips and ui._tool_buttons.size() >= 5)
	_ok("every tool has an icon", icons)
	var old_hidden := true
	for id in _ws._rail_buttons:
		old_hidden = old_hidden and not (_ws._rail_buttons[id] as Button).visible
	_ok("the old rail's tool list is gone; its part picker stays", old_hidden
			and (_ws._rail_box.get_child(0) as Control).visible)
	_ok("the options are in the rail, under the tools", ui._tools_panel.is_ancestor_of(_ws._rail)
			and _ws._rail.get_global_rect().position.y >= ui._tools_panel.hint.get_global_rect().end.y)
	for pair in [["draw", "shape"], ["shape", "stamp"], ["smooth", "smooth"], ["select", "models"]]:
		ui.pick_tool(pair[0])
		_ok("Block out %s: sculpting, %s" % [pair[0], pair[1]], _ws.tool == "sketch" and _ws.sketch_draw == "sculpt"
				and _ws.sculpt_mode == pair[1] and ui.active_tool() == pair[0], "%s %s" % [_ws.tool, _ws.sculpt_mode])


func _model(name: String) -> Dictionary:
	var b1 := BoxMesh.new()
	b1.size = Vector3(1.0, 0.3, 0.3)
	var b2 := BoxMesh.new()
	b2.size = Vector3(0.3, 0.3, 0.3)
	var m1 := ArrayMesh.new()
	m1.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, b1.get_mesh_arrays())
	var a2 := b2.get_mesh_arrays()
	var v2: PackedVector3Array = a2[Mesh.ARRAY_VERTEX]
	for i in v2.size():
		v2[i] += Vector3(1.0, 0, 0)
	a2[Mesh.ARRAY_VERTEX] = v2
	var m2 := ArrayMesh.new()
	m2.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, a2)
	_ws.add_model([["receiver", m1], ["muzzle", m2]], name + ".glb")
	return _ws._placed


func _row(ui: AssetWorkshopUI, want: Callable) -> TreeItem:
	var it: TreeItem = ui._tree.get_root().get_first_child()
	while it != null:
		var d: Variant = it.get_metadata(0)
		if d is Dictionary and want.call(d):
			return it
		it = it.get_next_in_tree()
	return null


func _outliner(ui: AssetWorkshopUI) -> void:
	print("[probe] the outliner")
	ui.pick_tool("draw")
	var m := _model("two")
	ui.refresh()
	var model_row := _row(ui, func(d): return d.t == "model")
	_ok("the model is one item under the asset, its body in its pop-up", model_row != null
			and model_row.get_text(0) == "two" and String(model_row.get_tooltip_text(0)).contains("receiver"))
	var piece_row := _row(ui, func(d): return d.t == "piece")
	_ok("its other piece a child of it", piece_row != null and piece_row.get_parent() == model_row
			and piece_row.get_text(0) == "muzzle")
	_ok("adding it picked it, gizmo and all", _ws.sculpt_mode == "models" and _ws._gizmo.visible)
	_ok("the centre is the selection's", _ws.build_centre().is_equal_approx(_ws._placed_centre()))
	ui.pick_tool("draw")
	piece_row.select(0)
	_ok("its row picks that piece, in Select, with the gizmo", int(_ws._placed.get("piece", -1)) == 1
			and _ws.sculpt_mode == "models" and _ws._gizmo.visible and ui.active_tool() == "select")
	var barrel: int = _ws.part_names.find("barrel")
	piece_row.set_range(1, barrel + 1)
	ui.edited(piece_row, 1)
	_ok("its part chosen in its row", int(m.parts[1]) == barrel, str(m.parts))
	var stock: int = _ws.part_names.find("stock")
	var stock_row := _row(ui, func(d): return d.t == "part" and int(d.i) == stock)
	var drag := {"outliner": {"t": "piece", "m": m, "k": 1}}
	_ok("a piece dropped on a part takes that part", ui.drop_on(stock_row, drag, false) == "part"
			and ui.drop_on(stock_row, drag, true) == "part" and int(m.parts[1]) == stock, str(m.parts))
	_ok("a piece cannot be dropped on a model", ui.drop_on(model_row, drag, false) == "")
	model_row.set_checked(2, false)
	ui.edited(model_row, 2)
	_ok("its tick hides it", not (m.node as Node3D).visible)
	(m.node as Node3D).visible = true
	_ok("clay: Make bricks (all) is offered", ui.action_names().has("Make bricks (all)"), str(ui.action_names()))
	model_row.set_text(0, "frame")
	ui.edited(model_row, 0)
	_ok("renamed in its row, kept with the models", _ws.model_name(m) == "frame"
			and _ws._models_meta()[0].name == "frame")
	_ws._undo()
	_ok("and one undo puts the name back", _ws.model_name(_ws.models[0]) == "two")
	# Grouping: a second model dropped on the first makes a group of the two.
	var m2 := _model("three")
	ui.refresh()
	var first_row := _row(ui, func(d): return d.t == "model" and is_same(d.m, _ws.models[0]))
	var mdrag := {"outliner": {"t": "model", "m": m2}}
	_ok("a model dropped on a model groups the two", ui.drop_on(first_row, mdrag, true) == "group"
			and _ws.model_groups().size() == 1
			and String(_ws.models[0].group) == String(m2.group) and String(m2.group) != "")
	ui.refresh()
	var group_row := _row(ui, func(d): return d.t == "group")
	_ok("the group is a row, both models in it", group_row != null and group_row.get_child_count() == 2)
	group_row.set_text(0, "furniture")
	ui.edited(group_row, 0)
	_ok("a group renamed in its row", _ws.model_groups() == PackedStringArray(["furniture"]))
	ui.refresh()
	var asset_row := _row(ui, func(d): return d.t == "asset")
	_ok("a model dropped on the asset leaves its group", ui.drop_on(asset_row, mdrag, true) == "ungroup"
			and String(m2.group) == "")
	_ws.select_model(m2)
	_ws.drop_model()
	_ws.select_model(_ws.models[0])
	_ws.drop_model()
	_ws.select_model(null)


func _stages(ui: AssetWorkshopUI) -> void:
	print("[probe] stages")
	ui.set_stage("blockout")
	ui.pick_tool("draw")
	_dab("body", Vector3(500, 40, 500), 40.0)
	ui._stage_step()
	_ok("Make bricks: bricks, and the Bricks stage", _ws.sculpt_state == "bricks" and ui.stage == "bricks"
			and ui.active_tool() == "place")
	ui.refresh()
	_ok("bricks: no Make bricks any more, Bricks to clay instead", not ui.action_names().has("Make bricks (all)")
			and ui.action_names().has("Bricks to clay"), str(ui.action_names()))
	ui.pick_tool("paint")
	_ok("Bricks: Paint is the paint tool", _ws._painting and ui.active_tool() == "paint")
	ui.pick_tool("select")
	_ok("Bricks: Select is the box select", _ws.tool == "select" and ui.active_tool() == "select")
	ui._stage_step()
	_ok("Bricks to clay: clay, and the Block out stage", _ws.sculpt_state == "sdf" and ui.stage == "blockout")
	ui.set_stage("detail")
	_ok("Detail: studs first", _ws.tool == "stud" and ui.active_tool() == "stud")
	_ws._show_sculpt_note(true, "Nothing converted: a probe's note.")
	ui.process(0.1)
	_ok("what the workshop says is shown big at the top", ui._toast.visible
			and ui._toast.text.begins_with("Nothing converted"))
	ui.set_stage("blockout")


func _dab(part: String, at_studs: Vector3, length: float) -> void:
	_ws.select_part(_ws.part_names.find(part))
	var at: Vector3 = _ws.sculpt.to_sample(at_studs * STUD)
	_ws.sculpt.form.begin_edit()
	_ws._sculpt_op = SdfForm.ADD
	_ws.sculpt_radius = 1.5
	_ws._sculpt_dab(at, at + Vector3(length, 0, 0))
	_ws._sculpt_record(_ws.sculpt.form.end_edit())


## A part's own Make bricks, and back; a furniture item's parts named and added.
func _parts(ui: AssetWorkshopUI) -> void:
	print("[probe] parts")
	_ws._reset_space()
	ui.set_stage("blockout")
	_dab("body", Vector3(500, 40, 500), 40.0)
	_dab("barrel", Vector3(500, 60, 500), 40.0)
	var body: int = _ws.part_names.find("body")
	var barrel: int = _ws.part_names.find("barrel")
	ui.refresh()
	var body_row := _row(ui, func(d): return d.t == "part" and int(d.i) == body)
	body_row.select(0)
	ui._fill_actions()
	_ok("a part with clay offers its own Make bricks", ui.action_names().has("Make bricks of this part"),
			str(ui.action_names()))
	var before: int = _ws.recipe.size()
	ui.press_action("Make bricks of this part")
	var clay: Dictionary = _ws.clay_counts()
	_ok("that part is bricks, the other still clay", _ws.sculpt_state == "sdf" and _ws.recipe.size() > before
			and int(clay.get(body + 1, 0)) == 0 and int(clay.get(barrel + 1, 0)) > 0, str(clay))
	var all_body := true
	for i in range(before, _ws.recipe.size()):
		all_body = all_body and _ws.part_of[i] == body
	_ok("its bricks are that part's", all_body)
	ui.refresh()
	body_row = _row(ui, func(d): return d.t == "part" and int(d.i) == body)
	body_row.select(0)
	ui._fill_actions()
	_ok("then: no Make bricks for it, Back to clay instead", not ui.action_names().has("Make bricks of this part")
			and ui.action_names().has("This part back to clay"), str(ui.action_names()))
	_ok("its row says bricks", String(body_row.get_text(1)).ends_with("bricks"), body_row.get_text(1))
	var laid: int = _ws.recipe.size() - before
	ui.press_action("This part back to clay")
	clay = _ws.clay_counts()
	_ok("back to clay: its bricks gone, its clay back", _ws.recipe.size() == before
			and int(clay.get(body + 1, 0)) > 0, "%d bricks were laid; %s" % [laid, clay])
	_ws._undo()
	_ok("one undo makes them bricks again", _ws.recipe.size() == before + laid,
			"%d vs %d" % [_ws.recipe.size(), before + laid])
	_ws.sculpt_convert()
	_ok("then Make bricks (all): both parts bricks", _ws.sculpt_state == "bricks"
			and _ws.part_of.has(body) and _ws.part_of.has(barrel))
	_ws._reset_space()
	# A gun's parts are slots; a furniture item's are its own.
	_ok("a gun's part cannot be renamed", not _ws.rename_part(body, "seat"))
	_ws.set_asset_kind("item")
	_ok("a furniture item's part can", _ws.rename_part(0, "Seat") and _ws.part_names[0] == "seat")
	_ok("but not to a name taken", not _ws.rename_part(1, "seat"))
	var n: int = _ws.part_names.size()
	_ok("and a part added", _ws.add_part("legs") == n and _ws.part_names[n] == "legs"
			and _ws.sculpt.palette.size() == n + 2)
	ui.refresh()
	var seat_row := _row(ui, func(d): return d.t == "part" and int(d.i) == 0)
	_ok("its part rows are renamable there", seat_row.is_editable(0))
	seat_row.select(0)
	ui._fill_actions()
	_ok("with Add part and Rename part", ui.action_names().has("Add part") and ui.action_names().has("Rename part"))


func _kinds(ui: AssetWorkshopUI) -> void:
	_ws.set_asset_kind("item")
	ui.set_stage("finish")
	_ok("furniture: no Gun or Mech menu, no hands or play", not _menu_shown("Gun") and not _menu_shown("Mech")
			and not ui._tool_buttons.has("!hands") and ui._tool_buttons.has("!save"))
	_ws.set_asset_kind("gun")
	ui.set_stage("finish")
	_ok("a gun: its Gun menu and its hands", _menu_shown("Gun") and not _menu_shown("Mech")
			and ui._tool_buttons.has("!hands"))
	_ws.set_asset_kind("mech")
	_ok("a mech: its Mech menu", _menu_shown("Mech") and not _menu_shown("Gun"))


func _menu_shown(label: String) -> bool:
	for mb in _ws._menu.find_children("*", "MenuButton", true, false):
		if (mb as MenuButton).text == label:
			return (mb as MenuButton).visible
	return false
