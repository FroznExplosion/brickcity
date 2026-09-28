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

## Tier 0: brick pieces a stud across, round the camera.
var near: WaterSurface = null
## There is no tier 1 any more: the four-stud blocks between the studded
## water and the sheet were the blocky donut round the camera, and cost more
## than the sheet (Water.md §8). Kept as a name, always null.
var far: WaterSurface = null
## Tier 1 now: the smooth sheet, from the studded tier to the horizon.
var sheet = null

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


## The ground under the water (R) and the distance to the nearest dry
## ground (G), one texel every `_step` studs, and the WET map beside it.
##
## Built in C++ (BrickWave.build_shore_field), which keeps the same field for
## the CPU's wave: the shore band is phased on that distance, and the swimmer
## and the drawn sea have to agree about where its crests are.
func _seabed_image() -> Image:
	var sea := BrickWave.get_sea_level()
	var field: PackedFloat32Array = BrickWave.build_shore_field(_half_studs, _step)
	@warning_ignore("integer_division")
	var n: int = maxi(2 * _half_studs / _step, 2)
	var img := Image.create_from_data(n, n, false, Image.FORMAT_RGF, field.to_byte_array())
	_wet.clear()
	for iz in n:
		for ix in n:
			if field[(iz * n + ix) * 2] < sea:
				_wet[Vector2i(floori(float(ix * _step - _half_studs) / WET_CELL),
						floori(float(iz * _step - _half_studs) / WET_CELL))] = true
	_wet_count = _wet.size()
	return img


## The ground changed (an edit): read the seabed again. One texture is
## shared by every tier, so updating it in place reaches all of them.
func refresh_seabed() -> void:
	if _seabed != null:
		_seabed.update(_seabed_image())


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
	build(_half_studs, _outer_metres, _step)
	set_lod_debug(lod_on)


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


func surface_at(p: Vector3) -> float:
	return near.surface_at(p) if near != null else -INF


func submerged_at(p: Vector3) -> bool:
	return near != null and near.submerged_at(p)


func triangle_count() -> int:
	return sheet.triangle_count() if sheet != null else 0
