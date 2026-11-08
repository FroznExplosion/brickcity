extends SceneTree
## The ghost hull (Docs/Hulls.md 7b): a generated ship's brick collision standing
## still in a physics space of its own (GhostHulls), walked on while the real ship
## rocks, turns and flies; shots, sight lines, damage, repair, docking and sleep
## through it.
##
##     godot --headless --path . --script res://tools/ghost_hull_probe.gd
##
##   built     its ghost built once when its bricks are in, in the ghost space
##   board     a body on its deck taken into the ghost: the same place on the ship,
##             its velocity turned into the deck's
##   stands    WAIT (60) s of the ship rocking, turning and flying fast: the body
##             stands where it was on the deck, drawn there on the real ship
##   walks     walked along the deck: the distance it walked, whatever the ship did
##   shot      fired aboard (ShipRays, as every gun casts): the wall it was aimed at,
##             a brick of the real ship, as structure
##   sight     a wall between hides the crew; a hole shot in it while it flies (the
##             ghost has it too) lets a shot from outside in, onto the crew
##   repair    while it flies, its bricks back in the ghost
##   loose     a brick with no outside to it counts as inside the hull (a group come
##             loose there stays in it, as crumbs riding with the ship)
##   moves     three frames of travel (planet, space, another planet), the origin
##             recentred each time: the ghost never rebuilt, the body where it was
##   asleep    its ghost switched off and on with its planet, never rebuilt
##   docked    from one ship's ghost straight onto another's, the same place
##   get off   back in the world at the real ship's place, the deck's velocity plus
##             its own

## The doc's gate: a minute on the deck of a ship rocking, turning and flying.
const WAIT := 60.0
const WALK := 3.0
const WALK_SPEED := 2.0
const GRAVITY := 9.8

var _pass := 0
var _fail := 0
var _st: SpaceStation
var _st2: SpaceStation
var _ghosts: GhostHulls
var _body: CharacterBody3D
var _frames := 0
var _stage := 0
var _t := 0.0
var _start := Vector3.ZERO
var _home := Transform3D()
var _ship_t := 0.0
var _walk := Vector3.ZERO
var _walk_time := WALK
var _drift_worst := 0.0
var _v0 := Vector3.ZERO


func _ok(what: String, cond: bool, detail := "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _finish() -> void:
	ShipRays.ships.clear()
	if _body != null:
		_body.queue_free()
	if _ai != null:
		_ai.body.queue_free()
	if _st2 != null:
		_st2.deactivate()
		_st2.queue_free()
	if _st != null:
		_st.deactivate()
		_st.queue_free()
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _ship(sd: int, title: String) -> SpaceStation:
	var d := OrbitalData.new()
	d.kind = "ship"
	d.layout = "generated"
	d.orbital_name = title
	d.orbital_seed = sd
	var st := SpaceStation.new()
	root.add_child(st)
	st.ghosts = _ghosts
	st.setup(d)
	st.prepare()
	st.activate()
	return st


func _physics_process(delta: float) -> bool:
	_frames += 1
	match _stage:
		0:
			print("ghost hull probe")
			_ghosts = GhostHulls.new()
			_st = _ship(1, "ghost ship")
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
			# Flown over a world: its bricks' world collision put away, only the ghost
			# to walk and to shoot.
			_st.ride()
			ShipRays.ships.clear()
			ShipRays.ships.append(_st)
			_board()
			_drop_cargo()
			_stage = 2
		2:
			_ship_move(delta)
			_gravity_step(delta, Vector3.ZERO)
			ShipCargo.tick(self, [_st], _st.get_world_3d().space)
			_t += delta
			_drift_worst = maxf(_drift_worst, (_body.global_position - _start).length())
			if _t < WAIT:
				return false
			_ok("stands: the ship rocking, turning, flying -- the body where it stood on the deck",
					_drift_worst < 0.02 and _body.is_on_floor(),
					"drift %.4f m worst over %.0f s, on the floor %s" % [_drift_worst, WAIT, _body.is_on_floor()])
			var on_ship := _st.ghost_slot.affine_inverse() * _start
			var real := _st.ghost_to_real() * _body.global_position
			var want := _st.global_transform * on_ship
			_ok("drawn on the real ship at the same place on it", (real - want).length() < 0.02,
					"%.4f m off, the ship %.0f m from where it was" % [(real - want).length(),
					(_st.global_position - _home.origin).length()])
			_cargo_checks()
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
			_sleep_check()
			_st2 = _ship(2, "ghost ship 2")
			_frames = 0
			_stage = 4
		4:
			if not _st2.bricked:
				if _frames > 1800:
					_ok("a second ship's bricks laid", false)
					_finish()
					return true
				return false
			_st2.global_transform = _st.global_transform
			_st2.ride()
			_dock_check()
			_get_off_check()
			_ai_start()
			_t = 0.0
			_stage = 5
		5:
			# An AI pawn (any pawn but the player's) aboard: carried by the same
			# crossing, its world-frame move turned into the ghost's.
			_ai.intents.move = _ai_dir
			_t += delta
			if _t < 1.5:
				return false
			var moved := _st.ghost_to_real() * _ai.body.global_position - _ai_from
			_ok("an AI pawn: on the ghost by the same crossing, walking where its world move says, aimed at in the world",
					_ai_boarded and _ai.ghost == _st and moved.length() > 1.0
					and moved.normalized().dot(_ai_dir) > 0.8 and (_ai.feet() - (_st.ghost_to_real() * _ai.feet_here())).length() < 1e-3,
					"%.2f m, %.2f along its move" % [moved.length(), moved.normalized().dot(_ai_dir)])
			_finish()
			return true
	return false


var _cargo: RigidBody3D
var _cargo_view: MeshInstance3D
var _cargo_g0 := Vector3.ZERO


## A crate dropped over the deck in the world, beside the crew (Docs/Hulls.md 7b.4).
func _drop_cargo() -> void:
	_cargo = RigidBody3D.new()
	_cargo.mass = 3.0
	# On the rubble layer, as a dropped gun is: it lies on bricks.
	_cargo.collision_layer = Layers.RUBBLE
	_cargo.collision_mask = Layers.RUBBLE_MASK
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = Vector3(0.3, 0.3, 0.3)
	cs.shape = bs
	_cargo.add_child(cs)
	_cargo_view = MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = bs.size
	_cargo_view.mesh = bm
	_cargo.add_child(_cargo_view)
	_cargo.add_to_group(ShipCargo.CARGO)
	root.add_child(_cargo)
	var up := _st.ghost_up()
	var g := _body.global_position + up * 1.0 + (_st.ghost_slot * _st.frame).basis.x.normalized() * 0.8
	_cargo_g0 = g
	_cargo.global_transform = Transform3D(Basis(), _st.ghost_to_real() * g)
	# Dropped by the crew: aboard at once, before the ship flies on.
	ShipCargo.tick(self, [_st], _st.get_world_3d().space)


func _cargo_checks() -> void:
	var on: bool = _cargo.has_meta(&"ghosted") and _cargo.get_meta(&"ghosted") == _st
	var g := _cargo.global_position
	var fell := (_cargo_g0 - g).dot(_st.ghost_up())
	var rests := _cargo.linear_velocity.length() < 0.05
	var real := _st.ghost_to_real() * g
	var drawn := _cargo_view.global_position.distance_to(real)
	_ok("cargo: a crate dropped on the flying deck rides in its ghost, lies on the deck, drawn on the real ship",
			on and drawn < 0.02 and (fell > 0.4 and rests if _st.ghost_pulls() else fell < 0.05),
			"ghosted %s, fell %.2f m, speed %.3f, drawn %.4f m off (the ship pulls: %s)" % [on, fell,
			_cargo.linear_velocity.length(), drawn, _st.ghost_pulls()])
	ShipCargo.get_off(_cargo, _st, _st.get_world_3d().space)
	_ok("cargo off: back in the world where it was drawn", not _cargo.has_meta(&"ghosted")
			and _cargo.global_position.distance_to(real) < 0.02 and not _cargo_view.top_level,
			"%.4f m" % _cargo.global_position.distance_to(real))
	_cargo.queue_free()


var _ai: Pawn
var _ai_dir := Vector3.ZERO
var _ai_from := Vector3.ZERO
var _ai_boarded := false


func _ai_start() -> void:
	var at := _st.global_transform * _st.cell_point(_st.seat_cell) + _st.global_basis.y * 0.05
	_ai = Pawn.spawn(root, at, 1)
	var ships: Array = [_st]
	_ai_boarded = GhostHulls.tick(_ai, ships, _st.get_world_3d().space) == 1
	# Along the clear way the body walked, in the world.
	_ai_dir = Gravity.flat(_st.ghost_to_real().basis * _walk, _st.global_basis.y).normalized()
	_ai_from = _st.ghost_to_real() * _ai.body.global_position


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
	_body.collision_layer = Layers.PAWN
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
	for i in 30:
		_gravity_step(1.0 / 60.0, Vector3.ZERO)
	_start = _body.global_position


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


## The world's rays, as every gun and sight line casts them (ShipRays.cast).
func _cast(from: Vector3, to: Vector3, ex: Array[RID] = []) -> Dictionary:
	return ShipRays.cast(_st.get_world_3d().direct_space_state,
			PhysicsRayQueryParameters3D.create(from, to, Layers.GUN_MASK, ex))


func _shot_checks() -> void:
	var g2r := _st.ghost_to_real()
	var up := _st.ghost_up()
	var me: Array[RID] = [_body.get_rid()]
	# Fired aboard, from the eye (the camera is in the world, on the real ship).
	var eye: Vector3 = g2r * (_body.global_position + up * 1.5)
	var dir := g2r.basis * (_st.ghost_slot * _st.frame).basis.z.normalized()
	# The first way round that meets bricks (a shut door's twin in the ghost is a
	# wall too, but not a brick to shoot a hole in).
	var hit := {}
	var real_ok := false
	for k in 16:
		var d := Basis((g2r.basis * up).normalized(), TAU * k / 16.0) * dir
		var h := _cast(eye, eye + d * 60.0, me)
		if h.is_empty():
			continue
		var cell := Vector3i((_st.cell_at(h.position + d * 0.1)).floor())
		if _st.bricks.is_solid(_st.chunk, cell):
			hit = h
			dir = d
			real_ok = true
			break
	_ok("shot aboard: the gun's ray meets the wall it was aimed at, a brick of the real ship, as structure",
			not hit.is_empty() and real_ok and hit.get("ship") == _st and hit.get("collider") == _st.shell_body,
			"%s" % (str(hit.get("position")) if not hit.is_empty() else "nothing"))
	if hit.is_empty():
		return
	var wall: Vector3 = hit.position
	# Who looks through that wall from the far side sees the wall, not the crew.
	var far := wall + dir * 1.5
	var chest: Vector3 = g2r * (_body.global_position + up * 1.0)
	var seen := _cast(far, chest)
	_ok("sight: a wall between hides the crew", seen.get("collider") != _body,
			"meets %s" % str(seen.get("collider")))
	# A hole there, by the hit path, while it flies.
	var lost0 := _st.gone().size()
	_st.damage(wall + dir * GunController.INTO_SURFACE, {"blast": true, "radius": 1.0, "hp": 0})
	_st._damage_step()
	var again := _cast(eye, wall + dir * 0.4, me)
	_ok("hit while it flies: bricks lost, and the ghost's wall has the hole too",
			_st.gone().size() > lost0 and (again.is_empty() or (again.position - eye).length() > (wall - eye).length() + 0.3),
			"%d brick(s) lost" % (_st.gone().size() - lost0))
	# From the far side, in through the hole: the shot (and the sight line) meets
	# the crew member standing there, in the ghost.
	seen = _cast(far, chest)
	_ok("in through the hole: a shot or a look from outside meets the crew inside", seen.get("collider") == _body,
			"meets %s" % str(seen.get("collider")))
	_st.restore(_st.restorable(wall, 30.0), wall, 30.0)
	_st._damage_step()
	again = _cast(eye, wall + dir * 0.4, me)
	_ok("repair while it flies: its bricks back in the ghost", not again.is_empty() and _st.gone().size() == lost0,
			"%d gone" % _st.gone().size())
	var inner := -1
	var outer := -1
	for b in _st.bricks.get_block_count(_st.chunk):
		var ins := _st._inside_hull(PackedInt32Array([b]))
		if ins and inner < 0:
			inner = b
		elif not ins and outer < 0:
			outer = b
		if inner >= 0 and outer >= 0:
			break
	_ok("loose inside: a brick with no outside to it is inside the hull, a hull brick is not",
			inner >= 0 and outer >= 0, "inner %d, outer %d" % [inner, outer])


func _moves_check() -> void:
	var g := _body.global_position
	var bodies := _st.ghost.bodies.duplicate()
	var holder := Node3D.new()
	root.add_child(holder)
	_st.reparent(holder, true)
	var on_ship := _st.global_transform.affine_inverse() * (_st.ghost_to_real() * g)
	# Planet -> space -> a second planet: three frames' worth of travel, each a rigid
	# move of everything in the world (PlanetSystem._travel), and the origin
	# recentred after each (PlanetFrame.recentre) -- the ghosted body is skipped.
	for m: Transform3D in [Transform3D(Basis(Vector3.UP, 0.7), Vector3(9000, 0, -300)),
			Transform3D(Basis(Vector3.RIGHT, 1.2), Vector3(-2e5, 4e4, 0)),
			Transform3D(Basis(Vector3.BACK, -0.4), Vector3(5000, -7000, 3e5))]:
		holder.global_transform = m * holder.global_transform
		PlanetFrame.recentre(root, _st.global_position)
		_st.on_origin_shift()
	var real1 := _st.ghost_to_real() * _body.global_position
	var off := (real1 - _st.global_transform * on_ship).length()
	_ok("moves: three frames, the origin recentred each time -- the ghost never rebuilt, the body where it was on the ship",
			_st.ghost_builds == 1 and _st.ghost.bodies == bodies and (_body.global_position - g).length() < 1e-4
			and off < 0.01, "%d build(s), %.4f m off its place on the ship" % [_st.ghost_builds, off])


## Its planet asleep: the ghost switched off (out of the space) and on again,
## nothing rebuilt; whoever stood on it where they were.
func _sleep_check() -> void:
	var g := _body.global_position
	var up := _st.ghost_up()
	var down := PhysicsRayQueryParameters3D.create(g + up * 0.5, g - up * 2.0, Layers.STRUCTURE)
	_st.ghost_switch(false)
	var off := _ghosts.state().intersect_ray(down).is_empty()
	_st.ghost_switch(true)
	var on := not _ghosts.state().intersect_ray(down).is_empty()
	_ok("asleep: its ghost switched off and on with its planet, never rebuilt", off and on
			and _st.ghost_builds == 1 and (_body.global_position - g).length() < 1e-4)


## Docked: off one ship's ghost straight onto the other's, at the same place in the
## world, in a slot of its own.
func _dock_check() -> void:
	var real := _st.ghost_to_real() * _body.global_position
	GhostHulls.get_off(_body, _st, _st.get_world_3d().space)
	GhostHulls.board(_body, _st2)
	var back := _st2.ghost_to_real() * _body.global_position
	_ok("docked: ghost to ghost, the same place in the world, its own slot", (back - real).length() < 1e-3
			and _body.get_meta(&"ghosted") == _st2 and _st2.ghost_slot.origin != _st.ghost_slot.origin,
			"slots %s / %s" % [str(_st.ghost_slot.origin), str(_st2.ghost_slot.origin)])
	GhostHulls.get_off(_body, _st2, _st.get_world_3d().space)
	GhostHulls.board(_body, _st)


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
