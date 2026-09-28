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
## Tier 1: the same wave at four studs a piece, out to 80 m.
var far: WaterSurface = null
## Tier 2: one sheet from the brick tiers to the horizon.
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
var _seabed: ImageTexture = null
var _half_studs := 0
var _step := 8


## Build the tiers over a square `half_studs` each way of the origin, with the
## sheet reaching `outer_metres`. The seabed is sampled every `step` studs:
## it is a cull mask and an absorption depth, neither of which needs a stud.
func build(half_studs: int, outer_metres: float, step := 8) -> void:
	var stud := BrickWorld.get_stud_metres()
	_half_studs = half_studs
	_step = step
	var seabed := ImageTexture.create_from_image(_seabed_image())
	_seabed = seabed
	var origin := Vector2(-half_studs * stud, -half_studs * stud)
	var extent := Vector2(2 * half_studs * stud, 2 * half_studs * stud)

	near = WaterSurface.new()
	near.name = "Water"
	near.radius = 20.0
	add_child(near)
	far = WaterSurface.new()
	far.name = "WaterFar"
	far.radius = 80.0
	far.pitch_studs = 4
	far.inner_radius = 19.0
	far.studs = false
	# One collider is enough, and it belongs to the tier under the camera.
	far.collide = false
	add_child(far)
	near.set_seabed(seabed, origin, extent)
	far.set_seabed(seabed, origin, extent)

	sheet = WaterSheetFx.new()
	sheet.name = "WaterSheet"
	sheet.inner_radius = far.radius - 4.0
	sheet.outer_radius = outer_metres
	add_child(sheet)
	sheet.build(seabed, origin, extent)


## The ground under the water, one texel every `_step` studs, and the WET
## map beside it.
func _seabed_image() -> Image:
	var plate := BrickWorld.get_plate_metres()
	var sea := BrickWave.get_sea_level()
	@warning_ignore("integer_division")
	var n: int = maxi(2 * _half_studs / _step, 2)
	var img := Image.create_empty(n, n, false, Image.FORMAT_RF)
	_wet.clear()
	for iz in n:
		for ix in n:
			var gx := ix * _step - _half_studs
			var gz := iz * _step - _half_studs
			# `surface_plate`, not `height_at`: on a plate-quantised field the
			# brick height rounds a plate step DOWN and the shoreline would
			# sit a plate inside the sand.
			var y := float(BrickTerrain.surface_plate(gx, gz) + 1) * plate
			img.set_pixel(ix, iz, Color(y, 0.0, 0.0))
			if y < sea:
				_wet[Vector2i(floori(float(gx) / WET_CELL), floori(float(gz) / WET_CELL))] = true
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
	far.visible = enabled and wet_near(camera, far.radius)
	sheet.visible = enabled
	# Followed even hidden: each tier keeps its own wave clock, and one that
	# skipped frames would come back out of phase with the others. It is two
	# uniform writes.
	near.follow(xz, delta, camera.y)
	far.follow(xz, delta, camera.y)
	sheet.follow(near.time())


func surface_at(p: Vector3) -> float:
	return near.surface_at(p) if near != null else -INF


func submerged_at(p: Vector3) -> bool:
	return near != null and near.submerged_at(p)


func triangle_count() -> int:
	return sheet.triangle_count() if sheet != null else 0
