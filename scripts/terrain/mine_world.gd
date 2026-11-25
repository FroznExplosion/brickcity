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
##       1-9 / wheel: the hotbar slot in the hands -- a gun fires, anything else
##       builds (MineHands, mine_builder.gd; Docs/Inventory.md 10). No arsenal here.
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
const TREE_NEAR_M := 25.0
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
## --gate=breaklag: each shot's time and when its brick was found and cleared.
var break_log: Array = []
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
## What is in the hands: the selected slot, a gun or not (Docs/Inventory.md 10).
var hands: MineHands = null
## Sky light on collapse pieces, drops and chests (Docs/MineWorld.md 19);
## null with --no-sky-light.
var sky_lit: MineSkyLit = null
## THE BRICK OVERLAY (Docs/BrickOverlay.md): real bevelled bricks over the
## flat ground near the eye. On with the world setting Chamfered brick edges
## (off: the flat ground alone).
var bricks: TerrainBricks = null
var _overlay_on := false

## Saving the world's changes (Docs/MineWorld.md 9): one file per seed and
## generator settings, under UserPaths.SAVES (a scripted pass: user://dev/).
const SAVE_MAGIC := "BCME"
## The edits by region (Docs/MineWorld.md 9): `<save>.regions/r_<rx>_<rz>.edits`,
## zstd, REGION_MAGIC, format, field version, rx, rz, count, the 13-byte records.
const REGION_MAGIC := "BCMR"
const REGION_FORMAT := 1
## A one-file save was loaded: the next save writes every region and drops it.
var _migrate_old := false
## The main thread's part of the last save, ms (the readout; --gate=save).
var last_save_ms := 0.0


static func _regions_dir(edits_path: String) -> String:
	return edits_path.get_basename() + ".regions"


func path_for_regions() -> String:
	return save_path()


## A folder and the files in it (a save's region folder).
static func _remove_dir(dir_path: String) -> void:
	var d := DirAccess.open(dir_path)
	if d == null:
		return
	for f in d.get_files():
		d.remove(f)
	DirAccess.remove_absolute(dir_path)
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
##
## 0 now (2026-11-21, --gate=breaklag): every edit is handed over the frame
## it lands, and the edits of one frame still make one bake a tile (the
## streamer starts its bakes once a frame). Bakes of one tile may overlap
## (TerrainStreamer's edit generations: the newest that lands is shown), so
## nothing is stale any more; at 0.1 s the second and third of three bricks
## broken at once waited a tenth of a second before their tiles were marked.
const REFRESH_EVERY := 0.0
var _coalesce := true
var _pending_tiles := Rect2i()
var _refresh_in := 0.0
## BLOCK LIGHT (Docs/MineWorld.md 18): the tiles the water says lava lit or
## went dark round (BrickFluid.take's "lava_light") -> Vector2i(first, last
## plate), rebaked at most every LAVA_RELIGHT_EVERY: running lava changes
## cells twice a second.
const LAVA_RELIGHT_EVERY := 0.5
var _lava_relight := {}
var _lava_relight_in := 0.0
var lava_relit_tiles := 0
var _gen_ms := 0.0
var _reanchors := 0
var _last_reanchor_ms := 0.0
var _reanchor_parts := ""
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
			for sub in old.get_directories():
				_remove_dir(_save_dir().path_join(sub))
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
	# Light in the cells (Docs/MineWorld.md 18): the bake spreads the sky's
	# light into caves and the ground's shader draws it per pixel.
	BrickTerrain.set_sky_light(_sky_light_on)

	_rig = LightRig.new()
	_rig.build_day(self, Vector3(-40, -30, 0), LightRig.SUN_ENERGY, DRY_AMBIENT)
	_rig.sun.directional_shadow_max_distance = 120.0
	# Two cascades, the first 12 m (a tenth): fine shadows round the player,
	# the rest soft. Four cost 1.1-1.4 ms more of GPU for cascades nobody
	# could tell apart (--gate=gpu, 2026-11-20, Docs/MineWorld.md 17).
	_rig.sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	_rig.sun.directional_shadow_split_1 = 0.1
	_mat = TerrainTile.ground_material(-_rig.sun.global_transform.basis.z, _sky_light_on)
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--sky-debug="):
			_mat.set_shader_parameter("sky_debug", int(a.get_slice("=", 1)))
	_brick_mat = ShaderMaterial.new()
	_brick_mat.shader = load("res://shaders/brick.gdshader")
	WeatherFx.register(_brick_mat)
	if _sky_light_on:
		sky_lit = MineSkyLit.new()
		sky_lit.name = "SkyLit"
		add_child(sky_lit)
		sky_lit.setup(self)
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
	drops.sky = sky_lit
	chests = MineChests.new()
	chests.name = "Chests"
	add_child(chests)
	chests.setup(self, builder.inv, drops)
	chests.sky = sky_lit
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
		elif "--gate=gpu" in OS.get_cmdline_user_args():
			_run_gpu_gate()
		elif "--gate=breaklag" in OS.get_cmdline_user_args():
			_run_breaklag_gate()
		elif "--gate=mega" in OS.get_cmdline_user_args():
			_run_mega_gate()
		elif "--gate=shift" in OS.get_cmdline_user_args():
			_run_shift_gate()
		elif "--gate=deep" in OS.get_cmdline_user_args():
			_run_deep_gate()
		elif "--gate=mouth" in OS.get_cmdline_user_args():
			_run_mouth_gate()
		elif "--gate=handover" in OS.get_cmdline_user_args():
			_run_handover_gate()
		elif "--gate=skylit" in OS.get_cmdline_user_args():
			_run_skylit_gate()
		elif "--gate=seams" in OS.get_cmdline_user_args():
			_run_seams_gate()
		elif "--gate=slits" in OS.get_cmdline_user_args():
			_run_slits_gate()
		elif "--gate=bricks" in OS.get_cmdline_user_args():
			_run_bricks_gate()
		elif "--gate=buildings" in OS.get_cmdline_user_args():
			_run_buildings_gate()
		elif "--gate=mem" in OS.get_cmdline_user_args():
			# Where the memory goes (Docs/TerrainRegions.md 2, A0).
			set_meta(&"mem_probe", load("res://tools/probes/terrain_mem_probe.gd").new())
			get_meta(&"mem_probe").run(self)
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
	BrickTerrain.set_sky_light(false)
	BrickTerrain.set_behind_faces(false)


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
	# A one-file save to move to regions: the first save writes them all.
	_edits_dirty = _migrate_old
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
	# The water's meshes carry each vertex's sky light (COLOR.b): a cave pool
	# as dark as its cave (MineWorld.md 19).
	water._water_mat.set_shader_parameter("sky_light", _sky_light_on)
	# The water's own changes, after the ground's (it reads its solids).
	var fluid_cells := _load_fluid()
	_fluid_saved_at = BrickFluid.change_count()
	if fluid_cells > 0:
		_save_status += ", %d water cells" % fluid_cells
	var stud := BrickWorld.get_stud_metres()
	spawn_xz = Vector2((cell.x + 0.5) * stud, (cell.y + 0.5) * stud)
	var feet := Vector3(spawn_xz.x, _ground_m(cell.x, cell.y) + 0.05, spawn_xz.y)

	var near := clampi(int(settings.get("detail_tiles", 4)), 2, 8)
	# Real bevels near the camera (Chamfered brick edges): the brick overlay.
	_overlay_on = bool(settings.get("chamfer", true))
	# The solid behind the overlay's bricks, baked inside the ground, so a
	# shot brick's hole shows real bricks the frame it is hit
	# (Docs/BrickOverlay.md 6b); `-- --no-behind` = the stand-in box instead.
	BrickTerrain.set_behind_faces(_overlay_on and not ("--no-behind" in OS.get_cmdline_user_args()))
	if bricks == null:
		bricks = TerrainBricks.new()
		bricks.name = "Bricks"
		add_child(bricks)
		bricks.setup(self, _mat, _sky_light_on)
	bricks.set_enabled(_overlay_on)
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
	# Its overlay is this world's own (`bricks`: deep sections too, shots).
	_streamer.auto_overlay = false
	add_child(_streamer)
	_streamer.setup(_mat)
	_streamer.settle(spawn_xz)

	_deep = TerrainDeep.new()
	_deep.name = "Deep"
	# How far caves are drawn (the settings' Cave view distance, default the
	# surface's detail; it was 2, ~25 m: a long cave ended in nothing while
	# its water, drawn further, hung in the air). Past it, a black fade
	# (_cave_fog).
	_deep.radius = clampi(int(settings.get("cave_tiles", near)), 2, 8)
	# Up and down too: one section each way (~11 m) left a deep hole empty
	# below while the fade only reached across. Half the radius in sections
	# (a section is ~11 m, a tile 11.2 m), so 4 tiles -> 2, 8 -> 4.
	_deep.up = clampi(ceili(_deep.radius / 2.0), 1, 4)
	_deep.down = _deep.up
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
	# Real brick trees to 25 m, cards past it: at 45 m the near trees were
	# half the GPU (Docs/MineWorld.md 17). -- --tree-near=N for a comparison.
	_trees.near_m = TREE_NEAR_M
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--tree-near="):
			_trees.near_m = float(arg.split("=")[1])
	_trees.stream(int(settings.seed), _tree_chance_at, _tree_variant_at, 420.0)
	_trees.solid_m = 64.0   # trunks the player and rounds meet
	# The instance pool, filled now rather than by the first new ground's
	# never-drawn nodes (the spawn spike, Docs/MineWorld.md 14).
	if _prewarm_on:
		var e := _eye_render()
		var tw := Time.get_ticks_usec()
		var kinds: Dictionary = PREWARM_PER_KIND.duplicate()
		if _sky_light_on:
			# The ground's studs carry their light (TerrainTile sky studs).
			kinds["StudsSky"] = kinds["Studs"]
			kinds["StudsSkyFar"] = kinds["StudsFar"]
			kinds.erase("Studs")
			kinds.erase("StudsFar")
		_warm = TerrainTile.prewarm_begin(_streamer, e - _eye_camera().global_transform.basis.z * 1.5,
				kinds)
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
		# No arsenal: the mine world's guns are hotbar items (MineHands,
		# Docs/Inventory.md 10); the city and planets keep theirs.
		kit = PlayerKit.attach(self, player, cam, gun, s, {"scripted": _gate, "arsenal": false})
		kit.enter(pawn, view)
		hands = MineHands.new()
		hands.name = "Hands"
		add_child(hands)
		hands.setup(self, gun, view, kit.library, builder)
		var loadout: Dictionary = {} if _gate else CharacterSave.load_from(character_path()).loadout
		if hands.ensure_guns(builder.inv, loadout):
			_inv_dirty = true
		hands.set_inventory(builder.inv)
		if kit.hud != null:
			kit.hud.hint_lines = PackedStringArray([
				"WASD move · SHIFT sprint · SPACE jump · F fly · LMB fire / break · RMB aim / place · R reload",
				"1-9 / wheel: the hand (a gun, a block, a tool) · X other hotbar · Z block size · E items · M world"])
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
	# A brick of the overlay goes NOW, before the worker finds it and the
	# tile is rebuilt (TerrainBricks.hide_at, Docs/BrickOverlay.md stage 6).
	var hole := -1
	if bricks != null and _overlay_on:
		hole = bricks.hide_at(at, global_transform.basis.inverse() * dir)
	if hole >= 0:
		# ...and the field is cleared now too, from the overlay's own box (a
		# brick and the plate on it, whole plates): no worker's find_brick
		# frame. clear_runs never takes bedrock (nothing removed: it comes
		# back, the same frame).
		_break_from_box(hole, bricks.hole_box(hole))
		return
	# High priority: at low, the shot waited behind every streaming bake
	# (all high) before it knew what it hit (Docs/MineWorld.md 21).
	var task := WorkerThreadPool.add_task(
		func() -> void:
			var s0 := Time.get_ticks_usec()
			holder[0] = BrickTerrain.find_brick(at, n)
			holder.append(s0)
			holder.append(Time.get_ticks_usec()), true, "break brick")
	_break_jobs.append([task, holder, at - dir * 0.6, Time.get_ticks_usec(), hole])


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
		var hole: int = job[4]
		var runs: PackedInt32Array = found.get("runs", PackedInt32Array())
		if runs.is_empty():
			if hole >= 0:
				bricks.drop_hole(hole)
			continue
		var res: Dictionary = BrickTerrain.clear_runs(runs)
		if int(res.get("removed", 0)) == 0:
			if hole >= 0:
				bricks.drop_hole(hole)
			continue
		var logged := {}
		if _streamer != null and _streamer.log_latency:
			logged = {"shot": job[3], "found": Time.get_ticks_usec()}
			var h: Array = job[1]
			if h.size() >= 3:
				logged["find_start"] = h[1]
				logged["find_end"] = h[2]
			break_log.append(logged)
		# What a shot destroys is gone (the user, 2026-11-20): no brick thrown.
		# What it leaves hanging falls -- the collapse, from terrain_edited.
		terrain_edited(res)
		if hole >= 0:
			_hole_wait(hole, res)
			if not logged.is_empty():
				logged["hidden"] = int(job[3])
		if not logged.is_empty():
			# The generation each tile must be drawn at for the hole to show.
			var want := {}
			var tl: PackedInt32Array = res["tiles"]
			for k in range(0, tl.size(), 2):
				var c := Vector2i(tl[k], tl[k + 1])
				if _streamer.has_tile(c):
					want[c] = int(_streamer._gen.get(c, 0))
			logged["want"] = want


## A shot brick of the overlay, cleared at once: its box as clear_runs' runs
## (x, z, first plate, last plate a column).
func _break_from_box(hole: int, box: AABB) -> void:
	var t0 := Time.get_ticks_usec()
	var stud := BrickWorld.get_stud_metres()
	var plate := BrickWorld.get_plate_metres()
	var x0 := roundi(box.position.x / stud)
	var x1 := roundi(box.end.x / stud)
	var z0 := roundi(box.position.z / stud)
	var z1 := roundi(box.end.z / stud)
	var p0 := roundi(box.position.y / plate)
	var p1 := roundi(box.end.y / plate) - 1
	var runs := PackedInt32Array()
	for z in range(z0, z1):
		for x in range(x0, x1):
			runs.append_array([x, z, p0, p1])
	var res: Dictionary = BrickTerrain.clear_runs(runs)
	if int(res.get("removed", 0)) == 0:
		bricks.drop_hole(hole)
		return
	terrain_edited(res)
	_hole_wait(hole, res)
	if _streamer != null and _streamer.log_latency:
		var want := {}
		var tl: PackedInt32Array = res["tiles"]
		for k in range(0, tl.size(), 2):
			var c := Vector2i(tl[k], tl[k + 1])
			if _streamer.has_tile(c):
				want[c] = int(_streamer._gen.get(c, 0))
		var now := Time.get_ticks_usec()
		break_log.append({"shot": t0, "find_start": t0, "find_end": t0, "found": now, "hidden": t0,
				"want": want})


## A hidden brick's hole stays till the tiles and sections the edit rebuilt
## are drawn at the generations it set (TerrainBricks.hole_wait).
func _hole_wait(hole: int, res: Dictionary) -> void:
	var want := {}
	var tl: PackedInt32Array = res["tiles"]
	var lo := Vector2i(1 << 30, 1 << 30)
	var hi := -lo
	for k in range(0, tl.size(), 2):
		var c := Vector2i(tl[k], tl[k + 1])
		lo = Vector2i(mini(lo.x, c.x), mini(lo.y, c.y))
		hi = Vector2i(maxi(hi.x, c.x), maxi(hi.y, c.y))
		if _streamer != null and _streamer.has_tile(c):
			want[c] = int(_streamer._gen.get(c, 0))
	var deep := {}
	if _deep != null and res.has("box_lo"):
		for k in _deep._box_keys(res.box_lo, res.box_hi):
			if _deep._secs.has(k) and _deep._secs[k] != null:
				deep[k] = int(_deep._gen.get(k, 0))
	bricks.hole_wait(hole, want, deep, Rect2i(lo, hi - lo + Vector2i.ONE) if not want.is_empty() else Rect2i())


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
	if sky_lit != null and res.has("box_lo"):
		sky_lit.dirty_box(res.box_lo, res.box_hi)
	if _deep != null and res.has("box_lo"):
		_deep.refresh_box(res.box_lo, res.box_hi)
	if collapse != null and not bool(res.get("anchored", false)):
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


## WHAT FALLS FROM THE GROUND, AND THE GROUND (Docs/MineWorld.md 20). A
## falling piece or sand column holds the near tiles over `rect` and the deep
## sections over its plate box (`lo`..`hi`, null for none) from the moment its
## cells are cleared: built and collided, they are not swapped in until it
## can be drawn too (ground_ready, then swap_ground and its release, in one
## call). Released the moment the tiles stopped drawing it, it showed a frame
## or more of nothing while its mesh was made, or drew twice.
func hold_ground(rect: Rect2i, lo, hi, who) -> void:
	if _streamer != null:
		_streamer.hold_tiles(rect, who)
	if _deep != null and lo != null:
		_deep.hold_box(lo, hi, who)


func unhold_ground(rect: Rect2i, who) -> void:
	if _streamer != null:
		_streamer.unhold(rect, who)
	if _deep != null:
		_deep.unhold(who)


## Could the ground over it swap now, holds by others aside: every tile and
## section rebuilt without it, the edits all flushed.
func ground_ready(rect: Rect2i, lo, hi, who) -> bool:
	if _streamer == null:
		return true
	if _pending_tiles.has_area() and rect.has_area() and _pending_tiles.intersects(rect):
		return false
	if not _streamer.tiles_ready(rect, who):
		return false
	return _deep == null or lo == null or _deep.ready_box(lo, hi, who)


## Swap the ground over it now (after ground_ready and unhold_ground).
func swap_ground(rect: Rect2i, lo, hi) -> void:
	if _streamer != null:
		_streamer.swap_ready(rect)
	if _deep != null and lo != null:
		_deep.swap_ready_box(lo, hi)


## Is tile `t` in the near-detail tier (LOD 0)? Settled pieces elsewhere are
## unloaded (Docs/TerrainCollapse.md 5).
func near_tile(t: Vector2i) -> bool:
	return _streamer != null and _streamer.has_tile(t)


## The water's "lava_light" (tx, tz, first plate, last plate ...): gathered,
## handed to the tiers by _flush_lava_light. Only the light changed: no
## collapse, no far tier (it has no light in its cells).
func lava_relit(flat: PackedInt32Array) -> void:
	if not _sky_light_on:
		return
	var tile := BrickTerrain.get_tile_studs()
	for i in range(0, flat.size(), 4):
		var t := Vector2i(flat[i], flat[i + 1])
		var r: Vector2i = _lava_relight.get(t, Vector2i(flat[i + 2], flat[i + 3]))
		_lava_relight[t] = Vector2i(mini(r.x, flat[i + 2]), maxi(r.y, flat[i + 3]))
		# Things near the lava take its block light again (MineSkyLit).
		if sky_lit != null:
			sky_lit.dirty_box(Vector3i(t.x * tile, flat[i + 2], t.y * tile),
					Vector3i(t.x * tile + tile - 1, flat[i + 3], t.y * tile + tile - 1))


func _flush_lava_light(delta: float) -> void:
	_lava_relight_in -= delta
	if _lava_relight.is_empty() or _lava_relight_in > 0.0:
		return
	_lava_relight_in = LAVA_RELIGHT_EVERY
	var tile := BrickTerrain.get_tile_studs()
	for t: Vector2i in _lava_relight:
		var r: Vector2i = _lava_relight[t]
		# A drawn tile only when the lava is within its light grid's plates:
		# priming a deep lava pool must not rebake the ground's top over it.
		var d := _streamer.tile_data(t)
		if d.is_empty() or (d.has("light_lo") and r.y >= int(d.light_lo) and r.x <= int(d.light_hi)):
			_streamer.refresh(Rect2i(t, Vector2i.ONE))
			lava_relit_tiles += 1
		if _deep != null:
			# Inset a stud: refresh_box reaches one cell out for faces.
			_deep.refresh_box(Vector3i(t.x * tile + 1, r.x, t.y * tile + 1),
					Vector3i(t.x * tile + tile - 2, r.y, t.y * tile + tile - 2))
	_lava_relight.clear()


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
## Light in the cells (Docs/MineWorld.md 18): the bake spreads the sky's
## light through the cells and the ground's shader draws it per pixel.
## `--no-sky-light` is the single factor from the eye's depth it replaced,
## for A/B.
var _sky_light_on := not ("--no-sky-light" in OS.get_cmdline_user_args())
## The light at the eye last frame (_day_night), 1 in the open: with sky light
## the brightness of the eye's own cell, eased (_eye_lights), which the
## exposure and the held gun follow; without it the depth factor that scaled
## the ambient, the sun and the sky.
var _cave_light := 1.0
## The light left deep underground (x the open-air light): the shader's
## `sky_light_floor` too.
const CAVE_DEEP_LIGHT := 0.015
## The shader's `sky_light_curve`: Minecraft's 0.8 a level.
const SKY_LIGHT_CURVE := 0.8
## The eye's sky light level (0..15, BrickTerrain.sky_light_at), asked again
## when the eye changes cell or every EYE_SKY_EVERY seconds.
var _eye_sky := 15.0
var _eye_sky_cell := Vector3i(1 << 30, 0, 0)
var _eye_sky_in := 0.0
const EYE_SKY_EVERY := 0.5
## Seconds the eye's light takes to follow a new level.
const EYE_LIGHT_EASE := 0.25
var _reflecting := true
## --gate=gpu: the day/night left as it is (nothing written to the sky, the
## sun or the ambient) to read what writing them every frame costs.
var sky_hold := false
## The ambient and the sky's energy as set_sky last wrote them (_day_night).
var _sky_writes_seen := -1
var _amb_base := 0.6
var _sky_energy_base := 1.0
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
	var q0 := Time.get_ticks_usec()
	_origin_step()
	var eye := _eye()
	_speed_step(eye, delta)
	_land_breaks()
	_refresh_in -= delta
	if _refresh_in <= 0.0:
		_flush_edits()
	_flush_lava_light(delta)
	var p0 := Time.get_ticks_usec()
	_behind_follow(eye)
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
			"reanchor": (p3 - p2) / 1000.0, "swapped": _reanchors != re0,
			# Before the tiers: origin shift, speed, landed breaks, edits.
			"pre": (p0 - q0) / 1000.0}
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
	# After the tiers (day and night, autosave, HUD), and this whole _process:
	# a slow frame's process time past it is other nodes' (--gate=stop).
	var q1 := Time.get_ticks_usec()
	_ptimes["post"] = (q1 - p3) / 1000.0
	_ptimes["all"] = (q1 - q0) / 1000.0


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
	var b0 := Time.get_ticks_usec()
	if not _far_next.build_poll(2.0):
		return
	# Its splits round the detail land while it is still hidden, one call a
	# frame that never waits. The swap's `cover(_streamer)` waited for them:
	# 29 ms on the main thread at every re-anchor, the walk's one slow frame
	# (CLAUDE.md: no waiting on a worker during play).
	var t0 := Time.get_ticks_usec()
	_far_next.cover(_streamer, false)
	if _far_next.refining():
		return
	var t1 := Time.get_ticks_usec()
	_far_next.visible = true
	var t2 := Time.get_ticks_usec()
	remove_child(_far)
	var t3 := Time.get_ticks_usec()
	_far.queue_free()
	_far = _far_next
	_far.hold = fast_hold
	_far_next = null
	_reanchors += 1
	_last_reanchor_ms = float(Time.get_ticks_usec() - t0) / 1000.0
	_reanchor_parts = "last poll %.1f, cover %.1f, show %.1f, remove %.1f ms" % [(t0 - b0) / 1000.0,
			(t1 - t0) / 1000.0, (t2 - t1) / 1000.0, (t3 - t2) / 1000.0]


## The sun goes round once a DAY_SECONDS; the sky, the ambient and the eye's
## exposure follow (LightRig, the planet's own calls). Caves are dark by the
## light in their cells (Docs/MineWorld.md 18), the rest by the eye's
## (_eye_lights); `--no-sky-light`: the old single factor from the eye's
## depth.
func _day_night(delta: float, eye: Vector3) -> void:
	if sky_hold:
		return
	if not _gate:
		_time = fposmod(_time + delta / DAY_SECONDS, 1.0)
	var a := (_time - 0.25) * TAU
	var to_sun := Vector3(cos(a), sin(a), 0.35).normalized()
	var height := sin(a)
	var seen := clampf(height * 6.0 + 0.4, 0.0, 1.0)
	var day := clampf(height * 2.5 + 0.4, 0.0, 1.0)
	_rig.set_sun(to_sun, seen, deg_to_rad(LightRig.DAY_SUN_ANGLE * 0.5), 1.0, 0.002)
	_rig.set_sky(day, 1.0, LightRig.HOME_ATMO, maxf(height, 0.0), Vector3.UP)
	# What set_sky wrote, kept: it writes only when the sky changes (every
	# few seconds, or never at a fixed hour), so the cave factor below is
	# applied to these, not to last frame's already-faded values. It was
	# `*= cave` every frame: underground the ambient and the sky's energy
	# shrank frame by frame towards nothing, and stayed wrong after the cave
	# until the sky next changed.
	if _rig.sky_writes != _sky_writes_seen:
		_sky_writes_seen = _rig.sky_writes
		_amb_base = _rig.env.ambient_light_energy
		_sky_energy_base = _rig.sky_mat.sky_energy_multiplier
	if _sky_light_on:
		_eye_lights(eye, delta)
		return
	var c := Vector2i(floori(eye.x / BrickWorld.get_stud_metres()), floori(eye.z / BrickWorld.get_stud_metres()))
	var under := _ground_m(c.x, c.y) - eye.y
	var cave := clampf(1.0 - (under - 1.5) / 6.0, 0.12, 1.0)
	# On down past 7.5 m to CAVE_DEEP_LIGHT at 30 m. Only DOWN there: above
	# ground `under` is negative.
	if under > 7.5:
		cave = minf(cave, lerpf(0.12, CAVE_DEEP_LIGHT, clampf((under - 7.5) / 22.5, 0.0, 1.0)))
		cave = maxf(cave, CAVE_DEEP_LIGHT)
	_cave_light = cave
	_rig.env.ambient_light_energy = _amb_base * cave
	# The ground casts no sun shadow, so the sun would reach into caves.
	_rig.sun.light_energy *= cave
	# And the sky the bricks reflect. Written only when it changes: a write to
	# the sky's material redraws its radiance map (Docs/PlanetCost.md 5.1).
	var sky_e := _sky_energy_base * cave
	if absf(_rig.sky_mat.sky_energy_multiplier - sky_e) > 0.0005:
		_rig.sky_mat.sky_energy_multiplier = sky_e
	# The reflection map does not follow the sky's energy (--gate=deep
	# --light-sweep, 2026-11-19): underground, no reflections.
	var reflect := cave >= 0.3
	if reflect != _reflecting:
		_reflecting = reflect
		_rig.env.reflected_light_source = Environment.REFLECTION_SOURCE_BG if reflect \
				else Environment.REFLECTION_SOURCE_DISABLED
	# A third of the ambient came from the sky's own light map.
	_rig.env.ambient_light_sky_contribution = LightRig.AMBIENT_SKY \
			* clampf((cave - 0.12) / 0.88, 0.0, 1.0)
	_mat.set_shader_parameter("sun_dir", -_rig.sun.global_transform.basis.z)
	_rig.expose(eye, delta)


## The light at the eye (Docs/MineWorld.md 18). The environment stays the open
## air's, so the sky, the trees, the water and everything else outdoors look
## the same from a cave mouth as from outside; the ground draws its own cells'
## light. What follows the eye's cell (BrickTerrain.sky_light_at): the
## exposure, so the eye opens up in a dark cave, and the first-person gun and
## arms (_held_light: they are always where the eye is).
func _eye_lights(eye: Vector3, delta: float) -> void:
	var stud := BrickWorld.get_stud_metres()
	var cell := Vector3i(floori(eye.x / stud), floori(eye.y / BrickTerrain.get_brick_metres()),
			floori(eye.z / stud))
	_eye_sky_in -= delta
	if cell != _eye_sky_cell or _eye_sky_in <= 0.0:
		_eye_sky_cell = cell
		_eye_sky_in = EYE_SKY_EVERY
		_eye_sky = BrickTerrain.sky_light_at(eye)
	# Eased: a level is a 20 % step, and the gun would flick at every cell.
	_cave_light = lerpf(_cave_light, sky_brightness(_eye_sky), 1.0 - exp(-delta / EYE_LIGHT_EASE))
	_cave_fog()
	# The sky's reflections stay on: the ground takes them down per pixel
	# (terrain.gdshader, SPECULAR); the held gun has its own dark box.
	_held_light(_cave_light, delta)
	_mat.set_shader_parameter("sun_dir", -_rig.sun.global_transform.basis.z)
	_rig.expose(eye, delta, false, _cave_light)


## The first-person gun and arms take the eye's light (Docs/MineWorld.md 18):
## everything else is lit by the open-air environment, and they are always
## where the eye is. Under the open sky nothing changes. Past that they move to
## their own render layer (HELD_LAYER), where an interior ReflectionProbe riding
## the camera gives them the eye's share of the ambient and no sky reflections
## (LightRig's ambient boxes do the same in rooms), and the sun skips them for
## a shadowless twin at the eye's share of the sun.
const HELD_LAYER := 1 << 11
var _held_box: ReflectionProbe = null
var _held_sun: DirectionalLight3D = null
var _held_on := false
var _held_scan := 0.0
const HELD_SCAN := 0.25


func _held_light(k: float, delta: float) -> void:
	if view == null or view.rig == null or view.camera == null:
		return
	if _held_box == null:
		_held_box = ReflectionProbe.new()
		_held_box.name = "HeldLight"
		_held_box.interior = true
		# Nothing drawn into it: no sky in the gun's reflections, no capture.
		_held_box.cull_mask = 0
		_held_box.update_mode = ReflectionProbe.UPDATE_ONCE
		_held_box.ambient_mode = ReflectionProbe.AMBIENT_COLOR
		_held_box.reflection_mask = HELD_LAYER
		_held_box.size = Vector3(4, 4, 4)
		_held_box.visible = false
		view.camera.add_child(_held_box)
		_held_sun = DirectionalLight3D.new()
		_held_sun.name = "HeldSun"
		_held_sun.shadow_enabled = false
		_held_sun.light_cull_mask = HELD_LAYER
		_held_sun.visible = false
		# A child with no transform of its own: the sun's direction.
		_rig.sun.add_child(_held_sun)
		_rig.sun.light_cull_mask &= ~HELD_LAYER
	var on := k < (0.97 if not _held_on else 0.985)
	if on:
		_held_box.ambient_color = _rig.env.ambient_light_color
		_held_box.ambient_color_energy = _rig.env.ambient_light_energy * k
		var raw := clampf((k - CAVE_DEEP_LIGHT) / (1.0 - CAVE_DEEP_LIGHT), 0.0, 1.0)
		_held_sun.light_color = _rig.sun.light_color
		_held_sun.light_energy = _rig.sun.light_energy * raw * raw
		_held_sun.visible = _rig.sun.visible
	_held_scan -= delta
	if on == _held_on and _held_scan > 0.0:
		return
	_held_scan = HELD_SCAN
	if on != _held_on:
		_held_on = on
		_held_box.visible = on
		if not on:
			_held_sun.visible = false
	# The gun's meshes change with the gun: looked for again each time.
	var mask := HELD_LAYER if on else 1
	for root: Node in [view.rig, view.arms]:
		if root == null:
			continue
		for n in root.find_children("*", "VisualInstance3D", true, false):
			if n is GeometryInstance3D:
				RenderLayers.set_layers(n as VisualInstance3D, mask)


## THE CAVE FADE (MineWorld.md 19): underground the caves are drawn only
## `_deep.radius` tiles round the eye, and past that a cave ends in nothing
## (the far tier has no caves). So in the dark the distance fades to black,
## ending where the drawn caves may end, by how dark the eye's cell is: none
## in the open, full in a closed cave. Under water or lava their own fog.
var _cave_fog_on := false


func _cave_fog() -> void:
	if _rig == null or _rig.env == null or _deep == null:
		return
	var env: Environment = _rig.env
	if water != null and int(water.get("_under_mode")) != 0:
		_cave_fog_on = false
		return
	var k := clampf((1.0 - _cave_light) * 1.25 - 0.1, 0.0, 1.0) if _deep.active else 0.0
	if k <= 0.01:
		if _cave_fog_on:
			env.fog_enabled = false
			_cave_fog_on = false
		return
	# The nearest place the drawn caves may end: across (tiles) or up/down
	# (sections, on their own grid: at least `down` whole sections below).
	var across := float(_deep.radius) * float(BrickTerrain.get_tile_studs()) * BrickWorld.get_stud_metres()
	var updown := float(mini(_deep.up, _deep.down)) * float(BrickTerrain.get_deep_section_plates()) 			* BrickWorld.get_plate_metres()
	var reach := minf(across, updown)
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_DEPTH
	env.fog_light_color = Color.BLACK
	env.fog_light_energy = 0.0
	env.fog_density = k
	env.fog_depth_begin = reach * 0.55
	env.fog_depth_end = reach
	env.fog_depth_curve = 1.0
	env.fog_sky_affect = 0.0
	env.fog_sun_scatter = 0.0
	env.fog_aerial_perspective = 0.0
	_cave_fog_on = true


## A level's brightness before the floor (0 at level 0, 1 at 15).
static func _sky_raw(level: float) -> float:
	var k0 := pow(SKY_LIGHT_CURVE, 15.0)
	return (pow(SKY_LIGHT_CURVE, 15.0 - level) - k0) / (1.0 - k0)


## A sky light level's brightness, as terrain.gdshader draws it.
static func sky_brightness(level: float) -> float:
	return lerpf(CAVE_DEEP_LIGHT, 1.0, _sky_raw(level))


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
	if not MineChests.is_container(chests.item_of(key)):
		# A station: the screen opens on what can be made (Docs/Inventory.md 12).
		toggle_inventory()
		if _inv_screen != null:
			_inv_screen.show_page("craft")
		return
	builder.inv.open_chest(key, chests.slots_of(key))
	toggle_inventory()


## The stations in reach of the player (the crafting list's).
func stations_near() -> Array:
	var feet := player_feet_local()
	if chests == null or feet == Vector3.INF:
		return []
	return chests.stations_near(feet + Vector3(0, 0.8, 0))


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
	var n := 0
	_migrate_old = false
	# The one-file save worlds were made with: loaded, and every region left
	# changed, so the next save writes them all and drops this file.
	if FileAccess.file_exists(path):
		var f := FileAccess.open_compressed(path, FileAccess.READ, FileAccess.COMPRESSION_ZSTD)
		if f != null and f.get_buffer(4).get_string_from_ascii() == SAVE_MAGIC:
			var fmt := f.get_32()
			var field := f.get_32()
			if fmt != SAVE_FORMAT or field != BrickTerrain.get_field_version():
				push_warning("[mine] %s is from another format or field; not loaded" % path)
			else:
				n += BrickTerrain.set_edits(f.get_buffer(f.get_32() * 13))
				_migrate_old = true
	# Region files (Docs/MineWorld.md 9), newer than the one file if both.
	var rdir := _regions_dir(path)
	var d := DirAccess.open(rdir)
	if d != null:
		for file in d.get_files():
			if not file.ends_with(".edits"):
				continue
			var rf := FileAccess.open_compressed(rdir.path_join(file), FileAccess.READ, FileAccess.COMPRESSION_ZSTD)
			if rf == null or rf.get_buffer(4).get_string_from_ascii() != REGION_MAGIC:
				continue
			if rf.get_32() != REGION_FORMAT or rf.get_32() != BrickTerrain.get_field_version():
				push_warning("[mine] %s is from another format or field; not loaded" % file)
				continue
			rf.get_32()   # rx
			rf.get_32()   # rz
			n += BrickTerrain.set_edits(rf.get_buffer(rf.get_32() * 13))
	if not _migrate_old:
		BrickTerrain.take_dirty_regions()   # what was loaded is what is saved
	return n


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
		if hands != null:
			hands.set_inventory(inv)
		_inv_loaded = true
	# The world's game mode (stage 7). A file from before kept the inventory's
	# own "creative" flag.
	survival = bool(world.get("survival", not bool(world.get("creative", true))))
	inv.creative = not survival
	if first and how_kit_added(inv):
		_inv_dirty = true
	# A world file from before stage 11 (format < 3) counted blocks in bricks.
	Inventory.units_in_bricks = int(world.get("format", 3)) < 3 and not world.is_empty()
	if chests != null:
		chests.inv = inv
		chests.restore(world.get("chests", {}))
	if drops != null:
		drops.inv = inv
		drops.restore(world.get("drops", []))
	Inventory.units_in_bricks = false
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
	for st in [&"workbench", &"furnace"]:
		if inv.ensure_item(st):
			print("[mine] %s added to the inventory" % st)
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
	if hands != null:
		hands.sync_ammo()
	if _inv_dirty:
		_inv_dirty = false
		save_character()
	# The world file: only what is the world's (stage 6).
	var inv_save := {"format": 3, "survival": survival}
	if chests != null:
		inv_save["chests"] = chests.to_save()
	if drops != null:
		inv_save["drops"] = drops.to_save()
	var inv_text := JSON.stringify(inv_save, "\t")
	_fluid_saved_at = fluid_at
	# Only the regions edited since the last save (Docs/MineWorld.md 9): it
	# packed every edit of the world here, on the main thread, each autosave.
	var t_save := Time.get_ticks_usec()
	var regions: Array = []
	var dirty := BrickTerrain.take_dirty_regions()
	for i in range(0, dirty.size(), 2):
		regions.append([dirty[i], dirty[i + 1], BrickTerrain.get_region_edits(dirty[i], dirty[i + 1])])
	var migrate := _migrate_old
	var rdir := _regions_dir(path_for_regions())
	var fluid_bytes: PackedByteArray = BrickFluid.get_save()
	var piece_bytes := var_to_bytes(collapse.to_save())
	var placed_bytes := BrickTerrain.get_placed().to_byte_array()
	var path := save_path()
	var dir := _save_dir()
	var field := BrickTerrain.get_field_version()
	var write := func() -> void:
		DirAccess.make_dir_recursive_absolute(dir)
		# The regions first: a world moving off the one-file save drops that
		# file only once every region is written.
		if not regions.is_empty():
			DirAccess.make_dir_recursive_absolute(rdir)
		var all_written := true
		for r in regions:
			var rp := rdir.path_join("r_%d_%d.edits" % [r[0], r[1]])
			var rf := FileAccess.open_compressed(rp + ".tmp", FileAccess.WRITE, FileAccess.COMPRESSION_ZSTD)
			if rf == null:
				all_written = false
				continue
			var rb: PackedByteArray = r[2]
			rf.store_buffer(REGION_MAGIC.to_ascii_buffer())
			rf.store_32(REGION_FORMAT)
			rf.store_32(field)
			rf.store_32(r[0])
			rf.store_32(r[1])
			@warning_ignore("integer_division")
			rf.store_32(rb.size() / 13)
			rf.store_buffer(rb)
			rf.close()
			DirAccess.rename_absolute(rp + ".tmp", rp)
		if migrate and all_written and FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
		var ip := _inventory_path(path)
		var iv := FileAccess.open(ip + ".tmp", FileAccess.WRITE)
		if iv != null:
			iv.store_string(inv_text)
			iv.close()
			DirAccess.rename_absolute(ip + ".tmp", ip)
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
	_migrate_old = false
	last_save_ms = float(Time.get_ticks_usec() - t_save) / 1000.0
	_save_status = "%d changes saved (%d regions written)" % [BrickTerrain.get_edit_count(), regions.size()]
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
	_remove_dir(_regions_dir(path))
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
		"%s   F fly/walk  1-9 hand  E items  M world generation  F3 readout  T +1 hour" % ("ON FOOT" if on_foot
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
			_menu.get("_map_step"), str(hovered.get_path()) if hovered != null else "nothing"])
	var look := cam.global_transform.basis
	var empty := (_menu as Control).get_global_rect().position + Vector2(20, 300)
	await _click(empty)
	hovered = get_viewport().gui_get_hovered_control()
	print("[mine-menu] click on the panel's empty part at %s: camera turned %s, hovered %s, menu open %s"
			% [empty, not look.is_equal_approx(cam.global_transform.basis),
			str(hovered.get_path()) if hovered != null else "nothing", _menu != null])
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
	check.call("item icons rendered at load (stage 4)", ItemIcons.ready and ItemIcons.has_icon(&"coal_ore")
			and ItemIcons.has_icon(&"bucket"))
	# Stage 10: the kit's guns (MineHands.ensure_guns) -- moved to the end of
	# the storage here so the checks below find the hotbars as they were.
	var kit_guns: Array = []
	for a in inv.all_addrs():
		if MineHands.is_gun(inv.get_slot(a)):
			kit_guns.append(inv.get_slot(a))
			inv.set_slot(a, null)
	check.call("the kit has guns as items (%d)" % kit_guns.size(), kit_guns.size() >= 2)
	for i in kit_guns.size():
		inv.main[26 - i] = kit_guns[i]
	inv.changed.emit()
	await _frames(2)
	# The sheet, for a look (a read-back: a gate's).
	if ItemIcons.ready and ItemIcons.texture != null:
		DirAccess.make_dir_recursive_absolute(UserPaths.DEV)
		ItemIcons.texture.get_image().save_png(UserPaths.DEV + "mine_item_icons.png")
	await _key(KEY_B)
	check.call("B: the items hands", builder.active)
	await _key(KEY_E)
	check.call("E: the inventory screen opens", inventory_open())
	await _frames(5)
	var scr := _inv_screen
	var tab: Button = scr.get("_tab_creative")
	await _click(tab.get_global_rect().get_center())
	check.call("the Creative tab shows the catalog", scr.page == "creative")
	await _click(_inv_slot(scr, {}, &"coal_ore").get_global_rect().get_center())
	check.call("a catalog item comes onto the cursor, a full stack",
			inv.cursor != null and inv.cursor.id == &"coal_ore" and inv.cursor.count == 999)
	await _click(_inv_slot(scr, Inventory.addr(&"hotbar_1", 2)).get_global_rect().get_center())
	check.call("... and swaps with what hotbar 2 slot 3 held (water source now held)",
			inv.hotbars[1][2] != null and inv.hotbars[1][2].id == &"coal_ore"
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
	await _click(_inv_slot(scr, {}, &"gravel").get_global_rect().get_center())
	check.call("a held stack clicked on the catalog is thrown away", inv.cursor == null)
	# A left drag spreads a stack: chests (64 to a stack) over the first three storage slots
	# (storage starts empty; the hotbars are the kit's).
	await _click(_inv_slot(scr, {}, &"chest").get_global_rect().get_center())
	await _shot(UserPaths.DEV + "inv_held.png")
	var tab_s: Button = scr.get("_tab_storage")
	await _click(tab_s.get_global_rect().get_center())
	check.call("the Storage tab, the stack still held", scr.page == "storage" and inv.cursor != null)
	var pts: Array[Vector2] = []
	for i in [0, 1, 2]:
		pts.append(_inv_slot(scr, Inventory.addr(&"main", i)).get_global_rect().get_center())
	await _gate_drag(pts)
	var spread := [inv.main[0], inv.main[1], inv.main[2]]
	check.call("a left drag spreads 64 chests over 3 slots (21 each, 1 held)",
			spread.all(func(s): return s != null and s.id == &"chest" and s.count == 21)
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
	var moved: bool = inv.main[2] == null and inv.main[5] != null and inv.main[5].id == &"chest" and inv.cursor == null
	check.call("a stack picked up and put down in another slot", moved)
	if moved:
		var over := _inv_slot(scr, Inventory.addr(&"main", 5)).get_global_rect().get_center()
		var m := InputEventMouseMotion.new()
		m.position = over
		m.global_position = over
		Input.parse_input_event(m)
		await _frames(2)
		await _key(KEY_9)
		check.call("9 over a storage slot sends it to hotbar 1 slot 9 (its obsidian to storage)",
				inv.hotbars[0][8] != null and inv.hotbars[0][8].id == &"chest"
				and inv.main[5] != null and inv.main[5].id == &"obsidian")
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
	check.call("the Large one swapped back on: 27 slots, its obsidian still in slot 6, the Small one in the hotbar",
			inv.backpack != null and inv.backpack.id == &"large_backpack" and int(scr.get("_storage_n")) == 27
			and inv.main[5] != null and inv.main[5].id == &"obsidian"
			and inv.hotbars[1][8] != null and inv.hotbars[1][8].id == &"small_backpack" and inv.cursor == null)
	# Stage 12: crafting, Terraria's. The Craft tab; gravel made by hand with
	# a real click on Make; sandstone greyed out until a workbench is near.
	var tab_c: Button = scr.get("_tab_craft")
	await _click(tab_c.get_global_rect().get_center())
	await _frames(3)
	check.call("the Craft tab", scr.page == "craft")
	var gravel0 := _carried_count(inv, &"gravel")
	var stone0 := _carried_count(inv, &"stone")
	var mk := _craft_button(scr, "Gravel", false)
	check.call("Gravel can be made by hand: its Make is live", mk != null and not mk.disabled)
	if mk != null:
		scr.body.ensure_control_visible(mk)
		await _frames(3)
		await _click(mk.get_global_rect().get_center())
		await _frames(3)
	check.call("Make: 12 stone -> 12 gravel (gravel %d -> %d, stone %d -> %d)" % [gravel0,
			_carried_count(inv, &"gravel"), stone0, _carried_count(inv, &"stone")],
			_carried_count(inv, &"gravel") == gravel0 + 12 and _carried_count(inv, &"stone") == stone0 - 12)
	var sb := _craft_button(scr, "Sandstone", false)
	check.call("Sandstone needs a workbench: greyed out", sb != null and sb.disabled)
	await _shot(UserPaths.DEV + "inv_craft.png")
	var winr := get_window()
	var sizer := winr.size
	winr.size = Vector2i(640, 400)
	await _frames(10)
	var cutr: Array = MenuFit.audit(scr, get_viewport().get_visible_rect())
	check.call("the Craft tab at 640x400: nothing cut off (%d)%s" % [cutr.size(),
			"" if cutr.is_empty() else "\n" + MenuFit.describe(cutr)], cutr.is_empty())
	winr.size = sizer
	await _frames(10)
	await _click(tab_s.get_global_rect().get_center())
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
	# Stage 10: a gun in a hotbar slot is in the hands; LMB fires it; another
	# slot puts it away (on foot, as a player shoots).
	var gun_stack: ItemStack = inv.main[26]
	inv.swap_with_hotbar(Inventory.addr(&"main", 26), 6)
	set_on_foot(true)
	# Away from the tree beside the spawn: a gun against a wall is held back.
	FpsRig.face(cam, pawn, Vector3.RIGHT)
	await _frames(30)
	await _key(KEY_7)
	await _frames(20)
	check.call("7: the gun in that slot is in the hands (%s), the builder rests" % [gun.gun.gun_name if gun.gun != null else "none"],
			gun.gun != null and not builder.active and hands.held == gun_stack)
	var rounds0 := gun.ammo
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.button_mask = MOUSE_BUTTON_MASK_LEFT
	Input.parse_input_event(press)
	await _frames(25)
	var up := press.duplicate()
	up.pressed = false
	up.button_mask = 0
	Input.parse_input_event(up)
	await _frames(5)
	var rounds1 := gun.ammo
	check.call("LMB fires it: %d -> %d rounds" % [rounds0, rounds1], rounds1 < rounds0)
	await _shot(UserPaths.DEV + "inv_gun.png")
	await _key(KEY_1)
	await _frames(20)
	check.call("1: a block in the hand -- the gun put away, the builder acts", gun.gun == null and builder.active
			and hands.held == null)
	check.call("... its rounds went back into its stack (%s)" % str(gun_stack.data.get("ammo", "?")),
			int(gun_stack.data.get("ammo", -1)) == rounds1)
	inv.swap_with_hotbar(Inventory.addr(&"main", 26), 6)
	set_on_foot(false)
	_fly_to(_eye() + Vector3(0, 0.8, 0), Vector3(0, 0, -1))
	walker.pitch = -0.75
	await _frames(20)
	# Hotbar 2 into the hand, its third slot, and place it.
	var bar0 := inv.active_hotbar
	await _key(KEY_X)
	await _frames(3)
	check.call("X (tap): the other hotbar", inv.active_hotbar == 1 - bar0)
	if inv.active_hotbar != 1:
		inv.toggle_hotbar()
	await _key(KEY_3)
	check.call("3: coal ore in the hand", inv.hand() != null and inv.hand().id == &"coal_ore")
	builder.update_target()
	var placed: bool = builder.place_target()
	await _frames(10)
	builder.update_target()
	var names := BrickTerrain.material_names()
	var m_id := int(builder.target.get("material", -1))
	check.call("RMB placed it: the block looked at is %s" % (names[m_id] if m_id >= 0 else "nothing"),
			placed and m_id >= 0 and names[m_id] == "coal ore")
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
		check.call("soil clicked from hotbar 1 into the chest", cs.size() > 0 and cs[0] != null
				and (cs[0] as ItemStack).id == &"soil")
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
	# Stage 12: a workbench from storage put down beside the chest; RMB on it
	# opens the Craft tab, where sandstone can now be made.
	var wb_at := -1
	for i in inv.main.size():
		if inv.main[i] != null and inv.main[i].id == &"workbench":
			wb_at = i
	check.call("the kit has a workbench in storage", wb_at >= 0)
	if wb_at >= 0:
		var held0 := inv.hand()
		inv.hotbars[inv.active_hotbar][inv.active_slot] = inv.main[wb_at]
		inv.main[wb_at] = held0
		inv.changed.emit()
		_fly_to(_eye() - Vector3(0, 1.6, 0) + Vector3(1.6, 0, 0), Vector3(0, 0, -1))
		walker.pitch = -1.45
		await _frames(10)
		var n0 := chests.count()
		builder.update_target()
		builder.place_target()
		await _frames(5)
		check.call("RMB with a workbench puts one down (%s near)" % str(stations_near()),
				chests.count() == n0 + 1 and stations_near().has(&"workbench"))
		builder.update_target()
		builder.place_target()
		await _frames(5)
		check.call("RMB on the workbench opens the Craft tab", inventory_open() and _inv_screen.page == "craft")
		if inventory_open():
			var sand0 := _carried_count(inv, &"sandstone")
			var sb2 := _craft_button(_inv_screen, "Sandstone", false)
			check.call("at the workbench Sandstone can be made", sb2 != null and not sb2.disabled)
			if sb2 != null:
				_inv_screen.body.ensure_control_visible(sb2)
				await _frames(3)
				await _click(sb2.get_global_rect().get_center())
				await _frames(3)
			check.call("Make: 12 sand -> 12 sandstone (%d -> %d)" % [sand0, _carried_count(inv, &"sandstone")],
					_carried_count(inv, &"sandstone") == sand0 + 12)
			await _shot(UserPaths.DEV + "inv_workbench.png")
			await _key(KEY_E)
		# The workbench back into storage (the checks after count the chests).
		for key in chests.chests.keys():
			if chests.item_of(key) == &"workbench":
				chests.break_chest(key, false)
		inv.main[wb_at] = ItemStack.make(&"workbench", 1)
		inv.hotbars[inv.active_hotbar][inv.active_slot] = held0
		inv.changed.emit()
	await _shot(UserPaths.DEV + "inv_chest_world.png")
	# Saved with the world, back after generating it again.
	_edits_dirty = true
	save_edits(true)
	var again := settings.duplicate(true)
	settings = {}
	generate(again)
	await _frames(20)
	inv = builder.inv
	check.call("after generating again: coal ore in hotbar 2 slot 3, chests in hotbar 1 slot 9, obsidian in storage",
			inv.hotbars[1][2] != null and inv.hotbars[1][2].id == &"coal_ore"
			and inv.hotbars[0][8] != null and inv.hotbars[0][8].id == &"chest"
			and inv.main[5] != null and inv.main[5].id == &"obsidian")
	var back: Array = chests.slots_of(ckey)
	var gun_back: ItemStack = inv.main[26]
	check.call("after generating again: the rifle in storage, its rounds kept",
			MineHands.is_gun(gun_back) and int(gun_back.data.get("ammo", -1)) == rounds1)
	check.call("after generating again: the chest is there, the soil in it", chests.count() == 1
			and back.size() > 0 and back[0] != null and (back[0] as ItemStack).id == &"soil")
	if chests.count() == 1:
		# A shot breaks it; the soil falls out; flying over it picks it up.
		# Generating again put the player on foot at the spawn, maybe beside
		# the chest: fly 2.4 m over it, out of a drop's reach.
		var box: AABB = chests.box_of(chests.chests[ckey].block)
		set_on_foot(false)
		_fly_to(box.get_center() + Vector3(0, 2.4, 0), Vector3(0, 0, -1))
		walker.pitch = -1.45
		await _frames(10)
		_mine(to_global(box.get_center()), Vector3.DOWN, null)
		await _frames(5)
		check.call("a shot breaks the chest, its soil drops (creative: not the chest)",
				chests.count() == 0 and drops.count() == 1
				and (drops.drops[0].stack as ItemStack).id == &"soil")
		await _frames(60)
		var drop_at: Vector3 = drops.drops[0].pos if drops.count() > 0 else box.get_center()
		check.call("the drop came to rest on the ground (%.2f m over the chest's floor)"
				% (drop_at.y - box.position.y), drops.count() > 0 and bool(drops.drops[0].rest)
				and absf(drop_at.y - box.position.y) < 0.5)
		await _shot(UserPaths.DEV + "inv_drop.png")
		var had := 0
		for a in inv.all_addrs():
			var s := inv.get_slot(a)
			if s != null and s.id == &"soil":
				had += s.count
		_fly_to(drop_at + Vector3(0, 0.1, 0), Vector3(0, 0, -1))
		await _frames(30)
		var now_has := 0
		for a in inv.all_addrs():
			var s := inv.get_slot(a)
			if s != null and s.id == &"soil":
				now_has += s.count
		check.call("walking over it picks it up (soil %d -> %d)" % [had, now_has],
				drops.count() == 0 and now_has > had)
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
	check.call("the inventory is in the character file (coal ore in hotbar 2 slot 3)",
			cinv.from_dict(ch.items) and cinv.hotbars[1][2] != null and cinv.hotbars[1][2].id == &"coal_ore")
	check.call("the world file holds only the world's (no hotbars; chests, drops, mode)",
			wsave is Dictionary and not wsave.has("hotbar_0") and wsave.has("chests") and wsave.has("survival"))
	# Stage 7: the world menu's Survival box, clicked.
	toggle_menu()
	await _frames(10)
	var survival_box: CheckBox = _menu.find_child("Survival", true, false) if _menu != null else null
	if survival_box != null:
		await _click(survival_box.get_global_rect().get_center())
	check.call("the world menu's Survival box: survival on", survival_box != null and survival and not inv.creative)
	if _menu != null:
		toggle_menu()
		await _frames(5)
	_fly_to(_eye() - Vector3(0, 1.6, 0), Vector3(0, 0, -1))
	inv.select_item(&"coal_ore")
	var before := inv.hand().count if inv.hand() != null else -1
	builder.size_i = 0
	walker.pitch = -1.0
	await _frames(10)
	builder.update_target()
	var put: bool = builder.place_target()
	var after := inv.hand().count if inv.hand() != null else -1
	# One brick a stud column it fills: 4 for a 2x2 block on flat ground, fewer
	# where the ground already stood in a column (placing only fills air).
	check.call("survival: a 2x2 block uses coal ore up (%d -> %d)" % [before, after],
			put and after < before and after >= before - 12)
	await _frames(5)
	builder.update_target()
	var took: bool = builder.break_target()
	await _frames(5)
	var after2 := inv.hand().count if inv.hand() != null else -1
	check.call("survival: breaking it gives coal ore back (%d -> %d)" % [after, after2], took and after2 > after)
	# Stage 11: the material's colour (V), the shape (Z), turned (R); the cost
	# is the plate cells laid.
	inv.select_item(&"stone")
	await _frames(3)
	await _key(KEY_V)
	var lay: int = builder.lay_material(ItemCatalog.get_def(&"stone"))
	check.call("V: stone lays its next colour (%s)" % names[lay], names[lay] == "dark stone")
	for i in 4:
		await _key(KEY_Z)
	await _key(KEY_R)
	check.call("Z x4: a 2x4 brick; R: turned (%s)" % builder.dims(), builder.dims() == Vector3i(4, 3, 2))
	var s0: int = inv.hand().count
	builder.update_target()
	var laid: bool = builder.place_target()
	await _frames(10)
	var used: int = s0 - inv.hand().count
	builder.update_target()
	var looked := int(builder.target.get("material", 0))
	check.call("a turned 2x4 dark stone brick laid: %d plate cells used (24 at most), the brick looked at is %s"
			% [used, names[looked]], laid and used > 0 and used <= 24 and names[looked] == "dark stone")
	await _shot(UserPaths.DEV + "inv_shapes.png")
	builder.size_i = 0
	builder.turned = false
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
		if slot.show_count > 0:
			continue        # the Recipes list's pictures, not the catalog's slots
		if a.is_empty() and slot.addr.is_empty() and slot.item_id == item:
			return slot
		if not a.is_empty() and not slot.addr.is_empty() and slot.addr.area == a.area \
				and slot.addr.index == a.index:
			return slot
	return null


## How many of item `id` the inventory carries (the gate's crafting checks).
func _carried_count(inv: Inventory, id: StringName) -> int:
	return inv.count_of({"id": id, "tag": "", "count": 1})


## The Craft page's Make (or All) button of recipe `name`, or null.
func _craft_button(scr: InventoryScreen, name: String, all: bool) -> Button:
	for b in scr.find_children("*", "Button", true, false):
		var btn := b as Button
		if btn.has_meta("recipe") and str(btn.get_meta("recipe")) == name and bool(btn.get_meta("all")) == all \
				and not btn.is_queued_for_deletion():
			return btn
	return null


## A click with `button`, real events (the gates' `_click` is the left one).
func _click_button(at: Vector2, button: MouseButton) -> void:
	var m := InputEventMouseMotion.new()
	m.position = at
	m.global_position = at
	Input.parse_input_event(m)
	await _frames(2)
	for down in [true, false]:
		var b := InputEventMouseButton.new()
		b.button_index = button
		b.position = at
		b.global_position = at
		b.pressed = down
		b.button_mask = (1 << (button - 1)) if down else 0
		Input.parse_input_event(b)
		await _frames(2)


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


## -- --gate=breaklag: HOW LONG A BROKEN BRICK TAKES TO GO from the ground
## (the user: "a hesitation when I break a brick"). Single shots spaced out,
## then three bricks at once; each stage timed: the brick found and cleared
## (find_brick on a worker), the tile marked,
## its bake started (a free slot), the bake landed, the new tile swapped in.
## Latency, not frame time: the frames are the edit gate's (--gate).
## `--streaming`: each shot fired with new ground streaming in, as when
## walking or flying (Docs/MineWorld.md 21): a strip of 18 tiles beside the
## player, 2-3 tiles off, is dropped and baked again as new ground just before
## it -- more than the streamer's slots, so the edit's bake competes with them.
func _run_breaklag_gate() -> void:
	await _frames(60)
	set_on_foot(true)
	await _frames(60)
	_streamer.log_latency = true
	var stud := BrickWorld.get_stud_metres()
	var e := _eye()
	var rows: Array = []
	var streaming := "--streaming" in OS.get_cmdline_user_args()
	var t_eye := _tile_of(e)
	if "--burst" in OS.get_cmdline_user_args():
		await _breaklag_burst(e, stud)
		_streamer.log_latency = false
		print("[breaklag] done")
		get_tree().quit()
		return
	var shoot := func(k: int, n: int) -> void:
		break_log.clear()
		_streamer.latency_log.clear()
		if streaming:
			_streamer.invalidate(Rect2i(t_eye + Vector2i(-3 if k % 2 == 0 else 2, -4), Vector2i(2, 9)))
		var t0 := Time.get_ticks_usec()
		var hid0: int = bricks.hidden_total if bricks != null else 0
		for j in n:
			var p := e + Vector3(1.6 + float((k * 3 + j) % 6) * 0.7, 0.0, -2.4 - floorf(float(k * 3 + j) / 6.0) * 0.7)
			var c := Vector2i(floori(p.x / stud), floori(p.z / stud))
			p.y = _ground_m(c.x, c.y) - 0.2
			_mine(p, Vector3.DOWN, null)
		# What the player sees: bricks of the brick overlay go the frame they
		# are shot (Docs/BrickOverlay.md 6), drawn in the next picture.
		var hid: int = (bricks.hidden_total if bricks != null else 0) - hid0
		await RenderingServer.frame_post_draw
		var seen_ms := (Time.get_ticks_usec() - t0) / 1000.0
		for f in 45:
			await get_tree().process_frame
		var found := 0
		for b in break_log:
			found = maxi(found, int(b.found) - t0)
		var first_dirty := 1 << 62
		var first_bake := 1 << 62
		var last_land := 0
		var last_swap := 0
		for r in _streamer.latency_log:
			first_dirty = mini(first_dirty, int(r.dirty))
			first_bake = mini(first_bake, int(r.get("bake", r.dirty)))
			last_land = maxi(last_land, int(r.get("land", r.dirty)))
			last_swap = maxi(last_swap, int(r.swap))
		if _streamer.latency_log.is_empty():
			print("[breaklag] %d brick(s): no tile swapped (missed?)" % n)
			return
		var row := {"n": n, "hid": hid, "seen": seen_ms if hid >= n else -1.0,
				"tiles": _streamer.latency_log.size(), "find": found / 1000.0,
				"mark": (first_dirty - t0 - found) / 1000.0, "wait": (first_bake - first_dirty) / 1000.0,
				"bake": (last_land - first_bake) / 1000.0, "swap": (last_swap - last_land) / 1000.0,
				"total": (last_swap - t0) / 1000.0}
		rows.append(row)
		print("[breaklag] %d brick(s), %d tile(s): found %.0f ms, marked +%.0f, bake started +%.0f, baked +%.0f, swapped +%.0f = %.0f ms; %s" % [
				n, row.tiles, row.find, row.mark, row.wait, row.bake, row.swap, row.total,
				"SEEN GONE in %.0f ms (the overlay hid %d of %d)" % [seen_ms, hid, n] if hid >= n
				else "seen with the tile (the overlay hid %d of %d)" % [hid, n]])
	for k in 12:
		await shoot.call(k, 1)
	for k in 4:
		await shoot.call(12 + k, 3)
	for n in [1, 3]:
		var sum := {}
		var worst := 0.0
		var cnt := 0
		var seen_sum := 0.0
		var seen_n := 0
		var seen_worst := 0.0
		for r in rows:
			if int(r.n) != n:
				continue
			cnt += 1
			if float(r.seen) >= 0.0:
				seen_n += 1
				seen_sum += float(r.seen)
				seen_worst = maxf(seen_worst, float(r.seen))
			worst = maxf(worst, float(r.total))
			for k in ["find", "mark", "wait", "bake", "swap", "total"]:
				sum[k] = float(sum.get(k, 0.0)) + float(r[k])
		if cnt == 0:
			continue
		print("[breaklag] %d brick(s), mean of %d: found %.0f, marked +%.0f, bake started +%.0f, baked +%.0f, swapped +%.0f = %.0f ms (worst %.0f)" % [
				n, cnt, sum.find / cnt, sum.mark / cnt, sum.wait / cnt, sum.bake / cnt, sum.swap / cnt, sum.total / cnt, worst])
		print("[breaklag] %d brick(s): seen gone in %.0f ms mean (worst %.0f) in %d of %d, the brick overlay hiding them at the shot" % [
				n, seen_sum / maxf(1.0, seen_n), seen_worst, seen_n, cnt])
	_streamer.log_latency = false
	print("[breaklag] done")
	get_tree().quit()


## --gate=breaklag --burst: SUSTAINED FIRE (the user: "sometimes full
## seconds" before a broken brick goes, Docs/MineWorld.md 21). Ten shots a
## second for 3 s (`--burst-every=N` frames a shot, 6) into the ground in front, a few studs apart, then quiet;
## each shot is timed from the trigger to the frame its hole is DRAWN (every
## tile it changed swapped in at its generation or later).
func _breaklag_burst(e: Vector3, stud: float) -> void:
	break_log.clear()
	var shots := 30
	var f := 0
	var fired := 0
	var gone: Array[float] = []
	var every := 6
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--burst-every="):
			every = maxi(1, int(arg.split("=")[1]))
	while f < 600:
		if fired < shots and f % every == 0:
			var p := e + Vector3(1.2 + float(fired % 5) * 0.7, 0.0, -2.0 - floorf(float(fired) / 5.0) * 0.7)
			var c := Vector2i(floori(p.x / stud), floori(p.z / stud))
			p.y = _ground_m(c.x, c.y) - 0.2
			_mine(p, Vector3.DOWN, null)
			fired += 1
		await get_tree().process_frame
		f += 1
		for b in break_log:
			if not b.has("want") or b.has("gone"):
				continue
			var shown := true
			for c in b.want:
				if int(_streamer.drawn_gen.get(c, -1)) < int(b.want[c]):
					shown = false
			if shown:
				b["gone"] = Time.get_ticks_usec()
				gone.append((b.gone - b.shot) / 1000.0)
		if fired == shots and gone.size() >= break_log.size() and f > shots * every + 30:
			break
	var waiting := 0
	for b in break_log:
		if not b.has("gone"):
			waiting += 1
	gone.sort()
	var mean := 0.0
	for g in gone:
		mean += g
	mean /= maxf(1.0, gone.size())
	var over := func(ms: float) -> int:
		var n := 0
		for g in gone:
			if g > ms:
				n += 1
		return n
	print("[breaklag] burst: %d shots, %d broke, %d never drawn; trigger to hole drawn: mean %.0f ms, median %.0f, worst %.0f; over 100 ms %d, over 250 ms %d, over 1 s %d" % [
			fired, break_log.size(), waiting, mean, gone[floori(gone.size() * 0.5)] if not gone.is_empty() else 0.0,
			gone[-1] if not gone.is_empty() else 0.0, over.call(100.0), over.call(250.0), over.call(1000.0)])
	print("[breaklag] burst, each: %s" % ", ".join(gone.map(func(g: float) -> String: return "%.0f" % g)))
	# The brick overlay hides a near brick the frame it is shot (its hole is
	# drawn the next frame), whatever the tile takes (Docs/BrickOverlay.md 6).
	var hidden := 0
	for b in break_log:
		if b.has("hidden"):
			hidden += 1
	print("[breaklag] burst: %d of %d hidden by the brick overlay the frame they were shot (%s)" % [hidden,
			break_log.size(), bricks.readout() if bricks != null and _overlay_on else "overlay off"])
	# Where each shot's time went: queued for a worker, finding, waiting to
	# be landed, then the tile.
	var parts: Array[String] = []
	for b in break_log:
		if b.has("find_start") and b.has("gone"):
			parts.append("%.0f/%.0f/%.0f/%.0f" % [(int(b.find_start) - int(b.shot)) / 1000.0,
					(int(b.find_end) - int(b.find_start)) / 1000.0, (int(b.found) - int(b.find_end)) / 1000.0,
					(int(b.gone) - int(b.found)) / 1000.0])
	print("[breaklag] burst, queued/find/land/tile ms: %s" % ", ".join(parts))


## -- --gate=gpu: WHERE THE GPU'S TIME GOES in the mine world (a report, not
## checks; the planet's --gate=cost method, Docs/PlanetCost.md). Flat out --
## vsync and the fps cap off, in memory only (never saved) -- because a
## vsynced iGPU clocks down to fill the frame and reads the same whatever it is
## given. From two views (on foot looking along the ground; over the land to
## the horizon), each suspect is switched off in turn and the GPU's own time
## read with it gone, against a baseline taken just before it (the heat's
## drift is out of each row). Only trustworthy with the editor closed and no
## other runs (CLAUDE.md).
const GPU_FRAMES := 150
var _gpu_saved := {}


func _gpu_measure() -> Dictionary:
	await _frames(20)
	var clock := FrameClock.new()
	add_child(clock)
	await _frames(GPU_FRAMES)
	var n := maxf(float(clock.frames), 1.0)
	var out := {"frame": clock.all_ms / n}
	for k in ["process", "draw", "gpu", "draws_k", "tris_M", "sh_draws_k", "sh_tris_M"]:
		out[k] = float(clock.all.get(k, 0.0)) / n
	clock.queue_free()
	return out


func _gpu_line(label: String, m: Dictionary, base: Dictionary) -> String:
	var d := ""
	if not base.is_empty():
		d = "  dGPU %+6.2f  dframe %+6.2f" % [float(m.gpu) - float(base.gpu), float(m.frame) - float(base.frame)]
	return "[gpu] %-32s frame %6.2f  gpu %6.2f  draw(cpu) %5.2f  process %5.2f | %5.2fk draws %5.2fM tris, shadow %5.2fk draws %5.2fM tris%s" % [
			label, float(m.frame), float(m.gpu), float(m.draw), float(m.process), float(m.draws_k),
			float(m.tris_M), float(m.sh_draws_k), float(m.sh_tris_M), d]


func _gpu_hide(nodes: Array) -> void:
	for n in nodes:
		if n != null and is_instance_valid(n):
			_gpu_saved[n] = (n as Node3D).visible
			(n as Node3D).visible = false


func _gpu_shadows_off(roots: Array) -> void:
	for r in roots:
		if r == null or not is_instance_valid(r):
			continue
		var list: Array = (r as Node).find_children("*", "GeometryInstance3D", true, false)
		if r is GeometryInstance3D:
			list.append(r)
		for g in list:
			_gpu_saved[g] = (g as GeometryInstance3D).cast_shadow
			(g as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func _gpu_back() -> void:
	for n in _gpu_saved:
		if not is_instance_valid(n):
			continue
		var v = _gpu_saved[n]
		if v is bool:
			(n as Node3D).visible = v
		else:
			(n as GeometryInstance3D).cast_shadow = v
	_gpu_saved.clear()


## Every instance node (studs, tufts, pebbles, bricks) of the near tiles.
func _gpu_instances() -> Array:
	return _streamer.find_children("*", "MultiMeshInstance3D", true, false)


## The trees' instance nodes, near (real brick trees) or far (cards), from
## every ImpostorLod under the trees.
func _gpu_tree_tier(tier: String) -> Array:
	var out: Array = []
	for n in _trees.find_children("*", "Node3D", true, false):
		if n is ImpostorLod:
			for c in (n as ImpostorLod)._chunks.values():
				if c[tier] != null:
					out.append(c[tier])
	return out


## The faces behind the overlay's bricks (Docs/BrickOverlay.md 6b), tiles'
## and sections'.
func _gpu_behind() -> Array:
	return _streamer.find_children("SurfaceBehind", "MeshInstance3D", true, false) 			+ _deep.find_children("SurfaceBehind", "MeshInstance3D", true, false)


func _gpu_toggles() -> Array:
	var vp := get_viewport()
	var sun := _rig.sun
	var sky: Sky = _rig.env.sky
	var t: Array = []
	var dist0 := sun.directional_shadow_max_distance
	var mode0 := sun.directional_shadow_mode
	t.append(["sun shadows off", func(): sun.shadow_enabled = false, func(): sun.shadow_enabled = true])
	t.append(["sun shadow %.0f -> 60 m" % dist0, func(): sun.directional_shadow_max_distance = 60.0,
			func(): sun.directional_shadow_max_distance = dist0])
	t.append(["sun shadow splits -> 2", func(): sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS,
			func(): sun.directional_shadow_mode = mode0])
	t.append(["trees cast no shadow", func(): _gpu_shadows_off([_trees]), _gpu_back])
	t.append(["tree cards cast no shadow", func(): _gpu_shadows_off(_gpu_tree_tier("far")), _gpu_back])
	t.append(["near trees cast no shadow", func(): _gpu_shadows_off(_gpu_tree_tier("near")), _gpu_back])
	t.append(["day/night not written (held)", func(): sky_hold = true, func(): sky_hold = false])
	var rad0 := sky.radiance_size
	t.append(["sky radiance -> 32", func(): sky.radiance_size = Sky.RADIANCE_SIZE_32, func(): sky.radiance_size = rad0])
	var glow0 := _rig.env.glow_enabled
	t.append(["glow off", func(): _rig.env.glow_enabled = false, func(): _rig.env.glow_enabled = glow0])
	t.append(["trees hidden", func(): _gpu_hide([_trees]), _gpu_back])
	t.append(["tree cards hidden", func(): _gpu_hide(_gpu_tree_tier("far")), _gpu_back])
	t.append(["near trees hidden", func(): _gpu_hide(_gpu_tree_tier("near")), _gpu_back])
	t.append(["near tiles hidden", func(): _gpu_hide([_streamer]), _gpu_back])
	t.append(["studs/tufts/pebbles hidden", func(): _gpu_hide(_gpu_instances()), _gpu_back])
	if bricks != null and _overlay_on:
		# The brick overlay (Docs/BrickOverlay.md 5): its boxes and the sunken
		# flat ground, against the flat ground alone.
		t.append(["brick overlay off", func(): bricks.set_enabled(false), func(): bricks.set_enabled(true)])
		t.append(["behind faces hidden", func(): _gpu_hide(_gpu_behind()), _gpu_back])
	t.append(["far tier hidden", func(): _gpu_hide([_far]), _gpu_back])
	t.append(["deep tier hidden", func(): _gpu_hide([_deep]), _gpu_back])
	t.append(["water (all) hidden", func(): _gpu_hide([water]), _gpu_back])
	if water.sea != null:
		t.append(["sea hidden", func(): _gpu_hide([water.sea]), _gpu_back])
	t.append(["lava lights hidden", func(): _gpu_hide(water._lights.values()), _gpu_back])
	var lod0 := vp.mesh_lod_threshold
	t.append(["mesh LOD threshold -> 4 px", func(): vp.mesh_lod_threshold = 4.0, func(): vp.mesh_lod_threshold = lod0])
	t.append(["shadow 2 splits, first 12 m", func():
			sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
			sun.directional_shadow_split_1 = 0.1,
			func(): sun.directional_shadow_mode = mode0])
	var scale0 := vp.scaling_3d_scale
	t.append(["render scale -> 0.5", func(): vp.scaling_3d_scale = 0.5, func(): vp.scaling_3d_scale = scale0])
	return t


func _gpu_view(view_name: String) -> void:
	print("[gpu] --- view: %s ---" % view_name)
	var first := true
	for row in _gpu_toggles():
		var base := await _gpu_measure()
		if first:
			first = false
			print(_gpu_line("baseline", base, {}))
		(row[1] as Callable).call()
		var m := await _gpu_measure()
		(row[2] as Callable).call()
		print(_gpu_line(row[0], m, base))


func _run_gpu_gate() -> void:
	await _frames(60)
	_time = 0.42
	var menu_settings := get_node_or_null(^"/root/MenuSettings")
	if menu_settings != null:
		menu_settings.set_value(&"vsync", 0, false)      # in memory: never saved
		menu_settings.set_value(&"max_fps", 0, false)
	var vp := get_viewport()
	var size := vp.get_visible_rect().size
	print("[gpu] trees: real bricks to %.0f m, cards past it" % _trees.near_m)
	print("[gpu] mine world, %dx%d at render scale %.2f, msaa %d, GI %d, sun shadow %.0f m mode %d, radiance %d, glow %s, near %d tiles" % [
			int(size.x), int(size.y), vp.scaling_3d_scale, vp.msaa_3d, LightRig.gi_level,
			_rig.sun.directional_shadow_max_distance, _rig.sun.directional_shadow_mode,
			_rig.env.sky.radiance_size, _rig.env.glow_enabled, _streamer.near_radius])
	set_on_foot(false)
	var e := _eye()
	# 1: on foot, looking along the ground.
	_fly_to(e + Vector3(0, 0.2, 0), Vector3(1, 0, 0.3).normalized())
	walker.pitch = -0.15
	await _frames(180)
	var tag := "near%d" % roundi(_trees.near_m)
	await _shot(UserPaths.DEV + "mine_gpu_ground_%s.png" % tag)
	await _gpu_view("on foot, along the ground")
	# 2: over the land to the horizon.
	_fly_to(e + Vector3(0, 25.0, 0), Vector3(1, 0, 0.3).normalized())
	walker.pitch = -0.12
	await _frames(240)
	await _shot(UserPaths.DEV + "mine_gpu_up_%s.png" % tag)
	await _gpu_view("25 m up, to the horizon")
	print("[gpu] sky writes %d over the pass (LightRig.sky_writes)" % _rig.sky_writes)
	if menu_settings != null:
		menu_settings.set_value(&"vsync", menu_settings.default_of(&"vsync"), false)
		menu_settings.set_value(&"max_fps", menu_settings.default_of(&"max_fps"), false)
	print("[gpu] done")
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
		wf.sort_custom(func(x: Array, y: Array) -> bool: return x[0] > y[0])
		if wf.size() > 5:
			wf.resize(5)
	var report := func(label: String, w: Dictionary) -> void:
		var n := maxf(float(w.n), 1.0)
		var parts := ""
		for k in ["scripts", "step", "process", "draw", "sync", "gpu", "draws_k", "tris_M"]:
			parts += " %s %.1f" % [k, float(w.parts.get(k, 0.0)) / n]
		var world := ""
		for k in ["near", "far", "deep", "trees", "water", "ground"]:
			world += " %s %.2f" % [k, float(w.world.get(k, 0.0)) / n]
		print("[breakwater] %s: %d frames, mean %.1f ms, worst %.1f ms, %d over 25 ms | clock mean:%s | world mean (ms):%s | water worker tick worst %.1f ms" % [
				label, w.n, float(w.sum) / n, w.worst, w.slow, parts, world, w.water_tick])
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
	var plate := BrickWorld.get_plate_metres()
	# --walk --cave: the walk is in a cave, 4-28 m under the ground, steered
	# along the cave floor (_cave_steer); its own cost is printed apart.
	var cave := walk and "--cave" in OS.get_cmdline_user_args()
	var dir := Vector3(1.0, 0.0, 0.3).normalized()
	var cpos := Vector3.ZERO
	var cfloor := 0
	var cave_us := 0
	var cave_turns := 0
	var cave_back := 0
	var cave_far := 0.0
	var cave_rock := 0
	var cave0 := Vector3.ZERO
	if cave:
		var e := _eye()
		var c := _find_walk_cave(Vector2i(floori(e.x / stud), floori(e.z / stud)))
		if c.x == 1 << 30:
			print("[mine-stop] no cave room within 900 studs: SKIPPED")
			get_tree().quit()
			return
		cfloor = c.y
		cpos = Vector3((c.x + 0.5) * stud, (c.y + 1) * plate, (c.z + 0.5) * stud)
		dir = _cave_open_dir(c.x, c.y, c.z)[0]
		cave0 = cpos
		print("[mine-stop] cave walk from (%d, %d, %d), %.0f m under the ground" % [c.x, c.y, c.z,
				_ground_m(c.x, c.z) - cpos.y])
		_fly_to(cpos + Vector3(0, 1.7, 0), dir)
		walker.pitch = -0.1
	else:
		_fly_to(_eye() + Vector3(0, 1.0 if walk else 10.0, 0), Vector3(1, -0.1, 0.3).normalized())
		walker.pitch = -0.15 if walk else -0.3
	await _frames(30)
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
		if cave:
			var cu := Time.get_ticks_usec()
			var st: Array = _cave_steer(cpos, cfloor, dir, speed * get_process_delta_time())
			cpos = st[0]
			cfloor = st[1]
			if st[2] != dir:
				cave_turns += 1
			if st[3] == 2:
				cave_back += 1
			elif st[3] == 3:
				cave_rock += 1
			dir = st[2]
			cave_far = maxf(cave_far, Vector2(cpos.x - cave0.x, cpos.z - cave0.z).length())
			walker.place(to_global(cpos + Vector3(0, 1.7, 0)), dir)
			walker.pitch = -0.1
			cave_us = maxi(cave_us, Time.get_ticks_usec() - cu)
		else:
			walker.global_position += dir * speed * get_process_delta_time()
		if walk and not cave:
			var tp := to_local(walker.global_position)
			var gy := _ground_m(floori(tp.x / stud), floori(tp.z / stud))
			walker.global_position.y = gy + 1.7
		await get_tree().process_frame
		if clock.last_ms > 33.3:
			mv_slow += 1
			mv_worst.append([clock.last_ms, float(clock.last.get("process", 0.0)), float(clock.last.get("draw", 0.0)),
					float(_ptimes.get("near", 0.0)), float(_ptimes.get("far", 0.0)), float(_ptimes.get("deep", 0.0)),
					float(clock.last.get("scripts", 0.0)), float(clock.last.get("step", 0.0)),
					_trees.last_us / 1000.0, water.last_us / 1000.0, collapse.last_us / 1000.0,
					float(_ptimes.get("reanchor", 0.0)), float(_ptimes.get("pre", 0.0)),
					float(_ptimes.get("post", 0.0)), float(_ptimes.get("all", 0.0))])
		if Time.get_ticks_msec() - t0 > secs - 4000:
			mv_gpu.append(float(clock.last.get("gpu", 0.0)))
			mv_tris = maxf(mv_tris, float(clock.last.get("tris_M", 0.0)))
	TerrainTile.profile_instances = false
	mv_worst.sort_custom(func(x: Array, y: Array) -> bool: return x[0] > y[0])
	print("[mine-stop] moving: %d frames over 33 ms; the worst (ms, process, draw, near, far, deep, scripts, step, trees, water, collapse, reanchor, pre, post, all of the mine's _process): %s" % [
			mv_slow, mv_worst.slice(0, 6).map(func(r: Array) -> String: return "%.0f/%.0f/%.0f/%.1f/%.1f/%.1f/%.1f/%.1f/%.1f/%.1f/%.1f/%.1f/%.1f/%.1f/%.1f" % r)])
	print("[mine-stop] moving: near tier %s" % _streamer.report())
	if _reanchors > 0:
		print("[mine-stop] moving: far rings re-anchored %d times, the last %.1f ms (%s)" % [_reanchors,
				_last_reanchor_ms, _reanchor_parts])
	if cave:
		print("[mine-stop] cave walk: reached %.0f m from the start, %d turns, %d dead ends, %d frames in rock (no way found), steering worst %.2f ms (in process); deep tier %s"
				% [cave_far, cave_turns, cave_back, cave_rock, cave_us / 1000.0, _deep.report()])
	var inst_keys := TerrainTile.instance_ms.keys()
	inst_keys.sort_custom(func(x, y) -> bool: return float(TerrainTile.instance_ms[x]) > float(TerrainTile.instance_ms[y]))
	print("[mine-stop] moving: instance steps %s" % [inst_keys.slice(0, 10).map(func(k) -> String: return "%s %.1f" % [k, float(TerrainTile.instance_ms[k])])])
	mv_gpu.sort()
	print("[mine-stop] %s %d s at %.0f m/s (held %s), stopping; the last 4 s moving: gpu median %.1f, 90th %.1f ms, tris up to %.2fM"
			% ["walked" if walk else "flew", secs / 1000.0, speed, fast_hold,
			mv_gpu[mv_gpu.size() >> 1] if not mv_gpu.is_empty() else 0.0,
			mv_gpu[int(mv_gpu.size() * 0.9)] if not mv_gpu.is_empty() else 0.0, mv_tris])
	var windows := []
	var w := {}
	var tw := Time.get_ticks_msec()
	var built0 := _streamer.built_count()
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
			w["far_n"] = _far.applies - far0
			w["deep_n"] = _deep.built - deep0
			w["lava"] = water.lava_lights()
			w["wtiles"] = water.drawn
			built0 = _streamer.built_count()
			far0 = _far.applies
			deep0 = _deep.built
			windows.append(w)
			w = {}
	for i in windows.size():
		var x: Dictionary = windows[i]
		print("[mine-stop] %4.2f s  tris %.2fM sh %.2fM draws %.1fk lava %d wtiles %d" % [(i + 1) * 0.25,
				x.tris, x.get("sh", 0.0), x.get("draws", 0.0), x.lava, x.wtiles])
		print("[mine-stop] %4.2f s  worst %5.1f mean %4.1f gpu %4.1f | worst frame: process %4.1f scripts %4.1f step %4.1f draw %4.1f; near %4.1f deep %4.1f far %4.1f trees %4.1f water %4.1f collapse %4.1f | water max %4.1f | built %d far %d deep %d"
				% [(i + 1) * 0.25, x.worst, x.sum / maxf(x.n, 1), x.gpu, x.process, x.scripts, x.step,
				x.draw, x.near, x.deep, x.far, x.trees, x.water, x.coll, x.water_max, x.built, x.far_n, x.deep_n])
	print("[mine-stop] %s | water %s" % [_streamer.report(), water.report()])
	get_tree().quit()


## --cave's start: a cave room 4-28 m under the ground (tall enough to
## stand in, a floor 3 x 3 studs) near `c0`, studs. x = 1 << 30: none.
func _find_walk_cave(c0: Vector2i) -> Vector3i:
	for r in range(0, 900, 6):
		for k in 8:
			var a := TAU * k / 8.0 + r * 0.37
			var x := c0.x + int(r * cos(a))
			var z := c0.y + int(r * sin(a))
			var top := BrickTerrain.surface_plate(x, z)
			var yp := top - 30
			while yp > top - 200 and BrickTerrain.solid_at(x, yp, z) != 0:
				yp -= 1
			if yp <= top - 200:
				continue
			while yp > top - 220 and BrickTerrain.solid_at(x, yp, z) == 0:
				yp -= 1
			if yp <= BrickTerrain.get_bedrock_plate() or not _cave_body_free(x, yp, z):
				continue
			var flat := true
			for dz in range(-1, 2):
				for dx in range(-1, 2):
					if _cave_floor(x + dx, z + dz, yp) != yp:
						flat = false
			# Not a pocket: a way out at least 60 studs (21 m) long.
			if flat and int(_cave_open_dir(x, yp, z)[1]) >= 60:
				return Vector3i(x, yp, z)
	return Vector3i(1 << 30, 0, 0)


## Room for the walker over a floor brick at plate `fp`: 13 plates (1.8 m).
func _cave_body_free(x: int, fp: int, z: int) -> bool:
	if BrickTerrain.solid_at(x, fp, z) == 0:
		return false
	for k in range(1, 14, 2):
		if BrickTerrain.solid_at(x, fp + k, z) != 0:
			return false
	return true


## The floor a walker at floor `fp` reaches in column (x, z): a step up or
## down of 6 plates (0.8 m). Not more down: from a deeper pit it could not
## climb back. -(1 << 30): none.
func _cave_floor(x: int, z: int, fp: int) -> int:
	for y in range(fp + 6, fp - 7, -1):
		if _cave_body_free(x, y, z):
			return y
	return -(1 << 30)


## The way out of the start with the longest walk, of 16: [dir, studs].
func _cave_open_dir(x: int, fp: int, z: int) -> Array:
	var stud := BrickWorld.get_stud_metres()
	var best := Vector3(1, 0, 0)
	var best_n := -1
	for k in 16:
		var d := Vector3(cos(TAU * k / 16.0), 0, sin(TAU * k / 16.0))
		var f := fp
		var n := 0
		while n < 60:
			var q := Vector3((x + 0.5) * stud, 0, (z + 0.5) * stud) + d * (n + 1) * stud
			f = _cave_floor(floori(q.x / stud), floori(q.z / stud), f)
			if f == -(1 << 30):
				break
			n += 1
		if n > best_n:
			best_n = n
			best = d
	return [best, best_n]


## One step of the cave walk: `pos` (terrain frame, the feet), on floor
## `fp`, heading `dir`, `step` metres. Looks 1.2 m ahead; blocked, it
## follows the wall on its left: right turns first (to 157 degrees), then
## left, else back, so it leaves a dead end instead of bouncing in it. Returns
## [pos, floor, dir, 0 ahead | 1 turned | 2 turned back | 3 no way].
func _cave_steer(pos: Vector3, fp: int, dir: Vector3, step: float) -> Array:
	var stud := BrickWorld.get_stud_metres()
	var plate := BrickWorld.get_plate_metres()
	var how := 0
	var tries := [0.0]
	for i in range(1, 8):
		tries.append(-i * PI / 8.0)
	for i in range(1, 8):
		tries.append(i * PI / 8.0)
	tries.append(PI)
	for t: float in tries:
		var d := dir.rotated(Vector3.UP, t)
		var la := pos + d * 1.2
		var f := _cave_floor(floori(la.x / stud), floori(la.z / stud), fp)
		if f == -(1 << 30):
			continue
		var np := pos + d * step
		var nf := _cave_floor(floori(np.x / stud), floori(np.z / stud), fp)
		if nf == -(1 << 30):
			continue
		how = 0 if t == 0.0 else (2 if t == PI else 1)
		return [Vector3(np.x, (nf + 1) * plate, np.z), nf, d, how]
	return [pos, fp, dir, 3]


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
	for k in ["Studs", "StudsFar", "StudsSky", "StudsSkyFar", "Tufts", "Pebbles", "Bricks"]:
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
			var pt := Vector3((x - t.x * 32 + 0.5) * stud, (yp + 1) * plate - 0.03, (z - t.y * 32 + 0.5) * stud)
			for o in range(0, boxes.size(), 6):
				if absf(pt.x - boxes[o]) <= boxes[o + 3] * 0.5 and absf(pt.y - boxes[o + 1]) <= boxes[o + 4] * 0.5 						and absf(pt.z - boxes[o + 2]) <= boxes[o + 5] * 0.5:
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
	print("[mine-deep] light in the cave: picture mean %.3f, eye's sky light %.1f, eye brightness %.3f, ambient %.3f, sun %.3f, sky %.3f, exposure %.2f"
			% [luma, _eye_sky, _cave_light, _rig.env.ambient_light_energy, _rig.sun.light_energy,
			_rig.sky_mat.sky_energy_multiplier, _rig.exposure])
	await _deep_lava(found, luma)
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
		# On, whatever the eye's rule left them: does the ground's AO keep
		# the sky's reflections off the cave's walls by itself?
		env.reflected_light_source = Environment.REFLECTION_SOURCE_BG
		await _frames(20)
		res.append("reflections on %.3f" % await _mean_luma())
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
		var amb := env.ambient_light_source
		var sun_was := _rig.sun.visible
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
		env.ambient_light_source = amb
		_rig.sun.visible = sun_was
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
			st != null and bool(st._collision_done), int((st._data.boxes as PackedFloat32Array).size() / 6.0) if st != null else 0])
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


## --gate=deep's lava (Docs/MineWorld.md 18): a pit of lava dug in the cave's
## floor ahead of the eye, its BLOCK LIGHT on the walls once the tiles round
## it are baked again; then the same with the water's per-tile lava lights
## hidden (do they still add anything?) and with the block light off.
func _deep_lava(found: Vector3, dark_luma: float) -> void:
	var stud := BrickWorld.get_stud_metres()
	var plate := BrickWorld.get_plate_metres()
	var fx := floori(found.x / stud) + 5
	var fz := floori(found.z / stud) + 1
	var b := floori(float(roundi(found.y / plate) - 1) / 3.0)
	var r: Dictionary = BrickTerrain.fill_box(Vector3i(fx - 1, b * 3, fz - 1), Vector3i(fx + 1, b * 3 + 2, fz + 1), 0, false)
	terrain_edited(r)
	water.manual = true
	for dz in range(-1, 2):
		for dx in range(-1, 2):
			BrickFluid.place(Vector3i(fx + dx, b, fz + dz), 2, 0, 3)
	water.step(1)
	var lava_n := int(BrickFluid.stats().get("lava_cells", 0))
	var relit0 := lava_relit_tiles
	for f in 400:
		await get_tree().process_frame
		if f > 90 and _lava_relight.is_empty() and _deep._tasks.is_empty() and _deep._dirty.is_empty() \
				and _deep._stale.is_empty():
			break
	await _frames(10)
	await _shot(UserPaths.DEV + "mine_deep_lava.png")
	var lit: float = await _mean_luma()
	_gpu_hide(water._lights.values())
	await _frames(4)
	await _shot(UserPaths.DEV + "mine_deep_lava_nolights.png")
	var no_omni: float = await _mean_luma()
	_gpu_back()
	_mat.set_shader_parameter("block_light_energy", 0.0)
	_mat.set_shader_parameter("block_light_ao", 0.0)
	await _frames(4)
	var no_block: float = await _mean_luma()
	_mat.set_shader_parameter("block_light_energy", 1.0)
	_mat.set_shader_parameter("block_light_ao", 0.5)
	await _frames(4)
	print("[mine-deep] lava in the cave: %d lava cells, %d tiles relit; picture mean %.3f (dark %.3f), lava lights hidden %.3f, block light off %.3f; %d lava lights"
			% [lava_n, lava_relit_tiles - relit0, lit, dark_luma, no_omni, no_block, water.lava_lights()])
	for dz in range(-1, 2):
		for dx in range(-1, 2):
			BrickFluid.remove(Vector3i(fx + dx, b, fz + dz), -1)
	water.step(1)
	water.manual = false


## -- --gate=handover (Docs/MineWorld.md 20): what the ground draws and what
## leaves it change in the SAME frame. After every drawn frame
## (RenderingServer.frame_post_draw) it notes which tiles are the ones from
## before an edit and whether what fell is out:
##   1. a shot breaks a top brick that crosses a tile edge: frames with one
##      tile swapped and the other not are frames where half the brick (and
##      its studs) is drawn -- the stud flash;
##   2. a floating dirt block across a tile edge falls as a piece, and a sand
##      column pair as columns: a frame with the tiles swapped and nothing out
##      is a gap (the flash as it starts to fall); one with it out and a tile
##      not swapped draws it twice.
## Pictures of the frames round each change go to user://dev/handover/.
func _run_handover_gate() -> void:
	await _frames(30)
	var dev := UserPaths.DEV.path_join("handover/")
	DirAccess.make_dir_recursive_absolute(dev)
	var fails := 0
	var stud := BrickWorld.get_stud_metres()
	var plate := BrickWorld.get_plate_metres()
	var tile := BrickTerrain.get_tile_studs()
	_time = 0.42
	set_on_foot(false)
	# Pictures of the ground, not of the gun, the readout or a tree.
	view.process_mode = Node.PROCESS_MODE_DISABLED
	view.rig.visible = false
	if view.arms != null:
		view.arms.visible = false
	_hud_layer.visible = false
	if _trees != null:
		_trees.visible = false
	var e := _eye()
	var edge_x := (floori(e.x / stud / tile) + 1) * tile
	var ez := floori(e.z / stud)
	var tile_of := func(x: int, z: int) -> Vector2i:
		return Vector2i(floori(float(x) / tile), floori(float(z) / tile))
	# 1. A top brick across the tile edge.
	var target := {}
	for dz in range(0, 40):
		for sgn in [1, -1]:
			var z: int = ez + dz * sgn
			var x0 := edge_x - 1
			var top := BrickTerrain.surface_plate(x0, z)
			var p := Vector3((x0 + 0.5) * stud, (top + 1) * plate - 0.03, (z + 0.5) * stud)
			var found: Dictionary = BrickTerrain.find_brick(p, Vector3.UP)
			var found_runs: PackedInt32Array = found.get("runs", PackedInt32Array())
			var lo_x := 1 << 30
			var hi_x := -(1 << 30)
			for i in range(0, found_runs.size(), 4):
				lo_x = mini(lo_x, found_runs[i])
				hi_x = maxi(hi_x, found_runs[i])
			if not found_runs.is_empty() and lo_x < edge_x and hi_x >= edge_x:
				target = {"p": p, "z": z, "top": top, "runs": found_runs}
				break
		if not target.is_empty():
			break
	if target.is_empty():
		print("[handover] FAIL  no top brick across a tile edge near x=%d" % edge_x)
		get_tree().quit()
		return
	var tz: int = target.z
	var aim := Vector3(edge_x * stud, (int(target.top) + 1) * plate, (tz + 0.5) * stud)
	await _aim_eye(aim + Vector3(0.3, 1.5, -1.6), aim)
	await _frames(120)
	_streamer.settle(Vector2(aim.x, aim.z))
	await _frames(20)
	var runs: PackedInt32Array = target.runs
	var tiles := {}
	for i in range(0, runs.size(), 4):
		tiles[tile_of.call(runs[i], runs[i + 1])] = true
	var old := {}
	for c in tiles:
		old[c] = _streamer._tiles.get(c)
	var on_screen := _eye_camera().unproject_position(to_global(aim))
	print("[handover] the brick is at %.0f, %.0f on screen when shot" % [on_screen.x, on_screen.y])
	_mine(target.p, Vector3.DOWN, null)
	var seq: Array[int] = []
	var flash := 0
	var shots := 0
	var last := 0
	for f in 90:
		await RenderingServer.frame_post_draw
		var n := 0
		for c in tiles:
			if _streamer._tiles.get(c) != old[c]:
				n += 1
		seq.append(n)
		if n > 0 and n < tiles.size():
			flash += 1
		# Pictures for a look only: 2026-11-22 these never showed the hole a
		# break leaves (the game does), so the check is the swap count above
		# and the cells below, not the pictures.
		if shots < 14:
			_shot(dev + "break_f%02d_%dof%d.png" % [f, n, tiles.size()])
			shots += 1
		last = n
		if n == tiles.size() and f > 4 and seq[f - 4] == n:
			break
	# And the brick really went: a swap of tiles still holding it is no break.
	var left := 0
	for i in range(0, runs.size(), 4):
		for yp in range(runs[i + 2], runs[i + 3] + 1):
			if BrickTerrain.solid_at(runs[i], yp, runs[i + 1]) != 0:
				left += 1
	var ok := flash == 0 and last == tiles.size() and left == 0
	print("[handover] %s  a brick across a tile edge (%d tiles) leaves in one frame: %d frame(s) half swapped, %d cell(s) of it left; swapped per frame %s" % [
			"ok  " if ok else "FAIL", tiles.size(), flash, left, seq])
	fails += 0 if ok else 1
	# 2. A floating dirt block, then sand, across the edge, over the ground.
	var hi_top := -(1 << 30)
	for dz in range(-1, 3):
		for dx in range(-2, 2):
			hi_top = maxi(hi_top, BrickTerrain.surface_plate(edge_x + dx, tz + 8 + dz))
	var b := (floori(float(hi_top + 1) / 3.0) + 3) * 3
	var aim2 := Vector3(edge_x * stud, b * plate, (tz + 8.5) * stud)
	await _aim_eye(aim2 + Vector3(0.4, 0.6, -3.2), aim2 + Vector3(0, -0.6, 0))
	await _frames(60)
	for kind in ["piece", "sand"]:
		var p0: int = collapse.pieces.pieces.size()
		var mat := 2 if kind == "piece" else 3
		var lo := Vector3i(edge_x - 1, b, tz + 8)
		var hi := lo + (Vector3i(1, 2, 1) if kind == "piece" else Vector3i(1, 8, 0))
		terrain_edited(BrickTerrain.fill_box(lo, hi, mat, true))
		var entry: Dictionary = {}
		var rect_tiles := {}
		var olds := {}
		var gap := 0
		var twice := 0
		var seen_out := false
		var trace: Array[String] = []
		var shots2 := 0
		var prev := ""
		for f in 400:
			await RenderingServer.frame_post_draw
			if entry.is_empty():
				for w in collapse._waiting:
					if w.kind == kind:
						entry = w
				if entry.is_empty():
					continue
				var r: Rect2i = entry.rect
				for c in _streamer._tiles:
					if r.has_point(c):
						rect_tiles[c] = true
						olds[c] = _streamer._tiles[c]
			var n := 0
			for c in rect_tiles:
				if _streamer._tiles.get(c) != olds[c]:
					n += 1
			var out: bool = (collapse.pieces.pieces.size() > p0) if kind == "piece" \
					else not collapse._sand.is_empty()
			var all := n == rect_tiles.size()
			# Once out, sand lands and is ground again: only frames before.
			if not out and n > 0 and not seen_out:
				gap += 1
			seen_out = seen_out or out
			if out and not all:
				twice += 1
			var st := "%d/%d%s" % [n, rect_tiles.size(), "+out" if out else ""]
			if st != prev:
				trace.append("f%d %s" % [f, st])
				prev = st
			if shots2 < 16:
				_shot(dev + "%s_f%03d_%s.png" % [kind, f, st.replace("/", "of").replace("+", "_")])
				shots2 += 1
			if out and all and shots2 >= 16:
				break
		ok = not entry.is_empty() and gap == 0 and twice == 0
		print("[handover] %s  falling %s: %d gap frame(s) (ground swapped, nothing out), %d drawn twice; %s" % [
				"ok  " if ok else "FAIL", kind, gap, twice, ", ".join(trace)])
		fails += 0 if ok else 1
		await _collapse_quiet(300)
		await _frames(30)
	print("[handover] %s (%d failures)" % ["PASS" if fails == 0 else "FAIL", fails])
	get_tree().quit()

## The eye at `from` (terrain frame) looking at `at`: placed, then moved by
## however far the eye landed from `from` (the walker's eye is not a fixed
## height over the feet it is placed by), and the pitch set from where the eye
## really is. Prints where `at` falls on the screen, so a gate's pictures can
## be trusted to show it.
func _aim_eye(from: Vector3, at: Vector3) -> void:
	var facing := ((at - from) * Vector3(1, 0, 1)).normalized()
	_fly_to(from - Vector3(0, 1.6, 0), facing)
	await _frames(2)
	_fly_to(from - Vector3(0, 1.6, 0) - (_eye() - from), facing)
	await _frames(2)
	var e := _eye()
	var d := at - e
	walker.pitch = atan2(d.y, Vector2(d.x, d.z).length())
	await _frames(2)
	var c := _eye_camera()
	var px := c.unproject_position(to_global(at))
	var size := get_viewport().get_visible_rect().size
	print("[gate] eye %s off by %.2f m; aim on screen at %.0f, %.0f of %.0f x %.0f" % [
			e, (_eye() - from).length(), px.x, px.y, size.x, size.y])


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
	# The pond made a lake (S3, Docs/MineWaterNext.md R1): sources in every
	# cell, its open top rides a small wave, bigger away from its rim.
	for x in range(5, 13):
		for z in range(5, 13):
			BrickFluid.place(Vector3i(o.x + x, w, o.y + z), 1, BrickFluid.SOURCE, 3)
	water.step(5)
	look.call(pm.call(16.0, w + 3.0, 16.0), pm.call(9.0, w, 9.0))
	await _frames(40)
	await _shot(dev + "water_lake.png")
	await _frames(30)
	await _shot(dev + "water_lake_later.png")
	var lake_at := Vector3((o.x + 9.5) * stud, (w + 1) * course, (o.y + 9.5) * stud)
	var lw0: float = water.surface_at(lake_at)
	await _frames(20)
	print("[water-gate] lake: surface at its middle %.3f then %.3f m (flat top %.3f)" % [
			lw0, water.surface_at(lake_at), (w + 1) * course])

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
	var night_luma: float = await _mean_luma()
	print("[water-gate] lava pool: %d lava lights, %d burning, %s" % [water.lava_lights(), water.fires.burning.size(), water.report()])
	# The ground's block light (Docs/MineWorld.md 18) without the per-tile
	# lava lights: what they still add.
	_gpu_hide(water._lights.values())
	await _frames(4)
	await _shot(dev + "water_lava_night_nolights.png")
	var no_omni: float = await _mean_luma()
	_gpu_back()
	print("[water-gate] lava at night: picture mean %.3f, lava lights hidden %.3f (block light alone), %d tiles relit"
			% [night_luma, no_omni, lava_relit_tiles])
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
	# Far away the terrain lets the platform's tile go, and its water goes
	# with it; back, both come back (the user, 2026-11-23: flowing water
	# never unloaded).
	var pt := Vector2i(floori(float(o.x) / 32.0), floori(float(o.y) / 32.0))
	var home := _eye()
	# Water drops at the chosen terrain LOD (Options > Video > Water Drops
	# At): 160 m off, the platform's ground is coarse (LOD 1): at the default
	# (drop at LOD 2) its water still shows; set to drop at LOD 1, it goes.
	var W := Water
	_fly_to(home + Vector3(160, 0, 0), Vector3(1, 0, 0))
	var lw := 0
	while lw < 900 and _streamer.has_tile(pt):
		await get_tree().process_frame
		lw += 1
	await _frames(60)
	var shown_lod2: bool = water.has_tile_drawn(pt)
	var bare2: int = water.drawn_on_bare()
	W.drop_lod = 1
	await _frames(60)
	var shown_lod1: bool = water.has_tile_drawn(pt)
	W.drop_lod = -1
	await _frames(60)
	print("[water-gate] water LOD: 160 m off (ground LOD %d), platform water drawn at drop LOD 2 %s (want true), at LOD 1 %s (want false), back %s; past the drop LOD %d (want 0)" % [
			Water.tile_lod(pt, Vector2i(floori(_eye().x / (32.0 * stud)), floori(_eye().z / (32.0 * stud))), _streamer),
			shown_lod2, shown_lod1, water.has_tile_drawn(pt), bare2])
	_fly_to(home + Vector3(400, 0, 0), Vector3(1, 0, 0))
	var waited := 0
	while waited < 900 and (_streamer.has_tile(pt) or water.has_tile_drawn(pt)):
		await get_tree().process_frame
		waited += 1
	var gone: bool = not water.has_tile_drawn(pt)
	var bare: int = water.drawn_on_bare()
	_fly_to(home, Vector3(1, 0, 0))
	waited = 0
	while waited < 900 and not water.has_tile_drawn(pt):
		await get_tree().process_frame
		waited += 1
	print("[water-gate] unload: platform tile water gone far away %s, drawn on bare ground %d (want 0), %d parked; back again %s" % [
			gone, bare, water.parked_count(), water.has_tile_drawn(pt)])
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
	# Low over the real band (Docs/MineWater.md 11.9), looking out along it:
	# its pieces must be flat tops riding the wave, as the tiers' are.
	walker.place(to_global(shore_m + Vector3(dir.x, 0, dir.y) * 1.5 + Vector3(0, 1.2, 0)),
			(Vector3(dir.x, 0, dir.y) * 0.5 + along).normalized())
	walker.pitch = -0.12
	await _frames(40)
	await _shot(dev + "sea_band_low.png")
	# Looking down at the shallows from 2.4 m (see-through water, MineWater.md
	# 7.4): near and far water alike tinted by the water looked through, no
	# line where one tier hands over to the next (the user, 2026-11-23).
	walker.place(to_global(shore_m + Vector3(dir.x, 0, dir.y) * 2.0 + Vector3(0, 2.4, 0)),
			Vector3(dir.x, 0, dir.y))
	walker.pitch = -0.75
	await _frames(40)
	await _shot(dev + "sea_look_down.png")
	# Along the shallows, low: past the real band's square the tiers draw
	# the sea; both must look alike (the user, 2026-11-23: clear past a line).
	walker.place(to_global(shore_m + Vector3(dir.x, 0, dir.y) * 2.0 + Vector3(0, 2.4, 0)),
			(Vector3(dir.x, 0, dir.y) * 0.3 + along).normalized())
	walker.pitch = -0.3
	await _frames(40)
	await _shot(dev + "sea_look_along.png")
	WaterShaders.set_debug(true)
	await _frames(2)
	await _shot(dev + "sea_look_along_alpha.png")
	WaterShaders.set_debug(false)
	# The user's video settings: MSAA 2x, FXAA.
	var vp := get_viewport()
	var msaa0 := vp.msaa_3d
	vp.msaa_3d = Viewport.MSAA_2X
	vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA
	await _frames(10)
	await _shot(dev + "sea_look_along_msaa.png")
	vp.msaa_3d = msaa0
	vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	walker.place(to_global(shore_m + Vector3(dir.x, 0, dir.y) * 1.0 + Vector3(0, 1.2, 0)),
			(Vector3(dir.x, 0, dir.y) + along * 0.4).normalized())
	walker.pitch = -0.15
	await _frames(20)
	await _shot(dev + "sea_band_out.png")
	water._water_mat.set_shader_parameter("debug_band", true)
	await _frames(2)
	await _shot(dev + "sea_band_out_tint.png")
	water._water_mat.set_shader_parameter("debug_band", false)
	# The same with big waves: the band's pieces must step like the tiers'.
	var gain0: float = water.sea.wave_gain
	water.sea.wave_gain = gain0 * 4.0
	water.sea.push_waves()
	await _frames(30)
	await _shot(dev + "sea_band_big.png")
	water._water_mat.set_shader_parameter("debug_band", true)
	await _frames(2)
	await _shot(dev + "sea_band_big_tint.png")
	water._water_mat.set_shader_parameter("debug_band", false)
	# A pillar in deep water, big waves: the band round it beside the tiers.
	var pc := coast + Vector2i((dir * 6.0).round())
	var plo := Vector3i(pc.x, (sea_b - 12) * 3, pc.y)
	var phi := Vector3i(pc.x + 1, (sea_b + 2) * 3, pc.y + 1)
	terrain_edited(BrickTerrain.fill_box(plo, phi, 4, false))
	var pm := Vector3((pc.x + 1) * stud, level, (pc.y + 1) * stud)
	walker.place(to_global(pm - Vector3(dir.x, 0, dir.y) * 5.0 + along * 2.0 + Vector3(0, 2.0, 0)),
			(Vector3(dir.x, 0, dir.y) - along * 0.3).normalized())
	walker.pitch = -0.3
	await _frames(60)
	await _shot(dev + "sea_pillar_big.png")
	water._water_mat.set_shader_parameter("debug_band", true)
	await _frames(2)
	await _shot(dev + "sea_pillar_big_tint.png")
	water._water_mat.set_shader_parameter("debug_band", false)
	# No bricks on water (R3, decision A): one laid sideways off the pillar
	# over deep water is refused; one on the sea floor goes.
	var size0: int = builder.size_i
	builder.size_i = 1          # the 1x1 brick (MineBuilder.SHAPES)
	var deep_to := Vector3i(pc.x + 2, sea_b - 1, pc.y)
	var fx := pc.x + 5
	var fp := BrickTerrain.surface_plate(fx, pc.y)
	var floor_to := Vector3i(fx, floori(fp / 3.0) + (1 if posmod(fp, 3) == 2 else 0), pc.y)
	var refused: bool = builder.floats_on_water(deep_to)
	var allowed: bool = not builder.floats_on_water(floor_to)
	builder.size_i = size0
	print("[sea-gate] no bricks on water: sideways over deep water refused %s, on the sea floor allowed %s" % [
			refused, allowed])
	water.sea.wave_gain = gain0
	water.sea.push_waves()
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
	# A world saved before regions (Docs/MineWorld.md 9): its one file loads,
	# the next save writes every region, and only then is the file dropped.
	var one := FileAccess.open_compressed(path, FileAccess.WRITE, FileAccess.COMPRESSION_ZSTD)
	var all := BrickTerrain.get_edits()
	one.store_buffer(SAVE_MAGIC.to_ascii_buffer())
	one.store_32(SAVE_FORMAT)
	one.store_32(BrickTerrain.get_field_version())
	@warning_ignore("integer_division")
	one.store_32(all.size() / 13)
	one.store_buffer(all)
	one.close()
	_remove_dir(_regions_dir(path))
	var s3 := settings.duplicate(true)
	settings = {}
	generate(s3)
	var back := BrickTerrain.get_edit_count()
	save_edits(true)
	var rfiles := DirAccess.get_files_at(_regions_dir(path)).size() if DirAccess.dir_exists_absolute(_regions_dir(path)) else 0
	var ok := back == count and rfiles > 0 and not FileAccess.file_exists(path)
	print("[mine-gate] %s one-file save moved to regions: %d edits back of %d, %d region files, old file %s (%s)" % [
			"ok  " if ok else "FAIL", back, count, rfiles, "gone" if not FileAccess.file_exists(path) else "STILL THERE", _save_status])


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


## -- --gate=mouth (Docs/MineWorld.md 18): a stone tunnel built on the ground
## near spawn, its mouth open to the day. From 4 studs inside, looking out,
## the day outside must be as bright as the same view with no tunnel (the old
## depth factor darkened all of it: `--no-sky-light` shows it), and the walls
## by the back of the tunnel must be darker than the ones by its mouth.
func _run_mouth_gate() -> void:
	await _frames(10)
	var dev := UserPaths.DEV
	DirAccess.make_dir_recursive_absolute(dev)
	_time = 0.42
	set_on_foot(false)
	_hud_layer.visible = false
	# The roof spans the tunnel: the ground's collapse (ground_collapse.gd)
	# would bring it down. This pass is about the light.
	if collapse != null:
		collapse.process_mode = Node.PROCESS_MODE_DISABLED
	var stud := BrickWorld.get_stud_metres()
	var plate := BrickWorld.get_plate_metres()
	var e := _eye()
	var o := Vector2i(floori(e.x / stud) + 6, floori(e.z / stud))
	var t_max := -(1 << 30)
	for dz in range(-3, 4):
		for dx in range(-6, 17):
			t_max = maxi(t_max, BrickTerrain.surface_plate(o.x + dx, o.y + dz))
	# The tunnel's floor: whole courses, one over the highest ground there.
	var b := (floori(float(t_max + 1) / 3.0) + 1) * 3
	# The walker's feet: its eye is about 1.6 m over them.
	var look_out := Vector3((o.x + 4.5) * stud, b * plate + 0.05, (o.y + 0.5) * stud)
	_fly_to(look_out, Vector3(-1, 0, 0))
	walker.pitch = -0.05
	await _frames(90)
	var centre := Rect2(0.3, 0.3, 0.4, 0.4)
	var before: float = await _mean_luma_in(centre)
	await _shot(dev + "mine_mouth_before.png")
	# Stone shell, then the air inside it: 5 x 5 studs inside, 6 courses tall,
	# 15 studs deep, open at the low-X end. The roof ONE course thick: its
	# course is the columns' top, drawn as top pieces, whose underside the
	# face mesher now draws (it had none: terrain_probe's thin roof check).
	terrain_edited(BrickTerrain.fill_box(Vector3i(o.x, b - 3, o.y - 3), Vector3i(o.x + 16, b + 20, o.y + 3), 4, true))
	terrain_edited(BrickTerrain.fill_box(Vector3i(o.x, b, o.y - 2), Vector3i(o.x + 15, b + 17, o.y + 2), 0, false))
	_flush_edits()
	var roof := 0
	for x in range(o.x, o.x + 16):
		for z in range(o.y - 2, o.y + 3):
			if BrickTerrain.solid_at(x, b + 19, z) != 0:
				roof += 1
	print("[mine-mouth] the tunnel's roof: %d of 80 cells solid; floor plate %d, ground top %d" % [roof, b, t_max])
	for k in [2, 6, 10, 14]:
		print("[mine-mouth] sky_light_at %d studs in: %.0f" % [k, BrickTerrain.sky_light_at(Vector3((o.x + k + 0.5) * stud, (b + 4) * plate, (o.y + 0.5) * stud))])
	_fly_to(look_out, Vector3(-1, 0, 0))
	walker.pitch = -0.05
	await _frames(150)
	var inside: float = await _mean_luma_in(centre)
	var eye_in := _eye_sky
	var light_in := _cave_light
	await _shot(dev + "mine_mouth_inside.png")
	# Facing the side wall, by the mouth and by the back.
	_fly_to(Vector3((o.x + 2.5) * stud, b * plate + 0.05, (o.y + 0.5) * stud), Vector3(0, 0, 1))
	await _frames(60)
	var wall_mouth: float = await _mean_luma_in(centre)
	_fly_to(Vector3((o.x + 13.5) * stud, b * plate + 0.05, (o.y + 0.5) * stud), Vector3(0, 0, 1))
	await _frames(60)
	var wall_back: float = await _mean_luma_in(centre)
	var eye_back := _eye_sky
	await _shot(dev + "mine_mouth_back.png")
	for m in [1, 2]:
		_mat.set_shader_parameter("sky_debug", m)
		await _frames(4)
		await _shot(dev + "mine_mouth_back_dbg%d.png" % m)
	_mat.set_shader_parameter("sky_debug", 0)
	_fly_to(look_out + Vector3(9.0 * stud, 0, 0), Vector3(-1, 0, 0))
	await _frames(60)
	await _shot(dev + "mine_mouth_from_back.png")
	var out_ok := inside >= before * 0.85
	var wall_ok := wall_back < wall_mouth * 0.9
	print("[mine-mouth] %s  the day seen from 4 studs inside a tunnel: centre %.3f, with no tunnel %.3f (eye's sky light %.1f, brightness %.3f, exposure %.2f)%s"
			% ["ok  " if out_ok else "FAIL", inside, before, eye_in, light_in, _rig.exposure,
			"" if _sky_light_on else " [--no-sky-light]"])
	print("[mine-mouth] %s  the tunnel's wall by its back %.3f, by its mouth %.3f (eye's level at the back %.1f; exposure follows the eye, so this is the picture, not the light)"
			% ["ok  " if wall_ok else "FAIL", wall_back, wall_mouth, eye_back])
	get_tree().quit()


## -- --gate=skylit (Docs/MineWorld.md 19): a collapse piece, a chest and a
## dropped item in a stone room built on the ground near spawn. Open to the
## sky they take level 15 and look as they always did (run it again with
## `--no-sky-light` for the shared materials: the "open" numbers should
## match); roofed over, each must be about as dark as the floor beside it,
## and much darker than the same room with their level forced to 15 (the old
## look: lit by the open air in a closed cave).
func _run_skylit_gate() -> void:
	await _frames(10)
	var dev := UserPaths.DEV
	DirAccess.make_dir_recursive_absolute(dev)
	_time = 0.42
	set_on_foot(false)
	view.process_mode = Node.PROCESS_MODE_DISABLED
	view.rig.visible = false
	if view.arms != null:
		view.arms.visible = false
	_hud_layer.visible = false
	# The kit's HUD too (key help, bars, aggro meters): the pictures show the room.
	if kit != null:
		for layer: CanvasLayer in [kit.hud, kit._aggro_layer]:
			if layer != null:
				layer.visible = false
	var stud := BrickWorld.get_stud_metres()
	var plate := BrickWorld.get_plate_metres()
	var site := _build_gate_room()
	var o: Vector2i = site[0]
	var b: int = site[1]
	# A floating dirt block (2 x 2 studs, a course): it falls as a piece.
	terrain_edited(BrickTerrain.fill_box(Vector3i(o.x + 2, b + 9, o.y - 5), Vector3i(o.x + 3, b + 11, o.y - 4), 2, true))
	chests.place(MineChests.block_of(Vector3i(o.x + 6, b, o.y - 5)), [], true)
	drops.spawn(ItemStack.make(&"grass", 1), Vector3((o.x + 11) * stud, (b + 4) * plate, (o.y - 4.5) * stud))
	var foot := Vector3((o.x + 7) * stud, b * plate + 0.05, (o.y + 6) * stud)
	_fly_to(foot, Vector3(0, 0, -1))
	walker.pitch = -0.45
	await _frames(60)
	await _collapse_quiet(400)
	await _frames(30)
	var piece: PlanetPieces.Piece = null
	for p in collapse.pieces.pieces:
		if is_instance_valid(p.body):
			piece = p
	var chest: Node3D = null
	for k in chests.chests:
		chest = chests.chests[k].node
	var drop: Node3D = drops.drops[0].node if drops.count() > 0 else null
	if piece == null or chest == null or drop == null:
		print("[mine-skylit] FAIL  not all made: piece %s, chest %s, drop %s" % [piece != null, chest != null, drop != null])
		get_tree().quit()
		return
	var things: Array = [["piece", piece.body], ["chest", chest], ["drop", drop]]
	# What is measured: each thing's middle on screen, and the floor a stud
	# in front of it (towards the camera), at 256 x 144.
	var spots := func() -> Array:
		var c := get_viewport().get_camera_3d()
		var out := []
		for t in things:
			var n: Node3D = t[1]
			var at: Vector3 = n.global_position
			var fl := to_global(Vector3(to_local(at).x, b * plate + 0.01, to_local(at).z + 2.0 * stud))
			out.append([c.unproject_position(at), c.unproject_position(fl)])
		return out
	var measure := func(tag: String) -> Array:
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		var sz := Vector2(img.get_width(), img.get_height())
		img.resize(256, 144)
		var res := []
		var sp: Array = spots.call()
		for s in sp:
			var pair := []
			for q: Vector2 in s:
				var px := Vector2i(int(q.x / sz.x * 256), int(q.y / sz.y * 144))
				var sum := 0.0
				var n := 0
				for y in range(px.y - 2, px.y + 3):
					for x in range(px.x - 2, px.x + 3):
						if x >= 0 and y >= 0 and x < 256 and y < 144:
							sum += img.get_pixel(x, y).get_luminance()
							n += 1
				pair.append(sum / maxf(n, 1))
			res.append(pair)
		var line := "[mine-skylit] %-9s" % tag
		for i in things.size():
			line += "  %s %.3f (floor %.3f, level %.0f) at %s" % [things[i][0], res[i][0], res[i][1],
					sky_lit.level_of(things[i][1]) if sky_lit != null else -1.0, sp[i][0]]
		print(line + "  eye level %.1f, exposure %.2f" % [_eye_sky, _rig.exposure])
		return res
	var open: Array = await measure.call("open")
	await _shot(dev + "mine_skylit_open.png")
	if sky_lit == null:
		print("[mine-skylit] --no-sky-light: the shared materials, open to the sky only")
		get_tree().quit()
		return
	# The roof: the collapse stopped first (it would bring the slab down).
	collapse.process_mode = Node.PROCESS_MODE_DISABLED
	terrain_edited(BrickTerrain.fill_box(Vector3i(o.x, b + 18, o.y - 9), Vector3i(o.x + 14, b + 20, o.y + 9), 4, true))
	_flush_edits()
	# The shell must be whole: every cell of its walls, floor and roof solid.
	var holes := []
	for y in range(b - 3, b + 21):
		for z in range(o.y - 9, o.y + 10):
			for x in range(o.x, o.x + 15):
				var inside := (x > o.x and x < o.x + 14 and z > o.y - 9 and z < o.y + 9 and y >= b and y <= b + 17) \
						or (x == o.x + 14 and z == o.y and y >= b and y <= b + 2)
				if not inside and BrickTerrain.solid_at(x, y, z) == 0:
					holes.append(Vector3i(x - o.x, y - b, z - o.y))
	print("[mine-skylit] the room's shell: %d holes %s" % [holes.size(), str(holes.slice(0, 12))])
	await _frames(150)
	var cave: Array = await measure.call("cave")
	await _shot(dev + "mine_skylit_cave.png")
	sky_lit.set_force(15.0)
	await _frames(4)
	var old: Array = await measure.call("cave, 15")
	await _shot(dev + "mine_skylit_cave_old.png")
	sky_lit.set_force(-1.0)
	await _frames(4)
	var fails := 0
	for i in things.size():
		var lvl := sky_lit.level_of(things[i][1])
		var obj: float = cave[i][0]
		var fl: float = cave[i][1]
		var was: float = old[i][0]
		var ok: bool = lvl <= 2.0 and obj <= maxf(fl * 2.0, 0.02) and obj < was * 0.5 \
				and sky_lit.level_of(things[i][1]) >= 0.0
		fails += 0 if ok else 1
		print("[mine-skylit] %s  %s in the closed room: %.3f, the floor beside it %.3f, lit by the open air %.3f (level %.0f; open to the sky %.3f)"
				% ["ok  " if ok else "FAIL", things[i][0], obj, fl, was, lvl, open[i][0]])
	# WATER in the dark room: its mesh carries the cells' sky light (COLOR.b,
	# brick::sky_levels_into), so a pool in the closed room is as dark as the
	# floor round it, not lit as the open sea is.
	water.manual = true
	var wpool := []
	for dz in range(-1, 2):
		for dx in range(-1, 2):
			var cell := Vector3i(o.x + 3 + dx, floori(b / 3.0), o.y + 2 + dz)
			BrickFluid.place(cell, 1, 0, 2)
			wpool.append(cell)
	water.step(2)
	await _frames(60)
	await RenderingServer.frame_post_draw
	var wc := get_viewport().get_camera_3d()
	var wat := Vector3((o.x + 3.5) * stud, b * plate + 2.0 * plate, (o.y + 2.5) * stud)
	var wq := wc.unproject_position(to_global(wat))
	var wimg := get_viewport().get_texture().get_image()
	var wsz := Vector2(wimg.get_width(), wimg.get_height())
	wimg.resize(256, 144)
	var wpx := Vector2i(int(wq.x / wsz.x * 256), int(wq.y / wsz.y * 144))
	var wl := 0.0
	var wn := 0
	for y in range(wpx.y - 2, wpx.y + 3):
		for x in range(wpx.x - 2, wpx.x + 3):
			if x >= 0 and y >= 0 and x < 256 and y < 144:
				wl += wimg.get_pixel(x, y).get_luminance()
				wn += 1
	wl /= maxf(wn, 1)
	await _shot(dev + "mine_skylit_water.png")
	var wok := wl <= 0.08
	fails += 0 if wok else 1
	print("[mine-skylit] %s  water in the closed room: %.3f at %s (must be <= 0.08; the floor about 0.04)"
			% ["ok  " if wok else "FAIL", wl, wq])
	for cell: Vector3i in wpool:
		BrickFluid.remove(cell, -1)
	water.step(2)
	# LAVA in the dark room (BrickTerrain.block_light_at): a pool of 3 x 3
	# cells on the floor behind the things, by the back wall (not in front of
	# any); each must take block light and draw brighter than in the dark.
	water.manual = true
	var pool := []
	for dz in range(-1, 2):
		for dx in range(-1, 2):
			var cell := Vector3i(o.x + 8 + dx, floori(b / 3.0), o.y - 7 + dz)
			BrickFluid.place(cell, 2, 0, 3)
			pool.append(cell)
	water.step(1)
	await _frames(90)
	sky_lit.ask_all()
	await _frames(30)
	var hot: Array = await measure.call("lava")
	await _shot(dev + "mine_skylit_lava.png")
	for i in things.size():
		var blk := sky_lit.block_of(things[i][1])
		var obj: float = hot[i][0]
		var ok: bool = blk >= 5.0 and obj > float(cave[i][0]) * 1.5 + 0.005
		fails += 0 if ok else 1
		print("[mine-skylit] %s  %s by the lava: %.3f (block level %.0f; in the dark %.3f)"
				% ["ok  " if ok else "FAIL", things[i][0], obj, blk, cave[i][0]])
	for cell: Vector3i in pool:
		BrickFluid.remove(cell, -1)
	print("[mine-skylit] %s; %s" % ["PASS" if fails == 0 else "%d FAILED" % fails, sky_lit.readout()])
	get_tree().quit()


## The gates' stone room (--gate=skylit, --gate=seams), built on the ground
## a few studs ahead of the eye: walls a stud thick round 13 x 17 studs, 6
## courses tall, open on top, on stone down to the lowest ground (a floor slab
## over a dip is let go by the collapse). Returns [o, b, t_min]: the corner
## column, the floor's plate, the lowest ground's plate. The roof is the
## caller's (a roof over open ground first would come down too).
func _build_gate_room() -> Array:
	var stud := BrickWorld.get_stud_metres()
	var e := _eye()
	var o := Vector2i(floori(e.x / stud) + 6, floori(e.z / stud))
	var t_max := -(1 << 30)
	var t_min := 1 << 30
	for dz in range(-10, 11):
		for dx in range(-1, 36):
			t_max = maxi(t_max, BrickTerrain.surface_plate(o.x + dx, o.y + dz))
			t_min = mini(t_min, BrickTerrain.surface_plate(o.x + dx, o.y + dz))
	# The room's floor: whole courses, one over the highest ground there.
	var b := (floori(float(t_max + 1) / 3.0) + 1) * 3
	terrain_edited(BrickTerrain.fill_box(Vector3i(o.x, mini(t_min, b - 3), o.y - 9), Vector3i(o.x + 14, b + 17, o.y + 9), 4, true))
	terrain_edited(BrickTerrain.fill_box(Vector3i(o.x + 1, b, o.y - 8), Vector3i(o.x + 13, b + 17, o.y + 8), 0, false))
	# Its way out: a tunnel a stud wide and a course tall, 20 studs long, up
	# to the sky at its end. A room with no way out is a sealed chamber,
	# which the mesher does not draw (nobody can be in it); light dies out
	# 15 cells along the tunnel, so the room is dark.
	terrain_edited(BrickTerrain.fill_box(Vector3i(o.x + 14, mini(t_min, b - 3), o.y - 1), Vector3i(o.x + 35, b + 5, o.y + 1), 4, true))
	terrain_edited(BrickTerrain.fill_box(Vector3i(o.x + 14, b, o.y), Vector3i(o.x + 34, b + 2, o.y), 0, false))
	terrain_edited(BrickTerrain.fill_box(Vector3i(o.x + 34, b, o.y), Vector3i(o.x + 34, b + 5, o.y), 0, false))
	return [o, b, t_min]


## -- --gate=buildings (Docs/TerrainBuildings.md, stage 1): a city tower
## written INTO the ground (MineBuildings.stamp), then looked at near, from
## 40 m and from 120 m (pictures mine_building_near/mid/far.png), shot (its
## wall brick hidden the frame it is hit, as the ground's are), and dug out
## from under half its footprint: what is cut loose falls (ground_collapse),
## pictures mine_building_dug.png / _fallen.png. `--floors=N` (1-10, 6).
func _run_buildings_gate() -> void:
	await _frames(10)
	var dev := UserPaths.DEV
	DirAccess.make_dir_recursive_absolute(dev)
	_time = 0.42
	set_on_foot(false)
	view.process_mode = Node.PROCESS_MODE_DISABLED
	view.rig.visible = false
	if view.arms != null:
		view.arms.visible = false
	_hud_layer.visible = false
	if kit != null:
		for layer: CanvasLayer in [kit.hud, kit._aggro_layer]:
			if layer != null:
				layer.visible = false
	var fails := 0
	var check := func(ok: bool, what: String) -> void:
		print("[mine-buildings] %s  %s" % ["ok  " if ok else "FAIL", what])
	var floors := 6
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--floors="):
			floors = clampi(int(a.get_slice("=", 1)), 1, 10)
	var stud := BrickWorld.get_stud_metres()
	var plate := BrickWorld.get_plate_metres()
	var e := _eye()
	var p := {"x": 20, "z": 20, "courses": floors * TowerRecipe.COURSES_PER_FLOOR, "rooms": true,
			"windows": true, "stairs": true}
	var corner := Vector2i(floori(e.x / stud) + 14, floori(e.z / stud) - 10)
	var t0 := Time.get_ticks_usec()
	var info: Dictionary = MineBuildings.stamp(self, corner, p)
	var stamp_ms := (Time.get_ticks_usec() - t0) / 1000.0
	_flush_edits()
	var base: int = info.base
	var lo: Vector3i = info.lo
	var hi: Vector3i = info.hi
	print("[mine-buildings] %d floors, 20 x 20 studs: %d bricks, %d cells (%d course cells kept as placed bricks), base plate %d (ground %d..), %.1f m tall; stamped in %.0f ms"
			% [floors, info.bricks, info.cells, info.placed, base, info.ground, (hi.y - base + 1) * plate, stamp_ms])
	var ok: bool = int(info.cells) > 1000
	check.call(ok, "the tower is in the ground (%d cells)" % int(info.cells))
	fails += 0 if ok else 1
	# It is ground now: the field says so.
	var mid_cell := Vector3i(lo.x, base + 6, lo.z + 10)
	ok = BrickTerrain.solid_at(mid_cell.x, mid_cell.y, mid_cell.z) != 0
	check.call(ok, "its wall is solid ground (BrickTerrain.solid_at)")
	fails += 0 if ok else 1
	var centre := Vector3((lo.x + 10) * stud, base * plate, (lo.z + 10) * stud)
	var height := (hi.y - base + 1) * plate
	var cam0 := get_viewport().get_camera_3d()
	var cam := Camera3D.new()
	add_child(cam)
	cam.attributes = cam0.attributes
	cam.near = 0.05
	cam.fov = cam0.fov
	cam.current = true
	var shoot_pic := func(tag: String, from: Vector3, at: Vector3) -> void:
		cam.global_transform = Transform3D(Basis(), to_global(from)).looking_at(to_global(at))
		_streamer.settle(Vector2(from.x, from.z))
		await _frames(30)
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(dev + "mine_building_%s.png" % tag)
	var look := centre + Vector3(0, height * 0.45, 0)
	await shoot_pic.call("near", centre + Vector3(-12.0, 1.8, -9.0), centre + Vector3(0, 3.0, 0))
	await shoot_pic.call("mid", centre + Vector3(-40.0, 6.0, -22.0), look)
	await shoot_pic.call("far", centre + Vector3(-110.0, 25.0, -60.0), look)
	# A shot at its west wall, 3 m up, from outside.
	cam.global_transform = Transform3D(Basis(), to_global(centre + Vector3(-12.0, 3.0, 0))).looking_at(
			to_global(Vector3(lo.x * stud, base * plate + 3.0, centre.z)))
	_streamer.settle(Vector2(centre.x - 12.0, centre.z))
	await _frames(20)
	var hid0: int = bricks.hidden_total if bricks != null else 0
	var wall_at := Vector3(lo.x * stud - 0.01, base * plate + 3.0, centre.z)
	_mine(to_global(wall_at), Vector3(1, 0, 0), null)
	ok = bricks != null and bricks.hidden_total == hid0 + 1
	check.call(ok, "a shot at its wall hides the brick the frame it is hit")
	fails += 0 if ok else 1
	await _frames(20)
	ok = BrickTerrain.solid_at(lo.x, roundi(3.0 / plate) + base, roundi(centre.z / stud)) == 0
	check.call(ok, "and the field has the hole")
	fails += 0 if ok else 1
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(dev + "mine_building_shot.png")
	# DIG out the ground under its west half: the foundation and the ground
	# under it, down past the lowest ground, so the west half hangs.
	var let0: int = collapse.groups_let_go
	var bricks0: int = collapse.bricks_let_go
	var g_lo := Vector3i(lo.x - 2, int(info.ground) - 12, lo.z - 2)
	# `--dig-all`: the whole footprint, so nothing but its own bricks hold it.
	var g_hi := Vector3i((hi.x + 2) if "--dig-all" in OS.get_cmdline_user_args() else (lo.x + 9), base - 1, hi.z + 2)
	terrain_edited(BrickTerrain.fill_box(g_lo, g_hi, 0, false))
	_flush_edits()
	cam.global_transform = Transform3D(Basis(), to_global(centre + Vector3(-34.0, 8.0, -26.0))).looking_at(
			to_global(centre + Vector3(0, height * 0.3, 0)))
	_streamer.settle(Vector2(centre.x - 34.0, centre.z - 26.0))
	await _frames(10)
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(dev + "mine_building_dug.png")
	for f in 360:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(dev + "mine_building_fallen.png")
	var let := collapse.groups_let_go - let0
	var fell := collapse.bricks_let_go - bricks0
	print("[mine-buildings] dug under %s: %d piece(s), %d brick(s) let go; %s" % ["all of it" if "--dig-all" in OS.get_cmdline_user_args()
			else "its west half", let, fell, collapse.readout()])
	ok = let > 0 and fell > 0
	check.call(ok, "cut loose, it falls (%d pieces, %d bricks)" % [let, fell])
	fails += 0 if ok else 1
	print("[mine-buildings] %s" % ["PASS" if fails == 0 else "%d FAILED" % fails])
	get_tree().quit()


## -- --gate=bricks: THE BRICK OVERLAY (Docs/BrickOverlay.md 4, stage 2). The
## stone room (_build_gate_room) roofed over, seen from inside (its corners,
## walls, floor and roof edges at the normal lens) and the open ground
## outside it, each view drawn with the overlay ON and OFF (pictures
## mine_bricks_<view>_on/off.png in user://dev). Counts: instances, bricks in
## reach, how far the overlay reached; the fill's cost over a full turn (24
## picks, one a frame). Checks: bricks are laid (inside and out), within
## max_bricks, every picked brick within range, a fill under 2 ms.
func _run_bricks_gate() -> void:
	await _frames(10)
	var dev := UserPaths.DEV
	DirAccess.make_dir_recursive_absolute(dev)
	_time = 0.42
	set_on_foot(false)
	view.process_mode = Node.PROCESS_MODE_DISABLED
	view.rig.visible = false
	if view.arms != null:
		view.arms.visible = false
	_hud_layer.visible = false
	if kit != null:
		for layer: CanvasLayer in [kit.hud, kit._aggro_layer]:
			if layer != null:
				layer.visible = false
	var fails := 0
	var check := func(passed: bool, what: String) -> void:
		print("[mine-bricks] %s  %s" % ["ok  " if passed else "FAIL", what])
	if bricks == null or not _overlay_on:
		print("[mine-bricks] FAIL  the overlay is off (Chamfered brick edges off)")
		get_tree().quit()
		return
	var stud := BrickWorld.get_stud_metres()
	var plate := BrickWorld.get_plate_metres()
	var site := _build_gate_room()
	var o: Vector2i = site[0]
	var b: int = site[1]
	var mid := Vector3((o.x + 7.5) * stud, (b + 9) * plate, (o.y + 0.5) * stud)
	_fly_to(Vector3(mid.x, b * plate + 0.05, mid.z), Vector3(0, 0, -1))
	await _frames(60)
	collapse.process_mode = Node.PROCESS_MODE_DISABLED
	terrain_edited(BrickTerrain.fill_box(Vector3i(o.x, b + 18, o.y - 9), Vector3i(o.x + 14, b + 20, o.y + 9), 4, true))
	_flush_edits()
	_streamer.settle(Vector2(mid.x, mid.z))
	await _frames(90)
	var cam0 := get_viewport().get_camera_3d()
	var shot_cam := Camera3D.new()
	add_child(shot_cam)
	shot_cam.attributes = cam0.attributes
	shot_cam.near = 0.02
	shot_cam.fov = cam0.fov
	shot_cam.current = true
	# Inside: two corners, a wall straight on, floor and roof edges.
	var views := []
	var c0 := Vector3((o.x + 1) * stud, (b + 3) * plate, (o.y - 8) * stud)
	var c1 := Vector3((o.x + 14) * stud, (b + 15) * plate, (o.y + 9) * stud)
	views.append(["room_corner", Transform3D(Basis(), mid.lerp(Vector3(c0.x, mid.y, c0.z), 0.4)).looking_at(c0)])
	views.append(["room_roof", Transform3D(Basis(), mid.lerp(Vector3(c1.x, mid.y, c1.z), 0.4)).looking_at(c1)])
	views.append(["room_wall", Transform3D(Basis(), mid).looking_at(mid + Vector3(0, -0.3, -4.0))])
	views.append(["room_floor", Transform3D(Basis(), mid + Vector3(0, 0.6, 0)).looking_at(
			Vector3(mid.x + 1.5, b * plate, mid.z + 1.0))])
	# Outside: the open ground beside the room, from a walker's height.
	var gx := o.x - 12
	var gz := o.y
	var gy := BrickTerrain.surface_plate(gx, gz)
	var eye_out := Vector3(gx * stud, (gy + 1) * plate + 1.7, gz * stud)
	views.append(["ground", Transform3D(Basis(), eye_out).looking_at(eye_out + Vector3(-3.0, -1.6, 1.0))])
	views.append(["ground_far", Transform3D(Basis(), eye_out).looking_at(eye_out + Vector3(-4.0, -0.4, -2.0))])
	# The dark room's own bricks, from each room view's pick: none lit by the
	# sky on a face inside it (the light is the bake's, of the faces it drew),
	# and no box reaching into its air.
	var rlo := Vector3((o.x + 1) * stud, b * plate, (o.y - 8) * stud)
	var rhi := Vector3((o.x + 14) * stud, (b + 18) * plate, (o.y + 9) * stud)
	var lit := 0
	var intrude := 0
	var scan := func(tag: String) -> Array:
		var n_lit := 0
		var n_in := 0
		var rb := bricks.buffer
		for i in bricks.count:
			var k := i * TerrainBricks.STRIDE
			var size := Vector3(rb[k], rb[k + 5], rb[k + 10])
			var c := Vector3(rb[k + 3], rb[k + 7], rb[k + 11])
			var blo := c - size * 0.5
			var bhi := c + size * 0.5
			var lv := []
			var any := false
			for f in 6:
				# The face's middle: on the room's inside (its box, edges in)?
				var fc := c
				var ax := f >> 1
				fc[ax] = bhi[ax] if f % 2 == 0 else blo[ax]
				var inside := fc.x > rlo.x - 0.01 and fc.x < rhi.x + 0.01 and fc.y > rlo.y - 0.01 \
						and fc.y < rhi.y + 0.01 and fc.z > rlo.z - 0.01 and fc.z < rhi.z + 0.01
				for corner in 4:
					var n := f * 4 + corner
					var l := (int(rb[k + 16 + int(n / 6.0)]) >> (4 * (n % 6))) & 15
					lv.append(l)
					if inside and l >= 6:
						any = true
			# Into the room's air (it is all air, 1 cm in from its faces)?
			if blo.x < rhi.x - 0.01 and bhi.x > rlo.x + 0.01 and blo.y < rhi.y - 0.01 and bhi.y > rlo.y + 0.01 \
					and blo.z < rhi.z - 0.01 and bhi.z > rlo.z + 0.01:
				n_in += 1
				if n_in <= 4:
					print("[mine-bricks]   %s: in the room's air: box %s..%s" % [tag, blo, bhi])
			if any:
				n_lit += 1
				if n_lit <= 6:
					print("[mine-bricks]   %s: lit in the room: box %s..%s faces' corners %s" % [tag, blo, bhi, lv])
		return [n_lit, n_in]
	var room_count := 0
	var out_count := 0
	for v: Array in views:
		var t: Transform3D = v[1]
		shot_cam.global_transform = t
		if str(v[0]) == "ground":
			_streamer.settle(Vector2(t.origin.x, t.origin.z))
		for on in [true, false]:
			bricks.set_enabled(on)
			await _frames(6)
			await RenderingServer.frame_post_draw
			get_viewport().get_texture().get_image().save_png(dev + "mine_bricks_%s_%s.png" % [v[0], "on" if on else "off"])
		bricks.set_enabled(true)
		await _frames(3)
		print("[mine-bricks] %-11s %s" % [v[0], bricks.readout()])
		if str(v[0]).begins_with("room"):
			room_count = maxi(room_count, bricks.count)
			var got: Array = scan.call(str(v[0]))
			lit += int(got[0])
			intrude += int(got[1])
		else:
			out_count = maxi(out_count, bricks.count)
	var ok: bool = lit == 0
	check.call(ok, "no sky light on the dark room's corners (%d bricks lit)" % lit)
	fails += 0 if ok else 1
	ok = intrude == 0
	check.call(ok, "no brick's box in the room's air (%d)" % intrude)
	fails += 0 if ok else 1
	ok = room_count > 50
	check.call(ok, "bricks laid in the room (%d)" % room_count)
	fails += 0 if ok else 1
	ok = out_count > 50
	check.call(ok, "bricks laid on the open ground (%d)" % out_count)
	fails += 0 if ok else 1
	# The turn: 24 picks, one a frame, from the room's middle.
	bricks.worst_fill_ms = 0.0
	var sum := 0.0
	var most := 0
	for i in 24:
		var yaw := TAU * i / 24.0
		shot_cam.global_transform = Transform3D(Basis(), mid).looking_at(mid + Vector3(sin(yaw), -0.2, cos(yaw)))
		await get_tree().process_frame
		sum += bricks.fill_ms
		most = maxi(most, bricks.count)
	print("[mine-bricks] turn: fill %.2f ms mean, %.2f worst; up to %d instances" % [sum / 24.0, bricks.worst_fill_ms, most])
	ok = bricks.worst_fill_ms < 2.0
	check.call(ok, "a fill under 2 ms (worst %.2f)" % bricks.worst_fill_ms)
	fails += 0 if ok else 1
	ok = most <= bricks.max_bricks
	check.call(ok, "within max_bricks (%d <= %d)" % [most, bricks.max_bricks])
	fails += 0 if ok else 1
	# Every instance within range of the eye (its box), from the buffer this
	# script wrote: the transform's origin and scale.
	var buf: PackedFloat32Array = bricks.buffer
	var e := to_local(shot_cam.global_position)
	var worst_d := 0.0
	for i in bricks.count:
		var k := i * TerrainBricks.STRIDE
		var size := Vector3(buf[k], buf[k + 5], buf[k + 10])
		var c := Vector3(buf[k + 3], buf[k + 7], buf[k + 11])
		var q := e.clamp(c - size * 0.5, c + size * 0.5)
		worst_d = maxf(worst_d, q.distance_to(e))
	ok = worst_d <= bricks.range_m + 0.01
	check.call(ok, "every brick within range (farthest %.2f m of %.1f)" % [worst_d, bricks.range_m])
	fails += 0 if ok else 1
	# A shot (stage 6): the brick goes the frame it is hit, its hole drawn by
	# the overlay till the rebuilt tile is; pictures the next frame and once
	# the hole is the ground's own (mine_bricks_shot_now / _later).
	shot_cam.global_transform = views[4][1]
	_streamer.settle(Vector2(shot_cam.global_position.x, shot_cam.global_position.z))
	await _frames(20)
	var aim := to_local(shot_cam.global_position) + (-shot_cam.global_transform.basis.z) * 2.5
	var sc := Vector2i(floori(aim.x / stud), floori(aim.z / stud))
	var shot_at := Vector3((sc.x + 0.5) * stud, _ground_m(sc.x, sc.y) - 0.02, (sc.y + 0.5) * stud)
	var hid0 := bricks.hidden_total
	_mine(to_global(shot_at), Vector3.DOWN, null)
	ok = bricks.hidden_total == hid0 + 1
	check.call(ok, "a shot brick is hidden the frame it is hit (%d)" % (bricks.hidden_total - hid0))
	fails += 0 if ok else 1
	# The next frame drawn (the picture of this one is not yet the change's).
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(dev + "mine_bricks_shot_now.png")
	print("[mine-bricks] shot: %d hole(s) still the overlay's in that frame" % bricks.holes.size())
	var waited := 0
	while not bricks.holes.is_empty() and waited < 300:
		await get_tree().process_frame
		waited += 1
	ok = bricks.holes.is_empty()
	check.call(ok, "its hole handed to the rebuilt tile (%d frames)" % waited)
	fails += 0 if ok else 1
	await _frames(4)
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(dev + "mine_bricks_shot_later.png")
	# A FAR shot, past the laid bricks (~20 m): found in the tiles' own lists,
	# hidden at once the same way (TerrainBricks._hide_far).
	var far_at := to_local(cam.global_position) + Vector3(-cam.global_transform.basis.z.x, 0.0,
			-cam.global_transform.basis.z.z).normalized() * 20.0
	var fc := Vector2i(floori(far_at.x / stud), floori(far_at.z / stud))
	var far_shot := Vector3((fc.x + 0.5) * stud, _ground_m(fc.x, fc.y) - 0.02, (fc.y + 0.5) * stud)
	var far0 := bricks.far_hidden
	_mine(to_global(far_shot), Vector3.DOWN, null)
	ok = bricks.far_hidden == far0 + 1
	check.call(ok, "a far brick (%.0f m) is hidden the frame it is hit" % to_local(cam.global_position).distance_to(far_shot))
	fails += 0 if ok else 1
	waited = 0
	while not bricks.holes.is_empty() and waited < 300:
		await get_tree().process_frame
		waited += 1
	ok = bricks.holes.is_empty()
	check.call(ok, "its hole handed to the rebuilt tile (%d frames)" % waited)
	fails += 0 if ok else 1
	print("[mine-bricks] %s; %s" % ["PASS" if fails == 0 else "%d FAILED" % fails, bricks.readout()])
	get_tree().quit()


## -- --gate=seams: does the near tier's chamfer open the walls of a room?
## The stone room roofed over, an unlit MAGENTA box round its outside, and
## close views of its walls, inside corners, floor and roof edges through a
## narrow lens: any magenta pixel is a slit through a wall (the bright dotted
## lines up a dark room's wall seams, MineWorld.md 19). Counted with the
## geometry chamfer off and on; on must add none.
func _run_seams_gate() -> void:
	if "--deep" in OS.get_cmdline_user_args():
		await _run_seams_deep()
		return
	await _frames(10)
	var dev := UserPaths.DEV
	DirAccess.make_dir_recursive_absolute(dev)
	_time = 0.42
	set_on_foot(false)
	view.process_mode = Node.PROCESS_MODE_DISABLED
	view.rig.visible = false
	if view.arms != null:
		view.arms.visible = false
	_hud_layer.visible = false
	if kit != null:
		for layer: CanvasLayer in [kit.hud, kit._aggro_layer]:
			if layer != null:
				layer.visible = false
	var stud := BrickWorld.get_stud_metres()
	var plate := BrickWorld.get_plate_metres()
	var site := _build_gate_room()
	var o: Vector2i = site[0]
	var b: int = site[1]
	var t_min: int = site[2]
	var mid := Vector3((o.x + 7.5) * stud, (b + 9) * plate, (o.y + 0.5) * stud)
	_fly_to(Vector3(mid.x, b * plate + 0.05, mid.z), Vector3(0, 0, -1))
	await _frames(60)
	collapse.process_mode = Node.PROCESS_MODE_DISABLED
	terrain_edited(BrickTerrain.fill_box(Vector3i(o.x, b + 18, o.y - 9), Vector3i(o.x + 14, b + 20, o.y + 9), 4, true))
	_flush_edits()
	# The magenta box, half a stud outside the shell all round.
	var lo := Vector3(o.x * stud - stud * 0.5, mini(t_min, b - 3) * plate - 0.2, (o.y - 9) * stud - stud * 0.5)
	var hi := Vector3((o.x + 15) * stud + stud * 0.5, (b + 21) * plate + 0.2, (o.y + 10) * stud + stud * 0.5)
	var box := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = hi - lo
	box.mesh = bm
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1, 0, 1)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	box.material_override = mat
	box.position = (lo + hi) * 0.5
	add_child(box)
	# The tunnel runs out through the box: a black card across it, just inside
	# the shell's outer face, so looking down the tunnel is not a hole.
	var card := MeshInstance3D.new()
	var cm := BoxMesh.new()
	cm.size = Vector3(0.01, 3.0 * plate + 0.1, stud + 0.1)
	card.mesh = cm
	var black := StandardMaterial3D.new()
	black.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	black.albedo_color = Color.BLACK
	card.material_override = black
	card.position = Vector3((o.x + 15.0) * stud, (b + 1.5) * plate, (o.y + 0.5) * stud)
	add_child(card)
	# Views from inside: the four inside corners at three heights, each wall
	# straight on, the floor's and roof's edges; 14 degrees, like a scope.
	var views := []
	var corners := [Vector3(o.x + 1, 0, o.y - 8), Vector3(o.x + 14, 0, o.y - 8),
			Vector3(o.x + 14, 0, o.y + 9), Vector3(o.x + 1, 0, o.y + 9)]
	for k in corners.size():
		var cxz: Vector3 = corners[k] * stud
		for h in [b + 2, b + 9, b + 16]:
			var at := Vector3(cxz.x, h * plate, cxz.z)
			var from := mid.lerp(Vector3(at.x, mid.y, at.z), 0.55)
			views.append(Transform3D(Basis(), from).looking_at(at))
	for a in 8:
		var yaw := TAU * a / 8.0
		var dir := Vector3(sin(yaw), 0, cos(yaw))
		for tilt in [-0.5, 0.0, 0.5]:
			views.append(Transform3D(Basis(), mid).looking_at(mid + dir * 4.0 + Vector3(0, tilt * 4.0, 0)))
	# Its own camera: the walker's is posed from the walker every frame.
	var cam0 := get_viewport().get_camera_3d()
	var shot_cam := Camera3D.new()
	add_child(shot_cam)
	shot_cam.attributes = cam0.attributes
	shot_cam.near = 0.02
	shot_cam.current = true
	var fov0 := shot_cam.fov
	var count := func(tag: String) -> Array:
		shot_cam.fov = 14.0
		var total := 0
		var worst := 0
		var lines := 0
		for i in views.size():
			shot_cam.global_transform = views[i]
			await _frames(4)
			await RenderingServer.frame_post_draw
			var img := get_viewport().get_texture().get_image()
			var n := 0
			for y in img.get_height():
				for x in img.get_width():
					var c := img.get_pixel(x, y)
					if c.r > 0.45 and c.b > 0.45 and c.g < 0.6 * minf(c.r, c.b):
						n += 1
			total += n
			lines += 1 if n > 0 else 0
			if i % 9 == 0:
				img.save_png(dev + "mine_seams_%s_view%d.png" % [tag, i])
			if n > worst:
				worst = n
				img.save_png(dev + "mine_seams_%s.png" % tag)
		print("[mine-seams] %-3s magenta %d px over %d views (%d views with any, worst %d)" % [tag, total, views.size(), lines, worst])
		shot_cam.fov = fov0
		return [total, lines]
	var settle := func() -> void:
		_streamer.invalidate(Rect2i(-(1 << 20), -(1 << 20), 1 << 21, 1 << 21))
		_streamer.settle(Vector2(mid.x, mid.z))
		await _frames(90)
	# The chamfer is the brick overlay's real bricks over the sunken flat
	# ground (Docs/BrickOverlay.md): off, then on.
	if _overlay_on:
		bricks.set_enabled(false)
	await settle.call()
	var off: Array = await count.call("off")
	if _overlay_on:
		bricks.set_enabled(true)
	await settle.call()
	var on: Array = await count.call("on")
	# Both tiers whole: the chamfer's slits and the flat tier's T-junction
	# cracks were both seen as dots in a dark cave.
	var ok: bool = on[0] == 0 and off[0] == 0
	print("[mine-seams] %s  %s on %d px, off %d px" % ["PASS" if ok else "FAIL",
			"overlay" if _overlay_on else "chamfer", on[0], off[0]])
	get_tree().quit()


## THE FACES BEHIND THE OVERLAY'S BRICKS, only round the eye
## (Docs/BrickOverlay.md 6b): the bake makes them for tiles within 2 of the
## eye's tile (and sections within 128 plates of it); here, as the eye moves,
## a tile or section that came into that ring without them is baked again,
## and one 2 tiles (or 64 plates) past it drops them. Every tile and section
## carrying them was ~200 MB more and the machine paged.
var _behind_at := Vector3i(1 << 30, 0, 0)

func _behind_follow(eye: Vector3) -> void:
	if not BrickTerrain.get_behind_faces():
		return
	var stud := BrickWorld.get_stud_metres()
	var span := BrickTerrain.get_tile_studs() * stud
	var c := Vector3i(floori(eye.x / span), floori(eye.y / BrickWorld.get_plate_metres()), floori(eye.z / span))
	BrickTerrain.set_behind_centre(c)
	if c.x == _behind_at.x and c.z == _behind_at.z and absi(c.y - _behind_at.y) < 32:
		return
	_behind_at = c
	for k in _streamer._tiles:
		var tile: TerrainTile = _streamer._tiles[k]
		if tile == null:
			continue
		if BrickTerrain.behind_wanted(k.x, -2147483648, k.y):
			if not tile.behind_baked:
				_streamer.refresh(Rect2i(k, Vector2i.ONE))
		elif tile.behind_baked and maxi(absi(k.x - c.x), absi(k.y - c.z)) > 3:
			tile.drop_behind()
	var sp := BrickTerrain.get_deep_section_plates()
	for k in _deep._secs:
		var sec: TerrainTile = _deep._secs[k]
		if sec == null:
			continue
		if BrickTerrain.behind_wanted(k.x, k.y, k.z):
			if not sec.behind_baked:
				_deep.rebake(k)
		elif sec.behind_baked and (maxi(absi(k.x - c.x), absi(k.z - c.z)) > 3
				or k.y * sp > c.y + 192 or (k.y + 1) * sp < c.y - 192):
			sec.drop_behind()


## -- --gate=slits: see-through slits in the OPEN ground near the eye (the
## user, 2026-11-24: "see through seams at the grid", gone with the chamfer
## off). The sky is a flat MAGENTA; scoped views look down across tile edges
## and corners from 2-10 m, so every pixel is ground: a magenta one is a slit.
## Counted three ways: the overlay off (flat ground, nothing sunk), the
## overlay's recess with its bricks hidden (what is open where no brick is
## laid: behind the eye, past the view), and the overlay whole. Fixed by
## the recess along the eye's ray (terrain.gdshader): 39359 px whole and
## 600288 px with its bricks hidden before, as the flat ground (~46) after.
func _run_slits_gate() -> void:
	await _frames(10)
	var dev := UserPaths.DEV
	DirAccess.make_dir_recursive_absolute(dev)
	_time = 0.42
	set_on_foot(false)
	view.process_mode = Node.PROCESS_MODE_DISABLED
	view.rig.visible = false
	if view.arms != null:
		view.arms.visible = false
	_hud_layer.visible = false
	if kit != null:
		for layer: CanvasLayer in [kit.hud, kit._aggro_layer]:
			if layer != null:
				layer.visible = false
	collapse.process_mode = Node.PROCESS_MODE_DISABLED
	var env: Environment = _rig.env
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(1, 0, 1)
	env.fog_enabled = false
	env.volumetric_fog_enabled = false
	var stud := BrickWorld.get_stud_metres()
	var ts := BrickTerrain.get_tile_studs()
	var e := _eye()
	var t := Vector2i(floori(e.x / (ts * stud)), floori(e.z / (ts * stud)))
	# The edges and corner of the eye's tile: points on the ground there.
	var marks: Array[Vector2i] = []
	for k in 4:
		marks.append(Vector2i((t.x + 1) * ts, t.y * ts + 4 + k * 8))   # +x edge
		marks.append(Vector2i(t.x * ts + 4 + k * 8, (t.y + 1) * ts))   # +z edge
	marks.append(Vector2i((t.x + 1) * ts, (t.y + 1) * ts))             # corner
	var views := []
	for m in marks:
		var at := Vector3(m.x * stud, _ground_m(m.x, m.y), m.y * stud)
		for a in 6:
			var yaw := TAU * (a + 0.5) / 6.0
			for d in [2.0, 5.0, 9.0]:
				var from := at + Vector3(sin(yaw) * d, 1.7 + d * 0.25, cos(yaw) * d)
				views.append(Transform3D(Basis(), from).looking_at(at))
	var centre := Vector3((t.x + 1) * ts * stud, e.y, (t.y + 1) * ts * stud)
	_fly_to(centre + Vector3(0, 3, 0), Vector3(0, 0, -1))
	_streamer.settle(Vector2(centre.x, centre.z))
	await _frames(90)
	var cam0 := get_viewport().get_camera_3d()
	var shot_cam := Camera3D.new()
	add_child(shot_cam)
	shot_cam.attributes = cam0.attributes
	shot_cam.near = 0.02
	shot_cam.fov = 20.0
	shot_cam.current = true
	var count := func(tag: String) -> int:
		var total := 0
		var hit := 0
		var worst := 0
		for i in views.size():
			shot_cam.global_transform = to_global_t(views[i])
			await _frames(4)
			await RenderingServer.frame_post_draw
			var img := get_viewport().get_texture().get_image()
			var n := 0
			for y in img.get_height():
				for x in img.get_width():
					var c := img.get_pixel(x, y)
					if c.r > 0.45 and c.b > 0.45 and c.g < 0.6 * minf(c.r, c.b):
						n += 1
			total += n
			hit += 1 if n > 0 else 0
			if n > worst:
				worst = n
				img.save_png(dev + "mine_slits_%s.png" % tag)
		print("[mine-slits] %-8s magenta %d px over %d views (%d views with any, worst %d)" % [tag, total, views.size(), hit, worst])
		return total
	var on_ := _overlay_on
	if on_:
		bricks.set_enabled(false)
	await _frames(30)
	var off: int = await count.call("off")
	var recess := -1
	var whole := -1
	if on_:
		bricks.set_enabled(true)
		await _frames(30)
		whole = await count.call("whole")
		bricks._mmi.visible = false
		await _frames(10)
		recess = await count.call("recess")
		bricks._mmi.visible = true
	# The flat ground alone keeps a few 1-3 px pinholes (T-junctions, ~50 over
	# the 162 views, too small to see); the overlay must add none: whole, or
	# sunk with its bricks hidden, within a few pixels of it.
	var ok := whole <= off + 10 and recess <= off + 10
	print("[mine-slits] %s  off %d px, overlay whole %d px, recess with no bricks %d px" % [
			"PASS" if ok else "FAIL", off, whole, recess])
	get_tree().quit()


func to_global_t(t: Transform3D) -> Transform3D:
	return global_transform * t


## -- --gate=seams --deep: the same count in a hall cut deep underground,
## drawn by the DEEP sections (unchamfered, MineWorld.md 16), seen from
## across it: 13 x 41 studs inside, 6 courses tall, 60 plates under the
## lowest ground, a 1-stud shaft up to the sky from its roof's middle (a
## sealed chamber is not drawn). An unlit magenta box half a stud outside its
## shell (a black card across the shaft); 36 scoped views from each end at
## its far corners, wall feet, roof edges. The user's dashed line along a
## cave's wall foot, seen from a distance, would show here.
func _run_seams_deep() -> void:
	await _frames(10)
	var dev := UserPaths.DEV
	DirAccess.make_dir_recursive_absolute(dev)
	_time = 0.42
	set_on_foot(false)
	view.process_mode = Node.PROCESS_MODE_DISABLED
	view.rig.visible = false
	if view.arms != null:
		view.arms.visible = false
	_hud_layer.visible = false
	if kit != null:
		for layer: CanvasLayer in [kit.hud, kit._aggro_layer]:
			if layer != null:
				layer.visible = false
	collapse.process_mode = Node.PROCESS_MODE_DISABLED
	var stud := BrickWorld.get_stud_metres()
	var plate := BrickWorld.get_plate_metres()
	var e := _eye()
	var o := Vector2i(floori(e.x / stud) + 4, floori(e.z / stud) - 20)
	var t_min := 1 << 30
	var t_max := -(1 << 30)
	for dz in range(-2, 44):
		for dx in range(-2, 17):
			t_min = mini(t_min, BrickTerrain.surface_plate(o.x + dx, o.y + dz))
			t_max = maxi(t_max, BrickTerrain.surface_plate(o.x + dx, o.y + dz))
	var b := (floori(float(t_min - 60) / 3.0)) * 3
	# --at-top: across the plate where the surface tiles stop and the deep
	# sections start (BrickTerrain.deep_top), 9 plates up the walls.
	var tile := BrickTerrain.get_tile_studs()
	var dtop := BrickTerrain.deep_top(floori(float(o.x + 6) / tile), floori(float(o.y + 20) / tile))
	if "--at-top" in OS.get_cmdline_user_args():
		b = floori(float(dtop - 9) / 3.0) * 3
	print("[mine-seams] deep_top %d, ground %d..%d, hall floor %d" % [dtop, t_min, t_max, b])
	if "--flat" in OS.get_cmdline_user_args() and bricks != null:
		bricks.set_enabled(false)
	terrain_edited(BrickTerrain.fill_box(Vector3i(o.x - 1, b - 3, o.y - 1), Vector3i(o.x + 14, b + 20, o.y + 42), 4, true))
	terrain_edited(BrickTerrain.fill_box(Vector3i(o.x, b, o.y), Vector3i(o.x + 13, b + 17, o.y + 41), 0, false))
	terrain_edited(BrickTerrain.fill_box(Vector3i(o.x + 6, b + 18, o.y + 20), Vector3i(o.x + 6, t_max + 6, o.y + 20), 0, false))
	_flush_edits()
	var near_end := Vector3((o.x + 6.5) * stud, b * plate + 0.05, (o.y + 1.5) * stud)
	_fly_to(near_end, Vector3(0, 0, 1))
	for f in 900:
		await get_tree().process_frame
		if f > 120 and _deep.active and _deep._tasks.is_empty() and _deep._dirty.is_empty() 				and _deep._swaps.is_empty():
			break
	await _frames(30)
	var lo := Vector3((o.x - 1) * stud - stud * 0.5, (b - 3) * plate - 0.2, (o.y - 1) * stud - stud * 0.5)
	var hi := Vector3((o.x + 15) * stud + stud * 0.5, (b + 21) * plate + 0.2, (o.y + 43) * stud + stud * 0.5)
	var box := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = hi - lo
	box.mesh = bm
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1, 0, 1)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	box.material_override = mat
	box.position = (lo + hi) * 0.5
	add_child(box)
	var card := MeshInstance3D.new()
	var cm := BoxMesh.new()
	cm.size = Vector3(stud + 0.1, 0.01, stud + 0.1)
	card.mesh = cm
	var black := StandardMaterial3D.new()
	black.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	black.albedo_color = Color.BLACK
	card.material_override = black
	card.position = Vector3((o.x + 6.5) * stud, (b + 21) * plate + 0.1, (o.y + 20.5) * stud)
	add_child(card)
	var views := []
	for end in [0, 1]:
		var ez := o.y + 1.5 if end == 0 else o.y + 39.5
		var fz := o.y + 41 if end == 0 else o.y
		var from := Vector3((o.x + 6.5) * stud, (b + 9) * plate, ez * stud)
		for tx in [o.x, o.x + 14]:
			for h in [b, b + 9, b + 18]:
				views.append(Transform3D(Basis(), from).looking_at(Vector3(tx * stud, h * plate, fz * stud)))
		for tz in [0.3, 0.6]:
			var zz: float = lerpf(ez, fz, tz)
			for tx in [o.x, o.x + 14]:
				for h in [b, b + 18]:
					views.append(Transform3D(Basis(), from).looking_at(Vector3(tx * stud, h * plate, zz * stud)))
		views.append(Transform3D(Basis(), from).looking_at(Vector3((o.x + 7) * stud, b * plate, fz * stud)))
		views.append(Transform3D(Basis(), from).looking_at(Vector3((o.x + 7) * stud, (b + 18) * plate, fz * stud)))
	var cam0 := get_viewport().get_camera_3d()
	var shot_cam := Camera3D.new()
	add_child(shot_cam)
	shot_cam.attributes = cam0.attributes
	shot_cam.near = 0.02
	shot_cam.fov = 10.0
	shot_cam.current = true
	var total := 0
	var hit := 0
	var worst := 0
	for i in views.size():
		shot_cam.global_transform = views[i]
		await _frames(4)
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		var n := 0
		for y in img.get_height():
			for x in img.get_width():
				var c := img.get_pixel(x, y)
				if c.r > 0.45 and c.b > 0.45 and c.g < 0.6 * minf(c.r, c.b):
					n += 1
		total += n
		hit += 1 if n > 0 else 0
		if n > 0:
			img.save_png(dev + "mine_seams_deep_hit%d.png" % i)
			print("[mine-seams] view %d: %d px, from %s to %s" % [i, n, views[i].origin, views[i].origin - views[i].basis.z])
		if n > worst:
			worst = n
			img.save_png(dev + "mine_seams_deep.png")
	print("[mine-seams] deep hall: %d sections drawn, floor plate %d (%d under the ground), overlay %s" % [_deep._secs.size(), b, t_min - b,
			bricks.readout() if _overlay_on else "off"])
	print("[mine-seams] %s  deep: magenta %d px over %d views (%d views with any, worst %d)"
			% ["PASS" if total == 0 else "FAIL", total, views.size(), hit, worst])
	get_tree().quit()


## The viewport's mean brightness over `r` (fractions of the picture).
func _mean_luma_in(r: Rect2) -> float:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.resize(64, 36)
	var s := 0.0
	var n := 0
	for y in range(int(r.position.y * 36), int(r.end.y * 36)):
		for x in range(int(r.position.x * 64), int(r.end.x * 64)):
			s += img.get_pixel(x, y).get_luminance()
			n += 1
	return s / maxf(n, 1)


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
