extends SceneTree

## The asset workshop's frame (AssetWorkshopUI; Docs/AssetWorkshop.md, "The asset
## workshop's frame"): stage tabs, the tool rail and its pop-ups, the outliner, the
## stage button, the kind's menus, the selection as the centre.
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
	_ok("four stage tabs, Block out first", ui._tab_buttons.size() == 4 and ui.stage == "blockout")
	var tips := true
	for id in ui._tool_buttons:
		tips = tips and String((ui._tool_buttons[id] as Button).tooltip_text).length() > 20
	_ok("every tool says what it does in its pop-up", tips and ui._tool_buttons.size() >= 5)
	var old_hidden := true
	for id in _ws._rail_buttons:
		old_hidden = old_hidden and not (_ws._rail_buttons[id] as Button).visible
	_ok("the old rail's tool list is gone; its part picker stays", old_hidden
			and (_ws._rail_box.get_child(0) as Control).visible)
	_ok("the options panel sits under the tools", _ws._rail.position.y >= ui._tools_panel.position.y
			and absf(_ws.rail_top - (ui._tools_panel.position.y + ui._tools_panel.size.y + 6.0)) < 1.0)

	# Block out: each tool is the sculpt tool in its mode.
	for pair in [["draw", "shape"], ["shape", "stamp"], ["smooth", "smooth"], ["select", "models"]]:
		ui.pick_tool(pair[0])
		_ok("Block out %s: sculpting, %s" % [pair[0], pair[1]], _ws.tool == "sketch" and _ws.sketch_draw == "sculpt"
				and _ws.sculpt_mode == pair[1] and ui.active_tool() == pair[0], "%s %s" % [_ws.tool, _ws.sculpt_mode])
	ui.pick_tool("draw")
	var at: Vector3 = _ws.sculpt.to_sample(Vector3(500, 40, 500) * STUD)
	_ws.sculpt.form.begin_edit()
	_ws._sculpt_op = SdfForm.ADD
	_ws.sculpt_radius = 1.5
	_ws._sculpt_dab(at, at + Vector3(40, 0, 0))
	_ws._sculpt_record(_ws.sculpt.form.end_edit())

	# The outliner: a model of two pieces is one item, its second piece a child.
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
	_ws.add_model([["receiver", m1], ["muzzle", m2]], "two.glb")
	ui.refresh()
	var top: TreeItem = ui._tree.get_root().get_first_child()
	var model_row: TreeItem = top.get_first_child()
	_ok("the asset at the top, the model as one item under it", top != null and model_row != null
			and (model_row.get_metadata(0) as Dictionary).t == "model"
			and String(model_row.get_text(0)).contains("two") and String(model_row.get_text(0)).contains("receiver"))
	var piece_row: TreeItem = model_row.get_first_child()
	_ok("its other piece a child of it", piece_row != null and model_row.get_child_count() == 1
			and String(piece_row.get_text(0)) == "muzzle")
	_ok("adding it picked it, gizmo and all", _ws.sculpt_mode == "models" and _ws._gizmo.visible)
	_ok("the centre is the selection's", _ws.build_centre().is_equal_approx(_ws._placed_centre()))
	ui.pick_tool("draw")
	piece_row.select(0)
	_ok("its row picks that piece, in Select, with the gizmo", int(_ws._placed.get("piece", -1)) == 1
			and _ws.sculpt_mode == "models" and _ws._gizmo.visible and ui.active_tool() == "select")
	var barrel: int = _ws.part_names.find("barrel")
	piece_row.set_range(1, barrel + 1)
	ui.edited(piece_row, 1)
	_ok("its part chosen in its row", int(_ws._placed.parts[1]) == barrel, str(_ws._placed.parts))
	model_row.set_checked(2, false)
	ui.edited(model_row, 2)
	_ok("its tick hides it", not (_ws._placed.node as Node3D).visible)
	(_ws._placed.node as Node3D).visible = true
	var names := []
	for c in ui._actions.get_children():
		names.append((c as Button).text)
	_ok("clay: the selection can be made bricks", names.has("Make bricks") and names.has("Remove"), str(names))

	# The stage button: clay to bricks, Bricks stage; back.
	_ws.select_model(null)
	ui._stage_step()
	_ok("Make bricks: bricks, and the Bricks stage", _ws.sculpt_state == "bricks" and ui.stage == "bricks"
			and ui.active_tool() == "place")
	ui.refresh()
	names = []
	for c in ui._actions.get_children():
		names.append((c as Button).text)
	_ok("bricks: no Make bricks any more, Back to clay instead", not names.has("Make bricks")
			and names.has("Back to clay"), str(names))
	ui.pick_tool("paint")
	_ok("Bricks: Paint is the paint tool", _ws._painting and ui.active_tool() == "paint")
	ui.pick_tool("select")
	_ok("Bricks: Select is the box select", _ws.tool == "select" and ui.active_tool() == "select")
	ui.set_stage("blockout")
	ui.pick_tool("draw")
	_ok("Block out on bricks: no clay tool until it is clay again", _ws.tool != "sketch" or _ws.sculpt_mode != "shape"
			or _ws.sculpt_state == "bricks")
	ui._stage_step()
	_ok("Back to clay: clay, and the Block out stage", _ws.sculpt_state == "sdf" and ui.stage == "blockout")
	ui.set_stage("detail")
	_ok("Detail: studs first", _ws.tool == "stud" and ui.active_tool() == "stud")
	_ws._show_sculpt_note(true, "Nothing converted: a probe's note.")
	ui.process(0.1)
	_ok("what the workshop says is shown big at the top", ui._toast.visible
			and ui._toast.text.begins_with("Nothing converted"))

	# The kind's menus and tools.
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
	_ws.set_asset_kind("gun")
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _menu_shown(label: String) -> bool:
	for mb in _ws._menu.find_children("*", "MenuButton", true, false):
		if (mb as MenuButton).text == label:
			return (mb as MenuButton).visible
	return false
