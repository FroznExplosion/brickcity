class_name TerrainTrees
extends Node3D

## The trees of a heightfield scene (the terrain test and the terrain editor),
## for looking at: the same trees in the same places as the city grows
## (Trees.scatter from the same seed), drawn the same way (ImpostorLod: real
## bricks near, octahedral cards far), but not registered as buildings -- this
## scene has no brick world to shoot them in. Docs/Impostors.md 8.
##
## Re-placed when the ground changes under them, a moment after the last
## edit rather than on every stroke of the brush -- and only where it changed.
##
## The ImpostorLod sets are KEPT across a rebuild: a new set has no baked
## card, and until it bakes every one of its trees is drawn at full detail.
## Re-making them on every edit was 9 million triangles for a couple of
## seconds after each tool switch or brush stroke.

const MAX_TREES := 6000
## Frames between tier passes: several thousand trees is several milliseconds
## of distance checks, and nobody crosses 45 m in a sixth of a second.
const UPDATE_EVERY := 10
const REBUILD_AFTER := 0.5
## The ImpostorLod square for trees. 6,000 cards over a kilometre and a half
## in 128 m squares were ~1,470 draw calls from the editor's height (two
## MultiMeshes a square a kind, and their shadow passes).
static var chunk_metres := 512.0

var camera: Camera3D
var material: Material
var rect := Rect2i()
var world_seed := 0
var count := 0

var _sets := {}
## One row per tree placed: {key, handle, x, z}.
var _placed: Array[Dictionary] = []
var _frame := 0
var _rebuild_in := -1.0
## Where the ground changed since the last rebuild; empty with `_rebuild_all`
## for a change that could be anywhere (a site moved, a pad cut).
var _pending := Rect2i()
var _rebuild_all := false
## Where each set was last sorted into tiers from, by key. A set is sorted
## again only once the camera has moved a metre from there, and the sets take
## turns, one a frame: a pass over all 6000 trees was 3.8 ms every tenth frame.
var _sorted_at := {}
var _turn := 0
const RESORT_METRES := 1.0


func setup(p_camera: Camera3D, p_material: Material) -> void:
	camera = p_camera
	material = p_material


func build(p_rect: Rect2i, p_seed: int) -> void:
	rect = p_rect
	world_seed = p_seed
	var t0 := Time.get_ticks_usec()
	_clear_placed(Rect2i())
	_place(Trees.scatter(rect, world_seed, MAX_TREES))
	count = _placed.size()
	print("[trees] %d scattered in %.0f ms" % [count, float(Time.get_ticks_usec() - t0) / 1000.0])
	_update()


## The ground changed: place again once the edits stop. `studs` is where;
## empty means anywhere.
func rebuild_soon(studs := Rect2i()) -> void:
	_rebuild_in = REBUILD_AFTER
	if not studs.has_area():
		_rebuild_all = true
	else:
		_pending = studs if not _pending.has_area() else _pending.merge(studs)


func _rebuild() -> void:
	if _rebuild_all:
		_rebuild_all = false
		_pending = Rect2i()
		build(rect, world_seed)
		return
	if not _pending.has_area():
		return
	var t0 := Time.get_ticks_usec()
	# Out to the scatter's lattice, so every tree whose cell is in the area
	# is taken away and Trees.scatter puts back exactly those cells.
	var sp: int = Trees.SPACING
	var lo := Vector2i(floori(float(_pending.position.x) / sp) * sp,
			floori(float(_pending.position.y) / sp) * sp)
	var hi := Vector2i(ceili(float(_pending.end.x) / sp) * sp,
			ceili(float(_pending.end.y) / sp) * sp)
	var area := Rect2i(lo, hi - lo).intersection(rect)
	_pending = Rect2i()
	if not area.has_area():
		return
	var gone := _clear_placed(area)
	var spots: Array = Trees.scatter(area, world_seed, MAX_TREES)
	_place(spots)
	count = _placed.size()
	print("[trees] %d re-placed (%d before) in %.0f ms" % [spots.size(), gone,
			float(Time.get_ticks_usec() - t0) / 1000.0])
	_update()


## Take away the trees standing in `area` (every tree when it is empty).
## Returns how many.
func _clear_placed(area: Rect2i) -> int:
	var kept: Array[Dictionary] = []
	var gone := 0
	for row in _placed:
		if area.has_area() and not area.has_point(Vector2i(row.x, row.z)):
			kept.append(row)
			continue
		(_sets[row.key] as ImpostorLod).remove(int(row.handle))
		gone += 1
	_placed = kept
	return gone


func _place(spots: Array) -> void:
	for spot in spots:
		var variant: int = spot.variant
		var key := "tree_%d" % variant
		if not _sets.has(key):
			var s := ImpostorLod.new()
			s.name = "Trees_%d" % variant
			add_child(s)
			var tree_mesh := RecipeMesh.build(Trees.recipe(variant), key)
			# Its crowns move in the wind (weather.gdshaderinc).
			if tree_mesh != null:
				s.sway = WeatherFx.sway_tree(tree_mesh.get_aabb().end.y)
			s.snowcap = 1.0   # snow on the crowns
			s.set_chunk(chunk_metres)
			s.setup(tree_mesh, material, 45.0)
			_sets[key] = s
		var cell: Vector3i = spot.cell
		var h := (_sets[key] as ImpostorLod).add(Trees.placement(cell, variant))
		_placed.append({"key": key, "handle": h, "x": cell.x, "z": cell.z})


func _process(delta: float) -> void:
	if _rebuild_in >= 0.0:
		_rebuild_in -= delta
		if _rebuild_in < 0.0:
			_rebuild()
	_frame += 1
	if camera == null or _sets.is_empty() or _frame % UPDATE_EVERY >= _sets.size():
		return
	# One set on each of the first frames of every UPDATE_EVERY.
	var keys := _sets.keys()
	var key: String = keys[_turn % keys.size()]
	_turn += 1
	var here := camera.global_position
	var was: Vector3 = _sorted_at.get(key, Vector3.INF)
	if was.distance_to(here) < RESORT_METRES:
		return
	_sorted_at[key] = here
	(_sets[key] as ImpostorLod).update(here)


## Every set, now: after trees were added or taken away.
func _update() -> void:
	if camera == null:
		return
	var here := camera.global_position
	for key in _sets:
		(_sets[key] as ImpostorLod).update(here)
		_sorted_at[key] = here
