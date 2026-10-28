class_name PlanetPieces
extends Node3D

## What comes loose from a planet building (Docs/Planets.md 11.11, D2): each
## group the structure solve lets go (BrickWorld.solve_structure, the city's
## call) cut out of the building's chunk into a chunk of its own
## (split_island) and let fall as one rigid body -- toward the planet's centre,
## not world -Y: the planet's towns stand anywhere on the sphere and the
## floating origin only translates (PlanetFrame), so up is Gravity.up_at here,
## never +Y. That is why this is not IslandManager: it is written for the flat
## city's up throughout (landing normals, support rays, crumbs, the heap).
## A piece lands on the ground or the building and, still, is frozen there.
##
## Step 2: a hard landing breaks it (the city's rule: joints sheared at its
## contacts, what is no longer joined comes away); a group of DEBRIS_MAX_BLOCKS
## or fewer is crumbs (PlanetCrumbs), not a piece; and a cap -- MAX_MOVING
## moving, MAX_PIECES kept, the oldest settled one out of sight shrunk away.
##
## Step 3: hits on a piece (`damage`, the city's IslandManager.damage): a round
## chips, ordnance blasts, its killed bricks thrown as crumbs; what is no longer
## joined comes away; what rested on the bricks taken is woken.
##
## Step 4: a whole building handed over as one piece (`adopt`, the city's
## CityScene._topple): its chunk as it is, nothing copied.
##
## Step 5: the AI told where pieces lie (`ground_changed`: a piece settled,
## woken, hit or gone -- the nav regions sync and forget the box).
##
## Not yet (D2's next steps): the city's snap preferences.

## A falling piece's weight, as the city's debris (IslandManager.DEBRIS_GRAVITY):
## a brick model falls faster than a building would, at this scale.
const GRAVITY_SCALE := 1.6
## Still for this long, slower than these: frozen where it lies.
const SETTLE_SPEED := 0.15
const SETTLE_SPIN := 0.2
const SETTLE_MS := 700
## The city's landing rule (IslandManager): a drop of IMPACT_DELTA in a tick,
## after IMPACT_FALL_TICKS over IMPACT_MIN_SPEED, MAX_IMPACTS a piece at most.
const IMPACT_MIN_SPEED := IslandManager.IMPACT_MIN_SPEED
const IMPACT_DELTA := IslandManager.IMPACT_DELTA
const IMPACT_FALL_TICKS := IslandManager.IMPACT_FALL_TICKS
const MAX_IMPACTS := IslandManager.MAX_IMPACTS
const MIN_IMPACT_BLOCKS := IslandManager.MIN_IMPACT_BLOCKS
const SHEAR_CONTACTS_MAX := IslandManager.SHEAR_CONTACTS_MAX
const SHEAR_MAX_BLOCKS := IslandManager.SHEAR_MAX_BLOCKS
const IMPACT_RADIUS := IslandManager.IMPACT_RADIUS
const IMPACT_RADIUS_MAX := IslandManager.IMPACT_RADIUS_MAX
## A long piece SNAPS across where it lands (IslandManager._snap_across).
const BREAK_MIN_DROP := IslandManager.BREAK_MIN_DROP
const BREAK_MIN_LENGTH := IslandManager.BREAK_MIN_LENGTH
const BREAK_MIN_PIECE := IslandManager.BREAK_MIN_PIECE
const BREAK_SPACING := IslandManager.BREAK_SPACING
const BREAK_PLANES_MAX := IslandManager.BREAK_PLANES_MAX
const BREAK_THICKNESS := IslandManager.BREAK_THICKNESS
## This many bricks or fewer: crumbs, not a piece.
const DEBRIS_MAX_BLOCKS := IslandManager.DEBRIS_MAX_BLOCKS
## The cap: moving at once, and kept in all.
const MAX_MOVING := IslandManager.MAX_MOVING
const MAX_PIECES := 160
## A piece over the cap shrinks away over this long (never a pop).
const FADE_MS := 600

class Piece:
	var chunk := -1
	var body: RigidBody3D = null
	var local_com := Vector3.ZERO
	var bricks := 0
	## Where it is on the planet: put back after a floating-origin shift.
	var planet_local := Transform3D.IDENTITY
	var slow_since := 0
	var settled := false
	var born_ms := 0
	## Its mesh, made on a worker: [task id, [mesh]], empty once hung.
	var job: Array = []
	## What draws it: its own mesh, or a toppled building's bands (a Node3D).
	var mesh_node: Node3D = null
	## The landing rule's state.
	var prev_speed := 0.0
	var fall_ticks := 0
	var impacts := 0
	## Over the cap: shrinking since (ms), 0 while kept.
	var fading_since := 0

## The ground changed where `box` (world) is: a piece settled there, woke, was
## hit or went. The scene's AI syncs its regions and forgets the box (setup_ai).
signal ground_changed(box: AABB)

var bricks: BrickWorld
var planet: Node3D
var brick_material: Material
var pieces: Array[Piece] = []
var made := 0
var settled_count := 0
var crumbs: PlanetCrumbs
## Counters, for the gates: hard landings, the pieces they broke off, the
## groups that went to crumbs (small / over the cap), pieces faded off the cap.
var landings := 0
var snaps := 0
var broke_off := 0
var crumbed_small := 0
var crumbed_cap := 0
var faded := 0
## Hits that killed bricks, the bricks they killed, settled pieces woken.
var hits := 0
var hit_killed := 0
var woken := 0
var toppled := 0


func setup(world: BrickWorld, p: Node3D, material: Material) -> void:
	bricks = world
	planet = p
	brick_material = material
	crumbs = PlanetCrumbs.new()
	add_child(crumbs)
	crumbs.setup(p)


## Cut each group of `groups` (block ids of `source`) out into a falling piece,
## moving at `linear` (world) -- or into crumbs, when it is small or the cap is
## full. Returns how many pieces were made.
func shed(source: int, groups: Array, linear := Vector3.ZERO) -> int:
	var n := 0
	for g in groups:
		var ids: PackedInt32Array = g
		if ids.is_empty():
			continue
		if ids.size() <= DEBRIS_MAX_BLOCKS or moving() >= MAX_MOVING:
			if ids.size() <= DEBRIS_MAX_BLOCKS:
				crumbed_small += 1
			else:
				crumbed_cap += 1
			_crumble(source, ids, linear)
			continue
		var split: Dictionary = bricks.split_island(source, ids)
		if split.is_empty():
			continue
		var p := Piece.new()
		p.chunk = int(split.chunk)
		p.local_com = split.local_com
		p.bricks = ids.size()
		p.born_ms = Time.get_ticks_msec()
		bricks.set_chunk_anchored(p.chunk, false)
		var body := RigidBody3D.new()
		body.mass = maxf(float(split.mass) * IslandManager.MASS_SCALE, 0.5)
		body.gravity_scale = 0.0
		body.collision_layer = Layers.FALLING
		body.collision_mask = Layers.FALLING_MASK
		body.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		# Where it touched, for a landing (IslandManager.MAX_CONTACTS).
		body.contact_monitor = true
		body.max_contacts_reported = IslandManager.MAX_CONTACTS
		# Shapes before the body joins a space (IslandManager.spawn's note).
		bricks.add_chunk_shapes(body.get_rid(), p.chunk, p.local_com, true,
				ids.size() >= IslandManager.MERGE_FALLING_BLOCKS)
		add_child(body)
		body.global_transform = bricks.get_chunk_transform(p.chunk) \
				* Transform3D(Basis(), p.local_com)
		body.linear_velocity = linear
		p.body = body
		p.prev_speed = linear.length()
		p.planet_local = planet.global_transform.affine_inverse() * body.global_transform
		_start_mesh(p)
		pieces.append(p)
		made += 1
		n += 1
	_cap()
	return n


## A whole chunk made a falling piece as it is -- a building toppling (the
## city's CityScene._topple: nothing copied, no split_island). `carried` is
## what draws it now (its bands, placed as the chunk is); it rides the body
## until the piece is first drawn again, and casts its own shadow meanwhile.
## The caller has freed the building's collision FIRST: a body that starts
## inside it is thrown by the solver.
func adopt(chunk: int, carried: Node3D) -> Piece:
	var p := Piece.new()
	p.chunk = chunk
	p.local_com = bricks.get_chunk_com(chunk)
	p.bricks = bricks.get_alive_block_count(chunk)
	p.born_ms = Time.get_ticks_msec()
	bricks.set_chunk_anchored(chunk, false)
	var xf := bricks.get_chunk_transform(chunk)
	var body := RigidBody3D.new()
	body.mass = maxf(bricks.get_chunk_mass(chunk) * IslandManager.MASS_SCALE, 0.5)
	body.gravity_scale = 0.0
	body.collision_layer = Layers.FALLING
	body.collision_mask = Layers.FALLING_MASK
	body.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	body.contact_monitor = true
	body.max_contacts_reported = IslandManager.MAX_CONTACTS
	bricks.add_chunk_shapes(body.get_rid(), chunk, p.local_com, true,
			p.bricks >= IslandManager.MERGE_FALLING_BLOCKS)
	add_child(body)
	body.global_transform = xf * Transform3D(Basis(), p.local_com)
	p.body = body
	p.planet_local = planet.global_transform.affine_inverse() * body.global_transform
	if carried != null:
		carried.reparent(body, false)
		carried.transform = Transform3D(Basis(), -p.local_com)
		for n in carried.find_children("*", "GeometryInstance3D", true, false):
			(n as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		# Drawn by the bands until it is first drawn again: then they go.
		p.mesh_node = carried
	pieces.append(p)
	made += 1
	toppled += 1
	return p


## `ids` of `source` thrown as crumbs, then cut out and freed.
func _crumble(source: int, ids: PackedInt32Array, linear: Vector3) -> void:
	crumbs.throw(bricks, source, ids, linear)
	var cut: Dictionary = bricks.split_island(source, ids)
	if not cut.is_empty():
		bricks.release_chunk(int(cut.chunk))


## Over MAX_PIECES: the oldest settled piece the camera cannot see shrinks away.
func _cap() -> void:
	var kept := 0
	for p in pieces:
		if p.fading_since == 0:
			kept += 1
	if kept <= MAX_PIECES:
		return
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	for p in pieces:
		if kept <= MAX_PIECES:
			break
		if not p.settled or p.fading_since != 0 or not is_instance_valid(p.body):
			continue
		if cam != null and not cam.is_position_behind(p.body.global_position) \
				and cam.global_position.distance_to(p.body.global_position) < 60.0:
			continue
		p.fading_since = Time.get_ticks_msec()
		kept -= 1


## Its arrays here, its GPU mesh on a worker -- the planet's bands' way
## (PlanetBuildings._draw_band): a mesh made on the main thread is ~9 ms.
func _start_mesh(p: Piece) -> void:
	var arrays: Array = bricks.build_chunk_mesh(p.chunk)
	if arrays.is_empty():
		return
	var holder := [null]
	var task := WorkerThreadPool.add_task(func() -> void:
			var m := ArrayMesh.new()
			m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, IslandManager.UPLOAD_COMPRESS)
			holder[0] = m, false, "planet piece")
	p.job = [task, holder]


func _hang_mesh(p: Piece) -> void:
	if p.job.is_empty() or not WorkerThreadPool.is_task_completed(int(p.job[0])):
		return
	WorkerThreadPool.wait_for_task_completion(int(p.job[0]))
	var mesh: ArrayMesh = (p.job[1] as Array)[0]
	p.job = []
	if mesh == null or not is_instance_valid(p.body):
		return
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = brick_material
	mi.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	mi.position = -p.local_com
	if p.mesh_node != null and is_instance_valid(p.mesh_node):
		p.mesh_node.queue_free()
	p.mesh_node = mi
	p.body.add_child(mi)


func _physics_process(_delta: float) -> void:
	var now := Time.get_ticks_msec()
	var landed: Array = []
	var i := pieces.size() - 1
	while i >= 0:
		var p := pieces[i]
		if p.fading_since != 0 and _fade(p, now):
			pieces.remove_at(i)
		i -= 1
	for p in pieces:
		if not p.job.is_empty():
			_hang_mesh(p)
		if p.settled or not is_instance_valid(p.body):
			continue
		var b := p.body
		b.constant_force = Gravity.down_at(b.global_position) * Gravity.strength() \
				* GRAVITY_SCALE * b.mass
		bricks.set_chunk_transform(p.chunk, b.global_transform * Transform3D(Basis(), -p.local_com))
		p.planet_local = planet.global_transform.affine_inverse() * b.global_transform
		# A hard landing: the city's rule.
		var speed := b.linear_velocity.length()
		var lost := p.prev_speed - speed
		var fell := p.fall_ticks
		p.fall_ticks = p.fall_ticks + 1 if speed > IMPACT_MIN_SPEED else 0
		if lost > IMPACT_DELTA and p.prev_speed > IMPACT_MIN_SPEED and fell >= IMPACT_FALL_TICKS \
				and p.impacts < MAX_IMPACTS and p.bricks >= MIN_IMPACT_BLOCKS:
			p.impacts += 1
			p.fall_ticks = 0
			landed.append([p, lost])
		p.prev_speed = speed
		if b.linear_velocity.length() < SETTLE_SPEED and b.angular_velocity.length() < SETTLE_SPIN:
			if p.slow_since == 0:
				p.slow_since = now
			elif now - p.slow_since >= SETTLE_MS:
				_settle(p)
		else:
			p.slow_since = 0
	for l in landed:
		_break_on_landing(l[0], l[1])


## A hard landing SHEARS the joints where it touched (IslandManager.
## fracture_on_impact's sweeps, its radius by the speed lost) -- it destroys
## nothing -- and what is no longer joined to the rest comes away.
func _break_on_landing(p: Piece, lost: float) -> void:
	if not is_instance_valid(p.body):
		return
	landings += 1
	var b := p.body
	var radius := clampf(IMPACT_RADIUS * lost * 0.08, IMPACT_RADIUS, IMPACT_RADIUS_MAX)
	var xf := b.global_transform * Transform3D(Basis(), -p.local_com)
	bricks.set_chunk_transform(p.chunk, xf)
	var st := PhysicsServer3D.body_get_direct_state(b.get_rid())
	var contacts := PackedVector3Array()
	if st != null:
		for k in mini(st.get_contact_count(), SHEAR_CONTACTS_MAX):
			contacts.append(st.get_contact_local_position(k))
	if contacts.is_empty():
		# No manifold left: under its middle, along the planet's down, a third
		# of its grid's size away.
		var size := Vector3(bricks.get_chunk_dims(p.chunk)) * BrickWorld.get_cell_size()
		contacts.append(b.global_position + Gravity.down_at(b.global_position) * size.length() * 0.3)
	var inv := DamageLog.grid_frame(bricks, p.chunk) * xf.affine_inverse()
	var loosened := 0
	for c in contacts:
		var e := DamageLog.Entry.new()
		e.kind = DamageLog.Kind.PIECE_SHEAR
		e.point = inv * c
		e.radius = radius
		e.limit = SHEAR_MAX_BLOCKS
		e.flags = DamageLog.FLAG_PEEL
		loosened += DamageLog.apply_entry(bricks, p.chunk, e).size()
	loosened += _snap_across(p, contacts, lost, xf)
	bricks.set_chunk_transform(p.chunk, xf)
	if loosened == 0:
		return
	var comps: Array = bricks.get_components_near(p.chunk)
	if comps.size() <= 1:
		return
	var off := comps.slice(1)
	var gone := 0
	for g in off:
		gone += (g as PackedInt32Array).size()
	broke_off += shed(p.chunk, off, b.linear_velocity)
	bricks.mark_chunk_whole(p.chunk)
	p.bricks = maxi(p.bricks - gone, 1)
	_reshape(p)
	_start_mesh(p)


## The piece whose live brick is at world `point` (a round's point, just inside
## what it struck), or null.
func piece_at(point: Vector3) -> Piece:
	var cs := BrickWorld.get_cell_size()
	for p in pieces:
		if p.fading_since != 0 or not is_instance_valid(p.body):
			continue
		var l := bricks.get_chunk_transform(p.chunk).affine_inverse() * point
		var dims := bricks.get_chunk_dims(p.chunk)
		var c := Vector3i(floori(l.x / cs.x), floori(l.y / cs.y), floori(l.z / cs.z))
		if c.x < 0 or c.y < 0 or c.z < 0 or c.x >= dims.x or c.y >= dims.y or c.z >= dims.z:
			continue
		var bid := bricks.block_at(p.chunk, c)
		if bid >= 0 and not bricks.is_block_absent(p.chunk, bid):
			return p
	return null


## The pieces any part of whose grid is within `radius` of world `point`.
func pieces_near(point: Vector3, radius: float) -> Array[Piece]:
	var out: Array[Piece] = []
	for p in pieces:
		if p.fading_since != 0 or not is_instance_valid(p.body):
			continue
		var l := bricks.get_chunk_transform(p.chunk).affine_inverse() * point
		var box := AABB(Vector3.ZERO, Vector3(bricks.get_chunk_dims(p.chunk)) * BrickWorld.get_cell_size())
		var near := l.clamp(box.position, box.end)
		if near.distance_to(l) <= radius:
			out.append(p)
	return out


## A hit on piece `p` at world `point` (StructuralDamage's record, `shot`): a
## round chips (`PIECE_CHIP`, its hp), ordnance blasts (`PIECE_BLAST`). What it
## killed is thrown as crumbs; the piece's shapes are rebuilt; what is no longer
## joined comes away; its mesh is made again; what rested on the bricks taken
## is woken. Returns the bricks killed.
func damage(p: Piece, point: Vector3, shot: Dictionary) -> int:
	if p == null or not is_instance_valid(p.body):
		return 0
	var blast := bool(shot.get("blast", false))
	var radius := float(shot.get("radius", 0.0))
	var xf := bricks.get_chunk_transform(p.chunk)
	var e := DamageLog.Entry.new()
	e.kind = DamageLog.Kind.PIECE_BLAST if blast else DamageLog.Kind.PIECE_CHIP
	e.point = DamageLog.grid_frame(bricks, p.chunk) * xf.affine_inverse() * point
	e.radius = radius
	e.limit = 0 if blast else int(shot.get("hp", 0))
	var killed := DamageLog.apply_entry(bricks, p.chunk, e)
	bricks.set_chunk_transform(p.chunk, xf)
	if killed.is_empty():
		return 0
	hits += 1
	hit_killed += killed.size()
	var linear := Vector3.ZERO if p.settled else p.body.linear_velocity
	crumbs.throw(bricks, p.chunk, killed, linear, point, radius * IslandManager.BLAST_CORE if blast else 0.0)
	var gone_box := xf * bricks.get_blocks_box(p.chunk, killed)
	p.bricks = maxi(p.bricks - killed.size(), 0)
	if bricks.get_alive_block_count(p.chunk) == 0:
		p.fading_since = Time.get_ticks_msec() - FADE_MS
	else:
		var comps: Array = bricks.get_components_near(p.chunk)
		if comps.size() > 1:
			var off := comps.slice(1)
			for g in off:
				p.bricks = maxi(p.bricks - (g as PackedInt32Array).size(), 0)
			broke_off += shed(p.chunk, off, linear)
			bricks.mark_chunk_whole(p.chunk)
		_reshape(p)
		_start_mesh(p)
	support_gone(gone_box, p)
	if p.settled:
		ground_changed.emit(gone_box.grow(1.0))
	return killed.size()


## Bricks in world box `box` are gone: every settled piece but `except` whose
## grid meets it is woken and falls if nothing else holds it
## (IslandManager.support_gone). Not the piece the bricks came out of: it is
## still lying where it lay.
func support_gone(box: AABB, except: Piece = null) -> void:
	var grown := box.grow(0.3)
	for p in pieces:
		if p == except or not p.settled or p.fading_since != 0 or not is_instance_valid(p.body):
			continue
		var pb := bricks.get_chunk_transform(p.chunk) \
				* AABB(Vector3.ZERO, Vector3(bricks.get_chunk_dims(p.chunk)) * BrickWorld.get_cell_size())
		if pb.intersects(grown):
			_wake(p)


func _wake(p: Piece) -> void:
	var b := p.body
	b.freeze = false
	b.collision_layer = Layers.FALLING
	b.collision_mask = Layers.FALLING_MASK
	p.settled = false
	p.slow_since = 0
	p.prev_speed = 0.0
	p.fall_ticks = 0
	settled_count -= 1
	woken += 1
	ground_changed.emit(world_box(p))


## A long piece landing hard snaps across at its contacts: the city's rule
## (IslandManager._snap_across) -- its long axis, at least BREAK_MIN_LENGTH; the
## drop it needs less the longer it is; a plane at each contact, never within
## BREAK_MIN_PIECE of an end nor BREAK_SPACING of another, BREAK_PLANES_MAX at
## most; one PIECE_SNAP (a seam first, a torn band where there is none). Not yet
## the city's preferences -- a weak seam, a floor line, a crack -- which read
## its island's own records. Returns the bricks torn.
func _snap_across(p: Piece, contacts: PackedVector3Array, severity: float, xf: Transform3D) -> int:
	var size := Vector3(bricks.get_chunk_dims(p.chunk)) * BrickWorld.get_cell_size()
	var axis := Vector3(0, 1, 0)
	var length := size.y
	if size.x > length and size.x >= size.z:
		axis = Vector3(1, 0, 0)
		length = size.x
	elif size.z > length:
		axis = Vector3(0, 0, 1)
		length = size.z
	if length < BREAK_MIN_LENGTH:
		return 0
	if severity < BREAK_MIN_DROP * clampf(BREAK_MIN_LENGTH / length, 0.2, 1.0):
		return 0
	var inv := xf.affine_inverse()
	var used: Array[float] = []
	var points := PackedVector3Array()
	for c in contacts:
		if points.size() >= BREAK_PLANES_MAX:
			break
		var local := inv * c
		var at := local.dot(axis)
		if at < BREAK_MIN_PIECE or length - at < BREAK_MIN_PIECE:
			continue
		var crowded := false
		for u in used:
			crowded = crowded or absf(u - at) < BREAK_SPACING
		if crowded:
			continue
		used.append(at)
		points.append(DamageLog.grid_frame(bricks, p.chunk) * local)
	if points.is_empty():
		return 0
	var e := DamageLog.Entry.new()
	e.kind = DamageLog.Kind.PIECE_SNAP
	e.points = points
	e.normal = axis
	e.radius = BREAK_THICKNESS
	e.flags = DamageLog.FLAG_STEP
	var torn := DamageLog.apply_entry(bricks, p.chunk, e)
	if not torn.is_empty():
		snaps += points.size()
	return torn.size()


## The piece's shapes from its bricks as they are now -- out of the space
## first: a shape call on a body in a space costs by its shape count.
func _reshape(p: Piece) -> void:
	var rid := p.body.get_rid()
	var space := PhysicsServer3D.body_get_space(rid)
	if space.is_valid():
		PhysicsServer3D.body_set_space(rid, RID())
	PhysicsServer3D.body_clear_shapes(rid)
	bricks.add_chunk_shapes(rid, p.chunk, p.local_com, true,
			p.bricks >= IslandManager.MERGE_FALLING_BLOCKS)
	if space.is_valid():
		PhysicsServer3D.body_set_space(rid, space)


## Shrinking away over FADE_MS; true once gone (its body and chunk freed).
func _fade(p: Piece, now: int) -> bool:
	var k := 1.0 - clampf(float(now - p.fading_since) / FADE_MS, 0.0, 1.0)
	if k > 0.0 and is_instance_valid(p.body):
		if p.mesh_node != null and is_instance_valid(p.mesh_node):
			p.mesh_node.scale = Vector3.ONE * maxf(k, 0.001)
		return false
	var gone_box := world_box(p)
	if is_instance_valid(p.body):
		p.body.queue_free()
	bricks.release_chunk(p.chunk)
	if p.settled:
		settled_count -= 1
		ground_changed.emit(gone_box)
	faded += 1
	return true


func _settle(p: Piece) -> void:
	var b := p.body
	b.constant_force = Vector3.ZERO
	b.freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
	b.freeze = true
	b.collision_layer = Layers.DEBRIS
	b.collision_mask = Layers.SETTLED_MASK
	bricks.set_chunk_transform(p.chunk, b.global_transform * Transform3D(Basis(), -p.local_com))
	p.planet_local = planet.global_transform.affine_inverse() * b.global_transform
	p.settled = true
	settled_count += 1
	ground_changed.emit(world_box(p))


## The floating origin moved the scene: a moving body is where the physics
## left it, not where its parent took it -- put back on the planet.
func on_origin_shift() -> void:
	for p in pieces:
		if not is_instance_valid(p.body):
			continue
		p.body.global_transform = planet.global_transform * p.planet_local
		p.body.reset_physics_interpolation()
		bricks.set_chunk_transform(p.chunk, p.body.global_transform * Transform3D(Basis(), -p.local_com))


func moving() -> int:
	var n := 0
	for p in pieces:
		if not p.settled:
			n += 1
	return n


func _exit_tree() -> void:
	# Meshes still being made: waited for, or the pool tears down under them.
	for p in pieces:
		if not p.job.is_empty():
			WorkerThreadPool.wait_for_task_completion(int(p.job[0]))
			p.job = []


## Where piece `p`'s grid is, in the world.
func world_box(p: Piece) -> AABB:
	return bricks.get_chunk_transform(p.chunk) \
			* AABB(Vector3.ZERO, Vector3(bricks.get_chunk_dims(p.chunk)) * BrickWorld.get_cell_size())
