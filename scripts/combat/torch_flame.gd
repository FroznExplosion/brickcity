class_name TorchFlame
extends GPUParticles3D
## The thermal torch's flame (GunController, GunAltFire.TORCH): a tongue of corrosive
## fire out of the muzzle down the aim, as long as the torch reaches (TORCH_RANGE) and as
## wide as its cone. Bright yellow-green at the nozzle, darkening to a sickly green as it
## rises and goes. World-space particles, so a swung torch leaves its fire behind it.
## GunController moves it to the muzzle every tick it burns and puts it out after.
## GPU particles (Docs/GpuOffload.md 2.2): 220 of them were stepped on the main
## thread every frame it burned.

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
	# Down its -Z, up to as far as it reaches, and the smoke rising off it.
	f.visibility_aabb = AABB(Vector3(-3.5, -3.0, -9.0), Vector3(7.0, 7.0, 10.0))
	var pm := ParticleProcessMaterial.new()
	pm.direction = Vector3(0.0, 0.0, -1.0)
	pm.spread = 9.0
	pm.initial_velocity_min = SPEED * 0.9
	pm.initial_velocity_max = SPEED * 1.1
	pm.gravity = Vector3(0.0, 2.5, 0.0)
	pm.damping_min = 11.0
	pm.damping_max = 15.0
	pm.angle_min = 0.0
	pm.angle_max = 360.0
	pm.angular_velocity_min = -180.0
	pm.angular_velocity_max = 180.0
	pm.scale_min = 0.7
	pm.scale_max = 1.2
	var grow := Curve.new()
	grow.add_point(Vector2(0.0, 0.15))
	grow.add_point(Vector2(0.3, 0.8))
	grow.add_point(Vector2(1.0, 2.6))
	pm.scale_curve = _curve(grow)
	var ramp := Gradient.new()
	# Dim at the nozzle (it overlaps itself most there, and in first person it is right
	# under the crosshair), brightest a metre or two out, then dark green smoke.
	ramp.set_color(0, Color(1.0, 0.95, 0.6, 0.3))
	ramp.set_color(1, Color(0.16, 0.06, 0.03, 0.0))
	ramp.add_point(0.2, Color(1.0, 0.6, 0.15, 0.6))
	ramp.add_point(0.55, Color(0.6, 0.2, 0.05, 0.45))
	pm.color_ramp = _ramp(ramp)
	f.process_material = pm
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
	f.draw_pass_1 = quad
	f.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# The core: a short, narrow, bright jet out of the nozzle, so the fire has a source.
	var core := GPUParticles3D.new()
	core.name = "Core"
	core.amount = 50
	core.lifetime = 0.14
	core.local_coords = false
	core.visibility_aabb = AABB(Vector3(-1.0, -1.0, -3.5), Vector3(2.0, 2.0, 4.5))
	var cpm := ParticleProcessMaterial.new()
	cpm.direction = Vector3(0.0, 0.0, -1.0)
	cpm.spread = 3.0
	cpm.initial_velocity_min = SPEED
	cpm.initial_velocity_max = SPEED * 1.1
	cpm.gravity = Vector3.ZERO
	var shrink := Curve.new()
	shrink.add_point(Vector2(0.0, 0.5))
	shrink.add_point(Vector2(1.0, 1.0))
	cpm.scale_curve = _curve(shrink)
	var core_ramp := Gradient.new()
	core_ramp.set_color(0, Color(1.0, 0.98, 0.8, 0.4))
	core_ramp.set_color(1, Color(1.0, 0.7, 0.3, 0.0))
	cpm.color_ramp = _ramp(core_ramp)
	core.process_material = cpm
	var cq := QuadMesh.new()
	cq.size = Vector2(0.18, 0.18)
	var core_mat := mat.duplicate() as StandardMaterial3D
	core_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	cq.material = core_mat
	core.draw_pass_1 = cq
	core.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	core.emitting = false
	f.add_child(core)
	var light := OmniLight3D.new()
	light.name = "Glow"
	light.light_color = Color(1.0, 0.6, 0.25)
	light.light_energy = 0.0
	light.omni_range = 4.0
	light.position = Vector3(0.0, 0.0, -1.5)
	f.add_child(light)
	return f


## On, at `from` facing along `basis`'s -Z; or out.
func burn(on: bool, from := Vector3.ZERO, basis := Basis.IDENTITY) -> void:
	# Placed first: lit, its first fire comes from where it is now.
	if on:
		global_transform = Transform3D(basis, from)
	emitting = on
	var core := get_node_or_null(^"Core") as GPUParticles3D
	if core != null:
		core.emitting = on
	var glow := get_node_or_null(^"Glow") as OmniLight3D
	if glow != null:
		glow.light_energy = 1.4 if on else 0.0


static func _curve(c: Curve) -> CurveTexture:
	var t := CurveTexture.new()
	t.curve = c
	return t


static func _ramp(g: Gradient) -> GradientTexture1D:
	var t := GradientTexture1D.new()
	t.gradient = g
	return t


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
