class_name LightRig
extends Node3D

## The scene's light (Docs/Lighting.md): the sun, a fill light from the
## brightest moon or planet in the sky, the environment (sky, ambient, tonemap,
## auto exposure), and the ambient boxes that keep the sky's light out of
## rooms and ships. One place for the numbers; a scene builds one and feeds it.
##
## The colour rules (Lighting.md 3): a world's air may colour its sky, but the
## ambient light that falls on everything -- the player's gun, a brick wall --
## is mostly neutral; the sun is the star's colour pulled toward white,
## reddened by the air it crosses low in the sky.

## The sun's energy at home's distance from home's star.
const SUN_ENERGY := 1.1
## Brightness by the star's light at the camera against home's (Lighting.md 2):
## (flux ratio)^GAIN_POW, held in GAIN_MIN..GAIN_MAX.
const GAIN_POW := 0.3
const GAIN_MIN := 0.6
const GAIN_MAX := 1.6
## How much of the star's own colour the sunlight keeps (the rest is white).
const STAR_MIX := 0.25
## The sun's size for shadow softness (degrees across); bigger is held here.
const SUN_ANGLE_MAX := 3.0
## Home's sun across (degrees), as PlanetSystem gives it: the fixed-day scenes.
const DAY_SUN_ANGLE := 2.29
## The sun turns its size only when it changes this much (degrees).
const ANGLE_STEP := 0.05
## The sky's cast from its air colour: no channel further than this from 1.
const SKY_CAST_DEV := 0.45
## The share of the ambient light from the sky; the rest is a neutral grey as
## bright as the sky.
const AMBIENT_SKY := 0.35
## Sunset: optical depth per channel at the zenith for a full atmosphere.
const SCATTER := Vector3(0.02, 0.055, 0.12)
## Air mass is held under this (the sun on the horizon).
const AIRMASS_MAX := 14.0
## The fill light (moon, planet): energy for a score (albedo x solid angle / pi
## x the lit part), as FILL_K * sqrt(score), at most FILL_MAX of the sun's.
const FILL_K := 0.6
const FILL_MAX := 0.35
const FILL_ALBEDO := 0.3
## The fill casts shadows only with the sun gone and it this bright.
const FILL_SHADOW_AT := 0.02
const FILL_COLOUR := Color(0.78, 0.84, 1.0)
## Home's sky.
const HOME_ATMO := Color(0.45, 0.65, 1.0)
const SKY_TOP := Color(0.36, 0.53, 0.78)
const SKY_HAZE := Color(0.70, 0.77, 0.84)
const SKY_GROUND := Color(0.62, 0.68, 0.74)
const NIGHT := Color(0.03, 0.04, 0.08)
const DUSK := Color(0.85, 0.45, 0.25)
## A moonless night: the ambient's least energy, and its colour then.
const NIGHT_AMBIENT := 0.6
const STARLIGHT := Color(0.4, 0.45, 0.6)
## Exposure (Lighting.md 3): the eye's, from the light known at the camera
## (in a box or out, the sun, the ambient) -- not Godot's auto exposure, whose
## measure lags and whose limits are in ISO. Bright daylight is 1; darker
## places open up as sqrt(EXPOSE_REF / light), at most EXPOSE_MAX, so a room or
## the night is brighter to the eye but still darker than noon. Per second it
## goes EXPOSE_RATE of the way.
const EXPOSE_REF := 0.8
const EXPOSE_MAX := 2.0
const EXPOSE_RATE := 2.0
## Inside a box the sun is only what comes in at the windows.
const WINDOW_SUN := 0.1
## Ambient boxes (Lighting.md 6.2). A building's inside: a share of the
## outdoor ambient and a floor; a ship's or a station's: its own lights.
const ROOM_SHARE := 0.25
const ROOM_FLOOR := 0.02
const ROOM_COLOUR := Color(0.56, 0.57, 0.6)
const CABIN_ENERGY := 0.3
const CABIN_COLOUR := Color(0.92, 0.93, 1.0)
## Walls kept out of a box (m), so their outer faces stay in the open.
const WALL := 0.45
const BOX_BLEND := 0.3

var sun: DirectionalLight3D
var fill: DirectionalLight3D
var env: Environment
var sky_mat: ProceduralSkyMaterial
var world_env: WorldEnvironment
var attributes: CameraAttributesPractical
## The sunlight's colour now (star and sunset), and the star's alone.
var sun_colour := Color.WHITE
var star_colour := Color(1.0, 0.95, 0.85)
## Last values handed in, for gates and the HUD.
var gain := 1.0
var sun_angle := 0.0
var fill_energy := 0.0
var fill_from: Node3D = null
## The light at the camera last measured, and the exposure for it.
var light_here := 1.0
var exposure := 1.0
var inside := false
## Held: expose() leaves the exposure as it is (a gate's comparisons).
var hold_exposure := false

# Box -> "room" or "cabin".
var _boxes := {}
var _sun_dir := Vector3.ZERO


## Build the lights and the environment under `parent`; `space_star`: the star
## is drawn by the scene (no sky sun disc).
func build(parent: Node, space_star := false) -> void:
	name = "LightRig"
	parent.add_child(self)
	sun = DirectionalLight3D.new()
	sun.name = "Sun"
	sun.light_energy = SUN_ENERGY
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 400.0
	add_child(sun)
	fill = DirectionalLight3D.new()
	fill.name = "Fill"
	fill.light_energy = 0.0
	fill.visible = false
	fill.shadow_enabled = false
	fill.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	fill.directional_shadow_max_distance = 120.0
	fill.light_specular = 0.3
	add_child(fill)
	env = Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	sky_mat = ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = SKY_TOP
	sky_mat.sky_horizon_color = SKY_HAZE
	sky_mat.ground_bottom_color = Color(0.25, 0.27, 0.24)
	sky_mat.ground_horizon_color = SKY_HAZE
	if space_star:
		# The star is the sun's disc; the sky's own would not sit on it.
		sky_mat.sun_angle_max = 0.5
	sky.sky_material = sky_mat
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.6
	env.ambient_light_sky_contribution = AMBIENT_SKY
	env.ambient_light_color = Color(0.6, 0.62, 0.65)
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	world_env = WorldEnvironment.new()
	world_env.environment = env
	attributes = CameraAttributesPractical.new()
	attributes.auto_exposure_enabled = false
	attributes.exposure_multiplier = 1.0
	world_env.camera_attributes = attributes
	add_child(world_env)


## A fixed day for the scenes without a star system (city, heightfield,
## terrain, sandbox; Lighting.md 9): built as `build`, the sun at `sun_deg`
## (rotation in degrees) and `energy`, home's sun size and colour, home's sky,
## and `ambient` for the ambient's energy (what the scene used to set).
## The sun's shadow distance is Godot's default; a scene sets its own after.
func build_day(parent: Node, sun_deg: Vector3, energy := SUN_ENERGY, ambient := 0.6) -> void:
	build(parent)
	sun.directional_shadow_max_distance = 100.0
	sun.rotation_degrees = sun_deg
	sun.light_energy = energy
	sun_angle = DAY_SUN_ANGLE
	sun.light_angular_distance = DAY_SUN_ANGLE
	# basis.z points at the sun: its y is how high the sun stands.
	set_sky(1.0, 1.0, HOME_ATMO, clampf(sun.basis.z.y, 0.0, 1.0), Vector3.UP)
	env.ambient_light_energy = ambient
	env.sky_rotation = Vector3.ZERO


# --- the sun ----------------------------------------------------------------

## The sunlight from `to_star` (unit, toward the star), `seen` of its disc
## (0..1), the star's angular radius `ang_r` (rad), and its flux at the camera
## against home's (`flux_ratio`).
func set_sun(to_star: Vector3, seen: float, ang_r: float, flux_ratio: float, step := 0.00087) -> void:
	if _sun_dir == Vector3.ZERO or _sun_dir.angle_to(-to_star) > step:
		_sun_dir = -to_star
		var up := Vector3.UP if absf(to_star.y) < 0.99 else Vector3.FORWARD
		sun.global_basis = Basis.looking_at(_sun_dir, up)
	gain = sun_gain(flux_ratio)
	sun.light_energy = SUN_ENERGY * gain * seen
	sun.visible = seen > 0.0
	var deg := minf(rad_to_deg(ang_r * 2.0), SUN_ANGLE_MAX)
	if absf(deg - sun_angle) > ANGLE_STEP:
		sun_angle = deg
		sun.light_angular_distance = deg


## How bright the sun is for its flux against home's (Lighting.md 2).
static func sun_gain(flux_ratio: float) -> float:
	return clampf(pow(maxf(flux_ratio, 0.0001), GAIN_POW), GAIN_MIN, GAIN_MAX)


## The sunlight's colour: the star's, STAR_MIX of it, reddened by the air's
## path at `sun_height` (sin of the sun over the horizon) through `air` (0..1).
static func sunlight_colour(star: Color, sun_height: float, air: float) -> Color:
	var base := Color.WHITE.lerp(star, STAR_MIX)
	if air <= 0.0:
		return base
	var mass := minf(1.0 / maxf(sun_height, 1.0 / AIRMASS_MAX), AIRMASS_MAX)
	var t := Vector3(exp(-SCATTER.x * mass * air), exp(-SCATTER.y * mass * air), exp(-SCATTER.z * mass * air))
	var m := maxf(t.x, maxf(t.y, t.z))
	return Color(base.r * t.x / m, base.g * t.y / m, base.b * t.z / m)


## The sky's colour cast from a world's air colour: home's is none; the hue
## kept, its luminance 1, no channel further than SKY_CAST_DEV from 1.
static func sky_cast(atmo: Color) -> Color:
	var c := Vector3(atmo.r / HOME_ATMO.r, atmo.g / HOME_ATMO.g, atmo.b / HOME_ATMO.b)
	var lum := c.x * 0.2126 + c.y * 0.7152 + c.z * 0.0722
	if lum <= 0.0001:
		return Color.WHITE
	c /= lum
	var dev := maxf(absf(c.x - 1.0), maxf(absf(c.y - 1.0), absf(c.z - 1.0)))
	if dev > SKY_CAST_DEV:
		c = Vector3.ONE.lerp(c, SKY_CAST_DEV / dev)
	return Color(c.x, c.y, c.z)


# --- the sky and the ambient -------------------------------------------------

## The sky by day (0..1: the sun's height, with twilight), air (0..1: none in
## space or on an airless world), the world's air colour; the sky's up.
func set_sky(day: float, air: float, atmo: Color, sun_height: float, up: Vector3) -> void:
	var cast := sky_cast(atmo)
	var dusk := (1.0 - absf(day * 2.0 - 1.0)) * 0.5
	var haze := (SKY_HAZE * cast).lerp(DUSK, dusk).lerp(NIGHT, 1.0 - day) * air
	sky_mat.sky_top_color = (SKY_TOP * cast).lerp(NIGHT, 1.0 - day) * air
	sky_mat.sky_horizon_color = haze
	# Under the horizon only a sliver of sky ever shows past the ground: haze.
	sky_mat.ground_horizon_color = haze
	sky_mat.ground_bottom_color = SKY_GROUND.lerp(NIGHT, 1.0 - day) * air
	sky_mat.sky_energy_multiplier = maxf(air * maxf(day, 0.1), 0.02)
	env.ambient_light_energy = NIGHT_AMBIENT + (0.15 + 0.45 * air) * day
	# The neutral part of the ambient, as bright as the sky round it; never
	# under starlight, so a moonless night can still be played in.
	var g := (sky_mat.sky_top_color.get_luminance() + haze.get_luminance()) * 0.5
	env.ambient_light_color = Color(maxf(g, STARLIGHT.r), maxf(g, STARLIGHT.g), maxf(g * 1.04, STARLIGHT.b))
	# The sky's up is the local up: a procedural sky's horizon is its own XZ
	# plane, and the world's Y is the local up only at the pole.
	env.sky_rotation = Quaternion(Vector3.UP, up).get_euler()
	sun_colour = sunlight_colour(star_colour, sun_height, air)
	sun.light_color = sun_colour
	_update_boxes()


# --- exposure ------------------------------------------------------------------

## The eye at `at` adapts over `dt`; `snap` jumps straight there.
func expose(at: Vector3, dt: float, snap := false) -> void:
	var box := box_at(at)
	inside = box != null
	var amb := 0.0
	if box != null:
		amb = box.ambient_color_energy * box.ambient_color.get_luminance()
	else:
		amb = env.ambient_light_energy * env.ambient_light_color.get_luminance()
	var direct := sun.light_energy * sun.light_color.get_luminance() if sun.visible else 0.0
	direct += fill_energy if fill.visible else 0.0
	light_here = amb + direct * (WINDOW_SUN if inside else 0.5)
	var want := clampf(sqrt(EXPOSE_REF / maxf(light_here, 0.001)), 1.0, EXPOSE_MAX)
	if hold_exposure:
		return
	exposure = want if snap else lerpf(exposure, want, clampf(dt * EXPOSE_RATE, 0.0, 1.0))
	attributes.exposure_multiplier = exposure


## The ambient box holding world point `at`, or null.
func box_at(at: Vector3) -> ReflectionProbe:
	_prune_boxes()
	for p in _boxes:
		var b := p as ReflectionProbe
		if not b.is_inside_tree():
			continue
		var l := b.global_transform.affine_inverse() * at
		if absf(l.x) <= b.size.x * 0.5 and absf(l.y) <= b.size.y * 0.5 and absf(l.z) <= b.size.z * 0.5:
			return b
	return null


# --- the fill: a moon or a planet --------------------------------------------

## The fill light from `body` (or none): `to_body` unit toward it, `score`
## (albedo x solid angle / pi x the lit part), its angular radius `ang_r`, how
## far over the horizon it stands (0..1), and the sun's `seen` (shadows only
## with the sun gone).
func set_fill(body: Node3D, to_body: Vector3, score: float, ang_r: float, over: float, sun_seen: float) -> void:
	fill_from = body
	fill_energy = 0.0 if body == null else clampf(FILL_K * sqrt(maxf(score, 0.0)), 0.0, FILL_MAX) * SUN_ENERGY * gain * over
	fill.visible = fill_energy > 0.002
	if not fill.visible:
		return
	var up := Vector3.UP if absf(to_body.y) < 0.99 else Vector3.FORWARD
	fill.global_basis = Basis.looking_at(-to_body, up)
	fill.light_energy = fill_energy
	fill.light_color = FILL_COLOUR.lerp(star_colour, 0.3)
	fill.light_angular_distance = minf(rad_to_deg(ang_r * 2.0), SUN_ANGLE_MAX)
	var shadows := sun_seen < 0.05 and fill_energy > FILL_SHADOW_AT
	if fill.shadow_enabled != shadows:
		fill.shadow_enabled = shadows


# --- ambient boxes (Lighting.md 6.2) ------------------------------------------

## A box under `owner_node` from `lo` to `hi` (its local space) that keeps the
## sky's light out: "room" (a building: a share of outdoors) or "cabin" (a
## ship or station: its own lights). Its walls (WALL) are left outside.
func add_box(owner_node: Node3D, lo: Vector3, hi: Vector3, kind := "room") -> ReflectionProbe:
	var p := ReflectionProbe.new()
	p.name = "AmbientBox"
	p.interior = true
	# Nothing drawn into it: dark reflections indoors, and no capture cost.
	p.cull_mask = 0
	p.update_mode = ReflectionProbe.UPDATE_ONCE
	p.ambient_mode = ReflectionProbe.AMBIENT_COLOR
	p.blend_distance = BOX_BLEND
	var a := lo + Vector3(WALL, 0.05, WALL)
	var b := hi - Vector3(WALL, WALL, WALL)
	p.size = (b - a).max(Vector3(0.2, 0.2, 0.2))
	p.position = (a + b) * 0.5
	owner_node.add_child(p)
	_boxes[p] = kind
	_style_box(p, kind)
	return p


func box_count() -> int:
	_prune_boxes()
	return _boxes.size()


func _prune_boxes() -> void:
	for p in _boxes.keys():
		if not is_instance_valid(p):
			_boxes.erase(p)


func _update_boxes() -> void:
	_prune_boxes()
	for p in _boxes:
		_style_box(p, _boxes[p])


func _style_box(p: ReflectionProbe, kind: String) -> void:
	if kind == "cabin":
		p.ambient_color = CABIN_COLOUR
		p.ambient_color_energy = CABIN_ENERGY
	else:
		p.ambient_color = ROOM_COLOUR
		p.ambient_color_energy = ROOM_FLOOR + env.ambient_light_energy * ROOM_SHARE
