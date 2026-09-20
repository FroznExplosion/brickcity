class_name WaterSurface
extends MultiMeshInstance3D

## Water tier 0: real 1x1 round plates, 0–20 m, camera-following.
## [Docs/Water.md](../Docs/Water.md) §3.0.
##
## The wave itself lives in `BrickWave` (D1). The CPU's entire per-frame job
## here is two uniforms — the snapped grid origin and
## the wave time. It never touches the instance buffer after startup. Every
## instance's height, column depth and shore cull happen in the vertex shader,
## for the reason §3.4 measures out: a 20 m disc crossing brick steps is 1,180
## block events a tick if the pieces are really created and destroyed.
##
## Spec §4 asks for a 50 m radius at ~20k instances and those cannot both be
## true — a 50 m disc at 1x1 pitch is 64k instances and 1.4M triangles. 20 m is
## 10.3k and ~226k, which is affordable, and tier 1's stepped mesh takes over
## beyond it (not built in slice 1).

const STUD := 0.35

@export var radius := 20.0

var _mat: ShaderMaterial = null
var _side := 0
var _time := 0.0


func _ready() -> void:
	_side = int(ceil(radius * 2.0 / STUD))
	# Odd, so there is a cell centred on the camera and the snap is symmetric.
	if _side % 2 == 0:
		_side += 1

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = PieceMeshes.unit_plate()
	mm.instance_count = _side * _side
	# Every instance is written ONCE, with identity. The vertex shader places
	# it from INSTANCE_ID, so nothing here is ever rewritten -- that is the
	# whole point of §3.4.
	for i in mm.instance_count:
		mm.set_instance_transform(i, Transform3D.IDENTITY)
	multimesh = mm

	_mat = ShaderMaterial.new()
	_mat.shader = load("res://shaders/water.gdshader")
	_mat.set_shader_parameter("waves", BrickWave.uniform_array())
	_mat.set_shader_parameter("wave_count", BrickWave.component_count())
	_mat.set_shader_parameter("sea_level", BrickWave.get_sea_level())
	_mat.set_shader_parameter("step_m", BrickWave.get_step_metres())
	_mat.set_shader_parameter("stud", STUD)
	_mat.set_shader_parameter("seed", 20260919)
	_mat.set_shader_parameter("grid_side", _side)
	_mat.set_shader_parameter("fade_radius", radius)
	material_override = _mat

	# A brick-thick moving surface casting a shadow map is not worth what it
	# costs, and the ground under it is already dark from depth colour.
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# The instances are placed in the vertex shader, so Godot's own culling
	# sees an empty AABB and throws the whole thing away.
	custom_aabb = AABB(Vector3(-radius, -40.0, -radius),
		Vector3(radius * 2.0, 80.0, radius * 2.0))


## The ground height in metres over a world rectangle, as an Rf image.
## Water.md §5: one texture, two jobs — cull dry land, and drive the
## absorption colour without alpha or a depth prepass.
func set_seabed(tex: Texture2D, origin: Vector2, extent: Vector2) -> void:
	_mat.set_shader_parameter("seabed_tex", tex)
	_mat.set_shader_parameter("seabed_origin", origin)
	_mat.set_shader_parameter("seabed_extent", extent)


func instance_count() -> int:
	return _side * _side


## Called every frame with the camera position. Two uniform writes.
func follow(camera_xz: Vector2, delta: float) -> void:
	_time += delta
	# Snap to the stud lattice, so the pieces stay on the world grid rather
	# than crawling with the camera. This is what keeps a floating brick and
	# the water's studs on the same integer lattice (D5).
	var origin_xz := Vector2(
		round(camera_xz.x / STUD) * STUD,
		round(camera_xz.y / STUD) * STUD)
	_mat.set_shader_parameter("snapped_origin", origin_xz)
	_mat.set_shader_parameter("wave_time", _time)
	global_position = Vector3.ZERO


func time() -> float:
	return _time
