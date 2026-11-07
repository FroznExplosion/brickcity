extends Node

## Crumbs: a small piece is not a body (Docs/DestructionLod.md). What breaks
## off small is drawn as crumbs -- instanced, settling on the floor under it,
## crumbling away -- instead of a physics piece each.
##
## A part of the island manager, made by it (IslandManager.crumbler), and moved
## out of island_manager.gd so this is in one place. It reads the manager
## through `host` -- typed against its script, so a name the manager no longer
## has is a parse error here.

const Host := preload("res://scripts/island_manager.gd")

var host: Host

## Full size this long, then shrinking to nothing at CRUMB_LIFE_MS.
const CRUMB_FULL_MS := 350

## m/s: away from its building, at most -- off the face it came from.
const CRUMB_KICK := 1.2

const CRUMB_FLOOR_MASK := Layers.WORLD | Layers.STRUCTURE | Layers.DEBRIS

## A crumb's floor asked again on landing (_crumb_floor_gone), from this far
## over where it was; lower by more than the slack, it had gone.
const CRUMB_FLOOR_RECHECK := 0.3

const CRUMB_FLOOR_SLACK := 0.05

const CRUMB_REST_SPEED := 1.5

const CRUMB_SLIDE := 0.5

var crumb_bounces := 0   ## times a crumb bounced

## A thrown brick that is out past the face of the hole before it has dropped
## this far below what is under the hole comes down outside (_add_crumbs): a
## course, so the bottom row of a ring leaves over the sill it stood on.
const CRUMB_SILL := 0.45

const CRUMB_FADE_MS := 600

var crumb_update_ms := 0.0   ## _update_crumbs, all told

var crumb_events := 0        ## of that, things that happened to a crumb (_crumb_event)

var crumb_scanned := 0       ## crumbs looked at to find them

var crumb_ticks := 0         ## ticks with crumbs

var lay_us := 0              ## of that, laying crumbs that stopped in the heap (BrickHeap)

var crumb_peak := 0          ## the most drawn at once

var crumble_parts := [0.0, 0.0, 0.0]  ## ms, all told: drawing, cutting out, deciding

var crumb_floors_gone := 0   ## crumbs whose floor had gone when they reached it

var _crumb_mat: ShaderMaterial

var _crumb_dt := 1.0 / 60.0

var _crumb_g := 9.8

var _crumb_keep := false

var _crumb_life := 84

var _crumb_full := 21

var _crumb_fall_max := 360

var _crumb_fade := 36

var _crumb_constants_set := false


func _init(h: Node3D) -> void:
	host = h
	name = "Crumbs"


## What comes off a PIECE -- shot apart, struck, broken by its own landing -- and
## is LANDMARK_COUNT bricks or fewer is crumbs, not a body, landmark-sized or
## not: wreckage coming apart into bricks. They were the most of what a
## collapse made: 9-48 bricks, 141 bodies in a --big --shot, 91 of them from
## shots at pieces (body_census, 2026-10-02). The host's decision, and it
## travels in the DETACH as FLAG_GONE, so nobody keeps a body of it -- a
## landmark is something every machine has or none does.
func crumbles_off_a_piece(chunk: int, ids: PackedInt32Array) -> bool:
	# Read once, not per pass of the loop below: the scene never swaps these.
	var h_world := host.world
	if not host.decides or ids.size() > Host.LANDMARK_COUNT or ids.size() <= Host.DEBRIS_MAX_BLOCKS:
		return false
	var furniture := true
	for id in ids:
		if not h_world.is_block_decorative(chunk, id):
			furniture = false
			break
	return not furniture and not host._in_wind(host._group_box(chunk, ids))


## Crumble a small piece if it is one: out of its source, and drawn as crumbs if
## it can be seen. Host.CRUMB_NOT, and nothing done, for anything else.
func crumble(source: int, block_ids: PackedInt32Array, linear: Vector3,
		limit := Host.DEBRIS_MAX_BLOCKS) -> int:
	# Read once, not per pass of the loop below: the scene never swaps these.
	var h_world := host.world
	var n := block_ids.size()
	if n == 0 or n > limit:
		return Host.CRUMB_NOT
	var furniture := true
	for id in block_ids:
		if not h_world.is_block_decorative(source, id):
			furniture = false
			break
	if furniture:
		return Host.CRUMB_NOT
	var box := host._group_box(source, block_ids)
	# Decided already when the DETACH said so (_crumbles_off_a_piece): the wind
	# was asked then, and the blocks have to go now either way.
	if limit == Host.DEBRIS_MAX_BLOCKS and host._in_wind(box):
		return Host.CRUMB_NOT
	var t0 := Time.get_ticks_usec()
	var dist := INF
	if host.camera != null and is_instance_valid(host.camera):
		dist = Host._distance_to_box(box, host.camera.global_position)
	var far := dist > Host.SMALL_KEEP_RANGE and dist < INF
	var shown := not far and host._box_seen(box)
	if shown and host.crumb_count + n > Host.CRUMBS_MAX:
		host.crumbs_over += n
		shown = false
	var t_add := Time.get_ticks_usec()
	if shown:
		add_crumbs(source, block_ids, box, linear)
		host.crumbled += 1
	elif far:
		host.tiny_deleted += n
	else:
		host.discarded += n
	crumble_parts[0] += float(Time.get_ticks_usec() - t_add) / 1000.0
	# Out of the source the way every piece goes, and the grid it was given
	# freed at once (_delete_where_it_is says why not killed in place).
	var t_cut := Time.get_ticks_usec()
	var cut: Dictionary = h_world.split_island(source, block_ids)
	if not cut.is_empty():
		h_world.release_chunk(int(cut.chunk))
	crumble_parts[1] += float(Time.get_ticks_usec() - t_cut) / 1000.0
	crumble_parts[2] += float(t_add - t0) / 1000.0
	host.crumble_worst_ms = maxf(host.crumble_worst_ms, float(Time.get_ticks_usec() - t0) / 1000.0)
	return Host.CRUMB_DRAWN if shown else Host.CRUMB_GONE


func crumb_cost_line() -> String:
	return "crumbs of every kind: %d at once at the most, moving them %.1f ms all told (laying the ones that stopped %.1f), %.2f the worst tick; %d ticks, %d events, %d looked at" % [
			crumb_peak, crumb_update_ms, float(lay_us) / 1000.0, host.crumb_worst_ms, crumb_ticks,
			crumb_events, crumb_scanned]


## `burst` and `throw`: thrown from a blast at `burst` (throw_killed) -- `throw`
## m/s off the face at most instead of CRUMB_KICK, and each brick its own way
## from the middle of the blast as well.
func add_crumbs(source: int, block_ids: PackedInt32Array, box: AABB, linear: Vector3,
		burst := Vector3.ZERO, throw := 0.0) -> void:
	# Read once, not per pass of the loop below: the scene never swaps these.
	var h_world := host.world
	var xf: Transform3D = h_world.get_chunk_transform(source)
	var tick_m: float = BrickWorld.get_cell_size().x / float(BrickWorld.ticks_per_stud())
	var centre := box.get_center()
	# Off the face it came from: away from the middle of its source's grid.
	var mid: Vector3 = xf * (Vector3(h_world.get_chunk_dims(source)) * BrickWorld.get_cell_size() * 0.5)
	var out := Vector3(centre.x - mid.x, 0.0, centre.z - mid.z)
	var out_dir := out.normalized() if out.length() > 0.01 else Vector3.ZERO
	# A blast's are out of the wall before they have dropped a brick's height:
	# slower, they sank through the wall under the hole on the way.
	var kick := out_dir * (randf_range(0.6, 1.0) * throw if throw > 0.0
			else randf_range(0.3, 1.0) * CRUMB_KICK)
	# Where it comes down: one ray, from where the kick takes it, down onto the
	# ground, a building or settled wreckage -- not onto anything still falling.
	var floor_y := -INF
	# A blast's ring reaches metres into a building, and is thrown harder: one
	# floor for all of it had the bricks that cleared the wall lying in the air
	# beside the hole, at the height of the storey's floor. So two rays: what
	# is under the hole, and what is under the air a metre past its face. A
	# brick that is out past the face before it has dropped CRUMB_SILL below
	# the first comes down on the second.
	var floor_past := -INF
	var fixed_y := 0
	var fixed_past := 0
	var face := INF
	var g := 0.0
	if throw > 0.0:
		floor_y = crumb_floor(Vector3(centre.x, box.position.y, centre.z))
		fixed_y = 1 if host._floor_on_ground else 0
		if out_dir != Vector3.ZERO:
			var reach := (absf(out_dir.x) * box.size.x + absf(out_dir.z) * box.size.z) * 0.5
			face = centre.dot(out_dir) + reach
			floor_past = crumb_floor(Vector3(centre.x, box.end.y, centre.z) + out_dir * (reach + 1.0))
			fixed_past = 1 if host._floor_on_ground else 0
		g = Gravity.strength() * Host.DEBRIS_GRAVITY
	else:
		floor_y = crumb_floor(centre + kick * 0.4)
		fixed_y = 1 if host._floor_on_ground else 0
	var frame_basis := xf.basis.orthonormalized()
	var now := Engine.get_physics_frames()
	for id in block_ids:
		if h_world.is_block_decorative(source, id):
			continue
		var t: Array = h_world.get_block_ticks(source, id)
		if t.is_empty():
			continue
		var size := Vector3(t[1] as Vector3i) * tick_m
		var local := (Vector3(t[0] as Vector3i) + Vector3(t[1] as Vector3i) * 0.5) * tick_m
		var cr := crumb_set(size.snapped(Vector3.ONE * 0.001))
		var axis := Vector3(randf() - 0.5, randf() - 0.5, randf() - 0.5)
		var from_blast := Vector3.ZERO
		if throw > 0.0:
			var away: Vector3 = xf * local - burst
			if away.length() > 0.01:
				from_blast = away.normalized() * throw * randf_range(0.2, 0.6)
		var at: Vector3 = xf * local
		var vel := linear + kick + from_blast + Vector3(randf_range(-1.0, 1.0),
				randf_range(0.0, 1.0), randf_range(-1.0, 1.0)) * Host.CRUMB_SCATTER
		var lands_on := floor_y
		var lands_fixed := fixed_y
		if face < INF:
			var speed_out := vel.dot(out_dir)
			var to_face := face - at.dot(out_dir)
			if floor_y == -INF or to_face <= 0.0:
				lands_on = floor_past
				lands_fixed = fixed_past
			elif speed_out > 0.05:
				# How far it has dropped by the time it is out past the face.
				var clear := to_face / speed_out
				var foot := at.y - size.y * 0.5 + vel.y * clear - 0.5 * g * clear * clear
				if foot > floor_y - CRUMB_SILL:
					lands_on = floor_past
					lands_fixed = fixed_past
		crumb_push(cr, at, vel, frame_basis, axis, randf_range(-Host.CRUMB_SPIN, Host.CRUMB_SPIN), now,
				lands_on, size.y * 0.5,
				BrickWorld.get_filament_colour(h_world.get_block_colour(source, id)), lands_fixed)


## The first thing under `from` a crumb stops on, or -INF. Whether that was
## the ground itself (Layers.WORLD) is left in _floor_on_ground.
func crumb_floor(from: Vector3) -> float:
	host._floor_on_ground = false
	if not host.is_inside_tree():
		return -INF
	var q := PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * 300.0,
			CRUMB_FLOOR_MASK)
	var hit := host.get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		return -INF
	host._floor_on_ground = hit.collider is CollisionObject3D 			and ((hit.collider as CollisionObject3D).collision_layer & Layers.WORLD) != 0
	return (hit.position as Vector3).y


## A crumb's floor is asked once, when it comes loose, and a fall takes a
## second or more: what it was going to land on may have gone meanwhile -- the
## storey a blast's ring came down on breaking off and falling as a section,
## a settled piece woken. It was laid where that floor had been, in mid-air,
## and lay there for good (user, 2026-10-17: "single bricks ... settle on a
## falling part of a building then stay there floating"). So on reaching it the
## floor is asked again, from a little above: gone or lower, the crumb falls on
## to the new one. True when it does.
func crumb_floor_gone(cr: Host.Crumbs, i: int, p: Vector3) -> bool:
	var was := cr.floor_y[i]
	if not is_finite(was):
		return false
	var now_y := crumb_floor(Vector3(p.x, was + CRUMB_FLOOR_RECHECK, p.z))
	if now_y >= was - CRUMB_FLOOR_SLACK:
		return false
	cr.floor_y[i] = now_y
	cr.on_ground[i] = 1 if host._floor_on_ground else 0
	crumb_floors_gone += 1
	return true


func crumb_set(key: Vector3) -> Host.Crumbs:
	if host._crumbs.has(key):
		return host._crumbs[key]
	var cr := Host.Crumbs.new()
	var mmi := MultiMeshInstance3D.new()
	mmi.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = PieceMeshes.chamfered_box(key)
	# Where a crumb is drawn is the shader's: the instance transforms are where
	# each began, so the box they make says nothing about where they are now.
	mm.custom_aabb = AABB(Vector3(-1e5, -1e5, -1e5), Vector3(2e5, 2e5, 2e5))
	mmi.multimesh = mm
	mmi.material_override = _crumb_material()
	host.add_child(mmi)
	cr.mmi = mmi
	host._crumbs[key] = cr
	return cr


## Fall, stop on the floor, shrink, go. Once a tick, after the pieces -- but
## only for the crumbs something happens to this tick (`next`): the falling
## itself is drawn by the shader (shaders/crumb.gdshader, Docs/GpuOffload.md
## 2.1). It was a step of every crumb and its transform written every tick,
## about a microsecond a brick on the main thread.
func update_crumbs() -> void:
	# Read once, not per pass of the loop below: the scene never swaps these.
	var h_crumbs := host._crumbs
	if h_crumbs.is_empty():
		return
	var t0 := Time.get_ticks_usec()
	var now := Engine.get_physics_frames()
	_crumb_constants()
	crumb_ticks += 1
	for key in h_crumbs:
		var cr: Host.Crumbs = h_crumbs[key]
		if cr.pos.is_empty() or cr.soonest > now:
			continue
		var soonest := 9223372036854775807
		var i := 0
		crumb_scanned += cr.pos.size()
		while i < cr.pos.size():
			if cr.next[i] <= now:
				crumb_events += 1
			if cr.next[i] <= now and _crumb_event(cr, i, key, now):
				continue   # gone: the last one is in its place now
			soonest = mini(soonest, cr.next[i])
			i += 1
		cr.soonest = soonest
		cr.mmi.multimesh.visible_instance_count = cr.pos.size()
	var ms := float(Time.get_ticks_usec() - t0) / 1000.0
	host.crumb_worst_ms = maxf(host.crumb_worst_ms, ms)
	crumb_update_ms += ms
	crumb_peak = maxi(crumb_peak, host.crumb_count)


## What happens to crumb `i` at tick `now`: laid in the heap, gone, its floor
## found, or it reached its floor -- bounces, lands, or the floor had gone.
## True when it was taken out.
func _crumb_event(cr: Host.Crumbs, i: int, key: Vector3, now: int) -> bool:
	var age := now - cr.born[i]
	# Come to rest: it lies where it stopped, for good (BrickHeap).
	if _crumb_keep and cr.landed[i] > 0:
		var t_lay := Time.get_ticks_usec()
		_lay_crumb(cr, i, key, _crumb_dt)
		lay_us += Time.get_ticks_usec() - t_lay
		_crumb_remove(cr, i)
		return true
	if age >= (_crumb_fall_max if _crumb_keep else _crumb_life):
		_crumb_remove(cr, i)
		return true
	# Handed back by the heap: its floor is asked once what took the old one
	# has had its tick to go (_heap_support_gone).
	if is_nan(cr.floor_y[i]):
		if age >= 2:
			cr.floor_y[i] = crumb_floor(_crumb_pos(cr, i, now))
			cr.on_ground[i] = 1 if host._floor_on_ground else 0
		_crumb_plan(cr, i, now)
		_crumb_write(cr, i)
		return false
	if cr.landed[i] == 0 and now >= cr.t_end[i]:
		var p := _crumb_pos(cr, i, now)
		var v := _crumb_vel(cr, i, now)
		if p.y - cr.half_h[i] <= cr.floor_y[i] and not crumb_floor_gone(cr, i, p):
			p.y = cr.floor_y[i] + cr.half_h[i]
			if -v.y * Host.crumb_bounce > CRUMB_REST_SPEED:
				v = Vector3(v.x * CRUMB_SLIDE, -v.y * Host.crumb_bounce, v.z * CRUMB_SLIDE)
				crumb_bounces += 1
			else:
				v = Vector3.ZERO
				cr.landed[i] = now
			cr.pos[i] = p
			cr.vel[i] = v
			cr.t0[i] = now
	_crumb_plan(cr, i, now)
	_crumb_write(cr, i)
	return false


func _crumb_remove(cr: Host.Crumbs, i: int) -> void:
	cr.remove(i)
	host.crumb_count -= 1
	if i < cr.pos.size():
		_crumb_write(cr, i)


## A new crumb in `cr`: thrown from `p` at `v`, turned `base`, spinning
## round `axis` at `rate` rad/s, onto `floor_y` (-INF none, NAN asked later).
## Its spin is kept as the shader reads it (8 bits each way), so where the CPU
## lays it and how it was drawn agree.
func crumb_push(cr: Host.Crumbs, p: Vector3, v: Vector3, base: Basis, axis: Vector3, rate: float,
		now: int, floor_y: float, half_h: float, colour: Color, on_ground: int,
		count_brick := true) -> void:
	if host.crumb_count == 0 or not _crumb_constants_set:
		_crumb_constants()
	var spin := Host.crumb_pack_spin(axis.normalized() if axis.length() > 0.01 else Vector3.UP, rate)
	cr.pos.append(p)
	cr.vel.append(v)
	cr.base.append(base)
	cr.axis.append(spin[1])
	cr.rate.append(spin[2])
	cr.spin.append(spin[0])
	cr.born.append(now)
	cr.landed.append(0)
	cr.floor_y.append(floor_y)
	cr.half_h.append(half_h)
	cr.colour.append(colour)
	cr.on_ground.append(on_ground)
	cr.t0.append(now)
	cr.t_end.append(now)
	cr.next.append(now)
	var i := cr.pos.size() - 1
	_crumb_plan(cr, i, now)
	var mm := cr.mmi.multimesh
	if mm.instance_count < cr.pos.size():
		# Growing a MultiMesh clears it: every crumb written again.
		mm.instance_count = maxi(cr.pos.size() * 2, 16)
		for j in cr.pos.size():
			_crumb_write(cr, j)
	else:
		_crumb_write(cr, i)
	mm.visible_instance_count = cr.pos.size()
	cr.soonest = mini(cr.soonest, cr.next[i]) if i > 0 else cr.next[i]
	host.crumb_count += 1
	if count_brick:
		host.crumb_bricks += 1


## Where crumb `i` is at tick `now`, and how fast: its stretch's start stepped
## on as _update_crumbs stepped it, a tick at a time (v -= g dt, then p += v dt),
## in closed form -- the same sums the shader does.
func _crumb_pos(cr: Host.Crumbs, i: int, now: int) -> Vector3:
	var n := float(clampi(now, cr.t0[i], maxi(cr.t_end[i], cr.t0[i])) - cr.t0[i])
	var p := cr.pos[i] + cr.vel[i] * (n * _crumb_dt)
	p.y -= _crumb_g * _crumb_dt * _crumb_dt * n * (n + 1.0) * 0.5
	return p


func _crumb_vel(cr: Host.Crumbs, i: int, now: int) -> Vector3:
	if cr.landed[i] > 0:
		return Vector3.ZERO
	var n := float(clampi(now, cr.t0[i], maxi(cr.t_end[i], cr.t0[i])) - cr.t0[i])
	return cr.vel[i] - Vector3(0.0, _crumb_g * _crumb_dt * n, 0.0)


## When crumb `i` next needs the CPU: it reaches its floor (the first tick its
## foot is at or under it), its floor is to be asked, it is to be laid, or it
## is done. `t_end` is when the shader holds it still: landed, or at its floor.
func _crumb_plan(cr: Host.Crumbs, i: int, now: int) -> void:
	var gone_at := cr.born[i] + (_crumb_fall_max if _crumb_keep else _crumb_life)
	if cr.landed[i] > 0:
		cr.t_end[i] = cr.landed[i]
		cr.next[i] = cr.landed[i] + 1 if _crumb_keep else gone_at
		return
	var fl := cr.floor_y[i]
	if is_nan(fl):
		cr.t_end[i] = gone_at
		cr.next[i] = mini(maxi(cr.born[i] + 2, now + 1), gone_at)
		return
	var hit := gone_at
	if is_finite(fl):
		hit = mini(cr.t0[i] + Host.ticks_to_floor(cr.pos[i].y - cr.half_h[i] - fl, cr.vel[i].y,
				_crumb_g, _crumb_dt), gone_at)
	cr.t_end[i] = hit
	cr.next[i] = maxi(hit, now + 1) if hit > now else now + 1
	if hit <= now:
		# Already at or under it (a floor found late, or lowered): next tick.
		cr.t_end[i] = now + 1


## Crumb `i` as the shader reads it (shaders/crumb.gdshader, its header).
func _crumb_write(cr: Host.Crumbs, i: int) -> void:
	var mm := cr.mmi.multimesh
	mm.set_instance_transform(i, Transform3D(cr.base[i], cr.pos[i]))
	var c := cr.colour[i]
	var rgb := float((clampi(int(round(c.r * 255.0)), 0, 255) << 16)
			| (clampi(int(round(c.g * 255.0)), 0, 255) << 8) | clampi(int(round(c.b * 255.0)), 0, 255))
	mm.set_instance_color(i, Color(rgb, cr.spin[i], float(cr.t_end[i]), float(cr.born[i])))
	var v := cr.vel[i]
	mm.set_instance_custom_data(i, Color(v.x, v.y, v.z, float(cr.t0[i])))


## Every crumb there is, as [where it is now, how fast], for probes.
func crumb_states() -> Array:
	# Read once, not per pass of the loop below: the scene never swaps these.
	var h_crumbs := host._crumbs
	var out := []
	var now := Engine.get_physics_frames()
	for key in h_crumbs:
		var cr: Host.Crumbs = h_crumbs[key]
		for i in cr.pos.size():
			out.append([_crumb_pos(cr, i, now), _crumb_vel(cr, i, now)])
	return out


func _crumb_material() -> ShaderMaterial:
	if _crumb_mat == null:
		_crumb_mat = ShaderMaterial.new()
		_crumb_mat.shader = load("res://shaders/crumb.gdshader")
		_crumb_mat.set_shader_parameter("spin_max", Host.CRUMB_SPIN)
		_crumb_constants_set = false
		_crumb_constants()
	return _crumb_mat


## The tick, gravity, and how crumbs go away -- the shader's copies kept with
## them. A change of whether bricks are kept re-plans every crumb.
func _crumb_constants() -> void:
	# Read once, not per pass of the loop below: the scene never swaps these.
	var h_crumbs := host._crumbs
	var tps := float(Engine.physics_ticks_per_second)
	var dt := 1.0 / tps
	var g := Gravity.strength() * Host.DEBRIS_GRAVITY
	var keep := host.heap != null and BrickHeap.enabled()
	var life := int(Host.CRUMB_LIFE_MS * tps / 1000.0)
	var full := int(CRUMB_FULL_MS * tps / 1000.0)
	var fall_max := int(Host.CRUMB_FALL_MAX_MS * tps / 1000.0)
	var fade := maxi(int(CRUMB_FADE_MS * tps / 1000.0), 1)
	if _crumb_constants_set and dt == _crumb_dt and g == _crumb_g and keep == _crumb_keep:
		return
	var replan := _crumb_constants_set and keep != _crumb_keep
	_crumb_dt = dt
	_crumb_g = g
	_crumb_keep = keep
	_crumb_life = life
	_crumb_full = full
	_crumb_fall_max = fall_max
	_crumb_fade = fade
	_crumb_constants_set = true
	var m := _crumb_material()
	m.set_shader_parameter("tick_s", dt)
	m.set_shader_parameter("gravity", g)
	m.set_shader_parameter("keep", keep)
	m.set_shader_parameter("life", float(life))
	m.set_shader_parameter("full", float(full))
	m.set_shader_parameter("fall_max", float(fall_max))
	m.set_shader_parameter("fade", float(fade))
	if replan:
		var now := Engine.get_physics_frames()
		for key in h_crumbs:
			var cr: Host.Crumbs = h_crumbs[key]
			for i in cr.pos.size():
				_crumb_plan(cr, i, now)
				_crumb_write(cr, i)
			cr.soonest = now


## A crumb that has come to rest, laid in the heap: flat on whichever of its
## faces was most nearly down (_lie_flat), on the floor it stopped on.
func _lay_crumb(cr: Host.Crumbs, i: int, size: Vector3, dt: float) -> void:
	if not is_finite(cr.floor_y[i]):
		return
	var turned := cr.landed[i] - cr.born[i]
	var b := Basis(cr.axis[i], cr.rate[i] * float(turned) * dt) * cr.base[i]
	var flat := _lie_flat(b, size)
	var p := cr.pos[i]
	# On the floor it came down on, or on what already lies there (a pile).
	p.y = host.heap.base_for(size, flat[0] as Basis, p, cr.floor_y[i]) + size[int(flat[1])] * 0.5
	host.heap.lay(size, Transform3D(flat[0] as Basis, p), cr.colour[i], cr.floor_y[i],
			cr.on_ground[i] != 0, _laid_on(p, cr.floor_y[i], size[int(flat[1])] * 0.5) if BrickHeap.track else "")


## What a brick laid at `p` came down on, said for BrickHeap.track: the body
## under it -- a piece, the ground, a body with no node (a building's bricks or
## its shell) -- and the floor it was laid for.
func _laid_on(p: Vector3, floor_y: float, half: float) -> String:
	var q := PhysicsRayQueryParameters3D.create(p, p + Vector3.DOWN * 300.0, CRUMB_FLOOR_MASK)
	var hit := host.get_world_3d().direct_space_state.intersect_ray(q)
	var under := "nothing"
	if not hit.is_empty():
		var isl := host.find_by_body(hit.collider) if hit.collider is Node else null
		if isl != null:
			under = "piece of chunk %d (%s)" % [isl.chunk, "settled" if isl.settled else "moving"]
		elif hit.collider is CollisionObject3D:
			under = "%s, layer %d" % [(hit.collider as Node).name, (hit.collider as CollisionObject3D).collision_layer]
		else:
			under = "a body with no node"
		under += " %.2f m under its foot" % (p.y - half - (hit.position as Vector3).y)
	return "on %s; its floor %.2f m under it" % [under, p.y - half - floor_y]


## `b` turned to lie on a face: the axis it comes down on made vertical, the
## next one levelled, which way it pointed kept. [basis, that axis]. Which face:
## the most nearly down, weighed by how thin the brick is that way -- a brick
## comes to rest on a broad face, and stands on its end only when it came down
## very nearly upright (one in five of a heap stood on end, weighed by the
## angle alone).
static func _lie_flat(b: Basis, size := Vector3.ONE) -> Array:
	var cols: Array[Vector3] = [b.x.normalized(), b.y.normalized(), b.z.normalized()]
	var up := 0
	var best := -1.0
	for k in 3:
		var score := absf(cols[k].y) / maxf(size[k], 0.001)
		if score > best:
			best = score
			up = k
	var a := (up + 1) % 3
	var m := (up + 2) % 3
	cols[up] = Vector3.UP if cols[up].y >= 0.0 else Vector3.DOWN
	var h := Vector3(cols[a].x, 0.0, cols[a].z)
	cols[a] = h.normalized() if h.length() > 0.001 else Vector3.RIGHT
	# Right-handed: the axis after next is this one across the next.
	cols[m] = cols[up].cross(cols[a])
	return [Basis(cols[0], cols[1], cols[2]), up]
