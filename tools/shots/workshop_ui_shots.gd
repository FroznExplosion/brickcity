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
	t.set_gen("tower")
	await _shot("b12b_generate_tower")
	t.set_gen("building")
	await _shot("b12c_generate_building")
	# Section 21, stage 7d: Generate > Model, a tapered round tower laid from a mesh.
	t.set_gen("model")
	var tower := CylinderMesh.new()
	tower.bottom_radius = 16.0 * BrickPalette.STUD_M
	tower.top_radius = 9.0 * BrickPalette.STUD_M
	tower.height = 40.0 * BrickPalette.STUD_M
	tower.radial_segments = 48
	tower.rings = 20
	# Coloured by height (stage 8b): a grey base, a white middle, a red band at the top.
	var tarr := tower.get_mesh_arrays()
	var tcols := PackedColorArray()
	for tv in (tarr[Mesh.ARRAY_VERTEX] as PackedVector3Array):
		var h: float = tv.y / tower.height + 0.5
		tcols.append(Color(0.45, 0.45, 0.48) if h < 0.2 else (Color(0.8, 0.1, 0.1) if h > 0.8 else Color(0.95, 0.95, 0.9)))
	tarr[Mesh.ARRAY_COLOR] = tcols
	var tmesh := ArrayMesh.new()
	tmesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, tarr)
	ws.bench._mat = 0   # plastic: the model's colours as they are
	t.model.size_studs = 30
	t.model.set_mesh(tmesh)
	await _shot("b12d_generate_model_budget")
	# Stage 8c: the colour table merged down to three.
	t.model.fewer(3)
	await _shot("b12f_generate_model_fewer")
	t.model.lay()
	while t.model.state == "laying":
		await process_frame
	await _shot("b12e_generate_model_laid", 12)
	ws.bench._undo()
	t.pick("paint")
	await _shot("b13_paint")
	t.set_stage("finish")
	await _shot("b13b_finish_tab")
	t.set_stage("structure")
	t.pick("hand")
	t._fly_open = false
	ws.bench._hotbar.toggle_browser()
	await _shot("b14_browser", 30)
	ws.bench._hotbar.show_section("furniture", false)
	await _shot("b14b_library_furniture", 12)
	ws.bench._hotbar.show_section("buildings", false)
	await _shot("b14c_library_buildings", 6)
	ws.bench._hotbar.show_section("bricks", false)
	ws.bench._hotbar.toggle_browser()
	t.act("keys")
	ws.bench._place_keys()
	await _shot("b15_keys")
	t.act("keys")
	await _menu_shots(ws.bench._menu, "b16", ["File", "Edit", "View", "Insert", "Building", "Help"])
	ws.bench._menu.show_open("open")
	await _shot("b17_open_dialog")
	ws.bench._menu._open_dialog.hide()
	ws.bench._menu.show_save_as("my building")
	await _shot("b18_save_dialog")
	ws.bench._menu._save_dialog.hide()
	ws.queue_free()
	for i in 10:
		await process_frame


## Stage 8d (Docs/BuildTools.md section 21): a coloured model stamped into clay -- a red top
## half and a blue bottom half, as asset_workshop_probe's colour round -- with "Colours for
## bricks" open under the actions, then Make bricks. A new asset after, so nothing is left.
func _asset_colours(ws, ui: AssetWorkshopUI) -> void:
	ws.bench._on_menu("new", null)
	for i in 20:
		await process_frame
	ui.set_stage("blockout")
	ws.rail_pick("sculpt")
	# In PLA, so red and blue stay red and blue (the hotbar is on bronze by now).
	var keep_mat: int = ws.bench._mat
	ws.bench._mat = 0
	var lo: Vector3 = ws.sculpt.to_sample(Vector3(500, 4, 500) * 0.35).floor()
	var hi := lo + Vector3(40, 20, 40)
	var mid := (lo.y + hi.y) * 0.5
	var quads := [
		[Vector3(lo.x, hi.y, lo.z), Vector3(lo.x, hi.y, hi.z), Vector3(hi.x, hi.y, hi.z), Vector3(hi.x, hi.y, lo.z), true],
		[Vector3(lo.x, lo.y, lo.z), Vector3(hi.x, lo.y, lo.z), Vector3(hi.x, lo.y, hi.z), Vector3(lo.x, lo.y, hi.z), false]]
	for half in [[mid, hi.y, true], [lo.y, mid, false]]:
		var y0: float = half[0]
		var y1: float = half[1]
		quads.append([Vector3(lo.x, y0, lo.z), Vector3(lo.x, y1, lo.z), Vector3(hi.x, y1, lo.z), Vector3(hi.x, y0, lo.z), half[2]])
		quads.append([Vector3(lo.x, y0, hi.z), Vector3(hi.x, y0, hi.z), Vector3(hi.x, y1, hi.z), Vector3(lo.x, y1, hi.z), half[2]])
		quads.append([Vector3(lo.x, y0, lo.z), Vector3(lo.x, y0, hi.z), Vector3(lo.x, y1, hi.z), Vector3(lo.x, y1, lo.z), half[2]])
		quads.append([Vector3(hi.x, y0, lo.z), Vector3(hi.x, y1, lo.z), Vector3(hi.x, y1, hi.z), Vector3(hi.x, y0, hi.z), half[2]])
	var v := PackedVector3Array()
	var c := PackedColorArray()
	for q in quads:
		for t in [[0, 1, 2], [0, 2, 3]]:
			for j in t:
				v.append(q[j])
				c.append(Color(0.9, 0.1, 0.1) if q[4] else Color(0.1, 0.2, 0.85))
	var idx := PackedInt32Array()
	for i in v.size():
		idx.append(i)
	ws.sculpt.form.begin_edit()
	ws.sculpt.form.stamp_mesh(SdfForm.ADD, v, idx, ws.part_sel + 1, c)
	ws._sculpt_record(ws.sculpt.form.end_edit())
	ui.colours_shown = true
	ws.colour_table_refresh()
	ui._fill_actions()
	await _shot("a8_colours_table", 12)
	ws.sculpt_convert()
	ui._fill_actions()
	await _shot("a8_colours_bricks", 12)
	ui.colours_shown = false
	ws.bench._mat = keep_mat
	ws.bench._on_menu("new", null)
	for i in 20:
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
	for id in ["select", "draw", "smooth", "measure"]:
		ui.pick_tool(id)
		await _shot("a1_blockout_" + id)
	ws.clay_pick("box")
	await _shot("a1_blockout_draw_box")
	ws.clay_pick("brush")
	ui.set_stage("bricks")
	for id in ["place", "select", "paint", "draw", "move", "measure"]:
		ui.pick_tool(id)
		await _shot("a2_bricks_" + id)
	ws.draw_pick("freehand")
	await _shot("a2_bricks_draw_freehand")
	ws.draw_pick("box")
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
	ws.bench._hotbar.show_section("bricks", false)
	await _shot("a5_browser", 30)
	ws.bench._hotbar.toggle_browser()
	ws.bench._keys_on = true
	ws.bench._keys_panel.visible = true
	await _shot("a5_keys_f1")
	ws.bench._keys_on = false
	ws.bench._keys_panel.visible = false
	await _menu_shots(ws.bench._menu, "a6", ["File", "Edit", "View", "Insert", "Gun", "Help"])
	await _asset_colours(ws, ui)
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
