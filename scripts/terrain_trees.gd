class_name TerrainTrees
extends Node3D

## The trees of a heightfield scene (the terrain test and the terrain editor),
## for looking at: the same trees in the same places as the city grows
## (Trees.scatter from the same seed), drawn the same way (ImpostorLod: real
## bricks near, octahedral cards far), but not registered as buildings -- this
## scene has no brick world to shoot them in. Docs/Impostors.md 8.
##
## Re-scattered when the ground changes under them, a moment after the last
## edit rather than on every stroke of the brush.

const MAX_TREES := 6000
## Frames between tier passes: several thousand trees is several milliseconds
## of distance checks, and nobody crosses 45 m in a sixth of a second.
const UPDATE_EVERY := 10
const REBUILD_AFTER := 0.5

var camera: Camera3D
var material: Material
var rect := Rect2i()
var world_seed := 0
var count := 0

var _sets := {}
var _frame := 0
var _rebuild_in := -1.0


func setup(p_camera: Camera3D, p_material: Material) -> void:
	camera = p_camera
	material = p_material


func build(p_rect: Rect2i, p_seed: int) -> void:
	rect = p_rect
	world_seed = p_seed
	for s in _sets.values():
		(s as Node).queue_free()
	_sets.clear()
	var t0 := Time.get_ticks_usec()
	var spots: Array = Trees.scatter(rect, world_seed, MAX_TREES)
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
			s.setup(tree_mesh, material, 45.0)
			_sets[key] = s
		(_sets[key] as ImpostorLod).add(Trees.placement(spot.cell, variant))
	count = spots.size()
	print("[trees] %d scattered in %.0f ms" % [count, float(Time.get_ticks_usec() - t0) / 1000.0])
	_update()


## The ground changed: scatter again once the edits stop.
func rebuild_soon() -> void:
	_rebuild_in = REBUILD_AFTER


func _process(delta: float) -> void:
	if _rebuild_in >= 0.0:
		_rebuild_in -= delta
		if _rebuild_in < 0.0:
			build(rect, world_seed)
	_frame += 1
	if _frame % UPDATE_EVERY == 0:
		_update()


func _update() -> void:
	if camera == null:
		return
	var here := camera.global_position
	for s in _sets.values():
		(s as ImpostorLod).update(here)
