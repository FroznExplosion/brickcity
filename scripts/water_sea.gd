extends Node3D

## THE SEA, as one thing a scene adds: the three water tiers and the seabed
## texture they share. [Docs/Terrain.md](../Docs/Terrain.md) §21.6,
## [Docs/Water.md](../Docs/Water.md) §3.
##
## heightfield_test builds the same three tiers by hand, because it toggles
## and measures each one on its own. A scene that just wants a coast — the
## city — wants them as a unit, at the sea level the world already settled
## (TerrainWorld.sea_level), and wants the brick tiers to cost nothing where
## there is no water to draw.
##
## Preloaded, not named: a new `class_name` is not in the global class cache
## until the editor rescans, and a headless run reads that cache off disk.

const WaterSheetFx := preload("res://scripts/water_sheet.gd")
const WaterPoolsFx := preload("res://scripts/water_pools.gd")

## Tier 0: brick pieces a stud across, round the camera.
var near: WaterSurface = null
## There is no tier 1 any more: the four-stud blocks between the studded
## water and the sheet were the blocky donut round the camera, and cost more
## than the sheet (Water.md §8). Kept as a name, always null.
var far: WaterSurface = null
## Tier 1 now: the smooth sheet, from the studded tier to the horizon.
var sheet = null
## The water in dug ground (water_pools.gd, Water.md §12): a hole dug below
## the sea where the world was dry is not sea, and fills by flowing.
var pools = null

## Stud columns per WET-map cell, and the map itself: whether any ground in
## the cell is under the sea. Tier 0 is 26k pieces whatever is under it, and
## a city on a hill has no water within 80 m of most of its streets, so the
## brick tiers are shown only where the map says there is something to show.
const WET_CELL := 64
var _wet := {}
var _wet_count := 0
## Off hides every tier (heightfield_test's F7, and the bench's "water off").
var enabled := true
## How far the studded tier reaches. 20 m read as a small blocky island in
## a smooth sea; 40 m is where a brick is ~2 px at 1080p.
var near_radius := 40.0
## The wave height gain the tiers are built with (BrickWave.set_wave_gain).
var wave_gain := 2.2
var _outer_metres := 600.0
## How far the sheet runs under the studded tier's edge.
const SEAM_OVERLAP := 3.0
var _seabed: ImageTexture = null
var _half_studs := 0
var _step := 8
## The pools' sea mask (BrickPools.sea_mask): studs a side, how far its
## window moves at a time, and where it is now.
const MASK_STUDS := 512
const MASK_SNAP := 64
var _mask_tex: ImageTexture = null
var _mask_at := Vector2i(1 << 30, 0)
var _mask_tiles := -1
var _mask_stale := true
## The pools' water moved: the calm channel follows it, at most this often.
const MASK_WATER_EVERY := 0.2
var _mask_water_t := 0.0

## A storm surge (set_surge): the level and gain before it, and where the
## seabed map was last read.
const SURGE_SEABED_STEP := 0.5
const SURGE_SEABED_MS := 2000
var _surge_base := NAN
var _surge_gain := 0.0
var _surge_mul := 1.0
var _surge_seabed := 0.0
var _surge_seabed_ms := 0


## Build the tiers over a square `half_studs` each way of the origin, with the
## sheet reaching `outer_metres`. The seabed is sampled every `step` studs:
## it is a cull mask and an absorption depth, neither of which needs a stud.
func build(half_studs: int, outer_metres: float, step := 8) -> void:
	var stud := BrickWorld.get_stud_metres()
	_half_studs = half_studs
	_outer_metres = outer_metres
	_step = step
	var seabed := ImageTexture.create_from_image(_seabed_image())
	_seabed = seabed
	var origin := Vector2(-half_studs * stud, -half_studs * stud)
	var extent := Vector2(2 * half_studs * stud, 2 * half_studs * stud)

	near = WaterSurface.new()
	near.name = "Water"
	# LOD 0: studded bricks to 40 m round the camera; the smooth sheet past it.
	near.radius = near_radius
	near.wave_gain = wave_gain
	add_child(near)
	near.set_seabed(seabed, origin, extent)

	sheet = WaterSheetFx.new()
	sheet.name = "WaterSheet"
	sheet.outer_radius = outer_metres
	add_child(sheet)
	sheet.build(seabed, origin, extent)

	pools = WaterPoolsFx.new()
	pools.name = "Pools"
	add_child(pools)
	pools.reset_for_world()


## The ground under the water (R) and the distance to the nearest dry
## ground (G), one texel every `_step` studs, and the WET map beside it.
##
## Built in C++ (BrickWave.build_shore_field), which keeps the same field for
## the CPU's wave: the shore band is phased on that distance, and the swimmer
## and the drawn sea have to agree about where its crests are.
func _seabed_image() -> Image:
	var field: PackedFloat32Array = BrickWave.build_shore_field(_half_studs, _step)
	@warning_ignore("integer_division")
	var n: int = maxi(2 * _half_studs / _step, 2)
	var img := Image.create_from_data(n, n, false, Image.FORMAT_RGF, field.to_byte_array())
	# The WET map from the same field, in C++: this loop was 160k samples of
	# GDScript, ~40 ms on every brush stroke.
	_wet.clear()
	for c in BrickWave.wet_cells(WET_CELL):
		_wet[c] = true
	_wet_count = _wet.size()
	return img


## The ground changed (an edit): read the seabed again. One texture is
## shared by every tier, so updating it in place reaches all of them.
## `studs`, when given, is where it changed: the pools there read their
## ground again, and a hole newly dug below the sea starts to fill.
func refresh_seabed(studs := Rect2i()) -> void:
	if _seabed != null:
		_seabed.update(_seabed_image())
	if pools == null or not studs.has_area():
		return
	_mask_stale = true
	# A whole-world change (a load, an undo of everything) is a new world to
	# the pools: scanning every column for dug ground would take seconds.
	var tile := BrickTerrain.get_tile_studs()
	if studs.get_area() > 64 * tile * tile:
		pools.reset_for_world()
	else:
		pools.ground_changed(studs)


## Is there sea anywhere in what was built?
func has_water() -> bool:
	return _wet_count > 0


## Is any ground within `radius` metres of `at` under the sea?
func wet_near(at: Vector3, radius: float) -> bool:
	var stud := BrickWorld.get_stud_metres()
	var cell_m := float(WET_CELL) * stud
	var x0 := floori((at.x - radius) / cell_m)
	var x1 := floori((at.x + radius) / cell_m)
	var z0 := floori((at.z - radius) / cell_m)
	var z1 := floori((at.z + radius) / cell_m)
	for cz in range(z0, z1 + 1):
		for cx in range(x0, x1 + 1):
			if _wet.has(Vector2i(cx, cz)):
				return true
	return false


func follow(camera: Vector3, delta: float) -> void:
	if near == null:
		return
	var xz := Vector2(camera.x, camera.z)
	# The sheet is flat rings and cheap; the brick tiers are not, and are shown
	# only where there is water inside their reach.
	near.visible = enabled and wet_near(camera, near.radius)
	sheet.visible = enabled
	if pools != null:
		pools.visible = enabled
		pools.tick(delta)
		_mask_water_t += delta
		if pools.water_moved and _mask_water_t >= MASK_WATER_EVERY:
			pools.water_moved = false
			_mask_water_t = 0.0
			_mask_stale = true
		_update_mask(camera)
	# Followed even hidden: the wave clock lives in the near tier.
	near.follow(xz, delta, camera.y)
	# The sheet leaves a hole exactly where the studded tier draws, and none
	# when it does not -- so there is never water twice, or none.
	# The hole a few metres INSIDE the studded tier's edge: the two overlap
	# there, the sheet a little lower (water.gdshader seam_sink), so the seam
	# between them is water whichever way the waves lean.
	# The centre is passed always: the sheet's wave LOD is by distance from
	# it, hole or no hole.
	sheet.follow(near.time(), xz, near.centre_for(xz),
			maxf(near.radius - SEAM_OVERLAP, 0.0) if near.visible else 0.0)


## Keep the sea from drawing over pools: a stud mask over a window round the
## camera, re-read when the window moves or the pools' ground changes.
func _update_mask(camera: Vector3) -> void:
	var stud := BrickWorld.get_stud_metres()
	var tiles := BrickPools.tile_count()
	if tiles == 0:
		if _mask_tiles != 0:
			_mask_tiles = 0
			_set_mask_param("pool_mask_size", 0.0)
		return
	@warning_ignore("integer_division")
	var at := Vector2i(floori(camera.x / stud / MASK_SNAP) * MASK_SNAP - MASK_STUDS / 2,
			floori(camera.z / stud / MASK_SNAP) * MASK_SNAP - MASK_STUDS / 2)
	if at == _mask_at and tiles == _mask_tiles and not _mask_stale:
		return
	_mask_at = at
	_mask_tiles = tiles
	_mask_stale = false
	# R: where the sea is not drawn. G: how much wave it keeps, none against
	# a pool's water (BrickPools.sea_mask).
	var img := Image.create_from_data(MASK_STUDS, MASK_STUDS, false, Image.FORMAT_RG8,
			BrickPools.sea_mask(at.x, at.y, MASK_STUDS))
	if _mask_tex == null:
		_mask_tex = ImageTexture.create_from_image(img)
	else:
		_mask_tex.update(img)
	_set_mask_param("pool_mask", _mask_tex)
	_set_mask_param("pool_calm", _mask_tex)
	_set_mask_param("pool_mask_origin", Vector2(at.x * stud, at.y * stud))
	_set_mask_param("pool_mask_size", MASK_STUDS * stud)


func _set_mask_param(param: String, value: Variant) -> void:
	for tier in [near, sheet]:
		if tier != null and tier._mat != null:
			tier._mat.set_shader_parameter(param, value)


## Build the tiers again: a new studded radius. The seabed is kept.
func rebuild() -> void:
	var lod_on := false
	if near != null:
		lod_on = bool(near._mat.get_shader_parameter("lod_debug"))
	for child in get_children():
		remove_child(child)
		child.queue_free()
	near = null
	sheet = null
	pools = null
	_mask_tex = null
	_mask_tiles = -1
	_mask_stale = true
	build(_half_studs, _outer_metres, _step)
	set_lod_debug(lod_on)


## A storm moves the sea (Docs/Disasters.md 18): `surge` metres over where it
## was, waves `wave_mul` times as big. (0, 1) puts it back exactly.
##
## BrickWave's own level, so the drawn sea, the swimmer and the water's
## collision rise together, and the flood itself needs nothing more: the water
## shader compares the ground (the seabed map's R) with `sea_level` per pixel.
## What the map's wet cells and shore distance decide -- where the studded tier
## shows, how the waves steer to the shore -- is re-read every SURGE_SEABED_STEP
## of level, no more than every SURGE_SEABED_MS, because a read is ~30 ms.
## Between reads newly flooded ground is drawn by the smooth sheet.
func set_surge(p_surge: float, wave_mul: float) -> void:
	if is_nan(_surge_base):
		if p_surge == 0.0 and wave_mul == 1.0:
			return
		_surge_base = BrickWave.get_sea_level()
		_surge_gain = wave_gain
		_surge_mul = 1.0
	var level := _surge_base + p_surge
	BrickWave.set_sea_level(level)
	_set_mask_param("sea_level", level)
	if absf(wave_mul - _surge_mul) > 0.02 or (wave_mul == 1.0 and _surge_mul != 1.0):
		_surge_mul = wave_mul
		wave_gain = _surge_gain * wave_mul
		push_waves()
	var now := Time.get_ticks_msec()
	var back := p_surge == 0.0 and wave_mul == 1.0
	if back or (absf(p_surge - _surge_seabed) >= SURGE_SEABED_STEP
			and now - _surge_seabed_ms >= SURGE_SEABED_MS):
		_surge_seabed = p_surge
		_surge_seabed_ms = now
		refresh_seabed()
	if back:
		_surge_base = NAN


## How far the storm has the sea above its own level (0 when calm).
func surge() -> float:
	return 0.0 if is_nan(_surge_base) else BrickWave.get_sea_level() - _surge_base


## The sea state changed (gain, shore strength, steering): into both tiers.
func push_waves() -> void:
	BrickWave.set_wave_gain(wave_gain)
	if near != null:
		near.wave_gain = wave_gain
		near.push_waves()
	if sheet != null:
		sheet.push_waves()


func set_lod_debug(on: bool) -> void:
	if near != null:
		near.set_lod_debug(on)
	if sheet != null:
		sheet.set_lod_debug(on)


## The water's surface over a point: a pool's where there is one, -INF
## where the ground is dug below the sea and has not filled, else the sea's.
func surface_at(p: Vector3) -> float:
	if near == null:
		return -INF
	if pools != null:
		var pool: float = pools.level_at(p)
		if not is_nan(pool):
			return pool
	return near.surface_at(p)


func submerged_at(p: Vector3) -> bool:
	return near != null and p.y < surface_at(p)


func triangle_count() -> int:
	return sheet.triangle_count() if sheet != null else 0
