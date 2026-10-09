class_name TransportTruck
extends CharacterBody3D
## A truck that brings a squad (Docs/AIVehicles.md, step 1).
##
## The first vehicle, and the least of one: a body that drives, that can be shot
## to pieces, and that carries a squad's worth of soldiers to the fight. What it
## carries is CARGO -- the kinds of unit the commander bought -- not bodies in
## seats: the soldiers are put down at the tailgate when it stops (its host's
## dismount), and until then they are the truck. Shoot the truck to pieces on
## the way and they die with it.
##
## It drives one path, asked for once, at DRIVE speed, turning no faster than
## TURN; it stops and lets them out when it is within DROP of where it was sent,
## when its path runs out, or when it has been stuck for STUCK seconds. A
## brick-built body, seats, moving cover and a vehicle map with clearance are
## the steps after this one (AIVehicles.md 3-4).

signal arrived(truck: TransportTruck)
signal wrecked(truck: TransportTruck)

const DRIVE := 9.0
const TURN := 1.6
const DROP := 22.0
const STUCK := 3.0
const HP := 400.0
const GRAVITY := 20.0
const SIZE := Vector3(2.3, 2.4, 5.6)
const CLEARANCE := 0.55
const WHEEL := 0.45
## Up-speed for a kerb: about half a metre at this gravity.
const KERB_POP := 4.5
## Seconds it backs up the first time it is stuck.
const REVERSE := 1.5
## An empty truck leaves the board this long after unloading.
const LEAVE_AFTER := 30.0

var services: AIServices
## The kinds of unit riding in it.
var cargo: Array[StringName] = []
var goal := Vector3.INF
var state := "idle"   # idle, driving, arrived, wrecked
var health: HealthPool
## Why it stopped: "there", "end of path", "stuck", "no way".
var stopped_because := ""
## What it was pressed against when it stuck.
var stuck_on: Array[String] = []

var _path := PackedVector3Array()
var _path_id := -1
var _wp := 0
var _from := Vector3.ZERO
var _moved_at := 0.0
var _yaw := 0.0
var _reverse_until := -INF
var _reversals := 0


static func make(s: AIServices, parent: Node, at: Vector3, yaw: float) -> TransportTruck:
	var t := TransportTruck.new()
	t.name = "Truck"
	t.services = s
	# Solid to pawns and to rounds, like wreckage: not brick, so not cover the
	# AI knows of yet (AIVehicles.md: brick-built is the next step).
	t.collision_layer = Layers.DEBRIS
	t.collision_mask = Layers.WORLD | Layers.STRUCTURE | Layers.DEBRIS
	t.floor_max_angle = deg_to_rad(40.0)
	t.floor_snap_length = 0.6
	t.floor_stop_on_slope = true
	# The body a clearance off the ground, on four spheres for wheels: the
	# ground is laid in plates, and a flat-bottomed box stops dead at the first
	# 14 cm step where a wheel rolls up it.
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(SIZE.x, SIZE.y - CLEARANCE, SIZE.z)
	shape.shape = box
	shape.position = Vector3.UP * (CLEARANCE + box.size.y * 0.5)
	t.add_child(shape)
	for x in [-SIZE.x * 0.4, SIZE.x * 0.4]:
		for z in [-SIZE.z * 0.35, SIZE.z * 0.3]:
			var ws := CollisionShape3D.new()
			var sph := SphereShape3D.new()
			sph.radius = WHEEL
			ws.shape = sph
			ws.position = Vector3(x, WHEEL, z)
			t.add_child(ws)
	t._build_look()
	var pool := HealthPool.new()
	pool.name = "HealthPool"
	var layer := DefenseLayer.new()
	layer.max_value = HP
	pool.layer_configs = [layer]
	t.add_child(pool)
	t.health = pool
	parent.add_child(t)
	t.global_position = at
	t._yaw = yaw
	t.rotation.y = yaw
	pool.died.connect(t._on_wrecked)
	return t


## Drive to `to` and let the cargo out there.
func send(to: Vector3) -> void:
	goal = to
	state = "driving"
	_path = PackedVector3Array()
	_path_id = services.ai_nav.request_path(global_position, to, 8.0, 20000)
	_from = global_position
	_moved_at = services.now()


func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= GRAVITY * delta
	else:
		velocity.y = maxf(velocity.y, 0.0)
	if state != "driving":
		velocity.x = move_toward(velocity.x, 0.0, DRIVE * delta * 2.0)
		velocity.z = move_toward(velocity.z, 0.0, DRIVE * delta * 2.0)
		move_and_slide()
		return
	var now := services.now()
	if now < _reverse_until:
		# Backing off what it was stuck on, before trying the way again.
		var back := global_transform.basis.z
		velocity.x = back.x * DRIVE * 0.35
		velocity.z = back.z * DRIVE * 0.35
		move_and_slide()
		_from = global_position
		_moved_at = now
		return
	if _path.is_empty():
		var st := services.ai_nav.get_status(_path_id)
		if st == AINav.PENDING:
			move_and_slide()
			return
		if st != AINav.DONE:
			_arrive("no way")   # let them out here and walk
			return
		_path = services.ai_nav.get_path(_path_id)
		_wp = 1 if _path.size() > 1 else 0
		# Face the way out before moving off: turning on the spot swings the
		# tail into whatever it was parked beside.
		if _wp < _path.size():
			var first := _path[mini(_wp + 2, _path.size() - 1)] - global_position
			if Vector2(first.x, first.z).length() > 0.5:
				_yaw = atan2(-first.x, -first.z)
				rotation.y = _yaw
	var at := global_position
	if Vector2(goal.x - at.x, goal.z - at.z).length() < DROP:
		_arrive("there")
		return
	while _wp < _path.size() and Vector2(_path[_wp].x - at.x, _path[_wp].z - at.z).length() < 2.0:
		_wp += 1
	if _wp >= _path.size():
		_arrive("end of path")
		return
	var to := _path[_wp] - at
	var want := atan2(-to.x, -to.z)
	var turn := clampf(wrapf(want - _yaw, -PI, PI), -TURN * delta, TURN * delta)
	_yaw += turn
	rotation.y = _yaw
	# Slower through a sharp turn.
	var speed := DRIVE * clampf(1.0 - absf(wrapf(want - _yaw, -PI, PI)) / PI, 0.3, 1.0)
	var fwd := -global_transform.basis.z
	velocity.x = fwd.x * speed
	velocity.z = fwd.z * speed
	move_and_slide()
	# A kerb: pressed against something while on the ground and going nowhere,
	# a pop up the way wheels climb one. Not a wall: a wall is still a wall,
	# and STUCK lets them out there.
	if is_on_floor() and is_on_wall() and Vector2(velocity.x, velocity.z).length() < speed * 0.3:
		velocity.y = KERB_POP
	if at.distance_to(_from) > 1.0:
		_from = at
		_moved_at = now
	elif now - _moved_at > STUCK and _reversals < 1:
		# The first time: back off and try again -- a corner clipped on a turn
		# is usually cleared by a length of reverse.
		_reversals += 1
		_reverse_until = now + REVERSE
	elif now - _moved_at > STUCK:
		# What it is up against, for the log: the thing a vehicle map would
		# have routed round.
		for i in get_slide_collision_count():
			var col := get_slide_collision(i)
			var who := col.get_collider()
			var layer := PhysicsServer3D.body_get_collision_layer(col.get_collider_rid())
			stuck_on.append("%s layer %d at %v n %v" % [who.get_class() if who != null else "server body",
					layer, col.get_position() - global_position, col.get_normal()])
		_arrive("stuck")


func _arrive(why: String) -> void:
	if state != "driving":
		return
	stopped_because = why
	state = "arrived"
	# Unloaded, it goes: an empty truck is in the next one's way.
	get_tree().create_timer(LEAVE_AFTER).timeout.connect(func() -> void:
		if is_instance_valid(self) and state == "arrived" and cargo.is_empty():
			queue_free())
	if _path_id >= 0:
		services.ai_nav.release(_path_id)
	arrived.emit(self)


## Is there room for a truck at `at` (feet), any way round -- a circle of its
## length, less a hand's breadth, clear of everything a truck hits?
static func room_at(world: World3D, at: Vector3) -> bool:
	var q := PhysicsShapeQueryParameters3D.new()
	var c := CylinderShape3D.new()
	# A full length and a metre: room to turn, and clear of another truck
	# parked there (a tail swung into one stuck the next).
	c.radius = SIZE.z + 1.0
	c.height = SIZE.y - CLEARANCE
	q.shape = c
	q.transform = Transform3D(Basis(), at + Vector3.UP * (CLEARANCE + c.height * 0.5 + 0.05))
	q.collision_mask = Layers.STRUCTURE | Layers.DEBRIS | Layers.FALLING | Layers.WORLD
	return world.direct_space_state.intersect_shape(q, 1).is_empty()


## Is a route wide enough for a truck the whole way -- at every waypoint and
## midway between them, a truck's width and a margin clear of buildings? A
## stand-in for the vehicle map (AIVehicles.md 3) until there is one: the foot
## map's paths squeeze between walls a body passes and a truck does not.
static func route_wide(world: World3D, path: PackedVector3Array) -> bool:
	return route_width_share(world, path) >= 1.0


## The share of a route's points with a truck's width clear round them, 0..1.
static func route_width_share(world: World3D, path: PackedVector3Array) -> float:
	var q := PhysicsShapeQueryParameters3D.new()
	var c := CylinderShape3D.new()
	c.radius = SIZE.x * 0.5 + 0.35
	c.height = SIZE.y - CLEARANCE
	q.shape = c
	q.collision_mask = Layers.STRUCTURE | Layers.DEBRIS
	var space := world.direct_space_state
	var clear := 0
	var total := 0
	for i in path.size():
		var pts := [path[i]]
		if i > 0:
			pts.append(path[i - 1].lerp(path[i], 0.5))
		for p in pts:
			total += 1
			q.transform = Transform3D(Basis(), (p as Vector3) + Vector3.UP * (CLEARANCE + c.height * 0.5 + 0.05))
			if space.intersect_shape(q, 1).is_empty():
				clear += 1
	return float(clear) / maxf(total, 1)


## How far along a route a truck gets before the first point it does not fit
## through, in metres: the whole of it when it fits all the way.
static func route_clear_run(world: World3D, path: PackedVector3Array) -> float:
	var q := PhysicsShapeQueryParameters3D.new()
	var c := CylinderShape3D.new()
	c.radius = SIZE.x * 0.5 + 0.35
	c.height = SIZE.y - CLEARANCE
	q.shape = c
	q.collision_mask = Layers.STRUCTURE | Layers.DEBRIS
	var space := world.direct_space_state
	var run := 0.0
	for i in path.size():
		var pts := [path[i]]
		if i > 0:
			pts.push_front(path[i - 1].lerp(path[i], 0.5))
		for p in pts:
			q.transform = Transform3D(Basis(), (p as Vector3) + Vector3.UP * (CLEARANCE + c.height * 0.5 + 0.05))
			if not space.intersect_shape(q, 1).is_empty():
				return run + (path[i - 1].distance_to(p) if i > 0 else 0.0)
		if i > 0:
			run += path[i - 1].distance_to(path[i])
	return run


## Where the cargo gets out: behind and beside the truck, on the side away from
## `threat` (its lee), as far out as a body can stand.
func tailgate_points(threat: Vector3, n: int) -> Array[Vector3]:
	var out: Array[Vector3] = []
	var b := global_transform.basis
	var side := b.x if (b.x.dot(global_position - threat) > 0.0) else -b.x
	var rear := b.z
	var base := global_position + rear * (SIZE.z * 0.5 + 1.0)
	for i in n * 3:
		if out.size() >= n:
			break
		var p := base + side * (0.8 + 0.9 * (i % 3)) + rear * (0.9 * (i / 3))
		p = services.ai_nav.snap(p)
		if services.ai_nav.can_stand(p):
			out.append(p)
	return out


func _on_wrecked() -> void:
	state = "wrecked"
	wrecked.emit(self)


func _build_look() -> void:
	var olive := StandardMaterial3D.new()
	olive.albedo_color = Color(0.33, 0.38, 0.24)
	var dark := StandardMaterial3D.new()
	dark.albedo_color = Color(0.12, 0.12, 0.12)
	var parts := [
		# cab, bed, canopy
		[Vector3(2.2, 1.6, 1.8), Vector3(0.0, 1.2, -1.8), olive],
		[Vector3(2.3, 0.5, 3.6), Vector3(0.0, 0.8, 0.9), olive],
		[Vector3(2.2, 1.3, 3.4), Vector3(0.0, 1.75, 0.9), olive],
	]
	for p in parts:
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = p[0]
		bm.material = p[2]
		mi.mesh = bm
		mi.position = p[1]
		add_child(mi)
	for x in [-1.1, 1.1]:
		for z in [-1.9, 1.6]:
			var w := MeshInstance3D.new()
			var cm := CylinderMesh.new()
			cm.top_radius = 0.45
			cm.bottom_radius = 0.45
			cm.height = 0.35
			cm.material = dark
			w.mesh = cm
			w.rotation.z = PI * 0.5
			w.position = Vector3(x, 0.45, z)
			add_child(w)
