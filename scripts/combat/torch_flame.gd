class_name TorchFlame
extends CPUParticles3D
## The thermal torch's flame (GunController, GunAltFire.TORCH): a tongue of corrosive
## fire out of the muzzle down the aim, as long as the torch reaches (TORCH_RANGE) and as
## wide as its cone. Bright yellow-green at the nozzle, darkening to a sickly green as it
## rises and goes. World-space particles, so a swung torch leaves its fire behind it.
## GunController moves it to the muzzle every tick it burns and puts it out after.

const LIFE := 0.5
const SPEED := 15.0


static func make() -> TorchFlame:
	var f := TorchFlame.new()
	f.name = "TorchFlame"
	f.top_level = true
	f.emitting = false
	f.amount = 170
	f.lifetime = LIFE
	f.local_coords = false
	f.explosiveness = 0.0
	f.randomness = 0.4
	f.direction = Vector3(0.0, 0.0, -1.0)
	f.spread = 9.0
	f.initial_velocity_min = SPEED * 0.9
	f.initial_velocity_max = SPEED * 1.1
	f.gravity = Vector3(0.0, 2.5, 0.0)
	f.damping_min = 11.0
	f.damping_max = 15.0
	f.angle_min = 0.0
	f.angle_max = 360.0
	f.angular_velocity_min = -180.0
	f.angular_velocity_max = 180.0
	f.scale_amount_min = 0.7
	f.scale_amount_max = 1.2
	var grow := Curve.new()
	grow.add_point(Vector2(0.0, 0.15))
	grow.add_point(Vector2(0.3, 0.8))
	grow.add_point(Vector2(1.0, 2.6))
	f.scale_amount_curve = grow
	var ramp := Gradient.new()
	# Dim at the nozzle (it overlaps itself most there, and in first person it is right
	# under the crosshair), brightest a metre or two out, then dark green smoke.
	ramp.set_color(0, Color(0.9, 1.0, 0.5, 0.3))
	ramp.set_color(1, Color(0.08, 0.16, 0.04, 0.0))
	ramp.add_point(0.2, Color(0.65, 0.95, 0.15, 0.6))
	ramp.add_point(0.55, Color(0.25, 0.55, 0.05, 0.45))
	f.color_ramp = ramp
	var quad := QuadMesh.new()
	quad.size = Vector2(0.55, 0.55)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	# Mixed, not added: added over a bright wall or sky it clips to white.
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_MIX
	mat.vertex_color_use_as_albedo = true
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.albedo_texture = _soft_dot()
	mat.no_depth_test = false
	quad.material = mat
	f.mesh = quad
	f.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# The core: a short, narrow, bright jet out of the nozzle, so the fire has a source.
	var core := CPUParticles3D.new()
	core.name = "Core"
	core.amount = 50
	core.lifetime = 0.14
	core.local_coords = false
	core.direction = Vector3(0.0, 0.0, -1.0)
	core.spread = 3.0
	core.initial_velocity_min = SPEED
	core.initial_velocity_max = SPEED * 1.1
	core.gravity = Vector3.ZERO
	var shrink := Curve.new()
	shrink.add_point(Vector2(0.0, 0.5))
	shrink.add_point(Vector2(1.0, 1.0))
	core.scale_amount_curve = shrink
	var core_ramp := Gradient.new()
	core_ramp.set_color(0, Color(0.95, 1.0, 0.7, 0.4))
	core_ramp.set_color(1, Color(0.7, 1.0, 0.35, 0.0))
	core.color_ramp = core_ramp
	var cq := QuadMesh.new()
	cq.size = Vector2(0.18, 0.18)
	var core_mat := mat.duplicate() as StandardMaterial3D
	core_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	cq.material = core_mat
	core.mesh = cq
	core.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	core.emitting = false
	f.add_child(core)
	var light := OmniLight3D.new()
	light.name = "Glow"
	light.light_color = Color(0.7, 1.0, 0.3)
	light.light_energy = 0.0
	light.omni_range = 4.0
	light.position = Vector3(0.0, 0.0, -1.5)
	f.add_child(light)
	return f


## On, at `from` facing along `basis`'s -Z; or out.
func burn(on: bool, from := Vector3.ZERO, basis := Basis.IDENTITY) -> void:
	emitting = on
	var core := get_node_or_null(^"Core") as CPUParticles3D
	if core != null:
		core.emitting = on
	var glow := get_node_or_null(^"Glow") as OmniLight3D
	if glow != null:
		glow.light_energy = 1.4 if on else 0.0
	if on:
		global_transform = Transform3D(basis, from)


## A round soft dot: each particle a puff, not a square.
static func _soft_dot() -> ImageTexture:
	var n := 32
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	for y in n:
		for x in n:
			var d := Vector2(x + 0.5 - n * 0.5, y + 0.5 - n * 0.5).length() / (n * 0.5)
			var a := clampf(1.0 - d, 0.0, 1.0)
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, a * a * (3.0 - 2.0 * a)))
	return ImageTexture.create_from_image(img)
