class_name CloudLayer
extends Node3D

## Clouds and their shadows (Docs/Lighting.md 2b). One cover function
## (shaders/clouds.gdshaderinc), drawn as a layer -- a planet's shell, turning
## with it, or a plane over the city following the camera -- and read by every
## surface that takes the sun (bricks, their studs, the ground, far buildings),
## which it darkens where a cloud stands between it and the sun. The shadows
## are faked, not shadow-mapped: Godot's sun has no light cookie.
##
## It sets the cover's globals itself each frame from the rig's sun; one layer
## live at a time (the last to step). Freed, or `cover` 0, nothing is shaded.
##
## Weather (WeatherFx): rain or snow thickens the cover towards overcast and
## greys the clouds' undersides; the wind blows them faster. The sun itself
## is dimmed by what reaches the camera (`cloud_here`), so what has no shader
## to darken -- figures, the gun -- darkens under a cloud too; the shaders
## take their share against it. From afar a planet's far look draws the same
## clouds (planet_impostor.gdshader, `params`); the shell gives way to it as
## the camera climbs past.

## A cloud's size, metres; the layer's height over the ground.
const CLOUD_SIZE := 650.0
const HEIGHT := 1200.0
## How much of a sunlit surface's light a full cloud takes (its albedo).
const SHADE := 0.45
## The wind up there, metres a second, in the layer's frame; WeatherFx's
## wind (0..~1.5) adds this many times its own.
const WIND := Vector3(7.0, 0.0, 3.0)
const WIND_GAIN := 14.0
## Rain or snow at full: the cover it brings, and how fast the sky follows
## (cover a second).
const STORM_COVER := 0.92
const COVER_RATE := 0.05
## The shell gives way to the far look's clouds between these heights over it.
const FAR_FROM := 400.0
const FAR_TO := 3000.0

## 0 clear .. 1 overcast. A planet's from its seed; the city's fair weather.
## The weather may make it more (`now_cover`), never less.
var cover := 0.45
var _weather := 0.0
## What reaches the camera, last frame (1 clear).
var here := 1.0
var _base_energy := -1.0
var _set_energy := -1.0
var rig: LightRig
## The planet whose clouds these are (its node; they turn with it), or null:
## flat, over the city.
var body: Node3D
var radius := 0.0
var height := HEIGHT
var _drift := Vector3.ZERO
## Held still: a scripted pass's pictures do not drift between shots.
static var still := false
var _mesh: MeshInstance3D
var _mat: ShaderMaterial
static var _live: CloudLayer


## A planet's clouds by its seed: {radius (the layer's, m), cover, drift}.
## The shell and the far look (PlanetBody) both read them.
static func params(planet_radius: float, peak: float, seed: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed * 7919 + 17
	var cv := rng.randf_range(0.3, 0.62)
	return {"radius": planet_radius + peak + HEIGHT * 0.75, "cover": cv,
			"drift": Vector3(rng.randf(), rng.randf(), rng.randf()) * 10000.0}


## A planet's clouds: a shell `height` metres over its peaks, under `body`.
static func for_planet(p_rig: LightRig, p_body: Node3D, planet_radius: float, peak: float,
		seed: int) -> CloudLayer:
	var c := CloudLayer.new()
	c.name = "Clouds"
	c.rig = p_rig
	c.body = p_body
	var p := params(planet_radius, peak, seed)
	c.radius = p.radius
	c.cover = p.cover
	c._drift = p.drift
	# From where its far look's clouds have blown to.
	var was = p_body.get("cloud_drift")
	if was is Vector3 and was != Vector3.INF:
		c._drift = was
	p_body.add_child(c)
	return c


## Is the live layer `b`'s (drifting its far look's clouds itself)?
static func drifts(b: Node3D) -> bool:
	return _live != null and is_instance_valid(_live) and _live.body == b


## The cover now: its own, or the weather's when that is more.
func now_cover() -> float:
	return maxf(cover, _weather)


## The city's: a plane `height` metres up over the camera.
static func for_city(p_rig: LightRig, parent: Node, p_height := HEIGHT) -> CloudLayer:
	var c := CloudLayer.new()
	c.name = "Clouds"
	c.rig = p_rig
	c.height = p_height
	parent.add_child(c)
	return c


func _ready() -> void:
	_mat = ShaderMaterial.new()
	_mat.shader = load("res://shaders/clouds.gdshader")
	_mat.set_shader_parameter("shell", body != null)
	_mesh = MeshInstance3D.new()
	_mesh.name = "Layer"
	_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if body != null:
		var s := SphereMesh.new()
		s.radius = radius
		s.height = radius * 2.0
		s.radial_segments = 160
		s.rings = 80
		_mesh.mesh = s
	else:
		var p := PlaneMesh.new()
		p.size = Vector2(18000.0, 18000.0)
		p.subdivide_width = 8
		p.subdivide_depth = 8
		_mesh.mesh = p
		_mesh.top_level = true
	_mesh.material_override = _mat
	# Never culled by its box: the camera is inside the shell.
	_mesh.extra_cull_margin = 16384.0
	add_child(_mesh)
	# After whatever sets the sun this frame (PlanetSystem, the rig): its
	# energy is what this dims.
	process_priority = 1000
	_live = self
	_push()


func _exit_tree() -> void:
	if _live == self:
		_live = null
		RenderingServer.global_shader_parameter_set(&"cloud_sun", Vector4.ZERO)
		RenderingServer.global_shader_parameter_set(&"cloud_here", 1.0)
		_dim_sun(1.0)
	# Its world's far look keeps its clouds when this goes, blown on from
	# where they are.
	if body != null and is_instance_valid(body):
		if body.get("cloud_drift") != null:
			body.set("cloud_drift", _drift)
		var imp = body.get("_impostor_mat")
		if imp is ShaderMaterial:
			(imp as ShaderMaterial).set_shader_parameter("cloud_show", 1.0)


func _process(delta: float) -> void:
	var storm := maxf(WeatherFx.rain, WeatherFx.snow)
	_weather = move_toward(_weather, STORM_COVER * storm, COVER_RATE * delta)
	if not still:
		_drift += (WIND + WeatherFx.wind * WIND_GAIN) * delta
	_push()


## How much of the sun reaches world point `at` (1 clear), the shader's sum
## worked out here (before its share against the camera's).
func shade_at(at: Vector3) -> float:
	if _live != self or now_cover() <= 0.0:
		return 1.0
	var s := _sun_dir()
	var from := _from_world()
	var p := from * at
	var d := (from.basis * s).normalized()
	var q: Vector3
	if body == null:
		q = p + d * maxf((height - p.y) / maxf(d.y, 0.05), 0.0)
	else:
		var b := p.dot(d)
		var c := p.dot(p) - radius * radius
		q = p + d * maxf(-b + sqrt(maxf(b * b - c, 0.0)), 0.0)
	return 1.0 - _strength() * density(q)


## The cover at `q` in the layer's frame: the shader's cloud_density.
func density(q: Vector3) -> float:
	var p := (q + _drift) / CLOUD_SIZE
	var n := 0.5 * _noise3(p) + 0.25 * _noise3(p * 2.03 + Vector3.ONE * 11.7) \
			+ 0.125 * _noise3(p * 4.01 + Vector3.ONE * 3.1) + 0.0625 * _noise3(p * 8.07 + Vector3.ONE * 7.9)
	n /= 0.9375
	n = n * 0.7 + _noise3(p * 0.16 + Vector3.ONE * 5.3) * 0.3
	var edge := 1.0 - now_cover()
	return smoothstep(edge - 0.06, edge + 0.16, n)


func _from_world() -> Transform3D:
	return body.global_transform.affine_inverse() if body != null else Transform3D.IDENTITY


func _sun_dir() -> Vector3:
	if rig == null or rig.sun == null:
		return Vector3.UP
	return rig.sun.global_basis.z.normalized()


## A full cloud's shade now: none at night, none with the sun off.
func _strength() -> float:
	if rig == null or rig.sun == null or not rig.sun.visible or now_cover() <= 0.0:
		return 0.0
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	var up := Vector3.UP
	if body != null and cam != null:
		up = (cam.global_position - body.global_position).normalized()
	var high := smoothstep(-0.05, 0.15, up.dot(_sun_dir()))
	var e := _base_energy if _base_energy >= 0.0 else rig.sun.light_energy
	return SHADE * high * clampf(e, 0.0, 1.0)


## The sun's energy times `k`, against what it was set to by whoever sets it
## (PlanetSystem each frame; the city once): read back each frame, so a new
## value from them is the new base.
func _dim_sun(k: float) -> void:
	if rig == null or rig.sun == null:
		return
	var e := rig.sun.light_energy
	if _set_energy < 0.0 or not is_equal_approx(e, _set_energy):
		_base_energy = e
	rig.sun.light_energy = _base_energy * k
	_set_energy = rig.sun.light_energy


func _push() -> void:
	if not is_inside_tree():
		return
	var cam := get_viewport().get_camera_3d()
	if body == null and cam != null:
		_mesh.global_position = Vector3(cam.global_position.x, height, cam.global_position.z)
	var s := _sun_dir()
	var sun_col := Color.BLACK
	var sky := Color(0.5, 0.55, 0.62)
	if rig != null and rig.sun != null:
		sun_col = rig.sun.light_color * clampf(rig.sun.light_energy, 0.0, 1.2)
		if rig.sky_mat != null:
			sky = rig.sky_mat.sky_horizon_color * rig.sky_mat.sky_energy_multiplier
	_mat.set_shader_parameter("sun_colour", sun_col)
	_mat.set_shader_parameter("sky_colour", sky)
	_mat.set_shader_parameter("storm", clampf(_weather / STORM_COVER, 0.0, 1.0))
	visible = now_cover() > 0.0
	# Climbing past the shell, the far look's clouds take over.
	var far := 0.0
	if body != null and cam != null:
		var up_by := cam.global_position.distance_to(body.global_position) - radius
		far = smoothstep(FAR_FROM, FAR_TO, up_by)
		_mat.set_shader_parameter("shell_fade", 1.0 - far)
		var imp = body.get("_impostor_mat")
		if imp is ShaderMaterial:
			(imp as ShaderMaterial).set_shader_parameter("cloud_show", far)
			(imp as ShaderMaterial).set_shader_parameter("cloud_cover", now_cover())
			(imp as ShaderMaterial).set_shader_parameter("cloud_drift_p", _drift)
	if _live != self:
		return
	# What reaches the camera dims the sun (and the shaders take their share
	# against it). Above the layer, none.
	here = 1.0
	if cam != null and far < 1.0:
		here = lerpf(shade_at(cam.global_position), 1.0, far)
	_dim_sun(here)
	RenderingServer.global_shader_parameter_set(&"cloud_here", here)
	RenderingServer.global_shader_parameter_set(&"cloud_from_world", Projection(_from_world()))
	RenderingServer.global_shader_parameter_set(&"cloud_sun", Vector4(s.x, s.y, s.z, _strength()))
	RenderingServer.global_shader_parameter_set(&"cloud_shape",
			Vector4(radius if body != null else 0.0, height, now_cover(), CLOUD_SIZE))
	RenderingServer.global_shader_parameter_set(&"cloud_drift", _drift)


# The shader's noise, mirrored.
static func _hash3(p: Vector3) -> float:
	p = (p * 0.3183099 + Vector3.ONE * 0.1)
	p = Vector3(p.x - floorf(p.x), p.y - floorf(p.y), p.z - floorf(p.z)) * 17.0
	var v := p.x * p.y * p.z * (p.x + p.y + p.z)
	return v - floorf(v)


static func _noise3(p: Vector3) -> float:
	var i := p.floor()
	var f := p - i
	f = f * f * (Vector3.ONE * 3.0 - 2.0 * f)
	var a := lerpf(_hash3(i), _hash3(i + Vector3(1, 0, 0)), f.x)
	var b := lerpf(_hash3(i + Vector3(0, 1, 0)), _hash3(i + Vector3(1, 1, 0)), f.x)
	var c := lerpf(_hash3(i + Vector3(0, 0, 1)), _hash3(i + Vector3(1, 0, 1)), f.x)
	var d := lerpf(_hash3(i + Vector3(0, 1, 1)), _hash3(i + Vector3(1, 1, 1)), f.x)
	return lerpf(lerpf(a, b, f.y), lerpf(c, d, f.y), f.z)
