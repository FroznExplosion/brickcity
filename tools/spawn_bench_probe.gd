extends SceneTree

## What a piece costs the main thread, part by part, with the renderer and
## paging out of the way (Docs/EngineChoice.md "What to do instead" 1 and 2:
## move the script to C++, or make fewer nodes and bodies). Headless, so
## uploads cost nothing here; what is left is the script, the C++ calls and
## the scene tree / physics server.
##
##     godot --headless --path . --script res://tools/spawn_bench_probe.gd
##
## Prints numbers; it checks nothing.

const SIZES := [12, 60, 300, 1500]
const PER_SIZE := 30
const TICKS := 60

var _started := false
var _w: BrickWorld
var _m: IslandManager
var _camera: Camera3D
var _palette


func _init() -> void:
	_w = BrickWorld.new()
	var ground := StaticBody3D.new()
	ground.collision_layer = Layers.WORLD
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(2000.0, 1.0, 2000.0)
	shape.shape = box
	shape.position = Vector3(0.0, -0.5, 0.0)
	ground.add_child(shape)
	root.add_child(ground)
	_camera = Camera3D.new()
	root.add_child(_camera)
	_m = IslandManager.new()
	root.add_child(_m)
	_m.setup(_w, null, _camera)
	_m.interest = func() -> PackedVector3Array: return PackedVector3Array([Vector3(0, 1, 0)])
	_palette = TowerRecipe.bake_palette(_w)
	physics_frame.connect(_run)


func _tower(at: Vector3) -> int:
	var c := _w.create_chunk(Vector3i.ZERO, TowerRecipe.chunk_dims(20, 20, 60))
	TowerRecipe.build(_w, c, _palette, 20, 20, 60)
	_w.set_chunk_transform(c, Transform3D(Basis(), at))
	return c


func _us(t0: int) -> float:
	return float(Time.get_ticks_usec() - t0)


func _run() -> void:
	if _started:
		return
	_started = true
	_bench_spawn()
	await _bench_tick()
	_bench_nodes()
	quit(0)


## spawn() of pieces SIZES bricks big, each cut from a fresh tower so they are
## all alike. Parts are spawn_prof's (split = C++ cut, shapes = C++ shapes,
## node = the RigidBody3D, MeshInstance3D and add_child, mesh = queueing its
## bake); "up to the cut" is the landmark test, the crumble choice and the cut.
func _bench_spawn() -> void:
	print("\nspawn, per piece (us), %d of each size" % PER_SIZE)
	print("  bricks  made  total  up to the cut  shapes  node  (into scene)  mesh")
	var x := 0.0
	for size: int in SIZES:
		var made := 0
		var sums := [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
		for k in PER_SIZE:
			var c := _tower(Vector3(x, 0.05, 200.0))
			x += 30.0
			var ids := PackedInt32Array()
			var start := 40 + k * 3
			for id in range(start, mini(start + size, _w.get_block_count(c))):
				ids.append(id)
			var t0 := Time.get_ticks_usec()
			var isl := _m.spawn(c, ids, Vector3.ZERO, Vector3.ZERO, -1, -1)
			var total := _us(t0)
			if isl == null:
				continue
			made += 1
			var w: Array = _m.spawn_last
			sums[0] += total
			sums[2] += float(w[1]) * 1000.0
			sums[3] += float(w[2]) * 1000.0
			sums[4] += float(w[3]) * 1000.0
			sums[5] += float(w[7]) * 1000.0
			sums[6] += float(w[4]) * 1000.0
		var n := maxf(made, 1)
		print("  %6d  %4d  %5.0f  %13.0f  %6.0f  %4.0f  %12.0f  %4.0f" % [size, made,
				sums[0] / n, sums[2] / n, sums[3] / n, sums[4] / n, sums[5] / n, sums[6] / n])


## tick() with the pieces above falling and landing: the island loop's cost
## per moving piece.
func _bench_tick() -> void:
	print("\nIslandManager.tick with %d piece(s)" % _m.islands.size())
	var worst := 0.0
	var sum := 0.0
	var moving_sum := 0
	var tp0: Dictionary = _m.tick_prof.duplicate()
	for t in TICKS:
		await physics_frame
		var t0 := Time.get_ticks_usec()
		_m.tick()
		var us := _us(t0)
		_m.start_mesh_jobs()
		sum += us
		worst = maxf(worst, us)
		var moving := 0
		for isl in _m.islands:
			if isl.is_valid() and not isl.settled:
				moving += 1
		moving_sum += moving
	var parts := ""
	for k in _m.tick_prof:
		parts += "%s %.0f  " % [k, (float(_m.tick_prof[k]) - float(tp0.get(k, 0.0))) * 1000.0 / TICKS]
	print("  mean %.0f us, worst %.0f us, %.0f moving on average -> %.1f us a moving piece" % [
			sum / TICKS, worst, float(moving_sum) / TICKS, sum / maxf(moving_sum, 1)])
	print("  of which (mean us a tick): " + parts)


## The bare cost of what a piece is made of, 500 times each: nodes the way
## spawn makes them, against server objects and a reused (pooled) body.
func _bench_nodes() -> void:
	const N := 500
	print("\nnodes and bodies, per piece (us), %d each" % N)
	var parent := Node3D.new()
	root.add_child(parent)
	var space := parent.get_world_3d().space
	var box := BoxShape3D.new()

	# As spawn does: RigidBody3D + MeshInstance3D child, into the tree.
	var bodies: Array[RigidBody3D] = []
	var t0 := Time.get_ticks_usec()
	for k in N:
		var b := RigidBody3D.new()
		b.contact_monitor = true
		b.max_contacts_reported = 4
		var mi := MeshInstance3D.new()
		mi.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		b.add_child(mi)
		b.transform = Transform3D(Basis(), Vector3(k * 3.0, 50.0, -300.0))
		parent.add_child(b)
		b.reset_physics_interpolation()
		bodies.append(b)
	var make_us := _us(t0) / N
	t0 = Time.get_ticks_usec()
	for b in bodies:
		PhysicsServer3D.body_add_shape(b.get_rid(), box.get_rid())
	var shape_us := _us(t0) / N
	t0 = Time.get_ticks_usec()
	for b in bodies:
		parent.remove_child(b)
		b.free()
	var free_us := _us(t0) / N
	print("  RigidBody3D + MeshInstance3D, new + into the tree   %.1f   (a shape added %.1f; out + free %.1f)" % [
			make_us, shape_us, free_us])

	# The same through the servers, no nodes.
	var rids: Array[RID] = []
	var insts: Array[RID] = []
	t0 = Time.get_ticks_usec()
	for k in N:
		var body := PhysicsServer3D.body_create()
		PhysicsServer3D.body_set_mode(body, PhysicsServer3D.BODY_MODE_RIGID)
		PhysicsServer3D.body_set_space(body, space)
		PhysicsServer3D.body_set_max_contacts_reported(body, 4)
		PhysicsServer3D.body_set_state(body, PhysicsServer3D.BODY_STATE_TRANSFORM,
				Transform3D(Basis(), Vector3(k * 3.0, 50.0, -400.0)))
		var inst := RenderingServer.instance_create()
		RenderingServer.instance_set_scenario(inst, parent.get_world_3d().scenario)
		rids.append(body)
		insts.append(inst)
	var srv_us := _us(t0) / N
	t0 = Time.get_ticks_usec()
	for r in rids:
		PhysicsServer3D.free_rid(r)
	for r in insts:
		RenderingServer.free_rid(r)
	var srv_free_us := _us(t0) / N
	print("  body + instance through the servers                 %.1f   (freed %.1f)" % [srv_us, srv_free_us])

	# Pooled: bodies made once, taken out of the space and back in.
	var pool: Array[RigidBody3D] = []
	for k in N:
		var b := RigidBody3D.new()
		var mi := MeshInstance3D.new()
		b.add_child(mi)
		parent.add_child(b)
		pool.append(b)
	t0 = Time.get_ticks_usec()
	for b in pool:
		b.process_mode = Node.PROCESS_MODE_DISABLED   # out of the space (DISABLE_MODE_REMOVE)
	var park_us := _us(t0) / N
	t0 = Time.get_ticks_usec()
	for k in N:
		var b := pool[k]
		b.process_mode = Node.PROCESS_MODE_INHERIT
		b.transform = Transform3D(Basis(), Vector3(k * 3.0, 50.0, -500.0))
		b.linear_velocity = Vector3.ZERO
		b.reset_physics_interpolation()
	var reuse_us := _us(t0) / N
	print("  a pooled body taken back (into the space, placed)   %.1f   (parked %.1f)" % [reuse_us, park_us])
	parent.queue_free()
