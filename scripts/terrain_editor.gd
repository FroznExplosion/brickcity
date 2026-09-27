extends Node3D

## Terrain LEVEL EDITOR. [Docs/Terrain.md](../Docs/Terrain.md) §20.
##
##     godot --path . scenes/terrain_editor.tscn
##     godot --path . scenes/terrain_editor.tscn -- --shot
##
## Editing terrain is an authoring job, not a gameplay one. Nothing here is
## reachable from the game: the game loads a world file and never writes one.
##
## What it edits is the FIELD, through pads (§19.12) — not a mesh, not a
## heightmap. That is the whole reason this is short: a pad goes into the
## generator, and the detailed tier, the coarse tier, the collider, the stud
## test, the seabed texture and the buoyancy solver all agree about it
## without being told. An editor that pushed vertices around would have to
## tell every one of them, forever.
##
## Three tools, because a level has three kinds of terrain edit in it:
##
##   1 PAD     flatten ground to a height — where a building stands
##   2 PAINT   say what the ground is made of, whatever the noise thinks
##   3 SITE    a building: a pad, plus how many storeys stand on it
##
## Keys:
##   1 / 2 / 3    pick the tool
##   LEFT CLICK   place under the cursor, or select what is already there
##   DELETE       remove the selection
##   [ / ]        radius        , / .   skirt
##   - / =        height (pad, site) or material (paint)
##   PAGE UP/DN   storeys, on a site
##   CTRL+S       save the world       CTRL+O   reload it
##   SPACE SPACE  walk/fly

const World := preload("res://scripts/terrain_world.gd")
## `-- --world=<name>` opens a different level.
var _world_path := "res://worlds/heightfield.json"

enum Tool { PAD, PAINT, SITE }
## The terrain materials an author can paint with, in the generator's order.
const MATERIALS: Array[String] = ["air", "grass", "dirt", "sand", "stone",
		"dark stone", "road"]
const WORLD_SEED := 20260921
const DRY_AMBIENT := 0.6
const NEAR_TILES := 4
const FAR_TILES := 50

var _streamer: TerrainStreamer = null
var _mat: ShaderMaterial = null
var _camera: DebugCamera = null
var _sun: DirectionalLight3D = null
var _label: Label = null
var _markers: Node3D = null

var _tool: Tool = Tool.PAD
var _selected := -1
var _paint_material := 3        ## sand, a visible default
var _drowned := 0.30
var _dirty := false
var _shot_mode := false
var _status := "loaded"


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg == "--shot":
			_shot_mode = true

	BrickTerrain.set_flat_mode(true)
	BrickTerrain.set_plate_steps(true)
	BrickTerrain.set_smooth_terrain(false)
	BrickTerrain.configure(WORLD_SEED)

	# The world file first, then the generator's own sites if there is none.
	# A level that has never been edited is a seed and nothing else.
	_world_path = World.world_path()
	var loaded := World.load_world(_world_path)
	if loaded.is_empty():
		World.stamp_sites()
		_status = "no world file; seeded from TerrainWorld.SITES"
	else:
		_drowned = float(loaded.get("drowned", 0.30))
		_status = "loaded %s" % _world_path

	_build_scenery()
	BrickTerrain.set_sun_direction(_sun.global_transform.basis.z)
	BrickWave.set_sea_level(World.sea_level_for(maxi(NEAR_TILES, 8), _drowned))
	_build_terrain()
	_refresh_markers()
	if _shot_mode:
		_run_shots()


func _build_scenery() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.36, 0.54, 0.78)
	sky_mat.sky_horizon_color = Color(0.74, 0.80, 0.84)
	sky_mat.ground_bottom_color = Color(0.28, 0.30, 0.28)
	sky_mat.ground_horizon_color = Color(0.74, 0.80, 0.84)
	sky.sky_material = sky_mat
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = DRY_AMBIENT
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	_sun = DirectionalLight3D.new()
	_sun.rotation_degrees = Vector3(-30, -36, 0)
	_sun.light_energy = 1.15
	_sun.shadow_enabled = true
	add_child(_sun)

	_camera = DebugCamera.new()
	_camera.name = "DebugCamera"
	_camera.capture_mouse = not _shot_mode
	_camera.allow_walk = not _shot_mode
	_camera.far = 1200.0
	_camera.position = Vector3(-14.0, 26.0, -14.0)
	_camera.rotation = Vector3(-0.55, -2.36, 0.0)
	add_child(_camera)

	_markers = Node3D.new()
	_markers.name = "PadMarkers"
	add_child(_markers)

	var layer := CanvasLayer.new()
	_label = Label.new()
	_label.position = Vector2(14, 12)
	_label.add_theme_color_override("font_color", Color(0.96, 0.97, 0.99))
	_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	_label.add_theme_constant_override("outline_size", 4)
	layer.add_child(_label)
	add_child(layer)


func _build_terrain() -> void:
	_mat = ShaderMaterial.new()
	_mat.shader = load("res://shaders/terrain.gdshader")
	_mat.set_shader_parameter("stud_pitch", BrickWorld.get_stud_metres())
	_mat.set_shader_parameter("stud_radius", PieceMeshes.STUD_R)
	_mat.set_shader_parameter("stud_height", PieceMeshes.STUD_H)
	_mat.set_shader_parameter("sun_dir", -_sun.global_transform.basis.z)

	_streamer = TerrainStreamer.new()
	_streamer.name = "Streamer"
	_streamer.near_radius = NEAR_TILES
	_streamer.keep_radius = NEAR_TILES + 2
	_streamer.world_half = FAR_TILES
	add_child(_streamer)
	_streamer.setup(_mat)
	_streamer.settle(Vector2(_camera.position.x, _camera.position.z))


func _process(_delta: float) -> void:
	if _streamer != null:
		_streamer.follow(Vector2(_camera.global_position.x, _camera.global_position.z))
	_update_hud()


# ---------------------------------------------------------------------------
# Editing

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed \
			and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		_click()
		return
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	var key := (event as InputEventKey).keycode
	if Input.is_key_pressed(KEY_CTRL):
		match key:
			KEY_S:
				var err := World.save_world(_world_path, WORLD_SEED, _drowned)
				_status = "saved %s" % _world_path if err == OK else "SAVE FAILED"
				_dirty = err != OK
				print("[editor] %s" % _status)
			KEY_O:
				var again := World.load_world(_world_path)
				if not again.is_empty():
					_drowned = float(again.get("drowned", 0.30))
				_selected = -1
				_dirty = false
				_status = "reloaded %s" % _world_path
				_rebuild_all()
		return
	match key:
		KEY_1:
			_set_tool(Tool.PAD)
		KEY_2:
			_set_tool(Tool.PAINT)
		KEY_3:
			_set_tool(Tool.SITE)
		KEY_DELETE:
			_delete_selected()
		KEY_BRACKETLEFT:
			_nudge_selected(-2, 0, 0.0)
		KEY_BRACKETRIGHT:
			_nudge_selected(2, 0, 0.0)
		KEY_COMMA:
			_nudge_selected(0, -1, 0.0)
		KEY_PERIOD:
			_nudge_selected(0, 1, 0.0)
		KEY_MINUS:
			_step_value(-1)
		KEY_EQUAL:
			_step_value(1)
		KEY_PAGEUP:
			_step_storeys(1)
		KEY_PAGEDOWN:
			_step_storeys(-1)


func _set_tool(t: Tool) -> void:
	_tool = t
	_selected = -1
	_status = "tool: %s" % ["pad", "paint", "site"][int(t)]
	_refresh_markers()


## `-` and `=` mean different things per tool, because the thing they change
## is what that tool is FOR: a pad is a height, a paint is a material.
func _step_value(dir: int) -> void:
	if _tool == Tool.PAINT:
		if _selected >= 0:
			var q := BrickTerrain.get_paint(_selected)
			var m: int = wrapi(int(q["material"]) + dir, 1, MATERIALS.size())
			var before: Rect2i = BrickTerrain.paint_bounds(_selected)
			BrickTerrain.set_paint(_selected, int(q["x"]), int(q["z"]),
				int(q["radius"]), int(q["skirt"]), m)
			_dirty = true
			_status = "material: %s" % MATERIALS[m]
			_rebuild_around(before)
		else:
			_paint_material = wrapi(_paint_material + dir, 1, MATERIALS.size())
			_status = "brush: %s" % MATERIALS[_paint_material]
		return
	_nudge_selected(0, 0, float(dir) * BrickTerrain.get_brick_metres())


func _step_storeys(dir: int) -> void:
	if _tool != Tool.SITE or _selected < 0 or _selected >= World.sites.size():
		return
	var site: Dictionary = World.sites[_selected]
	site["storeys"] = maxi(1, int(site["storeys"]) + dir)
	_dirty = true
	_status = "storeys: %d" % int(site["storeys"])
	_refresh_markers()


## Where the camera is pointing, on the ground. The collider is the terrain's
## own, so what gets hit is exactly what is drawn.
func _aim() -> Dictionary:
	var from := _camera.global_position
	var to := from - _camera.global_transform.basis.z * 400.0
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.collision_mask = Layers.WORLD
	return get_world_3d().direct_space_state.intersect_ray(q)


func _click() -> void:
	var hit := _aim()
	if hit.is_empty():
		_status = "nothing under the cursor"
		return
	var stud := BrickWorld.get_stud_metres()
	var p: Vector3 = hit["position"]
	var gx := int(floor(p.x / stud))
	var gz := int(floor(p.z / stud))

	var brick := BrickTerrain.get_brick_metres()
	var level := roundf(p.y / brick) * brick
	var tile := BrickTerrain.get_tile_studs()

	# A click on something this tool owns SELECTS it; a click on open ground
	# makes a new one.
	match _tool:
		Tool.PAD:
			var existing := BrickTerrain.pad_at(gx, gz)
			if existing >= 0:
				_selected = existing
				_status = "selected pad %d" % existing
				_refresh_markers()
				return
			BrickTerrain.add_pad(gx, gz, 10, 5, level)
			_selected = BrickTerrain.pad_count() - 1
			_status = "placed pad %d" % _selected
			_dirty = true
			_rebuild_around(BrickTerrain.pad_bounds(_selected))
		Tool.PAINT:
			var hit_paint := BrickTerrain.paint_at(gx, gz)
			if hit_paint >= 0:
				_selected = hit_paint
				_status = "selected paint %d (%s)" % [hit_paint,
					MATERIALS[int(BrickTerrain.get_paint(hit_paint)["material"])]]
				_refresh_markers()
				return
			BrickTerrain.add_paint(gx, gz, 12, 8, _paint_material)
			_selected = BrickTerrain.paint_count() - 1
			_status = "painted %s" % MATERIALS[_paint_material]
			_dirty = true
			_rebuild_around(BrickTerrain.paint_bounds(_selected))
		Tool.SITE:
			# A site is addressed by TILE, because a building stands on one.
			var t := Vector2i(floori(float(gx) / float(tile)),
					floori(float(gz) / float(tile)))
			for i in World.sites.size():
				if World.sites[i]["tile"] == t:
					_selected = i
					_status = "selected site %d" % i
					_refresh_markers()
					return
			World.sites.append({"tile": t, "radius": 12, "storeys": 5})
			_selected = World.sites.size() - 1
			_status = "placed site %d" % _selected
			_dirty = true
			_restamp_sites()


func _nudge_selected(d_radius: int, d_skirt: int, d_height: float) -> void:
	if _selected < 0:
		return
	if _tool == Tool.PAINT:
		if _selected >= BrickTerrain.paint_count():
			return
		var q := BrickTerrain.get_paint(_selected)
		var was: Rect2i = BrickTerrain.paint_bounds(_selected)
		BrickTerrain.set_paint(_selected, int(q["x"]), int(q["z"]),
			maxi(1, int(q["radius"]) + d_radius), maxi(0, int(q["skirt"]) + d_skirt),
			int(q["material"]))
		_dirty = true
		_rebuild_around(was.merge(BrickTerrain.paint_bounds(_selected)))
		return
	if _tool == Tool.SITE:
		if _selected >= World.sites.size():
			return
		var site: Dictionary = World.sites[_selected]
		site["radius"] = maxi(2, int(site["radius"]) + d_radius)
		_dirty = true
		_restamp_sites()
		return
	if _selected >= BrickTerrain.pad_count():
		return
	var pad := BrickTerrain.get_pad(_selected)
	# The OLD bounds have to be rebuilt too, or shrinking a pad leaves the
	# ground it used to flatten exactly as it was.
	var before: Rect2i = BrickTerrain.pad_bounds(_selected)
	BrickTerrain.set_pad(_selected, int(pad["x"]), int(pad["z"]),
		maxi(1, int(pad["radius"]) + d_radius),
		maxi(0, int(pad["skirt"]) + d_skirt),
		float(pad["height"]) + d_height)
	_dirty = true
	_rebuild_around(before.merge(BrickTerrain.pad_bounds(_selected)))


func _delete_selected() -> void:
	if _selected < 0:
		return
	if _tool == Tool.PAINT:
		if _selected >= BrickTerrain.paint_count():
			return
		var pb: Rect2i = BrickTerrain.paint_bounds(_selected)
		BrickTerrain.remove_paint(_selected)
		_selected = -1
		_dirty = true
		_status = "deleted paint"
		_rebuild_around(pb)
		return
	if _tool == Tool.SITE:
		if _selected >= World.sites.size():
			return
		World.sites.remove_at(_selected)
		_selected = -1
		_dirty = true
		_status = "deleted site"
		_restamp_sites()
		return
	if _selected >= BrickTerrain.pad_count():
		return
	var bounds: Rect2i = BrickTerrain.pad_bounds(_selected)
	BrickTerrain.remove_pad(_selected)
	_selected = -1
	_dirty = true
	_status = "deleted"
	_rebuild_around(bounds)


## Everything the edit touched, rebuilt; everything else left alone.
##
## An edit changes the FIELD, so every tile over the pad is stale — but only
## those. A pad is tens of studs across and the world is thousands, so a
## targeted rebuild is the difference between an editor that responds and one
## that stops for a second every time you press a key.
func _rebuild_around(bounds: Rect2i) -> void:
	var tile := BrickTerrain.get_tile_studs()
	var lo := Vector2i(floori(float(bounds.position.x) / float(tile)),
			floori(float(bounds.position.y) / float(tile)))
	var hi := Vector2i(floori(float(bounds.end.x) / float(tile)),
			floori(float(bounds.end.y) / float(tile)))
	_streamer.invalidate(Rect2i(lo, hi - lo + Vector2i.ONE))
	_streamer.settle(Vector2(_camera.global_position.x, _camera.global_position.z))
	_refresh_markers()


## Sites own pads, so moving or resizing one re-cuts every site pad.
##
## `stamp_sites` clears the pad list, which would throw away hand-placed pads
## too — so they are taken out first and put back. Sites and loose pads live
## in the same list because the FIELD only has one kind of flat spot; the
## editor is what knows the difference.
func _restamp_sites() -> void:
	var loose: Array[Dictionary] = []
	for i in BrickTerrain.pad_count():
		if not _is_site_pad(i):
			loose.append(BrickTerrain.get_pad(i))
	var keep := World.sites.duplicate(true)
	World.stamp_sites()
	World.sites = keep
	BrickTerrain.clear_pads()
	World.stamp_sites_only(keep)
	for pad in loose:
		BrickTerrain.add_pad(int(pad["x"]), int(pad["z"]), int(pad["radius"]),
			int(pad["skirt"]), float(pad["height"]))
	_rebuild_all()


## Is this pad one a site cut, rather than one an author placed by hand?
func _is_site_pad(index: int) -> bool:
	var pad := BrickTerrain.get_pad(index)
	var tile := BrickTerrain.get_tile_studs()
	for site in World.sites:
		var c: Vector2i = site["tile"]
		@warning_ignore("integer_division")
		if int(pad["x"]) == c.x * tile + tile / 2 \
				and int(pad["z"]) == c.y * tile + tile / 2:
			return true
	return false


func _rebuild_all() -> void:
	_streamer.invalidate(Rect2i(-FAR_TILES, -FAR_TILES,
		FAR_TILES * 2 + 1, FAR_TILES * 2 + 1))
	_streamer.settle(Vector2(_camera.global_position.x, _camera.global_position.z))
	_refresh_markers()


## A flat disc over each pad, so an author can see what they are editing —
## the ground itself only shows the RESULT of a pad, which is a flat spot
## that looks like any other flat spot.
func _refresh_markers() -> void:
	for child in _markers.get_children():
		_markers.remove_child(child)
		child.queue_free()
	var stud := BrickWorld.get_stud_metres()
	var plate := BrickWorld.get_plate_metres()
	var tile := BrickTerrain.get_tile_studs()
	for i in BrickTerrain.pad_count():
		var pad := BrickTerrain.get_pad(i)
		_marker(Vector3((int(pad["x"]) + 0.5) * stud, float(pad["height"]) + plate,
				(int(pad["z"]) + 0.5) * stud),
			float(int(pad["radius"]) * 2 + 1) * stud,
			Color(0.25, 0.7, 1.0, 0.18),
			_tool == Tool.PAD and i == _selected)
	for i in BrickTerrain.paint_count():
		var q := BrickTerrain.get_paint(i)
		var gx := int(q["x"])
		var gz := int(q["z"])
		_marker(Vector3((gx + 0.5) * stud,
				float(BrickTerrain.surface_plate(gx, gz) + 1) * plate + plate,
				(gz + 0.5) * stud),
			float(int(q["radius"]) * 2 + 1) * stud,
			Color(0.9, 0.45, 0.15, 0.22),
			_tool == Tool.PAINT and i == _selected)
	for i in World.sites.size():
		var site: Dictionary = World.sites[i]
		var c: Vector2i = site["tile"]
		@warning_ignore("integer_division")
		var gx2: int = c.x * tile + tile / 2
		@warning_ignore("integer_division")
		var gz2: int = c.y * tile + tile / 2
		_marker(Vector3((gx2 + 0.5) * stud,
				float(BrickTerrain.surface_plate(gx2, gz2) + 1) * plate + plate * 2.0,
				(gz2 + 0.5) * stud),
			float(int(site["radius"]) * 2 + 1) * stud,
			Color(0.35, 0.95, 0.45, 0.22),
			_tool == Tool.SITE and i == _selected)


## A flat disc over an edit, so an author can see what they are editing —
## the ground only shows the RESULT, which looks like ordinary ground.
func _marker(at: Vector3, width: float, tint: Color, selected: bool) -> void:
	var plate := BrickWorld.get_plate_metres()
	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(width, plate * 0.5, width)
	mi.mesh = box
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(1.0, 0.85, 0.2, 0.35) if selected else tint
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.position = at
	_markers.add_child(mi)


func _update_hud() -> void:
	if _label == null:
		return
	var lines: Array[String] = [
		"TERRAIN EDITOR   %s   seed %d%s" % [
			_world_path.get_file().get_basename(), WORLD_SEED,
			"  *UNSAVED*" if _dirty else ""],
		"world        %d pads   %d paints   %d sites" % [
			BrickTerrain.pad_count(), BrickTerrain.paint_count(),
			World.sites.size()],
		"tool         %s%s" % [["PAD", "PAINT", "SITE"][int(_tool)],
			"   brush: %s" % MATERIALS[_paint_material] if _tool == Tool.PAINT else ""],
		"status       %s" % _status,
	]
	if _tool == Tool.PAD and _selected >= 0 and _selected < BrickTerrain.pad_count():
		var pad := BrickTerrain.get_pad(_selected)
		lines.append("pad %d        at %d,%d   radius %d   skirt %d   height %.2f m" % [
			_selected, int(pad["x"]), int(pad["z"]), int(pad["radius"]),
			int(pad["skirt"]), float(pad["height"])])
	elif _tool == Tool.PAINT and _selected >= 0 and _selected < BrickTerrain.paint_count():
		var q := BrickTerrain.get_paint(_selected)
		lines.append("paint %d      at %d,%d   radius %d   skirt %d   %s" % [
			_selected, int(q["x"]), int(q["z"]), int(q["radius"]),
			int(q["skirt"]), MATERIALS[int(q["material"])]])
	elif _tool == Tool.SITE and _selected >= 0 and _selected < World.sites.size():
		var site: Dictionary = World.sites[_selected]
		lines.append("site %d       tile %s   radius %d   %d storeys" % [
			_selected, site["tile"], int(site["radius"]), int(site["storeys"])])
	else:
		lines.append("             nothing selected")
	lines.append("             %s" % _streamer.report())
	lines.append("1 pad  2 paint  3 site   LEFT CLICK place/select   DEL remove")
	lines.append("[ ] radius   , . skirt   - = height/material   PGUP/PGDN storeys")
	lines.append("CTRL+S save   CTRL+O reload   SPACE SPACE walk")
	_label.text = "\n".join(lines)


# ---------------------------------------------------------------------------

func _run_shots() -> void:
	await _frames(4)
	_camera.position = Vector3(-14.0, 26.0, -14.0)
	await _frames(4)
	get_viewport().get_texture().get_image().save_png("res://shots/editor_world.png")
	print("[editor] shot written: editor_world.png  (%d pads)" % BrickTerrain.pad_count())

	# Place, resize and delete, the way an author would, and photograph the
	# ground each time: an edit that does not change the ground is the
	# failure this capture exists to catch.
	var stud := BrickWorld.get_stud_metres()
	var gx := 40
	var gz := 40
	var brick := BrickTerrain.get_brick_metres()
	var level := roundf(float(BrickTerrain.surface_plate(gx, gz) + 1)
			* BrickWorld.get_plate_metres() / brick) * brick + brick * 2.0
	BrickTerrain.add_pad(gx, gz, 12, 6, level)
	_selected = BrickTerrain.pad_count() - 1
	_rebuild_around(BrickTerrain.pad_bounds(_selected))
	_camera.position = Vector3((gx + 0.5) * stud + 26.0, level + 18.0,
			(gz + 0.5) * stud + 26.0)
	_camera.look_at(Vector3((gx + 0.5) * stud, level, (gz + 0.5) * stud), Vector3.UP)
	await _frames(6)
	get_viewport().get_texture().get_image().save_png("res://shots/editor_placed.png")
	print("[editor] shot written: editor_placed.png")

	_nudge_selected(10, 4, 0.0)
	await _frames(6)
	get_viewport().get_texture().get_image().save_png("res://shots/editor_resized.png")
	print("[editor] shot written: editor_resized.png")

	_delete_selected()
	await _frames(6)
	get_viewport().get_texture().get_image().save_png("res://shots/editor_deleted.png")
	print("[editor] shot written: editor_deleted.png  (%d pads)"
			% BrickTerrain.pad_count())

	# PAINT: say the ground is sand and watch it become sand.
	_set_tool(Tool.PAINT)
	BrickTerrain.add_paint(gx, gz, 16, 10, 3)
	_selected = BrickTerrain.paint_count() - 1
	_rebuild_around(BrickTerrain.paint_bounds(_selected))
	await _frames(6)
	get_viewport().get_texture().get_image().save_png("res://shots/editor_painted.png")
	print("[editor] shot written: editor_painted.png  (%d paints, %s)" % [
		BrickTerrain.paint_count(),
		MATERIALS[int(BrickTerrain.get_paint(_selected)["material"])]])

	# SITE: a building's pad, cut by the site rather than by hand.
	_set_tool(Tool.SITE)
	var tile := BrickTerrain.get_tile_studs()
	World.sites.append({"tile": Vector2i(floori(float(gx) / float(tile)) + 1,
			floori(float(gz) / float(tile))), "radius": 14, "storeys": 6})
	_selected = World.sites.size() - 1
	_restamp_sites()
	await _frames(6)
	get_viewport().get_texture().get_image().save_png("res://shots/editor_site.png")
	print("[editor] shot written: editor_site.png  (%d sites, %d pads)" % [
		World.sites.size(), BrickTerrain.pad_count()])

	# And the world file, round trip, which is the only thing that outlives
	# the session.
	var path := "user://editor_shot_world.json"
	var err := World.save_world(path, WORLD_SEED, _drowned)
	var pads_before := BrickTerrain.pad_count()
	var paints_before := BrickTerrain.paint_count()
	var sites_before := World.sites.size()
	World.load_world(path)
	print("[editor] world round trip: %s  %d/%d pads  %d/%d paints  %d/%d sites" % [
		"ok" if err == OK else "FAILED",
		BrickTerrain.pad_count(), pads_before,
		BrickTerrain.paint_count(), paints_before,
		World.sites.size(), sites_before])
	get_tree().quit()


func _frames(n: int) -> void:
	for i in n:
		await RenderingServer.frame_post_draw
