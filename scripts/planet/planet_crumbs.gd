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
## Kept planet-local, so the floating origin's shift moves nothing here.

const KICK := 1.2
const SCATTER := 0.6
const SPIN := 5.0
const LIE_MS := 1400
const FADE_MS := 350
## Metres a ray looks down for a crumb's floor.
const FLOOR_REACH := 60.0

class Set:
	var mmi: MultiMeshInstance3D
	var pos := PackedVector3Array()      ## planet-local
	var vel := PackedVector3Array()
	var base: Array[Basis] = []
	var axis := PackedVector3Array()
	var rate := PackedFloat32Array()
	var born := PackedInt64Array()
	var landed := PackedInt64Array()     ## ms it came to rest, 0 while falling
	var floor_r := PackedFloat32Array()  ## the floor's distance from the planet's centre
	var half_h := PackedFloat32Array()
	var colour := PackedColorArray()

	func remove(i: int) -> void:
		var last := pos.size() - 1
		if i != last:
			pos[i] = pos[last]
			vel[i] = vel[last]
			base[i] = base[last]
			axis[i] = axis[last]
			rate[i] = rate[last]
			born[i] = born[last]
			landed[i] = landed[last]
			floor_r[i] = floor_r[last]
			half_h[i] = half_h[last]
			colour[i] = colour[last]
		pos.resize(last)
		vel.resize(last)
		base.resize(last)
		axis.resize(last)
		rate.resize(last)
		born.resize(last)
		landed.resize(last)
		floor_r.resize(last)
		half_h.resize(last)
		colour.resize(last)

var planet: Node3D
var _sets := {}
var thrown := 0
var alive := 0


func setup(p: Node3D) -> void:
	name = "Crumbs"
	planet = p


## Bricks `ids` of chunk `source` (in `world`) thrown as crumbs, moving at
## `linear` (world) as their group was. Call before the bricks are freed.
func throw(world: BrickWorld, source: int, ids: PackedInt32Array, linear := Vector3.ZERO) -> int:
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
	var now := Time.get_ticks_msec()
	var n := 0
	for id in ids:
		if world.is_block_decorative(source, id):
			continue
		var t: Array = world.get_block_ticks(source, id)
		if t.is_empty():
			continue
		var size := Vector3(t[1] as Vector3i) * tick_m
		var local := (Vector3(t[0] as Vector3i) + Vector3(t[1] as Vector3i) * 0.5) * tick_m
		var st := _set_for(size.snapped(Vector3.ONE * 0.001))
		var vel := linear + kick + (Gravity.flat(Vector3(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0),
				randf_range(-1.0, 1.0)), up) + up * randf_range(0.0, 1.0)) * SCATTER
		var ax := Vector3(randf() - 0.5, randf() - 0.5, randf() - 0.5)
		st.pos.append(to_planet * (xf * local))
		st.vel.append(to_planet.basis * vel)
		st.base.append(frame_basis)
		st.axis.append(ax.normalized() if ax.length() > 0.01 else Vector3.UP)
		st.rate.append(randf_range(-SPIN, SPIN))
		st.born.append(now)
		st.landed.append(0)
		st.floor_r.append(floor_r)
		st.half_h.append(size.y * 0.5)
		st.colour.append(BrickWorld.get_filament_colour(world.get_block_colour(source, id)))
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
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = PieceMeshes.chamfered_box(key)
	mmi.multimesh = mm
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.85
	mmi.material_override = mat
	add_child(mmi)
	st.mmi = mmi
	_sets[key] = st
	return st


## Fall, stop on the floor, lie, shrink, go. Planet-local throughout; drawn
## through this node's own transform.
func _physics_process(delta: float) -> void:
	if _sets.is_empty() or planet == null:
		return
	var now := Time.get_ticks_msec()
	var g := Gravity.strength() * PlanetPieces.GRAVITY_SCALE
	var to_here := global_transform.affine_inverse() * planet.global_transform
	for key in _sets:
		var st: Set = _sets[key]
		var i := st.pos.size() - 1
		while i >= 0:
			var gone := false
			if st.landed[i] == 0:
				var p := st.pos[i]
				var up := p.normalized()
				st.vel[i] -= up * g * delta
				p += st.vel[i] * delta
				if p.length() - st.half_h[i] <= st.floor_r[i]:
					p = up * (st.floor_r[i] + st.half_h[i])
					st.vel[i] = Vector3.ZERO
					st.landed[i] = now
					# It lies as it was turned when it came down.
					st.base[i] = Basis(st.axis[i], st.rate[i] * float(now - st.born[i]) / 1000.0) * st.base[i]
				st.pos[i] = p
			elif now - st.landed[i] > LIE_MS + FADE_MS:
				gone = true
			if gone:
				st.remove(i)
				alive -= 1
			i -= 1
		var mm := st.mmi.multimesh
		var n := st.pos.size()
		if mm.instance_count < n or mm.instance_count > n * 4 + 32:
			mm.instance_count = maxi(n * 2, 16)
		mm.visible_instance_count = n
		for k in n:
			var age := float(now - st.born[k]) / 1000.0
			var b: Basis = st.base[k]
			if st.landed[k] == 0:
				b = Basis(st.axis[k], st.rate[k] * age) * b
			var s := 1.0
			if st.landed[k] != 0:
				s = 1.0 - clampf(float(now - st.landed[k] - LIE_MS) / FADE_MS, 0.0, 1.0)
			mm.set_instance_transform(k, to_here * Transform3D(b.scaled(Vector3.ONE * maxf(s, 0.001)), st.pos[k]))
			mm.set_instance_color(k, st.colour[k])
