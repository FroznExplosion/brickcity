class_name CollapseDust
extends RefCounted

## A cloud of dust where a big building gives way (CollapseDirector). A
## placeholder: the effects area owns how destruction looks, and this is here so
## a collapse across the city reads as one before that lands. Presentation only,
## each machine its own, one draw call a cloud, simulated on the GPU
## (Docs/GpuOffload.md 2.2; it was CPUParticles3D, on the main thread).

const LIFETIME := 3.5

static var _mesh: QuadMesh


## A cloud about `size` metres across at `at`, freed once it has faded.
static func puff(parent: Node, at: Vector3, size: float) -> void:
	if parent == null or not parent.is_inside_tree():
		return
	var p := GPUParticles3D.new()
	p.one_shot = true
	p.explosiveness = 0.85
	p.amount = 24
	p.lifetime = LIFETIME
	p.local_coords = true   # it never moves
	p.draw_pass_1 = _quad()
	var reach := maxf(size, 2.0) + 12.0
	p.visibility_aabb = AABB(-Vector3.ONE * reach, Vector3.ONE * reach * 2.0)
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = maxf(size * 0.5, 1.0)
	pm.direction = Vector3.UP
	pm.spread = 70.0
	pm.initial_velocity_min = 0.5
	pm.initial_velocity_max = 2.5
	pm.gravity = Vector3(0.0, -0.4, 0.0)
	pm.damping_min = 0.6
	pm.damping_max = 1.2
	pm.scale_min = clampf(size * 0.4, 2.0, 6.0)
	pm.scale_max = clampf(size * 0.8, 3.0, 12.0)
	pm.color_ramp = _ramp()
	p.process_material = pm
	p.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	parent.add_child(p)
	p.global_position = at
	p.emitting = true
	parent.get_tree().create_timer(LIFETIME + 0.5).timeout.connect(p.queue_free)


static var _fade: GradientTexture1D


static func _ramp() -> GradientTexture1D:
	if _fade == null:
		var ramp := Gradient.new()
		ramp.set_color(0, Color(0.62, 0.59, 0.55, 0.55))
		ramp.set_color(1, Color(0.62, 0.59, 0.55, 0.0))
		_fade = GradientTexture1D.new()
		_fade.gradient = ramp
	return _fade


static func _quad() -> QuadMesh:
	if _mesh == null:
		_mesh = QuadMesh.new()
		_mesh.size = Vector2.ONE
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
		# Without it a particle billboard drops its scale, and a cloud of 6-12 m
		# puffs drew as two dozen hard 1 m squares hanging where the building
		# had been -- read as bits of the interior left floating in the air.
		mat.billboard_keep_scale = true
		# A soft round puff, not a square.
		var soft := GradientTexture2D.new()
		soft.fill = GradientTexture2D.FILL_RADIAL
		soft.fill_from = Vector2(0.5, 0.5)
		soft.fill_to = Vector2(1.0, 0.5)
		var fall := Gradient.new()
		fall.set_color(0, Color(1.0, 1.0, 1.0, 1.0))
		fall.set_color(1, Color(1.0, 1.0, 1.0, 0.0))
		soft.gradient = fall
		soft.width = 64
		soft.height = 64
		mat.albedo_texture = soft
		mat.vertex_color_use_as_albedo = true
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		_mesh.material = mat
	return _mesh
