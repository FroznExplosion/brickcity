extends SceneTree
## The ghost hull (Docs/Hulls.md 7b): a generated ship's brick collision standing
## still in a physics space of its own (GhostHulls), walked on while the real ship
## rocks, turns and flies.
##
##     godot --headless --path . --script res://tools/ghost_hull_probe.gd
##
##   built     its ghost built once when its bricks are in, in the ghost space, not
##             the world's
##   board     a body standing on its deck taken into the ghost: the same place on
##             the ship, its velocity turned into the deck's
##   stands    WAIT seconds of the ship rocking, turning and flying fast: the body
##             stands where it was on the deck (no drift), drawn there on the real ship
##   walks     walked along the deck: the distance it was walked, whatever the ship did
##   moves     the ship moved to another frame and the origin shifted under it: the
##             ghost never rebuilt, the body where it was
##   shot      a ray fired aboard (in the ghost) meets the wall it was aimed at -- a
##             brick of the real ship there
##   damage    a hole shot in the hull: the ghost's wall has the hole too
##   repair    the bricks back: so is the ghost's
##   get off   back in the world: at the real ship's place, its velocity the deck's
##             plus its own, as it was before it boarded

const WAIT := 6.0
const WALK := 3.0
const WALK_SPEED := 2.0
const GRAVITY := 9.8

var _pass := 0
var _fail := 0
var _st: SpaceStation
var _ghosts: GhostHulls
var _body: CharacterBody3D
var _frames := 0
var _stage := 0
var _t := 0.0
var _start := Vector3.ZERO
var _home := Transform3D()
var _ship_t := 0.0
var _walk := Vector3.ZERO
var _drift_worst := 0.0
var _real_worst := 0.0
var _v0 := Vector3.ZERO


func _ok(what: String, cond: bool, detail := "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _finish() -> void:
	if _body != null:
		_body.queue_free()
	if _st != null:
		_st.deactivate()
	if _ghosts != null:
		_ghosts.free_space()
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _physics_process(delta: float) -> bool:
	_frames += 1
	match _stage:
		0:
			print("ghost hull probe")
			_ghosts = GhostHulls.new()
			var d := OrbitalData.new()
			d.kind = "ship"
			d.layout = "generated"
			d.orbital_name = "ghost ship"
			d.orbital_seed = 1
			_st = SpaceStation.new()
			root.add_child(_st)
			_st.ghosts = _ghosts
			_st.setup(d)
			_st.prepare()
			_st.activate()
			_home = _st.global_transform
			_stage = 1
		1:
			if not _st.bricked:
				if _frames > 1800:
					_ok("its bricks laid", false)
					_finish()
					return true
				return false
			_ok("built: its ghost once, in its own space", _st.ghost_builds == 1 and _st.ghost != null
					and _st.ghost.bodies.size() > 0
					and PhysicsServer3D.body_get_space(_st.ghost.bodies[0]) == _ghosts.space
					and _ghosts.space != _st.get_world_3d().space,
					"%d band bod(ies), slot %s" % [_st.ghost.bodies.size() if _st.ghost != null else 0,
					str(_st.ghost_slot.origin)])
			_board()
			_stage = 2
		2:
			_ship_move(delta)
			_gravity_step(delta, Vector3.ZERO)
			_t += delta
			var drift := (_body.global_position - _start).length()
			_drift_worst = maxf(_drift_worst, drift)
			if _t < WAIT:
				return false
			_ok("stands: the ship rocking, turning, flying -- the body where it stood on the deck",
					_drift_worst < 0.02 and _body.is_on_floor(),
					"drift %.4f m worst over %.1f s, on the floor %s" % [_drift_worst, WAIT, _body.is_on_floor()])
			# Where it stood on the ship, in the ship's own frame, against where it is.
			var on_ship := _st.ghost_slot.affine_inverse() * _start
			var real := _st.ghost_to_real() * _body.global_position
			var want := _st.global_transform * on_ship
			_ok("drawn on the real ship at the same place on it", (real - want).length() < 0.02,
					"%.4f m off, the ship %.0f m from where it was" % [(real - want).length(),
					(_st.global_position - _home.origin).length()])
			_t = 0.0
			_start = _body.global_position
			_walk = _clear_way()
			_stage = 3
		3:
			_ship_move(delta)
			_gravity_step(delta, _walk * WALK_SPEED)
			_t += delta
			if _t < _walk_time:
				return false
			var moved := Gravity.flat(_body.global_position - _start, _st.ghost_up()).length()
			_ok("walks: the distance it walked along the deck, whatever the ship did",
					absf(moved - _walk_time * WALK_SPEED) < 0.3, "%.2f m in %.1f s (walked %.2f)" % [
					moved, _walk_time, _walk_time * WALK_SPEED])
			_shot_checks()
			_moves_check()
			_get_off_check()
			_finish()
			return true
	return false


## The ship's motion: a rock, a turn and a fast flight, as a boat in a swell or
## a ship banking would.
func _ship_move(delta: float) -> void:
	_ship_t += delta
	var b := Basis(Vector3.UP, _ship_t * 0.6) * Basis(Vector3.RIGHT, sin(_ship_t * 1.7) * 0.25) \
			* Basis(Vector3.BACK, sin(_ship_t * 1.1) * 0.2)
	_st.global_transform = Transform3D(b, _home.origin + Vector3(_ship_t * 300.0, sin(_ship_t) * 20.0, 0.0))


## A body standing in the ghost: its ship's gravity, `wish` along the deck.
func _gravity_step(delta: float, wish: Vector3) -> void:
	var up := _st.ghost_up()
	var v := _body.velocity
	v = Gravity.flat(wish, up) + up * v.dot(up)
	if _body.is_on_floor():
		v = Gravity.flat(v, up) - up * 0.1
	else:
		v -= up * GRAVITY * delta
	_body.velocity = v
	_body.up_direction = up
	_body.move_and_slide()


## A body on the deck by the seat, in the world first (as one walking in), then
## onto the ghost.
func _board() -> void:
	_body = CharacterBody3D.new()
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.3
	cap.height = 1.7
	cs.shape = cap
	cs.position = Vector3(0, 0.85, 0)
	_body.add_child(cs)
	_body.collision_mask = Layers.STRUCTURE | Layers.WORLD
	root.add_child(_body)
	# The bridge's seat (SpaceShip.seat), on its floor.
	var at := _st.global_transform * _st.cell_point(_st.seat_cell) + _st.global_basis.y * 0.05
	_body.global_transform = Transform3D(_st.global_basis, at)
	_v0 = Vector3(3.0, 0.0, -1.0)
	_body.velocity = _v0
	GhostHulls.board(_body, _st)
	var g := _body.global_position
	var back := _st.ghost_to_real() * g
	_ok("board: into the ghost space at the same place on the ship", GhostHulls.is_ghosted(_body)
			and PhysicsServer3D.body_get_space(_body.get_rid()) == _ghosts.space
			and (back - at).length() < 1e-3 and (_body.velocity - _st.ghost_to_real().basis.inverse() * _v0).length() < 1e-3,
			"ghost %s" % str(g))
	_body.velocity = Vector3.ZERO
	# Settle onto the floor before the watch starts.
	for i in 30:
		_gravity_step(1.0 / 60.0, Vector3.ZERO)
	_start = _body.global_position


var _walk_time := WALK


## The clearest way along the deck from where it stands (in the ghost: a ray at
## the knee), and how long to walk it to stay a metre short of what it meets.
func _clear_way() -> Vector3:
	var up := _st.ghost_up()
	var fwd := (_st.ghost_slot * _st.frame).basis.z.normalized()
	var from := _body.global_position + up * 0.4
	var best := fwd
	var best_d := 0.0
	for k in 16:
		var d := Basis(up, TAU * k / 16.0) * fwd
		var hit := _ghosts.state().intersect_ray(PhysicsRayQueryParameters3D.create(from, from + d * 8.0))
		var free: float = 8.0 if hit.is_empty() else (hit.position - from).length()
		if free > best_d:
			best_d = free
			best = d
	_walk_time = clampf((best_d - 1.0) / WALK_SPEED, 0.3, WALK)
	return best


func _moves_check() -> void:
	var g := _body.global_position
	var bodies := _st.ghost.bodies.duplicate()
	# Another frame: reparented under a moved node (a planet asleep, a jump), and
	# the origin shifted (its world collision rebuilt, as on_origin_shift does).
	var holder := Node3D.new()
	root.add_child(holder)
	holder.global_transform = Transform3D(Basis(Vector3.UP, 1.0), Vector3(5000, -300, 12000))
	_st.reparent(holder, true)
	_st.global_position += Vector3(-4000, 0, 900)
	_st.on_origin_shift()
	_ok("moves: another frame, an origin shift -- the ghost never rebuilt, the body where it was",
			_st.ghost_builds == 1 and _st.ghost.bodies == bodies and (_body.global_position - g).length() < 1e-4,
			"%d build(s)" % _st.ghost_builds)


func _shot_checks() -> void:
	var space := _ghosts.state()
	var up := _st.ghost_up()
	var from := _body.global_position + up * 1.5
	var dir := (_st.ghost_slot * _st.frame).basis.z.normalized()
	var hit := {}
	for k in 8:
		var d := Basis(up, TAU * k / 8.0) * dir
		var q := PhysicsRayQueryParameters3D.create(from, from + d * 60.0)
		hit = space.intersect_ray(q)
		if not hit.is_empty():
			dir = d
			break
	var real_ok := false
	if not hit.is_empty():
		var real: Vector3 = _st.ghost_to_real() * (hit.position - dir * 0.05)
		var cell := Vector3i((_st.cell_at(real + _st.ghost_to_real().basis * dir * 0.1)).floor())
		real_ok = _st.bricks.is_solid(_st.chunk, cell)
	_ok("shot: a ray aboard meets the wall it was aimed at, a brick of the real ship",
			not hit.is_empty() and real_ok, "%s" % (str(hit.get("position")) if not hit.is_empty() else "nothing"))
	if hit.is_empty():
		return
	# A hole: the bricks round where the ray met the wall, through the hit path.
	_st.riding = false
	var wall: Vector3 = _st.ghost_to_real() * hit.position
	_st.bricks.set_chunk_transform(_st.chunk, _st.global_transform * _st.frame)
	_st.damage(wall, {"blast": true, "radius": 1.0, "hp": 0})
	_st._damage_step()
	var q2 := PhysicsRayQueryParameters3D.create(from, hit.position + dir * 0.4)
	var again := space.intersect_ray(q2)
	_ok("damage: the ghost's wall has the hole too", again.is_empty(),
			"%d brick(s) lost" % _st.gone().size())
	_st.restore(_st.restorable(wall, 30.0), wall, 30.0)
	_st._damage_step()
	again = space.intersect_ray(q2)
	_ok("repair: and its bricks are back in it", not again.is_empty() and _st.gone().is_empty())


func _get_off_check() -> void:
	_body.velocity = Vector3(0.5, 0.0, 0.0)
	var g := _body.global_position
	var real := _st.ghost_to_real() * g
	var want_v := _st.ghost_to_real().basis * _body.velocity + _st.deck_velocity(g)
	GhostHulls.get_off(_body, _st, _st.get_world_3d().space)
	_ok("get off: in the world at the real ship's place, the deck's velocity plus its own",
			not GhostHulls.is_ghosted(_body) and PhysicsServer3D.body_get_space(_body.get_rid()) == _st.get_world_3d().space
			and (_body.global_position - real).length() < 1e-3 and (_body.velocity - want_v).length() < 1e-3,
			"%.1f m/s" % _body.velocity.length())
