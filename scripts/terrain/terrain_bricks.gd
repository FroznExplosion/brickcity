class_name TerrainBricks
extends Node3D
## THE BRICK OVERLAY (Docs/BrickOverlay.md 3): real bricks laid over the flat
## ground near the camera. The flat mesh is drawn everywhere, whole; here the
## bricks within `range_m` of the eye and in its view are drawn over it as
## ONE MultiMesh of bevelled boxes (BrickNear.bevel_box_mesh, scaled to each
## brick, the 13 mm bevel taken off in the shader: terrain.gdshader with
## `#define TERRAIN_BOX`). Nothing is baked: the instances are moved and
## retinted.
##
## The bricks are the bakes' own lists (TerrainTile.overlay, every drawn
## surface tile and deep section); BrickTerrain.overlay_pick dedupes them (a
## brick across a tile edge is in both tiles' lists), keeps those in range and
## in a cone a margin wider than the view, nearest first, up to `max_bricks`,
## and writes the MultiMesh buffer. Picked again when the eye moves `move_m`,
## turns `turn_deg`, or a tile changes (TerrainTile.overlay_version). Main
## thread, CPU arrays only: nothing read back from the renderer.
##
## A child of the mine world, at its origin: the lists are in its terrain
## frame, so the origin shift moves this with everything else.

## How far round the eye bricks are laid (metres, to the brick's box).
@export var range_m := 12.0
## The most instances drawn; past it the farthest are left out (and `far_m`
## says how far the overlay reached).
@export var max_bricks := 6000
## Degrees added round the view's half diagonal: turning, the bricks coming
## into view are already there for a pick or two.
@export var cone_margin_deg := 18.0
## Pick again when the eye has moved this far, or turned this many degrees.
@export var move_m := 0.35
@export var turn_deg := 4.0

## The mine world (untyped: it holds this).
var world: Node3D = null
var enabled := true

## Counters, for the readout and the gate.
var count := 0
var inside := 0
var seen := 0
var far_m := 0.0
var fills := 0
var fill_ms := 0.0
var worst_fill_ms := 0.0
var lists := 0
## The last pick's buffer as uploaded (CPU side, for the gate).
var buffer := PackedFloat32Array()

var _mmi: MultiMeshInstance3D = null
var _mm: MultiMesh = null
var _mat: ShaderMaterial = null
var _ground: ShaderMaterial = null
var _cap := 0
var _eye_at := Vector3.INF
var _fwd_at := Vector3.ZERO
var _version := -1
var _sync_in := 0.0
var _params: Array[StringName] = []

const STRIDE := 20
const CAP_STEP := 512

static var _box_shaders := {}


## terrain.gdshader with `#define TERRAIN_BOX` (and SKY_LIGHT when the
## ground has it), made once each.
static func box_shader(sky_light: bool) -> Shader:
	if not _box_shaders.has(sky_light):
		var code: String = (load("res://shaders/terrain.gdshader") as Shader).code
		var at := code.find("\n") + 1
		var s := Shader.new()
		s.code = code.insert(at, ("#define SKY_LIGHT\n" if sky_light else "") + "#define TERRAIN_BOX\n")
		_box_shaders[sky_light] = s
	return _box_shaders[sky_light]


## `ground`: the flat ground's material (TerrainTile.ground_material); the
## boxes draw with a copy of it, kept in step (`_sync`).
func setup(w: Node3D, ground: ShaderMaterial, sky_light: bool) -> void:
	world = w
	_ground = ground
	_mat = ground.duplicate() as ShaderMaterial
	_mat.shader = box_shader(sky_light)
	WeatherFx.register(_mat)
	for u in _mat.shader.get_shader_uniform_list():
		_params.append(StringName(u.name))
	_mm = MultiMesh.new()
	_mm.transform_format = MultiMesh.TRANSFORM_3D
	_mm.use_colors = true
	_mm.use_custom_data = true
	_mm.mesh = BrickNear.bevel_box_mesh()
	_mmi = MultiMeshInstance3D.new()
	_mmi.name = "Boxes"
	_mmi.multimesh = _mm
	_mmi.material_override = _mat
	# The ground casts no sun shadow in the mine world (mine_world.gd).
	_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_mmi.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	add_child(_mmi)


func set_enabled(on: bool) -> void:
	enabled = on
	if _mmi != null:
		_mmi.visible = on
	if not on and _ground != null:
		_ground.set_shader_parameter(&"overlay_reach", 0.0)
	_version = -1


## Pick again next frame whatever moved.
func refresh() -> void:
	_version = -1


func _process(delta: float) -> void:
	if world == null or _mm == null or not enabled:
		return
	# The camera drawing (a gate's own, or the walker's / the free one's).
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	_sync(delta)
	var eye: Vector3 = world.to_local(cam.global_position)
	var fwd: Vector3 = world.global_transform.basis.inverse() * -cam.global_transform.basis.z
	if _version == TerrainTile.overlay_version and eye.distance_to(_eye_at) < move_m \
			and fwd.dot(_fwd_at) > cos(deg_to_rad(turn_deg)):
		return
	fill(eye, fwd, cam)


## Pick and upload now.
func fill(eye: Vector3, fwd: Vector3, cam: Camera3D) -> void:
	var t0 := Time.get_ticks_usec()
	_version = TerrainTile.overlay_version
	_eye_at = eye
	_fwd_at = fwd
	var half := _half_view(cam) + deg_to_rad(cone_margin_deg)
	var tile_m := float(BrickTerrain.get_tile_studs()) * BrickWorld.get_stud_metres()
	var src: Array = []
	for t in TerrainTile.overlay_tiles.values():
		var tile := t as TerrainTile
		if tile == null or tile.overlay.is_empty() or not tile.is_visible_in_tree():
			continue
		# Its footprint (XZ) within reach of the eye.
		var o: Vector3 = world.to_local(tile.global_position)
		var dx := maxf(maxf(o.x - eye.x, eye.x - (o.x + tile_m)), 0.0)
		var dz := maxf(maxf(o.z - eye.z, eye.z - (o.z + tile_m)), 0.0)
		if dx * dx + dz * dz > range_m * range_m:
			continue
		src.append(tile.overlay)
	lists = src.size()
	var r: Dictionary = BrickTerrain.overlay_pick(src, eye, fwd, range_m, cos(minf(half, PI)), max_bricks)
	count = int(r.count)
	inside = int(r.inside)
	seen = int(r.seen)
	far_m = float(r.far_m)
	var buf: PackedFloat32Array = r.buffer
	if count > _cap or count < _cap - 4 * CAP_STEP:
		_cap = maxi(CAP_STEP, ceili(float(count) / CAP_STEP) * CAP_STEP)
		_mm.instance_count = 0
		_mm.use_colors = true
		_mm.use_custom_data = true
		_mm.instance_count = _cap
	if buf.size() < _cap * STRIDE:
		buf.resize(_cap * STRIDE)
	_mm.buffer = buf
	buffer = buf
	_mm.visible_instance_count = count
	# The flat ground sinks under the boxes as far as they reach from here,
	# less the walk before the next pick (terrain.gdshader overlay_reach).
	_ground.set_shader_parameter(&"overlay_reach", maxf(far_m - move_m, 0.0) if count > 0 else 0.0)
	fills += 1
	fill_ms = float(Time.get_ticks_usec() - t0) / 1000.0
	worst_fill_ms = maxf(worst_fill_ms, fill_ms)


## The view's half angle to its corner (radians).
func _half_view(cam: Camera3D) -> float:
	var size := get_viewport().get_visible_rect().size if get_viewport() != null else Vector2(16, 9)
	var aspect := size.x / maxf(size.y, 1.0)
	var tv := tan(deg_to_rad(cam.fov) * 0.5)
	var th := tv * aspect
	if cam.keep_aspect == Camera3D.KEEP_WIDTH:
		th = tv
		tv = th / aspect
	return atan(sqrt(tv * tv + th * th))


## The ground material's parameters copied over: the sun each frame, the rest
## once a second (the dev menu's toggles).
func _sync(delta: float) -> void:
	if _ground == null:
		return
	_mat.set_shader_parameter(&"sun_dir", _ground.get_shader_parameter(&"sun_dir"))
	_sync_in -= delta
	if _sync_in > 0.0:
		return
	_sync_in = 1.0
	for p in _params:
		if p == &"overlay_reach":
			continue
		var v = _ground.get_shader_parameter(p)
		if v != null:
			_mat.set_shader_parameter(p, v)


func readout() -> String:
	return "overlay bricks %d of %d in reach (%d read, %d lists), to %.1f m, fill %.2f ms (worst %.2f)" \
			% [count, inside, seen, lists, far_m, fill_ms, worst_fill_ms]
