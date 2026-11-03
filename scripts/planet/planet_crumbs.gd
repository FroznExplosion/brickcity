class_name PlanetCrumbs
extends Node3D

## The small groups a planet building sheds (Docs/Planets.md 11.11, D2 step 2):
## each brick thrown as a crumb -- the city's (IslandManager._add_crumbs, its
## chamfered boxes in the brick's own colour), but falling along the planet's
## down (Gravity.down_at), never -Y. A crumb is presentation only: no collision,
## nothing for the AI. It falls from where its brick was with a kick out of the
## face and a spin, stops on the first thing under it (one ray along down when
## it is thrown), lies LIE_MS, then shrinks away over FADE_MS.
##
## Drawn by the city's crumb shader (shaders/crumb.gdshader, `radial`;
## Docs/GpuOffload.md 2.1): a crumb is written when it is thrown, when it lands
## and when it goes. The fall, the spin and the shrink are the shader's, from the
## same sums as `_pos` -- down is toward the centre from where the fall starts,
## a straight line over a few metres. It was a step and a write of every crumb
## every tick. Only a wind (a breached hull) steps crumbs a tick at a time
## again, the ones it pushes.
##
## Kept planet-local, so the floating origin's shift moves nothing here; the
## MultiMeshes are drawn through the planet's transform.

const KICK := 1.2
const SCATTER := 0.6
const SPIN := IslandManager.CRUMB_SPIN
const LIE_MS := 1400
const FADE_MS := 350
## Metres a ray looks down for a crumb's floor.
const FLOOR_REACH := 60.0

class Set:
	var mmi: MultiMeshInstance3D
	var pos := PackedVector3Array()      ## planet-local, where this stretch starts
	var vel := PackedVector3Array()      ## planet-local, at the start of the stretch
	var base: Array[Basis] = []
	var axis := PackedVector3Array()     ## as the shader decodes it
	var rate := PackedFloat32Array()
	var spin := PackedFloat32Array()     ## packed, IslandManager.crumb_pack_spin
	var born := PackedInt64Array()       ## tick it started spinning from `base`
	var t0 := PackedInt64Array()         ## tick this stretch starts
	var t_end := PackedInt64Array()      ## tick it reaches its floor (or landed)
	var landed := PackedByteArray()
	var floor_r := PackedFloat32Array()  ## the floor's distance from the planet's centre
	var half_h := PackedFloat32Array()
	var colour := PackedFloat32Array()   ## 8 bits a channel in one number
	var next := PackedInt64Array()       ## tick the CPU looks at it again
	var soonest := 0

	func remove(i: int) -> void:
		var last := pos.size() - 1
		if i != last:
			pos[i] = pos[last]
			vel[i] = vel[last]
			base[i] = base[last]
			axis[i] = axis[last]
			rate[i] = rate[last]
			spin[i] = spin[last]
			born[i] = born[last]
			t0[i] = t0[last]
			t_end[i] = t_end[last]
			landed[i] = landed[last]
			floor_r[i] = floor_r[last]
			half_h[i] = half_h[last]
			colour[i] = colour[last]
			next[i] = next[last]
		pos.resize(last)
		vel.resize(last)
		base.resize(last)
		axis.resize(last)
		rate.resize(last)
		spin.resize(last)
		born.resize(last)
		t0.resize(last)
		t_end.resize(last)
		landed.resize(last)
		floor_r.resize(last)
		half_h.resize(last)
		colour.resize(last)
		next.resize(last)

var planet: Node3D
var _sets := {}
## A push on every crumb, world m/s^2 at a world point -- the air rushing out of a
## breached hull (SpaceStation, Docs/Hulls.md 4) -- or none. One strong enough
## lifts a crumb that lay down.
var wind := Callable()
const WIND_LIFT := 2.0
var thrown := 0
var alive := 0
## Times the CPU wrote a crumb (thrown, landed, gone, blown), for probes.
var events := 0

var _mat: ShaderMaterial
var _dt := 1.0 / 60.0
var _g := 0.0
var _lie := 84
var _fade := 21


func setup(p: Node3D) -> void:
	name = "Crumbs"
	planet = p


## Bricks `ids` of chunk `source` (in `world`) thrown as crumbs, moving at
## `linear` (world) as their group was. Call before the bricks are freed. A
## blast's (`core` > 0, centred on `core_at`): those within `core` of it are
## gone, not thrown (IslandManager.BLAST_CORE), the rest thrown out from it.
func throw(world: BrickWorld, source: int, ids: PackedInt32Array, linear := Vector3.ZERO,
		core_at := Vector3.INF, core := 0.0) -> int:
	_material()
	_constants()
	var xf := world.get_chunk_transform(source)
	var tick_m: float = BrickWorld.get_cell_size().x / float(BrickWorld.ticks_per_stud())
	var to_planet := planet.global_transform.affine_inverse()
	var box := world.get_blocks_box(source, ids)
	var centre: Vector3 = xf * box.get_center()
	var up := Gravity.up_at(centre)
	# Off the face it came from: away from the middle of its source's grid.
	var mid: Vector3 = xf * (Vector3(world.get_chunk_dims(source)) * BrickWorld.get_cell_size() * 0.5)
	var out := Gravity.flat(centre - mid, up)
	var out_dir := out.normalized() if out.length() > 0.01 else Vector3.ZERO
	var kick := out_dir * randf_range(0.3, 1.0) * KICK
	var floor_r := _floor_r(centre + kick * 0.4)
	var frame_basis := to_planet.basis * xf.basis.orthonormalized()
	var now := Engine.get_physics_frames()
	var n := 0
	for id in ids:
		if world.is_block_decorative(source, id):
			continue
		var t: Array = world.get_block_ticks(source, id)
		if t.is_empty():
			continue
		var size := Vector3(t[1] as Vector3i) * tick_m
		var local := (Vector3(t[0] as Vector3i) + Vector3(t[1] as Vector3i) * 0.5) * tick_m
		var at: Vector3 = xf * local
		var away := Vector3.ZERO
		if core > 0.0:
			if at.distance_to(core_at) < core:
				continue
			away = (at - core_at).normalized() * randf_range(1.0, 3.0)
		var st := _set_for(size.snapped(Vector3.ONE * 0.001))
		var vel := linear + kick + away + (Gravity.flat(Vector3(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0),
				randf_range(-1.0, 1.0)), up) + up * randf_range(0.0, 1.0)) * SCATTER
		var ax := Vector3(randf() - 0.5, randf() - 0.5, randf() - 0.5)
		# Its spin kept as the shader reads it, so it lies as it was drawn.
		var sp := IslandManager.crumb_pack_spin(ax.normalized() if ax.length() > 0.01 else Vector3.UP,
				randf_range(-SPIN, SPIN))
		var c := BrickWorld.get_filament_colour(world.get_block_colour(source, id))
		st.pos.append(to_planet * at)
		st.vel.append(to_planet.basis * vel)
		st.base.append(frame_basis)
		st.axis.append(sp[1])
		st.rate.append(sp[2])
		st.spin.append(sp[0])
		st.born.append(now)
		st.t0.append(now)
		st.t_end.append(now)
		st.landed.append(0)
		st.floor_r.append(floor_r)
		st.half_h.append(size.y * 0.5)
		st.colour.append(float((clampi(int(round(c.r * 255.0)), 0, 255) << 16)
				| (clampi(int(round(c.g * 255.0)), 0, 255) << 8) | clampi(int(round(c.b * 255.0)), 0, 255)))
		st.next.append(now)
		var i := st.pos.size() - 1
		_plan(st, i)
		var mm := st.mmi.multimesh
		if mm.instance_count < st.pos.size():
			# Growing a MultiMesh clears it: every crumb written again.
			mm.instance_count = maxi(st.pos.size() * 2, 16)
			for j in st.pos.size():
				_write(st, j)
		else:
			_write(st, i)
		mm.visible_instance_count = st.pos.size()
		st.soonest = mini(st.soonest, st.next[i]) if i > 0 else st.next[i]
		events += 1
		n += 1
	thrown += n
	alive += n
	return n


## The floor under world point `from`: its distance from the planet's centre.
## The first thing a ray along down meets (the ground, a building, a settled
## piece); missed, the planet's own ground there.
func _floor_r(from: Vector3) -> float:
	var c := planet.global_position
	var down := Gravity.down_at(from)
	if is_inside_tree():
		var q := PhysicsRayQueryParameters3D.create(from - down * 0.5, from + down * FLOOR_REACH,
				Layers.WORLD | Layers.STRUCTURE | Layers.DEBRIS)
		var hit := get_world_3d().direct_space_state.intersect_ray(q)
		if not hit.is_empty():
			return (hit.position as Vector3).distance_to(c)
	var g := Gravity.ground_height(from)
	return Gravity.planet_radius + (g if not is_nan(g) else 0.0)


func _set_for(key: Vector3) -> Set:
	if _sets.has(key):
		return _sets[key]
	var st := Set.new()
	var mmi := MultiMeshInstance3D.new()
	mmi.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	# Drawn through the planet (_process), whatever this node hangs under.
	mmi.top_level = true
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = PieceMeshes.chamfered_box(key)
	# Where a crumb is drawn is the shader's: the instances are where each
	# stretch began.
	mm.custom_aabb = AABB(Vector3(-1e5, -1e5, -1e5), Vector3(2e5, 2e5, 2e5))
	mmi.multimesh = mm
	mmi.material_override = _material()
	add_child(mmi)
	if planet != null:
		mmi.global_transform = planet.global_transform
	st.mmi = mmi
	_sets[key] = st
	return st


func _material() -> ShaderMaterial:
	if _mat == null:
		_mat = ShaderMaterial.new()
		_mat.shader = load("res://shaders/crumb.gdshader")
		_mat.set_shader_parameter("spin_max", SPIN)
		_mat.set_shader_parameter("radial", true)
		_mat.set_shader_parameter("fade_from_stop", true)
		_g = -1.0
		_constants()
	return _mat


## The tick, gravity and how long a crumb lies -- the shader's copies kept
## with them.
func _constants() -> void:
	var tps := float(Engine.physics_ticks_per_second)
	var g := Gravity.strength() * PlanetPieces.GRAVITY_SCALE
	if _mat == null or (g == _g and 1.0 / tps == _dt):
		return
	_dt = 1.0 / tps
	_g = g
	_lie = int(LIE_MS * tps / 1000.0)
	_fade = maxi(int(FADE_MS * tps / 1000.0), 1)
	_mat.set_shader_parameter("tick_s", _dt)
	_mat.set_shader_parameter("gravity", _g)
	_mat.set_shader_parameter("full", float(_lie))
	_mat.set_shader_parameter("life", float(_lie + _fade))


## Where crumb `i` is at tick `now` (planet-local), and how fast: the stretch
## stepped on a tick at a time (v -= g dt along down, then p += v dt) in closed
## form, as the shader does.
func _pos(st: Set, i: int, now: int) -> Vector3:
	var n := float(clampi(now, st.t0[i], maxi(st.t_end[i], st.t0[i])) - st.t0[i])
	var p0 := st.pos[i]
	return p0 + st.vel[i] * (n * _dt) - p0.normalized() * (_g * _dt * _dt * n * (n + 1.0) * 0.5)


func _vel(st: Set, i: int, now: int) -> Vector3:
	if st.landed[i] != 0:
		return Vector3.ZERO
	var n := float(clampi(now, st.t0[i], maxi(st.t_end[i], st.t0[i])) - st.t0[i])
	return st.vel[i] - st.pos[i].normalized() * (_g * _dt * n)


## Crumb `i`'s turn at tick `now`: its base spun on from when it set off.
func _turned(st: Set, i: int, now: int) -> Basis:
	var ticks := clampi(now, st.born[i], maxi(st.t_end[i], st.born[i])) - st.born[i]
	return Basis(st.axis[i], st.rate[i] * float(ticks) * _dt) * st.base[i]


## When crumb `i` next needs the CPU: it reaches its floor, or it is gone.
func _plan(st: Set, i: int) -> void:
	if st.landed[i] != 0:
		st.t_end[i] = st.t0[i]
		st.next[i] = st.t0[i] + _lie + _fade
		return
	var up := st.pos[i].normalized()
	var h := st.pos[i].length() - st.half_h[i] - st.floor_r[i]
	st.t_end[i] = st.t0[i] + IslandManager.ticks_to_floor(h, st.vel[i].dot(up), _g, _dt)
	st.next[i] = st.t_end[i]


## Crumb `i` as the shader reads it (shaders/crumb.gdshader, its header).
func _write(st: Set, i: int) -> void:
	var mm := st.mmi.multimesh
	mm.set_instance_transform(i, Transform3D(st.base[i], st.pos[i]))
	mm.set_instance_color(i, Color(st.colour[i], st.spin[i], float(st.t_end[i]), float(st.born[i])))
	var v := st.vel[i]
	mm.set_instance_custom_data(i, Color(v.x, v.y, v.z, float(st.t0[i])))


## Every crumb there is, where it is now (planet-local), for probes.
func positions() -> PackedVector3Array:
	var out := PackedVector3Array()
	var now := Engine.get_physics_frames()
	for key in _sets:
		var st: Set = _sets[key]
		for i in st.pos.size():
			out.append(_pos(st, i, now))
	return out


## Land, lie, go -- for the crumbs whose tick it is; and the wind's push.
func _physics_process(delta: float) -> void:
	if alive == 0 or planet == null:
		return
	_constants()
	var now := Engine.get_physics_frames()
	var blow := wind.is_valid()
	var pxf := planet.global_transform
	var to_local := pxf.basis.inverse()
	for key in _sets:
		var st: Set = _sets[key]
		if st.pos.is_empty() or (st.soonest > now and not blow):
			continue
		var soonest := 9223372036854775807
		var i := 0
		while i < st.pos.size():
			if blow:
				_blow(st, i, now, delta, pxf, to_local)
			if st.next[i] <= now:
				events += 1
				if st.landed[i] != 0:
					st.remove(i)
					alive -= 1
					if i < st.pos.size():
						_write(st, i)
					continue   # the last one is in its place now
				# Down: on its floor, as it was turned when it came down.
				var up := _pos(st, i, now).normalized()
				st.base[i] = _turned(st, i, now)
				st.pos[i] = up * (st.floor_r[i] + st.half_h[i])
				st.vel[i] = Vector3.ZERO
				st.born[i] = now
				st.t0[i] = now
				st.landed[i] = 1
				_plan(st, i)
				_write(st, i)
			soonest = mini(soonest, st.next[i])
			i += 1
		st.soonest = soonest
		st.mmi.multimesh.visible_instance_count = st.pos.size()


## The wind on crumb `i` this tick: a falling one pushed, one lying down picked
## up by a strong one. Either way a new stretch starts from here.
func _blow(st: Set, i: int, now: int, delta: float, pxf: Transform3D, to_local: Basis) -> void:
	var p := _pos(st, i, now)
	var a: Vector3 = wind.call(pxf * p)
	if a == Vector3.ZERO:
		return
	var al := to_local * a
	var v := _vel(st, i, now)
	if st.landed[i] != 0:
		if al.length() <= WIND_LIFT:
			return
		# Picked up off the floor: a hop, so it is carried, not dragged.
		st.landed[i] = 0
		v = al * 0.15 + p.normalized() * 0.6
	else:
		v += al * delta
		st.base[i] = _turned(st, i, now)
	st.born[i] = now
	st.pos[i] = p
	st.vel[i] = v
	st.t0[i] = now
	_plan(st, i)
	_write(st, i)
	events += 1


func _process(_delta: float) -> void:
	if alive == 0 or planet == null or _mat == null:
		return
	IslandManager.crumb_clock()
	var pxf := planet.global_transform
	_mat.set_shader_parameter("frame", Projection(pxf))
	for key in _sets:
		(_sets[key] as Set).mmi.global_transform = pxf
