class_name Wildfire
extends Disaster

## A wildfire (Docs/Disasters.md 27): a fire front across the land, not inside
## a building -- the building fire (FireSpread) is cells of walls; this is
## cells of ground.
##
##   * THE GROUND is a grid of CELL metres round where it starts. Each cell's
##     fuel is its terrain (grass high, dirt some, sand, stone, the sea and
##     lying snow none), more where a tree stands -- a tree cell burns longer
##     and taller. Wet ground burns less.
##   * IT SPREADS with the wind: every STEP_S each burning cell may light its
##     eight neighbours, likelier downwind and where there is more fuel, less
##     in rain. A cell burns for its fuel's worth and never lights again. No
##     more than MAX_BURNING at once: past that the front waits.
##   * IT MARKS THE GROUND: a map the terrain shaders read (WeatherFx.set_burn)
##     -- burning cells glow, burnt ones are left black. The scars stay.
##   * IT REACHES BUILDINGS: a burning cell against a building lights it, and
##     the building fire takes it from there.
##   * People standing in it are burnt; the AI keeps out of where it burns and
##     loses sight in its smoke.
##
## Deterministic: where it starts, its wind and every spread from the rng.

const CELL := 4.0
const SPAN := 128                 ## cells each way of the player the map covers
const STEP_S := 0.25
const SPREAD := 0.22              ## per step, a full-fuel neighbour downwind
const BURN_S := 9.0               ## a cell's life at full fuel
const TREE_FUEL := 1.6
const MAX_BURNING := 180
const FLAMES := 36                ## flame emitters, on the burning cells nearest the camera
const SMOKES := 4
const PAWN_DAMAGE := 4.0          ## a step, standing in it
const START_MIN := 45.0           ## m upwind of the player it starts
const START_MAX := 80.0

## For the probe.
var burnt := 0
var peak_burning := 0
var buildings_lit := 0
var burnt_pawns := 0
var origin := Vector3.ZERO

var _wind_dir := Vector3.RIGHT
var _burning := {}                ## Vector2i -> seconds left
var _order: Array[Vector2i] = []  ## burning, in the order they caught
var _done := {}                   ## Vector2i -> true: burnt out
var _fuel := {}                   ## Vector2i -> fuel, cached
var _trees := {}                  ## Vector2i -> true
var _next := 0.0
var _img: Image
var _tex: ImageTexture
var _dirty := false
var _tex_next := 0.0
var _flames: Array[GPUParticles3D] = []
var _smokes: Array[GPUParticles3D] = []
var _lights: Array[OmniLight3D] = []
var _roar: AudioStreamPlayer3D
var _hazards: Array[int] = []
var _lit_buildings := {}


func _init() -> void:
	title = "Wildfire"
	warning_s = 4.0
	active_s = 120.0
	ending_s = 10.0


func _on_begin() -> void:
	var a := rng.randf() * TAU
	_wind_dir = Vector3(cos(a), 0.0, sin(a))
	_build()


func _on_phase(p: Phase) -> void:
	match p:
		Phase.ACTIVE:
			_start()
			ctx.set_storm(true)
		Phase.DONE:
			ctx.set_storm(false)
			ctx.gale = Vector3.ZERO
			ctx.set_screen(0.0, 0.0)
			ctx.set_weather(0.0, 1.0, 1.0)
			for i in _hazards:
				ctx.clear_hazard(i)
			_hazards.clear()
			for k in _burning.keys():
				_burn_out(k)
			_flush_tex()
			for f in _flames:
				f.emitting = false
			for s in _smokes:
				s.emitting = false
			for l in _lights:
				l.visible = false
			_roar.stop()


# --- The grid -------------------------------------------------------------------

func _key(p: Vector3) -> Vector2i:
	return Vector2i(floori((p.x - origin.x) / CELL), floori((p.z - origin.z) / CELL))


func _centre(k: Vector2i) -> Vector3:
	var x := origin.x + (k.x + 0.5) * CELL
	var z := origin.z + (k.y + 0.5) * CELL
	return Vector3(x, _ground(x, z), z)


func _ground(x: float, z: float) -> float:
	var stud := BrickWorld.get_stud_metres()
	return float(BrickTerrain.surface_plate(floori(x / stud), floori(z / stud)) + 1) \
			* BrickWorld.get_plate_metres()


## What a cell has to burn: its terrain, a tree, how wet, snow lying.
func _fuel_of(k: Vector2i) -> float:
	if _fuel.has(k):
		return _fuel[k]
	var f := 0.0
	if k.x >= 0 and k.y >= 0 and k.x < SPAN * 2 and k.y < SPAN * 2:
		var c := _centre(k)
		if c.y > BrickWave.get_sea_level() + 0.1:
			var stud := BrickWorld.get_stud_metres()
			var tm := BrickTerrain.material_at(floori(c.x / stud), floori(c.z / stud))
			var names: PackedStringArray = BrickTerrain.material_names()
			var name := names[tm].to_lower() if tm >= 0 and tm < names.size() else ""
			if name.contains("grass") or name.contains("moss") or name.contains("leaf"):
				f = 1.0
			elif name.contains("dirt") or name.contains("soil") or name.contains("mud"):
				f = 0.4
			elif name.contains("sand") or name.contains("stone") or name.contains("rock") \
					or name.contains("snow") or name.contains("gravel") or name.contains("ice"):
				f = 0.0
			else:
				f = 0.6
			if _trees.has(k):
				f += TREE_FUEL
	_fuel[k] = f
	return f


func _start() -> void:
	var at := ctx.player_pos()
	# The map round the player; the spark upwind, on something that burns.
	origin = Vector3(at.x - SPAN * CELL, 0.0, at.z - SPAN * CELL)
	var best := Vector3.INF
	for i in 60:
		var d := rng.randf_range(START_MIN, START_MAX)
		var p := at - _wind_dir.rotated(Vector3.UP, rng.randf_range(-0.5, 0.5)) * d
		if _fuel_of(_key(p)) >= 0.6:
			best = p
			break
	_fuel.clear()
	_find_trees()
	_img = Image.create(SPAN * 2, SPAN * 2, false, Image.FORMAT_RGBA8)
	_img.fill(Color(0, 0, 0, 0))
	_tex = ImageTexture.create_from_image(_img)
	WeatherFx.set_burn(_tex, Vector4(origin.x, origin.z, SPAN * 2 * CELL, SPAN * 2 * CELL))
	if best == Vector3.INF:
		best = at - _wind_dir * START_MIN
	# A few cells round the spark, so it takes.
	var k0 := _key(best)
	for dz in range(-1, 2):
		for dx in range(-1, 2):
			_catch(k0 + Vector2i(dx, dz))


func _find_trees() -> void:
	_trees.clear()
	var host = ctx.city
	var t = host.get("_trees")
	if t != null and t.rect.has_area():
		for spot in Trees.scatter(t.rect, t.world_seed, TerrainTrees.MAX_TREES):
			var o: Vector3 = Trees.placement(spot.cell, spot.variant).origin
			_trees[_key(o)] = true
	elif ctx.registry != null:
		for b in ctx.registry.buildings:
			if b.is_build() and b.build != null and String(b.build.name).begins_with("tree_"):
				_trees[_key(b.xform.origin)] = true


func _catch(k: Vector2i) -> bool:
	if _burning.has(k) or _done.has(k) or _burning.size() >= MAX_BURNING:
		return false
	var f := _fuel_of(k)
	if f <= 0.05:
		return false
	_burning[k] = BURN_S * f * rng.randf_range(0.8, 1.2)
	_order.append(k)
	_paint(k, false)
	return true


func _burn_out(k: Vector2i) -> void:
	_burning.erase(k)
	_order.erase(k)
	_done[k] = true
	burnt += 1
	_paint(k, true)


func _paint(k: Vector2i, out: bool) -> void:
	var px := k.x
	var py := k.y
	if px < 0 or py < 0 or px >= SPAN * 2 or py >= SPAN * 2:
		return
	_img.set_pixel(px, py, Color(1.0 if out else 0.5, 0.0 if out else 1.0, 0.0, 1.0))
	_dirty = true


func _flush_tex() -> void:
	if _dirty and _tex != null:
		_tex.update(_img)
		_dirty = false


# --- Ticks ----------------------------------------------------------------------

func _tick_warning(_dt: float) -> void:
	ctx.set_sky(phase_t / warning_s * 0.3, Color(1.0, 0.75, 0.5), Color(0.5, 0.42, 0.38),
			Color(0.85, 0.6, 0.45), 0.9)


func _tick_active(dt: float) -> void:
	_burn(dt)
	# Out of fuel: it ends early.
	if _burning.is_empty() and phase_t > 5.0:
		end_now()


func _tick_ending(dt: float) -> void:
	_burn(dt, false)


func _burn(dt: float, spread := true) -> void:
	var k_fire := clampf(float(_burning.size()) / 60.0, 0.0, 1.0)
	ctx.set_sky(0.3 + 0.5 * k_fire, Color(1.0, 0.7, 0.45), Color(0.45, 0.38, 0.34),
			Color(0.8, 0.55, 0.4), 0.8)
	ctx.gale = _wind_dir * 0.35
	_next -= dt
	if _next > 0.0:
		_visuals_later(dt)
		return
	_next += STEP_S
	var rain := 0.3 if ctx.raining else 1.0
	var wet := 1.0 - 0.7 * ctx.wet
	for k in _order.duplicate():
		_burning[k] = float(_burning[k]) - STEP_S * (1.0 / rain)
		if float(_burning[k]) <= 0.0:
			_burn_out(k)
			continue
		if not spread:
			continue
		for dz in range(-1, 2):
			for dx in range(-1, 2):
				if dx == 0 and dz == 0:
					continue
				var n: Vector2i = k + Vector2i(dx, dz)
				if _burning.has(n) or _done.has(n):
					continue
				var to := Vector3(dx, 0.0, dz).normalized()
				var downwind := 0.25 + 1.5 * maxf(0.0, to.dot(_wind_dir))
				var p := SPREAD * downwind * minf(_fuel_of(n), 1.5) * rain * wet * intensity
				if rng.randf() < p:
					_catch(n)
	peak_burning = maxi(peak_burning, _burning.size())
	_reach_buildings()
	_hurt_pawns()
	_mark_hazards()
	_visuals_later(dt)


## A burning cell against a building lights it: the building fire takes over.
func _reach_buildings() -> void:
	if ctx.registry == null:
		return
	for k in _order:
		var c := _centre(k)
		var id := ctx.building_at(c, CELL * 0.75)
		if id < 0 or _lit_buildings.has(id):
			continue
		_lit_buildings[id] = true
		if ctx.ignite(c + Vector3.UP * 1.3, 0.8):
			buildings_lit += 1


func _hurt_pawns() -> void:
	for p in ctx.pawns():
		if _burning.has(_key(p.feet())):
			if ctx.damage_pawns(p.chest(), 0.6, PAWN_DAMAGE * intensity) > 0:
				burnt_pawns += 1


## The burning ground as danger: blocks of 3 x 3 cells.
func _mark_hazards() -> void:
	for i in _hazards:
		ctx.clear_hazard(i)
	_hazards.clear()
	var blocks := {}
	for k in _order:
		blocks[Vector2i(floori(k.x / 3.0), floori(k.y / 3.0))] = true
	var i := 0
	for b in blocks:
		if i >= 60:
			break
		var lo := origin + Vector3(b.x * 3 * CELL, 0.0, b.y * 3 * CELL)
		var c := _centre(Vector2i(b.x * 3 + 1, b.y * 3 + 1))
		ctx.set_hazard(i, AABB(Vector3(lo.x, c.y - 1.0, lo.z), Vector3(3 * CELL, 5.0, 3 * CELL)))
		_hazards.append(i)
		i += 1


# --- Look and sound -------------------------------------------------------------

func _visuals_later(dt: float) -> void:
	_tex_next -= dt
	if _tex_next <= 0.0:
		_tex_next = 0.4
		_flush_tex()
		_place_visuals()


## Flames on the burning cells nearest the camera, smoke over the front, glow.
func _place_visuals() -> void:
	var cam := ctx.player_pos()
	var near: Array = []
	for k in _order:
		near.append([_centre(k).distance_squared_to(cam), k])
	near.sort_custom(func(a, b) -> bool: return a[0] < b[0])
	for i in _flames.size():
		var f := _flames[i]
		if i < near.size():
			var k: Vector2i = near[i][1]
			f.global_position = _centre(k)
			f.scale = Vector3.ONE * (2.2 if _trees.has(k) else 1.0)
			f.emitting = true
		else:
			f.emitting = false
	# Smoke and light over the burning cells spread far apart.
	for i in _smokes.size():
		var on := i < _order.size()
		_smokes[i].emitting = on
		_lights[i].visible = on
		if on:
			var k: Vector2i = _order[floori(float(i * _order.size()) / maxi(_smokes.size(), 1))]
			_smokes[i].global_position = _centre(k) + Vector3.UP * 3.0
			_lights[i].global_position = _centre(k) + Vector3.UP * 2.0
	if not near.is_empty():
		_roar.global_position = _centre(near[0][1])
		var d := sqrt(float(near[0][0]))
		_roar.volume_db = lerpf(4.0, -20.0, clampf(d / 80.0, 0.0, 1.0))
		if not _roar.playing:
			_roar.play()
		var k_near := clampf(1.0 - d / 60.0, 0.0, 1.0)
		ctx.set_screen(0.0, 0.15 + 0.35 * k_near, Color(0.45, 0.38, 0.33))
		ctx.set_weather(0.4 + 0.6 * k_near, 0.75, 1.5, intensity)


func _build() -> void:
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
	flame_quad.size = Vector2(1.6, 1.6)
	flame_quad.material = flame_mat
	var fp := ParticleProcessMaterial.new()
	fp.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	fp.emission_box_extents = Vector3(CELL * 0.5, 0.2, CELL * 0.5)
	fp.direction = Vector3.UP
	fp.spread = 12.0
	fp.initial_velocity_min = 1.6
	fp.initial_velocity_max = 3.6
	fp.gravity = Vector3(_wind_dir.x * 1.5, 1.2, _wind_dir.z * 1.5)
	fp.scale_min = 0.6
	fp.scale_max = 1.5
	var fg := Gradient.new()
	fg.offsets = PackedFloat32Array([0.0, 0.3, 0.7, 1.0])
	fg.colors = PackedColorArray([Color(1.0, 0.9, 0.5, 1.0), Color(1.0, 0.5, 0.1, 0.9),
			Color(0.8, 0.2, 0.05, 0.5), Color(0.2, 0.05, 0.02, 0.0)])
	var framp := GradientTexture1D.new()
	framp.gradient = fg
	fp.color_ramp = framp
	for i in FLAMES:
		var p := GPUParticles3D.new()
		p.amount = 26
		p.lifetime = 1.0
		p.emitting = false
		p.local_coords = false
		p.process_material = fp
		p.draw_pass_1 = flame_quad
		p.visibility_aabb = AABB(Vector3(-4, -1, -4), Vector3(8, 10, 8))
		add_child(p)
		_flames.append(p)

	var smoke_mat := StandardMaterial3D.new()
	smoke_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	smoke_mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	smoke_mat.vertex_color_use_as_albedo = true
	smoke_mat.albedo_texture = puff
	var smoke_quad := QuadMesh.new()
	smoke_quad.size = Vector2(8.0, 8.0)
	smoke_quad.material = smoke_mat
	var sp := ParticleProcessMaterial.new()
	sp.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	sp.emission_sphere_radius = 6.0
	sp.direction = Vector3.UP
	sp.spread = 15.0
	sp.initial_velocity_min = 3.0
	sp.initial_velocity_max = 5.0
	sp.gravity = Vector3(_wind_dir.x * 2.0, 0.6, _wind_dir.z * 2.0)
	sp.scale_min = 1.0
	sp.scale_max = 2.6
	var sg := Gradient.new()
	sg.offsets = PackedFloat32Array([0.0, 0.2, 1.0])
	sg.colors = PackedColorArray([Color(0.15, 0.13, 0.12, 0.0), Color(0.16, 0.14, 0.13, 0.8),
			Color(0.35, 0.34, 0.33, 0.0)])
	var sramp := GradientTexture1D.new()
	sramp.gradient = sg
	sp.color_ramp = sramp
	for i in SMOKES:
		var s := GPUParticles3D.new()
		s.amount = 70
		s.lifetime = 12.0
		s.emitting = false
		s.local_coords = false
		s.process_material = sp
		s.draw_pass_1 = smoke_quad
		s.visibility_aabb = AABB(Vector3(-60, -5, -60), Vector3(120, 90, 120))
		add_child(s)
		_smokes.append(s)
		var l := OmniLight3D.new()
		l.light_color = Color(1.0, 0.5, 0.18)
		l.light_energy = 8.0
		l.omni_range = 22.0
		l.visible = false
		add_child(l)
		_lights.append(l)
	_roar = AudioStreamPlayer3D.new()
	_roar.stream = DisasterSounds.fire()
	_roar.unit_size = 20.0
	_roar.max_distance = 200.0
	add_child(_roar)
