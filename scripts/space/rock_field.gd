class_name RockField
extends Node3D

## A ring round a planet or a belt round a star (Docs/Planets.md 11.12 step 6;
## after STA Docs/15 §3): an annulus about its node's Y. Far, a shader disc.
## Near, rocks drawn by a MultiMesh round the player, in cells, each cell's
## rocks a pure function of the cell: nothing is stored, every visit and every
## peer sees the same, and `blocked` asks that same function whether a point is
## in a rock, so a ship is stopped with no bodies at all. The rocks do not go
## round: they hold still in the frame of what they ring.

const CELL := 300.0
## Cells drawn each way round the player, in the plane and across it.
const SPAN := 5
const SPAN_Y := 2
## Past this speed (m/s) nothing is drawn: a blur, and a rebuild every frame.
const FAST := 2500.0
const ROCK_MIN := 3.0
const ROCK_MAX := 34.0

var inner := 0.0
var outer := 0.0
var half_thick := 150.0
var field_seed := 1
var colour := Color(0.5, 0.46, 0.42)
## Its near rocks are placed from outside (`hold_near`), every frame: a belt's.
var held := false
var drawn := 0
var _mmi: MultiMeshInstance3D
var _rng := RandomNumberGenerator.new()
var _at := Vector3i(1 << 30, 0, 0)
var _last := Vector3.ZERO


func setup(p_inner: float, p_outer: float, p_seed: int, p_colour: Color) -> void:
	name = "Rocks"
	inner = p_inner
	outer = p_outer
	field_seed = p_seed
	colour = p_colour


## Cell `c`'s rocks: each [local position, radius]. A pure function of `c`.
func rocks_in(c: Vector3i) -> Array:
	var out := []
	var centre := Vector3(c) * CELL
	if absf(centre.y) > half_thick + CELL:
		return out
	var r := Vector2(centre.x, centre.z).length()
	if r < inner - CELL or r > outer + CELL:
		return out
	_rng.seed = hash(c) ^ field_seed
	for _k in _rng.randi_range(0, 3):
		var p := centre + Vector3(_rng.randf_range(-0.5, 0.5), _rng.randf_range(-0.5, 0.5), _rng.randf_range(-0.5, 0.5)) * CELL
		var u := _rng.randf()
		var size := lerpf(ROCK_MIN, ROCK_MAX, u * u * u)
		var pr := Vector2(p.x, p.z).length()
		if pr >= inner and pr <= outer and absf(p.y) <= half_thick:
			out.append([p, size])
	return out


static func cell_of(p: Vector3) -> Vector3i:
	return Vector3i((p / CELL).round())


## A sphere of `radius` at local `p` touches a rock.
func blocked(p: Vector3, radius: float) -> bool:
	var c := cell_of(p)
	for x in range(c.x - 1, c.x + 2):
		for y in range(c.y - 1, c.y + 2):
			for z in range(c.z - 1, c.z + 2):
				for e in rocks_in(Vector3i(x, y, z)):
					if (e[0] as Vector3).distance_to(p) < float(e[1]) + radius:
						return true
	return false


## Where the near rocks are drawn from, field-local.
func mid() -> Vector3:
	return Vector3(_at) * CELL


## The near rocks' place in the world, for a field that is `held`.
func hold_near(xf: Transform3D) -> void:
	if _mmi != null:
		_mmi.global_transform = xf


## Whether local `p` is near enough the field to draw any of it.
func near(p: Vector3) -> bool:
	var r := Vector2(p.x, p.z).length()
	var m := CELL * (SPAN + 1)
	return r > inner - m and r < outer + m and absf(p.y) < half_thick + m


## The player at local `p`: the cells round it drawn, again when it crosses
## one. Hidden if it is not near, or too fast to see them.
func refresh(p: Vector3, dt: float) -> void:
	var speed := p.distance_to(_last) / maxf(dt, 0.001)
	_last = p
	if not near(p) or speed > FAST:
		if _mmi != null:
			_mmi.visible = false
		return
	var c := cell_of(p)
	if _mmi != null and c == _at and _mmi.visible:
		return
	_at = c
	if _mmi == null:
		_build_near()
	var list := []
	for x in range(c.x - SPAN, c.x + SPAN + 1):
		for y in range(c.y - SPAN_Y, c.y + SPAN_Y + 1):
			for z in range(c.z - SPAN, c.z + SPAN + 1):
				list.append_array(rocks_in(Vector3i(x, y, z)))
	drawn = list.size()
	var mm := _mmi.multimesh
	if mm.instance_count < drawn:
		mm.instance_count = drawn * 2
	mm.visible_instance_count = drawn
	_mmi.visible = true
	# From the middle cell, so the transforms are small numbers (a belt's are
	# millions of metres out).
	var mid := Vector3(c) * CELL
	if not held:
		_mmi.position = mid
	for i in drawn:
		var e: Array = list[i]
		var p0: Vector3 = e[0]
		_rng.seed = hash(p0)
		var b := Basis.from_euler(Vector3(_rng.randf() * TAU, _rng.randf() * TAU, _rng.randf() * TAU))
		var s := float(e[1])
		b = b.scaled(Vector3(s * _rng.randf_range(0.8, 1.3), s * _rng.randf_range(0.6, 1.0), s * _rng.randf_range(0.8, 1.4)))
		mm.set_instance_transform(i, Transform3D(b, p0 - mid))
		mm.set_instance_color(i, colour.lightened(_rng.randf_range(-0.12, 0.12)))


func _build_near() -> void:
	var sm := SphereMesh.new()
	sm.radial_segments = 10
	sm.rings = 6
	sm.radius = 1.0
	sm.height = 2.0
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = sm
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.95
	_mmi = MultiMeshInstance3D.new()
	_mmi.name = "Near"
	_mmi.multimesh = mm
	_mmi.material_override = mat
	_mmi.extra_cull_margin = CELL * SPAN
	_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_mmi.top_level = held
	_mmi.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	add_child(_mmi)


## How much of the sun the thickest of the ring takes (body_shadow's RING_SHADE).
const SHADE := 0.85
## The far disc's density (build_far), and the disc.
var far_density := 0.7
var disc: MeshInstance3D


## The bands' frequency, as the disc draws them.
func grain() -> float:
	return float(field_seed % 97) + 40.0


## The ring's cover at `r` (of the outer radius): ring_band.gdshaderinc's.
static func alpha_at(r: float, inner_frac: float, density: float, grain_f: float) -> float:
	if r > 1.0 or r < inner_frac:
		return 0.0
	var t := (r - inner_frac) / (1.0 - inner_frac)
	var edge := smoothstep(0.0, 0.04, t) * smoothstep(1.0, 0.96, t)
	var band := 0.6 + 0.25 * sin(r * grain_f) + 0.15 * sin(r * grain_f * 2.7 + 1.3)
	return clampf(density * band * edge, 0.0, 1.0)


## The sun left at `world` through this ring, toward `sd` (world): its shadow
## on the ground (Docs/Lighting.md 2a).
func light_at(world: Vector3, sd: Vector3) -> float:
	var inv := global_basis.orthonormalized().inverse()
	var p := inv * (world - global_position)
	var s := inv * sd
	if absf(s.y) < 1e-4:
		return 1.0
	var t := -p.y / s.y
	if t <= 0.0:
		return 1.0
	var q := p + s * t
	return 1.0 - SHADE * alpha_at(Vector2(q.x, q.z).length() / outer, inner / outer, far_density, grain())


## The far look: a disc under `parent` (a look node, so scaled space draws it),
## turned as this field is.
func build_far(parent: Node3D, density := 0.7) -> MeshInstance3D:
	far_density = density
	var pm := PlaneMesh.new()
	pm.size = Vector2.ONE * outer * 2.0
	var mi := MeshInstance3D.new()
	mi.name = "RockDisc"
	mi.mesh = pm
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/rock_disc.gdshader")
	mat.set_shader_parameter("inner", inner / outer)
	mat.set_shader_parameter("tint", colour)
	mat.set_shader_parameter("density", density)
	mat.set_shader_parameter("grain", grain())
	mat.set_shader_parameter("outer_m", outer)
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.extra_cull_margin = outer
	mi.transform = transform
	parent.add_child(mi)
	disc = mi
	return mi
