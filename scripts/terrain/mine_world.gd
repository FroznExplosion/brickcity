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
##       B build mode (mine_builder.gd: break, place, pick, hotbar)
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
		elif "--gate=menu" in OS.get_cmdline_user_args():
			_run_menu_gate()
		elif "--gate=look" in OS.get_cmdline_user_args():
			_run_look_gate()
		elif "--gate=cave" in OS.get_cmdline_user_args():
			_run_cave_gate()
		elif "--gate=collapse" in OS.get_cmdline_user_args():
			_run_collapse_gate()
		elif "--gate=flight" in OS.get_cmdline_user_args():
			_run_flight_gate()
		else:
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
	collapse.reset()
	BrickTerrain.clear_terrain_edits()
	BrickTerrain.configure(int(settings.seed))
	BrickTerrain.set_generator(1)
	BrickTerrain.reset_gen_params()
	BrickTerrain.set_gen_params(settings.gen)
	# Before anything bakes: the tiles are made from the field WITH them.
	var loaded := _load_edits()
	_load_pieces()
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
	_gen_ms = float(Time.get_ticks_usec() - t0) / 1000.0
	print("[mine] generated '%s' seed %d in %.0f ms; spawn %s (%s)" % [settings.name,
			int(settings.seed), _gen_ms, cell, _biome_names[BrickTerrain.biome_at(cell.x, cell.y)]])


func _teardown() -> void:
	fast_hold = false
	_speed = 0.0
	_speed_from = Vector3.INF
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
	if collapse != null and collapse.shoot(point, dir, _info):
		return
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

## FAST FLIGHT HOLD (Docs/MineWorld.md 14), after zylanntest's
## DynamicLodController: above FAST_HOLD_MPS the near tier starts no new
## bakes (nor studs, chamfer, collision) and the far tier no new refines or
## relods; what is drawn stays. Below FAST_RESUME_MPS it all resumes. Flying
## at the default 50 m/s is not held; Shift (500 m/s) is. -- --no-fast-hold
## turns it off (A/B).
const FAST_HOLD_MPS := 80.0
const FAST_RESUME_MPS := 40.0
var fast_hold := false
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
		_far.hold = hold
		if _far_next != null:
			_far_next.hold = hold


func _process(delta: float) -> void:
	_frame_ms = lerpf(_frame_ms, delta * 1000.0, 0.1)
	if _streamer == null:
		return
	var eye := _eye()
	_speed_step(eye, delta)
	_land_breaks()
	_refresh_in -= delta
	if _refresh_in <= 0.0:
		_flush_edits()
	var p0 := Time.get_ticks_usec()
	_streamer.follow(Vector2(eye.x, eye.z))
	var p1 := Time.get_ticks_usec()
	_far.cover(_streamer, false)
	_far.relod(eye, false)
	var p2 := Time.get_ticks_usec()
	var re0 := _reanchors
	_follow_far(eye)
	var p3 := Time.get_ticks_usec()
	_ptimes = {"near": (p1 - p0) / 1000.0, "far": (p2 - p1) / 1000.0,
			"reanchor": (p3 - p2) / 1000.0, "swapped": _reanchors != re0}
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
	_rig.env.ambient_light_energy *= cave
	# The ground casts no sun shadow, so the sun would reach into caves: it
	# fades with depth the way the ambient does.
	_rig.sun.light_energy *= cave
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


# ---------------------------------------------------------------------------
# The pause menu (Escape): the game's own (menu/core/MenuManager.gd), allowed
# here through terrain_scene.gd and BrickcityMenuHost's scene hooks.

## The menu gate turns this on to open the pause menu the player's way.
var _gate_pause_ok := false


func pause_allowed() -> bool:
	return (not _gate or _gate_pause_ok) and _menu == null


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


## The pieces that came off the ground, beside the edits (Docs/TerrainCollapse.md 5).
const PIECES_MAGIC := "BCMP"
const PIECES_FORMAT := 1


static func _pieces_path(edits_path: String) -> String:
	return edits_path.get_basename() + ".pieces"


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
	var piece_bytes := var_to_bytes(collapse.to_save())
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
		"far   %d blocks, %d hidden, %.0fk tris, anchor %s, re-centred %d (%.0f ms)" % [
				_far.block_count(), _far.hidden_count(), _far.triangle_count() / 1000.0,
				_far.anchor, _reanchors, _last_reanchor_ms],
		"trees %d   edits %d   generated in %.0f ms" % [_trees.count if _trees != null else 0,
				BrickTerrain.get_edit_count(), _gen_ms],
		"blocks placed %d  broken %d   %s" % [builder.placed, builder.broken, _save_status],
		"water %s" % water.report(),
		collapse.readout(),
		"%s   F fly/walk  B build  M world generation  F3 readout  T +1 hour" % ("ON FOOT" if on_foot
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
	walker.place(Vector3(e.x, _ground_m(c.x, c.y) + 1.6, e.z), Vector3(1, 0, -1).normalized())
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
	await _gate_cave()
	await _gate_edits()
	print("[mine-gate] done")
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
	walker.place(Vector3((o.x + 6) * stud, (b + 12) * plate + 1.0, (o.y - 22) * stud), Vector3(0, 0, 1))
	walker.pitch = -0.1
	await _frames(60)
	await _collapse_quiet(240)
	var arm_cell := Vector3i(o.x + 11, b + 20, o.y)
	var stands := BrickTerrain.solid_at(arm_cell.x, arm_cell.y, arm_cell.z) == 4
	print("[mine-collapse] %s  the stone arm stands on its pillar" % ("ok  " if stands else "FAIL"))
	fails += 0 if stands else 1
	# A floating dirt block and a floating sand block beside it.
	var d0 := Vector3i(o.x + 4, b + 30, o.y + 6)
	put.call(d0, d0 + Vector3i(1, 2, 1), 2)
	var s0 := Vector3i(o.x + 8, b + 30, o.y + 6)
	put.call(s0, s0 + Vector3i(1, 8, 1), 3)
	await _frames(4)
	_shot(dev + "mine_collapse_0_built.png")
	var clock := FrameClock.new()
	add_child(clock)
	clock.spoil()
	var made0 := int(collapse.groups_let_go)
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
	# Fly off past the detail tiles: the pieces are unloaded; back: laid again.
	var kept := collapse.pieces.pieces.size()
	var home := walker.global_position
	walker.place(home + Vector3(260.0, 40.0, 0.0), Vector3(1, 0, 0))
	await _frames(180)
	collapse._tend()
	ok = collapse.dormant_count() == kept and collapse.pieces.pieces.is_empty()
	print("[mine-collapse] %s  flown off: %d piece(s) unloaded, %d laid" % ["ok  " if ok else "FAIL", collapse.dormant_count(), collapse.pieces.pieces.size()])
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
	_shot(dev + "mine_collapse_4_reloaded.png")
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
	walker.place(found + Vector3(0, 0.4, 0), Vector3(1, 0, 0))
	walker.pitch = -0.3
	await _frames(90)
	set_on_foot(true)
	var t0 := pawn.feet()
	var low := t0.y
	for f in 200:
		await get_tree().physics_frame
		low = minf(low, pawn.feet().y)
	var t1 := pawn.feet()
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

	# Lava (stage 6): a walled pool on the east side, at night for its glow
	# and its lights; a pawn in it burns; cut off, it cools into stone.
	lay.call(19, 5, 29, 5, w, w, dark)
	lay.call(19, 13, 29, 13, w, w, dark)
	lay.call(19, 5, 19, 13, w, w, dark)
	lay.call(29, 5, 29, 13, w, w, dark)
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
	print("[water-gate] lava pool: %d lava lights, %s" % [water.lava_lights(), water.report()])
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
	walker.place(from, Vector3(dir.x, 0, dir.y))
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
		walker.place(rm + Vector3(-14, 10, -14), Vector3(1, 0, 1).normalized())
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
	walker.place(chm + Vector3(side.x, 0, side.y) * 4.0 + Vector3(0, 4, 0), -Vector3(side.x, 0, side.y))
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
	var fc := BrickFluid.cell_of(pawn.feet() + Vector3.UP * 0.05)
	print("[sea-gate] swimmer put at %s, feet %s (ground %.1f m), cell %s %s, surface %.2f, probe set %s" % [
			deep, pawn.feet(), _ground_m(fc.x, fc.z), fc, BrickFluid.cell_info(fc),
			water.surface_at(pawn.feet() + Vector3.UP * 0.05), Pawn.water_probe.is_valid()])
	await _shot(dev + "sea_underwater.png")
	await _frames(150)
	var top: float = water.surface_at(pawn.feet() + Vector3.UP * 0.05)
	print("[sea-gate] swim: under water at first %s, swimming %s, eye %.2f m over the surface after 3 s (want about +0.1)" % [
			under, pawn.moves != null and pawn.moves.swimming, _eye().y - top])
	# A bucket: filled from the sea, poured on dry land.
	set_on_foot(false)
	walker.place(cm - Vector3(dir.x, 0, dir.y) * 2.0 + Vector3(0, 2.2, 0), Vector3(dir.x, 0, dir.y))
	walker.pitch = -0.8
	await _frames(10)
	builder.set_active(true)
	builder.slot = builder.hotbar.find(builder.BUCKET)
	var filled: bool = builder.take_fluid()
	var held: int = builder.bucket
	var land := shore - Vector2i((dir * 10.0).round())
	walker.place(Vector3((land.x + 0.5) * stud, _ground_m(land.x, land.y) + 2.0, (land.y + 0.5) * stud),
			-Vector3(dir.x, 0, dir.y))
	walker.pitch = -1.45
	await _frames(10)
	builder.update_target()
	print("[sea-gate] pour target %s" % builder.target)
	var poured: bool = builder.place_target()
	water.step(1)
	print("[sea-gate] bucket: filled from the sea %s (%d tiles), poured %s (%d left), %s" % [
			filled, held, poured, builder.bucket, builder.log_blocks.slice(-3)])
	builder.set_active(false)
	view.process_mode = Node.PROCESS_MODE_INHERIT
	_hud_layer.visible = true
	print("[sea-gate] done")
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
