extends Node3D

## THE MINE WORLD: the terrain test as a flat, endless, Minecraft-like world.
## Docs/MineWorld.md.
##
##     godot --path . scenes/terrain_test.tscn
##     godot --path . scenes/terrain_test.tscn -- --gate     (scripted pass, pictures)
##     godot --path . scenes/terrain_test.tscn -- --bench    (the old destruction bench)
##
## Nothing here is a copy of another scene's machinery:
##
##   ground     the biome generator (BrickTerrain.set_generator(1),
##              terrain_biomes.cpp); water OFF -- basins are dry sand
##   near       TerrainStreamer, full detail round the player
##   far        TerrainCoarse, BLOCKY at every ring (coarse_smooth_step 0),
##              laid out round the player's tile and rebuilt there as they go
##   trees      TerrainTrees, streamed, by biome (Trees.scatter's callables)
##   player     FpsRig: planet.tscn's pawn on foot and PlanetWalker flying
##   light      LightRig, with the sun turning: day and night
##
## Keys: F fly/walk · F9 world generation menu · F3 readout · T skip an hour
##       left mouse (on foot): shoot -- the ground breaks where it is hit

const Presets := preload("res://scripts/terrain/worldgen_presets.gd")
const Menu := preload("res://scripts/terrain/worldgen_menu.gd")

## A whole day, seconds (Minecraft's is 20 minutes).
const DAY_SECONDS := 1200.0
const MINE_RADIUS := 0.65
## Far rings are rebuilt round the player once they are this many tiles from
## the tile the current rings were laid out round.
const REANCHOR_TILES := 16
const DRY_AMBIENT := 0.6

var settings: Dictionary = {}
var spawn_xz := Vector2.ZERO

var _mat: ShaderMaterial = null
var _brick_mat: ShaderMaterial = null
var _streamer: TerrainStreamer = null
var _far: TerrainCoarse = null
var _far_next: TerrainCoarse = null
var _trees: TerrainTrees = null
var _rig: LightRig = null

var walker: PlanetWalker
var cam: PlayerCamera
var pawn: Pawn
var player: PlayerController
var gun: GunController
var view: PlayerView
var kit: PlayerKit
var on_foot := true

var _time := 0.30           ## of a day: 0 midnight, 0.25 sunrise, 0.5 noon
var _hud: Label = null
var _hud_layer: CanvasLayer = null
var _show_readout := true
var _hud_in := 0.0
var _frame_ms := 0.0
var _menu: Control = null
var _gen_ms := 0.0
var _reanchors := 0
var _last_reanchor_ms := 0.0
var _gate := false
var _biome_names: PackedStringArray
var _tree_chance: Array[float] = []
var _tree_variants: Array = []


func _ready() -> void:
	_gate = "--gate" in OS.get_cmdline_user_args()
	if _gate:
		PlayerCamera.hands_off = true
		var tw := get_node_or_null(^"/root/TestWindow")
		if tw != null:
			tw.use_default_settings()
	# Flat ground: a planet left behind by another scene must not pull here.
	Gravity.planet = null
	# Blocky brick ground, the way the Minecraft look wants it.
	BrickTerrain.set_flat_mode(false)
	BrickTerrain.set_smooth_terrain(false)
	BrickTerrain.set_plate_steps(false)
	BrickTerrain.set_slope_pieces(false)
	BrickTerrain.set_coarse_smooth_step(0)
	# The sun moves, so nothing bakes it into the ground (set_sun_direction
	# zero); the detail tiles cast into the shadow map instead.
	BrickTerrain.set_sun_direction(Vector3.ZERO)

	_rig = LightRig.new()
	_rig.build_day(self, Vector3(-40, -30, 0), LightRig.SUN_ENERGY, DRY_AMBIENT)
	_rig.sun.directional_shadow_max_distance = 120.0
	_mat = TerrainTile.ground_material(-_rig.sun.global_transform.basis.z)
	_brick_mat = ShaderMaterial.new()
	_brick_mat.shader = load("res://shaders/brick.gdshader")
	WeatherFx.register(_brick_mat)
	_build_hud()

	var start := Presets.load_settings(ContentPacks.resolve("worldgen/default.json"))
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--seed="):
			start["seed"] = int(arg.split("=")[1])
		elif arg.begins_with("--preset="):
			for p in Presets.list():
				if str(p.name).to_lower() == arg.split("=")[1].to_lower():
					start = Presets.load_settings(p.path)
	generate(start)
	if _gate:
		_run_gate()


func _exit_tree() -> void:
	# Every other scene expects the classic field.
	_teardown()
	BrickTerrain.set_generator(0)
	BrickTerrain.reset_gen_params()
	BrickTerrain.set_coarse_smooth_step(8)


# ---------------------------------------------------------------------------
# Generating

## A new world from `s` (Presets.complete's shape): everything that was baked
## from the old field goes first, so no worker is reading the params while
## they change.
func generate(s: Dictionary) -> void:
	var t0 := Time.get_ticks_usec()
	settings = s.duplicate(true)
	_teardown()
	_reanchors = 0
	_last_reanchor_ms = 0.0
	BrickTerrain.clear_terrain_edits()
	BrickTerrain.configure(int(settings.seed))
	BrickTerrain.set_generator(1)
	BrickTerrain.reset_gen_params()
	BrickTerrain.set_gen_params(settings.gen)
	var sea := float(settings.gen.get("sea_m", 20.0))
	# No water is drawn; the sea line is still where trees stop.
	BrickWave.set_sea_level(sea)
	_biome_names = BrickTerrain.biome_names()
	_cache_tree_rules()

	var sp = settings.get("spawn", null)
	var want := Vector2i.ZERO
	if sp is Array and (sp as Array).size() == 2:
		want = Vector2i(int(sp[0]), int(sp[1]))
	var cell := _find_spawn(want)
	var stud := BrickWorld.get_stud_metres()
	spawn_xz = Vector2((cell.x + 0.5) * stud, (cell.y + 0.5) * stud)
	var feet := Vector3(spawn_xz.x, _ground_m(cell.x, cell.y) + 0.05, spawn_xz.y)

	var near := clampi(int(settings.get("detail_tiles", 4)), 2, 8)
	_streamer = TerrainStreamer.new()
	_streamer.name = "Streamer"
	_streamer.near_radius = near
	_streamer.keep_radius = near + 2
	_streamer.world_half = 1 << 20
	_streamer.shadow_radius = 2
	add_child(_streamer)
	_streamer.setup(_mat)
	_streamer.settle(spawn_xz)

	_far = _new_far(_tile_of(feet))
	_far.build(_far_tiles(), _mat, Rect2i(), _streamer.align)
	_far.cover(_streamer)

	_place_player(feet)
	_trees = TerrainTrees.new()
	_trees.name = "Trees"
	add_child(_trees)
	_trees.setup(_eye_camera(), _brick_mat)
	_trees.stream(int(settings.seed), _tree_chance_at, _tree_variant_at, 420.0)
	_gen_ms = float(Time.get_ticks_usec() - t0) / 1000.0
	print("[mine] generated '%s' seed %d in %.0f ms; spawn %s (%s)" % [settings.name,
			int(settings.seed), _gen_ms, cell, _biome_names[BrickTerrain.biome_at(cell.x, cell.y)]])


func _teardown() -> void:
	# Removing a tier from the tree waits for its bakes (their _exit_tree).
	for n in [_trees, _far_next, _far, _streamer]:
		if n != null and is_instance_valid(n):
			remove_child(n)
			n.queue_free()
	_trees = null
	_far_next = null
	_far = null
	_streamer = null


func _new_far(tile: Vector2i) -> TerrainCoarse:
	var f := TerrainCoarse.new()
	f.name = "Far"
	# Snapped to the coarsest block, so the lattice lines up with the old one.
	var snap := 16
	f.anchor = Vector2i(floori(float(tile.x) / snap) * snap, floori(float(tile.y) / snap) * snap)
	add_child(f)
	return f


func _far_tiles() -> int:
	return clampi(int(settings.get("far_tiles", 64)), 16, 192)


func _tile_of(p: Vector3) -> Vector2i:
	var tile_m := float(BrickTerrain.get_tile_studs()) * BrickWorld.get_stud_metres()
	return Vector2i(floori(p.x / tile_m), floori(p.z / tile_m))


func _ground_m(x: int, z: int) -> float:
	return float(BrickTerrain.surface_plate(x, z) + 1) * BrickWorld.get_plate_metres()


## Dry land near `want` (studs): not a basin, river or beach, above the sea
## line, and flat enough to stand on. A spiral out, a stud lattice of 24.
func _find_spawn(want: Vector2i) -> Vector2i:
	var bad := ["Dry Ocean", "Dry River", "Beach", "Snowy Beach", "Stony Shore"]
	var sea_p := int(floor(float(settings.gen.get("sea_m", 20.0)) / BrickWorld.get_plate_metres()))
	for ring in 200:
		var r := ring * 24
		var n := maxi(1, ring * 8)
		for i in n:
			var a := TAU * float(i) / float(n)
			var c := want + Vector2i(int(cos(a) * r), int(sin(a) * r))
			if _biome_names[BrickTerrain.biome_at(c.x, c.y)] in bad:
				continue
			var h := BrickTerrain.surface_plate(c.x, c.y)
			if h <= sea_p + 3:
				continue
			var flat := true
			for d in [Vector2i(2, 0), Vector2i(-2, 0), Vector2i(0, 2), Vector2i(0, -2)]:
				if absi(BrickTerrain.surface_plate(c.x + d.x, c.y + d.y) - h) > 3:
					flat = false
					break
			if flat:
				return c
	return want


# ---------------------------------------------------------------------------
# Trees by biome

func _cache_tree_rules() -> void:
	_tree_chance.clear()
	_tree_variants.clear()
	var trees: Dictionary = settings.get("trees", {})
	for n in _biome_names:
		_tree_chance.append(float(trees.get(n, 0.0)))
		_tree_variants.append(Presets.BIOME_VARIANTS.get(n, []))


func _tree_chance_at(x: int, z: int) -> float:
	var b := BrickTerrain.biome_at(x, z)
	return _tree_chance[b] if b < _tree_chance.size() else 0.0


func _tree_variant_at(x: int, z: int, roll: float) -> int:
	var b := BrickTerrain.biome_at(x, z)
	var kinds: Array = _tree_variants[b] if b < _tree_variants.size() else []
	if kinds.is_empty():
		return int(roll * Trees.VARIANTS) % Trees.VARIANTS
	return int(kinds[int(roll * kinds.size()) % kinds.size()])


# ---------------------------------------------------------------------------
# The player (FpsRig: planet.tscn's own)

func _place_player(feet: Vector3) -> void:
	var far := _far_tiles() * BrickTerrain.get_tile_studs() * BrickWorld.get_stud_metres() + 300.0
	if pawn == null:
		walker = PlanetWalker.new()
		walker.name = "Walker"
		walker.scripted = _gate
		add_child(walker)
		walker.camera.far = far
		walker.place(feet + Vector3.UP, Vector3.FORWARD)
		walker.frozen = false
		var parts := FpsRig.make_player(self, feet, far, _gate)
		cam = parts.cam
		pawn = parts.pawn
		player = parts.player
		gun = parts.gun
		view = parts.view
		gun.on_structure_hit = _mine
		var s := AIServices.new()
		s.world3d = get_world_3d()
		kit = PlayerKit.attach(self, player, cam, gun, s, {"scripted": _gate})
		kit.enter(pawn, view)
		FpsRig.face(cam, pawn, Vector3.FORWARD)
	walker.camera.far = far
	cam.far = far
	set_on_foot(true, feet)


func set_on_foot(on: bool, feet := Vector3.INF) -> void:
	on_foot = on
	if on and feet == Vector3.INF:
		var t := walker.global_position
		var c := Vector2i(floori(t.x / BrickWorld.get_stud_metres()), floori(t.z / BrickWorld.get_stud_metres()))
		feet = Vector3(t.x, _ground_m(c.x, c.y) + 0.05, t.z)
		# Under the ground (flying through a cave roof): stand where the
		# walker is instead.
		if feet.y > t.y + 2.0:
			feet = t
	FpsRig.switch_mode(on, feet, walker, pawn, player, cam, view, kit)
	if _trees != null:
		_trees.camera = _eye_camera()


func _eye_camera() -> Camera3D:
	return cam if on_foot else walker.camera


func _eye() -> Vector3:
	return _eye_camera().global_position


## The gun hit the ground: break it there. Minecraft's left click, as a shot.
func _mine(point: Vector3, _dir: Vector3, _shot) -> void:
	var res: Dictionary = BrickTerrain.carve(point, MINE_RADIUS)
	var tiles: PackedInt32Array = res["tiles"]
	if tiles.is_empty():
		return
	var lo := Vector2i(1 << 30, 1 << 30)
	var hi := -lo
	for i in range(0, tiles.size(), 2):
		lo = Vector2i(mini(lo.x, tiles[i]), mini(lo.y, tiles[i + 1]))
		hi = Vector2i(maxi(hi.x, tiles[i]), maxi(hi.y, tiles[i + 1]))
	var rect := Rect2i(lo, hi - lo + Vector2i.ONE)
	_streamer.refresh(rect)
	_far.field_changed(rect)


# ---------------------------------------------------------------------------
# Every frame

func _process(delta: float) -> void:
	_frame_ms = lerpf(_frame_ms, delta * 1000.0, 0.1)
	if _streamer == null:
		return
	var eye := _eye()
	_streamer.follow(Vector2(eye.x, eye.z))
	_far.cover(_streamer, false)
	_far.relod(eye, false)
	_follow_far(eye)
	if not on_foot and walker.global_position.y < -500.0:
		walker.place(Vector3(eye.x, 200.0, eye.z), Vector3.FORWARD)
	if on_foot and pawn.feet().y < -500.0:
		set_on_foot(true, Vector3(eye.x, 0.0, eye.z) + Vector3.UP * 300.0)
	_day_night(delta, eye)
	_hud_in -= delta
	if _hud_in <= 0.0:
		_hud_in = 0.2
		_update_hud()


## An endless world: when the player is REANCHOR_TILES from where the far
## rings were laid out, bake a new set round them on the workers, swap it in
## when it is done, and drop the old.
func _follow_far(eye: Vector3) -> void:
	var t := _tile_of(eye)
	if _far_next == null:
		var d := t - _far.anchor
		if maxi(absi(d.x), absi(d.y)) >= REANCHOR_TILES:
			_far_next = _new_far(t)
			_far_next.visible = false
			if not _far_next.build_begin(_far_tiles(), _mat, Rect2i(), _streamer.align):
				_far_next.queue_free()
				_far_next = null
		return
	if not _far_next.build_poll():
		return
	var t0 := Time.get_ticks_usec()
	_far_next.cover(_streamer)
	_far_next.visible = true
	remove_child(_far)
	_far.queue_free()
	_far = _far_next
	_far_next = null
	_reanchors += 1
	_last_reanchor_ms = float(Time.get_ticks_usec() - t0) / 1000.0


## The sun goes round once a DAY_SECONDS; the sky, the ambient and the eye's
## exposure follow (LightRig, the planet's own calls). Under the ground the
## ambient fades, so caves are dark.
func _day_night(delta: float, eye: Vector3) -> void:
	if not _gate:
		_time = fposmod(_time + delta / DAY_SECONDS, 1.0)
	var a := (_time - 0.25) * TAU
	var to_sun := Vector3(cos(a), sin(a), 0.35).normalized()
	var height := sin(a)
	var seen := clampf(height * 6.0 + 0.4, 0.0, 1.0)
	var day := clampf(height * 2.5 + 0.4, 0.0, 1.0)
	_rig.set_sun(to_sun, seen, deg_to_rad(LightRig.DAY_SUN_ANGLE * 0.5), 1.0, 0.002)
	_rig.set_sky(day, 1.0, LightRig.HOME_ATMO, maxf(height, 0.0), Vector3.UP)
	var c := Vector2i(floori(eye.x / BrickWorld.get_stud_metres()), floori(eye.z / BrickWorld.get_stud_metres()))
	var under := _ground_m(c.x, c.y) - eye.y
	var cave := clampf(1.0 - (under - 1.5) / 6.0, 0.12, 1.0)
	_rig.env.ambient_light_energy *= cave
	_mat.set_shader_parameter("sun_dir", -_rig.sun.global_transform.basis.z)
	_rig.expose(eye, delta)


func _unhandled_input(event: InputEvent) -> void:
	if _gate or not (event is InputEventKey and event.pressed and not event.echo):
		return
	match (event as InputEventKey).keycode:
		KEY_F:
			if _menu == null:
				set_on_foot(not on_foot)
				get_viewport().set_input_as_handled()
		KEY_F9:
			toggle_menu()
			get_viewport().set_input_as_handled()
		KEY_F3:
			_show_readout = not _show_readout
			_update_hud()
		KEY_T:
			_time = fposmod(_time + 1.0 / 24.0, 1.0)


func toggle_menu() -> void:
	if _menu != null:
		_menu.queue_free()
		_menu = null
		return
	_menu = Menu.new()
	_menu.name = "WorldGenMenu"
	_hud_layer.add_child(_menu)
	_menu.setup(self)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func menu_closed() -> void:
	_menu = null


# ---------------------------------------------------------------------------
# The readout (F3)

func _build_hud() -> void:
	_hud_layer = CanvasLayer.new()
	_hud_layer.layer = 5
	add_child(_hud_layer)
	_hud = Label.new()
	# Under the kit's own top-left panels (key help, aggro meters).
	_hud.position = Vector2(14, 280)
	_hud.add_theme_color_override("font_color", Color(0.96, 0.97, 0.99))
	_hud.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	_hud.add_theme_constant_override("outline_size", 4)
	_hud.add_theme_font_size_override("font_size", 14)
	_hud_layer.add_child(_hud)


func _update_hud() -> void:
	if _hud == null or _streamer == null:
		return
	if not _show_readout:
		_hud.text = "F3 readout  F9 world generation"
		return
	var eye := _eye()
	var stud := BrickWorld.get_stud_metres()
	var c := Vector2i(floori(eye.x / stud), floori(eye.z / stud))
	var b := BrickTerrain.biome_at(c.x, c.y)
	var sea := float(settings.gen.get("sea_m", 20.0))
	var hour := int(_time * 24.0)
	var minute := int(fposmod(_time * 24.0, 1.0) * 60.0)
	_hud.text = "\n".join([
		"%s   seed %d   %02d:%02d   %.1f ms" % [settings.name, int(settings.seed), hour, minute, _frame_ms],
		"XYZ  %.1f / %.1f / %.1f m   (%.1f m above the sea line)" % [eye.x, eye.y, eye.z, eye.y - sea],
		"biome  %s   ground %s" % [_biome_names[b] if b < _biome_names.size() else "?",
				BrickTerrain.material_names()[BrickTerrain.material_at(c.x, c.y)]],
		"near  %s" % _streamer.report(),
		"far   %d blocks, %d hidden, %.0fk tris, anchor %s, re-centred %d (%.0f ms)" % [
				_far.block_count(), _far.hidden_count(), _far.triangle_count() / 1000.0,
				_far.anchor, _reanchors, _last_reanchor_ms],
		"trees %d   edits %d   generated in %.0f ms" % [_trees.count if _trees != null else 0,
				BrickTerrain.get_edit_count(), _gen_ms],
		"%s   F fly/walk  F9 world generation  F3 readout  T +1 hour" % ("ON FOOT" if on_foot
				else "FLYING %.0f m/s (wheel)" % walker.fly_speed),
	])


# ---------------------------------------------------------------------------
# The scripted pass: -- --gate. Pictures to user://dev/, numbers to the log.

func _run_gate() -> void:
	await _frames(10)
	var dev := UserPaths.DEV
	DirAccess.make_dir_recursive_absolute(dev)
	_time = 0.42
	await _frames(20)
	await _shot(dev + "mine_spawn.png")
	# Fly up for the overview, then out along X far enough to re-centre the
	# far rings twice, then back down to stand.
	set_on_foot(false)
	walker.place(walker.global_position + Vector3(0, 60, 0), Vector3(1, -0.35, 0.4).normalized())
	walker.pitch = -0.45
	await _frames(30)
	await _shot(dev + "mine_overview.png")
	var t0 := Time.get_ticks_usec()
	var worst := 0.0
	var from := walker.global_position
	for i in 900:
		walker.global_position = from + Vector3(1.0, 0.0, 0.3) * float(i) * 1.6
		var f0 := Time.get_ticks_usec()
		await get_tree().process_frame
		worst = maxf(worst, float(Time.get_ticks_usec() - f0) / 1000.0)
	print("[mine-gate] flew %.0f m in %.1f s, worst frame %.0f ms, re-centred %d times (last %.0f ms), %s"
			% [900 * 1.6, float(Time.get_ticks_usec() - t0) / 1e6, worst, _reanchors,
			_last_reanchor_ms, _streamer.report()])
	await _frames(120)
	print("[mine-gate] holes round the camera after the flight: %d" % _holes())
	await _shot(dev + "mine_far_away.png")
	# A cliff or a mountain, for overhangs: the highest ground near here.
	var e := _eye()
	var stud := BrickWorld.get_stud_metres()
	var best := Vector2i.ZERO
	var best_h := -(1 << 30)
	var c0 := Vector2i(floori(e.x / stud), floori(e.z / stud))
	for dz in range(-300, 300, 12):
		for dx in range(-300, 300, 12):
			var h := BrickTerrain.surface_plate(c0.x + dx, c0.y + dz)
			if h > best_h:
				best_h = h
				best = c0 + Vector2i(dx, dz)
	var top := Vector3((best.x + 0.5) * stud, _ground_m(best.x, best.y), (best.y + 0.5) * stud)
	walker.place(top + Vector3(-22, 6, -22), (top - (top + Vector3(-22, 6, -22))).normalized())
	walker.pitch = -0.2
	await _frames(90)
	await _shot(dev + "mine_mountain.png")
	# Night.
	_time = 0.02
	await _frames(20)
	await _shot(dev + "mine_night.png")
	_time = 0.42
	# The menu, then a new world from changed settings.
	toggle_menu()
	await _frames(10)
	await _shot(dev + "mine_menu.png")
	var s := settings.duplicate(true)
	s["seed"] = int(s.seed) + 1
	s.gen["height_scale"] = 1.4
	toggle_menu()
	var g0 := Time.get_ticks_usec()
	generate(s)
	print("[mine-gate] regenerated in %.0f ms" % (float(Time.get_ticks_usec() - g0) / 1000.0))
	await _frames(40)
	await _shot(dev + "mine_regenerated.png")
	print("[mine-gate] done")
	get_tree().quit()


## Tiles within 12 of the camera that neither tier draws: a hole in the
## ground. Must be 0 once streaming has caught up.
func _holes() -> int:
	var c := _tile_of(_eye())
	var n := 0
	for dz in range(-12, 13):
		for dx in range(-12, 13):
			var t := c + Vector2i(dx, dz)
			if not _streamer.has_tile(t) and _far.drawing(t).is_empty():
				n += 1
	return n


func _shot(path: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(path)
	print("[mine-gate] shot %s" % path)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame
