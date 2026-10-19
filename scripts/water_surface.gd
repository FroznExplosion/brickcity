class_name WaterSurface
extends MultiMeshInstance3D

## Water tier 0: real 1x1 round plates round the camera (and, at pitch 2,
## the 2x2 ring past them), drawn in culled chunks (Docs/Water.md §9.11).
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
## Pieces a side of one chunk. The pieces are drawn in square chunks, one
## MultiMesh each, so the engine's frustum culling drops the ones off screen:
## as one disc round the camera its box always held the camera and every
## piece went through the vertex shader -- five wave evaluations a vertex --
## including the two thirds of them behind it (2026-10-19).
const CHUNK_PIECES := 24
## [node, x offset in pieces, z offset, width, depth], one per chunk.
var _chunks: Array = []
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

	_mat = ShaderMaterial.new()
	_mat.shader = load("res://shaders/water.gdshader")
	# Before uniform_array(), which bakes the gain into the amplitudes.
	BrickWave.set_wave_gain(wave_gain)
	push_waves()
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
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_mat.set_shader_parameter("chunked", true)
	_build_chunks()

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


## The chunks: this node draws nothing itself. A chunk wholly outside the
## disc, or wholly inside `inner_radius`, is never made -- the square's
## corners were a fifth of the pieces, all dropped in the shader.
func _build_chunks() -> void:
	@warning_ignore("integer_division")
	var half := _side / 2
	var z := 0
	while z < _side:
		var x := 0
		var d := mini(CHUNK_PIECES, _side - z)
		while x < _side:
			var w := mini(CHUNK_PIECES, _side - x)
			# The chunk's nearest and farthest points from the middle, in
			# pieces; a piece of slack either way for the snap.
			var dx0 := float(x - half)
			var dx1 := float(x + w - 1 - half)
			var dz0 := float(z - half)
			var dz1 := float(z + d - 1 - half)
			var nx := 0.0 if dx0 <= 0.0 and dx1 >= 0.0 else minf(absf(dx0), absf(dx1))
			var nz := 0.0 if dz0 <= 0.0 and dz1 >= 0.0 else minf(absf(dz0), absf(dz1))
			var fx := maxf(absf(dx0), absf(dx1))
			var fz := maxf(absf(dz0), absf(dz1))
			var near_m := Vector2(nx, nz).length() * _pitch - _pitch
			var far_m := Vector2(fx, fz).length() * _pitch + _pitch
			if near_m < radius and far_m >= inner_radius:
				_add_chunk(x, z, w, d)
			x += CHUNK_PIECES
		z += CHUNK_PIECES


func _add_chunk(x: int, z: int, w: int, d: int) -> void:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = PieceMeshes.unit_plate()
	mm.instance_count = w * d
	# Every instance is written ONCE: identity, and its cell in the grid. The
	# vertex shader places it from that, so nothing here is ever rewritten --
	# that is the whole point of §3.4.
	for i in mm.instance_count:
		mm.set_instance_transform(i, Transform3D.IDENTITY)
		@warning_ignore("integer_division")
		mm.set_instance_custom_data(i, Color(float(x + i % w), float(z + i / w), 0.0, 0.0))
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "Chunk_%d_%d" % [x, z]
	mmi.multimesh = mm
	mmi.material_override = _mat
	# A brick-thick moving surface casting a shadow map is not worth what it
	# costs, and the ground under it is already dark from depth colour.
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mmi)
	_chunks.append([mmi, x, z, w, d])
	_place_chunk(_chunks.back(), Vector2.ZERO)


## A chunk's culling box, round where its pieces are for this grid origin.
## The pieces are placed in the vertex shader, so without it Godot's culling
## sees an empty box and throws the chunk away.
func _place_chunk(c: Array, origin_xz: Vector2) -> void:
	@warning_ignore("integer_division")
	var half := _side / 2
	var x0 := origin_xz.x + (float(int(c[1]) - half) - 0.5) * _pitch
	var z0 := origin_xz.y + (float(int(c[2]) - half) - 0.5) * _pitch
	var sea := BrickWave.get_sea_level()
	(c[0] as MultiMeshInstance3D).custom_aabb = AABB(Vector3(x0, sea - 40.0, z0),
			Vector3(float(int(c[3])) * _pitch, 80.0, float(int(c[4])) * _pitch))


## Pieces actually built (the chunks'), not the square they came from.
func instance_count() -> int:
	var n := 0
	for c in _chunks:
		n += int(c[3]) * int(c[4])
	return n


func chunk_count() -> int:
	return _chunks.size()


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
	for c in _chunks:
		_place_chunk(c, origin_xz)
	_mat.set_shader_parameter("wave_time", _time)
	_mat.set_shader_parameter("camera_submerged",
			submerged_at(Vector3(camera_xz.x, _camera_y, camera_xz.y)))
	if _collider != null:
		_collider.follow(camera_xz, _time, delta)
	global_position = Vector3.ZERO


## The sea state into this tier's material, from BrickWave: at setup, and
## again whenever the dev menu changes it (Terrain.md 20.10).
func push_waves() -> void:
	if _mat == null:
		return
	_mat.set_shader_parameter("waves", BrickWave.uniform_array())
	_mat.set_shader_parameter("wave_count", BrickWave.component_count())
	_mat.set_shader_parameter("groups", BrickWave.group_uniform_array())
	_mat.set_shader_parameter("group_count", BrickWave.group_uniform_array().size() >> 1)
	_mat.set_shader_parameter("shore_band", BrickWave.shore_band_uniform())
	_mat.set_shader_parameter("swell_blend", BrickWave.swell_blend_uniform())
	_mat.set_shader_parameter("shore_calm", BrickWave.shore_calm_uniform())


func set_lod_debug(on: bool) -> void:
	if _mat != null:
		_mat.set_shader_parameter("lod_debug", on)


## The middle of this tier for a camera: its pieces are alive within
## `radius` of here (the sheet's hole).
func centre_for(camera_xz: Vector2) -> Vector2:
	return Vector2(round(camera_xz.x / _pitch) * _pitch, round(camera_xz.y / _pitch) * _pitch)


func time() -> float:
	return _time
