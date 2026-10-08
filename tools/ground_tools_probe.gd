extends SceneTree

## One ground and one set of ground tools, in every scene that has ground
## (Docs/Terrain.md 22.15).
##
##     godot --headless --path . --script res://tools/ground_tools_probe.gd
##
## The combat arena is where everything is tested together, so what the
## heightfield test can do to its ground the arena has to be able to do to its
## own. Two things were the heightfield test's alone and are checked in both:
##
##   * the geometry chamfer near the camera (TerrainTile.bevel_enabled) -- a
##     switch each scene set for itself, and only one did;
##   * the terrain dev menu (F10, terrain_dev_menu.gd) -- every row it offers
##     a scene has to do something on that scene;
##   * the level editor's tools (terrain_editor.gd) -- always in hand in the
##     heightfield test, an edit mode (F11) in the arena, where a brush moves
##     the ground and a building's site does not move.

var _passed := 0
var _failed := 0


func _initialize() -> void:
	_run.call_deferred()


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_passed += 1
	else:
		_failed += 1
	print("  %s %s%s" % ["ok  " if cond else "FAIL", what, ("  " + detail) if detail != "" else ""])


func _frames(n: int) -> void:
	for i in n:
		await process_frame


## Chamfered triangles held by the tiles round the camera, and how many of
## those tiles are showing their chamfered mesh.
func _chamfer(streamer: TerrainStreamer) -> Dictionary:
	var tris := 0
	var shown := 0
	for t in streamer.tiles():
		var tile := t as TerrainTile
		tris += tile.bevel_tri_count
		var near := tile.get_node_or_null(^"SurfaceChamfered") as MeshInstance3D
		if near != null and near.visible:
			shown += 1
	return {"tris": tris, "shown": shown}


## The rows a dev menu built: its controls, by what they say.
func _rows(menu: Node) -> PackedStringArray:
	var out := PackedStringArray()
	for n in menu.find_children("*", "BaseButton", true, false):
		out.append((n as BaseButton).text)
	return out


func _press(menu: Node, text: String) -> bool:
	for n in menu.find_children("*", "BaseButton", true, false):
		var b := n as BaseButton
		if b.text != text:
			continue
		if b is CheckBox:
			b.button_pressed = not b.button_pressed
		else:
			b.pressed.emit()
		return true
	return false


func _run() -> void:
	print("ground tools probe")
	# A probe's scene must never take the mouse (CLAUDE.md, "Testing").
	DebugCamera.hands_off = true
	_ok("the geometry chamfer is on without a scene asking", TerrainTile.bevel_enabled)

	await _arena()
	await _heightfield()

	print("ground tools probe: %d passed, %d failed" % [_passed, _failed])
	quit(1 if _failed > 0 else 0)


func _arena() -> void:
	print(" combat arena")
	var scene: Node3D = load("res://scenes/combat_arena.tscn").instantiate()
	root.add_child(scene)
	await _frames(30)
	var streamer: TerrainStreamer = scene._terrain_streamer
	_ok("the arena stands on terrain", streamer != null)
	if streamer == null:
		scene.queue_free()
		return
	var cam: Camera3D = scene.camera
	streamer.settle(Vector2(cam.global_position.x, cam.global_position.z))
	await _frames(4)
	var c := _chamfer(streamer)
	_ok("its ground near the camera is chamfered", int(c.tris) > 0 and int(c.shown) > 0,
			"%d chamfered triangles held, %d tile(s) showing them" % [c.tris, c.shown])

	scene._toggle_terrain_dev_menu()
	var menu: Node = scene._terrain_dev_menu
	_ok("F10 opens the terrain dev menu", menu != null)
	if menu != null:
		var rows := _rows(menu)
		_ok("no rows for a detail square that follows the camera: the city's does not",
				not rows.has("Freeze LOD streaming"), "%s" % [rows])
		_press(menu, "LOD colour view")
		_ok("LOD colour view tints the ground",
				bool(scene._terrain_mat.get_shader_parameter("lod_debug")))
		_press(menu, "LOD colour view")
		_ok("and takes the tint off again",
				not bool(scene._terrain_mat.get_shader_parameter("lod_debug")))

		var blocks: int = scene._terrain_coarse.block_count()
		_press(menu, "Rebuild far terrain")
		await _frames(2)
		_ok("Rebuild far terrain lays the coarse tier again",
				is_instance_valid(scene._terrain_coarse)
				and scene._terrain_coarse.block_count() == blocks and blocks > 0,
				"%d blocks before, %d after" % [blocks, scene._terrain_coarse.block_count()])

		var tiles: int = streamer.tile_count()
		_press(menu, "Real chamfers near the camera")
		streamer.settle(Vector2(cam.global_position.x, cam.global_position.z))
		await _frames(4)
		var off := _chamfer(streamer)
		_ok("Real chamfers off: every tile rebuilt flat", not TerrainTile.bevel_enabled
				and int(off.tris) == 0 and streamer.tile_count() == tiles,
				"%d chamfered triangles, %d of %d tiles" % [off.tris, streamer.tile_count(), tiles])
		_press(menu, "Real chamfers near the camera")
		streamer.settle(Vector2(cam.global_position.x, cam.global_position.z))
		await _frames(4)
		var on := _chamfer(streamer)
		_ok("and on again: chamfered again", TerrainTile.bevel_enabled and int(on.tris) > 0,
				"%d chamfered triangles" % on.tris)

		scene._toggle_terrain_dev_menu()
		await _frames(2)
		_ok("F10 closes it", scene._terrain_dev_menu == null)
	await _arena_edit(scene, streamer, cam)
	scene.queue_free()
	await _frames(4)


## The arena's edit mode: the level editor's tools on the city's ground.
func _arena_edit(scene: Node3D, streamer: TerrainStreamer, cam: Camera3D) -> void:
	scene._toggle_terrain_edit()
	var ed = scene._terrain_editor
	_ok("F11 puts the editing tools in hand", scene._edit_mode and ed != null
			and ed.is_processing() and ed.is_processing_unhandled_input())
	if ed == null:
		return
	_ok("out of the pawn: the tools are aimed with a free camera",
			not scene._player.is_possessing())

	# A site here is a building standing on its pad.
	ed._set_tool(ed.Tool.SITE)
	_ok("the site tool is not offered", ed._tool != ed.Tool.SITE, ed._status)
	var site_pad := -1
	for i in BrickTerrain.pad_count():
		if ed._is_site_pad(i):
			site_pad = i
			break
	var pads := BrickTerrain.pad_count()
	if site_pad >= 0:
		var was: Dictionary = BrickTerrain.get_pad(site_pad)
		ed._set_tool(ed.Tool.PAD)
		ed._selected = site_pad
		ed._delete_selected()
		ed._nudge_selected(2, 0, 0.0)
		ed._move_selected(int(was["x"]) + 5, int(was["z"]) + 5)
		var now: Dictionary = BrickTerrain.get_pad(site_pad)
		_ok("a building's pad cannot be deleted, resized or moved",
				BrickTerrain.pad_count() == pads and int(now["x"]) == int(was["x"])
				and int(now["z"]) == int(was["z"]) and int(now["radius"]) == int(was["radius"]),
				"%d pads, %d before" % [BrickTerrain.pad_count(), pads])
	else:
		_ok("the city's world has site pads to protect", false, "%d pads, none a site's" % pads)

	# A brush on open ground, well clear of every pad's skirt.
	var stud := BrickWorld.get_stud_metres()
	var plate := BrickWorld.get_plate_metres()
	var spot := Vector2i.ZERO
	var found := false
	for k in 96:
		var a := TAU * k / 96.0
		var c := Vector2i(int(cos(a) * 150.0), int(sin(a) * 150.0))
		var clear := true
		for i in BrickTerrain.pad_count():
			if (BrickTerrain.pad_bounds(i) as Rect2i).grow(24).has_point(c):
				clear = false
				break
		if clear:
			spot = c
			found = true
			break
	_ok("there is open ground in the city's square to try a brush on", found)
	if found:
		var ground := float(BrickTerrain.surface_plate(spot.x, spot.y) + 1) * plate
		cam.global_position = Vector3((spot.x + 0.5) * stud, ground + 14.0, (spot.y + 0.5) * stud)
		cam.rotation = Vector3(-PI * 0.5, 0.0, 0.0)
		ed._set_tool(ed.Tool.RAISE)
		ed._begin_stroke()
		await _frames(40)
		ed._end_stroke()
		streamer.settle(Vector2(cam.global_position.x, cam.global_position.z))
		await _frames(4)
		var raised := float(BrickTerrain.surface_plate(spot.x, spot.y) + 1) * plate
		_ok("the raise brush raises the city's ground", raised > ground + plate * 0.5,
				"%.2f m to %.2f m at %s" % [ground, raised, spot])
		_ok("and the edit is marked unsaved", ed.is_dirty())
		# Put it back: the field is global, and the next scene reads it.
		var back: Rect2i = BrickTerrain.sculpt_undo()
		streamer.refresh(scene._tiles_over(back))
		scene.terrain_changed(back)
		var again := float(BrickTerrain.surface_plate(spot.x, spot.y) + 1) * plate
		_ok("undo puts it back", is_equal_approx(again, ground), "%.2f m" % again)

	scene._toggle_terrain_edit()
	_ok("F11 again puts them away", not scene._edit_mode and not ed.is_processing()
			and not ed.is_processing_unhandled_input() and not ed.visible)
	await _frames(2)


func _heightfield() -> void:
	print(" heightfield test")
	var scene: Node3D = load("res://scenes/heightfield_test.tscn").instantiate()
	root.add_child(scene)
	await _frames(30)
	var streamer: TerrainStreamer = scene._streamer
	var cam: Camera3D = scene._camera
	streamer.settle(Vector2(cam.global_position.x, cam.global_position.z))
	await _frames(4)
	var c := _chamfer(streamer)
	_ok("its ground near the camera is chamfered", int(c.tris) > 0 and int(c.shown) > 0,
			"%d chamfered triangles held, %d tile(s) showing them" % [c.tris, c.shown])

	var ed = scene._editor
	_ok("the editing tools are in hand, sites and all", ed != null and ed.is_processing()
			and ed._edits_sites and ed._world_half == scene.FAR_TILES)

	scene._toggle_dev_menu()
	var menu: Node = scene._dev_menu
	_ok("F10 opens the terrain dev menu", menu != null)
	if menu != null:
		var rows := _rows(menu)
		_ok("with the rows for a detail square that follows the camera",
				rows.has("Freeze LOD streaming"), "%s" % [rows])
		# The row that called a function no scene had (rebuild_detail).
		var slopes: bool = BrickTerrain.get_slope_pieces()
		_press(menu, "Slopes and curves on terrace edges")
		streamer.settle(Vector2(cam.global_position.x, cam.global_position.z))
		await _frames(4)
		_ok("Slopes and curves rebuilds the detail tiles",
				BrickTerrain.get_slope_pieces() != slopes and streamer.tile_count() > 0)
		_press(menu, "Slopes and curves on terrace edges")
		streamer.settle(Vector2(cam.global_position.x, cam.global_position.z))
		_press(menu, "Rebuild far terrain")
		await _frames(2)
		_ok("Rebuild far terrain lays the far tier again", scene._far.block_count() > 0,
				"%d blocks" % scene._far.block_count())
		scene._toggle_dev_menu()
		await _frames(2)
		_ok("F10 closes it", scene._dev_menu == null)
	scene.queue_free()
	await _frames(4)
