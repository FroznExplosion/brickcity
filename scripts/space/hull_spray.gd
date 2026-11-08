class_name HullSpray
extends RefCounted
## The sea pouring in (Docs/Hulls.md 8.2): at each hole the water came in at in
## its last step (HullWater.inflow: none once the room stands at the outside level,
## or its air is held in a pocket), a jet of white water bursts in and falls --
## the waterfall at a hole -- as hard as the hole is deep (sqrt of the depth, as
## the inflow goes). Up to JETS a ship. Presentation only, on the
## GPU; the water itself is HullWater's.

const JETS := 6
const EVERY := 0.2
## Water in at a hole cell under this, cells a step: no jet.
const MIN_IN := 0.001

var _jets: Array[GPUParticles3D] = []
var _wait := 0.0
static var _quad: QuadMesh


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
		var s := sqrt(maxf(float(w.depth), 0.0))
		pm.initial_velocity_min = 1.0 + 2.0 * s
		pm.initial_velocity_max = 1.8 + 3.0 * s
		pm.gravity = Gravity.down_at(w.at) * 9.8
		j.amount_ratio = clampf(0.3 + s, 0.3, 1.0)
		j.emitting = true


## Where `st`'s jets go now: [{at, dir (world, inward), depth (m)}].
static func jets_of(st: SpaceStation) -> Array:
	var out: Array = []
	var w := st.hull_water
	var air := st.air
	if w == null or air == null or not st.water_depth.is_valid():
		return out
	var to_w := st.global_transform * st.frame
	for ci in air._parent.size():
		if air._parent[ci] != ci:
			continue
		for b: int in air._breach[ci]:
			if float(w.inflow.get(b, 0.0)) < MIN_IN:
				continue
			var d := st._hole_depth(b)
			if is_nan(d) or d <= 0.0:
				continue
			var dir := Vector3.ZERO
			for j in air._neighbours(b):
				if w.passable(j):
					dir += Vector3(air._cell(j) - air._cell(b))
			if dir == Vector3.ZERO:
				continue
			var at := st.global_transform * st.cell_point(air._cell(b)) \
					+ to_w.basis.y.normalized() * BrickWorld.get_plate_metres() * 0.5
			out.append({"at": at, "dir": (to_w.basis * (dir * BrickWorld.get_cell_size())).normalized(),
					"depth": d})
			if out.size() >= JETS:
				return out
	return out


func _make(st: SpaceStation) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.name = "HullSpray"
	p.amount = 90
	p.lifetime = 0.7
	p.local_coords = false
	p.top_level = true
	if _quad == null:
		_quad = QuadMesh.new()
		_quad.size = Vector2(0.09, 0.09)
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
		m.vertex_color_use_as_albedo = true
		m.albedo_texture = VentDust.soft_dot()
		_quad.material = m
	p.draw_pass_1 = _quad
	p.visibility_aabb = AABB(Vector3.ONE * -12.0, Vector3.ONE * 24.0)
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = 0.12
	pm.spread = 18.0
	pm.damping_min = 0.2
	pm.damping_max = 0.6
	pm.scale_min = 0.5
	pm.scale_max = 1.4
	var g := Gradient.new()
	g.set_color(0, Color(0.95, 0.98, 1.0, 0.85))
	g.set_color(1, Color(0.6, 0.8, 0.9, 0.0))
	var gt := GradientTexture1D.new()
	gt.gradient = g
	pm.color_ramp = gt
	p.process_material = pm
	p.emitting = false
	st.add_child(p)
	return p
