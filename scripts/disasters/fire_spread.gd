class_name FireSpread
extends Node3D

## Fire, as a service: lightning, meteors and "a building catches" start it with
## ignite(), and it burns on its own after whatever lit it is gone
## (Docs/Disasters.md section 5).
##
## Fire lives on a coarse grid, not on bricks: a cell is 4 x 4 studs and one
## storey (1.4 x 2.66 x 1.4 m), about one corner of a room. Twice a second each
## burning cell heats up, CHIPS the bricks in it -- wear through the world
## authority, so a PLA wall sags and holes rather than vanishing -- tries to
## catch its six neighbours (mostly upward: fire climbs), and burns its fuel.
## A burnt-out cell never catches again.
##
## This is a printed city: plastic melts before it burns. Flammability comes
## from the material index (brick_grid.h BRICK_MATERIALS); metal and stone do
## not burn and stop the spread.
##
## HARD CAP: MAX_CELLS. At the cap nothing new catches -- fire is the one
## disaster whose cost would otherwise grow on its own.
##
## Deterministic: cells are stepped in the order they caught, on the physics
## tick, from a seeded rng.

const CELL := Vector3(1.4, 2.66, 1.4)
const MAX_CELLS := 48
## Each cell is stepped every STEP_S, a slice of the cells each tick.
const STEP_S := 0.5
const CHIP_RADIUS := 0.9
## hp per step at full heat, scaled by (0.5 + flammability): PLA 24, wood 36.
## A brick has 255 (StructuralDamage.BRICK_HP), so PLA lasts ~5 s in a full fire.
const CHIP_HP := 24.0
const HEAT_RATE := 0.17          ## per step: ~3 s from a spark to full
## Tuned so a PLA cell sets ~1.5 others alight over its life: a fire that grows
## and then runs out of building, not one that fills its cap and holds it.
const SPREAD := 0.06
const BIAS_UP := 3.0
const BIAS_SIDE := 1.0
const BIAS_DOWN := 0.3
const FUEL_BASE := 4.0           ## steps' worth, plus FUEL_PER_FLAM * flammability
const FUEL_PER_FLAM := 8.0
const PAWN_DAMAGE := 6.0         ## per step at full heat, to anyone in the cell

## Burn, per material index -- append-only, like the table it mirrors.
## PLA, PLA matte, PLA silk, ABS, PETG, TPU, Nylon, Glow PLA, Carbon PLA,
## Wood PLA, Wood, Metal, Stone.
const FLAMMABILITY := [0.5, 0.5, 0.5, 0.4, 0.35, 0.3, 0.25, 0.5, 0.4, 0.8, 1.0, 0.0, 0.0]
const FLAM_UNKNOWN := 0.5

const DIRS := [Vector3i(0, 1, 0), Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
		Vector3i(0, 0, 1), Vector3i(0, 0, -1), Vector3i(0, -1, 0)]

class Cell:
	var key: Vector3i
	var heat := 0.0
	var fuel := 0.0
	var flam := 0.0
	var steps := 0
	var emitter: GPUParticles3D

## What the world is, as callables so the probe can run fire without a city:
## material_at(Vector3) -> int (-1 for no brick); chip(Vector3, float, int);
## damage(Vector3, float, float) -> int; raining() -> bool.
var material_at: Callable
var chip: Callable
var damage: Callable
var raining: Callable

var rng := RandomNumberGenerator.new()
## Burning cells in the order they caught.
var cells: Array[Cell] = []
var _by_key := {}
## Cells that have burnt out: they do not catch again.
var _burnt := {}
## Flammability per cell key, sampled once (material_at walks every building).
var _flam := {}
var _tick := 0
var _douse := 0.0

## Clusters of burning cells, regrouped twice a second: [sum of centres, count,
## highest centre y]. Smoke, light and sound gather per cluster.
var _groups: Array = []
## Where the smoke is, for the AI (it blocks sight): [centre, radius] per
## cluster, above the fire.
var smoke_spots: Array = []

## Counters for the probe and the HUD.
var caught := 0
var chips := 0
var peak := 0
var capped := 0                  ## catches refused at the cap

var _visuals := true
var _free_emitters: Array[GPUParticles3D] = []
var _smoke: Array[GPUParticles3D] = []
var _lights: Array[OmniLight3D] = []
var _roar: AudioStreamPlayer3D


func setup(seed_value: int, visuals := true) -> void:
	rng.seed = seed_value
	_visuals = visuals
	if _visuals:
		_build_visuals()


## Catch fire at `point` -- or, if there is nothing there to burn, in the cell
## below it (a strike on a roof lands on the air just above the slab). False
## where neither will burn, or at the cap.
func ignite(point: Vector3, heat: float) -> bool:
	var k := key_of(point)
	for c in [k, k + Vector3i.DOWN]:
		if _catch(c, heat):
			return true
	return false


func count() -> int:
	return cells.size()


func is_burning() -> bool:
	return not cells.is_empty()


## Put it all out over the next couple of seconds: no more spread, fuel cut.
func douse() -> void:
	_douse = 3.0
	for c in cells:
		c.fuel = minf(c.fuel, 2.0)


static func key_of(p: Vector3) -> Vector3i:
	return Vector3i(floori(p.x / CELL.x), floori(p.y / CELL.y), floori(p.z / CELL.z))


static func centre_of(k: Vector3i) -> Vector3:
	return (Vector3(k) + Vector3(0.5, 0.5, 0.5)) * CELL


static func flammability(material: int) -> float:
	if material < 0:
		return 0.0
	if material >= FLAMMABILITY.size():
		return FLAM_UNKNOWN
	return FLAMMABILITY[material]


## How well cell `k` burns: the most flammable brick among a few points in it --
## the middle, the floor, and the four walls' planes -- or 0 for none.
func flam_at(k: Vector3i) -> float:
	if _flam.has(k):
		return _flam[k]
	var c := centre_of(k)
	var h := CELL * 0.5
	var best := 0.0
	for off in [Vector3.ZERO, Vector3(0, -h.y + 0.1, 0), Vector3(h.x - 0.2, 0, 0),
			Vector3(-h.x + 0.2, 0, 0), Vector3(0, 0, h.z - 0.2), Vector3(0, 0, -h.z + 0.2)]:
		best = maxf(best, flammability(int(material_at.call(c + off))))
	_flam[k] = best
	return best


func _physics_process(_delta: float) -> void:
	tick()


## One physics tick: step the slice of cells whose turn it is.
func tick() -> void:
	_tick += 1
	if cells.is_empty():
		# Out: nothing left to group, so no smoke for the AI or the eye.
		if not _groups.is_empty():
			_groups = []
			smoke_spots = []
			if _visuals:
				for i in _smoke.size():
					_smoke[i].emitting = false
					_lights[i].visible = false
		return
	var slices := maxi(1, int(round(STEP_S * Engine.physics_ticks_per_second)))
	_douse = maxf(0.0, _douse - 1.0 / Engine.physics_ticks_per_second)
	var wet := raining.is_valid() and bool(raining.call())
	# Snapshot: cells caught this tick start stepping next time round.
	var snapshot := cells.duplicate()
	for i in snapshot.size():
		if (i + _tick) % slices == 0:
			_step(snapshot[i], wet)
	var i := cells.size() - 1
	while i >= 0:
		if cells[i].fuel <= 0.0:
			_die(i)
		i -= 1
	peak = maxi(peak, cells.size())
	if _tick % 15 == 0:
		_regroup()
	if _visuals:
		_update_visuals()


func _step(c: Cell, wet: bool) -> void:
	c.steps += 1
	c.heat = minf(1.0, c.heat + HEAT_RATE * (0.5 if wet else 1.0))
	var centre := centre_of(c.key)
	var hp := int(round(CHIP_HP * c.heat * (0.5 + c.flam)))
	if hp > 0 and chip.is_valid():
		chip.call(centre, CHIP_RADIUS, hp)
		chips += 1
	if damage.is_valid():
		damage.call(centre, CELL.x, PAWN_DAMAGE * c.heat)
	if _douse <= 0.0:
		for d in DIRS:
			var n: Vector3i = c.key + d
			if _by_key.has(n) or _burnt.has(n):
				continue
			var f := flam_at(n)
			if f <= 0.0:
				continue
			var bias := BIAS_UP if d.y > 0 else (BIAS_DOWN if d.y < 0 else BIAS_SIDE)
			var p := f * c.heat * bias * SPREAD * (0.5 if wet else 1.0)
			if rng.randf() < p:
				_catch(n, 0.3)
	c.fuel -= STEP_S * c.heat * 2.0


func _catch(k: Vector3i, heat: float) -> bool:
	if _by_key.has(k) or _burnt.has(k):
		return false
	var f := flam_at(k)
	if f <= 0.0:
		return false
	if cells.size() >= MAX_CELLS:
		capped += 1
		return false
	var c := Cell.new()
	c.key = k
	c.flam = f
	c.heat = clampf(heat, 0.05, 1.0)
	c.fuel = FUEL_BASE + FUEL_PER_FLAM * f
	cells.append(c)
	_by_key[k] = c
	caught += 1
	if _visuals and not _free_emitters.is_empty():
		c.emitter = _free_emitters.pop_back()
		c.emitter.global_position = _vent(k)
		c.emitter.emitting = true
	return true


## Where a cell's flames show: out of its face onto open air, if it has one --
## a fire in a room is seen at the window, licking up the wall -- or low in
## the cell if it is shut in.
func _vent(k: Vector3i) -> Vector3:
	var base := centre_of(k) - Vector3(0, CELL.y * 0.35, 0)
	for d in [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]:
		if flam_at(k + d) <= 0.0:
			return base + Vector3(d) * (CELL.x * 0.5 + 0.25) + Vector3.UP * 0.4
	return base


func _die(i: int) -> void:
	var c := cells[i]
	cells.remove_at(i)
	_by_key.erase(c.key)
	_burnt[c.key] = true
	if c.emitter != null:
		c.emitter.emitting = false
		_free_emitters.append(c.emitter)
		c.emitter = null


# --- Look and sound -------------------------------------------------------------

func _update_visuals() -> void:
	# Flames follow heat; smoke and light gather per cluster of cells -- a
	# light per cell would be 48 lights.
	for c in cells:
		if c.emitter != null:
			c.emitter.amount_ratio = 0.3 + 0.7 * c.heat
	if _tick % 15 != 0:
		return
	var groups := _groups
	for i in _smoke.size():
		var on := i < groups.size()
		_smoke[i].emitting = on
		_lights[i].visible = on
		if on:
			var centre: Vector3 = groups[i][0] / float(groups[i][1])
			_smoke[i].global_position = Vector3(centre.x, groups[i][2] + CELL.y * 0.5, centre.z)
			_lights[i].global_position = centre
			_lights[i].light_energy = 3.0 + minf(6.0, groups[i][1] * 0.5)
	if _roar != null:
		if cells.is_empty():
			_roar.stop()
		else:
			var first: Vector3 = groups[0][0] / float(groups[0][1])
			_roar.global_position = first
			_roar.volume_db = -6.0 + minf(8.0, cells.size() * 0.3)
			if not _roar.playing:
				_roar.play()


func _regroup() -> void:
	_groups = []
	for c in cells:
		var p := centre_of(c.key)
		var joined := false
		for g in _groups:
			if (g[0] / float(g[1])).distance_to(p) < 12.0:
				g[0] += p
				g[1] += 1
				g[2] = maxf(g[2], p.y)
				joined = true
				break
		if not joined:
			_groups.append([p, 1, p.y])
	smoke_spots = []
	for g in _groups:
		var centre: Vector3 = g[0] / float(g[1])
		# A column of smoke over the fire, bigger as the fire is.
		smoke_spots.append([Vector3(centre.x, float(g[2]) + CELL.y * 1.5, centre.z),
				3.0 + minf(5.0, float(g[1]) * 0.3)])


func _process(_delta: float) -> void:
	for l in _lights:
		if l.visible:
			l.light_energy *= randf_range(0.9, 1.1)
			l.light_energy = clampf(l.light_energy, 2.0, 10.0)
	if _roar != null and cells.is_empty() and _roar.playing:
		_roar.stop()


func _build_visuals() -> void:
	var puff := GradientTexture2D.new()
	puff.width = 64
	puff.height = 64
	puff.fill = GradientTexture2D.FILL_RADIAL
	puff.fill_from = Vector2(0.5, 0.5)
	puff.fill_to = Vector2(1.0, 0.5)
	var pg := Gradient.new()
	pg.offsets = PackedFloat32Array([0.0, 0.5, 1.0])
	pg.colors = PackedColorArray([Color(1, 1, 1, 1), Color(1, 1, 1, 0.45), Color(1, 1, 1, 0)])
	puff.gradient = pg

	var flame_mat := StandardMaterial3D.new()
	flame_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	flame_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	flame_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	flame_mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	flame_mat.vertex_color_use_as_albedo = true
	flame_mat.albedo_texture = puff
	var flame_quad := QuadMesh.new()
	flame_quad.size = Vector2(1.1, 1.1)
	flame_quad.material = flame_mat
	var flame_proc := ParticleProcessMaterial.new()
	flame_proc.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	flame_proc.emission_box_extents = Vector3(0.6, 0.2, 0.6)
	flame_proc.direction = Vector3.UP
	flame_proc.spread = 15.0
	flame_proc.initial_velocity_min = 1.2
	flame_proc.initial_velocity_max = 2.6
	flame_proc.gravity = Vector3(0, 1.0, 0)
	flame_proc.scale_min = 0.6
	flame_proc.scale_max = 1.3
	flame_proc.color_ramp = _ramp([Color(1.0, 0.9, 0.5, 1.0), Color(1.0, 0.5, 0.1, 0.9),
			Color(0.8, 0.2, 0.05, 0.5), Color(0.2, 0.05, 0.02, 0.0)])
	for i in MAX_CELLS:
		var p := GPUParticles3D.new()
		p.amount = 18
		p.lifetime = 0.9
		p.emitting = false
		p.process_material = flame_proc
		p.draw_pass_1 = flame_quad
		p.visibility_aabb = AABB(Vector3(-2, -1, -2), Vector3(4, 5, 4))
		add_child(p)
		_free_emitters.append(p)

	var smoke_mat := StandardMaterial3D.new()
	smoke_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	smoke_mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	smoke_mat.vertex_color_use_as_albedo = true
	smoke_mat.albedo_texture = puff
	var smoke_quad := QuadMesh.new()
	smoke_quad.size = Vector2(4.0, 4.0)
	smoke_quad.material = smoke_mat
	var smoke_proc := ParticleProcessMaterial.new()
	smoke_proc.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	smoke_proc.emission_sphere_radius = 2.0
	smoke_proc.direction = Vector3.UP
	smoke_proc.spread = 12.0
	smoke_proc.initial_velocity_min = 2.0
	smoke_proc.initial_velocity_max = 3.5
	smoke_proc.gravity = Vector3(0.6, 0.3, 0.2)
	smoke_proc.scale_min = 0.8
	smoke_proc.scale_max = 2.2
	smoke_proc.color_ramp = _ramp([Color(0.2, 0.18, 0.17, 0.0), Color(0.18, 0.17, 0.16, 0.75),
			Color(0.3, 0.3, 0.3, 0.4), Color(0.4, 0.4, 0.4, 0.0)])
	for i in 6:
		var s := GPUParticles3D.new()
		s.amount = 40
		s.lifetime = 7.0
		s.emitting = false
		s.process_material = smoke_proc
		s.draw_pass_1 = smoke_quad
		s.visibility_aabb = AABB(Vector3(-15, -2, -15), Vector3(30, 40, 30))
		add_child(s)
		_smoke.append(s)
		var l := OmniLight3D.new()
		l.light_color = Color(1.0, 0.5, 0.18)
		l.omni_range = 14.0
		l.visible = false
		add_child(l)
		_lights.append(l)
	_roar = AudioStreamPlayer3D.new()
	_roar.stream = DisasterSounds.fire()
	_roar.unit_size = 12.0
	_roar.max_distance = 120.0
	add_child(_roar)


func _ramp(colours: Array) -> GradientTexture1D:
	var g := Gradient.new()
	var offs := PackedFloat32Array()
	for i in colours.size():
		offs.append(float(i) / (colours.size() - 1))
	g.offsets = offs
	g.colors = PackedColorArray(colours)
	var t := GradientTexture1D.new()
	t.gradient = g
	return t
