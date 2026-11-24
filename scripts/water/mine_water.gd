extends Node3D

## WATER AND LAVA in the mine world (Docs/MineWater.md): drives BrickFluid and
## draws what it builds.
##
## - Every frame: tells BrickFluid where the player is (the sim ring) and lets
##   it start a tick on its thread when one is due (`update`, never a wait).
## - A finished tick's meshes are swapped into one MeshInstance3D per terrain
##   tile, recycled, never made per rebuild (7.1).
## - Lava meeting water hands back cells of rock: they are laid as terrain
##   edits here, through the host's `terrain_edited` like any block.
## - The host calls `terrain_changed` with every edit's result, so water reads
##   its ground again where a block was placed or a shot dug (4.3).
## - The generated sea (stage 3, 7.2) is drawn by WaterSea's wave tiers, the
##   heightfield test's: its shore field is computed round the player on a
##   worker and swapped in when they have moved on; where BrickFluid says the
##   sea was changed (walled off, emptied) the tiers do not draw it.
## - The player's side (stage 4, section 10): `surface_at` / `flow_at` for
##   swimming (Pawn.water_probe), the underwater look, lava burning.
##
## Preloaded by path, not named (see terrain_scene.gd).

const WaterSeaFx := preload("res://scripts/water/water_sea.gd")
const FloatersFx := preload("res://scripts/water/floaters.gd")
const LavaFireFx := preload("res://scripts/water/lava_fire.gd")
## The water meshes carry CUSTOM0 (how far each vertex moved since its tile's
## last mesh) as four floats: the shader eases them (water_fluid.gdshader).
const MESH_FLAGS := Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT

const TILE_STUDS := 32
## The shore field: 3072 studs each way (1.08 km, past the sheet's 1 km),
## a sample every 8 studs; computed again when the player is 768 studs from
## its centre, or a while after the ground under the sea line changed.
const FIELD_HALF := 3072
const FIELD_STEP := 8
const FIELD_MOVE := 768
const FIELD_EDIT_DELAY := 1.5
const SEA_OUTER_M := 1000.0
## Lava on a pawn, health a second (Docs/MineWater.md 10).
const LAVA_DPS := 40.0
## Moving through lava is this much of moving through water (4.6).
const LAVA_DRAG := 0.35
## The light lava casts (stage 6): one light a tile with lava in it, at the
## middle of its lava, within LAVA_LIGHT_RANGE_M of the eye.
const LAVA_LIGHT := Color(1.0, 0.45, 0.12)
const LAVA_LIGHT_ENERGY := 2.2
const LAVA_LIGHT_RANGE := 7.0
const LAVA_LIGHT_FAR_M := 40.0
const LAVA_FOG := Color(0.9, 0.32, 0.05)

var host: Node = null
## The gate ticks the water itself (tick_now) so its pictures are the same
## every run.
var manual := false
var sim_radius_m := 90.0
## The sim radius the world was set up with (detail tiles + 2); `sim_radius_m`
## is this, or less when water drops at LOD 1.
var _base_sim_m := 90.0
var _near_tiles := 4
## WATER DROPS AT A TERRAIN LOD (Options > Video > Water Drops At; the user,
## 2026-11-24): water is drawn on a tile only while its ground is drawn at a
## lower LOD than this -- 0 the detailed tiles, 1 the coarse blocks sampled
## every 4 studs (to TerrainCoarse.FIRST tiles), 2 every 8, ... At 1 it runs
## and is drawn on the detailed ground only (cheapest); at 2 (the default) the
## coarse ring's water stays drawn, frozen; inland water keeps its sections
## that far (BrickFluid.set_keep_inland), the open sea is the tiers'.
## The menu sets Engine meta `water_drop_lod`; this, when set (1+), wins over
## it (the water gate).
static var drop_lod := -1


static func _drop_lod() -> int:
	if drop_lod >= 1:
		return drop_lod
	return int(Engine.get_meta(&"water_drop_lod", 2))
var sea_on := false
var wave_scale := 1.0
## The sea's tiers (WaterSea), when the sea is on.
var sea: Node3D = null
## Tiles drawn, and the last tick's numbers for the HUD.
var drawn := 0
var rock_laid := 0
var field_moves := 0
var last_field_ms := 0.0

var _water_mat: ShaderMaterial
var _lava_mat: ShaderMaterial
var _tiles := {}                       ## Vector2i -> MeshInstance3D
## Stage 5 (MineWater.md 8): a tile past the sim ring, where water is frozen,
## shows its FAR mesh (a quad per 4 x 4 studs, no sides); inside, the full one.
var _tile_far := {}                    ## Vector2i -> bool, what it shows
var _lod_pending := {}                 ## Vector2i -> true, asked, not back yet
## Tiles with water whose ground is not drawn (the terrain let the tile go):
## their water is not drawn either, and is asked for again when it is.
var _parked := {}                      ## Vector2i -> true
var _lod_in := 0.0
const LOD_EVERY := 0.5
var far_tiles := 0
## Stage 8: tiles whose generated lava pools and springs were read (primed),
## asked for nearest first within the sim ring, PRIME_PER a check.
var _primed := {}
const PRIME_PER := 6
var primed_count := 0
var _spare: Array[MeshInstance3D] = []
var _field_task := -1
var _field_out := [PackedFloat32Array()]
var _field_for := Vector2i.ZERO
var _field_t0 := 0
var _field_edit_in := -1.0
var _under := Underwater.new()
var _under_mode := 0                   ## 0 dry, 1 water, 2 lava
var _dry_ambient := 0.6
## What floats and what sinks (floaters.gd, stage 8).
var floaters: Node = null
## What lava set alight (lava_fire.gd).
var fires: Node3D = null
var _lights := {}                      ## Vector2i -> OmniLight3D
var _burn_in := 0.0
var _queued_meshes := {}               ## Vector2i -> a take()'s mesh entry
## The real sea's band (Docs/MineWater.md 11.9) waves with the tiers' own
## waves: these of the near tier's shader parameters are copied to the fluid
## water's material (sea_wave.gdshaderinc), wave_time every frame.
const SEA_WAVE_PARAMS := ["waves", "wave_count", "groups", "group_count", "shore_band", "swell_blend",
		"shore_calm", "sea_level", "pool_calm", "pool_mask_origin", "pool_mask_size", "seabed_tex",
		"seabed_origin", "seabed_extent", "open_sea_depth", "water_outside_field", "swash_delay",
		"swash_loss", "trough_colour", "crest_colour", "deep_tint", "absorption_depth", "water_roughness",
		"grid_lines", "grid_line_width", "grid_line_darken", "print_lines_enabled", "layer_height",
		"bead_width", "bead_groove", "layer_darken", "resolve_begin", "resolve_end", "print_fade_begin",
		"print_fade_end", "foam_at", "step_m"]
var _wave_copy_in := 0.0
const MESH_SWAPS_PER_FRAME := 6
var _spare_lights: Array[OmniLight3D] = []


func setup(p_host: Node) -> void:
	host = p_host
	if not RenderingServer.frame_pre_draw.is_connected(_pre_draw):
		RenderingServer.frame_pre_draw.connect(_pre_draw)
	var shader: Shader = load("res://shaders/water_fluid.gdshader")
	# See-through, Minecraft's way (Docs/MineWater.md 7.4); lava stays solid.
	_water_mat = WaterShaders.material("res://shaders/water_fluid.gdshader", true)
	_lava_mat = ShaderMaterial.new()
	_lava_mat.shader = shader
	_lava_mat.set_shader_parameter("lava", true)
	# How long a new height takes to ease in: the mesher eases on from where
	# a corner is drawn, on the same numbers (BrickFluid.ease_seconds).
	var ease_s := BrickFluid.ease_seconds()
	_water_mat.set_shader_parameter("ease_s", ease_s[1])
	_lava_mat.set_shader_parameter("ease_s", ease_s[2])
	# The pawn asks with global positions; the water is in the mine world's
	# terrain frame (its origin shift, Docs/MineWorld.md 15).
	Pawn.water_probe = func(p: Vector3) -> float: return surface_at(host.to_local(p))
	Pawn.water_flow = func(p: Vector3) -> Vector3: return flow_at(host.to_local(p))
	Pawn.water_drag = func(p: Vector3) -> float: return drag_at(host.to_local(p))
	fires = LavaFireFx.new()
	fires.name = "LavaFire"
	add_child(fires)
	fires.setup(host)
	floaters = FloatersFx.new()
	floaters.name = "Floaters"
	add_child(floaters)
	floaters.setup(host, self)
	reset_world(20.0, 4, false)
	set_process(true)


## A new world: everything the last one had goes. Returns the sea level the
## water uses (snapped to a brick course, 7.2).
func reset_world(sea_m: float, near_tiles: int, p_sea_on: bool, p_wave_scale := 1.0,
		centre := Vector2i.ZERO) -> float:
	_finish_field()
	var level := BrickFluid.reset(sea_m, p_sea_on)
	sea_on = p_sea_on
	wave_scale = p_wave_scale
	BrickWave.set_sea_level(level if sea_on else sea_m)
	_near_tiles = near_tiles
	_base_sim_m = float(near_tiles + 2) * TILE_STUDS * BrickWorld.get_stud_metres()
	sim_radius_m = _base_sim_m
	for t in _tiles.keys():
		_release(t)
	drawn = 0
	rock_laid = 0
	field_moves = 0
	_primed.clear()
	_queued_meshes.clear()
	_parked.clear()
	_wave_copy_in = 0.0
	BrickFluid.set_real_sea(p_sea_on)
	if fires != null:
		fires.clear()
	primed_count = 0
	if sea != null:
		remove_child(sea)
		sea.queue_free()
		sea = null
	if sea_on:
		# The first field round the spawn, now: generating is a load.
		var c := centre
		var t0 := Time.get_ticks_usec()
		var f: PackedFloat32Array = BrickWave.compute_shore_field(c.x, c.y, FIELD_HALF, FIELD_STEP)
		last_field_ms = float(Time.get_ticks_usec() - t0) / 1000.0
		sea = WaterSeaFx.new()
		sea.name = "Sea"
		sea.use_pools = false
		sea.use_fluid_mask = true
		sea.see_through = true
		sea.surface_collide = false     # a ceiling to a swimmer; nothing floats yet
		sea.wave_gain = 2.2 * wave_scale
		add_child(sea)
		sea.build_at(FIELD_HALF, SEA_OUTER_M, FIELD_STEP, c, f)
		sea.push_waves()
	return level if sea_on else sea_m


func _exit_tree() -> void:
	if RenderingServer.frame_pre_draw.is_connected(_pre_draw):
		RenderingServer.frame_pre_draw.disconnect(_pre_draw)
	_finish_field()
	Pawn.water_probe = Callable()
	Pawn.water_flow = Callable()
	Pawn.water_drag = Callable()
	# Joins a running tick and frees the sections.
	BrickFluid.reset(20.0, false)


func _eye_studs() -> Vector2i:
	var e: Vector3 = host._eye() if host != null and host.get("walker") != null else Vector3.ZERO
	var stud := BrickWorld.get_stud_metres()
	return Vector2i(floori(e.x / stud), floori(e.z / stud))


## The clock the shader eases on (seconds); the same for `now_s` and every
## instance's `swap_s`.
func _clock() -> float:
	return float(Time.get_ticks_usec()) / 1.0e6


## The last frame's _process, microseconds (the mine world's --gate=stop and
## its F3 slow-frame line).
var last_us := 0


func _process(delta: float) -> void:
	var t_in := Time.get_ticks_usec()
	_process_body(delta)
	last_us = Time.get_ticks_usec() - t_in


func _process_body(delta: float) -> void:
	var now := _clock()
	_water_mat.set_shader_parameter("now_s", now)
	_lava_mat.set_shader_parameter("now_s", now)
	# The lakes' waves ride this clock in the shader and in the queries.
	BrickFluid.set_wave_clock(now)
	if host == null:
		return
	var eye: Vector3 = host._eye()
	BrickFluid.set_centre(eye, sim_radius_m)
	if not manual and BrickFluid.update(delta):
		apply(BrickFluid.take())
	_lod_in -= delta
	if _lod_in <= 0.0:
		_lod_in = LOD_EVERY
		_check_lod(eye)
		_prime_near(eye)
	if sea != null:
		sea.follow(eye, delta)
		_follow_field(delta)
	_swap_some()
	_copy_sea_waves(delta)
	_underwater(eye)
	_burn_in -= delta
	if _burn_in <= 0.0:
		# Lava burns at ten checks a second: every pawn every frame was waste.
		_burn(0.1 - _burn_in)
		_burn_in = 0.1


## The gate's clock: `ticks` ticks now, then what they built.
func step(ticks: int) -> void:
	BrickFluid.tick_now(ticks)
	apply(BrickFluid.take())
	while not _queued_meshes.is_empty():
		_swap_some()
	_copy_sea_waves(1.0)
	WaterShaders.sync_all()


func apply(res: Dictionary) -> void:
	var fire: PackedInt32Array = res.get("fire", PackedInt32Array())
	for i in range(0, fire.size(), 3):
		fires.ignite(Vector3i(fire[i], fire[i + 1], fire[i + 2]))
	# Meshes are swapped a few a frame (_swap_some): a tick that remeshed 24
	# tiles put 24 uploads in one frame. A newer mesh of a tile replaces one
	# still waiting.
	for m in res.get("meshes", []):
		_queued_meshes[m.tile] = m

	if sea != null and bool(res.get("mask_changed", false)):
		sea.fluid_mask_dirty = true
	# Lava came or went: the ground's block light round it (MineWorld.md 18).
	var lit: PackedInt32Array = res.get("lava_light", PackedInt32Array())
	if not lit.is_empty() and host != null and host.has_method("lava_relit"):
		host.lava_relit(lit)
	# Rock the lava made: (x, z, first plate, last plate, material) a cell.
	# All of a tick's rock is ONE terrain edit (one box, the tiles merged): a
	# cell at a time was a tile rebuild and a collapse survey per cell.
	var terr: PackedInt32Array = res.get("terrain", PackedInt32Array())
	if terr.is_empty():
		return
	var tiles := {}
	var blo := Vector3i(1 << 30, 1 << 30, 1 << 30)
	var bhi := -blo
	var any := 0
	for i in range(0, terr.size(), 5):
		var lo := Vector3i(terr[i], terr[i + 2], terr[i + 1])
		var hi := Vector3i(terr[i], terr[i + 3], terr[i + 1])
		var r: Dictionary = BrickTerrain.fill_box(lo, hi, terr[i + 4], true)
		if int(r.get("changed", 0)) <= 0:
			continue
		any += 1
		rock_laid += 1
		var tl: PackedInt32Array = r["tiles"]
		for k in range(0, tl.size(), 2):
			tiles[Vector2i(tl[k], tl[k + 1])] = true
		blo = Vector3i(mini(blo.x, lo.x), mini(blo.y, lo.y), mini(blo.z, lo.z))
		bhi = Vector3i(maxi(bhi.x, hi.x), maxi(bhi.y, hi.y), maxi(bhi.z, hi.z))
	if any > 0:
		var flat := PackedInt32Array()
		for k in tiles:
			flat.append(k.x)
			flat.append(k.y)
		# "anchored": lava rock is part of the world, like Minecraft's: it
		# stays where it formed, over water too, so it dams the lava (it fell
		# as loose bricks and the lava ran on, for ever -- the user,
		# 2026-11-23). Adding ground takes no one's support: no survey.
		host.terrain_edited({"tiles": flat, "box_lo": blo, "box_hi": bhi, "changed": any, "anchored": true})


## An edit's result (fill_box, carve, clear_runs): its plate box. Ground
## changed under the sea line also reshapes the shore field, a little later.
func terrain_changed(res: Dictionary) -> void:
	if not res.has("box_lo"):
		return
	BrickFluid.terrain_changed(res.box_lo, res.box_hi)
	if sea != null and int((res.box_lo as Vector3i).y) <= BrickFluid.get_sea_course() * 3 + 3:
		if _field_edit_in < 0.0:
			_field_edit_in = FIELD_EDIT_DELAY


# ---------------------------------------------------------------------------
# The shore field, streamed (7.2)

func _follow_field(delta: float) -> void:
	if _field_task >= 0:
		if not WorkerThreadPool.is_task_completed(_field_task):
			return
		WorkerThreadPool.wait_for_task_completion(_field_task)
		_field_task = -1
		sea.move_field(_field_for, _field_out[0])
		last_field_ms = float(Time.get_ticks_usec() - _field_t0) / 1000.0
		field_moves += 1
		return
	if _field_edit_in >= 0.0:
		_field_edit_in -= delta
	var c := _eye_studs()
	var d: Vector2i = c - sea.field_centre
	var moved := maxi(absi(d.x), absi(d.y)) >= FIELD_MOVE
	# _field_edit_in: -1 idle, counting down after an edit, due at 0.
	if moved or (_field_edit_in > -1.0 and _field_edit_in <= 0.0):
		_field_edit_in = -1.0
		# The edit's centre stays where it is; a move takes the player's.
		_field_for = c if moved else sea.field_centre
		_field_t0 = Time.get_ticks_usec()
		var at := _field_for
		var holder := _field_out
		_field_task = WorkerThreadPool.add_task(func() -> void:
			holder[0] = BrickWave.compute_shore_field(at.x, at.y, FIELD_HALF, FIELD_STEP),
			false, "shore field")


## Load time and teardown only: a field still being computed is waited for.
func _finish_field() -> void:
	if _field_task >= 0:
		WorkerThreadPool.wait_for_task_completion(_field_task)
		_field_task = -1


# ---------------------------------------------------------------------------
# What the player asks (section 10)

## The top of the water over a point, metres; -INF when the point is not in
## water. Sea water has the waves the tiers draw (BrickWave), the rest is
## BrickFluid's.
func surface_at(p: Vector3) -> float:
	var s := BrickFluid.surface_at(p)
	if sea == null:
		return s
	var level := BrickFluid.get_sea_level()
	if p.y < level - 3.0 or p.y > level + 3.0:
		return s
	# One native call (it built a Dictionary a query, many a frame).
	if BrickFluid.ocean_at(p):
		# The band's water and the tiers' sea ride the same waves.
		return maxf(s, float(sea.surface_at(p)))
	return s


func flow_at(p: Vector3) -> Vector3:
	return BrickFluid.flow_at(p)


## How freely a body moves in the fluid at a point: 1 water, less in lava.
func drag_at(p: Vector3) -> float:
	return LAVA_DRAG if BrickFluid.fluid_at(p) == 2 else 1.0


## 0 none, 1 water, 2 lava at a point (sea waves counted).
func fluid_at(p: Vector3) -> int:
	var f := BrickFluid.fluid_at(p)
	# Under a wave's crest (the sea's, or a lake's, S3) is water too.
	if f == 0 and p.y < surface_at(p):
		return 1
	return f


func _underwater(eye: Vector3) -> void:
	var rig = host.get("_rig")
	if rig == null or rig.env == null:
		return
	var mode := fluid_at(eye)
	if mode == _under_mode:
		return
	var env: Environment = rig.env
	if _under_mode == 0:
		_dry_ambient = env.ambient_light_energy
	_under.set_submerged(env, false, _dry_ambient)
	_under_mode = mode
	if mode == 0:
		return
	_under.set_submerged(env, true, _dry_ambient)
	if mode == 2:
		env.fog_light_color = LAVA_FOG
		env.fog_density = 1.2
		env.ambient_light_color = LAVA_FOG


## Every pawn standing or swimming in lava burns (the player only on foot).
func _burn(delta: float) -> void:
	var player: Pawn = host.get("pawn")
	for n in get_tree().get_nodes_in_group(Pawn.GROUP):
		var pawn := n as Pawn
		if pawn == null or pawn.health == null or pawn.body == null:
			continue
		if pawn == player and not host.get("on_foot"):
			continue
		# Just over the feet: a pawn stands on the studs, a plate up, so a
		# probe higher than that missed a two-plate lava sheet. In the
		# terrain frame (the origin shift, MineWorld.md 15).
		if BrickFluid.fluid_at(host.to_local(pawn.feet() + pawn.up * 0.03)) == 2:
			pawn.health.apply_impact(LAVA_DPS * delta, Elements.FIRE)


# ---------------------------------------------------------------------------
# Meshes

## The sea's wave numbers onto the fluid water (the band waves with the
## tiers): the clock every frame, the rest four times a second (the field and
## the mask move now and then). CPU-side material values, no read-back.
## Just before the frame is drawn, after every node's _process: the sea's
## clock onto the fluid water, then every see-through material's uniforms
## onto its depth pass (WaterShaders). Copied earlier in the frame the depth
## pass was a frame behind the waves, and the water behind its own depth
## did not draw: the shore strip was bare and far water too clear (the user,
## 2026-11-23).
func _pre_draw() -> void:
	if sea != null and sea.near != null and sea.near._mat != null:
		_water_mat.set_shader_parameter("wave_time", sea.near._mat.get_shader_parameter("wave_time"))
	WaterShaders.sync_all()


func _copy_sea_waves(delta: float) -> void:
	if sea == null or sea.near == null or sea.near._mat == null:
		return
	var src: ShaderMaterial = sea.near._mat
	_water_mat.set_shader_parameter("wave_time", src.get_shader_parameter("wave_time"))
	_wave_copy_in -= delta
	if _wave_copy_in > 0.0:
		return
	_wave_copy_in = 0.25
	for n in SEA_WAVE_PARAMS:
		_water_mat.set_shader_parameter(n, src.get_shader_parameter(n))


## A few of the waiting meshes into their tiles, nearest the eye first.
func _swap_some() -> void:
	if _queued_meshes.is_empty():
		return
	var keys := _queued_meshes.keys()
	if keys.size() > MESH_SWAPS_PER_FRAME:
		var e: Vector3 = host._eye()
		var tm := TILE_STUDS * BrickWorld.get_stud_metres()
		var c := Vector2(e.x / tm, e.z / tm)
		keys.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
			return (Vector2(a) - c).length_squared() < (Vector2(b) - c).length_squared())
	for i in mini(MESH_SWAPS_PER_FRAME, keys.size()):
		var m: Dictionary = _queued_meshes[keys[i]]
		_queued_meshes.erase(keys[i])
		_lod_pending.erase(m.tile)
		if _parked.has(m.tile):
			continue
		_show(m.tile, m.water, m.lava, float(m.get("built_s", -1.0)))
		_tile_far[m.tile] = bool(m.get("far", false))


func _show(tile: Vector2i, water: Array, lava: Array, built_s := -1.0) -> void:
	if water.is_empty() and lava.is_empty():
		_release(tile)
		return
	var mi: MeshInstance3D = _tiles.get(tile)
	if mi == null:
		mi = _spare.pop_back() if not _spare.is_empty() else _new_instance()
		mi.visible = true
		_tiles[tile] = mi
		drawn = _tiles.size()
	var mesh := mi.mesh as ArrayMesh
	mesh.clear_surfaces()
	if not water.is_empty():
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, water, [], {}, MESH_FLAGS)
		mesh.surface_set_material(mesh.get_surface_count() - 1, _water_mat)
	if not lava.is_empty():
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, lava, [], {}, MESH_FLAGS)
		mesh.surface_set_material(mesh.get_surface_count() - 1, _lava_mat)
	# It eases from where the last mesh was drawn when this one was built
	# (water_fluid.gdshader): from the build's time, the mesher's reckoning.
	mi.set_instance_shader_parameter("swap_s", built_s if built_s >= 0.0 else _clock())
	_light(tile, lava)


## Generated lava pools and springs (stage 8) are worked out from the seed
## and stored nowhere: a tile coming into the sim ring is primed once, so its
## pools are read and drawn and its springs start running.
func _prime_near(eye: Vector3) -> void:
	if not BrickFluid.has_generated():
		return
	var tile_m := TILE_STUDS * BrickWorld.get_stud_metres()
	var c := Vector2i(floori(eye.x / tile_m), floori(eye.z / tile_m))
	var r := int(ceil(sim_radius_m / tile_m))
	# Cave pools are read in bands round the eye's height: a tile is primed
	# again when the eye goes down (or up) a band.
	var band := floori(eye.y / (BrickWorld.get_plate_metres() * 3.0) / 16.0)
	var want: Array = []
	for dz in range(-r, r + 1):
		for dx in range(-r, r + 1):
			var t := c + Vector2i(dx, dz)
			if not _primed.has(Vector3i(t.x, band, t.y)):
				want.append(t)
	if want.is_empty():
		return
	want.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return (a - c).length_squared() < (b - c).length_squared())
	for i in mini(PRIME_PER, want.size()):
		_primed[Vector3i(want[i].x, band, want[i].y)] = true
		BrickFluid.prime_tile(want[i].x, want[i].y, band * 16 - 16, band * 16 + 32)
		primed_count += 1


## Past the sim ring a tile's water is frozen: show its far mesh; back in
## reach, the full one. Each asked for once, built with the next tick.
##
## Where the terrain has let its tile go (its detail unloaded, the coarse
## tier drawn instead) the water goes too, and comes back with the tile:
## frozen water was drawn at any distance, over coarse ground or none (the
## user, 2026-11-23: "flowing water never seems to unload").
func _check_lod(eye: Vector3) -> void:
	var tile_m := TILE_STUDS * BrickWorld.get_stud_metres()
	var n := 0
	# The chosen drop LOD: the sim's reach (LOD 1: the detailed ground only)
	# and how far inland water keeps its sections (to the drop LOD's edge,
	# that square's corner).
	var dl := _drop_lod()
	if dl <= 1:
		sim_radius_m = minf(_base_sim_m, (float(_near_tiles) + 0.5) * tile_m)
		BrickFluid.set_keep_inland(0.0)
	else:
		sim_radius_m = _base_sim_m
		BrickFluid.set_keep_inland(float(TerrainCoarse.FIRST << (dl - 2)) * tile_m * 1.42 + tile_m)
	var st: Object = host.get("_streamer") if host != null else null
	var ct := Vector2i(floori(eye.x / tile_m), floori(eye.z / tile_m))
	if st != null and st.has_method("has_tile"):
		for t in _tiles.keys():
			if tile_lod(t, ct, st) >= dl:
				_release(t)
				_parked[t] = true
		for t in _parked.keys():
			if tile_lod(t, ct, st) < dl:
				_parked.erase(t)
				var c := Vector2((t.x + 0.5) * tile_m, (t.y + 0.5) * tile_m)
				_lod_pending[t] = true
				if c.distance_to(Vector2(eye.x, eye.z)) > sim_radius_m + tile_m * 0.5:
					BrickFluid.request_far_mesh(t.x, t.y)
				else:
					BrickFluid.request_mesh(t.x, t.y)
	for t in _tiles.keys():
		var centre := Vector2((t.x + 0.5) * tile_m, (t.y + 0.5) * tile_m)
		var want_far := centre.distance_to(Vector2(eye.x, eye.z)) > sim_radius_m + tile_m * 0.5
		if want_far:
			n += 1
		if want_far == bool(_tile_far.get(t, false)) or _lod_pending.has(t):
			continue
		_lod_pending[t] = true
		if want_far:
			BrickFluid.request_far_mesh(t.x, t.y)
		else:
			BrickFluid.request_mesh(t.x, t.y)
	far_tiles = n


## A tile's lava light: at the middle of its lava, a little above it; none
## when the tile has none. Recycled like the meshes.
func _light(tile: Vector2i, lava: Array) -> void:
	var l: OmniLight3D = _lights.get(tile)
	if lava.is_empty():
		if l != null:
			_lights.erase(tile)
			l.visible = false
			_spare_lights.append(l)
		return
	var v: PackedVector3Array = lava[Mesh.ARRAY_VERTEX]
	# A light's place needs no exact centre: at most 64 vertices, evenly
	# spread, not every one of a big pool's thousands in GDScript on every
	# remesh of its tile.
	var sum := Vector3.ZERO
	var top := -INF
	@warning_ignore("integer_division")
	var every := maxi(1, v.size() / 64)
	var seen := 0
	for i in range(0, v.size(), every):
		var p := v[i]
		sum += p
		top = maxf(top, p.y)
		seen += 1
	if l == null:
		l = _spare_lights.pop_back() if not _spare_lights.is_empty() else _new_light()
		_lights[tile] = l
		l.visible = true
	var c := sum / maxf(seen, 1)
	l.position = Vector3(c.x, top + 0.6, c.z)
	# Bigger lava, a brighter, wider light.
	var k := clampf(float(v.size()) / 400.0, 0.4, 1.6)
	l.light_energy = LAVA_LIGHT_ENERGY * k
	l.omni_range = LAVA_LIGHT_RANGE * sqrt(k)


func _new_light() -> OmniLight3D:
	var l := OmniLight3D.new()
	l.light_color = LAVA_LIGHT
	l.shadow_enabled = false
	l.omni_attenuation = 1.5
	l.distance_fade_enabled = true
	l.distance_fade_begin = LAVA_LIGHT_FAR_M
	l.distance_fade_length = 20.0
	# Not the ground with block light in its cells (lit twice otherwise):
	# only what the cells cannot light -- studs, props, pawns, drops.
	l.light_cull_mask = 0xFFFFF & ~RenderLayers.BLOCK_LIT
	add_child(l)
	return l


## Water tiles drawn where the ground is at the drop LOD or past it (want 0),
## and tiles parked for it (the water gate).
func drawn_on_bare() -> int:
	var st: Object = host.get("_streamer") if host != null else null
	var n := 0
	if st != null and host != null:
		var tile_m := TILE_STUDS * BrickWorld.get_stud_metres()
		var e: Vector3 = host._eye()
		var ct := Vector2i(floori(e.x / tile_m), floori(e.z / tile_m))
		for t in _tiles.keys():
			if tile_lod(t, ct, st) >= _drop_lod():
				n += 1
	return n


## The terrain LOD tile `t`'s ground is drawn at, seen from tile `ct`: 0 a
## detailed tile (the streamer has it), else the coarse tier's ring by the
## tile's distance (TerrainCoarse.relod's rule): 1 within FIRST tiles, then
## one more each doubling.
static func tile_lod(t: Vector2i, ct: Vector2i, streamer: Object) -> int:
	if streamer != null and bool(streamer.call("has_tile", t)):
		return 0
	var d := maxi(absi(t.x - ct.x), absi(t.y - ct.y))
	var level := 0
	while level < TerrainCoarse.LEVELS - 1 and d >= (TerrainCoarse.FIRST << level):
		level += 1
	return 1 + level


func parked_count() -> int:
	return _parked.size()


func has_tile_drawn(t: Vector2i) -> bool:
	return _tiles.has(t)


func lava_lights() -> int:
	return _lights.size()


func _release(tile: Vector2i) -> void:
	_light(tile, [])
	var mi: MeshInstance3D = _tiles.get(tile)
	_tile_far.erase(tile)
	_lod_pending.erase(tile)
	if mi == null:
		return
	_tiles.erase(tile)
	(mi.mesh as ArrayMesh).clear_surfaces()
	mi.visible = false
	_spare.append(mi)
	drawn = _tiles.size()


func _new_instance() -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = ArrayMesh.new()
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	return mi


func report() -> String:
	var s: Dictionary = BrickFluid.stats()
	var line := "%d awake, %d tiles drawn (%d far), tick %.2f ms (%d cells, mesh %.2f), %d sections, %d rock" % [
			BrickFluid.active_count(), drawn, far_tiles, float(s.get("tick_ms", 0.0)),
			int(s.get("evals", 0)), float(s.get("mesh_ms", 0.0)), BrickFluid.section_count(), rock_laid]
	# The main thread's worst wait for the water's lock since the last report
	# (Docs/MineWater.md 11.8), and far sections let go.
	line += ", lock wait %.2f ms (%d over 1 ms, hold %.2f), %d let go" % [
			float(s.get("main_wait_ms", 0.0)), int(s.get("main_waits_1ms", 0)),
			float(s.get("apply_ms", 0.0)), int(s.get("evicted", 0))]
	if not _lights.is_empty():
		line += ", %d lava lights" % _lights.size()
	if fires != null and not fires.burning.is_empty():
		line += ", %d burning (%d burned)" % [fires.burning.size(), fires.burned]
	if primed_count > 0:
		line += ", %d tiles primed" % primed_count
	if floaters != null and floaters.wet_bodies > 0:
		line += ", %d bodies in water (%d floating)" % [floaters.wet_bodies, floaters.floating]
	if sea != null:
		line += ", sea at %.2f m, shore field %.0f ms (%d moves)" % [
				BrickFluid.get_sea_level(), last_field_ms, field_moves]
	return line
