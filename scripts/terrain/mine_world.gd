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
##       B build mode (mine_builder.gd: break, place, pick, hotbar)
##       left mouse (on foot, not building): shoot -- the ground breaks where hit

const Presets := preload("res://scripts/terrain/worldgen_presets.gd")
const Menu := preload("res://scripts/terrain/worldgen_menu.gd")
const Builder := preload("res://scripts/terrain/mine_builder.gd")
const Debris := preload("res://scripts/terrain/terrain_debris.gd")
const Water := preload("res://scripts/water/mine_water.gd")

## A whole day, seconds (Minecraft's is 20 minutes).
const DAY_SECONDS := 1200.0
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
var _menu_layer: CanvasLayer = null
var _menu_prev_mouse := Input.MOUSE_MODE_VISIBLE
var builder: Node3D = null
var debris: Node3D = null
## Water and lava (mine_water.gd, Docs/MineWater.md).
var water: Node3D = null
## Shots waiting for their brick: [task id, holder, origin]. Which brick a
## shot breaks takes a tile's sample and packing, ~10 ms -- a worker's job
## (Docs/WhereWorkRuns.md); the main thread only clears the cells it found.
var _break_jobs: Array = []
const MAX_BREAK_JOBS := 12
var _menu_cam_captured := false

## Saving the world's changes (Docs/MineWorld.md 9): one file per seed and
## generator settings, under UserPaths.SAVES (a scripted pass: user://dev/).
const SAVE_MAGIC := "BCME"
const SAVE_FORMAT := 1
const AUTOSAVE_SECONDS := 30.0
var _edits_dirty := false
var _save_task := -1
var _save_in := AUTOSAVE_SECONDS
var _save_status := ""
## A/B for the edit hitch: `-- --sync-far` re-bakes the far tier the old,
## waiting way after every edit.
var _sync_far := false
## Edits gathered and handed to the tiers at most every REFRESH_EVERY: a
## rifle's shots each marked tiles stale while their re-bake was in flight,
## and every one of them was baked and swapped in again. `-- --no-coalesce`
## hands each edit over at once (the A/B).
const REFRESH_EVERY := 0.1
var _coalesce := true
var _pending_tiles := Rect2i()
var _refresh_in := 0.0
var _gen_ms := 0.0
var _reanchors := 0
var _last_reanchor_ms := 0.0
var _gate := false
var _water_gate := false
var _biome_names: PackedStringArray
var _tree_chance: Array[float] = []
var _tree_variants: Array = []


func _ready() -> void:
	_gate = "--gate" in OS.get_cmdline_user_args()
	_water_gate = "--gate=water" in OS.get_cmdline_user_args()
	_gate = _gate or _water_gate
	_sync_far = "--sync-far" in OS.get_cmdline_user_args()
	_coalesce = not "--no-coalesce" in OS.get_cmdline_user_args()
	if _gate:
		# A pass starts from the world as generated: last run's test saves go.
		var old := DirAccess.open(_save_dir())
		if old != null:
			for f in old.get_files():
				old.remove(f)
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
	builder = Builder.new()
	builder.name = "Builder"
	add_child(builder)
	builder.setup(self, _hud_layer)
	debris = Debris.new()
	debris.name = "Debris"
	add_child(debris)
	water = Water.new()
	water.name = "Water"
	add_child(water)
	water.setup(self, 20.0, 4)

	var start := Presets.load_settings(ContentPacks.resolve("worldgen/default.json"))
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--seed="):
			start["seed"] = int(arg.split("=")[1])
		elif arg.begins_with("--preset="):
			for p in Presets.list():
				if str(p.name).to_lower() == arg.split("=")[1].to_lower():
					start = Presets.load_settings(p.path)
	generate(start)
	if _water_gate:
		_run_water_gate()
	elif _gate:
		_run_gate()


func _exit_tree() -> void:
	save_edits(true)
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
	# The world being left keeps its changes: saved under ITS settings.
	if not settings.is_empty():
		save_edits(true)
	settings = s.duplicate(true)
	_teardown()
	_pending_tiles = Rect2i()
	_reanchors = 0
	_last_reanchor_ms = 0.0
	BrickTerrain.clear_terrain_edits()
	BrickTerrain.configure(int(settings.seed))
	BrickTerrain.set_generator(1)
	BrickTerrain.reset_gen_params()
	BrickTerrain.set_gen_params(settings.gen)
	# Before anything bakes: the tiles are made from the field WITH them.
	var loaded := _load_edits()
	_edits_dirty = false
	_save_status = "%d changes loaded" % loaded if loaded > 0 else "new world"
	var sea := float(settings.gen.get("sea_m", 20.0))
	# No water is drawn; the sea line is still where trees stop.
	BrickWave.set_sea_level(sea)
	_biome_names = BrickTerrain.biome_names()
	_cache_tree_rules()
	water.reset_world(sea, clampi(int(settings.get("detail_tiles", 4)), 2, 8))

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
	_wait_breaks()
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


## On foot or flying. Flying has NO collision at all (through hills, into
## caves) and keeps the pawn's camera, arms and gun with the flight
## (FpsRig keep_view). Landing puts the pawn exactly where the flight is --
## unless that is inside the ground, then on top of it.
func set_on_foot(on: bool, feet := Vector3.INF) -> void:
	on_foot = on
	if on and feet == Vector3.INF:
		feet = walker.global_position
		var stud := BrickWorld.get_stud_metres()
		var plate := BrickWorld.get_plate_metres()
		var c := Vector2i(floori(feet.x / stud), floori(feet.z / stud))
		var buried := false
		for h in [0.1, 0.9, 1.6]:
			if BrickTerrain.solid_at(c.x, floori((feet.y + h) / plate), c.y) != 0:
				buried = true
		if buried:
			feet.y = _ground_m(c.x, c.y) + 0.05
	FpsRig.switch_mode(on, feet, walker, pawn, player, cam, view, kit, true)
	if not on:
		walker.collision_layer = 0
		walker.collision_mask = 0
	if builder != null:
		builder.on_mode_changed()
	if _trees != null:
		_trees.camera = _eye_camera()


func _eye_camera() -> Camera3D:
	return cam if on_foot else walker.camera


func _eye() -> Vector3:
	return _eye_camera().global_position


## The gun hit the ground: it breaks WHOLE BRICKS there -- the surface piece
## hit, or the one brick of a wall -- and throws it (BrickTerrain.break_brick,
## Docs/MineWorld.md 10). A sphere of plate cells cut bricks in pieces and the
## rebuilt tile re-laid the bricks round it, which read as the ground being
## regenerated rather than broken.
func _mine(point: Vector3, dir: Vector3, _info) -> void:
	if _break_jobs.size() >= MAX_BREAK_JOBS:
		return
	var holder := [{}]
	var n := -dir
	var task := WorkerThreadPool.add_task(
		func() -> void: holder[0] = BrickTerrain.find_brick(point, n), false, "break brick")
	_break_jobs.append([task, holder, point - dir * 0.6])


## Finished shots: clear the cells each found, throw its brick. Never waits.
func _land_breaks() -> void:
	var i := 0
	while i < _break_jobs.size():
		var job: Array = _break_jobs[i]
		if not WorkerThreadPool.is_task_completed(job[0]):
			i += 1
			continue
		WorkerThreadPool.wait_for_task_completion(job[0])
		_break_jobs.remove_at(i)
		var found: Dictionary = job[1][0]
		var runs: PackedInt32Array = found.get("runs", PackedInt32Array())
		if runs.is_empty():
			continue
		var res: Dictionary = BrickTerrain.clear_runs(runs)
		if int(res.get("removed", 0)) == 0:
			continue
		debris.spawn(found["debris"], job[2])
		terrain_edited(res)


func _wait_breaks() -> void:
	for job in _break_jobs:
		WorkerThreadPool.wait_for_task_completion(job[0])
	_break_jobs.clear()


## The field changed (a shot, a block broken or placed): rebake the tiles it
## names behind the old ones, and the far blocks over them.
func terrain_edited(res: Dictionary) -> void:
	water.terrain_changed(res)
	var tiles: PackedInt32Array = res["tiles"]
	if tiles.is_empty():
		return
	var lo := Vector2i(1 << 30, 1 << 30)
	var hi := -lo
	for i in range(0, tiles.size(), 2):
		lo = Vector2i(mini(lo.x, tiles[i]), mini(lo.y, tiles[i + 1]))
		hi = Vector2i(maxi(hi.x, tiles[i]), maxi(hi.y, tiles[i + 1]))
	var rect := Rect2i(lo, hi - lo + Vector2i.ONE)
	_edits_dirty = true
	_pending_tiles = rect if not _pending_tiles.has_area() else _pending_tiles.merge(rect)
	if not _coalesce or _refresh_in <= 0.0:
		_flush_edits()


func _flush_edits() -> void:
	if not _pending_tiles.has_area():
		return
	var rect := _pending_tiles
	_pending_tiles = Rect2i()
	_refresh_in = REFRESH_EVERY
	_streamer.refresh(rect)
	if _sync_far:
		_far.field_changed(rect)
	else:
		_far.field_changed_soon(rect)


# ---------------------------------------------------------------------------
# Every frame

func _process(delta: float) -> void:
	_frame_ms = lerpf(_frame_ms, delta * 1000.0, 0.1)
	if _streamer == null:
		return
	var eye := _eye()
	_land_breaks()
	_refresh_in -= delta
	if _refresh_in <= 0.0:
		_flush_edits()
	_streamer.follow(Vector2(eye.x, eye.z))
	_far.cover(_streamer, false)
	_far.relod(eye, false)
	_follow_far(eye)
	if not on_foot:
		FpsRig.follow_flight(cam, walker)
	if not on_foot and walker.global_position.y < -500.0:
		walker.place(Vector3(eye.x, 200.0, eye.z), Vector3.FORWARD)
	if on_foot and pawn.feet().y < -500.0:
		set_on_foot(true, Vector3(eye.x, 0.0, eye.z) + Vector3.UP * 300.0)
	_day_night(delta, eye)
	_autosave(delta)
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


## The world generation menu, opened the way the pause menu opens
## (menu/core/MenuManager.gd): a canvas layer of its own above everything,
## the tree PAUSED so nothing in the world -- camera, walker, pawn, gun,
## builder -- sees a click or a key, the mouse freed, and put back on close.
## On the HUD layer it was a PanelContainer, whose mouse filter passes a click
## on its empty parts on to the game: the walker took the mouse and the
## camera turned under the menu.
func toggle_menu() -> void:
	if _menu != null:
		_menu.call("_close")
		return
	_menu_prev_mouse = Input.mouse_mode
	_menu_layer = CanvasLayer.new()
	_menu_layer.name = "WorldGenMenuLayer"
	_menu_layer.layer = 80
	_menu_layer.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_menu_layer)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.35)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_menu_layer.add_child(dim)
	_menu = Menu.new()
	_menu.name = "WorldGenMenu"
	_menu_layer.add_child(_menu)
	_menu.setup(self)
	# The world stops here, not by pausing the tree: SceneTree.paused cannot
	# be set while the engine holds the tree suspended (run from the editor,
	# "Pause state cannot be modified while suspended"), and then nothing
	# stopped. Disabling this node stops every child of it -- camera, pawn,
	# walker, gun, builder, streaming -- and the menu's layer, ALWAYS, alone
	# takes input.
	process_mode = Node.PROCESS_MODE_DISABLED
	# PlayerCamera turns on mouse motion whenever it counts itself captured,
	# whatever the mouse mode says: release it the camera's own way.
	_menu_cam_captured = cam != null and bool(cam.get("_captured"))
	if cam != null:
		cam._set_captured(false)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func menu_closed() -> void:
	_menu = null
	if _menu_layer != null:
		_menu_layer.queue_free()
		_menu_layer = null
	process_mode = Node.PROCESS_MODE_INHERIT
	if PlayerCamera.hands_off:
		return
	if _menu_cam_captured and cam != null:
		cam._set_captured(true)
	elif _menu_prev_mouse == Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func menu_is_open() -> bool:
	return _menu != null


# ---------------------------------------------------------------------------
# Saving the world's changes

func _save_dir() -> String:
	return (UserPaths.DEV + "mine_saves/") if _gate else (UserPaths.SAVES + "mine_world/")


## One file per seed AND generator settings: an edit means nothing against
## a different field.
func save_path() -> String:
	var key := "%s|%d" % [JSON.stringify(settings.get("gen", {}), "", true), int(settings.get("seed", 0))]
	return _save_dir() + "%d_%08x.edits" % [int(settings.get("seed", 0)), key.hash() & 0xffffffff]


func _load_edits() -> int:
	var path := save_path()
	if not FileAccess.file_exists(path):
		return 0
	var f := FileAccess.open_compressed(path, FileAccess.READ, FileAccess.COMPRESSION_ZSTD)
	if f == null:
		return 0
	if f.get_buffer(4).get_string_from_ascii() != SAVE_MAGIC:
		return 0
	var fmt := f.get_32()
	var field := f.get_32()
	if fmt != SAVE_FORMAT or field != BrickTerrain.get_field_version():
		push_warning("[mine] %s is from another format or field; not loaded" % path)
		return 0
	var n := f.get_32()
	return BrickTerrain.set_edits(f.get_buffer(n * 13))


## Write the changes if there are any unsaved. `wait`: now, on this thread
## (leaving, generating); otherwise on a worker, checked next frame.
func save_edits(wait := false) -> void:
	if _save_task >= 0:
		if not wait and not WorkerThreadPool.is_task_completed(_save_task):
			return
		WorkerThreadPool.wait_for_task_completion(_save_task)
		_save_task = -1
	if not _edits_dirty or settings.is_empty():
		return
	_edits_dirty = false
	var bytes: PackedByteArray = BrickTerrain.get_edits()
	var path := save_path()
	var dir := _save_dir()
	var field := BrickTerrain.get_field_version()
	var write := func() -> void:
		DirAccess.make_dir_recursive_absolute(dir)
		var f := FileAccess.open_compressed(path + ".tmp", FileAccess.WRITE, FileAccess.COMPRESSION_ZSTD)
		if f == null:
			return
		f.store_buffer(SAVE_MAGIC.to_ascii_buffer())
		f.store_32(SAVE_FORMAT)
		f.store_32(field)
		@warning_ignore("integer_division")
		f.store_32(bytes.size() / 13)
		f.store_buffer(bytes)
		f.close()
		DirAccess.rename_absolute(path + ".tmp", path)
	@warning_ignore("integer_division")
	_save_status = "%d changes saved" % (bytes.size() / 13)
	if wait:
		write.call()
	else:
		_save_task = WorkerThreadPool.add_task(write, false, "mine world save")


func _autosave(delta: float) -> void:
	if _save_task >= 0 and WorkerThreadPool.is_task_completed(_save_task):
		WorkerThreadPool.wait_for_task_completion(_save_task)
		_save_task = -1
	_save_in -= delta
	if _save_in <= 0.0:
		_save_in = AUTOSAVE_SECONDS
		save_edits(false)


## The world as generated again: its saved changes thrown away (the menu's
## "Forget changes to this world").
func forget_edits() -> void:
	if _save_task >= 0:
		WorkerThreadPool.wait_for_task_completion(_save_task)
		_save_task = -1
	var path := save_path()
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	_edits_dirty = false
	var s2 := settings.duplicate(true)
	settings = {}
	generate(s2)


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
		"blocks placed %d  broken %d   %s" % [builder.placed, builder.broken, _save_status],
		"water %s" % water.report(),
		"%s   F fly/walk  B build  F9 world generation  F3 readout  T +1 hour" % ("ON FOOT" if on_foot
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
	print("[mine-gate] flying: collision layer %d mask %d, drawn camera is the pawn's %s, %.2f m from the flight camera, arms shown %s"
			% [walker.collision_layer, walker.collision_mask, cam.current,
			cam.global_position.distance_to(walker.camera.global_position), view.rig.visible])
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
	print("[mine-gate] menu open: world stopped %s, mouse visible %s" % [not can_process(),
			Input.mouse_mode == Input.MOUSE_MODE_VISIBLE])
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
	await _gate_build()
	# Landing in mid-air: the pawn is put where the flight is, not dropped
	# to the ground.
	var at := walker.global_position + Vector3(0, 12, 0)
	walker.global_position = at
	await _frames(2)
	at = walker.global_position
	set_on_foot(true)
	print("[mine-gate] landed %.2f m from where the flight was (ground %.1f m below)"
			% [pawn.feet().distance_to(at), at.y - _ground_m(floori(at.x / BrickWorld.get_stud_metres()),
			floori(at.z / BrickWorld.get_stud_metres()))])
	await _frames(60)
	await _gate_edits()
	print("[mine-gate] done")
	get_tree().quit()


## The water pass: -- --gate=water (Docs/MineWater.md 14, stage 2). On a
## walled stone platform laid above the ground near spawn (so the ground under
## each scene is known, and nothing runs off into the world): a stream down a
## stepped hill, a waterfall off a cliff, a pond, lava meeting water, then the
## stream drying once its source is taken. The water is ticked by the pass
## (water.step), so the pictures are the same every run.
func _run_water_gate() -> void:
	await _frames(10)
	var dev := UserPaths.DEV
	DirAccess.make_dir_recursive_absolute(dev)
	_time = 0.42
	water.manual = true
	var stud := BrickWorld.get_stud_metres()
	var course := BrickWorld.get_plate_metres() * 3.0
	var e := _eye()
	var o := Vector2i(floori(e.x / stud) + 6, floori(e.z / stud) - 40)
	var top := -(1 << 30)
	for dz in range(-32, 33, 2):
		for dx in range(-32, 33, 2):
			top = maxi(top, BrickTerrain.surface_plate(o.x + dx, o.y + dz))
	var fl := floori(float(top) / 3.0) + 4          ## the platform's course
	var w := fl + 1                                ## water stands here
	var lay := func(x0: int, z0: int, x1: int, z1: int, b0: int, b1: int, mat: int) -> void:
		var r: Dictionary = BrickTerrain.fill_box(Vector3i(o.x + x0, b0 * 3, o.y + z0),
				Vector3i(o.x + x1, b1 * 3 + 2, o.y + z1), mat, false)
		terrain_edited(r)
	var stone := maxi(BrickTerrain.material_names().find("stone"), 1)
	var dark := maxi(BrickTerrain.material_names().find("dark stone"), 1)
	lay.call(-32, -32, 32, 32, fl, fl, stone)
	# The rim, two bricks tall: water spreads 14 studs, nothing gets out.
	lay.call(-32, -32, 32, -32, w, w + 1, dark)
	lay.call(-32, 32, 32, 32, w, w + 1, dark)
	lay.call(-32, -32, -32, 32, w, w + 1, dark)
	lay.call(32, -32, 32, 32, w, w + 1, dark)
	# A: a stepped hill, four steps down to the east.
	for i in 4:
		lay.call(-24 + i * 4, -26, -21 + i * 4, -18, w, w + 3 - i, dark)
	# B: a cliff six bricks tall with a source near its east edge.
	lay.call(-30, 0, -20, 22, w, w + 5, dark)
	# C: a pond, a wall one brick tall round 8 x 8.
	lay.call(4, 4, 13, 4, w, w, dark)
	lay.call(4, 13, 13, 13, w, w, dark)
	lay.call(4, 4, 4, 13, w, w, dark)
	lay.call(13, 4, 13, 13, w, w, dark)
	# D: a lava pit beside a water channel, in a walled box.
	lay.call(18, -26, 30, -26, w, w + 1, dark)
	lay.call(18, -14, 30, -14, w, w + 1, dark)
	lay.call(18, -26, 18, -14, w, w + 1, dark)
	await _frames(30)
	water.step(1)

	var src_a := Vector3i(o.x - 23, w + 4, o.y - 22)
	BrickFluid.place(src_a, 1, BrickFluid.SOURCE, 3)
	BrickFluid.place(Vector3i(o.x - 21, w + 6, o.y + 11), 1, BrickFluid.SOURCE, 3)
	for x in range(5, 13):
		for z in range(5, 13):
			BrickFluid.place(Vector3i(o.x + x, w, o.y + z), 1, BrickFluid.STILL, 2)
	BrickFluid.place(Vector3i(o.x + 21, w, o.y - 20), 2, BrickFluid.SOURCE, 3)
	BrickFluid.place(Vector3i(o.x + 28, w, o.y - 20), 1, BrickFluid.SOURCE, 3)
	var t0 := Time.get_ticks_usec()
	var worst := 0.0
	var ticks := 0
	for i in 300:
		water.step(1)
		ticks += 1
		var tick_ms := float(BrickFluid.stats().get("tick_ms", 0.0))
		worst = maxf(worst, tick_ms)
		if BrickFluid.active_count() == 0:
			break
		if i % 10 == 0:
			await get_tree().process_frame
	print("[water-gate] platform at course %d (%.1f m); settled in %d ticks (%.0f ms), worst tick %.2f ms; %s" % [
			fl, fl * course, ticks, float(Time.get_ticks_usec() - t0) / 1000.0, worst, water.report()])
	await _frames(30)

	set_on_foot(false)
	# Pictures of the water, not of the gun and the readout.
	# PlayerView shows its rig again every frame: it is paused meanwhile.
	view.process_mode = Node.PROCESS_MODE_DISABLED
	view.rig.visible = false
	if view.arms != null:
		view.arms.visible = false
	_hud_layer.visible = false
	var pm := func(x: float, b: float, z: float) -> Vector3:
		return Vector3((o.x + x) * stud, b * course, (o.y + z) * stud)
	var look := func(from: Vector3, at: Vector3) -> void:
		walker.place(from, ((at - from) * Vector3(1, 0, 1)).normalized())
		var d := at - from
		walker.pitch = atan2(d.y, Vector2(d.x, d.z).length())
	look.call(pm.call(-4.0, w + 7.0, -4.0), pm.call(-16.0, w + 1.0, -22.0))
	await _frames(40)
	await _shot(dev + "water_stream.png")
	look.call(pm.call(-6.0, w + 5.0, 14.0), pm.call(-20.0, w + 3.0, 11.0))
	await _frames(40)
	await _shot(dev + "water_fall.png")
	look.call(pm.call(18.0, w + 6.0, 20.0), pm.call(9.0, w, 9.0))
	await _frames(40)
	await _shot(dev + "water_pond.png")
	look.call(pm.call(24.0, w + 7.0, -4.0), pm.call(24.0, w, -20.0))
	await _frames(40)
	await _shot(dev + "water_lava.png")
	print("[water-gate] pond holds %d tiles (128 poured), lava laid %d rock cells" % [
			_pond_units(o, w), water.rock_laid])

	# The stream cut off: it drains to its hollows, then dries.
	BrickFluid.remove(src_a, -1)
	water.step(40)
	look.call(pm.call(-4.0, w + 7.0, -4.0), pm.call(-16.0, w + 1.0, -22.0))
	await _frames(30)
	await _shot(dev + "water_draining.png")
	for i in 60:
		water.step(10)
		await get_tree().process_frame
	await _frames(20)
	await _shot(dev + "water_dried.png")
	var wet := 0
	for x in range(-30, 0):
		for z in range(-31, -10):
			for b in range(w, w + 5):
				var ci: Dictionary = BrickFluid.cell_info(Vector3i(o.x + x, b, o.y + z))
				if int(ci.fluid) != 0 and int(ci.kind) == BrickFluid.STILL:
					wet += 1
	# Still water only: the waterfall's running water reaches this far.
	print("[water-gate] stream area still cells after drying: %d (want 0); %s" % [wet, water.report()])
	view.process_mode = Node.PROCESS_MODE_INHERIT
	view.rig.visible = true
	_hud_layer.visible = true

	# Live ticks on the worker (the game's way), a source poured on the
	# platform: frames must not wait on it.
	water.manual = false
	BrickFluid.place(Vector3i(o.x - 5, w, o.y + 20), 1, BrickFluid.SOURCE, 3)
	var fw := 0.0
	for f in 120:
		var f0 := Time.get_ticks_usec()
		await get_tree().process_frame
		fw = maxf(fw, float(Time.get_ticks_usec() - f0) / 1000.0)
	print("[water-gate] live: 120 frames, worst %.1f ms; %s" % [fw, water.report()])
	print("[water-gate] done")
	get_tree().quit()


func _pond_units(o: Vector2i, w: int) -> int:
	var n := 0
	for x in range(5, 13):
		for z in range(5, 13):
			var c: Dictionary = BrickFluid.cell_info(Vector3i(o.x + x, w, o.y + z))
			if int(c.fluid) == 1:
				n += int(c.amount)
	return n


## Build mode, as a player would: fly a little above the ground looking down
## at it, place a pillar, break a block out of it, picture it.
func _gate_build() -> void:
	set_on_foot(false)
	var e := _eye()
	var stud := BrickWorld.get_stud_metres()
	var c := Vector2i(floori(e.x / stud), floori(e.z / stud))
	var g := _ground_m(c.x, c.y)
	walker.place(Vector3(e.x, g + 2.4, e.z), Vector3(0, 0, -1))
	walker.pitch = -0.75
	await _frames(20)
	builder.set_active(true)
	var ok_place := 0
	for i in 4:
		builder.update_target()
		if builder.place_target():
			ok_place += 1
		await _frames(8)
	builder.update_target()
	var ok_break: bool = builder.break_target()
	await _frames(40)
	builder.update_target()
	print("[mine-gate] build: placed %d of 4, broke %s, edits %d, %s"
			% [ok_place, ok_break, BrickTerrain.get_edit_count(), builder.log_blocks])
	await _shot(UserPaths.DEV + "mine_build_view.png")
	walker.place(Vector3(e.x + 2.5, g + 3.2, e.z + 2.5), Vector3(-1, 0, -1))
	walker.pitch = -0.6
	await _frames(40)
	await _shot(UserPaths.DEV + "mine_build.png")
	builder.set_active(false)


## The edit hitch, measured: shots at the ground in front of the player, one
## every 15 frames, the worst frame of each window kept. Then the save: the
## changes written, the world generated again, the same changes back.
func _gate_edits() -> void:
	set_on_foot(true)
	await _frames(30)
	var e := _eye()
	var stud := BrickWorld.get_stud_metres()
	# Baseline: the same frames with nothing edited, so an edit's frames have
	# something to be compared with (vsync, other programs).
	var idle_worst := 0.0
	var idle_slow := 0
	for f in 180:
		var t0 := Time.get_ticks_usec()
		await get_tree().process_frame
		var ms := float(Time.get_ticks_usec() - t0) / 1000.0
		idle_worst = maxf(idle_worst, ms)
		if ms > 20.0:
			idle_slow += 1
	print("[mine-gate] idle: 180 frames, worst %.1f ms, %d over 20 ms" % [idle_worst, idle_slow])
	_streamer.reset_stats()
	TerrainTile.profile_instances = true
	TerrainTile.instance_ms.clear()
	var worst := 0.0
	var sum := 0.0
	var frames := 0
	for i in 12:
		var p := e + Vector3(2.0 + float(i % 4) * 1.3, 0.0, -3.0 - floorf(float(i) / 4.0) * 1.3)
		var c := Vector2i(floori(p.x / stud), floori(p.z / stud))
		p.y = _ground_m(c.x, c.y) - 0.2
		_mine(p, Vector3.DOWN, null)
		for f in 15:
			var t0 := Time.get_ticks_usec()
			await get_tree().process_frame
			var ms := float(Time.get_ticks_usec() - t0) / 1000.0
			worst = maxf(worst, ms)
			sum += ms
			frames += 1
	print("[mine-gate] edits (%s far): 12 shots, worst frame %.1f ms, mean %.1f ms, %s" % [
			"waiting" if _sync_far else "no-wait", worst, sum / frames, _streamer.report()])
	# Sustained fire: a shot every 4 frames for 30 shots, as a rifle held down.
	var slow := 0
	var worst2 := 0.0
	var sum2 := 0.0
	var n2 := 0
	for i in 30:
		var p := e + Vector3(1.5 + float(i % 6) * 0.5, 0.0, -2.5 - floorf(float(i) / 6.0) * 0.5)
		var c := Vector2i(floori(p.x / stud), floori(p.z / stud))
		p.y = _ground_m(c.x, c.y) - 0.2
		_mine(p, Vector3.DOWN, null)
		for f in 4:
			var t0 := Time.get_ticks_usec()
			await get_tree().process_frame
			var ms := float(Time.get_ticks_usec() - t0) / 1000.0
			worst2 = maxf(worst2, ms)
			sum2 += ms
			n2 += 1
			if ms > 20.0:
				slow += 1
	for f in 60:
		var t0 := Time.get_ticks_usec()
		await get_tree().process_frame
		var ms := float(Time.get_ticks_usec() - t0) / 1000.0
		worst2 = maxf(worst2, ms)
		if ms > 20.0:
			slow += 1
	print("[mine-gate] rapid fire (%s): 30 shots, worst frame %.1f ms, mean %.1f ms, %d of 180 frames over 20 ms, %s" % [
			"coalesced" if _coalesce else "each at once", worst2, sum2 / n2, slow, _streamer.report()])
	TerrainTile.profile_instances = false
	var keys := TerrainTile.instance_ms.keys()
	keys.sort()
	print("[mine-gate] instances phase, worst by step: %s" % ", ".join(keys.map(
			func(k: String) -> String: return "%s %.1f" % [k, TerrainTile.instance_ms[k]])))
	# A look at what the shots left: whole bricks gone, the rest as laid.
	set_on_foot(false)
	walker.place(e + Vector3(5.5, 2.5, 0.5), Vector3(-0.3, 0.0, -1.0).normalized())
	walker.pitch = -0.55
	await _frames(30)
	await _shot(UserPaths.DEV + "mine_broken.png")
	var count := BrickTerrain.get_edit_count()
	save_edits(true)
	var path := save_path()
	var s2 := settings.duplicate(true)
	settings = {}
	generate(s2)
	print("[mine-gate] save: %d edits written to %s, %d back after generating again (%s)" % [
			count, path, BrickTerrain.get_edit_count(), _save_status])


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
