class_name CollapseDust
extends RefCounted

## A cloud of dust where a big building gives way (CollapseDirector). A
## placeholder: the effects area owns how destruction looks, and this is here so
## a collapse across the city reads as one before that lands. Presentation only,
## each machine its own, one draw call a cloud.

const LIFETIME := 3.5

static var _mesh: QuadMesh


## A cloud about `size` metres across at `at`, freed once it has faded.
static func puff(parent: Node, at: Vector3, size: float) -> void:
	if parent == null or not parent.is_inside_tree():
		return
	var p := CPUParticles3D.new()
	p.one_shot = true
	p.explosiveness = 0.85
	p.amount = 24
	p.lifetime = LIFETIME
	p.mesh = _quad()
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	p.emission_sphere_radius = maxf(size * 0.5, 1.0)
	p.direction = Vector3.UP
	p.spread = 70.0
	p.initial_velocity_min = 0.5
	p.initial_velocity_max = 2.5
	p.gravity = Vector3(0.0, -0.4, 0.0)
	p.damping_min = 0.6
	p.damping_max = 1.2
	p.scale_amount_min = clampf(size * 0.4, 2.0, 6.0)
	p.scale_amount_max = clampf(size * 0.8, 3.0, 12.0)
	var ramp := Gradient.new()
	ramp.set_color(0, Color(0.62, 0.59, 0.55, 0.55))
	ramp.set_color(1, Color(0.62, 0.59, 0.55, 0.0))
	p.color_ramp = ramp
	p.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	parent.add_child(p)
	p.global_position = at
	p.emitting = true
	parent.get_tree().create_timer(LIFETIME + 0.5).timeout.connect(p.queue_free)


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
