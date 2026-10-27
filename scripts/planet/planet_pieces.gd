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
## Not yet (D2's next steps): a hard landing breaking a piece, hits on a piece,
## the small ones as crumbs, a cap on how many, a building toppling whole.

## A falling piece's weight, as the city's debris (IslandManager.DEBRIS_GRAVITY):
## a brick model falls faster than a building would, at this scale.
const GRAVITY_SCALE := 1.6
## Still for this long, slower than these: frozen where it lies.
const SETTLE_SPEED := 0.15
const SETTLE_SPIN := 0.2
const SETTLE_MS := 700

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

var bricks: BrickWorld
var planet: Node3D
var brick_material: Material
var pieces: Array[Piece] = []
var made := 0
var settled_count := 0


func setup(world: BrickWorld, p: Node3D, material: Material) -> void:
	bricks = world
	planet = p
	brick_material = material


## Cut each group of `groups` (block ids of `source`) out into a falling piece.
## Returns how many were made.
func shed(source: int, groups: Array) -> int:
	var n := 0
	for g in groups:
		var ids: PackedInt32Array = g
		if ids.is_empty():
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
		# Shapes before the body joins a space (IslandManager.spawn's note).
		bricks.add_chunk_shapes(body.get_rid(), p.chunk, p.local_com, true,
				ids.size() >= IslandManager.MERGE_FALLING_BLOCKS)
		add_child(body)
		body.global_transform = bricks.get_chunk_transform(p.chunk) \
				* Transform3D(Basis(), p.local_com)
		p.body = body
		p.planet_local = planet.global_transform.affine_inverse() * body.global_transform
		_start_mesh(p)
		pieces.append(p)
		made += 1
		n += 1
	return n


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
	p.body.add_child(mi)


func _physics_process(_delta: float) -> void:
	var now := Time.get_ticks_msec()
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
		if b.linear_velocity.length() < SETTLE_SPEED and b.angular_velocity.length() < SETTLE_SPIN:
			if p.slow_since == 0:
				p.slow_since = now
			elif now - p.slow_since >= SETTLE_MS:
				_settle(p)
		else:
			p.slow_since = 0


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
