extends Node3D

## POOLS: the water in dug ground, drawn. [Docs/Water.md](../Docs/Water.md) §12.
##
## BrickPools (C++) holds and flows the water; this node ticks it and keeps
## one mesh per pool tile that has water to draw. The sea is not here: it is
## infinite and drawn by its tiers (water_sea.gd). A hole dug in the beach
## below the sea fills from it -- through a breach, or seeping through the
## sand -- and the water in it is drawn by this.

const PoolShader := preload("res://shaders/water_pool.gdshader")

## How often the meshes of tiles whose water moved are rebuilt, seconds. The
## sim runs at 60 Hz; the drawn level steps a plate at a time, so 10 Hz is
## enough to see it rise.
const MESH_EVERY := 0.1

var _mat := ShaderMaterial.new()
## Vector2i tile -> MeshInstance3D.
var _nodes := {}
var _mesh_t := 0.0
## Triangles drawn, for the HUD and the probe.
var triangles := 0


func _init() -> void:
	_mat.shader = PoolShader


## Start over for a world: forget every pool, then fill the ones a loaded
## world's sculpt already dug -- full before anyone sees them.
func reset_for_world() -> void:
	for n in _nodes.values():
		(n as Node).queue_free()
	_nodes.clear()
	BrickPools.clear()
	BrickPools.scan_sculpt()
	BrickPools.settle(1200)
	refresh_meshes()


## The ground changed over these studs.
func ground_changed(studs: Rect2i) -> void:
	BrickPools.ground_changed(studs)


func tick(delta: float) -> void:
	BrickPools.tick(delta)
	_mesh_t += delta
	if _mesh_t >= MESH_EVERY:
		_mesh_t = 0.0
		refresh_meshes()


## Re-mesh every tile whose drawn water changed.
func refresh_meshes() -> void:
	for t in BrickPools.take_dirty_tiles():
		var tile := t as Vector2i
		var baked: Dictionary = BrickPools.build_mesh(tile.x, tile.y)
		var arrays: Array = baked["mesh"]
		var mi: MeshInstance3D = _nodes.get(tile)
		if arrays.is_empty():
			if mi != null:
				triangles -= int(mi.get_meta("tris", 0))
				mi.queue_free()
				_nodes.erase(tile)
			continue
		if mi == null:
			mi = MeshInstance3D.new()
			mi.name = "Pool_%d_%d" % [tile.x, tile.y]
			mi.material_override = _mat
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			add_child(mi)
			_nodes[tile] = mi
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		mi.mesh = mesh
		triangles += int(baked["triangle_count"]) - int(mi.get_meta("tris", 0))
		mi.set_meta("tris", int(baked["triangle_count"]))


## The pool's surface over a point: NAN where there is no pool (ask the sea),
## -INF where the ground is dug and dry.
func level_at(p: Vector3) -> float:
	return BrickPools.level_at(p.x, p.z)


func tile_count() -> int:
	return _nodes.size()
