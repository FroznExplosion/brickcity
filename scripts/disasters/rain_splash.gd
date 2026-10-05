class_name RainSplash
extends Node3D

## Rain that lands (Docs/Disasters.md 19): a disaster's rain stops on roofs and
## splashes where it meets the ground, the roofs and the water.
##
## Two parts, because one would not do:
##
##   * STOPPING. A GPUParticlesCollisionHeightField3D follows the camera and the
##     rain hides on contact with it -- so it does not fall through a roof and
##     on into the room below. But Godot draws that field from what casts
##     shadows, and the ground bakes its own and casts none: rain went straight
##     through it, and the field's splashes landed only on tree crowns.
##   * SPLASHING. So the splashes do not come from the collision. Every
##     REFRESH_S, RAYS physics rays straight down round the camera find where
##     drops are landing -- ground, roof, water, anything that collides -- and
##     a splash emitter fires from those points (EMISSION_SHAPE_POINTS): tiny
##     drops thrown up and out, gone in a quarter of a second. Its rate follows
##     the rain's.

const SIZE := Vector3(64.0, 60.0, 64.0)
const RAYS := 256
const REACH := 22.0               ## m round the camera the splashes are
const REFRESH_S := 0.2
const SPLASHES := 900

var rain: GPUParticles3D
var splash: GPUParticles3D
var points := 0                   ## last refresh: rays that found somewhere to land
## Where it landed, the last refresh: [point, normal]. What hail chips, and
## what the sounds play on.
var hits: Array = []
## The sound of it on what it hits (SurfaceSounds), or null for silence.
var sounds: SurfaceSounds = null
var ctx: DisasterContext = null
## Where it is raining, when that is not everywhere round the camera: (x, z,
## radius); radius 0 for everywhere. A waterspout's cell.
var area := Vector3.ZERO

var _proc: ParticleProcessMaterial
var _img: Image
var _tex: ImageTexture
var _next := 0.0
var _rng := RandomNumberGenerator.new()


## Make `rain` (with process material `proc`) stop on what it hits and splash.
## Adds itself under `parent`. Returns itself.
## `sound` "rain" or "hail" plays it on what it hits (SurfaceSounds); "" none.
static func add(p_rain: GPUParticles3D, proc: ParticleProcessMaterial, parent: Node3D,
		colour := Color(0.9, 0.94, 1.0, 0.9), sound := "", p_ctx: DisasterContext = null) -> RainSplash:
	var r := RainSplash.new()
	r.name = "RainSplash"
	r.rain = p_rain
	r.ctx = p_ctx
	parent.add_child(r)
	r._build(proc, colour)
	if sound != "" and p_ctx != null:
		r.sounds = SurfaceSounds.new()
		r.sounds.name = "Sounds"
		r.add_child(r.sounds)
		r.sounds.setup(sound)
	return r


func _build(rain_proc: ParticleProcessMaterial, colour: Color) -> void:
	var field := GPUParticlesCollisionHeightField3D.new()
	field.name = "RainField"
	field.size = SIZE
	field.resolution = GPUParticlesCollisionHeightField3D.RESOLUTION_512
	field.follow_camera_enabled = true
	field.update_mode = GPUParticlesCollisionHeightField3D.UPDATE_MODE_WHEN_MOVED
	add_child(field)
	rain_proc.collision_mode = ParticleProcessMaterial.COLLISION_HIDE_ON_CONTACT
	rain_proc.collision_use_scale = false
	rain.collision_base_size = 0.02

	_rng.seed = 0x5A1A5
	_img = Image.create(RAYS, 1, false, Image.FORMAT_RGBF)
	_tex = ImageTexture.create_from_image(_img)
	var drop_mat := StandardMaterial3D.new()
	drop_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	drop_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	drop_mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	drop_mat.vertex_color_use_as_albedo = true
	var drop := QuadMesh.new()
	drop.size = Vector2(0.06, 0.06)
	drop.material = drop_mat
	_proc = ParticleProcessMaterial.new()
	_proc.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_POINTS
	_proc.emission_point_texture = _tex
	_proc.emission_point_count = 0
	_proc.direction = Vector3.UP
	_proc.spread = 55.0
	_proc.initial_velocity_min = 1.0
	_proc.initial_velocity_max = 2.2
	_proc.gravity = Vector3(0.0, -9.8, 0.0)
	_proc.scale_min = 0.6
	_proc.scale_max = 1.4
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 1.0])
	g.colors = PackedColorArray([colour, Color(colour.r, colour.g, colour.b, 0.0)])
	var ramp := GradientTexture1D.new()
	ramp.gradient = g
	_proc.color_ramp = ramp
	splash = GPUParticles3D.new()
	splash.name = "Splashes"
	splash.amount = SPLASHES
	splash.lifetime = 0.28
	splash.local_coords = false
	splash.process_material = _proc
	splash.draw_pass_1 = drop
	splash.emitting = false
	splash.visibility_aabb = AABB(Vector3(-REACH - 5.0, -60.0, -REACH - 5.0),
			Vector3((REACH + 5.0) * 2.0, 120.0, (REACH + 5.0) * 2.0))
	add_child(splash)


func _physics_process(delta: float) -> void:
	if rain == null or not is_instance_valid(rain):
		return
	var on := rain.emitting and rain.amount_ratio > 0.05
	splash.emitting = on and points > 0
	splash.amount_ratio = rain.amount_ratio
	if not on:
		return
	if sounds != null:
		sounds.step(delta, rain.amount_ratio)
	_next -= delta
	if _next > 0.0:
		return
	_next = REFRESH_S
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var at := cam.global_position
	var space := get_world_3d().direct_space_state
	var n := 0
	hits.clear()
	for i in RAYS:
		var a := _rng.randf() * TAU
		var d := sqrt(_rng.randf()) * REACH
		var x := at.x + cos(a) * d
		var z := at.z + sin(a) * d
		if area.z > 0.0 and Vector2(x - area.x, z - area.y).length() > area.z:
			continue
		var q := PhysicsRayQueryParameters3D.create(Vector3(x, at.y + 40.0, z), Vector3(x, at.y - 60.0, z))
		var hit := space.intersect_ray(q)
		if hit.is_empty():
			continue
		var p: Vector3 = hit.position
		hits.append([p, hit.normal])
		# Relative to the emitter, which stands under the camera.
		_img.set_pixel(n, 0, Color(p.x - at.x, p.y, p.z - at.z))
		n += 1
	points = n
	if sounds != null:
		sounds.set_points(hits, at, ctx.city, ctx)
	if n == 0:
		return
	_tex.update(_img)
	_proc.emission_point_count = n
	splash.global_position = Vector3(at.x, 0.0, at.z)


## Hail: what is thrown up where it lands is `pellet`, bouncing higher and
## longer than a splash of water.
func bounce(pellet: Mesh) -> void:
	splash.draw_pass_1 = pellet
	splash.lifetime = 0.6
	_proc.initial_velocity_min = 1.8
	_proc.initial_velocity_max = 3.8
	_proc.spread = 40.0
	_proc.scale_min = 0.5
	_proc.scale_max = 1.0
