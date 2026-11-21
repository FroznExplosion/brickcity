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
## Keys: F fly/walk · M world generation menu (also in the pause menu, Escape)
##       · F3 readout · T skip an hour. NOT F9: in the editor's embedded game
##       view F9 is the editor's "Suspend/Resume Embedded Project", and a
##       suspended tree takes no clicks at all.
##       B guns <-> items (mine_builder.gd: break, place, pick; Inventory, Docs/Inventory.md)
##       left mouse (on foot, not building): shoot -- the ground breaks where hit

const Presets := preload("res://scripts/terrain/worldgen_presets.gd")
const Menu := preload("res://scripts/terrain/worldgen_menu.gd")
const Builder := preload("res://scripts/terrain/mine_builder.gd")
const Debris := preload("res://scripts/terrain/terrain_debris.gd")
const Collapse := preload("res://scripts/terrain/ground_collapse.gd")
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
## The underground under the surface tiles (Docs/MineWorld.md 16).
var _deep: TerrainDeep = null
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
## The ground coming down where an edit leaves it hanging (ground_collapse.gd,
## Docs/TerrainCollapse.md).
var collapse: Collapse = null
## Water and lava (mine_water.gd, Docs/MineWater.md).
var water: Node3D = null
## Shots waiting for their brick: [task id, holder, origin]. Which brick a
## shot breaks takes a tile's sample and packing, ~10 ms -- a worker's job
## (Docs/WhereWorkRuns.md); the main thread only clears the cells it found.
var _break_jobs: Array = []
const MAX_BREAK_JOBS := 12
var _menu_cam_captured := false
## The inventory screen (Docs/Inventory.md 4, stage 3) and its layer, or null.
var _inv_screen: InventoryScreen = null
var _inv_layer: CanvasLayer = null
var _inv_cam_captured := false
var _inv_prev_mouse := Input.MOUSE_MODE_VISIBLE
var _inv_walker_frozen := false
## Chests and the items lying in the world (Docs/Inventory.md 4, stage 5).
var chests: MineChests = null
var drops: DroppedItems = null

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
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--gate"):
			_gate = true
		if arg == "--gate=water":
			_water_gate = true
	_sync_far = "--sync-far" in OS.get_cmdline_user_args()
	_coalesce = not "--no-coalesce" in OS.get_cmdline_user_args()
	if _gate:
		# A pass starts from the world as generated: last run's test saves go.
		var old := DirAccess.open(_save_dir())
		if old != null:
			for f in old.get_files():
				old.remove(f)
		# ... and its character: the pass starts from the starting kit.
		if FileAccess.file_exists(GATE_CHARACTER):
			DirAccess.remove_absolute(GATE_CHARACTER)
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
	# The top course laid on the ground's bond, so it sits staggered on the
	# courses under it like real LEGO (Docs/TerrainBond.md).
	BrickTerrain.set_bond_top(true)
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
	builder.inv.changed.connect(_on_inventory_changed)
	drops = DroppedItems.new()
	drops.name = "DroppedItems"
	add_child(drops)
	drops.setup(self, builder.inv)
	chests = MineChests.new()
	chests.name = "Chests"
	add_child(chests)
	chests.setup(self, builder.inv, drops)
	_build_item_icons()
	debris = Debris.new()
	debris.name = "Debris"
	add_child(debris)
	collapse = Collapse.new()
	collapse.name = "Collapse"
	add_child(collapse)
	collapse.setup(self, _brick_mat)
	# A piece coming to rest changes what a save holds.
	collapse.pieces.ground_changed.connect(func(_box: AABB) -> void: _edits_dirty = true)
	water = Water.new()
	water.name = "Water"
	add_child(water)
	water.setup(self)

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
		if _water_gate:
			_run_water_gate()
		elif "--gate=sea" in OS.get_cmdline_user_args():
			_run_sea_gate()
		elif "--gate=gen" in OS.get_cmdline_user_args():
			_run_gen_gate()
		elif "--gate=menu" in OS.get_cmdline_user_args():
			_run_menu_gate()
		elif "--gate=inventory" in OS.get_cmdline_user_args():
			_run_inventory_gate()
		elif "--gate=look" in OS.get_cmdline_user_args():
			_run_look_gate()
		elif "--gate=cave" in OS.get_cmdline_user_args():
			_run_cave_gate()
		elif "--gate=collapse" in OS.get_cmdline_user_args():
			_run_collapse_gate()
		elif "--gate=flight" in OS.get_cmdline_user_args():
			_run_flight_gate()
		elif "--gate=spawn" in OS.get_cmdline_user_args():
			_run_spawn_gate()
		elif "--gate=stop" in OS.get_cmdline_user_args():
			_run_stop_gate()
		elif "--gate=breakwater" in OS.get_cmdline_user_args():
			_run_breakwater_gate()
		elif "--gate=mega" in OS.get_cmdline_user_args():
			_run_mega_gate()
		elif "--gate=shift" in OS.get_cmdline_user_args():
			_run_shift_gate()
		elif "--gate=deep" in OS.get_cmdline_user_args():
			_run_deep_gate()
		else:
			_run_gate()


func _exit_tree() -> void:
	save_edits(true)
	# Every other scene expects the classic field.
	_teardown()
	BrickTerrain.set_generator(0)
	BrickTerrain.set_deep_tier(false)
	BrickTerrain.reset_gen_params()
	BrickTerrain.set_coarse_smooth_step(8)
	BrickTerrain.set_bond_top(false)


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
	collapse.reset()
	BrickTerrain.clear_terrain_edits()
	BrickTerrain.configure(int(settings.seed))
	BrickTerrain.set_generator(1)
	# Surface tiles stop at their floor; the deep tier draws under it
	# (Docs/MineWorld.md 16).
	BrickTerrain.set_deep_tier(true)
	BrickTerrain.reset_gen_params()
	BrickTerrain.set_gen_params(settings.gen)
	# Before anything bakes: the tiles are made from the field WITH them.
	var loaded := _load_edits()
	_load_pieces()
	_load_placed()
	_load_inventory()
	_edits_dirty = false
	_save_status = "%d changes loaded" % loaded if loaded > 0 else "new world"
	var sea := float(settings.gen.get("sea_m", 20.0))
	# The sea line is where trees stop; the water snaps it to a course below.
	BrickWave.set_sea_level(sea)
	_biome_names = BrickTerrain.biome_names()
	_cache_tree_rules()

	var sp = settings.get("spawn", null)
	var want := Vector2i.ZERO
	if sp is Array and (sp as Array).size() == 2:
		want = Vector2i(int(sp[0]), int(sp[1]))
	var cell := _find_spawn(want)
	# The sea is water unless the settings say not (Docs/MineWater.md 9); its
	# first shore field round the spawn.
	water.reset_world(sea, clampi(int(settings.get("detail_tiles", 4)), 2, 8),
			bool(settings.gen.get("water", true)), float(settings.gen.get("wave_scale", 1.0)), cell)
	# The water's own changes, after the ground's (it reads its solids).
	var fluid_cells := _load_fluid()
	_fluid_saved_at = BrickFluid.change_count()
	if fluid_cells > 0:
		_save_status += ", %d water cells" % fluid_cells
	var stud := BrickWorld.get_stud_metres()
	spawn_xz = Vector2((cell.x + 0.5) * stud, (cell.y + 0.5) * stud)
	var feet := Vector3(spawn_xz.x, _ground_m(cell.x, cell.y) + 0.05, spawn_xz.y)

	var near := clampi(int(settings.get("detail_tiles", 4)), 2, 8)
	_streamer = TerrainStreamer.new()
	_streamer.name = "Streamer"
	_streamer.near_radius = near
	_streamer.keep_radius = near + 2
	_streamer.world_half = 1 << 20
	# The ground never casts into the sun's shadow map. It did (the sun moves,
	# so it cannot be baked as the heightfield test bakes it), and a brick top
	# shadowing itself drew a fine diagonal grain over every lit surface --
	# the "fuzzy, blurry bricks" (Docs/MineWorld.md 11). Trees, the player and
	# debris still cast onto it; underground the sun fades instead (_day_night).
	_streamer.shadow_radius = -1
	add_child(_streamer)
	_streamer.setup(_mat)
	_streamer.settle(spawn_xz)

	_deep = TerrainDeep.new()
	_deep.name = "Deep"
	add_child(_deep)
	_deep.setup(_mat)

	_far = _new_far(_tile_of(feet))
	_far.build(_far_tiles(), _mat, Rect2i(), _streamer.align)
	_far.cover(_streamer)

	_place_player(feet)
	_trees = TerrainTrees.new()
	_trees.name = "Trees"
	add_child(_trees)
	_trees.setup(_eye_camera(), _brick_mat)
	_trees.stream(int(settings.seed), _tree_chance_at, _tree_variant_at, 420.0)
	_trees.solid_m = 64.0   # trunks the player and rounds meet
	# The instance pool, filled now rather than by the first new ground's
	# never-drawn nodes (the spawn spike, Docs/MineWorld.md 14).
	if _prewarm_on:
		var e := _eye_render()
		var tw := Time.get_ticks_usec()
		_warm = TerrainTile.prewarm_begin(_streamer, e - _eye_camera().global_transform.basis.z * 1.5,
				PREWARM_PER_KIND)
		prewarm_ms = float(Time.get_ticks_usec() - tw) / 1000.0
		_warm_frame_ms = 0.0
		_warm_frames = 3
	_gen_ms = float(Time.get_ticks_usec() - t0) / 1000.0
	print("[mine] generated '%s' seed %d in %.0f ms; spawn %s (%s)" % [settings.name,
			int(settings.seed), _gen_ms, cell, _biome_names[BrickTerrain.biome_at(cell.x, cell.y)]])


func _teardown() -> void:
	fast_hold = false
	_speed = 0.0
	_speed_from = Vector3.INF
	_wait_breaks()
	# Removing a tier from the tree waits for its bakes (their _exit_tree).
	for n in [_trees, _far_next, _far, _streamer, _deep]:
		if n != null and is_instance_valid(n):
			remove_child(n)
			n.queue_free()
	_deep = null
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
	# Not in a lake (Docs/MineWater.md 14.8).
	if BrickFluid.lake_top(x, z) != -2147483648:
		return 0.0
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
		walker.place(to_global(feet + Vector3.UP), Vector3.FORWARD)
		walker.frozen = false
		var parts := FpsRig.make_player(self, to_global(feet), far, _gate)
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
		feet = to_local(walker.global_position)
		var stud := BrickWorld.get_stud_metres()
		var plate := BrickWorld.get_plate_metres()
		var c := Vector2i(floori(feet.x / stud), floori(feet.z / stud))
		var buried := false
		for h in [0.1, 0.9, 1.6]:
			if BrickTerrain.solid_at(c.x, floori((feet.y + h) / plate), c.y) != 0:
				buried = true
		if buried:
			feet.y = _ground_m(c.x, c.y) + 0.05
	FpsRig.switch_mode(on, to_global(feet) if feet != Vector3.INF else feet, walker, pawn,
			player, cam, view, kit, true)
	if not on:
		walker.collision_layer = 0
		walker.collision_mask = 0
	if builder != null:
		builder.on_mode_changed()
	if _trees != null:
		_trees.camera = _eye_camera()


func _eye_camera() -> Camera3D:
	return cam if on_foot else walker.camera


## The eye in the TERRAIN frame -- the one BrickTerrain, BrickFluid, the
## tiles, trees, water and pieces (all children of this node) are laid out
## in. It is the global position until the first origin shift moves this
## node (Docs/MineWorld.md 15).
func _eye() -> Vector3:
	return to_local(_eye_camera().global_position)


## Flying, at a TERRAIN-frame position (the gates' placements).
func _fly_to(at: Vector3, facing: Vector3) -> void:
	walker.place(to_global(at), facing)


## The eye where it is drawn (global): the one to place nodes from.
func _eye_render() -> Vector3:
	return _eye_camera().global_position


# ---------------------------------------------------------------------------
# Origin shift (Docs/MineWorld.md 15). Positions are float32: past ~20 km
# from the origin the precision shows. When the eye is SHIFT_AT from the
# global origin, this node and everything in it moves back by whole tiles
# (PlanetFrame.shift, the planet's own). Inside it nothing changes: every
# child keeps its local position, which is its terrain position, and the
# field (integer studs and plates) never knew. Only a global position used
# as a terrain one needs to_local, and a terrain one used to place a node
# to_global.

## Metres from the global origin that start a shift (a gate lowers it).
var shift_at := 4000.0
## The terrain-frame position of the global origin: the sum of the shifts.
var origin_shift := Vector3.ZERO
var shifts := 0


func _origin_step() -> void:
	var g := _eye_render()
	if Vector2(g.x, g.z).length() < shift_at:
		return
	# Whole tiles, so anything patterned on the stud lattice in world space
	# (the printed surface, the grid light) lines up as before.
	var tile_m := float(BrickTerrain.get_tile_studs()) * BrickWorld.get_stud_metres()
	var d := Vector3(roundf(g.x / tile_m) * tile_m, 0.0, roundf(g.z / tile_m) * tile_m)
	PlanetFrame.shift(get_parent(), -d)
	origin_shift += d
	shifts += 1
	print("[mine] origin shift %d: %s m, the global origin is now terrain %s" % [shifts, -d, origin_shift])


## The gun hit the ground: it breaks WHOLE BRICKS there -- the surface piece
## hit, or the one brick of a wall -- and throws it (BrickTerrain.break_brick,
## Docs/MineWorld.md 10). A sphere of plate cells cut bricks in pieces and the
## rebuilt tile re-laid the bricks round it, which read as the ground being
## regenerated rather than broken.
func _mine(point: Vector3, dir: Vector3, _info) -> void:
	if chests != null and chests.shot(to_local(point)):
		return
	if collapse != null and collapse.shoot(point, dir, _info):
		return
	if _break_jobs.size() >= MAX_BREAK_JOBS:
		return
	var holder := [{}]
	var n := -dir
	var at := to_local(point)
	var task := WorkerThreadPool.add_task(
		func() -> void: holder[0] = BrickTerrain.find_brick(at, n), false, "break brick")
	_break_jobs.append([task, holder, at - dir * 0.6])


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
		# What a shot destroys is gone (the user, 2026-11-20): no brick thrown.
		# What it leaves hanging falls -- the collapse, from terrain_edited.
		terrain_edited(res)


func _wait_breaks() -> void:
	for job in _break_jobs:
		WorkerThreadPool.wait_for_task_completion(job[0])
	_break_jobs.clear()


## The field changed (a shot, a block broken or placed): rebake the tiles it
## names behind the old ones, and the far blocks over them.
func terrain_edited(res: Dictionary) -> void:
	water.terrain_changed(res)
	if chests != null:
		chests.check()
	if drops != null:
		drops.wake()
	if _deep != null and res.has("box_lo"):
		_deep.refresh_box(res.box_lo, res.box_hi)
	if collapse != null:
		collapse.queue(res)
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


## No tile over `rect` (tiles) waits to be rebuilt: what fell from it is drawn
## on its own once the tile no longer draws it (ground_collapse.gd).
func tiles_fresh(rect: Rect2i) -> bool:
	if _streamer == null:
		return true
	if _pending_tiles.has_area() and rect.has_area() and _pending_tiles.intersects(rect):
		return false
	return _streamer.fresh(rect)


## Is tile `t` in the near-detail tier (LOD 0)? Settled pieces elsewhere are
## unloaded (Docs/TerrainCollapse.md 5).
func near_tile(t: Vector2i) -> bool:
	return _streamer != null and _streamer.has_tile(t)


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

## SLOW FRAMES, for the F3 readout (Docs/MineWorld.md 14): frames over
## SLOW_FRAME_MS in the last 10 s, and what the world's own systems took in
## the last one -- the previous frame's parts (_ptimes, trees, water, ground
## collapse), CPU clocks only (no renderer read-backs in play). Small parts in
## a slow frame mean the time went elsewhere: the GPU, the editor (playing in
## the editor's game view, its debugger mirrors every node the world adds), or
## a vsync miss.
const SLOW_FRAME_MS := 25.0
var _slow_at: Array[int] = []
var _slow_last := ""


func _note_slow(delta: float) -> void:
	var ms := delta * 1000.0
	var now := Time.get_ticks_msec()
	while not _slow_at.is_empty() and now - _slow_at[0] > 10000:
		_slow_at.pop_front()
	if ms < SLOW_FRAME_MS or _streamer == null:
		return
	_slow_at.append(now)
	var parts := {"near": float(_ptimes.get("near", 0.0)), "deep": float(_ptimes.get("deep", 0.0)),
			"far": float(_ptimes.get("far", 0.0)) + float(_ptimes.get("reanchor", 0.0)),
			"trees": _trees.last_us / 1000.0 if _trees != null else 0.0,
			"water": water.last_us / 1000.0, "ground": collapse.last_us / 1000.0 if collapse != null else 0.0}
	var sum := 0.0
	for k in parts:
		sum += float(parts[k])
	_slow_last = "%.0f ms: world %.1f ms (near %.1f deep %.1f far %.1f trees %.1f water %.1f ground %.1f)%s" % [
			ms, sum, parts.near, parts.deep, parts.far, parts.trees, parts.water, parts.ground,
			"" if sum > ms * 0.4 else " -- the rest outside the world: GPU / editor / vsync"]


func _slow_line() -> String:
	if _slow_at.is_empty():
		return "slow frames (> %.0f ms) in 10 s: none" % SLOW_FRAME_MS
	return "slow frames (> %.0f ms) in 10 s: %d; last %s" % [SLOW_FRAME_MS, _slow_at.size(), _slow_last]


## FAST FLIGHT HOLD (Docs/MineWorld.md 14), after zylanntest's
## DynamicLodController: above FAST_HOLD_MPS the near tier starts no new
## bakes (nor studs, chamfer, collision) and the far tier no new refines or
## relods; what is drawn stays. Below FAST_RESUME_MPS it all resumes. Flying
## at the default 50 m/s is not held; Shift (500 m/s) is. -- --no-fast-hold
## turns it off (A/B).
const FAST_HOLD_MPS := 80.0
const FAST_RESUME_MPS := 40.0
var fast_hold := false
## Pre-warmed instance nodes waiting to go into the pool (TerrainTile.prewarm).
## Sized by --gate=spawn (2026-11-19): from the first loaded square to the full
## resident set, 600 frames at 30 m/s made 194 far-stud, 185 pebble and 45
## near-stud nodes new.
const PREWARM_PER_KIND := {"StudsFar": 220, "Pebbles": 220, "Studs": 56, "Tufts": 220}
var prewarm_ms := 0.0
var _warm_frame_ms := 0.0
var _warm: Array = []
var _warm_frames := 0
var _prewarm_on := not ("--no-prewarm" in OS.get_cmdline_user_args())
## The underground light factor last frame (_day_night): 1 in the open.
var _cave_light := 1.0
## The light left deep underground (x the open-air light), and the A/B switch
## for the old fade (12 % from 7.5 m down, sky untouched).
const CAVE_DEEP_LIGHT := 0.015
var _old_cave_light := "--old-cave-light" in OS.get_cmdline_user_args()
var _reflecting := true
## This frame's main-thread costs, ms (the flight gate prints slow frames').
var _ptimes := {}
var _speed := 0.0
var _speed_from := Vector3.INF
var _fast_hold_on := not ("--no-fast-hold" in OS.get_cmdline_user_args())


func _speed_step(eye: Vector3, delta: float) -> void:
	var moved := eye.distance_to(_speed_from) if _speed_from != Vector3.INF else 0.0
	_speed_from = eye
	# A jump (placed, teleported, a new world) is not speed: the ground there
	# is wanted at once.
	var inst := 0.0 if moved > 150.0 else moved / maxf(delta, 0.001)
	_speed = lerpf(_speed, inst, 1.0 - exp(-delta / 0.2))
	var hold := fast_hold
	if _speed > FAST_HOLD_MPS:
		hold = _fast_hold_on
	elif _speed < FAST_RESUME_MPS:
		hold = false
	if hold != fast_hold:
		fast_hold = hold
		_streamer.hold = hold
		_deep.hold = hold
		_far.hold = hold
		if _far_next != null:
			_far_next.hold = hold


func _process(delta: float) -> void:
	_frame_ms = lerpf(_frame_ms, delta * 1000.0, 0.1)
	_note_slow(delta)
	if _streamer == null:
		return
	if _warm_frames > 0:
		_warm_frames -= 1
		_warm_frame_ms += delta * 1000.0
		if _warm_frames == 0:
			print("[mine] instance pool pre-filled: %d nodes, %.0f ms to add, %.0f ms over the next 3 frames"
					% [_warm.size(), prewarm_ms, _warm_frame_ms])
			TerrainTile.prewarm_end(_warm)
			_warm = []
	_origin_step()
	var eye := _eye()
	_speed_step(eye, delta)
	_land_breaks()
	_refresh_in -= delta
	if _refresh_in <= 0.0:
		_flush_edits()
	var p0 := Time.get_ticks_usec()
	_streamer.follow(Vector2(eye.x, eye.z))
	var pd := Time.get_ticks_usec()
	_deep.follow(eye)
	var p1 := Time.get_ticks_usec()
	_far.cover(_streamer, false)
	_far.relod(eye, false)
	var p2 := Time.get_ticks_usec()
	var re0 := _reanchors
	_follow_far(eye)
	var p3 := Time.get_ticks_usec()
	_ptimes = {"near": (pd - p0) / 1000.0, "deep": (p1 - pd) / 1000.0, "far": (p2 - p1) / 1000.0,
			"reanchor": (p3 - p2) / 1000.0, "swapped": _reanchors != re0}
	if not on_foot:
		FpsRig.follow_flight(cam, walker)
	if not on_foot and walker.global_position.y < -500.0:
		walker.place(to_global(Vector3(eye.x, 200.0, eye.z)), Vector3.FORWARD)
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
			_far_next.hold = fast_hold
			_far_next.visible = false
			if not _far_next.build_begin(_far_tiles(), _mat, Rect2i(), _streamer.align):
				_far_next.queue_free()
				_far_next = null
		return
	# A slice a frame: the new tier is hidden until it is all in.
	if not _far_next.build_poll(2.0):
		return
	var t0 := Time.get_ticks_usec()
	_far_next.cover(_streamer)
	_far_next.visible = true
	remove_child(_far)
	_far.queue_free()
	_far = _far_next
	_far.hold = fast_hold
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
	if not _old_cave_light:
		# On down past 7.5 m to CAVE_DEEP_LIGHT at 30 m: the deep caves
		# (Docs/MineWorld.md 16) were lit like a shaded street.
		# Only DOWN there: above ground `under` is negative, the curve sat at
		# its 0.12 start and every daytime scene was cave-dark.
		if under > 7.5:
			cave = minf(cave, lerpf(0.12, CAVE_DEEP_LIGHT, clampf((under - 7.5) / 22.5, 0.0, 1.0)))
			cave = maxf(cave, CAVE_DEEP_LIGHT)
	_cave_light = cave
	_rig.env.ambient_light_energy *= cave
	# The ground casts no sun shadow, so the sun would reach into caves: it
	# fades with depth the way the ambient does.
	_rig.sun.light_energy *= cave
	if not _old_cave_light:
		# And the sky: the bricks REFLECT it (the environment's reflections
		# come from the sky, not the ambient), which the ambient's fade
		# never touched.
		_rig.sky_mat.sky_energy_multiplier *= cave
		# Measured (--gate=deep --light-sweep, 2026-11-19): with ambient, sun
		# and sky all at 3 %, the sky's reflections still lit the cave as
		# much as the ambient did -- the reflection map does not follow the
		# sky's energy. Underground there is no sky to reflect.
		var reflect := cave >= 0.3
		if reflect != _reflecting:
			_reflecting = reflect
			_rig.env.reflected_light_source = Environment.REFLECTION_SOURCE_BG if reflect 					else Environment.REFLECTION_SOURCE_DISABLED
		# The ambient too: a third of it came from the sky's own light map,
		# and a wall facing sideways saw the bright horizon in it. That share
		# fades out as the cave light goes from open air to 12 %.
		_rig.env.ambient_light_sky_contribution = LightRig.AMBIENT_SKY 				* clampf((cave - 0.12) / 0.88, 0.0, 1.0)
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
		KEY_M:
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
	# A MenuScreen: full screen, dimmed backdrop that takes every click.
	_menu = Menu.new()
	_menu.name = "WorldGenMenu"
	_menu.setup(self)
	_menu_layer.add_child(_menu)
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


## The inventory screen (E or Tab from the items hands). Unlike the world
## generation menu the world keeps running, Minecraft's way: the screen takes
## every key while open (InventoryScreen._input), the mouse is freed the
## camera's own way (so the pawn's controller and the arsenal, which act only
## on a captured mouse, go quiet), and the flight is held (`walker.frozen`:
## it reads WASD itself). On foot the pawn still falls, swims, is hit.
func toggle_inventory() -> void:
	if _inv_screen != null:
		_inv_screen.close_screen()
		return
	if _menu != null:
		return
	_inv_prev_mouse = Input.mouse_mode
	_inv_layer = CanvasLayer.new()
	_inv_layer.name = "InventoryLayer"
	_inv_layer.layer = 70
	_inv_layer.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_inv_layer)
	_inv_screen = InventoryScreen.new()
	_inv_screen.name = "InventoryScreen"
	_inv_screen.setup(builder.inv, self)
	_inv_layer.add_child(_inv_screen)
	# The hotbars are in the screen; the HUD behind it would only clutter it.
	_hud_layer.visible = false
	if walker != null:
		_inv_walker_frozen = walker.frozen
		if not on_foot:
			walker.frozen = true
	_inv_cam_captured = cam != null and bool(cam.get("_captured"))
	if cam != null:
		cam._set_captured(false)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func inventory_closed() -> void:
	_inv_screen = null
	builder.inv.close_chest()
	_hud_layer.visible = true
	if _inv_layer != null:
		_inv_layer.queue_free()
		_inv_layer = null
	if walker != null:
		walker.frozen = _inv_walker_frozen
	if PlayerCamera.hands_off:
		return
	if _inv_cam_captured and cam != null:
		cam._set_captured(true)
	elif _inv_prev_mouse == Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func inventory_open() -> bool:
	return _inv_screen != null


## RMB on a chest: its slots borrowed by the inventory, the screen open on it.
func open_chest(key: String) -> void:
	if chests == null or not chests.chests.has(key):
		return
	if _inv_screen != null:
		_inv_screen.close_screen()
	builder.inv.open_chest(key, chests.slots_of(key))
	toggle_inventory()


## Where the player stands, in the terrain frame (dropped items, chests).
func player_feet_local() -> Vector3:
	if on_foot and pawn != null:
		return to_local(pawn.feet())
	if walker != null:
		return to_local((walker as Node3D).global_position)
	return Vector3.INF


## A stack thrown from the player (Q in the screen, a held stack with no
## room on close): it lands a little in front.
func drop_from_player(s: ItemStack) -> void:
	if drops == null or s == null:
		return
	var feet := player_feet_local()
	if feet == Vector3.INF:
		return
	var fwd := Vector3.FORWARD
	if cam != null:
		var f := to_local(cam.global_position - cam.global_transform.basis.z) - to_local(cam.global_position)
		fwd = Vector3(f.x, 0, f.z).normalized() if Vector3(f.x, 0, f.z).length() > 0.01 else fwd
	drops.spawn(s, feet + Vector3(0, 1.2, 0) + fwd * 0.4, fwd * 3.0 + Vector3(0, 1.5, 0))


## The world menu's Survival box (Docs/Inventory.md 7): this world's game
## mode, at once, saved with its changes.
func set_survival(on: bool) -> void:
	survival = on
	builder.inv.creative = not on
	builder.inv.changed.emit()
	_world_dirty = true
	print("[mine] game mode: %s" % ("survival" if on else "creative"))


## A chest or a dropped item changed: the save is out of date.
func world_items_changed() -> void:
	_world_dirty = true


# ---------------------------------------------------------------------------
# The pause menu (Escape): the game's own (menu/core/MenuManager.gd), allowed
# here through terrain_scene.gd and BrickcityMenuHost's scene hooks.

## The menu gate turns this on to open the pause menu the player's way.
var _gate_pause_ok := false


func pause_allowed() -> bool:
	return (not _gate or _gate_pause_ok) and _menu == null and _inv_screen == null


## Entries this scene adds to the pause menu.
func pause_menu_entries() -> Array:
	return [{"label": "World generation...", "tooltip": "Change how the world is generated (M).",
		"action": func() -> void:
			MenuManager.close_pause()
			toggle_menu()}]


## The pause menu closed: MenuManager has put the mouse mode back; the camera
## is told too, so its own idea of being captured agrees.
func pause_closed() -> void:
	if PlayerCamera.hands_off or _menu != null:
		return
	if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and on_foot and cam != null:
		cam._set_captured(true)


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


## The water, beside the edits (Docs/MineWater.md 11): each cell that differs
## from the world as generated (BrickFluid.get_save), loaded after the edits
## and every cell woken, so a river that was running runs on.
const FLUID_MAGIC := "BCWF"
const FLUID_FORMAT := 1
## BrickFluid.change_count() when the water was last written.
var _fluid_saved_at := -1


static func _fluid_path(edits_path: String) -> String:
	return edits_path.get_basename() + ".fluid"


func _load_fluid() -> int:
	var path := _fluid_path(save_path())
	if not FileAccess.file_exists(path):
		return 0
	var f := FileAccess.open_compressed(path, FileAccess.READ, FileAccess.COMPRESSION_ZSTD)
	if f == null or f.get_buffer(4).get_string_from_ascii() != FLUID_MAGIC or f.get_32() != FLUID_FORMAT:
		push_warning("[mine] %s is from another format; not loaded" % path)
		return 0
	var n := f.get_32()
	return BrickFluid.set_save(f.get_buffer(n))


## The pieces that came off the ground, beside the edits (Docs/TerrainCollapse.md 5).
const PIECES_MAGIC := "BCMP"
const PIECES_FORMAT := 1


static func _pieces_path(edits_path: String) -> String:
	return edits_path.get_basename() + ".pieces"


## The blocks the player laid, each one brick (BrickTerrain.mark_placed,
## Docs/TerrainBond.md 1): 4 ints a cell, beside the edits. No file: none.
const PLACED_MAGIC := "BCPB"
const PLACED_FORMAT := 1


static func _placed_path(edits_path: String) -> String:
	return edits_path.get_basename() + ".placed"


func _load_placed() -> void:
	var path := _placed_path(save_path())
	if not FileAccess.file_exists(path):
		return
	var f := FileAccess.open_compressed(path, FileAccess.READ, FileAccess.COMPRESSION_ZSTD)
	if f == null or f.get_buffer(4).get_string_from_ascii() != PLACED_MAGIC or f.get_32() != PLACED_FORMAT:
		push_warning("[mine] %s is from another format; not loaded" % path)
		return
	var n := f.get_32()
	var cells := f.get_buffer(n).to_int32_array()
	BrickTerrain.set_placed(cells)


func _load_pieces() -> void:
	var path := _pieces_path(save_path())
	if not FileAccess.file_exists(path):
		return
	var f := FileAccess.open_compressed(path, FileAccess.READ, FileAccess.COMPRESSION_ZSTD)
	if f == null or f.get_buffer(4).get_string_from_ascii() != PIECES_MAGIC or f.get_32() != PIECES_FORMAT:
		push_warning("[mine] %s is from another format; not loaded" % path)
		return
	var n := f.get_32()
	var saved = bytes_to_var(f.get_buffer(n))
	if saved is Array:
		collapse.restore(saved)


## The player's items, beside the edits (Docs/Inventory.md 3.2): JSON, the
## inventory's own `to_dict`. No file: the starting kit.
var _inv_dirty := false
## The world's own items (chests, drops) or its mode changed (Docs/Inventory.md 6-7).
var _world_dirty := false
## The inventory came from the character already: a world generated after
## keeps it.
var _inv_loaded := false
## This world's game mode (Docs/Inventory.md 7): saved in its world file.
var survival := false


static func _inventory_path(edits_path: String) -> String:
	return edits_path.get_basename() + ".inv"


func _load_inventory() -> void:
	var path := _inventory_path(save_path())
	var world = null
	if FileAccess.file_exists(path):
		world = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (world is Dictionary):
		world = {}
	var inv: Inventory = builder.inv
	var first := not _inv_loaded
	if first:
		# The character's own (Docs/Inventory.md 6), once: after this the same
		# inventory goes from world to world with the player.
		inv = Inventory.new()
		var ok := inv.from_dict(CharacterSave.load_from(character_path()).items)
		var how := "the character's"
		if not ok and world.has("hotbar_0"):
			# A world file from before stage 6 held the inventory: it is the
			# character's now (once -- the character has one from then on).
			ok = inv.from_dict(world)
			how = "taken from the old world file"
			_inv_dirty = true
		if not ok:
			inv.seed_default()
			how = "the starting kit"
		print("[mine] inventory: %s" % how)
		if builder.inv.changed.is_connected(_on_inventory_changed):
			builder.inv.changed.disconnect(_on_inventory_changed)
		builder.set_inventory(inv)
		inv.changed.connect(_on_inventory_changed)
		_inv_loaded = true
	# The world's game mode (stage 7). A file from before kept the inventory's
	# own "creative" flag.
	survival = bool(world.get("survival", not bool(world.get("creative", true))))
	inv.creative = not survival
	if first and how_kit_added(inv):
		_inv_dirty = true
	if chests != null:
		chests.inv = inv
		chests.restore(world.get("chests", {}))
	if drops != null:
		drops.inv = inv
		drops.restore(world.get("drops", []))
	_world_dirty = false
	builder._refresh_bar()


## Kit added since a save was made (creative only: a survival player who
## used theirs up must not get more each load). True if anything was added.
func how_kit_added(inv: Inventory) -> bool:
	if not inv.creative:
		return false
	var added := false
	if inv.ensure_item(&"mega_pickaxe", &"pickaxe"):
		print("[mine] Mega Pickaxe added to the inventory")
		added = true
	if inv.ensure_item(&"chest", &"mega_pickaxe"):
		print("[mine] chests added to the inventory")
		added = true
	return added


## Where the character (and so the inventory) is kept: the player's file, or
## a scripted pass's own.
const GATE_CHARACTER := UserPaths.DEV + "character_gate.json"


func character_path() -> String:
	return GATE_CHARACTER if _gate else CharacterSave.PATH


## The inventory into the character file: read it, change only `items`,
## write it (PlayerKit does the same with the guns and the level, so neither
## loses the other's). A small file, on this thread, only when it changed.
func save_character() -> void:
	var s := CharacterSave.load_from(character_path())
	s.items = builder.inv.to_dict()
	DirAccess.make_dir_recursive_absolute(character_path().get_base_dir())
	s.save(character_path())


func _on_inventory_changed() -> void:
	_inv_dirty = true


## The items' icons and spin frames, rendered once as the scene loads
## (ItemIcons: one render, no read-back); the HUD redraws with them.
func _build_item_icons() -> void:
	var t0 := Time.get_ticks_usec()
	await ItemIcons.build(self)
	print("[mine] item icons: %s in %.0f ms" % ["%d items x %d frames" % [ItemCatalog.ids().size(),
			ItemIcons.FRAMES] if ItemIcons.ready else "none (no renderer)", (Time.get_ticks_usec() - t0) / 1000.0])
	if builder != null:
		builder._refresh_bar()


## Write the changes if there are any unsaved. `wait`: now, on this thread
## (leaving, generating); otherwise on a worker, checked next frame.
func save_edits(wait := false) -> void:
	if _save_task >= 0:
		if not wait and not WorkerThreadPool.is_task_completed(_save_task):
			return
		WorkerThreadPool.wait_for_task_completion(_save_task)
		_save_task = -1
	var fluid_at := BrickFluid.change_count()
	if (not _edits_dirty and not _inv_dirty and not _world_dirty and fluid_at == _fluid_saved_at) \
			or settings.is_empty():
		return
	_edits_dirty = false
	_world_dirty = false
	if _inv_dirty:
		_inv_dirty = false
		save_character()
	# The world file: only what is the world's (stage 6).
	var inv_save := {"format": 2, "survival": survival}
	if chests != null:
		inv_save["chests"] = chests.to_save()
	if drops != null:
		inv_save["drops"] = drops.to_save()
	var inv_text := JSON.stringify(inv_save, "\t")
	_fluid_saved_at = fluid_at
	var bytes: PackedByteArray = BrickTerrain.get_edits()
	var fluid_bytes: PackedByteArray = BrickFluid.get_save()
	var piece_bytes := var_to_bytes(collapse.to_save())
	var placed_bytes := BrickTerrain.get_placed().to_byte_array()
	var path := save_path()
	var dir := _save_dir()
	var field := BrickTerrain.get_field_version()
	var write := func() -> void:
		DirAccess.make_dir_recursive_absolute(dir)
		var ip := _inventory_path(path)
		var iv := FileAccess.open(ip + ".tmp", FileAccess.WRITE)
		if iv != null:
			iv.store_string(inv_text)
			iv.close()
			DirAccess.rename_absolute(ip + ".tmp", ip)
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
		var pp := _pieces_path(path)
		var g := FileAccess.open_compressed(pp + ".tmp", FileAccess.WRITE, FileAccess.COMPRESSION_ZSTD)
		if g == null:
			return
		g.store_buffer(PIECES_MAGIC.to_ascii_buffer())
		g.store_32(PIECES_FORMAT)
		g.store_32(piece_bytes.size())
		g.store_buffer(piece_bytes)
		g.close()
		DirAccess.rename_absolute(pp + ".tmp", pp)
		var bp := _placed_path(path)
		var pb := FileAccess.open_compressed(bp + ".tmp", FileAccess.WRITE, FileAccess.COMPRESSION_ZSTD)
		if pb != null:
			pb.store_buffer(PLACED_MAGIC.to_ascii_buffer())
			pb.store_32(PLACED_FORMAT)
			pb.store_32(placed_bytes.size())
			pb.store_buffer(placed_bytes)
			pb.close()
			DirAccess.rename_absolute(bp + ".tmp", bp)
		var fp := _fluid_path(path)
		var h := FileAccess.open_compressed(fp + ".tmp", FileAccess.WRITE, FileAccess.COMPRESSION_ZSTD)
		if h == null:
			return
		h.store_buffer(FLUID_MAGIC.to_ascii_buffer())
		h.store_32(FLUID_FORMAT)
		h.store_32(fluid_bytes.size())
		h.store_buffer(fluid_bytes)
		h.close()
		DirAccess.rename_absolute(fp + ".tmp", fp)
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
	if FileAccess.file_exists(_pieces_path(path)):
		DirAccess.remove_absolute(_pieces_path(path))
	if FileAccess.file_exists(_placed_path(path)):
		DirAccess.remove_absolute(_placed_path(path))
	if FileAccess.file_exists(_fluid_path(path)):
		DirAccess.remove_absolute(_fluid_path(path))
	if FileAccess.file_exists(_inventory_path(path)):
		DirAccess.remove_absolute(_inventory_path(path))
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
		_hud.text = "F3 readout  M world generation"
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
		"deep  %s" % _deep.report(),
		_slow_line(),
		"far   %d blocks, %d hidden, %.0fk tris, anchor %s, re-centred %d (%.0f ms)" % [
				_far.block_count(), _far.hidden_count(), _far.triangle_count() / 1000.0,
				_far.anchor, _reanchors, _last_reanchor_ms],
		"trees %d   edits %d   generated in %.0f ms" % [_trees.count if _trees != null else 0,
				BrickTerrain.get_edit_count(), _gen_ms],
		"blocks placed %d  broken %d   %s" % [builder.placed, builder.broken, _save_status],
		"water %s" % water.report(),
		collapse.readout(),
		"%s   F fly/walk  B guns/items  M world generation  F3 readout  T +1 hour" % ("ON FOOT" if on_foot
				else "FLYING %.0f m/s (wheel), moving %.0f m/s%s" % [walker.fly_speed, _speed,
				"  DETAIL HELD" if fast_hold else ""]),
	])


# ---------------------------------------------------------------------------
# The scripted pass: -- --gate. Pictures to user://dev/, numbers to the log.

## -- --gate=menu: the world generation menu clicked the way a player clicks
## it -- real mouse events through the engine's input -- and what the click
## reached. A button must act; a click on the panel's empty part must not
## turn the camera or reach the game.
func _run_menu_gate() -> void:
	await _frames(20)
	toggle_menu()
	await _frames(10)
	var zoom: Button = null
	for b in _menu.find_children("*", "Button", true, false):
		if (b as Button).text == "Zoom in":
			zoom = b
	var before: int = _menu.get("_map_step")
	var at := zoom.get_global_rect().get_center()
	await _click(at)
	var hovered := get_viewport().gui_get_hovered_control()
	print("[mine-menu] click on 'Zoom in' at %s: map step %d -> %d, hovered %s" % [at, before,
			_menu.get("_map_step"), hovered.get_path() if hovered != null else "nothing"])
	var look := cam.global_transform.basis
	var empty := (_menu as Control).get_global_rect().position + Vector2(20, 300)
	await _click(empty)
	hovered = get_viewport().gui_get_hovered_control()
	print("[mine-menu] click on the panel's empty part at %s: camera turned %s, hovered %s, menu open %s"
			% [empty, not look.is_equal_approx(cam.global_transform.basis),
			hovered.get_path() if hovered != null else "nothing", _menu != null])
	var key := InputEventKey.new()
	key.keycode = KEY_M
	key.physical_keycode = KEY_M
	key.pressed = true
	Input.parse_input_event(key)
	await _frames(2)
	key = key.duplicate()
	key.pressed = false
	Input.parse_input_event(key)
	await _frames(2)
	print("[mine-menu] M again: menu open %s, world running %s" % [_menu != null, can_process()])
	# The pause menu: Escape, then its "World generation..." entry.
	_gate_pause_ok = true
	await _key(KEY_ESCAPE)
	var mm := get_node_or_null(^"/root/MenuManager")
	var paused_open: bool = mm != null and bool(mm.call("is_open"))
	var entry: Button = null
	for b in get_tree().root.find_children("*", "Button", true, false):
		if (b as Button).text.begins_with("World generation") and (b as Button).is_visible_in_tree():
			entry = b
	print("[mine-menu] Escape: pause menu open %s, tree paused %s, entry found %s" % [paused_open,
			get_tree().paused, entry != null])
	if entry != null:
		await _click(entry.get_global_rect().get_center())
		print("[mine-menu] clicked 'World generation...': pause menu open %s, generation menu open %s, tree paused %s"
				% [bool(mm.call("is_open")), _menu != null, get_tree().paused])
		if _menu != null:
			toggle_menu()
	await _menu_small_window_check()
	get_tree().quit()


## The menu on a small window: Generate world inside the viewport, nothing
## cut off (MenuFit.audit, as the Options menu's fit test), and a real click
## on it builds a new world.
func _menu_small_window_check() -> void:
	var win := get_window()
	var size0 := win.size
	for small in [Vector2i(800, 450), Vector2i(640, 400)]:
		win.size = small
		await _frames(10)
		toggle_menu()
		await _frames(10)
		var vp := get_viewport().get_visible_rect()
		var gen: Button = _menu.call("generate_button")
		var r := gen.get_global_rect()
		var cut: Array = MenuFit.audit(_menu, vp)
		print("[mine-menu] window %s (viewport %s): Generate world at %s, inside %s, cut off %d%s" % [
				small, vp.size, r, vp.encloses(r), cut.size(),
				"" if cut.is_empty() else "
" + MenuFit.describe(cut)])
		await _shot(UserPaths.DEV + "mine_menu_%dx%d.png" % [small.x, small.y])
		if small.x == 640:
			var seed0 := int(settings.seed)
			var ms0 := _gen_ms
			_gen_ms = -1.0
			await _click(r.get_center())
			await _frames(5)
			print("[mine-menu] clicked Generate world: menu open %s, regenerated %s (%.0f ms, seed %d -> %d), world running %s"
					% [_menu != null, _gen_ms >= 0.0, _gen_ms, seed0, int(settings.seed), can_process()])
			if _gen_ms < 0.0:
				_gen_ms = ms0
		if _menu != null:
			toggle_menu()
			await _frames(3)
	win.size = size0
	await _frames(5)


func _key(code: Key) -> void:
	for down in [true, false]:
		var k := InputEventKey.new()
		k.keycode = code
		k.physical_keycode = code
		k.pressed = down
		Input.parse_input_event(k)
		await _frames(3)


## -- --gate=inventory (Docs/Inventory.md 5): the items hands and the
## inventory screen driven the player's way -- real key and mouse events
## through the engine's input. B, E; the Creative tab; a catalog item taken
## and put in hotbar 2; a stack spread over three slots by a drag; Escape puts
## the held stack back; 1-9 over a slot sends it to the hotbar; the screen
## fits 640x400 (MenuFit.audit); E closes; X and 3 put hotbar 2's item in the
## hand and RMB places it; the inventory comes back after saving and
## generating the world again. Prints INV-GATE PASS/FAIL.
func _run_inventory_gate() -> void:
	var fails: Array[String] = []
	var check := func(what: String, ok: bool) -> void:
		print("[inv-gate] %s %s" % ["ok  " if ok else "FAIL", what])
		if not ok:
			fails.append(what)
	await _frames(30)
	var e := _eye()
	var stud := BrickWorld.get_stud_metres()
	var c := Vector2i(floori(e.x / stud), floori(e.z / stud))
	var g := _ground_m(c.x, c.y)
	set_on_foot(false)
	_fly_to(Vector3(e.x, g + 2.4, e.z), Vector3(0, 0, -1))
	walker.pitch = -0.75
	await _frames(20)
	builder.gate_keys = true
	var inv: Inventory = builder.inv
	var waited := 0
	while not ItemIcons.ready and waited < 120:
		await _frames(1)
		waited += 1
	check.call("item icons rendered at load (stage 4)", ItemIcons.ready and ItemIcons.has_icon(&"granite")
			and ItemIcons.has_icon(&"bucket"))
	await _key(KEY_B)
	check.call("B: the items hands", builder.active)
	await _key(KEY_E)
	check.call("E: the inventory screen opens", inventory_open())
	await _frames(5)
	var scr := _inv_screen
	var tab: Button = scr.get("_tab_creative")
	await _click(tab.get_global_rect().get_center())
	check.call("the Creative tab shows the catalog", scr.page == "creative")
	await _click(_inv_slot(scr, {}, &"granite").get_global_rect().get_center())
	check.call("a catalog item comes onto the cursor, a full stack",
			inv.cursor != null and inv.cursor.id == &"granite" and inv.cursor.count == 64)
	await _click(_inv_slot(scr, Inventory.addr(&"hotbar_1", 2)).get_global_rect().get_center())
	check.call("... and swaps with what hotbar 2 slot 3 held (water source now held)",
			inv.hotbars[1][2] != null and inv.hotbars[1][2].id == &"granite"
			and inv.cursor != null and inv.cursor.id == &"water_source")
	await _shot(UserPaths.DEV + "inv_creative.png")
	# The slot under the mouse spins (zylanntest's hover): a moment later it
	# shows another frame.
	var spun: InvSlot = _inv_slot(scr, Inventory.addr(&"hotbar_1", 2))
	var a0: float = spun.get("_angle")
	await _frames(20)
	var a1: float = spun.get("_angle")
	check.call("the hovered slot spins (%.2f -> %.2f rad)" % [a0, a1], absf(wrapf(a1 - a0, -PI, PI)) > 0.2)
	await _shot(UserPaths.DEV + "inv_spin.png")
	await _click(_inv_slot(scr, {}, &"dirt").get_global_rect().get_center())
	check.call("a held stack clicked on the catalog is thrown away", inv.cursor == null)
	# A left drag spreads a stack: sand over the first three storage slots
	# (storage starts empty; the hotbars are the kit's).
	await _click(_inv_slot(scr, {}, &"sand").get_global_rect().get_center())
	await _shot(UserPaths.DEV + "inv_held.png")
	var tab_s: Button = scr.get("_tab_storage")
	await _click(tab_s.get_global_rect().get_center())
	check.call("the Storage tab, the stack still held", scr.page == "storage" and inv.cursor != null)
	var pts: Array[Vector2] = []
	for i in [0, 1, 2]:
		pts.append(_inv_slot(scr, Inventory.addr(&"main", i)).get_global_rect().get_center())
	await _gate_drag(pts)
	var spread := [inv.main[0], inv.main[1], inv.main[2]]
	check.call("a left drag spreads 64 sand over 3 slots (21 each, 1 held)",
			spread.all(func(s): return s != null and s.id == &"sand" and s.count == 21)
			and inv.cursor != null and inv.cursor.count == 1)
	var held_before := inv.cursor != null
	await _key(KEY_ESCAPE)
	check.call("Escape with a stack held puts it back and keeps the screen open",
			held_before and inv.cursor == null and inventory_open())
	if not inventory_open():
		print("[inv-gate] INV-GATE FAIL: the screen closed early")
		get_tree().quit(1)
		return
	check.call("... onto its own kind first (storage slot 1: 22)",
			inv.main[0] != null and inv.main[0].count == 22)
	# Left click picks a stack up, left click on an empty slot puts it down.
	await _click(_inv_slot(scr, Inventory.addr(&"main", 2)).get_global_rect().get_center())
	await _click(_inv_slot(scr, Inventory.addr(&"main", 5)).get_global_rect().get_center())
	var moved: bool = inv.main[2] == null and inv.main[5] != null and inv.main[5].id == &"sand" and inv.cursor == null
	check.call("a stack picked up and put down in another slot", moved)
	if moved:
		var over := _inv_slot(scr, Inventory.addr(&"main", 5)).get_global_rect().get_center()
		var m := InputEventMouseMotion.new()
		m.position = over
		m.global_position = over
		Input.parse_input_event(m)
		await _frames(2)
		await _key(KEY_9)
		check.call("9 over a storage slot sends it to hotbar 1 slot 9 (its terracotta to storage)",
				inv.hotbars[0][8] != null and inv.hotbars[0][8].id == &"sand"
				and inv.main[5] != null and inv.main[5].id == &"terracotta")
	# Stage 8: backpacks, real clicks. Off: no storage; parked in a hotbar; a
	# Small one from the catalog on: 9 slots; the Large one back: 27, its
	# contents still in it.
	await _click(_inv_slot(scr, Inventory.addr(&"backpack")).get_global_rect().get_center())
	await _frames(3)
	check.call("the backpack taken off: on the cursor, no storage (%d slots)" % int(scr.get("_storage_n")),
			inv.cursor != null and inv.cursor.id == &"large_backpack" and int(scr.get("_storage_n")) == 0)
	await _click(_inv_slot(scr, Inventory.addr(&"hotbar_1", 8)).get_global_rect().get_center())
	check.call("... put in hotbar 2 slot 9", inv.hotbars[1][8] != null and inv.hotbars[1][8].id == &"large_backpack")
	await _click(tab.get_global_rect().get_center())
	await _click(_inv_slot(scr, {}, &"small_backpack").get_global_rect().get_center())
	await _click(_inv_slot(scr, Inventory.addr(&"backpack")).get_global_rect().get_center())
	await _click(tab_s.get_global_rect().get_center())
	await _frames(3)
	check.call("a Small backpack from the catalog put on: 9 storage slots",
			inv.backpack != null and inv.backpack.id == &"small_backpack" and int(scr.get("_storage_n")) == 9)
	await _shot(UserPaths.DEV + "inv_backpack.png")
	await _click(_inv_slot(scr, Inventory.addr(&"hotbar_1", 8)).get_global_rect().get_center())
	await _click(_inv_slot(scr, Inventory.addr(&"backpack")).get_global_rect().get_center())
	await _click(_inv_slot(scr, Inventory.addr(&"hotbar_1", 8)).get_global_rect().get_center())
	await _frames(3)
	check.call("the Large one swapped back on: 27 slots, its terracotta still in slot 6, the Small one in the hotbar",
			inv.backpack != null and inv.backpack.id == &"large_backpack" and int(scr.get("_storage_n")) == 27
			and inv.main[5] != null and inv.main[5].id == &"terracotta"
			and inv.hotbars[1][8] != null and inv.hotbars[1][8].id == &"small_backpack" and inv.cursor == null)
	# Fits a small window.
	var win := get_window()
	var size0 := win.size
	for small in [Vector2i(800, 450), Vector2i(640, 400)]:
		win.size = small
		await _frames(10)
		var vp := get_viewport().get_visible_rect()
		var cut: Array = MenuFit.audit(scr, vp)
		var close: Button = scr.find_child("Close", true, false)
		check.call("window %s: nothing cut off (%d)%s, Close inside" % [small, cut.size(),
				"" if cut.is_empty() else "\n" + MenuFit.describe(cut)],
				cut.is_empty() and vp.encloses(close.get_global_rect()))
		await _shot(UserPaths.DEV + "inv_%dx%d.png" % [small.x, small.y])
	win.size = size0
	await _frames(10)
	await _key(KEY_E)
	check.call("E closes the screen", not inventory_open())
	# Hotbar 2 into the hand, its third slot, and place it.
	var bar0 := inv.active_hotbar
	await _key(KEY_X)
	await _frames(3)
	check.call("X (tap): the other hotbar", inv.active_hotbar == 1 - bar0)
	if inv.active_hotbar != 1:
		inv.toggle_hotbar()
	await _key(KEY_3)
	check.call("3: granite in the hand", inv.hand() != null and inv.hand().id == &"granite")
	builder.update_target()
	var placed: bool = builder.place_target()
	await _frames(10)
	builder.update_target()
	var names := BrickTerrain.material_names()
	var m_id := int(builder.target.get("material", -1))
	check.call("RMB placed it: the block looked at is %s" % (names[m_id] if m_id >= 0 else "nothing"),
			placed and m_id >= 0 and names[m_id] == "granite")
	await _shot(UserPaths.DEV + "inv_hotbar.png")
	# Stage 5: a chest from the kit (hotbar 2 slot 8), put down on the ground
	# looked straight down at, opened with RMB, filled with real clicks.
	await _key(KEY_8)
	check.call("8: a chest in the hand", inv.hand() != null and inv.hand().id == &"chest")
	walker.pitch = -1.45
	await _frames(10)
	builder.update_target()
	builder.place_target()
	check.call("RMB with a chest puts one down", chests.count() == 1)
	var ckey: String = chests.chests.keys()[0] if chests.count() > 0 else ""
	if ckey != "":
		# A look at it from the side, then back over it.
		var cb: AABB = chests.box_of(chests.chests[ckey].block)
		var over := _eye()
		_fly_to(cb.get_center() + Vector3(1.3, 0.3, 0.4), Vector3(-1, 0, -0.3))
		walker.pitch = -0.35
		await _frames(15)
		await _shot(UserPaths.DEV + "inv_chest_placed.png")
		_fly_to(over - Vector3(0, 1.6, 0), Vector3(0, 0, -1))
		walker.pitch = -1.45
	await _frames(10)
	builder.update_target()
	check.call("the chest is what is looked at", builder.target.get("chest", "") == ckey)
	builder.place_target()
	await _frames(5)
	check.call("RMB on the chest opens it in the screen", inventory_open() and inv.chest_key == ckey
			and ckey != "")
	if inventory_open():
		scr = _inv_screen
		await _click(_inv_slot(scr, Inventory.addr(&"hotbar_0", 0)).get_global_rect().get_center())
		await _click(_inv_slot(scr, Inventory.addr(&"chest", 0)).get_global_rect().get_center())
		var cs: Array = chests.slots_of(ckey)
		check.call("grass clicked from hotbar 1 into the chest", cs.size() > 0 and cs[0] != null
				and (cs[0] as ItemStack).id == &"grass")
		await _shot(UserPaths.DEV + "inv_chest.png")
		win.size = Vector2i(640, 400)
		await _frames(10)
		var vp2 := get_viewport().get_visible_rect()
		var cut2: Array = MenuFit.audit(scr, vp2)
		check.call("the chest screen at 640x400: nothing cut off (%d)" % cut2.size(), cut2.is_empty())
		await _shot(UserPaths.DEV + "inv_chest_640x400.png")
		win.size = size0
		await _frames(10)
		await _key(KEY_E)
	check.call("E closes the chest", not inventory_open() and inv.chest_key == "")
	await _shot(UserPaths.DEV + "inv_chest_world.png")
	# Saved with the world, back after generating it again.
	_edits_dirty = true
	save_edits(true)
	var again := settings.duplicate(true)
	settings = {}
	generate(again)
	await _frames(20)
	inv = builder.inv
	check.call("after generating again: granite in hotbar 2 slot 3, sand in hotbar 1 slot 9, terracotta in storage",
			inv.hotbars[1][2] != null and inv.hotbars[1][2].id == &"granite"
			and inv.hotbars[0][8] != null and inv.hotbars[0][8].id == &"sand"
			and inv.main[5] != null and inv.main[5].id == &"terracotta")
	var back: Array = chests.slots_of(ckey)
	check.call("after generating again: the chest is there, the grass in it", chests.count() == 1
			and back.size() > 0 and back[0] != null and (back[0] as ItemStack).id == &"grass")
	if chests.count() == 1:
		# A shot breaks it; the grass falls out; flying over it picks it up.
		# Generating again put the player on foot at the spawn, maybe beside
		# the chest: fly 2.4 m over it, out of a drop's reach.
		var box: AABB = chests.box_of(chests.chests[ckey].block)
		set_on_foot(false)
		_fly_to(box.get_center() + Vector3(0, 2.4, 0), Vector3(0, 0, -1))
		walker.pitch = -1.45
		await _frames(10)
		_mine(to_global(box.get_center()), Vector3.DOWN, null)
		await _frames(5)
		check.call("a shot breaks the chest, its grass drops (creative: not the chest)",
				chests.count() == 0 and drops.count() == 1
				and (drops.drops[0].stack as ItemStack).id == &"grass")
		await _frames(60)
		var drop_at: Vector3 = drops.drops[0].pos if drops.count() > 0 else box.get_center()
		check.call("the drop came to rest on the ground (%.2f m over the chest's floor)"
				% (drop_at.y - box.position.y), drops.count() > 0 and bool(drops.drops[0].rest)
				and absf(drop_at.y - box.position.y) < 0.5)
		await _shot(UserPaths.DEV + "inv_drop.png")
		var had := 0
		for a in inv.all_addrs():
			var s := inv.get_slot(a)
			if s != null and s.id == &"grass":
				had += s.count
		_fly_to(drop_at + Vector3(0, 0.1, 0), Vector3(0, 0, -1))
		await _frames(30)
		var now_has := 0
		for a in inv.all_addrs():
			var s := inv.get_slot(a)
			if s != null and s.id == &"grass":
				now_has += s.count
		check.call("walking over it picks it up (grass %d -> %d)" % [had, now_has],
				drops.count() == 0 and now_has == had + 64)
		# The ground under a second chest goes: it breaks.
		_fly_to(box.get_center() + Vector3(0, 2.4, 0), Vector3(0, 0, -1))
		walker.pitch = -1.45
		await _frames(10)
		inv.select_item(&"chest")
		builder.update_target()
		builder.place_target()
		check.call("a second chest put down", chests.count() == 1)
		if chests.count() == 1:
			var k2: String = chests.chests.keys()[0]
			var lo: Vector3i = chests.lo_cell(chests.chests[k2].block)
			var res: Dictionary = BrickTerrain.fill_box(lo + Vector3i(0, -3, 0),
					lo + Vector3i(MineChests.STUDS - 1, -1, MineChests.STUDS - 1), 0, false)
			terrain_edited(res)
			await _frames(5)
			check.call("the ground under it removed: the chest breaks", chests.count() == 0)
		_edits_dirty = true
		save_edits(true)
	# Stage 6: the inventory went into the character file, not the world's.
	_inv_dirty = true
	_edits_dirty = true
	save_edits(true)
	var ch := CharacterSave.load_from(GATE_CHARACTER)
	var cinv := Inventory.new()
	var wtext := FileAccess.get_file_as_string(_inventory_path(save_path()))
	var wsave = JSON.parse_string(wtext)
	check.call("the inventory is in the character file (granite in hotbar 2 slot 3)",
			cinv.from_dict(ch.items) and cinv.hotbars[1][2] != null and cinv.hotbars[1][2].id == &"granite")
	check.call("the world file holds only the world's (no hotbars; chests, drops, mode)",
			wsave is Dictionary and not wsave.has("hotbar_0") and wsave.has("chests") and wsave.has("survival"))
	# Stage 7: the world menu's Survival box, clicked.
	toggle_menu()
	await _frames(10)
	var box: CheckBox = _menu.find_child("Survival", true, false) if _menu != null else null
	if box != null:
		await _click(box.get_global_rect().get_center())
	check.call("the world menu's Survival box: survival on", box != null and survival and not inv.creative)
	if _menu != null:
		toggle_menu()
		await _frames(5)
	_fly_to(_eye() - Vector3(0, 1.6, 0), Vector3(0, 0, -1))
	inv.select_item(&"granite")
	var before := inv.hand().count if inv.hand() != null else -1
	builder.size_i = 0
	walker.pitch = -1.0
	await _frames(10)
	builder.update_target()
	var put: bool = builder.place_target()
	var after := inv.hand().count if inv.hand() != null else -1
	# One brick a stud column it fills: 4 for a 2x2 block on flat ground, fewer
	# where the ground already stood in a column (placing only fills air).
	check.call("survival: a 2x2 block uses granite up (%d -> %d)" % [before, after],
			put and after < before and after >= before - 4)
	await _frames(5)
	builder.update_target()
	var took: bool = builder.break_target()
	await _frames(5)
	var after2 := inv.hand().count if inv.hand() != null else -1
	check.call("survival: breaking it gives granite back (%d -> %d)" % [after, after2], took and after2 > after)
	save_edits(true)
	var again2 := settings.duplicate(true)
	settings = {}
	generate(again2)
	await _frames(20)
	check.call("after generating again: still survival", survival and not builder.inv.creative)
	set_survival(false)
	builder.set_active(false)
	builder.gate_keys = false
	print("[inv-gate] INV-GATE %s (%d failed)%s" % ["PASS" if fails.is_empty() else "FAIL",
			fails.size(), "" if fails.is_empty() else ": " + ", ".join(fails)])
	get_tree().quit(0 if fails.is_empty() else 1)


func _inv_slot(scr: InventoryScreen, a: Dictionary, item := &"") -> InvSlot:
	for s in scr.find_children("*", "InvSlot", true, false):
		var slot := s as InvSlot
		if a.is_empty() and slot.addr.is_empty() and slot.item_id == item:
			return slot
		if not a.is_empty() and not slot.addr.is_empty() and slot.addr.area == a.area \
				and slot.addr.index == a.index:
			return slot
	return null


## A left-button drag through `pts`, real events: press at the first, moves
## with the button held, release at the last.
func _gate_drag(pts: Array[Vector2]) -> void:
	var m := InputEventMouseMotion.new()
	m.position = pts[0]
	m.global_position = pts[0]
	Input.parse_input_event(m)
	await _frames(2)
	var b := InputEventMouseButton.new()
	b.button_index = MOUSE_BUTTON_LEFT
	b.position = pts[0]
	b.global_position = pts[0]
	b.pressed = true
	b.button_mask = MOUSE_BUTTON_MASK_LEFT
	Input.parse_input_event(b)
	await _frames(2)
	for p in pts.slice(1):
		m = InputEventMouseMotion.new()
		m.position = p
		m.global_position = p
		m.button_mask = MOUSE_BUTTON_MASK_LEFT
		Input.parse_input_event(m)
		await _frames(2)
	b = b.duplicate()
	b.position = pts[-1]
	b.global_position = pts[-1]
	b.pressed = false
	b.button_mask = 0
	Input.parse_input_event(b)
	await _frames(3)


## -- --gate=look: the same close view of the ground four ways -- FXAA on and
## off, the printed lines on and off -- at render scale 1 and MSAA 2x (the
## user's saved video settings), to see what makes the bricks look soft.
func _run_look_gate() -> void:
	var vp := get_viewport()
	vp.scaling_3d_scale = 1.0
	vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	vp.msaa_3d = Viewport.MSAA_2X
	vp.use_taa = false
	_time = 0.42
	set_on_foot(false)
	var e := _eye()
	var stud := BrickWorld.get_stud_metres()
	var c := Vector2i(floori(e.x / stud), floori(e.z / stud))
	_fly_to(Vector3(e.x, _ground_m(c.x, c.y) + 1.6, e.z), Vector3(1, 0, -1).normalized())
	walker.pitch = -0.5
	await _frames(60)
	if "--look=parts" in OS.get_cmdline_user_args():
		# Which painted effect is the grain: each off in turn, FXAA off.
		vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
		var keys := ["print_lines_enabled", "seams_enabled", "chamfer_enabled",
				"stud_shadows_enabled", "studs_enabled"]
		for k in keys:
			_mat.set_shader_parameter(k, true)
		await _frames(12)
		await _shot(UserPaths.DEV + "mine_part_all_on.png")
		for k in keys:
			_mat.set_shader_parameter(k, false)
			await _frames(12)
			await _shot(UserPaths.DEV + "mine_part_no_%s.png" % k)
			_mat.set_shader_parameter(k, true)
		for k in keys:
			_mat.set_shader_parameter(k, false)
		await _frames(12)
		await _shot(UserPaths.DEV + "mine_part_all_off.png")
		for k in keys:
			_mat.set_shader_parameter(k, true)
		_rig.sun.shadow_enabled = false
		await _frames(12)
		await _shot(UserPaths.DEV + "mine_part_no_sun_shadow.png")
		_rig.sun.shadow_enabled = true
		# (a) the ground out of the shadow map
		for t in _streamer.tiles():
			(t as TerrainTile).set_casts_shadow(false)
		await _frames(12)
		await _shot(UserPaths.DEV + "mine_part_ground_no_cast.png")
		for t in _streamer.tiles():
			(t as TerrainTile).set_casts_shadow(true)
		# (b) casting, with more bias
		var b0 := _rig.sun.shadow_bias
		var n0 := _rig.sun.shadow_normal_bias
		_rig.sun.shadow_bias = 0.4
		_rig.sun.shadow_normal_bias = 4.0
		await _frames(12)
		await _shot(UserPaths.DEV + "mine_part_more_bias.png")
		_rig.sun.shadow_bias = b0
		_rig.sun.shadow_normal_bias = n0
		print("[mine-look] sun shadow bias %.3f normal bias %.3f, max distance %.0f, mode %d, terrain casts within %d tiles"
				% [_rig.sun.shadow_bias, _rig.sun.shadow_normal_bias, _rig.sun.directional_shadow_max_distance,
				_rig.sun.directional_shadow_mode, _streamer.shadow_radius])
		get_tree().quit()
		return
	for fx in [true, false]:
		for lines in [true, false]:
			vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA if fx else Viewport.SCREEN_SPACE_AA_DISABLED
			_mat.set_shader_parameter("print_lines_enabled", lines)
			for m in [TerrainTile.instance_material(), TerrainTile.stud_material()]:
				m.set_shader_parameter("print_lines_enabled", lines)
			await _frames(12)
			await _shot(UserPaths.DEV + "mine_look_fxaa_%s_lines_%s.png" % ["on" if fx else "off", "on" if lines else "off"])
	get_tree().quit()


func _click(at: Vector2) -> void:
	var m := InputEventMouseMotion.new()
	m.position = at
	m.global_position = at
	Input.parse_input_event(m)
	await _frames(2)
	for down in [true, false]:
		var b := InputEventMouseButton.new()
		b.button_index = MOUSE_BUTTON_LEFT
		b.position = at
		b.global_position = at
		b.pressed = down
		b.button_mask = MOUSE_BUTTON_MASK_LEFT if down else 0
		Input.parse_input_event(b)
		await _frames(2)


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
	await _gate_flight()
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
	_fly_to(top + Vector3(-22, 6, -22), (top - (top + Vector3(-22, 6, -22))).normalized())
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
			% [pawn.feet().distance_to(at), at.y - _ground_m(floori(to_local(at).x / BrickWorld.get_stud_metres()),
			floori(to_local(at).z / BrickWorld.get_stud_metres()))])
	await _frames(60)
	await _gate_cave()
	await _gate_edits()
	print("[mine-gate] done")
	get_tree().quit()


## -- --gate=breakwater: WHERE A FRAME GOES while bricks are broken beside
## running water (the user: "poor performance while breaking bricks and water
## is flowing"). Pours sources on the ground in front of the player, lets them
## run, then rapid-fires into the ground beside and under the water (the holes
## take the water, the collapse surveys, debris flies). Three windows -- water
## alone, shooting into it, settling -- each: frame mean / worst / slow, the
## main thread by the clock (scripts, physics step, process, draw, GPU, draws),
## the mine world's own parts (near, far, deep, trees, water, ground), the
## water's worker tick, debris bodies, surveys; and the worst frames, part by
## part. Measures, decides nothing: run it on a quiet, cool machine (CLAUDE.md).
func _run_breakwater_gate() -> void:
	await _frames(60)
	_time = 0.42
	var clock := FrameClock.new()
	add_child(clock)
	set_on_foot(true)
	await _frames(30)
	var stud := BrickWorld.get_stud_metres()
	var e := _eye()
	# Sources: a row of four on the ground 3-6 m ahead, each its own course.
	var sources := 0
	for i in 4:
		var p := e + Vector3(1.0 + float(i) * 1.2, 0.0, -4.5)
		var c := Vector2i(floori(p.x / stud), floori(p.z / stud))
		var top := BrickTerrain.surface_plate(c.x, c.y)
		BrickFluid.place(Vector3i(c.x, floori((top + 1) / 3.0), c.y), 1, BrickFluid.SOURCE, 3)
		sources += 1
	water.manual = false
	# Let it spread a little before anything is timed.
	await _frames(90)
	var win := func() -> Dictionary:
		return {"n": 0, "sum": 0.0, "worst": 0.0, "slow": 0, "parts": {}, "world": {},
				"water_tick": 0.0, "worst_frames": []}
	var sample := func(w: Dictionary) -> void:
		var ms := clock.last_ms
		w.n += 1
		w.sum += ms
		w.worst = maxf(w.worst, ms)
		if ms > 25.0:
			w.slow += 1
		for k in clock.last:
			w.parts[k] = float(w.parts.get(k, 0.0)) + float(clock.last[k])
		var world := {"near": float(_ptimes.get("near", 0.0)), "far": float(_ptimes.get("far", 0.0))
				+ float(_ptimes.get("reanchor", 0.0)), "deep": float(_ptimes.get("deep", 0.0)),
				"trees": _trees.last_us / 1000.0 if _trees != null else 0.0,
				"water": water.last_us / 1000.0,
				"ground": collapse.last_us / 1000.0 if collapse != null else 0.0}
		for k in world:
			w.world[k] = float(w.world.get(k, 0.0)) + float(world[k])
		var st: Dictionary = BrickFluid.stats()
		w.water_tick = maxf(w.water_tick, float(st.get("tick_ms", 0.0)))
		var wf: Array = w.worst_frames
		wf.append([ms, clock.last.duplicate(), world, debris.bodies.size()])
		wf.sort_custom(func(a: Array, b: Array) -> bool: return a[0] > b[0])
		if wf.size() > 5:
			wf.resize(5)
	var report := func(name: String, w: Dictionary) -> void:
		var n := maxf(float(w.n), 1.0)
		var parts := ""
		for k in ["scripts", "step", "process", "draw", "sync", "gpu", "draws_k", "tris_M"]:
			parts += " %s %.1f" % [k, float(w.parts.get(k, 0.0)) / n]
		var world := ""
		for k in ["near", "far", "deep", "trees", "water", "ground"]:
			world += " %s %.2f" % [k, float(w.world.get(k, 0.0)) / n]
		print("[breakwater] %s: %d frames, mean %.1f ms, worst %.1f ms, %d over 25 ms | clock mean:%s | world mean (ms):%s | water worker tick worst %.1f ms" % [
				name, w.n, float(w.sum) / n, w.worst, w.slow, parts, world, w.water_tick])
		for f in w.worst_frames:
			var cp: Dictionary = f[1]
			var wp: Dictionary = f[2]
			print("[breakwater]   worst %.1f ms: scripts %.1f step %.1f process %.1f draw %.1f sync %.1f gpu %.1f | near %.1f far %.1f deep %.1f trees %.1f water %.1f ground %.1f | debris %d" % [
					f[0], float(cp.get("scripts", 0.0)), float(cp.get("step", 0.0)), float(cp.get("process", 0.0)),
					float(cp.get("draw", 0.0)), float(cp.get("sync", 0.0)), float(cp.get("gpu", 0.0)),
					wp.near, wp.far, wp.deep, wp.trees, wp.water, wp.ground, f[3]])
	# A: water running, nothing shot.
	var a: Dictionary = win.call()
	for f in 240:
		await get_tree().process_frame
		sample.call(a)
	# B: rapid fire beside and under the water, a shot every 4 frames.
	var b: Dictionary = win.call()
	var surveys0 := collapse.surveys if collapse != null else 0
	var shots := 0
	var debris_peak := 0
	for i in 120:
		var p := e + Vector3(0.6 + float(i % 8) * 0.6, 0.0, -3.0 - floorf(float(i % 40) / 8.0) * 0.6)
		var c := Vector2i(floori(p.x / stud), floori(p.z / stud))
		p.y = _ground_m(c.x, c.y) - 0.2
		_mine(p, Vector3.DOWN, null)
		shots += 1
		for f in 4:
			await get_tree().process_frame
			sample.call(b)
			debris_peak = maxi(debris_peak, debris.bodies.size())
	# C: settling, nothing shot.
	var cw: Dictionary = win.call()
	for f in 240:
		await get_tree().process_frame
		sample.call(cw)
	print("[breakwater] %d sources, %d shots, %d tiles rebuilt, %d surveys, debris peak %d bodies, %d edits; %s" % [
			sources, shots, _streamer.built_count(), (collapse.surveys if collapse != null else 0) - surveys0,
			debris_peak, BrickTerrain.get_edit_count(), water.report()])
	report.call("A water only", a)
	report.call("B shooting into water", b)
	report.call("C settling", cw)
	print("[breakwater] done")
	get_tree().quit()


## -- --gate=stop: what the frame does after the player STOPS (the user:
## "after stopping, while still, the fps drops for a few seconds"). Flies at
## the default 50 m/s over new ground for 8 s, stops, and prints the next 8 s
## in quarter-second windows: the worst and mean frame, the GPU's worst, the
## main thread's parts (FrameClock), the mine world's own (near, deep, far,
## trees) and what each tier did in the window.
func _run_stop_gate() -> void:
	await _frames(60)
	var clock := FrameClock.new()
	add_child(clock)
	set_on_foot(false)
	# --walk: 6 m/s at eye height over the ground for 15 s, a player's walk;
	# else the default flight, 50 m/s 10 m up for 8 s.
	var walk := "--walk" in OS.get_cmdline_user_args()
	var speed := 6.0 if walk else 50.0
	var secs := 15000 if walk else 8000
	var stud := BrickWorld.get_stud_metres()
	_fly_to(_eye() + Vector3(0, 1.0 if walk else 10.0, 0), Vector3(1, -0.1, 0.3).normalized())
	walker.pitch = -0.15 if walk else -0.3
	await _frames(30)
	var dir := Vector3(1.0, 0.0, 0.3).normalized()
	var t0 := Time.get_ticks_msec()
	var mv_gpu: Array[float] = []
	var mv_tris := 0.0
	# While moving: the streamer's phases counted from here (not the load's
	# first tiles), the worst frames and what the world spent in them.
	_streamer.reset_stats()
	TerrainTile.profile_instances = true
	TerrainTile.instance_ms.clear()
	var mv_worst: Array = []
	var mv_slow := 0
	while Time.get_ticks_msec() - t0 < secs:
		walker.global_position += dir * speed * get_process_delta_time()
		if walk:
			var tp := to_local(walker.global_position)
			var gy := _ground_m(floori(tp.x / stud), floori(tp.z / stud))
			walker.global_position.y = gy + 1.7
		await get_tree().process_frame
		if clock.last_ms > 33.3:
			mv_slow += 1
			mv_worst.append([clock.last_ms, float(clock.last.get("process", 0.0)), float(clock.last.get("draw", 0.0)),
					float(_ptimes.get("near", 0.0)), float(_ptimes.get("far", 0.0)), float(_ptimes.get("deep", 0.0))])
		if Time.get_ticks_msec() - t0 > secs - 4000:
			mv_gpu.append(float(clock.last.get("gpu", 0.0)))
			mv_tris = maxf(mv_tris, float(clock.last.get("tris_M", 0.0)))
	TerrainTile.profile_instances = false
	mv_worst.sort_custom(func(x: Array, y: Array) -> bool: return x[0] > y[0])
	print("[mine-stop] moving: %d frames over 33 ms; the worst (ms, process, draw, near, far, deep): %s" % [
			mv_slow, mv_worst.slice(0, 6).map(func(r: Array) -> String: return "%.0f/%.0f/%.0f/%.1f/%.1f/%.1f" % r)])
	print("[mine-stop] moving: near tier %s" % _streamer.report())
	var inst_keys := TerrainTile.instance_ms.keys()
	inst_keys.sort_custom(func(x, y) -> bool: return float(TerrainTile.instance_ms[x]) > float(TerrainTile.instance_ms[y]))
	print("[mine-stop] moving: instance steps %s" % [inst_keys.slice(0, 10).map(func(k) -> String: return "%s %.1f" % [k, float(TerrainTile.instance_ms[k])])])
	mv_gpu.sort()
	print("[mine-stop] %s %d s at %.0f m/s (held %s), stopping; the last 4 s moving: gpu median %.1f, 90th %.1f ms, tris up to %.2fM"
			% ["walked" if walk else "flew", secs / 1000, speed, fast_hold,
			mv_gpu[mv_gpu.size() / 2] if not mv_gpu.is_empty() else 0.0,
			mv_gpu[int(mv_gpu.size() * 0.9)] if not mv_gpu.is_empty() else 0.0, mv_tris])
	var windows := []
	var w := {}
	var tw := Time.get_ticks_msec()
	var built0 := _streamer.built_count()
	var bev0 := _streamer.bevels_added
	var far0 := _far.applies
	var deep0 := _deep.built
	while Time.get_ticks_msec() - tw < 8000:
		await get_tree().process_frame
		var ms := clock.last_ms
		var p: Dictionary = clock.last
		if w.is_empty():
			w = {"n": 0, "worst": 0.0, "sum": 0.0, "gpu": 0.0, "process": 0.0, "scripts": 0.0,
					"step": 0.0, "draw": 0.0, "sync": 0.0, "near": 0.0, "deep": 0.0, "far": 0.0,
					"trees": 0.0, "tris": 0.0, "water": 0.0, "coll": 0.0, "water_max": 0.0}
		w.n += 1
		w.sum += ms
		if ms > w.worst:
			w.worst = ms
			for k in ["process", "scripts", "step", "draw", "sync"]:
				w[k] = float(p.get(k, 0.0))
			w.near = float(_ptimes.get("near", 0.0))
			w.deep = float(_ptimes.get("deep", 0.0))
			w.far = float(_ptimes.get("far", 0.0)) + float(_ptimes.get("reanchor", 0.0))
			w.trees = _trees.last_us / 1000.0
			w.water = water.last_us / 1000.0
			w.coll = collapse.last_us / 1000.0
		w.gpu = maxf(w.gpu, float(p.get("gpu", 0.0)))
		w.water_max = maxf(w.water_max, water.last_us / 1000.0)
		w.draws = maxf(float(w.get("draws", 0.0)), float(p.get("draws_k", 0.0)))
		w.sh = maxf(float(w.get("sh", 0.0)), float(p.get("sh_tris_M", 0.0)))
		w.tris = maxf(w.tris, float(p.get("tris_M", 0.0)))
		var el := Time.get_ticks_msec() - tw
		if el >= (windows.size() + 1) * 250:
			w["built"] = _streamer.built_count() - built0
			w["bev"] = _streamer.bevels_added - bev0
			w["far_n"] = _far.applies - far0
			w["deep_n"] = _deep.built - deep0
			w["lava"] = water.lava_lights()
			w["wtiles"] = water.drawn
			built0 = _streamer.built_count()
			bev0 = _streamer.bevels_added
			far0 = _far.applies
			deep0 = _deep.built
			windows.append(w)
			w = {}
	for i in windows.size():
		var x: Dictionary = windows[i]
		print("[mine-stop] %4.2f s  tris %.2fM sh %.2fM draws %.1fk lava %d wtiles %d" % [(i + 1) * 0.25,
				x.tris, x.get("sh", 0.0), x.get("draws", 0.0), x.lava, x.wtiles])
		print("[mine-stop] %4.2f s  worst %5.1f mean %4.1f gpu %4.1f | worst frame: process %4.1f scripts %4.1f step %4.1f draw %4.1f; near %4.1f deep %4.1f far %4.1f trees %4.1f water %4.1f collapse %4.1f | water max %4.1f | built %d bevel %d far %d deep %d"
				% [(i + 1) * 0.25, x.worst, x.sum / maxf(x.n, 1), x.gpu, x.process, x.scripts, x.step,
				x.draw, x.near, x.deep, x.far, x.trees, x.water, x.coll, x.water_max, x.built, x.bev, x.far_n, x.deep_n])
	print("[mine-stop] %s | bevel hand-over worst %.1f ms | water %s" % [_streamer.report(), _streamer.bevel_ms, water.report()])
	get_tree().quit()


## -- --gate=spawn: the first new ground after the world is made. Flying at
## 30 m/s (under the fast-flight hold) from the spawn, every new tile's studs
## and scatter need instance nodes, and until tiles are dropped the pool is
## empty: a never-drawn MultiMesh node stalls the render thread (TerrainTile,
## _mm_pool). Frame times, the near tier's worst instance step, and how many
## instance nodes were new and how many reused (Docs/MineWorld.md 14).
func _run_spawn_gate() -> void:
	await _frames(5)
	TerrainTile.profile_instances = true
	TerrainTile.instance_ms.clear()
	_streamer.reset_stats()
	set_on_foot(false)
	_fly_to(_eye() + Vector3(0, 8, 0), Vector3(1, -0.2, 0.3).normalized())
	var worst := 0.0
	var slow := 0
	var notes: Array[String] = []
	for i in 600:
		walker.global_position += Vector3(1.0, 0.0, 0.3).normalized() * 0.5
		var f0 := Time.get_ticks_usec()
		await get_tree().process_frame
		var ms := float(Time.get_ticks_usec() - f0) / 1000.0
		if i > 2:
			worst = maxf(worst, ms)
			if ms > 33.0:
				slow += 1
				if notes.size() < 8:
					notes.append("f%d %.0f ms (near %.1f)" % [i, ms, _ptimes.get("near", 0.0)])
	var nodes := []
	for k in ["Studs", "StudsFar", "Tufts", "Pebbles", "Bricks"]:
		nodes.append("%s %d new / %d reused" % [k, int(TerrainTile.instance_ms.get(k + " new", 0.0)),
				int(TerrainTile.instance_ms.get(k + " reused", 0.0))])
	print("[mine-spawn] 600 frames at 30 m/s from the spawn: worst %.0f ms, %d over 33 ms; %s; %s"
			% [worst, slow, _streamer.report(), ", ".join(nodes)])
	for n in notes:
		print("[mine-spawn]   slow %s" % n)
	TerrainTile.profile_instances = false
	get_tree().quit()


## -- --gate=flight: only the fast flight (below), from the spawn.
func _run_flight_gate() -> void:
	await _frames(30)
	set_on_foot(false)
	walker.place(walker.global_position + Vector3(0, 60, 0), Vector3(1, -0.35, 0.4).normalized())
	walker.pitch = -0.45
	await _frames(120)
	await _gate_flight()
	await _frames(120)
	print("[mine-gate] holes round the camera after the flight: %d" % _holes())
	await _shot(UserPaths.DEV + "mine_far_away.png")
	get_tree().quit()


## Fast flight into new ground: 1.6 m a frame (~100 m/s at 60 fps) along X
## for 900 frames, re-centring the far rings twice. The worst frame and the
## frames over 33 ms are the spike (Docs/MineWorld.md 14); then 1 s slow
## (0.3 m a frame) so the detail comes back, and the frames of THAT.
func _gate_flight() -> void:
	var t0 := Time.get_ticks_usec()
	var worst := 0.0
	var slow := 0
	var held := 0
	var from := walker.global_position
	_streamer.reset_stats()
	var notes: Array[String] = []
	for i in 900:
		walker.global_position = from + Vector3(1.0, 0.0, 0.3) * float(i) * 1.6
		var f0 := Time.get_ticks_usec()
		var built0 := _streamer.built_count()
		var trees0: int = _trees.count
		await get_tree().process_frame
		var ms := float(Time.get_ticks_usec() - f0) / 1000.0
		worst = maxf(worst, ms)
		if ms > 33.0:
			slow += 1
			if notes.size() < 16:
				notes.append("f%d %.0f ms: near %.1f far %.1f reanchor %.1f%s trees %.1f (+%d) built +%d" % [i, ms,
						_ptimes.get("near", 0.0), _ptimes.get("far", 0.0), _ptimes.get("reanchor", 0.0),
						" SWAPPED" if _ptimes.get("swapped", false) else "", _trees.last_us / 1000.0,
						_trees.count - trees0, _streamer.built_count() - built0])
		if fast_hold:
			held += 1
	print("[mine-gate] flew %.0f m in %.1f s, worst frame %.0f ms, %d over 33 ms, detail held %d of 900 frames%s, re-centred %d times (last %.0f ms), %s"
			% [900 * 1.6, float(Time.get_ticks_usec() - t0) / 1e6, worst, slow, held,
			"" if _fast_hold_on else " (--no-fast-hold)", _reanchors, _last_reanchor_ms,
			_streamer.report()])
	for n in notes:
		print("[mine-gate]   slow %s" % n)
	# Slowing down: the detail resumes round the camera.
	var at := walker.global_position
	worst = 0.0
	slow = 0
	for i in 120:
		walker.global_position = at + Vector3(1.0, 0.0, 0.3) * float(i) * 0.3
		var f0 := Time.get_ticks_usec()
		await get_tree().process_frame
		var ms := float(Time.get_ticks_usec() - f0) / 1000.0
		worst = maxf(worst, ms)
		if ms > 33.0:
			slow += 1
	print("[mine-gate] slowed down: held %s, 120 frames worst %.0f ms, %d over 33 ms, %s"
			% [fast_hold, worst, slow, _streamer.report()])


## -- --gate=shift: the origin shift (Docs/MineWorld.md 15) with its
## threshold lowered to 300 m, so a 1.2 km flight shifts several times. After
## it: the eye is near the global origin, the ground round it is all drawn,
## the pawn lands and stands on it (the colliders moved with their tiles),
## and a block placed lands where it is looked at.
func _run_shift_gate() -> void:
	await _frames(30)
	shift_at = 300.0
	set_on_foot(false)
	var e0 := _eye()
	_fly_to(e0 + Vector3(0, 30, 0), Vector3(1, -0.3, 0.2).normalized())
	await _frames(60)
	var from := walker.global_position
	var step := Vector3(1.0, 0.0, 0.25).normalized() * 0.8
	for i in 1500:
		walker.global_position += step
		await get_tree().process_frame
	var e1 := _eye()
	var g1 := _eye_render()
	print("[mine-shift] flew %.0f m (terrain eye %s -> %s): %d shifts, the eye is %.0f m from the global origin, origin is terrain %s"
			% [Vector2(e1.x - e0.x, e1.z - e0.z).length(), e0, e1, shifts, Vector2(g1.x, g1.z).length(),
			origin_shift])
	shift_at = 1e9   # no more while it lands
	await _frames(150)
	print("[mine-shift] holes round the camera: %d" % _holes())
	await _shot(UserPaths.DEV + "mine_shift_far.png")
	# Down onto the ground and stand.
	var stud := BrickWorld.get_stud_metres()
	var c := Vector2i(floori(e1.x / stud), floori(e1.z / stud))
	var g := _ground_m(c.x, c.y)
	_fly_to(Vector3(e1.x, g + 1.0, e1.z), Vector3(1, 0, 0))
	await _frames(30)
	set_on_foot(true)
	var low := INF
	for f in 150:
		await get_tree().physics_frame
		low = minf(low, to_local(pawn.feet()).y)
	var feet := to_local(pawn.feet())
	print("[mine-shift] landed: feet %.2f m over the ground (lowest %.2f) -- %s"
			% [feet.y - g, low - g, "STANDING" if absf(feet.y - g) < 0.6 and low > g - 1.0 else "FELL"])
	# A block, as the build pass places it.
	set_on_foot(false)
	_fly_to(Vector3(e1.x, g + 2.4, e1.z), Vector3(0, 0, -1))
	walker.pitch = -0.75
	await _frames(20)
	builder.set_active(true)
	builder.update_target()
	var want: Dictionary = builder.target.duplicate()
	var placed: bool = builder.place_target()
	await _frames(10)
	var cell: Vector3i = want.get("cell", Vector3i.ZERO)
	print("[mine-shift] build: looked at %s, placed %s, outline at %s (terrain %s)"
			% [cell, placed, builder._outline.global_position, to_local(builder._outline.global_position)])
	builder.set_active(false)
	await _shot(UserPaths.DEV + "mine_shift_build.png")
	# Falling ground after the shifts: a floating dirt block lets go as a
	# piece, and the piece must be where the block was -- piece transforms
	# are global, the block's cells are terrain (ground_collapse.gd).
	var made0 := int(collapse.groups_let_go)
	var plate := BrickWorld.get_plate_metres()
	var d0 := Vector3i(c.x + 6, floori(g / plate) + 24, c.y)
	terrain_edited(BrickTerrain.fill_box(d0, d0 + Vector3i(1, 2, 1), 2, true))
	var want_at := to_global(Vector3((d0.x + 1) * stud, (d0.y + 1.5) * plate, (d0.z + 1) * stud))
	var tw := Time.get_ticks_msec()
	var n0: int = collapse.pieces.pieces.size()
	while Time.get_ticks_msec() - tw < 5000 and collapse.pieces.pieces.size() <= n0:
		await get_tree().process_frame
	await _frames(2)
	var near_m := INF
	for pc in collapse.pieces.pieces:
		var mid: Vector3 = collapse.pieces.world_box(pc).get_center()
		near_m = minf(near_m, Vector2(mid.x - want_at.x, mid.z - want_at.z).length())
	print("[mine-shift] falling ground: %d let go, the nearest piece %.2f m (across) from where the block was -- %s"
			% [int(collapse.groups_let_go) - made0, near_m, "IN PLACE" if near_m < 1.5 else "DISPLACED"])
	get_tree().quit()


## -- --gate=deep: the deep tier (Docs/MineWorld.md 16). A reachable cave
## well under a surface tile's floor (its floor inside a section's collider),
## flown into: the sections load round the eye, the frames while they do,
## the pawn lands and stands. Then a cave that crosses a tile's floor, looked
## at across the boundary, for seams.
func _run_deep_gate() -> void:
	await _frames(30)
	var stud := BrickWorld.get_stud_metres()
	var plate := BrickWorld.get_plate_metres()
	var sec := BrickTerrain.get_deep_section_plates()
	var e := _eye()
	var c0 := Vector2i(floori(e.x / stud), floori(e.z / stud))
	var found := Vector3.INF
	var cross := Vector3.INF
	var tops := {}
	for r in range(0, 600, 6):
		for k in 8:
			var a := TAU * k / 8.0 + r * 0.37
			var x := c0.x + int(r * cos(a))
			var z := c0.y + int(r * sin(a))
			var t := Vector2i(floori(float(x) / 32.0), floori(float(z) / 32.0))
			if not tops.has(t):
				tops[t] = BrickTerrain.deep_top(t.x, t.y)
			var floor_p: int = tops[t]
			if cross == Vector3.INF and BrickTerrain.solid_at(x, floor_p, z) == 0 					and BrickTerrain.solid_at(x, floor_p - 1, z) == 0 and BrickTerrain.solid_at(x, floor_p - 6, z) == 0:
				cross = Vector3((x + 0.5) * stud, floor_p * plate, (z + 0.5) * stud)
			if found != Vector3.INF:
				continue
			# A room at least 3 m tall, 20 m or more under the floor.
			var yp := floor_p - 140
			while yp > floor_p - 500 and BrickTerrain.solid_at(x, yp, z) != 0:
				yp -= 1
			var air := 0
			while yp > floor_p - 520 and BrickTerrain.solid_at(x, yp, z) == 0:
				yp -= 1
				air += 1
			if air < 22 or yp <= BrickTerrain.get_bedrock_plate():
				continue
			# A floor, not a ledge: the same top over 5 x 5 studs.
			var flat := true
			for dz in range(-2, 3):
				for dx in range(-2, 3):
					if BrickTerrain.solid_at(x + dx, yp, z + dz) == 0 							or BrickTerrain.solid_at(x + dx, yp + 1, z + dz) != 0 							or BrickTerrain.solid_at(x + dx, yp + 14, z + dz) != 0:
						flat = false
			if not flat:
				continue
			var s: Dictionary = BrickTerrain.build_section(t.x, floori(float(yp) / sec), t.y)
			var boxes: PackedFloat32Array = s.get("boxes", PackedFloat32Array())
			var q := Vector3((x - t.x * 32 + 0.5) * stud, (yp + 1) * plate - 0.03, (z - t.y * 32 + 0.5) * stud)
			for o in range(0, boxes.size(), 6):
				if absf(q.x - boxes[o]) <= boxes[o + 3] * 0.5 and absf(q.y - boxes[o + 1]) <= boxes[o + 4] * 0.5 						and absf(q.z - boxes[o + 2]) <= boxes[o + 5] * 0.5:
					found = Vector3((x + 0.5) * stud, (yp + 1) * plate, (z + 0.5) * stud)
					break
		if found != Vector3.INF and cross != Vector3.INF:
			break
	if found == Vector3.INF:
		print("[mine-deep] no reachable deep cave within 600 studs: SKIPPED")
		get_tree().quit()
		return
	set_on_foot(false)
	_fly_to(found + Vector3(0, 1.2, 0), Vector3(1, 0, 0.3).normalized())
	walker.pitch = -0.25
	var worst := 0.0
	var slow := 0
	var frames := 0
	for f in 600:
		var f0 := Time.get_ticks_usec()
		await get_tree().process_frame
		var ms := float(Time.get_ticks_usec() - f0) / 1000.0
		frames += 1
		if f > 2:
			worst = maxf(worst, ms)
			if ms > 33.0:
				slow += 1
		if f > 60 and _deep._tasks.is_empty() and _deep._collide_pending.is_empty():
			break
	print("[mine-deep] in a cave %.0f m under the surface (%.0f m under the sea line): %s; loaded in %d frames, worst %.0f ms, %d over 33 ms"
			% [_ground_m(floori(found.x / stud), floori(found.z / stud)) - found.y,
			float(BrickTerrain.get_gen_params()["sea_m"]) - found.y, _deep.report(), frames, worst, slow])
	await _shot(UserPaths.DEV + "mine_deep_cave.png")
	var luma: float = await _mean_luma()
	print("[mine-deep] light in the cave: picture mean %.3f, cave factor %.3f, ambient %.3f, sun %.3f, sky %.3f, exposure %.2f"
			% [luma, _cave_light, _rig.env.ambient_light_energy, _rig.sun.light_energy,
			_rig.sky_mat.sky_energy_multiplier, _rig.exposure])
	if "--light-sweep" in OS.get_cmdline_user_args():
		# What lights the cave: each in turn off.
		var env := _rig.env
		var res := []
		_hud_layer.visible = false
		view.rig.visible = false
		await _frames(8)
		res.append("no HUD/gun %.3f" % await _mean_luma())
		for k in ["ssil_enabled", "sdfgi_enabled", "ssao_enabled", "glow_enabled", "fog_enabled", "volumetric_fog_enabled"]:
			var was = env.get(k)
			env.set(k, false)
			await _frames(30)
			res.append("%s(was %s) off %.3f" % [k, was, await _mean_luma()])
			env.set(k, was)
		var rs = env.reflected_light_source
		env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
		await _frames(20)
		res.append("reflections off %.3f" % await _mean_luma())
		env.reflected_light_source = rs
		var hold := _rig.hold_exposure
		_rig.hold_exposure = true
		_rig.attributes.exposure_multiplier = 1.0
		await _frames(10)
		res.append("exposure 1 %.3f" % await _mean_luma())
		env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
		await _frames(10)
		res.append("+ no reflections %.3f" % await _mean_luma())
		var amb := env.ambient_light_energy
		env.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
		await _frames(10)
		res.append("+ no ambient %.3f" % await _mean_luma())
		_rig.sun.visible = false
		await _frames(10)
		res.append("+ no sun %.3f" % await _mean_luma())
		var lights := []
		for l in get_tree().root.find_children("*", "Light3D", true, false):
			if (l as Light3D).visible and l != _rig.sun:
				lights.append("%s(%s)" % [l.name, l.get_class()])
				(l as Light3D).visible = false
		await _frames(10)
		res.append("+ no other lights %.3f [%s]" % [await _mean_luma(), ", ".join(lights.slice(0, 6))])
		_rig.hold_exposure = hold
		print("[mine-deep] light sweep (gi level %s): %s" % [LightRig.gi_level, ", ".join(res)])
		_hud_layer.visible = true
	# What is under the landing spot, in the physics space.
	var under := to_global(found)
	var q := PhysicsRayQueryParameters3D.create(under + Vector3(0, 1.0, 0), under - Vector3(0, 3.0, 0), Layers.WORLD)
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	var key := TerrainDeep.section_of(found + Vector3(0, -0.05, 0))
	var st = _deep._secs.get(key)
	print("[mine-deep] under the landing spot: hit %s; its section %s drawn %s, collision done %s, %d boxes"
			% [hit.get("position", "nothing"), key, st != null,
			st != null and bool(st._collision_done), (st._data.boxes as PackedFloat32Array).size() / 6 if st != null else 0])
	var wat := to_local(walker.global_position)
	set_on_foot(true)
	var t_land := to_local(pawn.feet())
	var low := INF
	for f in 200:
		await get_tree().physics_frame
		var fp := to_local(pawn.feet())
		low = minf(low, fp.y)
	var t1 := to_local(pawn.feet())
	print("[mine-deep] walker at %s, pawn put at %s, ended at %s, floor %s" % [wat, t_land, t1, found])
	print("[mine-deep] landed: feet %.2f m over the floor after 200 ticks (lowest %.2f) -- %s"
			% [t1.y - found.y, low - found.y, "STANDING" if absf(t1.y - found.y) < 0.6 and low > found.y - 1.0 else "FELL"])
	if cross != Vector3.INF:
		set_on_foot(false)
		_fly_to(cross + Vector3(-3.0, -1.0, -3.0), Vector3(1, 0, 1).normalized())
		walker.pitch = 0.35
		await _frames(240)
		print("[mine-deep] a cave across a tile's floor at %s: %s" % [cross, _deep.report()])
		await _shot(UserPaths.DEV + "mine_deep_seam.png")
	get_tree().quit()


## -- --gate=cave: only the cave landing (below).
func _run_collapse_gate() -> void:
	await _frames(30)
	await _gate_collapse()
	get_tree().quit()


## The ground coming down (Docs/TerrainCollapse.md 7), built and shot where
## the camera looks: a floating dirt block falls as a piece, floating sand as
## columns that land as ground, a stone arm on a pillar stands until the
## pillar's foot is shot out, then pillar and arm fall as one piece; the
## pieces settle, are unloaded when the player flies off past the detail
## tiles and come back, and are saved and loaded with the world.
func _gate_collapse() -> void:
	var dev := UserPaths.DEV
	DirAccess.make_dir_recursive_absolute(dev)
	var fails := 0
	var stud := BrickWorld.get_stud_metres()
	var plate := BrickWorld.get_plate_metres()
	_time = 0.42
	set_on_foot(false)
	var e := _eye()
	var o := Vector2i(floori(e.x / stud) + 14, floori(e.z / stud))
	var top := func(x: int, z: int) -> int:
		var yp := BrickTerrain.surface_plate(x, z) + 30
		while yp > -600 and BrickTerrain.solid_at(x, yp, z) == 0:
			yp -= 1
		return yp
	var t_max := -(1 << 30)
	for dz in range(-2, 4):
		for dx in range(-2, 16):
			t_max = maxi(t_max, int(top.call(o.x + dx, o.y + dz)))
	# Whole bricks, a course over the highest ground there.
	var b := (floori(float(t_max + 1) / 3.0) + 1) * 3
	var put := func(lo: Vector3i, hi: Vector3i, mat: int) -> void:
		terrain_edited(BrickTerrain.fill_box(lo, hi, mat, true))
	# The pillar (stone, 2x2) from the ground up, 8 bricks over the base.
	for dz in 2:
		for dx in 2:
			var t: int = top.call(o.x + dx, o.y + dz)
			put.call(Vector3i(o.x + dx, t + 1, o.y + dz), Vector3i(o.x + dx, b + 23, o.y + dz), 4)
	# The arm: stone, 2 courses, 10 studs out along +X.
	put.call(Vector3i(o.x + 2, b + 18, o.y), Vector3i(o.x + 11, b + 23, o.y + 1), 4)
	_fly_to(Vector3((o.x + 6) * stud, (b + 12) * plate + 1.0, (o.y - 22) * stud), Vector3(0, 0, 1))
	walker.pitch = -0.1
	await _frames(60)
	await _collapse_quiet(240)
	var arm_cell := Vector3i(o.x + 11, b + 20, o.y)
	var stands := BrickTerrain.solid_at(arm_cell.x, arm_cell.y, arm_cell.z) == 4
	print("[mine-collapse] %s  the stone arm stands on its pillar" % ("ok  " if stands else "FAIL"))
	fails += 0 if stands else 1
	# A shot into the ground: its brick is gone, nothing is thrown (2026-11-20).
	var gx := o.x + 20
	var gz := o.y + 8
	var gtop: int = top.call(gx, gz)
	var bodies0: int = debris.bodies.size()
	var edits0 := BrickTerrain.get_edit_count()
	_mine(Vector3((gx + 0.5) * stud, (gtop + 1) * plate + 0.01, (gz + 0.5) * stud) + Vector3.DOWN * 0.03,
			Vector3.DOWN, StructuralDamage.for_shot(null))
	await _frames(20)
	var gone_ok: bool = BrickTerrain.get_edit_count() > edits0 and debris.bodies.size() == bodies0
	print("[mine-collapse] %s  a shot deletes its brick, throws none (%d plates edited, %d bodies thrown)" % [
			"ok  " if gone_ok else "FAIL", BrickTerrain.get_edit_count() - edits0, debris.bodies.size() - bodies0])
	fails += 0 if gone_ok else 1
	# A floating dirt block and a floating sand block beside it.
	var made0 := int(collapse.groups_let_go)
	var d0 := Vector3i(o.x + 4, b + 30, o.y + 6)
	put.call(d0, d0 + Vector3i(1, 2, 1), 2)
	var s0 := Vector3i(o.x + 8, b + 30, o.y + 6)
	put.call(s0, s0 + Vector3i(1, 8, 1), 3)
	await _frames(4)
	_shot(dev + "mine_collapse_0_built.png")
	var clock := FrameClock.new()
	add_child(clock)
	clock.spoil()
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 6000:
		await get_tree().process_frame
		if not collapse.busy() and Time.get_ticks_msec() - t0 > 1500:
			break
	clock.spoil()
	_shot(dev + "mine_collapse_1_fell.png")
	var ok := int(collapse.groups_let_go) > made0
	print("[mine-collapse] %s  the dirt block fell as a piece (%d let go)" % ["ok  " if ok else "FAIL", int(collapse.groups_let_go) - made0])
	fails += 0 if ok else 1
	ok = collapse.columns_landed >= 4 and BrickTerrain.solid_at(s0.x, s0.y, s0.z) == 0
	var landed_at := -1
	for yp in range(s0.y, s0.y - 200, -1):
		if BrickTerrain.solid_at(s0.x, yp, s0.z) == 3:
			landed_at = yp
			break
	ok = ok and landed_at >= 0
	print("[mine-collapse] %s  the sand fell as columns and landed as sand (%d landed, sand top at %d, left %d)" % [
			"ok  " if ok else "FAIL", collapse.columns_landed, landed_at, s0.y])
	fails += 0 if ok else 1
	# The pillar's foot shot out: what a shot does, two courses of it.
	var runs := PackedInt32Array()
	for dz in 2:
		for dx in 2:
			runs.append_array([o.x + dx, o.y + dz, b, b + 5])
	var made1 := int(collapse.groups_let_go)
	var bricks1 := int(collapse.bricks_let_go)
	terrain_edited(BrickTerrain.clear_runs(runs))
	t0 = Time.get_ticks_msec()
	var shots := 0
	while Time.get_ticks_msec() - t0 < 8000:
		await get_tree().process_frame
		if shots == 0 and Time.get_ticks_msec() - t0 > 700:
			clock.spoil()
			_shot(dev + "mine_collapse_2_falling.png")
			shots = 1
		if not collapse.busy() and Time.get_ticks_msec() - t0 > 2000:
			break
	clock.spoil()
	_shot(dev + "mine_collapse_3_down.png")
	# Frames while it all fell, the screenshots' read-backs left out.
	for line in clock.report_lines():
		print("[mine-collapse] " + line)
	clock.queue_free()
	ok = int(collapse.groups_let_go) > made1 and BrickTerrain.solid_at(arm_cell.x, arm_cell.y, arm_cell.z) == 0
	print("[mine-collapse] %s  foot shot out: pillar and arm fell (%d piece(s), %d bricks)" % [
			"ok  " if ok else "FAIL", int(collapse.groups_let_go) - made1, int(collapse.bricks_let_go) - bricks1])
	fails += 0 if ok else 1
	var settled := 0
	for p in collapse.pieces.pieces:
		settled += 1 if p.settled else 0
	ok = settled == collapse.pieces.pieces.size() and settled > 0
	print("[mine-collapse] %s  every piece settled (%d of %d)" % ["ok  " if ok else "FAIL", settled, collapse.pieces.pieces.size()])
	fails += 0 if ok else 1
	print("[mine-collapse] survey worst %.1f ms (worker), apply worst %.1f ms (main)" % [
			collapse.worst_survey_ms, collapse.worst_apply_ms])
	# A blast on a piece chips it (PlanetPieces.damage, through the gun's hook).
	var alive := func() -> int:
		var n := 0
		for p in collapse.pieces.pieces:
			n += collapse.bricks.get_alive_block_count(p.chunk)
		return n
	var before: int = alive.call()
	var hit_ok := false
	for p in collapse.pieces.pieces:
		var box := collapse.pieces.world_box(p)
		var q := PhysicsRayQueryParameters3D.create(box.get_center() + Vector3.UP * (box.size.y + 3.0),
				box.get_center() - Vector3.UP * (box.size.y + 3.0))
		var hit := get_world_3d().direct_space_state.intersect_ray(q)
		if hit.is_empty() or hit.collider != p.body:
			print("[mine-collapse]   ray over a piece met %s" % (hit.get("collider") if not hit.is_empty() else "nothing"))
			continue
		var shot := StructuralDamage.for_shot(WeaponClass.builtin(&"grenade"))
		hit_ok = collapse.shoot(hit.position + Vector3.DOWN * 0.05, Vector3.DOWN, shot)
		print("[mine-collapse]   blast at %s on a piece: %s, shot %s" % [hit.position, hit_ok, shot])
		break
	await _frames(30)
	ok = hit_ok and int(alive.call()) < before
	print("[mine-collapse] %s  a blast on a piece chips it (%d bricks -> %d)" % ["ok  " if ok else "FAIL", before, int(alive.call())])
	fails += 0 if ok else 1
	await _collapse_quiet(300)
	var size_of := func(p: PlanetPieces.Piece) -> int:
		return collapse.bricks.get_alive_block_count(p.chunk)
	# Studs: a piece of ground draws its open studs, as the ground does.
	var studded := 0
	for p in collapse.pieces.pieces:
		if p.mesh_node != null:
			for n in p.mesh_node.find_children("*", "MultiMeshInstance3D", true, false):
				if (n as MultiMeshInstance3D).multimesh.instance_count > 0:
					studded += 1
					break
	ok = studded == collapse.pieces.pieces.size() and studded > 0
	print("[mine-collapse] %s  pieces draw their studs (%d of %d)" % ["ok  " if ok else "FAIL", studded, collapse.pieces.pieces.size()])
	fails += 0 if ok else 1
	# Mined in build mode: the brick looked at on a piece goes.
	var arm: PlanetPieces.Piece = null
	for p in collapse.pieces.pieces:
		if arm == null or int(size_of.call(p)) > int(size_of.call(arm)):
			arm = p
	var abox := collapse.pieces.world_box(arm)
	# A point on one of its bricks: straight down onto it.
	var look_at_pt := abox.get_center()
	var dq := PhysicsRayQueryParameters3D.create(abox.get_center() + Vector3.UP * (abox.size.y + 3.0),
			abox.get_center() - Vector3.UP * (abox.size.y + 3.0), Layers.DEBRIS | Layers.FALLING)
	var dh := get_world_3d().direct_space_state.intersect_ray(dq)
	if not dh.is_empty():
		look_at_pt = dh.position
	var cam_at := look_at_pt + Vector3(0.0, 3.0, -2.0)
	var ecam := _eye_camera()
	var keep_xf := ecam.global_transform
	ecam.global_transform = Transform3D(Basis.looking_at(look_at_pt - cam_at, Vector3.UP), cam_at)
	var arm_n0 := int(size_of.call(arm))
	builder.update_target()
	var aimed: bool = not (builder.piece_target as Array).is_empty()
	var mined: bool = builder.break_target()
	ecam.global_transform = keep_xf
	ok = aimed and mined and int(size_of.call(arm)) < arm_n0
	print("[mine-collapse] %s  build mode mines a piece's brick (aimed %s, %d -> %d bricks)" % [
			"ok  " if ok else "FAIL", aimed, arm_n0, int(size_of.call(arm))])
	fails += 0 if ok else 1
	await _frames(10)
	# A pistol wears a piece's brick down and breaks it (StructuralDamage).
	var total := func() -> int:
		var n := 0
		for p in collapse.pieces.pieces:
			n += int(size_of.call(p))
		return n
	var pn0: int = total.call()
	var shots_n := 0
	var down := Vector3.DOWN
	for k in 80:
		var h2 := {}
		for p in collapse.pieces.pieces:
			var pb := collapse.pieces.world_box(p)
			var q2 := PhysicsRayQueryParameters3D.create(pb.get_center() + Vector3.UP * (pb.size.y + 3.0),
					pb.get_center() - Vector3.UP * (pb.size.y + 3.0), Layers.DEBRIS | Layers.FALLING)
			h2 = get_world_3d().direct_space_state.intersect_ray(q2)
			if not h2.is_empty():
				break
		if h2.is_empty():
			break
		var pt: Vector3 = h2.position + down * 0.05
		_mine(pt, down, StructuralDamage.for_shot(null))
		shots_n += 1
		if int(total.call()) < pn0:
			break
		await _frames(1)
	ok = int(total.call()) < pn0
	print("[mine-collapse] %s  pistol rounds break a piece's brick (%d shot(s), %d -> %d bricks in pieces)" % [
			"ok  " if ok else "FAIL", shots_n, pn0, int(total.call())])
	fails += 0 if ok else 1
	await _collapse_quiet(300)
	# Sand dropped onto the fallen arm: it lands ON the piece, as pieces.
	var big: PlanetPieces.Piece = null
	for p in collapse.pieces.pieces:
		if big == null or int(size_of.call(p)) > int(size_of.call(big)):
			big = p
	var on0 := collapse.columns_on_pieces
	if big != null:
		var bb := collapse.pieces.world_box(big)
		var cx := floori(bb.get_center().x / stud)
		var cz := floori(bb.get_center().z / stud)
		var sy := (floori(bb.end.y / plate / 3.0) + 4) * 3
		put.call(Vector3i(cx, sy, cz), Vector3i(cx + 1, sy + 5, cz + 1), 3)
		await _frames(30)
		await _collapse_quiet(400)
		var resting := 0
		for p in collapse.pieces.pieces:
			if p != big and p.settled and collapse.pieces.world_box(p).position.y > bb.position.y + 0.2:
				resting += 1
		ok = collapse.columns_on_pieces > on0 and resting > 0
		print("[mine-collapse] %s  sand dropped on a piece lands on it (%d column(s) met it, %d resting above its foot)" % [
				"ok  " if ok else "FAIL", collapse.columns_on_pieces - on0, resting])
		fails += 0 if ok else 1
		_shot(dev + "mine_collapse_4_sand_on_piece.png")
	else:
		print("[mine-collapse] FAIL  no piece to drop sand on")
		fails += 1
	# The cap: one piece laid, the nearest the player; the bigger rest put away,
	# the small rest deleted; the cap back, the put-away ones laid again.
	var eye0 := _eye()
	var nearest: PlanetPieces.Piece = null
	var big_n := 0
	for p in collapse.pieces.pieces:
		if int(size_of.call(p)) > Collapse.SMALL_MAX:
			big_n += 1
		if nearest == null or eye0.distance_to(collapse.pieces.world_box(p).get_center()) \
				< eye0.distance_to(collapse.pieces.world_box(nearest).get_center()):
			nearest = p
	var laid0 := collapse.pieces.pieces.size()
	var del0 := collapse.deleted
	collapse.max_loaded = 1
	collapse._tend()
	await _frames(60)
	ok = collapse.pieces.pieces.size() == 1 and collapse.pieces.pieces[0] == nearest \
			and collapse.deleted - del0 + collapse.dormant_count() == laid0 - 1
	print("[mine-collapse] %s  cap 1: the nearest kept, %d put away, %d deleted (of %d)" % [
			"ok  " if ok else "FAIL", collapse.dormant_count(), collapse.deleted - del0, laid0])
	fails += 0 if ok else 1
	collapse.max_loaded = Collapse.MAX_LOADED
	collapse._tend()
	await _frames(5)
	var want_laid := big_n + (0 if int(size_of.call(nearest)) > Collapse.SMALL_MAX else 1)
	ok = collapse.pieces.pieces.size() == want_laid and collapse.dormant_count() == 0
	print("[mine-collapse] %s  cap back: %d piece(s) laid (want %d: the big ones and the nearest)" % [
			"ok  " if ok else "FAIL", collapse.pieces.pieces.size(), want_laid])
	fails += 0 if ok else 1
	# Fly off past the detail tiles: big pieces unloaded, small ones deleted;
	# back: the big ones laid again.
	var kept := 0
	for p in collapse.pieces.pieces:
		kept += 1 if int(size_of.call(p)) > Collapse.SMALL_MAX else 0
	var home := walker.global_position
	walker.place(home + Vector3(260.0, 40.0, 0.0), Vector3(1, 0, 0))
	await _frames(180)
	collapse._tend()
	ok = collapse.dormant_count() == kept and collapse.pieces.pieces.is_empty()
	print("[mine-collapse] %s  flown off: %d piece(s) unloaded (want %d), %d laid" % ["ok  " if ok else "FAIL", collapse.dormant_count(), kept, collapse.pieces.pieces.size()])
	fails += 0 if ok else 1
	walker.place(home, Vector3(0, 0, 1))
	await _frames(180)
	collapse._tend()
	ok = collapse.pieces.pieces.size() == kept and collapse.dormant_count() == 0
	print("[mine-collapse] %s  back: %d piece(s) laid again" % ["ok  " if ok else "FAIL", collapse.pieces.pieces.size()])
	fails += 0 if ok else 1
	# Saved and loaded with the world.
	_edits_dirty = true
	save_edits(true)
	ok = FileAccess.file_exists(_pieces_path(save_path()))
	var s2 := settings.duplicate(true)
	settings = {}
	generate(s2)
	walker.place(home, Vector3(0, 0, 1))
	await _frames(180)
	collapse._tend()
	ok = ok and collapse.pieces.pieces.size() == kept
	print("[mine-collapse] %s  saved and loaded: %d piece(s) back of %d" % ["ok  " if ok else "FAIL", collapse.pieces.pieces.size(), kept])
	fails += 0 if ok else 1
	_shot(dev + "mine_collapse_5_reloaded.png")
	print("[mine-collapse] %s" % collapse.readout())
	print("[mine-collapse] %s (%d failures)" % ["PASS" if fails == 0 else "FAIL", fails])


## Until nothing is surveyed, waiting, falling or moving, at most `frames`.
func _collapse_quiet(frames: int) -> void:
	for i in frames:
		await get_tree().process_frame
		if not collapse.busy():
			return


func _run_cave_gate() -> void:
	await _frames(30)
	await _gate_cave()
	get_tree().quit()


## Fly into a cave, land (F), and the pawn must still be standing on the
## cave floor a few seconds later: cave floors had no collider and the pawn
## fell through bricks it could see (Docs/MineWorld.md 13). The cave is one
## the player can reach: its floor is inside one of the tile's boxes (a
## sealed chamber has no faces and no collider, and nobody gets in).
func _gate_cave() -> void:
	set_on_foot(false)
	var stud := BrickWorld.get_stud_metres()
	var plate := BrickWorld.get_plate_metres()
	var e := _eye()
	var c0 := Vector2i(floori(e.x / stud), floori(e.z / stud))
	var found := Vector3.INF
	var tile_studs := BrickTerrain.get_tile_studs()
	var boxes_of := {}
	for r in range(0, 400, 4):
		for k in 8:
			var a := TAU * k / 8.0 + r * 0.37
			var x := c0.x + int(r * cos(a))
			var z := c0.y + int(r * sin(a))
			var top := BrickTerrain.surface_plate(x, z)
			var yp := top - 4
			var lo := top - 600
			while yp > lo and BrickTerrain.solid_at(x, yp, z) != 0:
				yp -= 1
			var air := 0
			while yp > lo and BrickTerrain.solid_at(x, yp, z) == 0:
				yp -= 1
				air += 1
			if yp <= lo or air < 22:
				continue
			var t := Vector2i(floori(float(x) / tile_studs), floori(float(z) / tile_studs))
			if not boxes_of.has(t):
				boxes_of[t] = (BrickTerrain.build_tile(t.x, t.y) as Dictionary).boxes
			var boxes: PackedFloat32Array = boxes_of[t]
			var p := Vector3((x - t.x * tile_studs + 0.5) * stud, (yp + 1) * plate - 0.03,
					(z - t.y * tile_studs + 0.5) * stud)
			for o in range(0, boxes.size(), 6):
				if absf(p.x - boxes[o]) <= boxes[o + 3] * 0.5 and absf(p.y - boxes[o + 1]) <= boxes[o + 4] * 0.5 						and absf(p.z - boxes[o + 2]) <= boxes[o + 5] * 0.5:
					found = Vector3((x + 0.5) * stud, (yp + 1) * plate, (z + 0.5) * stud)
					break
			if found != Vector3.INF:
				break
		if found != Vector3.INF:
			break
	if found == Vector3.INF:
		print("[mine-cave] no reachable cave within 400 studs: SKIPPED")
		return
	# Fly in, let the tiles round it build, land.
	_fly_to(found + Vector3(0, 0.4, 0), Vector3(1, 0, 0))
	walker.pitch = -0.3
	await _frames(90)
	set_on_foot(true)
	var t0 := to_local(pawn.feet())
	var low := t0.y
	for f in 200:
		await get_tree().physics_frame
		low = minf(low, pawn.feet().y)
	var t1 := to_local(pawn.feet())
	print("[mine-cave] landed in a cave %.0f m under the surface at %s: feet %.2f m above the floor at landing, %.2f m after 200 ticks (lowest %.2f) -- %s"
			% [_ground_m(floori(found.x / stud), floori(found.z / stud)) - found.y, found,
			t0.y - found.y, t1.y - found.y, low - found.y,
			"STANDING" if absf(t1.y - found.y) < 0.6 and low > found.y - 1.0 else "FELL"])
	await _shot(UserPaths.DEV + "mine_cave_landing.png")


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
	# The platform floats: the ground's own collapse (ground_collapse.gd)
	# would bring it down. This pass is about the water.
	if collapse != null:
		collapse.process_mode = Node.PROCESS_MODE_DISABLED
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
		_fly_to(from, ((at - from) * Vector3(1, 0, 1)).normalized())
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

	# Lava (stage 6): a walled pool on the east side, at night for its glow
	# and its lights; a pawn in it burns; cut off, it cools into stone.
	lay.call(19, 5, 29, 5, w, w, dark)
	lay.call(19, 13, 29, 13, w, w, dark)
	lay.call(19, 5, 19, 13, w, w, dark)
	lay.call(29, 5, 29, 13, w, w, dark)
	# A wood block in the pool: lava sets it alight and it burns away.
	var wood_id := BrickTerrain.material_names().find("wood")
	lay.call(24, 7, 24, 7, w, w, wood_id)
	lay.call(24, 7, 24, 7, w + 1, w + 1, wood_id)
	var lava_src := [Vector3i(o.x + 22, w, o.y + 9), Vector3i(o.x + 26, w, o.y + 9)]
	for c in lava_src:
		BrickFluid.place(c, 2, BrickFluid.SOURCE, 3)
	water.step(150)
	await _frames(20)
	_time = 0.02
	view.process_mode = Node.PROCESS_MODE_DISABLED
	view.rig.visible = false
	if view.arms != null:
		view.arms.visible = false
	_hud_layer.visible = false
	look.call(pm.call(14.0, w + 6.0, 1.0), pm.call(24.0, w, 9.0))
	await _frames(40)
	await _shot(dev + "water_lava_night.png")
	print("[water-gate] lava pool: %d lava lights, %d burning, %s" % [water.lava_lights(), water.fires.burning.size(), water.report()])
	_time = 0.42
	view.process_mode = Node.PROCESS_MODE_INHERIT
	_hud_layer.visible = true
	set_on_foot(true, pm.call(24.0, w + 0.2, 9.0))
	await _frames(5)
	var hp0: float = pawn.health.total_current()
	await _frames(60)
	var hp1: float = pawn.health.total_current()
	print("[water-gate] a pawn in lava: health %.0f -> %.0f over 60 frames (burning %s)" % [
			hp0, hp1, hp1 < hp0])
	pawn.health.reset()
	set_on_foot(false)
	for c in lava_src:
		BrickFluid.remove(c, -1)
	var rock0: int = water.rock_laid
	for i in 600:
		await get_tree().process_frame
		if water.fires.burning.is_empty() and water.fires.burned > 0:
			break
	print("[water-gate] fire: %d plates of wood burned away, %d still burning" % [water.fires.burned, water.fires.burning.size()])
	water.step(900)
	await _frames(30)
	var lava_left := 0
	for x in range(20, 29):
		for z in range(6, 13):
			if int(BrickFluid.cell_info(Vector3i(o.x + x, w, o.y + z)).fluid) == 2:
				lava_left += 1
	print("[water-gate] the pool cut off: %d cells cooled into stone, %d lava left (want 0), %d lights" % [
			water.rock_laid - rock0, lava_left, water.lava_lights()])
	view.process_mode = Node.PROCESS_MODE_DISABLED
	view.rig.visible = false
	if view.arms != null:
		view.arms.visible = false
	_hud_layer.visible = false
	look.call(pm.call(14.0, w + 6.0, 1.0), pm.call(24.0, w, 9.0))
	await _frames(30)
	await _shot(dev + "water_lava_cooled.png")
	view.process_mode = Node.PROCESS_MODE_INHERIT
	_hud_layer.visible = true

	# Floating and sinking (stage 8): a tank three bricks deep, a wood brick
	# and a stone brick dropped in. By the majority rule, a piece mostly wood
	# floats and one mostly stone sinks.
	lay.call(21, 16, 31, 16, w, w + 2, dark)
	lay.call(21, 28, 31, 28, w, w + 2, dark)
	lay.call(21, 16, 21, 28, w, w + 2, dark)
	lay.call(31, 16, 31, 28, w, w + 2, dark)
	for x in range(22, 31):
		for z in range(17, 28):
			for b in range(w, w + 3):
				BrickFluid.place(Vector3i(o.x + x, b, o.y + z), 1, BrickFluid.STILL, 3)
	water.step(3)
	var names := BrickTerrain.material_names()
	var wood_col := BrickWorld.get_filament_colour(BrickTerrain.material_filament_index(names.find("wood")))
	var stone_col := BrickWorld.get_filament_colour(BrickTerrain.material_filament_index(names.find("stone")))
	var drop_at: Vector3 = pm.call(26.0, w + 5.0, 22.0)
	var buf := PackedFloat32Array([drop_at.x - 0.6, drop_at.y, drop_at.z, 0.35, 0.42, 0.35, wood_col.r, wood_col.g, wood_col.b,
			drop_at.x + 0.6, drop_at.y, drop_at.z, 0.35, 0.42, 0.35, stone_col.r, stone_col.g, stone_col.b])
	var n0: int = debris.bodies.size()
	debris.spawn(buf, drop_at + Vector3(0, 3, 0))
	var wood_b: RigidBody3D = debris.bodies[n0] if debris.bodies.size() > n0 else null
	var stone_b: RigidBody3D = debris.bodies[n0 + 1] if debris.bodies.size() > n0 + 1 else null
	if wood_b != null and stone_b != null:
		wood_b.linear_velocity = Vector3.ZERO
		stone_b.linear_velocity = Vector3.ZERO
	for i in 180:
		await get_tree().physics_frame
	var surf := (w + 3) * course
	var bed := w * course
	if wood_b != null and stone_b != null and is_instance_valid(wood_b) and is_instance_valid(stone_b):
		var wy := to_local(wood_b.global_position).y
		var sy := to_local(stone_b.global_position).y
		print("[water-gate] debris in a tank (surface %.2f m, bed %.2f m): wood at %.2f m (floating %s), stone at %.2f m (sunk %s); %s" % [
				surf, bed, wy, absf(wy - surf) < 0.35, sy, sy < bed + 0.5, water.report()])
	else:
		print("[water-gate] FAIL the debris bricks were not made")
	var fl8: Node = water.floaters
	print("[water-gate] majority: wood, wood, stone -> %.2f (floats %s); stone, stone, wood -> %.2f (sinks %s); leaves -> %.2f" % [
			fl8.majority_density(["wood", "wood", "stone"]), fl8.majority_density(["wood", "wood", "stone"]) < 1.0,
			fl8.majority_density(["stone", "stone", "wood"]), fl8.majority_density(["stone", "stone", "wood"]) > 1.0,
			fl8.majority_density(["leaves"])])
	view.process_mode = Node.PROCESS_MODE_DISABLED
	view.rig.visible = false
	if view.arms != null:
		view.arms.visible = false
	_hud_layer.visible = false
	look.call(pm.call(26.0, w + 6.0, 31.0), pm.call(26.0, w + 2.0, 22.0))
	debris.spawn(buf, drop_at + Vector3(0, 3, 0))
	for i in 120:
		await get_tree().physics_frame
	await _shot(dev + "water_float.png")
	view.process_mode = Node.PROCESS_MODE_INHERIT
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
	# Saving (stage 7): the water written beside the edits, the world made
	# again from its settings, the same water back.
	water.manual = true
	water.step(1)
	var before := _platform_fluid(o, w)
	save_edits(true)
	var s2 := settings.duplicate(true)
	settings = {}
	generate(s2)
	water.manual = true
	# The saved cells applied, the rules paused: running water would run on
	# after a load (as it should) and the count would not be the save's.
	BrickFluid.set_simulating(false)
	water.step(2)
	var after := _platform_fluid(o, w)
	BrickFluid.set_simulating(true)
	print("[water-gate] save: water on the platform %s before, %s after generating again (%s)" % [
			before, after, _save_status])
	print("[water-gate] done")
	get_tree().quit()


## The sea pass: -- --gate=sea (Docs/MineWater.md 14, stages 3 and 4). The
## generated sea drawn by the wave tiers at a coast, a river mouth, a channel
## dug off the sea filling, then the player: swimming, under water, a bucket.
func _run_sea_gate() -> void:
	await _frames(10)
	var dev := UserPaths.DEV
	DirAccess.make_dir_recursive_absolute(dev)
	_time = 0.42
	var stud := BrickWorld.get_stud_metres()
	var sea_b := BrickFluid.get_sea_course()
	var level := BrickFluid.get_sea_level()
	print("[sea-gate] sea on %s at %.2f m (course %d); first shore field %.0f ms" % [
			water.sea_on, level, sea_b, water.last_field_ms])
	# A coast: out from the spawn until the ground is a few bricks under the
	# sea, the last dry column before it the shore.
	var e := _eye()
	var c0 := Vector2i(floori(e.x / stud), floori(e.z / stud))
	var coast := Vector2i(1 << 30, 0)
	var shore := Vector2i.ZERO          ## the last dry column before it
	var dir := Vector2.ZERO
	for a in 16:
		var d := Vector2(cos(a * TAU / 16.0), sin(a * TAU / 16.0))
		var dry := false
		var last_dry := Vector2i.ZERO
		for r in range(0, 12000, 4):
			var p := c0 + Vector2i(d * r)
			var h := BrickTerrain.surface_plate(p.x, p.y)
			if h >= sea_b * 3:
				dry = true
				last_dry = p
			elif dry and h < sea_b * 3 - 9:
				coast = p
				shore = last_dry
				dir = d
				break
		if coast.x != 1 << 30:
			break
	if coast.x == 1 << 30:
		print("[sea-gate] FAIL no coast within 12000 studs")
		get_tree().quit()
		return
	set_on_foot(false)
	var cm := Vector3((coast.x + 0.5) * stud, level, (coast.y + 0.5) * stud)
	var from := cm - Vector3(dir.x, 0, dir.y) * 26.0 + Vector3(0, 9, 0)
	_fly_to(from, Vector3(dir.x, 0, dir.y))
	walker.pitch = -0.3
	var moves0: int = water.field_moves
	for i in 600:
		await get_tree().process_frame
		if water.field_moves > moves0 and i > 120:
			break
	await _frames(60)
	print("[sea-gate] coast at %s (%.0f m out); field moved %d times, last %.0f ms; %s" % [
			coast, Vector2(coast - c0).length() * stud, water.field_moves - moves0,
			water.last_field_ms, water.report()])
	view.process_mode = Node.PROCESS_MODE_DISABLED
	view.rig.visible = false
	if view.arms != null:
		view.arms.visible = false
	_hud_layer.visible = false
	await _shot(dev + "sea_coast.png")
	# The beach close by, three times a second apart: the swash running up
	# the sand and back (water.gdshader swash_delay).
	var shore_m := Vector3((shore.x + 0.5) * stud, level, (shore.y + 0.5) * stud)
	var along := Vector3(-dir.y, 0, dir.x)
	walker.place(to_global(shore_m - Vector3(dir.x, 0, dir.y) * 3.0 + along * 4.0 + Vector3(0, 1.6, 0)),
			(Vector3(dir.x, 0, dir.y) * 0.6 - along).normalized())
	walker.pitch = -0.35
	await _frames(40)
	for k in 3:
		await _shot(dev + "sea_beach_%d.png" % k)
		await _frames(60)
	# A river mouth: a river column under the sea line near the coast.
	var river := Vector2i(1 << 30, 0)
	for r in range(16, 900, 16):
		for a in 24:
			var p := coast + Vector2i(Vector2(cos(a * TAU / 24.0), sin(a * TAU / 24.0)) * r)
			var bn: String = _biome_names[BrickTerrain.biome_at(p.x, p.y)]
			if bn.contains("River") and BrickTerrain.surface_plate(p.x, p.y) < sea_b * 3:
				river = p
				break
		if river.x != 1 << 30:
			break
	if river.x != 1 << 30:
		var rm := Vector3((river.x + 0.5) * stud, level, (river.y + 0.5) * stud)
		_fly_to(rm + Vector3(-14, 10, -14), Vector3(1, 0, 1).normalized())
		walker.pitch = -0.45
		await _frames(150)
		print("[sea-gate] river mouth at %s, water there %d" % [river, water.fluid_at(rm - Vector3(0, 0.2, 0))])
		await _shot(dev + "sea_river.png")
	else:
		print("[sea-gate] no river under the sea line within 900 studs of the coast")
	# A channel dug off the sea, 3 studs wide, 14 long, two bricks under the
	# sea line: from just off the shore into the dry land, and the sea runs in.
	var back := -dir
	var side := Vector2(-back.y, back.x)
	var start := shore + Vector2i((dir * 3.0).round())
	for i in 14:
		var p := start + Vector2i((back * i).round())
		for w in range(-1, 2):
			var q := p + Vector2i((side * w).round())
			var h := BrickTerrain.surface_plate(q.x, q.y)
			var r: Dictionary = BrickTerrain.fill_box(Vector3i(q.x, (sea_b - 2) * 3, q.y),
					Vector3i(q.x, maxi(h, (sea_b - 2) * 3), q.y), 0, false)
			terrain_edited(r)
	water.manual = true
	water.step(60)
	await _frames(30)
	var wet := 0
	var calm := 0
	for i in range(2, 14):
		var p := start + Vector2i((back * i).round())
		var ci: Dictionary = BrickFluid.cell_info(Vector3i(p.x, sea_b - 2, p.y))
		if int(ci.fluid) == 1:
			wet += 1
			if not bool(ci.ocean):
				calm += 1
	print("[sea-gate] channel: %d of 12 cells along it wet (%d calm, drawn by the fluid mesher), %s" % [
			wet, calm, water.report()])
	var chm := Vector3((start.x + back.x * 7 + 0.5) * stud, level, (start.y + back.y * 7 + 0.5) * stud)
	_fly_to(chm + Vector3(side.x, 0, side.y) * 4.0 + Vector3(0, 4, 0), -Vector3(side.x, 0, side.y))
	walker.pitch = -0.6
	await _frames(40)
	await _shot(dev + "sea_channel.png")
	water.manual = false
	# Swimming: the pawn put three metres under the sea, off the coast.
	var dc := coast
	for r in range(0, 3000, 4):
		var p := coast + Vector2i(dir * r)
		if _ground_m(p.x, p.y) < level - 3.5:
			dc = p
			break
	var deep := Vector3((dc.x + 0.5) * stud, level - 3.0, (dc.y + 0.5) * stud)
	set_on_foot(true, deep)
	await _frames(20)
	var under: bool = water.fluid_at(_eye()) == 1
	var feet_t := to_local(pawn.feet())
	var fc := BrickFluid.cell_of(feet_t + Vector3.UP * 0.05)
	print("[sea-gate] swimmer put at %s, feet %s (ground %.1f m), cell %s %s, surface %.2f, probe set %s" % [
			deep, feet_t, _ground_m(fc.x, fc.z), fc, BrickFluid.cell_info(fc),
			water.surface_at(feet_t + Vector3.UP * 0.05), Pawn.water_probe.is_valid()])
	await _shot(dev + "sea_underwater.png")
	await _frames(150)
	var top: float = water.surface_at(to_local(pawn.feet()) + Vector3.UP * 0.05)
	print("[sea-gate] swim: under water at first %s, swimming %s, eye %.2f m over the surface after 3 s (want about +0.1)" % [
			under, pawn.moves != null and pawn.moves.swimming, _eye().y - top])
	# A bucket: filled from the sea, poured on dry land.
	set_on_foot(false)
	_fly_to(cm - Vector3(dir.x, 0, dir.y) * 2.0 + Vector3(0, 2.2, 0), Vector3(dir.x, 0, dir.y))
	walker.pitch = -0.8
	await _frames(10)
	builder.set_active(true)
	builder.select(&"bucket")
	var filled: bool = builder.take_fluid()
	var held: int = builder.bucket_tiles()
	var land := shore - Vector2i((dir * 10.0).round())
	_fly_to(Vector3((land.x + 0.5) * stud, _ground_m(land.x, land.y) + 2.0, (land.y + 0.5) * stud),
			-Vector3(dir.x, 0, dir.y))
	walker.pitch = -1.45
	await _frames(10)
	builder.update_target()
	print("[sea-gate] pour target %s" % builder.target)
	var poured: bool = builder.place_target()
	water.step(1)
	print("[sea-gate] bucket: filled from the sea %s (%d tiles), poured %s (%d left), %s" % [
			filled, held, poured, builder.bucket_tiles(), builder.log_blocks.slice(-3)])
	builder.set_active(false)
	view.process_mode = Node.PROCESS_MODE_INHERIT
	_hud_layer.visible = true
	print("[sea-gate] done")
	get_tree().quit()


## The generated-fluid pass: -- --gate=gen (Docs/MineWater.md stage 8).
## Springs out of cliff faces near the spawn once their tiles are primed,
## and a lava pool in a deep cave, seen down a shaft dug to it.
func _run_gen_gate() -> void:
	await _frames(10)
	# The ground's collapse is paused (this pass is about the water): with it,
	# the 120 m shaft dug to the lava crashed the scene about half the runs
	# (2026-11-19, no backtrace; not the water's thread, which reports its own
	# crashes now). `--with-collapse` runs it to reproduce that.
	if not "--with-collapse" in OS.get_cmdline_user_args() and collapse != null:
		collapse.process_mode = Node.PROCESS_MODE_DISABLED
	var dev := UserPaths.DEV
	DirAccess.make_dir_recursive_absolute(dev)
	_time = 0.42
	var stud := BrickWorld.get_stud_metres()
	var course := BrickWorld.get_plate_metres() * 3.0
	set_on_foot(false)
	view.process_mode = Node.PROCESS_MODE_DISABLED
	view.rig.visible = false
	if view.arms != null:
		view.arms.visible = false
	_hud_layer.visible = false
	for i in 240:
		await get_tree().process_frame
	print("[gen-gate] primed %d tiles; %s" % [water.primed_count, water.report()])
	# A spring: running water, not the sea, in a tile near the eye.
	var e := _eye()
	var c0 := Vector2i(floori(e.x / stud), floori(e.z / stud))
	var spring := Vector3i(1 << 30, 0, 0)
	var sea_b := BrickFluid.get_sea_course()
	var best_d := 1 << 30
	for dz in range(-96, 97):
		for dx in range(-96, 97):
			var p := c0 + Vector2i(dx, dz)
			var top := floori(BrickTerrain.surface_plate(p.x, p.y) / 3.0)
			if top < sea_b + 2 or dx * dx + dz * dz >= best_d:
				continue
			for k in range(0, 3):
				var ci: Dictionary = BrickFluid.cell_info(Vector3i(p.x, top + k, p.y))
				if int(ci.fluid) == 1 and not bool(ci.ocean):
					spring = Vector3i(p.x, top + k, p.y)
					best_d = dx * dx + dz * dz
					break
	if spring.x != 1 << 30:
		var sm := Vector3((spring.x + 0.5) * stud, spring.y * course, (spring.z + 0.5) * stud)
		walker.place(to_global(sm + Vector3(-6, 5, -6)), Vector3(1, 0, 1).normalized())
		walker.pitch = -0.5
		await _frames(60)
		print("[gen-gate] water from a spring at %s (%.0f m from the spawn view)" % [
				spring, Vector2(spring.x - c0.x, spring.z - c0.y).length() * stud])
		await _shot(dev + "gen_spring.png")
	else:
		print("[gen-gate] FAIL no spring water within 160 studs")
	# A lava pool: cave air under the lava line near the spawn.
	var lava_b := floori((float(settings.gen.get("sea_m", 20.0)) + float(settings.gen.get("lava_m", -4.0))) / course)
	var pool := Vector2i(1 << 30, 0)
	for r in range(0, 2000, 4):
		for a in 16:
			var p := c0 + Vector2i(Vector2(cos(a * TAU / 16.0), sin(a * TAU / 16.0)) * r)
			if int(BrickFluid.cell_info(Vector3i(p.x, lava_b - 1, p.y)).fluid) == 2:
				pool = p
				break
		if pool.x != 1 << 30:
			break
	if pool.x == 1 << 30:
		print("[gen-gate] FAIL no lava pool within 2000 studs")
	else:
		if "--no-water" in OS.get_cmdline_user_args():
			# Bisecting a crash: the water stopped before the shaft is dug.
			water.process_mode = Node.PROCESS_MODE_DISABLED
			water.manual = true
		# A shaft 4 x 4 down to just over the lava, to look into the cave.
		var top := BrickTerrain.surface_plate(pool.x, pool.y)
		for z in range(pool.y - 2, pool.y + 2):
			var r: Dictionary = BrickTerrain.fill_box(Vector3i(pool.x - 2, lava_b * 3, z),
					Vector3i(pool.x + 1, top + 3, z), 0, false)
			terrain_edited(r)
		var pm := Vector3((pool.x + 0.5) * stud, lava_b * course, (pool.y + 0.5) * stud)
		walker.place(to_global(pm + Vector3(0.2, 3.0, 0.2)), Vector3(1, 0, 0))
		walker.pitch = -1.45
		# The deep tier (terrain_deep.gd) streams the caves round the eye once
		# it is under ground: time for it.
		for i in 420:
			await get_tree().process_frame
		print("[gen-gate] lava pool at %s course %d, %.0f m down from the surface; %s" % [
				pool, lava_b - 1, (top / 3.0 - lava_b) * course, water.report()])
		await _shot(dev + "gen_lava.png")
		walker.place(to_global(Vector3(pm.x + 0.2, (top + 6) * BrickWorld.get_plate_metres(), pm.z + 0.2)), Vector3(1, 0, 0))
		walker.pitch = -1.5
		await _frames(30)
		await _shot(dev + "gen_lava_top.png")

	# A lake over the sea (stage 8), nearest the spawn.
	var lake := Vector2i(1 << 30, 0)
	var lake_top := 0
	for r in range(0, 3000, 16):
		for a in 32:
			var p := c0 + Vector2i(Vector2(cos(a * TAU / 32.0), sin(a * TAU / 32.0)) * r)
			var lt := BrickFluid.lake_top(p.x, p.y)
			if lt != -2147483648:
				lake = p
				lake_top = lt
				break
		if lake.x != 1 << 30:
			break
	if lake.x == 1 << 30:
		print("[gen-gate] FAIL no lake within 3000 studs")
	else:
		var lm := Vector3((lake.x + 0.5) * stud, (lake_top + 1) * course, (lake.y + 0.5) * stud)
		walker.place(to_global(lm + Vector3(-14, 8, -14)), Vector3(1, 0, 1).normalized())
		walker.pitch = -0.45
		for i in 240:
			await get_tree().process_frame
		print("[gen-gate] lake at %s, level course %d (%.1f m over the sea), water there %d" % [
				lake, lake_top, (lake_top + 1) * course - BrickFluid.get_sea_level(),
				water.fluid_at(lm - Vector3(0, 0.2, 0))])
		await _shot(dev + "gen_lake.png")
	# A cave pool: water in cave air under the ground near the spawn, seen
	# down a shaft dug to just over it.
	var pool_at := Vector3i(1 << 30, 0, 0)
	for r in range(0, 400, 6):
		for a in 16:
			var p := c0 + Vector2i(Vector2(cos(a * TAU / 16.0), sin(a * TAU / 16.0)) * r)
			var top := floori(BrickTerrain.surface_plate(p.x, p.y) / 3.0)
			for b in range(top - 40, top - 4):
				var ci: Dictionary = BrickFluid.cell_info(Vector3i(p.x, b, p.y))
				if int(ci.fluid) != 1 or bool(ci.ocean) or int(ci.solid) != 0:
					continue
				# Cave air over it, four courses: room for the eye.
				var room := true
				for k in range(1, 5):
					var up: Dictionary = BrickFluid.cell_info(Vector3i(p.x, b + k, p.y))
					if int(up.fluid) != 0 or int(up.capacity) < 3:
						room = false
						break
				if room:
					pool_at = Vector3i(p.x, b, p.y)
					break
			if pool_at.x != 1 << 30:
				break
		if pool_at.x != 1 << 30:
			break
	if pool_at.x == 1 << 30:
		print("[gen-gate] FAIL no cave pool within 400 studs")
	else:
		var ptop := BrickTerrain.surface_plate(pool_at.x, pool_at.z)
		# In the cave over it (nothing dug: a shaft through the pools higher
		# up let their water pour down onto the eye).
		var pp := Vector3((pool_at.x + 0.5) * stud, (pool_at.y + 1) * course, (pool_at.z + 0.5) * stud)
		walker.place(to_global(pp + Vector3(0.0, 0.9, 0.0)), Vector3(1, 0, 0))
		walker.pitch = -0.7
		for i in 420:
			await get_tree().process_frame
		print("[gen-gate] cave pool at %s, %.0f m under the ground; deep tier %s" % [
				pool_at, (ptop / 3.0 - pool_at.y) * course, _deep.report()])
		await _shot(dev + "gen_pool.png")
	view.process_mode = Node.PROCESS_MODE_INHERIT
	_hud_layer.visible = true
	print("[gen-gate] done")
	get_tree().quit()


## Water and lava on the platform: [cells, tiles of water, tiles of lava].
func _platform_fluid(o: Vector2i, w: int) -> Array:
	var cells := 0
	var wt := 0
	var lt := 0
	for x in range(-31, 32):
		for z in range(-31, 32):
			for b in range(w, w + 7):
				var c: Dictionary = BrickFluid.cell_info(Vector3i(o.x + x, b, o.y + z))
				if int(c.fluid) == 0:
					continue
				cells += 1
				if int(c.fluid) == 1:
					wt += int(c.amount)
				else:
					lt += int(c.amount)
	return [cells, wt, lt]


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
## -- --gate=mega: the Mega Pickaxe against the pickaxe, looking down at flat
## ground: the plate cells one break clears, and the hold repeat of each.
func _run_mega_gate() -> void:
	await _frames(30)
	set_on_foot(false)
	var stud := BrickWorld.get_stud_metres()
	var e := _eye()
	var c := Vector2i(floori(e.x / stud), floori(e.z / stud))
	var res := {}
	for tool in [&"pickaxe", &"mega_pickaxe"]:
		var g := _ground_m(c.x, c.y)
		_fly_to(Vector3((c.x + 0.5) * stud, g + 2.0, (c.y + 0.5) * stud), Vector3(0, 0, -1))
		walker.pitch = -1.45
		await _frames(20)
		builder.set_active(true)
		var picked: bool = builder.select(tool)
		builder.update_target()
		var before := BrickTerrain.get_edit_count()
		var ok: bool = builder.break_target()
		await _frames(30)
		res[tool] = [picked, ok, BrickTerrain.get_edit_count() - before, builder._break_repeat()]
		await _shot(UserPaths.DEV + "mine_%s.png" % tool)
		c += Vector2i(40, 0)
	builder.set_active(false)
	var s: int = builder.block_studs()
	print("[mine-mega] block %d x %d studs; pickaxe: held %s, broke %s, %d cells, every %.2f s; Mega Pickaxe: held %s, broke %s, %d cells (a full 5 x 5 face is %d), every %.2f s"
			% [s, s, res.pickaxe[0], res.pickaxe[1], res.pickaxe[2], res.pickaxe[3],
			res.mega_pickaxe[0], res.mega_pickaxe[1], res.mega_pickaxe[2], 25 * s * s * 3, res.mega_pickaxe[3]])
	get_tree().quit()


func _gate_build() -> void:
	set_on_foot(false)
	var e := _eye()
	var stud := BrickWorld.get_stud_metres()
	var c := Vector2i(floori(e.x / stud), floori(e.z / stud))
	var g := _ground_m(c.x, c.y)
	_fly_to(Vector3(e.x, g + 2.4, e.z), Vector3(0, 0, -1))
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
	_fly_to(Vector3(e.x + 2.5, g + 3.2, e.z + 2.5), Vector3(-1, 0, -1))
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
	# Frames where a tile near the camera was drawn flat or without its
	# studs (the flicker round an edit): 0 since a refresh swaps whole.
	var bare := 0
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
			if _streamer.bare_near_tiles() > 0:
				bare += 1
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
			if _streamer.bare_near_tiles() > 0:
				bare += 1
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
	print("[mine-gate] %s flicker: %d of 300 edit frames drew a near tile flat or bare (want 0)" % [
			"ok  " if bare == 0 else "FAIL", bare])
	var keys := TerrainTile.instance_ms.keys()
	keys.sort()
	print("[mine-gate] instances phase, worst by step: %s" % ", ".join(keys.map(
			func(k: String) -> String: return "%s %.1f" % [k, TerrainTile.instance_ms[k]])))
	# A look at what the shots left: whole bricks gone, the rest as laid.
	set_on_foot(false)
	_fly_to(e + Vector3(5.5, 2.5, 0.5), Vector3(-0.3, 0.0, -1.0).normalized())
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


## The viewport's mean brightness (0..1), for the gates' light checks.
func _mean_luma() -> float:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.resize(64, 36)
	var s := 0.0
	for y in 36:
		for x in 64:
			s += img.get_pixel(x, y).get_luminance()
	return s / (64.0 * 36.0)


func _shot(path: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(path)
	print("[mine-gate] shot %s" % path)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame
