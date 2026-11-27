class_name Mob
extends Node
## A creature of the mine world (Docs/MineCreatures.md): a Pawn's body driven
## by a brain, walking TerrainNav's graph. MobZombie and MobPig extend it.
##
## Positions are in the TERRAIN frame (the mine world node's local space, which
## the origin shift moves): `feet()`, paths, goals. The Pawn works in global
## space; MineMobs converts (to_terrain / to_world). Directions are the same in
## both, the shift being a translation.
##
## A path is asked on a worker (TerrainNav.find_path in WorkerThreadPool) and
## taken when done, never waited for (CLAUDE.md).

const THINK_HZ := 4.0
## A path older than this is asked again when the goal is far.
const PATH_STALE := 3.0
const ARRIVE := 0.3

var mobs   # MineMobs -- untyped: two class_name scripts typing each other leak at exit
var pawn: Pawn
var kind := &""
## TerrainNav body: width studs, height plates, step up plates, drop plates.
var body := Vector4i(2, 12, 3, 19)
## A fall of at least this many bricks onto a planted plot tramples it
## (Docs/MineCreatures.md 5.3). 0: walking over one is enough.
var trample_bricks := 3.0
var look: Node3D
var state := "idle"
var asleep := false
## Brain off, standing (a gate holds one in place).
var held := false
var dead := false
var running := false
var trampled := 0
## Where to face instead of the way it walks (INF: the walk).
var face_point := Vector3.INF
## The last path's answer: did it get to the goal (false: as near as it could).
var path_reached := false
var path_answers := 0
## The path held answers the goal now asked (not an older one).
var answered := false

var _goal := Vector3.INF
var _path := PackedVector3Array()
var _wp := 0
var _job := -1
var _job_out := []
var _job_goal := Vector3.INF
var _path_at := -INF
var _next_think := 0.0
var _stuck_at := Vector3.INF
var _stuck_t := 0.0
var _anim_t := 0.0
var _die_t := 0.0


## Called once by MineMobs after the pawn is made.
func attach(p_mobs, p_pawn: Pawn, p_look: Node3D) -> void:
	mobs = p_mobs
	pawn = p_pawn
	look = p_look
	name = "Mob"
	process_physics_priority = -5
	pawn.body.add_child(self)
	pawn.no_crouch = true
	if look != null:
		pawn.body.add_child(look)
		look.position = Vector3.DOWN * pawn.stand_height * 0.5
	pawn.landed.connect(_on_landed)


func feet() -> Vector3:
	return mobs.to_terrain(pawn.feet())


func is_dead() -> bool:
	return dead or pawn == null or not is_instance_valid(pawn) or (pawn.health != null and pawn.health.is_dead())


## The brain, THINK_HZ times a second.
func think(_now: float) -> void:
	pass


## The point to walk to this tick, when the brain steers by something other
## than a path (a zombie on the flow field). INF: follow the path.
func steer_point() -> Vector3:
	return Vector3.INF


## Ask for a way to `goal` (terrain frame), unless the one held still serves.
func walk_to(goal: Vector3, now: float) -> void:
	var same := _goal != Vector3.INF and goal.distance_to(_goal) < 1.0
	if same and (now - _path_at < PATH_STALE or feet().distance_to(goal) < 4.0):
		return
	if not same:
		_path = PackedVector3Array()
		_wp = 0
		answered = false
	_goal = goal
	if _job >= 0:
		return     # one ask at a time: the next think asks again
	_job_goal = goal
	var out := []
	_job_out = out
	var nav: TerrainNav = mobs.nav
	var from := feet()
	var b := body
	_job = WorkerThreadPool.add_task(func() -> void:
			out.append(nav.find_path(from, goal, b, 4000)), true, "mob path")
	_path_at = now


func stop() -> void:
	_goal = Vector3.INF
	_path = PackedVector3Array()
	_wp = 0


## At the end of the path held (or it has none).
func arrived() -> bool:
	return _path.is_empty() or _wp >= _path.size()


func _poll_path() -> void:
	if _job < 0 or not WorkerThreadPool.is_task_completed(_job):
		return
	WorkerThreadPool.wait_for_task_completion(_job)   # done: returns at once
	_job = -1
	if _job_out.is_empty() or _goal == Vector3.INF:
		return
	if _job_goal != _goal:
		_path_at = -INF    # answered a goal since changed: ask again
		return
	var res: Dictionary = _job_out[0]
	_path = res.path
	_wp = 1 if _path.size() > 1 else 0
	path_reached = bool(res.reached)
	path_answers += 1
	answered = true


func _physics_process(delta: float) -> void:
	if dead:
		_dying(delta)
		return
	if is_dead():
		_die()
		return
	if asleep:
		return
	if held:
		pawn.intents.move = Vector3.ZERO
		return
	var now: float = mobs.now()
	if now >= _next_think:
		_next_think = now + 1.0 / THINK_HZ
		think(now)
	_poll_path()
	_steer(delta)
	_animate(delta)


func _steer(delta: float) -> void:
	var f := feet()
	var to := steer_point()
	if to == Vector3.INF and not _path.is_empty():
		while _wp < _path.size() and Vector2(_path[_wp].x - f.x, _path[_wp].z - f.z).length() < ARRIVE:
			_wp += 1
		if _wp < _path.size():
			to = _path[_wp]
	var wish := Vector3.ZERO
	if to != Vector3.INF:
		var d := Vector3(to.x - f.x, 0.0, to.z - f.z)
		if d.length() > 0.08:
			wish = d.normalized()
	if wish != Vector3.ZERO:
		wish = (wish + mobs.separation(self) * 0.6).normalized()
	pawn.intents.move = wish
	pawn.intents.run = running
	pawn.intents.jump = false
	# Stuck against something the graph says is not there (a body, a crop's
	# edge): a hop, then a new path.
	if wish != Vector3.ZERO:
		if _stuck_at == Vector3.INF or f.distance_to(_stuck_at) > 0.25:
			_stuck_at = f
			_stuck_t = 0.0
		else:
			_stuck_t += delta
			if _stuck_t > 1.2:
				_stuck_t = 0.0
				pawn.intents.jump = true
				_path_at = -INF
	else:
		_stuck_t = 0.0


func _animate(delta: float) -> void:
	if look == null:
		return
	var v := pawn.body.velocity
	var speed := Vector2(v.x, v.z).length()
	_anim_t += delta
	MobLooks.swing(look, _anim_t, speed)
	var want := INF
	if face_point != Vector3.INF:
		var d := face_point - feet()
		if Vector2(d.x, d.z).length() > 0.1:
			want = atan2(-d.x, -d.z)
	elif speed > 0.2:
		want = atan2(-v.x, -v.z)
	if want != INF:
		look.rotation.y = lerp_angle(look.rotation.y, want, minf(1.0, delta * 8.0))


func _on_landed() -> void:
	if dead or mobs.host.farming == null:
		return
	if trample_bricks > 0.0 and pawn.last_fall < trample_bricks * Pawn.BRICK_M - 0.05:
		return
	if mobs.host.farming.creature_landed(feet()):
		trampled += 1
		mobs.log_line("%s trampled a plot (fell %.2f m)" % [kind, pawn.last_fall])


## Walking over plots tramples them, for a creature with trample_bricks 0.
func _walk_trample() -> void:
	if trample_bricks <= 0.0 and pawn.is_on_floor() and mobs.host.farming != null:
		if mobs.host.farming.creature_landed(feet()):
			trampled += 1


func _die() -> void:
	dead = true
	_die_t = 0.0
	pawn.intents.move = Vector3.ZERO
	for c in pawn.body.get_children():
		if c is CollisionShape3D:
			(c as CollisionShape3D).set_deferred(&"disabled", true)
	pawn.body.collision_layer = 0
	mobs.on_died(self)


## Tip over, then go.
func _dying(delta: float) -> void:
	_die_t += delta
	if look != null:
		look.rotation.z = minf(_die_t / 0.5, 1.0) * PI * 0.5
	if _die_t > 2.0 and pawn != null and is_instance_valid(pawn.body):
		pawn.body.queue_free()


func _exit_tree() -> void:
	# Leaving the tree (a new world, quitting): the job's answer is thrown away.
	if _job >= 0:
		WorkerThreadPool.wait_for_task_completion(_job)
		_job = -1
