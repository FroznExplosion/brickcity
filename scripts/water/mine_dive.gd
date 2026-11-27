class_name MineDive
extends Node3D

## Under the mine world's water: the look by depth, breath, the readout
## (Docs/MineOcean.md 2.1, 2.2). MineWater owns it and calls [method frame]
## every frame with the eye and whether the eye is in water.
##
## The look is `Underwater`'s fog, re-tuned by depth: clear and green near the
## top, darker and bluer going down, near black past DARK_M. Environment
## values only (CPU side, set when the depth moved), no pass, no read-back.

## Depth (metres under the surface) at which the deep look is reached.
const DARK_M := 60.0
const DEEP_FOG := Color(0.012, 0.045, 0.10)
const DEEP_AMBIENT := Color(0.10, 0.20, 0.34)
const DENSITY_DEEP := 0.15
const BRIGHT_TOP := 0.92
const BRIGHT_DEEP := 0.2
## Breath: seconds under water, how fast it comes back in air, and the
## damage a second with none left. Creative never drowns.
const BREATH_S := 20.0
const REFILL_S := 4.0
const DROWN_DPS := 2.0

var host: Node = null
var water: Node = null
## Seconds of breath left (BREATH_S full).
var breath := BREATH_S
## The eye's depth under the surface, metres (0 out of the water).
var depth := 0.0
## 0 top .. 1 the deep look (smoothed), what the view was last set to.
var shade := 0.0
var _shade_set := -1.0
var _under := false
var _snow: GPUParticles3D = null
var _bar: BreathBar = null
var drowned_s := 0.0


func setup(p_host: Node, p_water: Node) -> void:
	host = p_host
	water = p_water
	_build()
	var layer = host.get("_hud_layer")
	if layer is CanvasLayer:
		_bar = BreathBar.new()
		_bar.name = "Breath"
		_bar.dive = self
		_bar.visible = false
		(layer as CanvasLayer).add_child(_bar)


func _exit_tree() -> void:
	if _bar != null and is_instance_valid(_bar):
		_bar.queue_free()


## `in_water`: the eye is in water (not lava). `env`: the view's, already
## made submerged by Underwater when in_water.
func frame(delta: float, eye: Vector3, in_water: bool, env: Environment, dry_ambient: float) -> void:
	_under = in_water
	depth = maxf(0.0, float(water.surface_at(eye)) - eye.y) if in_water else 0.0
	var want := smoothstep(0.0, DARK_M, depth)
	shade = want if not in_water else lerpf(shade, want, 1.0 - exp(-3.0 * delta))
	if in_water and env != null and absf(shade - _shade_set) > 0.004:
		_shade_set = shade
		env.fog_light_color = Underwater.TINT.lerp(DEEP_FOG, shade)
		env.fog_density = lerpf(Underwater.DENSITY, DENSITY_DEEP, shade)
		env.ambient_light_color = Underwater.AMBIENT.lerp(DEEP_AMBIENT, shade)
		env.ambient_light_energy = dry_ambient * lerpf(1.35, 0.2, shade)
		env.fog_sun_scatter = lerpf(0.35, 0.0, shade)
		env.adjustment_brightness = lerpf(BRIGHT_TOP, BRIGHT_DEEP, shade)
	if not in_water:
		_shade_set = -1.0
	# Marine snow round the eye, under water only.
	if _snow != null:
		_snow.emitting = in_water
		if in_water:
			_snow.position = eye
	_breathe(delta)
	if _bar != null:
		_bar.visible = in_water or breath < BREATH_S - 0.01
		if _bar.visible:
			_bar.queue_redraw()


func _breathe(delta: float) -> void:
	var on_foot: bool = bool(host.get("on_foot"))
	var survival: bool = bool(host.get("survival"))
	if not _under or not on_foot:
		breath = minf(BREATH_S, breath + delta * BREATH_S / REFILL_S)
		return
	breath = maxf(0.0, breath - delta)
	if breath > 0.0 or not survival:
		return
	var pawn: Pawn = host.get("pawn")
	if pawn != null and pawn.health != null and not pawn.health.is_dead():
		pawn.health.apply_impact(DROWN_DPS * delta, Elements.MELEE)
		drowned_s += delta


func _build() -> void:
	var mote_mat := StandardMaterial3D.new()
	mote_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mote_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mote_mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mote_mat.albedo_color = Color(0.80, 0.90, 0.88, 0.45)
	var mote := QuadMesh.new()
	mote.size = Vector2(0.035, 0.035)
	mote.material = mote_mat
	var mp := ParticleProcessMaterial.new()
	mp.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	mp.emission_box_extents = Vector3(9.0, 6.0, 9.0)
	mp.direction = Vector3(0.0, -1.0, 0.0)
	mp.spread = 40.0
	mp.initial_velocity_min = 0.05
	mp.initial_velocity_max = 0.2
	mp.gravity = Vector3.ZERO
	mp.turbulence_enabled = true
	mp.turbulence_noise_strength = 0.3
	mp.turbulence_noise_scale = 4.0
	mp.scale_min = 0.5
	mp.scale_max = 1.5
	_snow = GPUParticles3D.new()
	_snow.name = "MarineSnow"
	_snow.amount = 900
	_snow.lifetime = 9.0
	_snow.preprocess = 4.0
	_snow.local_coords = false
	_snow.emitting = false
	_snow.process_material = mp
	_snow.draw_pass_1 = mote
	_snow.visibility_aabb = AABB(Vector3(-14, -10, -14), Vector3(28, 20, 28))
	add_child(_snow)


func report() -> String:
	return "depth %.1f m, shade %.2f, breath %.1f s, drowned %.1f s" % [depth, shade, breath, drowned_s]


## Bubbles for breath and the depth in metres, bottom middle over the hotbar.
class BreathBar extends Control:
	var dive: MineDive

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		set_anchors_preset(Control.PRESET_FULL_RECT)

	func _draw() -> void:
		if dive == null:
			return
		var vs := get_viewport_rect().size
		var n := 10
		var left := dive.breath / MineDive.BREATH_S * n
		var r := 7.0
		var x0 := vs.x * 0.5 - (n - 1) * r * 1.3
		var y := vs.y - 118.0
		for i in n:
			var c := Vector2(x0 + i * r * 2.6, y)
			var f := clampf(left - i, 0.0, 1.0)
			draw_circle(c, r, Color(0.05, 0.1, 0.15, 0.45))
			if f > 0.0:
				draw_circle(c, r * (0.35 + 0.65 * f), Color(0.65, 0.88, 1.0, 0.9))
				draw_circle(c + Vector2(-r * 0.3, -r * 0.3), r * 0.22, Color(1, 1, 1, 0.85))
		if dive.depth > 0.5:
			var font := get_theme_default_font()
			var s := "%d m" % roundi(dive.depth)
			draw_string(font, Vector2(x0 + n * r * 2.6, y + 5.0), s, HORIZONTAL_ALIGNMENT_LEFT, -1, 16,
					Color(0.85, 0.95, 1.0, 0.9))
