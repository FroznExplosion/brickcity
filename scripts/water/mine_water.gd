extends Node3D

## WATER AND LAVA in the mine world (Docs/MineWater.md, stage 2): drives
## BrickFluid and draws what it builds.
##
## - Every frame: tells BrickFluid where the player is (the sim ring) and lets
##   it start a tick on its worker when one is due (`update`, never a wait).
## - A finished tick's meshes are swapped into one MeshInstance3D per terrain
##   tile, recycled, never made per rebuild (7.1).
## - Lava meeting water hands back cells of rock: they are laid as terrain
##   edits here, through the host's `terrain_edited` like any block.
## - The host calls `terrain_changed` with every edit's result, so water reads
##   its ground again where a block was placed or a shot dug (4.3).
##
## The generated sea is off until stage 3 (the wave tiers draw it then).
##
## Preloaded by path, not named (see terrain_scene.gd).

const TILE_STUDS := 32

var host: Node = null
## The gate ticks the water itself (tick_now) so its pictures are the same
## every run.
var manual := false
var sim_radius_m := 90.0
## Tiles drawn, and the last tick's numbers for the HUD.
var drawn := 0
var rock_laid := 0

var _water_mat: ShaderMaterial
var _lava_mat: ShaderMaterial
var _tiles := {}                       ## Vector2i -> MeshInstance3D
var _spare: Array[MeshInstance3D] = []


func setup(p_host: Node, sea_m: float, near_tiles: int) -> void:
	host = p_host
	var shader: Shader = load("res://shaders/water_fluid.gdshader")
	_water_mat = ShaderMaterial.new()
	_water_mat.shader = shader
	_lava_mat = ShaderMaterial.new()
	_lava_mat.shader = shader
	_lava_mat.set_shader_parameter("lava", true)
	reset_world(sea_m, near_tiles)


## A new world: everything the last one had goes.
func reset_world(sea_m: float, near_tiles: int) -> void:
	BrickFluid.reset(sea_m, false)
	sim_radius_m = float(near_tiles + 2) * TILE_STUDS * BrickWorld.get_stud_metres()
	for t in _tiles.keys():
		_release(t)
	drawn = 0
	rock_laid = 0


func _exit_tree() -> void:
	# Joins a running tick and frees the sections.
	BrickFluid.reset(20.0, false)


func _process(delta: float) -> void:
	if host == null:
		return
	BrickFluid.set_centre(host._eye(), sim_radius_m)
	if manual:
		return
	if BrickFluid.update(delta):
		apply(BrickFluid.take())


## The gate's clock: `ticks` ticks now, then what they built.
func step(ticks: int) -> void:
	BrickFluid.tick_now(ticks)
	apply(BrickFluid.take())


func apply(res: Dictionary) -> void:
	for m in res.get("meshes", []):
		_show(m.tile, m.water, m.lava)
	var terr: PackedInt32Array = res.get("terrain", PackedInt32Array())
	for i in range(0, terr.size(), 4):
		var b := terr[i + 1]
		var lo := Vector3i(terr[i], b * 3, terr[i + 2])
		var hi := Vector3i(terr[i], b * 3 + 2, terr[i + 2])
		var r: Dictionary = BrickTerrain.fill_box(lo, hi, terr[i + 3], true)
		if int(r.get("changed", 0)) > 0:
			rock_laid += 1
			host.terrain_edited(r)


## An edit's result (fill_box, carve, clear_runs): its plate box.
func terrain_changed(res: Dictionary) -> void:
	if res.has("box_lo"):
		BrickFluid.terrain_changed(res.box_lo, res.box_hi)


func _show(tile: Vector2i, water: Array, lava: Array) -> void:
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
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, water)
		mesh.surface_set_material(mesh.get_surface_count() - 1, _water_mat)
	if not lava.is_empty():
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, lava)
		mesh.surface_set_material(mesh.get_surface_count() - 1, _lava_mat)


func _release(tile: Vector2i) -> void:
	var mi: MeshInstance3D = _tiles.get(tile)
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
	return "%d awake, %d tiles drawn, tick %.2f ms (%d cells), %d sections, %d rock" % [
			BrickFluid.active_count(), drawn, float(s.get("tick_ms", 0.0)),
			int(s.get("evals", 0)), BrickFluid.section_count(), rock_laid]
