extends Node3D

## Terrain and water test scene. Slice 1 of [Docs/Terrain.md](../Docs/Terrain.md)
## §14 (T0–T2b, part of T4/T5) and [Docs/Water.md](../Docs/Water.md) §10 (W0–W3).
##
##     godot --path . scenes/terrain_test.tscn
##     godot --path . scenes/terrain_test.tscn -- --shot
##
## What it is here to answer, in order:
##
##   1. Does packed ground read as LAID BRICK rather than as a baseplate?
##      That is the whole reason the mesher packs instead of greedy-merging,
##      and the piece mix is "mostly 2x4" (TerrainGrid.PARTITIONS).
##   2. Do the painted studs and their faked contact shadow hold up next to
##      the real geometry studs, across the 18 m handover?
##   3. Does brick-stepped water read as water, with the pieces moving rather
##      than being created and destroyed?
##
## Keys: F1 seams · F2 painted studs · F3 stud contact shadows ·
##       F4 geometry studs + scatter · F5 water · Space walk/fly
##       LEFT MOUSE blast the ground · F6 clear all damage

const TILES := 5          ## 5x5 tiles = 160 studs = 56 m square.
const WORLD_SEED := 20260919

var _tiles: Array[TerrainTile] = []
## (tx, tz) -> tile, so a carve can find exactly the ones it dirtied.
var _tile_at := {}
var _debris: Array[RigidBody3D] = []
var _last_carve := ""
var _rebuild_ms := 0.0
var _water: WaterSurface = null
var _camera: DebugCamera = null
var _sun: DirectionalLight3D = null
var _terrain_mat: ShaderMaterial = null
var _label: Label = null

var _shot_mode := false
var _build_ms := 0.0
var _frame_ms := 0.0
var _show_geometry_studs := true


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg == "--shot":
			_shot_mode = true

	BrickTerrain.configure(WORLD_SEED)
	_build_scenery()
	_build_terrain()
	_build_water()
	_update_hud()

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
	env.ambient_light_energy = 0.55
	env.ssao_enabled = false
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	_sun = DirectionalLight3D.new()
	_sun.rotation_degrees = Vector3(-42, -38, 0)
	_sun.light_energy = 1.15
	_sun.shadow_enabled = true
	add_child(_sun)

	_camera = DebugCamera.new()
	_camera.name = "DebugCamera"
	_camera.capture_mouse = not _shot_mode
	_camera.allow_walk = not _shot_mode
	_camera.far = 800.0
	_camera.position = Vector3(-9.0, 9.5, -9.0)
	_camera.rotation = Vector3(-0.42, -2.36, 0.0)
	add_child(_camera)

	var layer := CanvasLayer.new()
	_label = Label.new()
	_label.position = Vector2(14, 12)
	_label.add_theme_color_override("font_color", Color(0.96, 0.97, 0.99))
	_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	_label.add_theme_constant_override("outline_size", 4)
	layer.add_child(_label)
	add_child(layer)


func _build_terrain() -> void:
	_terrain_mat = ShaderMaterial.new()
	_terrain_mat.shader = load("res://shaders/terrain.gdshader")
	_terrain_mat.set_shader_parameter("stud_pitch", BrickWorld.get_stud_metres())
	_terrain_mat.set_shader_parameter("stud_radius", PieceMeshes.STUD_R)
	_terrain_mat.set_shader_parameter("stud_height", PieceMeshes.STUD_H)
	for key in _toggles:
		_terrain_mat.set_shader_parameter(key, _toggles[key])
	_sync_sun()

	var t0 := Time.get_ticks_usec()
	@warning_ignore("integer_division")
	var half := TILES / 2
	for tz in range(-half, half + 1):
		for tx in range(-half, half + 1):
			var tile := TerrainTile.new()
			tile.name = "Tile_%d_%d" % [tx, tz]
			add_child(tile)
			tile.build(tx, tz, _terrain_mat)
			_tiles.append(tile)
			_tile_at[Vector2i(tx, tz)] = tile
	_build_ms = float(Time.get_ticks_usec() - t0) / 1000.0


## The faked contact shadow needs the sun as a world-space direction pointing
## from the surface TO the light. Docs/Terrain.md §7.4.
func _sync_sun() -> void:
	_terrain_mat.set_shader_parameter("sun_dir", -_sun.global_transform.basis.z)


func _build_water() -> void:
	_water = WaterSurface.new()
	_water.name = "Water"
	_water.radius = 20.0
	add_child(_water)
	_water.set_seabed(_build_seabed(), _field_origin(), _field_extent())


## One Rf texel a stud cell, holding the top of the ground in metres.
##
## This is the whole of §5's mechanism at test-scene scale. A real world would
## stream it per tile alongside the voxels; here the field is 160 studs square,
## so one 160x160 image covers it and costs 100 KB.
func _build_seabed() -> ImageTexture:
	var tile := BrickTerrain.get_tile_studs()
	var brick := BrickTerrain.get_brick_metres()
	var n := TILES * tile
	@warning_ignore("integer_division")
	var half := n / 2
	var img := Image.create_empty(n, n, false, Image.FORMAT_RF)
	for iz in n:
		for ix in n:
			var h := BrickTerrain.height_at(ix - half, iz - half)
			img.set_pixel(ix, iz, Color(float(h + 1) * brick, 0.0, 0.0))
	return ImageTexture.create_from_image(img)


func _field_origin() -> Vector2:
	@warning_ignore("integer_division")
	var half := TILES * BrickTerrain.get_tile_studs() / 2
	var stud := BrickWorld.get_stud_metres()
	return Vector2(-half * stud, -half * stud)


func _field_extent() -> Vector2:
	var n := TILES * BrickTerrain.get_tile_studs()
	var stud := BrickWorld.get_stud_metres()
	return Vector2(n * stud, n * stud)


func _process(delta: float) -> void:
	_frame_ms = lerpf(_frame_ms, delta * 1000.0, 0.1)
	if _water != null and _water.visible:
		_water.follow(Vector2(_camera.global_position.x, _camera.global_position.z), delta)
	_update_hud()


const BLAST_RADIUS := 1.9
const DEBRIS_CAP := 160
const DEBRIS_LIFE := 7.0


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed \
			and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		_blast()
		return
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	match (event as InputEventKey).keycode:
		KEY_F1:
			_toggle("seams_enabled")
		KEY_F2:
			_toggle("studs_enabled")
		KEY_F3:
			_toggle("stud_shadows_enabled")
		KEY_F4:
			_show_geometry_studs = not _show_geometry_studs
			for tile in _tiles:
				for child in tile.get_children():
					if child is MultiMeshInstance3D:
						(child as MultiMeshInstance3D).visible = _show_geometry_studs
		KEY_F5:
			_water.visible = not _water.visible
		KEY_F6:
			_clear_damage()


## Toggle state is held HERE, not read back from the material.
##
## `get_shader_parameter` returns null for a uniform that has never been
## written -- the shader's own default is not visible through it -- and
## `bool(null)` is not a conversion GDScript has, so F1 to F3 raised
## "Nonexistent 'bool' constructor" and took the input handler down with them.
## Keeping the state on this side means the default is stated once, in
## `_toggles`, and the material is only ever written to.
var _toggles := {
	"seams_enabled": true,
	"studs_enabled": true,
	"stud_shadows_enabled": true,
}


## Shoot the ground. The whole loop: ray, carve the truth, rebuild whatever
## the carve says is now stale, throw the rim as rigid bodies.
##
## `carve` does none of that itself — it edits the field and reports what
## changed, exactly the way `BrickWorld::apply_hit` does. Presentation is this
## function's problem and nothing below it knows there was a camera involved.
func _blast() -> void:
	var from := _camera.global_position
	var to := from - _camera.global_transform.basis.z * 300.0
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.collision_mask = Layers.WORLD
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		_last_carve = "missed"
		return

	# A shade INTO the surface, or a glancing hit removes nothing: the contact
	# point sits exactly on the face and half the sphere is already air.
	var point: Vector3 = hit["position"] - (hit["normal"] as Vector3) * 0.2
	var t0 := Time.get_ticks_usec()
	var res: Dictionary = BrickTerrain.carve(point, BLAST_RADIUS)
	var carve_ms := float(Time.get_ticks_usec() - t0) / 1000.0

	t0 = Time.get_ticks_usec()
	var tiles: PackedInt32Array = res["tiles"]
	var rebuilt := 0
	for i in range(0, tiles.size(), 2):
		var key := Vector2i(tiles[i], tiles[i + 1])
		if _tile_at.has(key):
			(_tile_at[key] as TerrainTile).rebuild(_terrain_mat)
			rebuilt += 1
	_rebuild_ms = float(Time.get_ticks_usec() - t0) / 1000.0

	_spawn_debris(res["debris"], point)
	_last_carve = "%d cells, %d tiles, carve %.1f ms, rebuild %.0f ms" % [
		res["removed"], rebuilt, carve_ms, _rebuild_ms]


## Nine floats a piece: position, size, colour. Capped and swept, because a
## blast that removes two thousand plates must not become two thousand bodies
## — the same debris budget M4 settled on for buildings.
func _spawn_debris(buf: PackedFloat32Array, origin: Vector3) -> void:
	@warning_ignore("integer_division")
	var n := buf.size() / 9
	for i in n:
		if _debris.size() >= DEBRIS_CAP:
			break
		var o := i * 9
		var pos := Vector3(buf[o], buf[o + 1], buf[o + 2])
		var size := Vector3(buf[o + 3], buf[o + 4], buf[o + 5])
		var col := Color(buf[o + 6], buf[o + 7], buf[o + 8])

		var body := RigidBody3D.new()
		body.collision_layer = Layers.RUBBLE
		body.collision_mask = Layers.RUBBLE_MASK
		body.position = pos
		var shape := BoxShape3D.new()
		shape.size = size
		var cs := CollisionShape3D.new()
		cs.shape = shape
		body.add_child(cs)
		var mi := MeshInstance3D.new()
		mi.mesh = PieceMeshes.chamfered_box(size)
		var mat := StandardMaterial3D.new()
		mat.albedo_color = col
		mat.roughness = 0.9
		mi.material_override = mat
		body.add_child(mi)
		add_child(body)
		# Outward from the blast, so it reads as thrown rather than dropped.
		var away := (pos - origin).normalized() + Vector3.UP * 0.5
		body.linear_velocity = away * randf_range(3.0, 7.0)
		body.angular_velocity = Vector3(randf_range(-6, 6), randf_range(-6, 6),
			randf_range(-6, 6))
		_debris.append(body)
		var timer := get_tree().create_timer(DEBRIS_LIFE)
		timer.timeout.connect(func() -> void:
			_debris.erase(body)
			if is_instance_valid(body):
				body.queue_free())


func _clear_damage() -> void:
	BrickTerrain.clear_terrain_edits()
	for tile in _tiles:
		tile.rebuild(_terrain_mat)
	for body in _debris:
		if is_instance_valid(body):
			body.queue_free()
	_debris.clear()
	_last_carve = "damage cleared"


func _toggle(param: String) -> void:
	var on: bool = not bool(_toggles.get(param, true))
	_toggles[param] = on
	_terrain_mat.set_shader_parameter(param, on)


func _update_hud() -> void:
	if _label == null:
		return
	var pieces := 0
	var tris := 0
	var studs := 0
	var scatter := 0
	for tile in _tiles:
		pieces += tile.piece_count
		tris += tile.tri_count
		studs += tile.stud_count
		scatter += tile.scatter_count
	var tile := BrickTerrain.get_tile_studs()
	var cells := TILES * TILES * tile * tile
	_label.text = "\n".join([
		"terrain  %d tiles  %d cells  %d pieces  %.1f studs/piece" % [
			_tiles.size(), cells, pieces,
			float(cells) / maxf(float(pieces), 1.0)],
		"         %d tris   %d studs   %d scatter   built %.1f ms" % [
			tris, studs, scatter, _build_ms],
		"water    %d instances  terrace %.1f studs  t=%.1fs" % [
			_water.instance_count(), BrickWave.terrace_studs(), _water.time()],
		"frame    %.1f ms   edits %d   debris %d" % [
			_frame_ms, BrickTerrain.get_edit_count(), _debris.size()],
		"blast    %s" % (_last_carve if _last_carve != "" else "left click the ground"),
		"F1 seams  F2 painted studs  F3 contact shadows  F4 geometry studs  F5 water  F6 repair",
	])


# ---------------------------------------------------------------------------

func _run_shots() -> void:
	await _frames(4)
	# Standing on it: the packed pieces and the geometry studs.
	await _shot("terrain_close", Vector3(3.0, 1.8, 3.0), Vector3(-0.22, -2.30, 0.0))
	# The 18 m handover: geometry studs give way to painted ones.
	await _shot("terrain_handover", Vector3(-16.0, 6.0, -16.0), Vector3(-0.34, -2.36, 0.0))
	# The whole field, for terraces, ramps and the shoreline.
	await _shot("terrain_wide", Vector3(-40.0, 26.0, -40.0), Vector3(-0.50, -2.36, 0.0))
	# Water, low over the surface.
	await _shot("water_close", Vector3(-6.0, 2.6, -6.0), Vector3(-0.14, -2.36, 0.0))
	# Destruction: three craters punched into a hillside, then a look at what
	# they left. This is the capture that shows the ground is volumetric —
	# a crater has WALLS, and a heightfield could not draw them.
	await _shot_blast()
	# The packing itself, with nothing standing on it. This is the capture the
	# whole mesher exists for: is the ground LAID, out of 2x4s and their
	# neighbours, or is it a moulded baseplate with a grid drawn on it?
	await _shot_packing()
	await _shot_debris_ab()
	print("[terrain] pieces/tris/studs written to shots/")
	get_tree().quit()


func _shot_blast() -> void:
	var stud := BrickWorld.get_stud_metres()
	var plate := BrickWorld.get_plate_metres()
	# Where the ground WAS, so the camera does not end up inside the hill it
	# is about to look into.
	var ground := float(BrickTerrain.surface_plate(-6, -6)) * plate
	for spot in [Vector2i(-6, -6), Vector2i(-2, -7), Vector2i(-9, -2)]:
		var yp := BrickTerrain.surface_plate(spot.x, spot.y)
		var p := Vector3((spot.x + 0.5) * stud, (yp - 2) * plate, (spot.y + 0.5) * stud)
		var res: Dictionary = BrickTerrain.carve(p, 2.4)
		var tiles: PackedInt32Array = res["tiles"]
		for i in range(0, tiles.size(), 2):
			var key := Vector2i(tiles[i], tiles[i + 1])
			if _tile_at.has(key):
				(_tile_at[key] as TerrainTile).rebuild(_terrain_mat)
	var focus := Vector3(-2.1, ground - 0.6, -2.1)
	_camera.position = Vector3(-2.1, ground + 4.2, -2.1) + Vector3(4.5, 0.0, 4.5)
	_camera.look_at(focus, Vector3.UP)
	await _frames(6)
	get_viewport().get_texture().get_image().save_png("res://shots/terrain_blast.png")
	print("[terrain] shot written: terrain_blast.png  (%d edits)"
		% BrickTerrain.get_edit_count())

	# Now dig a shaft well past the section floor and stand in it. This is the
	# capture that catches see-through ground: from the bottom of a deep hole
	# every wall and the floor have to be solid, and any face the mesher
	# wrongly culled shows as a window into the sky.
	var sx := 6
	var sz := 6
	var start := BrickTerrain.surface_plate(sx, sz)
	for step in 12:
		var y := start - step * 7
		var res2: Dictionary = BrickTerrain.carve(
			Vector3((sx + 0.5) * stud, (float(y) + 0.5) * plate, (sz + 0.5) * stud), 2.6)
		var t2: PackedInt32Array = res2["tiles"]
		for i in range(0, t2.size(), 2):
			var k2 := Vector2i(t2[i], t2[i + 1])
			if _tile_at.has(k2):
				(_tile_at[k2] as TerrainTile).rebuild(_terrain_mat)
	var floor_y := float(BrickTerrain.surface_plate(sx, sz)) * plate
	_camera.position = Vector3((sx + 0.5) * stud, floor_y + 1.6, (sz + 0.5) * stud)
	_camera.rotation = Vector3(0.18, -0.9, 0.0)
	await _frames(6)
	get_viewport().get_texture().get_image().save_png("res://shots/terrain_shaft.png")
	print("[terrain] shot written: terrain_shaft.png  (%.1f m down, %d edits)"
		% [float(start) * plate - floor_y, BrickTerrain.get_edit_count()])

	# Looking UP from the bottom of the shaft. Downward-facing faces — cave
	# roofs, overhang undersides, the lip of the hole — are 2,958 of the
	# 4,894 triangles the winding bug made invisible, and this is the only
	# angle that shows them. A wall-facing capture cannot: side faces were
	# always wound correctly, which is why the bug survived four rounds of
	# looking at screenshots.
	_camera.rotation = Vector3(0.95, -0.9, 0.0)
	await _frames(6)
	get_viewport().get_texture().get_image().save_png("res://shots/terrain_ceiling.png")
	print("[terrain] shot written: terrain_ceiling.png")


## Chamfered brick against plain box, side by side, at the distance debris is
## actually seen from. This is the comparison that decides whether the bevel
## is worth 44 triangles — the same shape of test the `--chamfer` gate runs
## for the shaded version, so the two answers are comparable.
func _shot_debris_ab() -> void:
	BrickTerrain.clear_terrain_edits()
	for tile in _tiles:
		tile.rebuild(_terrain_mat)
	_water.visible = false

	var stud := BrickWorld.get_stud_metres()
	var brick := BrickTerrain.get_brick_metres()
	var size := Vector3(stud * 2.0, brick, stud * 4.0)
	var ground := float(BrickTerrain.surface_plate(0, 0)) * BrickWorld.get_plate_metres()
	var holder := Node3D.new()
	add_child(holder)

	for i in 6:
		var mi := MeshInstance3D.new()
		var chamfered := i % 2 == 0
		mi.mesh = PieceMeshes.chamfered_box(size) if chamfered else _plain_box(size)
		var mat := StandardMaterial3D.new()
		mat.albedo_color = BrickWorld.get_filament_colour(4 if chamfered else 8)
		mat.roughness = 0.85
		mi.material_override = mat
		# Tumbled, so the comparison is on silhouettes and not on one flat face.
		mi.position = Vector3(-1.5 + float(i) * 0.6, ground + 1.35, 0.0)
		mi.rotation = Vector3(0.45 + float(i) * 0.09, 0.7 + float(i) * 0.31, 0.2)
		holder.add_child(mi)

	# 2.4 m: where a brick that has just come off a wall actually passes
	# you. At that range the 13 mm bevel is 7.4 px, which is the whole
	# question.
	_camera.position = Vector3(0.0, ground + 1.7, 2.4)
	_camera.look_at(Vector3(0.0, ground + 1.35, 0.0), Vector3.UP)
	await _frames(6)
	get_viewport().get_texture().get_image().save_png("res://shots/debris_chamfer_ab.png")
	print("[terrain] shot written: debris_chamfer_ab.png  (red = chamfered, blue = plain box)")
	holder.queue_free()


func _plain_box(size: Vector3) -> BoxMesh:
	var b := BoxMesh.new()
	b.size = size
	return b


func _shot_packing() -> void:
	_terrain_mat.set_shader_parameter("studs_enabled", false)
	_terrain_mat.set_shader_parameter("stud_shadows_enabled", false)
	_water.visible = false
	for tile in _tiles:
		for child in tile.get_children():
			if child is MultiMeshInstance3D:
				(child as MultiMeshInstance3D).visible = false
	_camera.position = Vector3(0.0, 13.0, 0.0)
	_camera.rotation = Vector3(-PI / 2.0, 0.0, 0.0)
	await _frames(6)
	get_viewport().get_texture().get_image().save_png("res://shots/terrain_packing.png")
	print("[terrain] shot written: terrain_packing.png")


## Camera Y is a CLEARANCE above whatever is under it, not an absolute. The
## field's relief is a generator parameter and a fixed height put the first
## capture inside a hill and under the sea at once.
func _shot(shot_name: String, pos: Vector3, rot: Vector3) -> void:
	var stud := BrickWorld.get_stud_metres()
	var brick := BrickTerrain.get_brick_metres()
	var gx := int(floor(pos.x / stud))
	var gz := int(floor(pos.z / stud))
	var ground := float(BrickTerrain.height_at(gx, gz) + 1) * brick
	var sea: float = BrickWave.get_sea_level()
	pos.y = maxf(pos.y + maxf(ground, sea), pos.y)
	_camera.position = pos
	_camera.rotation = rot
	await _frames(6)
	var img := get_viewport().get_texture().get_image()
	img.save_png("res://shots/%s.png" % shot_name)
	print("[terrain] shot written: %s.png" % shot_name)


func _frames(n: int) -> void:
	for i in n:
		await RenderingServer.frame_post_draw
