class_name Pawn
extends Node
## A character that walks the city: the player, and every soldier the AI runs.
##
## A COMPONENT, never a base class (Docs/Plan.md D7): it sits under the body it
## drives, because GDScript has single inheritance and a pawn has to be able to
## live under a CharacterBody3D today and something else tomorrow. It reads
## `intents` -- filled by PlayerController or by an AI brain, it does not know
## which -- and moves the body at the physics rate, so the same request makes the
## same move on every machine and for every brain.
##
## Every length is derived from the grid rather than from a human: a stud is
## 0.35 m and a plate 0.14 m, so a brick course is 0.42 m and the figure that
## walks this city is measured in bricks like everything else it walks on. The
## movement rules came from the debug walker (DebugCamera), which now drives one
## of these; `-- --walk` is the gate for both.

const PLATE_M := 0.14
const BRICK_M := PLATE_M * 3.0
## Four bricks: 38.4 mm in print, 1.68 m here. The height real brick buildings
## are designed around, so what is built here fits what is built for them
## (Docs/Parts/README.md section 5). The SIZE only -- the figure's shape is our
## own: a bigger head and a slimmer body than the trademarked one.
const BODY_HEIGHT := BRICK_M * 4.0
## The head is a brick and a quarter of it. Eyes at its middle.
const HEAD_HEIGHT := BRICK_M * 1.25
## Crouched: a whole brick shorter, which is exactly the clearance the floor
## under you costs. A room is a fixed number of courses tall, so what you stand ON
## decides whether you fit: a tile floor is one plate, a brick three, and the two
## plates between them are the difference between walking under a beam and being
## stopped dead by it. A brick of crouch covers that with a plate to spare.
const CROUCH_HEIGHT := BODY_HEIGHT - BRICK_M
## A stud and a half across (0.525 m), slimmer than a two-stud figure.
const BODY_RADIUS := 0.35 * 0.75
const EYE_HEIGHT := BODY_HEIGHT - HEAD_HEIGHT * 0.5
## In bricks per second, so they stay honest if the figure is resized: 6.7, 13.3
## and 2.9 courses a second.
const WALK_SPEED := BRICK_M * 6.7
const RUN_SPEED := BRICK_M * 13.3
const CROUCH_SPEED := BRICK_M * 2.9
## Aiming down the sights: a careful walk, 4.4 courses a second.
const AIM_SPEED := BRICK_M * 4.4
## Clears one course and no more, at this gravity.
const JUMP_SPEED := 4.2
const GRAVITY := 20.0
## One brick course plus a hair. A city full of rubble is a city full of kerbs,
## and a body that stops dead on any of them cannot cross its own debris -- so a
## step up to one course is walked over rather than jumped.
const STEP_HEIGHT := BRICK_M + 0.03

signal landed

## Filled by whoever drives this pawn.
var intents := PawnIntents.new()
## Faction. 0 = the players' side.
var team := 0
## The body this drives: the parent.
var body: CharacterBody3D
## Its health, when it has one (spawn(with_health = true)). A child of the body,
## so a bullet that strikes the body finds it (GunController._living).
var health: HealthPool
## Its gun, when it holds one. The motor passes `fire` and `reload` on.
var gun: GunController
## Where it looks from, turned to `intents.look_yaw` / `look_pitch` every tick: a
## gun held by a brain aims down this (a player's gun aims down the camera).
var eye: Node3D
## The player's movement on top of the walk -- momentum, slide, wall-run, mantle,
## grapple (PawnMoves). Null for a soldier, whose walk is the plain one below.
var moves: PawnMoves

var _capsule: CapsuleShape3D
var _height := BODY_HEIGHT
var _auto_crouched := false
## Asking to crouch does nothing (Docs/AI.md A21: no soldier crouches). Ducking
## under something too low to stand under still happens: that is the body, not
## a choice.
var no_crouch := false
## A push from outside -- wind, for now (Docs/Disasters.md, the tornado). Added
## to the walk each step and bled off, so whoever sets it sets it every tick
## they are pushing. Its y lifts: the body rises at least that fast.
var shove := Vector3.ZERO
const SHOVE_DECAY := 3.0
var _was_on_floor := true
## Falls: dropping further than SAFE_FALL hurts, FALL_DAMAGE hp a metre past it
## (Docs/Collapse.md 4.4) -- one storey (2.66 m) is ~30 hp, four storeys kill.
const SAFE_FALL := 1.5
const FALL_DAMAGE := 26.0
var _fall_from := 0.0
## Rising under its own jump: that height was climbed, not fallen from, so it
## does not count towards the fall (a high jump on the flat lands unhurt).
## Set by PawnMoves; cleared at the top of the jump.
var rising_jump := false
## What the last jump rose, taken off every height the fall is measured from.
var _jump_gain := 0.0
## How far the legs are pulled up in the air (a head-anchored crouch or tuck):
## the feet rose that much without the body rising, so a fall does not count it.
var _tuck := 0.0
## Eye height changes the camera must take at once rather than ease: a crouch in
## the air keeps the head where it is, so the eye's height over the feet jumps
## while the eye itself does not move. PlayerController takes it (take_eye_snap).
var _eye_snap := 0.0
var _placed := false
## How far the last landing dropped, for the probe.
var last_fall := 0.0


## A standing pawn with its feet at `feet`, under `parent`. Returns the pawn;
## its body is `pawn.body`.
static func spawn(parent: Node, at_feet: Vector3, p_team := 0, with_health := true,
		max_health := 100.0) -> Pawn:
	var b := CharacterBody3D.new()
	b.name = "PawnBody"
	b.collision_layer = Layers.PAWN
	b.collision_mask = Layers.PAWN_MASK
	b.floor_max_angle = deg_to_rad(50.0)
	b.floor_snap_length = STEP_HEIGHT
	b.slide_on_ceiling = true
	var shape := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.height = BODY_HEIGHT
	capsule.radius = BODY_RADIUS
	shape.shape = capsule
	b.add_child(shape)
	var p := Pawn.new()
	p.name = "Pawn"
	p.team = p_team
	p._capsule = capsule
	b.add_child(p)
	var e := Node3D.new()
	e.name = "Eye"
	e.position = Vector3.UP * (BODY_HEIGHT * 0.5 - HEAD_HEIGHT * 0.5)
	b.add_child(e)
	p.eye = e
	if with_health:
		var pool := HealthPool.new()
		pool.name = "HealthPool"
		var layer := DefenseLayer.new()
		layer.max_value = max_health
		pool.layer_configs = [layer]
		b.add_child(pool)
		p.health = pool
	parent.add_child(b)
	p.place(at_feet)
	return p


func _ready() -> void:
	body = get_parent() as CharacterBody3D
	if _capsule == null and body != null:
		for c in body.get_children():
			if c is CollisionShape3D and (c as CollisionShape3D).shape is CapsuleShape3D:
				_capsule = (c as CollisionShape3D).shape
				_height = _capsule.height
				break


## Put the feet here, still. A teleport: interpolation is told so, or it would
## blend the body in from wherever it was.
func place(at_feet: Vector3) -> void:
	if body == null:
		body = get_parent() as CharacterBody3D
	# Put here, not fallen here: the drop to the first floor below is free.
	_placed = true
	# Before the tree is running (a probe's _init) there is no global transform
	# yet; the parent is then taken to sit at the origin.
	if body.is_inside_tree():
		body.global_position = at_feet + Vector3.UP * _height * 0.5
	else:
		body.position = at_feet + Vector3.UP * _height * 0.5
	body.velocity = Vector3.ZERO
	body.reset_physics_interpolation()


## The middle of the body: what somebody aiming at this pawn aims at.
func chest() -> Vector3:
	# Six tenths of the way up, standing or crouched.
	return feet() + Vector3.UP * _height * 0.62


func feet() -> Vector3:
	return body.global_position - Vector3.UP * _height * 0.5


## Body centre (a capsule's origin) up to the eye: the middle of the head,
## whatever height the body is -- EYE_HEIGHT above the feet standing, a brick
## lower crouched. (The debug walker put it a plate below the crown, 1.54 m, and
## its own gate, which expects EYE_HEIGHT, has failed on that since the figure was
## resized.)
func eye_offset() -> float:
	return _height * 0.5 - HEAD_HEIGHT * 0.5


## Where the eye is between physics ticks -- what a camera should follow, since
## the body moves 30 times a second under a faster picture.
func eye_interpolated() -> Vector3:
	return body.get_global_transform_interpolated().origin + Vector3.UP * eye_offset()


## The feet between physics ticks, at the body's present height.
func feet_interpolated() -> Vector3:
	return body.get_global_transform_interpolated().origin - Vector3.UP * _height * 0.5


## Feet up to the eye: EYE_HEIGHT standing, a brick less crouched.
func eye_height() -> float:
	return _height - HEAD_HEIGHT * 0.5


func is_crouched() -> bool:
	return _height < BODY_HEIGHT


## Crouching nobody asked for: the ceiling did it.
func is_auto_crouched() -> bool:
	return _auto_crouched


func is_on_floor() -> bool:
	return body != null and body.is_on_floor()


func _physics_process(delta: float) -> void:
	if body == null or not body.is_inside_tree():
		return
	step(delta)
	if eye != null:
		eye.position = Vector3.UP * eye_offset()
		eye.rotation = Vector3(intents.look_pitch, intents.look_yaw, 0.0)
	if gun != null:
		gun.set_trigger(intents.fire)
		if intents.reload:
			gun.reload()
	intents.reload = false


## One tick of movement from `intents`.
func step(delta: float) -> void:
	var wish := Vector3(intents.move.x, 0.0, intents.move.z)
	if wish.length() > 1.0:
		wish = wish.normalized()

	# Stand if there is room to, crouch if there is not, and let the brain ask
	# for it either way. The test is along the motion rather than in place, so
	# walking at a beam ducks under it instead of stopping dead in front of it.
	var probe := wish * WALK_SPEED * delta
	# A mantle owns the body's height from start to finish: it chose the height
	# that fits where it is going, and a stand-up half way would move the body.
	if moves == null or not moves.owns_height():
		_auto_crouched = false
		var low_h := CROUCH_HEIGHT if intents.crouch and not no_crouch else 0.0
		if moves != null and moves.low_height() > 0.0:
			low_h = moves.low_height() if low_h == 0.0 else minf(low_h, moves.low_height())
		# In the air a crouch pulls the legs up and keeps the head where it is: what
		# a body tucking through a window does, and the view does not drop.
		var top := moves != null and not body.is_on_floor()
		if low_h > 0.0:
			_set_height(low_h, top)
		elif _fits(BODY_HEIGHT, probe, top):
			_set_height(BODY_HEIGHT, top)
		elif _fits(CROUCH_HEIGHT, probe, top):
			_set_height(CROUCH_HEIGHT, top)
			_auto_crouched = true

	var speed := WALK_SPEED
	if is_crouched():
		speed = CROUCH_SPEED
	elif intents.aim:
		speed = AIM_SPEED
	elif intents.run:
		speed = RUN_SPEED

	if moves != null:
		moves.step(delta, wish, speed)
	else:
		_walk(delta, wish, speed)
	_track_fall()


## The plain walk: the velocity is the wish, every tick -- no momentum, which is
## what a soldier on a path wants.
func _walk(delta: float, wish: Vector3, speed: float) -> void:
	if intents.jump:
		intents.jump = false
		if body.is_on_floor():
			body.velocity.y = JUMP_SPEED

	var before := body.global_position
	body.velocity.x = wish.x * speed + shove.x
	body.velocity.z = wish.z * speed + shove.z
	if shove.y > 0.0 and body.velocity.y < shove.y:
		body.velocity.y = shove.y
	elif body.is_on_floor() and body.velocity.y <= 0.0:
		body.velocity.y = 0.0
	else:
		body.velocity.y -= GRAVITY * delta
	shove *= exp(-SHOVE_DECAY * delta)
	body.move_and_slide()

	# Stopped dead by something low -- a kerb of rubble, a course of brick, the lip
	# of a floor slab. Step over it rather than making anybody jump.
	if wish != Vector3.ZERO and body.is_on_wall():
		var wanted := wish * speed * delta
		var moved := body.global_position - before
		if Vector2(moved.x, moved.z).length() < Vector2(wanted.x, wanted.z).length() * 0.5:
			_step_over(wanted)


## Where a fall started and what landing from it costs.
func _track_fall() -> void:
	var on_floor := body.is_on_floor()
	# Where a fall started: the highest the feet were since they left a floor.
	var feet_y := feet().y
	if on_floor and _was_on_floor:
		_placed = false   # placed standing: the next fall is a real one
	if _was_on_floor and not on_floor:
		_fall_from = feet_y
		_jump_gain = 0.0
	elif not on_floor:
		if rising_jump and body.velocity.y > 0.0:
			_jump_gain = maxf(_jump_gain, feet_y - _fall_from)
		else:
			_fall_from = maxf(_fall_from, feet_y - _jump_gain)
	if on_floor or body.velocity.y <= 0.0:
		rising_jump = false
	if on_floor and not _was_on_floor:
		# Landed with the legs pulled up: they reach the ground that much higher
		# than they would have hanging down.
		var drop := _fall_from - feet_y - _tuck
		last_fall = drop
		# A storey is 2.66 m and the AI may now choose to drop one (AINav
		# MAX_DROP): it lands hurt, not dead. A jump off a roof does not.
		var placed := _placed
		_placed = false
		if drop > SAFE_FALL and not placed and health != null and not health.is_dead():
			var packet := DamagePacket.new((drop - SAFE_FALL) * FALL_DAMAGE, null, null)
			packet.hit_position = feet()
			DamageSystem.resolve(packet, health)
		landed.emit()
	if on_floor:
		_tuck = 0.0
	_was_on_floor = on_floor


## What the camera must add to its eye height at once (see _eye_snap).
func take_eye_snap() -> float:
	var s := _eye_snap
	_eye_snap = 0.0
	return s


## Resize the capsule with the FEET planted. A capsule grows about its centre, so
## changing the height alone would sink the body into the floor or lift it off.
##
## `from_top`: keep the HEAD where it is instead -- the legs pull up or drop down.
## For the air, where there is no floor to plant on. The feet move by the change;
## the fall does not count it, and the eye (which hangs from the head) stays put.
func _set_height(h: float, from_top := false) -> void:
	if is_equal_approx(h, _height) or _capsule == null:
		return
	var delta := h - _height
	_height = h
	_capsule.height = h
	if from_top:
		body.global_position.y -= delta * 0.5
		_tuck = maxf(_tuck - delta, 0.0)
		_fall_from -= delta
		_eye_snap += delta
	else:
		body.global_position.y += delta * 0.5


## Would the body fit at `h` if it moved by `motion`? The capsule has to be the
## size being asked about, so it is resized, tested and put back.
func _fits(h: float, motion: Vector3, from_top := false) -> bool:
	if _capsule == null:
		return true
	var was := _height
	var xf := body.global_transform
	xf.origin.y += (h - was) * (-0.5 if from_top else 0.5)
	_capsule.height = h
	var blocked := body.test_move(xf, motion)
	_capsule.height = was
	return not blocked


## Raise, move, settle. Keeps the result only if the body came down on something
## -- otherwise that was a ledge to walk off, not a step to climb.
func _step_over(motion: Vector3) -> bool:
	var start := body.global_transform
	if body.test_move(start, Vector3.UP * STEP_HEIGHT):
		# No headroom to rise into. Crouching is what makes a step up onto a brick
		# possible under a low ceiling, so try it before giving up.
		if _height <= CROUCH_HEIGHT or not _fits(CROUCH_HEIGHT, Vector3.UP * STEP_HEIGHT):
			return false
		_set_height(CROUCH_HEIGHT)
		_auto_crouched = true
		start = body.global_transform
		if body.test_move(start, Vector3.UP * STEP_HEIGHT):
			return false
	var lifted := start.translated(Vector3.UP * STEP_HEIGHT)
	if body.test_move(lifted, motion):
		return false
	body.global_transform = lifted.translated(motion)
	body.move_and_collide(Vector3.DOWN * (STEP_HEIGHT + 0.02))
	if body.global_position.y > start.origin.y + STEP_HEIGHT * 0.9:
		body.global_transform = start
		return false
	return true
