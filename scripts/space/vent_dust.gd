class_name VentDust
extends RefCounted
## Dust at a venting hole (Docs/Hulls.md 4.2): while a room loses air through a
## breach, a jet of grey dust blows out of each of its holes (up to JETS a ship),
## outward, as strong as the air is going -- so a breach you cannot see the inside
## of shows from outside, and one you stand by shows where the rush goes.
## Presentation only, on the GPU (GPUParticles3D, world coordinates: what has blown
## out stays behind a flying ship).

## Jets a ship at most, and how often they are looked for again, seconds.
const JETS := 6
const EVERY := 0.25
## A room venting slower than this (its air's share a second) blows no dust.
const MIN_RATE := 0.01

var _jets: Array[GPUParticles3D] = []
var _wait := 0.0
static var _quad: QuadMesh


## One frame of `st`'s jets: looked for again every EVERY.
func update(st: SpaceStation, dt: float) -> void:
	_wait -= dt
	if _wait > 0.0:
		return
	_wait = EVERY
	var want := jets_of(st)
	for k in maxi(want.size(), _jets.size()):
		if k >= want.size():
			_jets[k].emitting = false
			continue
		if k >= _jets.size():
			_jets.append(_make(st))
		var j := _jets[k]
		var w: Dictionary = want[k]
		j.global_position = w.at
		var pm := j.process_material as ParticleProcessMaterial
		pm.direction = w.dir
		j.amount_ratio = clampf(float(w.rate) * float(w.pressure) * 4.0, 0.15, 1.0)
		pm.initial_velocity_min = 2.0 + 8.0 * float(w.pressure)
		pm.initial_velocity_max = 4.0 + 14.0 * float(w.pressure)
		j.emitting = true


## Where `st`'s jets go now: [{at (world), dir (world, outward), rate, pressure}],
## a few holes of each venting room, spread along its breach.
static func jets_of(st: SpaceStation) -> Array:
	var out: Array = []
	if st.air == null or not st.bricked:
		return out
	var air := st.air
	var to_w := st.global_transform * st.frame
	for c in air.compartments():
		var ci: int = c.id
		if int(c.breaches) == 0 or air.vent_rate(ci) < MIN_RATE:
			continue
		var cells := air.breach_cells(ci)
		var n := mini(cells.size(), 3)
		for k in n:
			@warning_ignore("integer_division")
			var h: Vector3i = cells[k * cells.size() / n]
			# Outward: away from the room's cells beside the hole.
			var d := Vector3.ZERO
			for o in [Vector3i.RIGHT, Vector3i.LEFT, Vector3i.UP, Vector3i.DOWN, Vector3i.BACK, Vector3i.FORWARD]:
				if air.compartment_at(h + o) == ci:
					d -= Vector3(o)
			var at := st.global_transform * st.cell_point(h) \
					+ to_w.basis.y.normalized() * BrickWorld.get_plate_metres() * 0.5
			var dir := (to_w.basis * (d * BrickWorld.get_cell_size())).normalized() if d != Vector3.ZERO \
					else (at - st.global_position).normalized()
			out.append({"at": at, "dir": dir, "rate": air.vent_rate(ci), "pressure": air.pressure(ci)})
			if out.size() >= JETS:
				return out
	return out


func _make(st: SpaceStation) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.name = "VentDust"
	p.amount = 48
	p.lifetime = 1.4
	p.local_coords = false
	p.top_level = true
	if _quad == null:
		_quad = QuadMesh.new()
		_quad.size = Vector2(0.5, 0.5)
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
		m.vertex_color_use_as_albedo = true
		m.albedo_texture = soft_dot()
		_quad.material = m
	p.draw_pass_1 = _quad
	p.visibility_aabb = AABB(Vector3.ONE * -30.0, Vector3.ONE * 60.0)
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = 0.3
	pm.spread = 22.0
	pm.gravity = Vector3.ZERO
	pm.damping_min = 0.3
	pm.damping_max = 0.8
	pm.scale_min = 0.4
	pm.scale_max = 1.6
	var g := Gradient.new()
	g.set_color(0, Color(0.82, 0.82, 0.8, 0.55))
	g.set_color(1, Color(0.7, 0.7, 0.7, 0.0))
	var gt := GradientTexture1D.new()
	gt.gradient = g
	pm.color_ramp = gt
	var sc := Curve.new()
	sc.max_value = 2.0
	sc.add_point(Vector2(0, 0.4))
	sc.add_point(Vector2(1, 1.6))
	var st_tex := CurveTexture.new()
	st_tex.curve = sc
	pm.scale_curve = st_tex
	p.process_material = pm
	p.emitting = false
	st.add_child(p)
	return p


## A soft round dot (white, fading to clear at its rim): what a particle is drawn
## with, so it is a puff or a drop and not a square.
static var _dot: GradientTexture2D


static func soft_dot() -> Texture2D:
	if _dot == null:
		var g := Gradient.new()
		g.set_color(0, Color(1, 1, 1, 1))
		g.set_color(1, Color(1, 1, 1, 0))
		_dot = GradientTexture2D.new()
		_dot.gradient = g
		_dot.fill = GradientTexture2D.FILL_RADIAL
		_dot.fill_from = Vector2(0.5, 0.5)
		_dot.fill_to = Vector2(1.0, 0.5)
		_dot.width = 32
		_dot.height = 32
	return _dot


func clear() -> void:
	for j in _jets:
		if is_instance_valid(j):
			j.queue_free()
	_jets.clear()
