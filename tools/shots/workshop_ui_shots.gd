extends SceneTree

## Not headless (it takes pictures): both workshops' screens, tool by tool, to compare their
## UI side by side (the rail, the top bar or stage tabs, the pop-out or options, the menus,
## the outliner, the brick browser).
##
##     godot --path . --script res://tools/shots/workshop_ui_shots.gd [-- --only=building|asset]
##
## Writes user://dev/ui_shots/*.png. Saves nothing of the user's: the hotbar and the part
## toolbars are pointed at user://dev/, and the asset autosave is switched off before a frame
## runs (it is still READ, so the asset pictures show the last session's build first).

const OUT := "user://dev/ui_shots/"


func _init() -> void:
	_go.call_deferred()


func _shot(name: String, frames: int = 8) -> void:
	for i in frames:
		await process_frame
	await RenderingServer.frame_post_draw
	root.get_viewport().get_texture().get_image().save_png(OUT + name + ".png")
	print("[ui shots] ", name)


func _go() -> void:
	DirAccess.make_dir_recursive_absolute(OUT)
	var only := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--only="):
			only = a.substr(7)
	if only != "asset":
		await _building()
	if only != "building":
		await _asset()
	quit()


func _close_menus(menu: WorkshopMenu) -> void:
	for mb in menu.bar().menus():
		(mb as MenuButton).get_popup().hide()


func _menu_shots(menu: WorkshopMenu, prefix: String, labels: Array) -> void:
	for mb in menu.bar().menus():
		var b := mb as MenuButton
		if not b.visible or not (b.text in labels):
			continue
		b.show_popup()
		await _shot("%s_menu_%s" % [prefix, b.text.to_lower().replace(" ", "_")], 6)
		b.get_popup().hide()


func _building() -> void:
	var ws = load("res://scenes/workshop.tscn").instantiate()
	root.add_child(ws)
	ws.bench._hotbar.save_path = "user://dev/_ui_shots_hotbar.json"
	for i in 30:
		await process_frame
	var t: WorkshopTools = ws.bench._tools
	t.pick("hand")
	await _shot("b01_hand_popout")
	t._fly_open = false
	await _shot("b02_hand_placing")
	t.pick("draw")
	await _shot("b03_draw_line_walls")
	t.set_outline("box")
	t.makes = "building"
	await _shot("b04_draw_box_building")
	t.makes = "solid"
	await _shot("b05_draw_box_solid")
	t.pick("roof")
	await _shot("b06_roof")
	t.pick("stairs")
	await _shot("b07_stairs")
	t.pick("cut")
	await _shot("b08_cut")
	t.cut_kind = "window"
	await _shot("b09_cut_window")
	t.pick("repeat")
	await _shot("b10_repeat")
	t.pick("select")
	await _shot("b11_select")
	t.pick("rooms")
	await _shot("b12_rooms")
	t.pick("paint")
	await _shot("b13_paint")
	t.pick("hand")
	t._fly_open = false
	ws.bench._hotbar.toggle_browser()
	await _shot("b14_browser", 30)
	ws.bench._hotbar.toggle_browser()
	t.act("keys")
	ws.bench._place_keys()
	await _shot("b15_keys")
	t.act("keys")
	await _menu_shots(ws.bench._menu, "b16", ["File", "Edit", "Insert", "Type", "Layer", "Generated", "Finish"])
	ws.bench._menu.show_open("open")
	await _shot("b17_open_dialog")
	ws.bench._menu._open_dialog.hide()
	ws.bench._menu.show_save_as("my building")
	await _shot("b18_save_dialog")
	ws.bench._menu._save_dialog.hide()
	ws.queue_free()
	for i in 10:
		await process_frame


func _asset() -> void:
	var ws = load("res://scenes/asset_workshop.tscn").instantiate()
	root.add_child(ws)
	ws._no_autosave = true
	ws.bench._hotbar.save_path = "user://dev/_ui_shots_asset_hotbar.json"
	ws.toolbars_save = "user://dev/_ui_shots_asset_toolbars.json"
	for i in 40:
		await process_frame
	var ui: AssetWorkshopUI = ws._ui
	await _shot("a01_start_as_opened")
	ws.show_help(false)
	await _shot("a02_last_session")
	# A new asset: clay, nothing built, so Block out's tools can be picked.
	ws.bench._on_menu("new", null)
	for i in 20:
		await process_frame
	ui.set_stage("blockout")
	for id in ["select", "draw", "shape", "smooth", "measure"]:
		ui.pick_tool(id)
		await _shot("a1_blockout_" + id)
	ui.set_stage("bricks")
	for id in ["place", "select", "paint", "sketch", "shape", "move", "measure"]:
		ui.pick_tool(id)
		await _shot("a2_bricks_" + id)
	ui.set_stage("detail")
	for id in ["stud", "paint"]:
		ui.pick_tool(id)
		await _shot("a3_detail_" + id)
	ui.pick_tool("!point")
	await _shot("a3_detail_point")
	ui.pick_tool("!point")
	ui.set_stage("finish")
	await _shot("a4_finish")
	ui.set_stage("bricks")
	ws._toggle_panel()
	await _shot("a5_photos_panel")
	ws._toggle_panel()
	ws._toggle_guide_panel()
	await _shot("a5_guides_panel")
	ws._toggle_guide_panel()
	ws.toggle_catalog()
	await _shot("a5_catalog", 20)
	ws.toggle_catalog()
	ws.bench._hotbar.toggle_browser()
	await _shot("a5_browser", 30)
	ws.bench._hotbar.toggle_browser()
	ws.bench._keys_on = true
	ws.bench._keys_panel.visible = true
	await _shot("a5_keys_f1")
	ws.bench._keys_on = false
	ws.bench._keys_panel.visible = false
	await _menu_shots(ws.bench._menu, "a6", ["File", "Edit", "Asset", "View", "Part", "Block out", "Brick", "Gun",
			"Photos", "Help", "Finish"])
	ws.set_asset_kind("item")
	ui.set_stage("blockout")
	await _shot("a7_item_blockout", 12)
	ws.bench._on_menu("save_as_ask", null)
	await _shot("a7_item_save_dialog")
	ws.bench._menu._save_dialog.hide()
	ws.set_asset_kind("mech")
	await _shot("a7_mech", 12)
	await _menu_shots(ws.bench._menu, "a7", ["Mech"])
	ws.queue_free()
	for i in 10:
		await process_frame
