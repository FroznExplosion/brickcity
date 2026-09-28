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
const DRY_AMBIENT := 0.55
## Preloaded, not reached for by class name: a new `class_name` is not in the
## global class cache until the editor rescans, and a headless run reads that
## cache off disk. Same reason as UnderwaterFx.
const World := preload("res://scripts/terrain_world.gd")
## Preloaded rather than reached for by class name: a brand new `class_name`
## is not in the global class cache until the editor has rescanned, and a
## headless run reads that cache off disk.
const UnderwaterFx := preload("res://scripts/underwater.gd")
const WORLD_SEED := 20260919

var _tiles: Array[TerrainTile] = []
## (tx, tz) -> tile, so a carve can find exactly the ones it dirtied.
var _tile_at := {}
var _debris: Array[RigidBody3D] = []
var _last_carve := ""
var _rebuild_ms := 0.0
var _water: WaterSurface = null
var _water_far: WaterSurface = null
var _env: Environment = null
var _under := UnderwaterFx.new()
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

	# This bench is where the geometry chamfer is measured, so it is on here
	# and nowhere else (TerrainTile.bevel_enabled).
	TerrainTile.bevel_enabled = true
	BrickTerrain.configure(WORLD_SEED)
	# The generator's floor sits barely under the default 1.1 m sea, so the
	# map had puddles and no sea at all: the deepest water in the field
	# measured 0.82 m, the shore taper cut every wave to a third, and a
	# system built for tall waves had nowhere to put one. 1.9 m floods the
	# low ground to ~1.5 m and leaves the hills dry.
	# Sampled over THIS scene's field, not a wider area: it builds a fixed
	# 5x5 tiles and never streams, so a sea derived from ground it does not
	# contain leaves it dry.
	@warning_ignore("integer_division")
	var field_half: int = maxi(TILES / 2, 1)
	BrickWave.set_sea_level(World.sea_level_for(field_half, 0.30))
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
	env.ambient_light_energy = DRY_AMBIENT
	env.ssao_enabled = false
	_env = env
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
	var coords: Array[Vector2i] = []
	for tz in range(-half, half + 1):
		for tx in range(-half, half + 1):
			coords.append(Vector2i(tx, tz))

	# BAKED IN PARALLEL, assembled on the main thread.
	#
	# This scene keeps its fixed 5x5 field rather than streaming: it is the
	# DESTRUCTION bench, `_tile_at` has to hold every tile for a carve to
	# find what it dirtied, and 56 m is the whole point of the fixture. What
	# it does not need is one core building tiles in series — `build_tile`
	# only reads the field, so a worker can run it (§19.2).
	var baked: Array[Dictionary] = []
	baked.resize(coords.size())
	var task := WorkerThreadPool.add_group_task(
		func(i: int) -> void: baked[i] = TerrainTile.bake(coords[i].x, coords[i].y),
		coords.size(), -1, true, "terrain bake")
	WorkerThreadPool.wait_for_group_task_completion(task)

	for i in coords.size():
		var tile := TerrainTile.new()
		tile.name = "Tile_%d_%d" % [coords[i].x, coords[i].y]
		add_child(tile)
		tile.build(coords[i].x, coords[i].y, _terrain_mat, baked[i])
		_tiles.append(tile)
		_tile_at[coords[i]] = tile
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
	# Tier 1: the same wave at four studs a piece, from tier 0's edge out to
	# 80 m. Without it the sea is a 20 m disc with a cliff round it.
	_water_far = WaterSurface.new()
	_water_far.name = "WaterFar"
	_water_far.radius = 80.0
	_water_far.pitch_studs = 4
	_water_far.inner_radius = 19.0
	_water_far.studs = false
	add_child(_water_far)
	var seabed := _build_seabed()
	_water.set_seabed(seabed, _field_origin(), _field_extent())
	_water_far.set_seabed(seabed, _field_origin(), _field_extent())
	# Swimming. The camera is a debug tool and does not know the water node
	# exists; it asks a Callable where the surface is.
	_camera.water_probe = func(p: Vector3) -> float: return _water.surface_at(p)


## One Rf texel a stud cell, holding the top of the ground in metres.
##
## This is the whole of §5's mechanism at test-scene scale. A real world would
## stream it per tile alongside the voxels; here the field is 160 studs square,
## so one 160x160 image covers it and costs 100 KB.
func _build_seabed() -> ImageTexture:
	var tile := BrickTerrain.get_tile_studs()
	var n := TILES * tile
	@warning_ignore("integer_division")
	var half := n / 2
	# Ground (R) and distance to the shore (G), from the same C++ field the
	# CPU wave reads (BrickWave.build_shore_field): the shore band is phased
	# on that distance (Water.md 9.6).
	var field: PackedFloat32Array = BrickWave.build_shore_field(half, 1)
	var img := Image.create_from_data(n, n, false, Image.FORMAT_RGF, field.to_byte_array())
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
		_water.follow(Vector2(_camera.global_position.x, _camera.global_position.z),
				delta, _camera.global_position.y)
		_water_far.follow(Vector2(_camera.global_position.x, _camera.global_position.z),
				delta, _camera.global_position.y)
		_under.set_submerged(_env, _water.submerged_at(_camera.global_position),
				DRY_AMBIENT)
	elif _water != null:
		# Hiding the water has to take the underwater look with it. It did
		# not, and every capture taken after a submerged one came out fogged
		# green with the sea switched off.
		_under.set_submerged(_env, false, DRY_AMBIENT)
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
			_water_far.visible = _water.visible
		KEY_V:
			_water.set_brick_steps(not _water.brick_steps)
			_water_far.set_brick_steps(_water.brick_steps)
			print("[terrain] water: %s" % ("brick steps + stop motion"
					if _water.brick_steps else "smooth bob"))
		KEY_F6:
			_clear_damage()
		KEY_P:
			var on: bool = not bool(_toggles.get("print_lines_enabled", true))
			_toggles["print_lines_enabled"] = on
			_terrain_mat.set_shader_parameter("print_lines_enabled", on)
			for mat in [TerrainTile.instance_material(), TerrainTile.stud_material(),
					TerrainTile.tuft_material()]:
				mat.set_shader_parameter("print_lines_enabled", on)
			_water.set_print_lines(on)
			_water_far.set_print_lines(on)
			print("[terrain] print lines: %s" % ("ON" if on else "OFF"))
		KEY_G:
			TerrainTile.bevel_enabled = not TerrainTile.bevel_enabled
			var t0 := Time.get_ticks_usec()
			for tile in _tiles:
				tile.rebuild(_terrain_mat)
			var flat := 0
			var bev := 0
			for tile in _tiles:
				flat += tile.tri_count
				bev += tile.bevel_tri_count
			print("[terrain] near chamfer tier %s — %d flat + %d chamfered tris, %.0f ms"
					% ["ON" if TerrainTile.bevel_enabled else "OFF", flat, bev,
					float(Time.get_ticks_usec() - t0) / 1000.0])
		KEY_F7:
			_painted = not _painted
			for key in _toggles:
				_toggles[key] = _painted
				_terrain_mat.set_shader_parameter(key, _painted)
			print("[terrain] painted detail: %s (geometry only when OFF)"
					% ("ON" if _painted else "OFF"))


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
	"chamfer_enabled": true,
	"print_lines_enabled": true,
}

## Everything the shader PAINTS, off at once, so what is left is the geometry
## and nothing else. The question "is that bevel real or drawn?" cannot be
## answered by looking at a surface carrying four shaded effects.
var _painted := true


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
		# A brick that has just come off the ground is the same printed
		# plastic the ground is, layer lines and all -- and in OBJECT space,
		# so the lines tumble with it. That is the reason the print pass is
		# procedural rather than a texture (spec §2).
		mi.material_override = _debris_material(col)
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
		"authored %d pads  %d paints  %d sites" % [
			BrickTerrain.pad_count(), BrickTerrain.paint_count(),
			World.sites.size()],
		"water    %d instances  %s  sea %.1f m  %s" % [
			_water.instance_count() + _water_far.instance_count(),
			("stepped, terrace %.1f studs" % BrickWave.terrace_studs())
				if _water.brick_steps else "smooth",
			BrickWave.get_sea_level(),
			"SWIMMING" if _camera.is_swimming()
				else ("under" if _under.is_submerged() else "dry")],
		"frame    %.1f ms   edits %d   debris %d" % [
			_frame_ms, BrickTerrain.get_edit_count(), _debris.size()],
		"blast    %s" % (_last_carve if _last_carve != "" else "left click the ground"),
		"F1 seams  F2 studs  F3 shadows  F4 stud geometry  F5 water  F6 repair  F7 geometry only  V wave steps  P print  G real chamfer",
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
	await _shot_water()
	# Destruction: three craters punched into a hillside, then a look at what
	# they left. This is the capture that shows the ground is volumetric —
	# a crater has WALLS, and a heightfield could not draw them.
	await _shot_blast()
	# The packing itself, with nothing standing on it. This is the capture the
	# whole mesher exists for: is the ground LAID, out of 2x4s and their
	# neighbours, or is it a moulded baseplate with a grid drawn on it?
	await _shot_packing()
	await _shot_debris_ab()
	await _shot_geometry_only()
	await _measure_chamfer()
	await _shot_ramp()
	await _shot_geo_chamfer()
	await _shot_corner()
	await _shot_brick_join()
	print("[terrain] pieces/tris/studs written to shots/")
	get_tree().quit()


## Water, actually OVER water. `water_close` stands near the shore and mostly
## sees ground, which is no use for judging a wave: so find the deepest column
## in the field, sit a metre above the surface there, and then put the camera
## under it.
##
## The second capture is the whole reason tall bricks are allowed at all. A
## tall column seen from below is a forest of brick sides filling the view;
## submerged, the column collapses to one brick and what is left is the
## underside of a sheet. Water.md 3.5.
func _shot_water() -> void:
	var stud := BrickWorld.get_stud_metres()
	var plate := BrickWorld.get_plate_metres()
	var sea: float = BrickWave.get_sea_level()
	var half := TILES * BrickTerrain.get_tile_studs() / 2
	var best := Vector2i(0, 0)
	var deepest := 1 << 30
	# Inside the field by a margin: the deepest cell is usually ON the
	# boundary, and a capture there is half void.
	var edge := half - 24
	for gz in range(-edge, edge, 3):
		for gx in range(-edge, edge, 3):
			var yp := BrickTerrain.surface_plate(gx, gz)
			if yp < deepest:
				deepest = yp
				best = Vector2i(gx, gz)
	var seabed := float(deepest) * plate
	if seabed >= sea:
		print("[terrain] no water in the field (seabed %.1f m, sea %.1f m); skipping"
				% [seabed, sea])
		return
	var here := Vector3((best.x + 0.5) * stud, 0.0, (best.y + 0.5) * stud)
	# Look back at the middle of the field, so the far shore is in frame and
	# the taper has something to run into.
	var yaw := atan2(here.x, here.z)
	print("[terrain] water probe: cell %s  seabed %.2f m  depth %.2f m"
			% [best, float(deepest) * plate, sea - float(deepest) * plate])

	# Above the CREST, not above the still level: the pieces bob smoothly now
	# and a crest stands a couple of metres over the sea, so a fixed offset
	# from `sea_level` put the camera under water.
	var crest := _water.surface_at(here) + 0.9
	_camera.position = Vector3(here.x, crest, here.z)
	_camera.rotation = Vector3(-0.10, yaw, 0.0)
	await _frames(8)
	get_viewport().get_texture().get_image().save_png("res://shots/water_waves.png")
	print("[terrain] shot written: water_waves.png")

	# Between the seabed and the surface, not a fixed drop: a fixed one put
	# the camera inside the sand in water under a metre deep.
	var bed := float(deepest) * plate
	_camera.position = Vector3(here.x, maxf(bed + 0.45, sea - 1.2), here.z)
	# Looking UP at the surface, which is the view the underside has to hold
	# together in -- edge-on is where a thick sheet showed its sides.
	_camera.rotation = Vector3(0.55, yaw, 0.0)
	await _frames(8)
	get_viewport().get_texture().get_image().save_png("res://shots/water_under.png")
	print("[terrain] shot written: water_under.png  submerged=%s"
			% _water.submerged_at(_camera.global_position))

	# Straight down, where the wave reads as COLOUR rather than as steps --
	# which is the claim the whole surface rests on (Water §3.6).
	_camera.position = Vector3(here.x, sea + 16.0, here.z)
	_camera.rotation = Vector3(-PI / 2.0, 0.0, 0.0)
	await _frames(8)
	get_viewport().get_texture().get_image().save_png("res://shots/water_bands.png")
	print("[terrain] shot written: water_bands.png")

	# Mid angle, smooth then stepped, same camera: the A/B for "do the bricks
	# bob or do they climb a staircase".
	_camera.position = Vector3(here.x, _water.surface_at(here) + 4.0, here.z)
	_camera.rotation = Vector3(-0.45, yaw, 0.0)
	await _frames(8)
	get_viewport().get_texture().get_image().save_png("res://shots/water_mid.png")
	_water.set_brick_steps(true)
	_water_far.set_brick_steps(true)
	await _frames(8)
	get_viewport().get_texture().get_image().save_png("res://shots/water_mid_stepped.png")
	_water.set_brick_steps(false)
	_water_far.set_brick_steps(false)
	print("[terrain] shots written: water_mid.png, water_mid_stepped.png")


## One printed-plastic material per debris colour. The mesh carries no
## vertex colours, so the shader's `tint` supplies it.
var _debris_mats := {}

func _debris_material(col: Color) -> ShaderMaterial:
	if _debris_mats.has(col):
		return _debris_mats[col]
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/printed.gdshader")
	mat.set_shader_parameter("tint", col)
	_debris_mats[col] = mat
	return mat


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
## The ground up close with every painted effect OFF, so what is on screen is
## triangles and light and nothing else. Paired with the default capture this
## is the only way to tell which part of the look is geometry and which is the
## shader drawing lines on a flat surface.
## Does the shaded chamfer change any pixels, and by how much?
##
## "I cannot see it" is not a measurement, and the eye is a poor judge of a
## 13 mm facet. This renders the same frame with the bevel on and off and
## counts what moved — the same gate the city scene already runs, which is
## how we know brick.gdshader's version works.
## A ramp, close and from the low side — the angle that showed the wall the
## wedge was supposed to replace, the overlapping faces beside it, and the
## stray square behind it.
## Real chamfer geometry, on and off, with the triangle cost of each.
##
## The shaded bevel cannot give a SILHOUETTE — a brick outlined in light is
## still a box against the sky — so this is the only version that changes the
## outline of a piece. What it costs is the whole question, and the answer is
## printed rather than argued.
## A convex terrace CORNER, close and low. Three chamfered faces meet there
## and each one's strip stops a bevel short of the other two, so a missing
## corner triangle shows as a pinwheel of light and dark wedges — you are
## seeing the backs of the surrounding facets through the hole. It is the one
## place the artefact appears and no other capture pointed at it.
## Adjacent bricks on flat ground, from just above the surface. This is the
## view the gaps and the messy corners were reported from, and no capture
## aimed at it — the wide shots average the artefact away and the corner shot
## looks at a terrace, not at two pieces meeting on the flat.
func _shot_brick_join() -> void:
	var stud := BrickWorld.get_stud_metres()
	var plate := BrickWorld.get_plate_metres()
	# A cell with three flat neighbours, so several pieces meet nearby.
	var best := Vector2i(999, 999)
	for z in range(-14, 14):
		for x in range(-14, 14):
			if not BrickTerrain.is_plate(x, z):
				continue
			if not (BrickTerrain.is_plate(x + 1, z) and BrickTerrain.is_plate(x, z + 1)
					and BrickTerrain.is_plate(x + 1, z + 1)):
				continue
			best = Vector2i(x, z)
			break
		if best.x != 999:
			break
	if best.x == 999:
		print("[terrain] no flat join found")
		return

	var top := float(BrickTerrain.surface_plate(best.x, best.y) + 1) * plate
	var focus := Vector3((best.x + 1.0) * stud, top, (best.y + 1.0) * stud)
	TerrainTile.bevel_enabled = true
	for tile in _tiles:
		tile.rebuild(_terrain_mat)
	for key in _toggles:
		_terrain_mat.set_shader_parameter(key, false)
	_camera.position = focus + Vector3(0.62, 0.30, 0.62)
	_camera.look_at(focus, Vector3.UP)
	await _frames(6)
	get_viewport().get_texture().get_image().save_png("res://shots/brick_join.png")
	print("[terrain] shot written: brick_join.png  (join at %d,%d)" % [best.x, best.y])
	for key in _toggles:
		_terrain_mat.set_shader_parameter(key, _toggles[key])


func _shot_corner() -> void:
	var stud := BrickWorld.get_stud_metres()
	var plate := BrickWorld.get_plate_metres()
	var best := Vector2i(999, 999)
	var best_d := 1e9
	for z in range(-20, 20):
		for x in range(-20, 20):
			var h := BrickTerrain.height_at(x, z)
			# Two perpendicular neighbours lower: a convex corner.
			var lo_x: bool = BrickTerrain.height_at(x + 1, z) < h
			var lo_z: bool = BrickTerrain.height_at(x, z + 1) < h
			if not (lo_x and lo_z):
				continue
			var d := float(x * x + z * z)
			if d < best_d:
				best_d = d
				best = Vector2i(x, z)
	if best.x == 999:
		print("[terrain] no convex corner found")
		return

	var top := float(BrickTerrain.surface_plate(best.x, best.y) + 1) * plate
	var focus := Vector3((best.x + 1.0) * stud, top - 0.05, (best.y + 1.0) * stud)
	for key in _toggles:
		_terrain_mat.set_shader_parameter(key, false)
	_camera.position = focus + Vector3(0.55, 0.30, 0.55)
	_camera.look_at(focus, Vector3.UP)
	# BOTH, from the identical camera. Anything present in the OFF frame is
	# not the chamfer, whatever it looks like.
	for on in [false, true]:
		TerrainTile.bevel_enabled = on
		for tile in _tiles:
			tile.rebuild(_terrain_mat)
		await _frames(6)
		get_viewport().get_texture().get_image().save_png(
			"res://shots/terrain_corner_%s.png" % ("on" if on else "off"))
	print("[terrain] shots written: terrain_corner_on/off.png  (corner at %d,%d)"
			% [best.x, best.y])
	for key in _toggles:
		_terrain_mat.set_shader_parameter(key, _toggles[key])


func _shot_geo_chamfer() -> void:
	var plate := BrickWorld.get_plate_metres()
	var ground := float(BrickTerrain.surface_plate(2, 2)) * plate
	_camera.position = Vector3(0.95, ground + 0.42, 0.95)
	_camera.look_at(Vector3(-0.35, ground + 0.02, -0.35), Vector3.UP)
	# The shaded bevel off, so only the geometry differs between the frames.
	_terrain_mat.set_shader_parameter("chamfer_enabled", false)

	var was := TerrainTile.bevel_enabled
	for on in [false, true]:
		TerrainTile.bevel_enabled = on
		var t0 := Time.get_ticks_usec()
		for tile in _tiles:
			tile.rebuild(_terrain_mat)
		var ms := float(Time.get_ticks_usec() - t0) / 1000.0
		var flat := 0
		var bev := 0
		for tile in _tiles:
			flat += tile.tri_count
			bev += tile.bevel_tri_count
		await _frames(6)
		get_viewport().get_texture().get_image().save_png(
			"res://shots/geo_chamfer_%s.png" % ("on" if on else "off"))
		# `bev` is held for the whole field but only tiles inside BEVEL_RANGE
		# ever draw it, so the resident cost and the drawn cost differ a lot.
		print("[geo-chamfer] %s: %d flat + %d chamfered tris held, build %.0f ms"
				% ["ON " if on else "OFF", flat, bev, ms])

	TerrainTile.bevel_enabled = was
	for tile in _tiles:
		tile.rebuild(_terrain_mat)
	_terrain_mat.set_shader_parameter("chamfer_enabled", _toggles["chamfer_enabled"])


func _shot_ramp() -> void:
	var stud := BrickWorld.get_stud_metres()
	var plate := BrickWorld.get_plate_metres()
	var best := Vector2i(999, 999)
	var best_d := 1e9
	for z in range(-24, 24):
		for x in range(-24, 24):
			if BrickTerrain.ramp_dir(x, z) < 0:
				continue
			var d := float(x * x + z * z)
			if d < best_d:
				best_d = d
				best = Vector2i(x, z)
	if best.x == 999:
		print("[terrain] no ramp found to photograph")
		return

	var r := BrickTerrain.ramp_dir(best.x, best.y)
	var top := float(BrickTerrain.surface_plate(best.x, best.y) + 1) * plate
	var focus := Vector3((best.x + 0.5) * stud, top - 0.2, (best.y + 0.5) * stud)
	# Stand on the LOW side, which is the direction the wedge faces.
	var dirs: Array[Vector3] = [Vector3(-1, 0, 0), Vector3(1, 0, 0),
			Vector3(0, 0, -1), Vector3(0, 0, 1)]
	var away: Vector3 = dirs[r]
	_camera.position = focus + away * 1.5 + Vector3(0.45, 0.62, 0.45)
	_camera.look_at(focus, Vector3.UP)
	await _frames(6)
	get_viewport().get_texture().get_image().save_png("res://shots/terrain_ramp.png")
	print("[terrain] shot written: terrain_ramp.png  (ramp at %d,%d facing %d)"
			% [best.x, best.y, r])


func _measure_chamfer() -> void:
	var plate := BrickWorld.get_plate_metres()
	var ground := float(BrickTerrain.surface_plate(2, 2)) * plate
	_camera.position = Vector3(1.1, ground + 0.5, 1.1)
	_camera.look_at(Vector3(-0.3, ground + 0.1, -0.3), Vector3.UP)

	# Only the chamfer differs between the two frames.
	for key in _toggles:
		_terrain_mat.set_shader_parameter(key, key == "chamfer_enabled")

	var off := await _grab_chamfer(false, "terrain_chamfer_off")
	var on := await _grab_chamfer(true, "terrain_chamfer_on")

	var moved := 0
	var total := 0
	var worst := 0.0
	for y in range(0, off.get_height(), 3):
		for x in range(0, off.get_width(), 3):
			total += 1
			var d: float = (off.get_pixel(x, y) - on.get_pixel(x, y)).r
			var a: float = absf(d) + absf((off.get_pixel(x, y) - on.get_pixel(x, y)).g)
			worst = maxf(worst, a)
			if a > 0.012:
				moved += 1
	var pct := 100.0 * float(moved) / maxf(float(total), 1.0)
	print("[chamfer] terrain: %.1f%% of sampled pixels changed, worst delta %.3f" % [pct, worst])
	if pct < 1.0:
		print("[chamfer] FAIL — the bevel is doing nothing on terrain bricks")
	else:
		print("[chamfer] ok — the bevel is visibly shading brick edges")

	for key in _toggles:
		_terrain_mat.set_shader_parameter(key, _toggles[key])


func _grab_chamfer(on: bool, shot_name: String) -> Image:
	_terrain_mat.set_shader_parameter("chamfer_enabled", on)
	await _frames(5)
	var img := get_viewport().get_texture().get_image()
	img.save_png("res://shots/%s.png" % shot_name)
	return img


func _shot_geometry_only() -> void:
	var plate := BrickWorld.get_plate_metres()
	var ground := float(BrickTerrain.surface_plate(2, 2)) * plate
	_camera.position = Vector3(1.4, ground + 0.62, 1.4)
	_camera.look_at(Vector3(-0.4, ground + 0.12, -0.4), Vector3.UP)

	for key in _toggles:
		_terrain_mat.set_shader_parameter(key, false)
	await _frames(6)
	get_viewport().get_texture().get_image().save_png("res://shots/geometry_only.png")
	print("[terrain] shot written: geometry_only.png")

	for key in _toggles:
		_terrain_mat.set_shader_parameter(key, _toggles[key])
	await _frames(6)
	get_viewport().get_texture().get_image().save_png("res://shots/geometry_painted.png")
	print("[terrain] shot written: geometry_painted.png")


func _shot_debris_ab() -> void:
	BrickTerrain.clear_terrain_edits()
	for tile in _tiles:
		tile.rebuild(_terrain_mat)
	_water.visible = false
	_water_far.visible = false

	var stud := BrickWorld.get_stud_metres()
	var brick := BrickTerrain.get_brick_metres()
	var size := Vector3(stud * 2.0, brick, stud * 4.0)
	# Above the SEA as well as above the ground: at sea 1.9 m the middle of
	# the field is under water, and the A/B is about silhouettes.
	var ground: float = maxf(
			float(BrickTerrain.surface_plate(0, 0)) * BrickWorld.get_plate_metres(),
			BrickWave.get_sea_level())
	var holder := Node3D.new()
	add_child(holder)

	for i in 6:
		var mi := MeshInstance3D.new()
		var chamfered := i % 2 == 0
		# if/else, not a ternary: the branches are ArrayMesh and BoxMesh, and
		# Godot warns on a ternary over two unrelated classes whatever the
		# variable is declared as.
		if chamfered:
			mi.mesh = PieceMeshes.chamfered_box(size)
		else:
			mi.mesh = _plain_box(size)
		mi.material_override = _debris_material(
				BrickWorld.get_filament_colour(4 if chamfered else 8))
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
	_water_far.visible = false
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
