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

## Pitch of this tier's pieces, in metres.
var _pitch := STUD

@export var radius := 20.0
## Tall waves are the point of the brick step: a 3 m swell is seven steps
## rather than a ramp needing more vertices. The shore taper is what stops
## them driving through the beach.
##
## Pushed into `BrickWave` rather than into the shader, because the shader is
## not allowed its own copy of anything the buoyancy solver also needs.
@export var wave_gain := 2.2
## Snap the pieces to brick courses instead of letting them bob smoothly.
## Off: the sea is 1x1 bricks riding the wave, level and flat-topped, each at
## its own exact height. See the shader for why the grid does not win here.
@export var brick_steps := false

## Studs per piece. 1 is tier 0 — real 1x1 bricks. Tier 1 runs 4, where a
## stud is under a pixel anyway and 1x1s would cost sixteen times the
## instances for detail nobody can see.
@export var pitch_studs := 1
## Nothing is drawn inside this radius. Tier 1 sets it to just under tier 0's
## radius, so the fine sheet covers the join.
@export var inner_radius := 0.0
## Painted studs. Off: the water is flat-topped brick.
@export var studs := false
## Give the surface near the camera real collision, so a dropped brick rests
## on a crest instead of being pushed by a force (Water §7.1).
@export var collide := true

var _mat: ShaderMaterial = null
var _side := 0
var _time := 0.0
var _camera_y := 0.0
const WaterColliderFx := preload("res://scripts/water_collider.gd")
var _collider = null


func _ready() -> void:
	_pitch = STUD * float(pitch_studs)
	_side = int(ceil(radius * 2.0 / _pitch))
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
	# Before uniform_array(), which bakes the gain into the amplitudes.
	BrickWave.set_wave_gain(wave_gain)
	_mat.set_shader_parameter("waves", BrickWave.uniform_array())
	_mat.set_shader_parameter("wave_count", BrickWave.component_count())
	_mat.set_shader_parameter("groups", BrickWave.group_uniform_array())
	_mat.set_shader_parameter("group_count", BrickWave.group_uniform_array().size() >> 1)
	_mat.set_shader_parameter("shore_band", BrickWave.shore_band_uniform())
	_mat.set_shader_parameter("swell_blend", BrickWave.swell_blend_uniform())
	_mat.set_shader_parameter("sea_level", BrickWave.get_sea_level())
	_mat.set_shader_parameter("step_m", BrickWave.get_step_metres())
	_mat.set_shader_parameter("stud", _pitch)
	_mat.set_shader_parameter("inner_radius", inner_radius)
	_mat.set_shader_parameter("studs_enabled", studs)
	_mat.set_shader_parameter("shore_taper_depth", BrickWave.get_shore_taper_depth())
	set_brick_steps(brick_steps)
	_mat.set_shader_parameter("grid_side", _side)
	# Past the edge of the seabed map is OPEN SEA, not dry land: it was dry,
	# so from the world's edge looking out the water sank out of sight.
	_mat.set_shader_parameter("water_outside_field", true)
	_mat.set_shader_parameter("fade_radius", radius)
	material_override = _mat

	# A brick-thick moving surface casting a shadow map is not worth what it
	# costs, and the ground under it is already dark from depth colour.
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# The instances are placed in the vertex shader, so Godot's own culling
	# sees an empty AABB and throws the whole thing away.
	custom_aabb = AABB(Vector3(-radius, -40.0, -radius),
		Vector3(radius * 2.0, 80.0, radius * 2.0))

	if collide:
		_collider = WaterColliderFx.new()
		_collider.name = "WaterCollision"
		add_child(_collider)
		_collider.setup(get_world_3d().space)


## The ground height in metres over a world rectangle, as an Rf image.
## Water.md §5: one texture, two jobs — cull dry land, and drive the
## absorption colour without alpha or a depth prepass.
func set_seabed(tex: Texture2D, origin: Vector2, extent: Vector2) -> void:
	_mat.set_shader_parameter("seabed_tex", tex)
	_mat.set_shader_parameter("seabed_origin", origin)
	_mat.set_shader_parameter("seabed_extent", extent)


## Stepped and stop-motion go together: a 12 Hz hold on a continuous height
## is a stutter, on a quantised one it is the brick-film look.
func set_brick_steps(on: bool) -> void:
	brick_steps = on
	_mat.set_shader_parameter("brick_steps", on)
	_mat.set_shader_parameter("hold_seconds", 0.08 if on else 0.0)


func set_print_lines(on: bool) -> void:
	_mat.set_shader_parameter("print_lines_enabled", on)


func instance_count() -> int:
	return _side * _side


## Called every frame with the camera position. Two uniform writes.
## Is the camera under the surface? The shader collapses the columns when it
## is — a tall column seen from below is a wall of brick sides filling the
## view, which is the one real objection to tall water.
func submerged_at(p: Vector3) -> bool:
	return p.y < surface_at(p)


## The CONTINUOUS surface at a world point, which is what gameplay asks for.
##
## With smooth bobbing this is also exactly what is DRAWN, so the swimmer and
## the pieces agree to the float — the 0.42 m disagreement that `stepped_at`
## existed to describe only comes back if `brick_steps` is turned on.
func surface_at(p: Vector3) -> float:
	return BrickWave.height_at(p.x, p.z, _time)


func follow(camera_xz: Vector2, delta: float, camera_y: float = 0.0) -> void:
	_camera_y = camera_y
	_time += delta
	# Snap to the stud lattice, so the pieces stay on the world grid rather
	# than crawling with the camera. This is what keeps a floating brick and
	# the water's studs on the same integer lattice (D5).
	# Snapped to this TIER's pitch, and to the global lattice either way: a
	# coarse piece has to land on a multiple of its own size or the two
	# sheets slide against each other as the camera moves.
	var origin_xz := Vector2(
		round(camera_xz.x / _pitch) * _pitch,
		round(camera_xz.y / _pitch) * _pitch)
	_mat.set_shader_parameter("snapped_origin", origin_xz)
	# The culling box goes WITH the pieces. They are placed in the vertex
	# shader round the camera, but the box was set once round the world's
	# origin: away from it the engine culled the whole tier whenever that
	# box was off screen -- the near water vanishing, and coming back when
	# the camera turned toward the origin.
	var sea := BrickWave.get_sea_level()
	custom_aabb = AABB(Vector3(origin_xz.x - radius, sea - 40.0, origin_xz.y - radius),
		Vector3(radius * 2.0, 80.0, radius * 2.0))
	_mat.set_shader_parameter("wave_time", _time)
	_mat.set_shader_parameter("camera_submerged",
			submerged_at(Vector3(camera_xz.x, _camera_y, camera_xz.y)))
	if _collider != null:
		_collider.follow(camera_xz, _time, delta)
	global_position = Vector3.ZERO


func set_lod_debug(on: bool) -> void:
	if _mat != null:
		_mat.set_shader_parameter("lod_debug", on)


## The middle of this tier for a camera: its pieces are alive within
## `radius` of here (the sheet's hole).
func centre_for(camera_xz: Vector2) -> Vector2:
	return Vector2(round(camera_xz.x / _pitch) * _pitch, round(camera_xz.y / _pitch) * _pitch)


func time() -> float:
	return _time
