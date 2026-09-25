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

var _capsule: CapsuleShape3D
var _height := BODY_HEIGHT
var _auto_crouched := false
var _was_on_floor := true


## A standing pawn with its feet at `feet`, under `parent`. Returns the pawn;
## its body is `pawn.body`.
static func spawn(parent: Node, feet: Vector3, p_team := 0, with_health := true,
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
	if with_health:
		var pool := HealthPool.new()
		pool.name = "HealthPool"
		var layer := DefenseLayer.new()
		layer.max_value = max_health
		pool.layer_configs = [layer]
		b.add_child(pool)
		p.health = pool
	parent.add_child(b)
	p.place(feet)
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
func place(feet: Vector3) -> void:
	if body == null:
		body = get_parent() as CharacterBody3D
	# Before the tree is running (a probe's _init) there is no global transform
	# yet; the parent is then taken to sit at the origin.
	if body.is_inside_tree():
		body.global_position = feet + Vector3.UP * _height * 0.5
	else:
		body.position = feet + Vector3.UP * _height * 0.5
	body.velocity = Vector3.ZERO
	body.reset_physics_interpolation()


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
	_auto_crouched = false
	if intents.crouch:
		_set_height(CROUCH_HEIGHT)
	elif _fits(BODY_HEIGHT, probe):
		_set_height(BODY_HEIGHT)
	elif _fits(CROUCH_HEIGHT, probe):
		_set_height(CROUCH_HEIGHT)
		_auto_crouched = true

	var speed := WALK_SPEED
	if is_crouched():
		speed = CROUCH_SPEED
	elif intents.run:
		speed = RUN_SPEED

	if intents.jump:
		intents.jump = false
		if body.is_on_floor():
			body.velocity.y = JUMP_SPEED

	var before := body.global_position
	body.velocity.x = wish.x * speed
	body.velocity.z = wish.z * speed
	if body.is_on_floor() and body.velocity.y <= 0.0:
		body.velocity.y = 0.0
	else:
		body.velocity.y -= GRAVITY * delta
	body.move_and_slide()

	# Stopped dead by something low -- a kerb of rubble, a course of brick, the lip
	# of a floor slab. Step over it rather than making anybody jump.
	if wish != Vector3.ZERO and body.is_on_wall():
		var wanted := wish * speed * delta
		var moved := body.global_position - before
		if Vector2(moved.x, moved.z).length() < Vector2(wanted.x, wanted.z).length() * 0.5:
			_step_over(wanted)

	var on_floor := body.is_on_floor()
	if on_floor and not _was_on_floor:
		landed.emit()
	_was_on_floor = on_floor


## Resize the capsule with the FEET planted. A capsule grows about its centre, so
## changing the height alone would sink the body into the floor or lift it off.
func _set_height(h: float) -> void:
	if is_equal_approx(h, _height) or _capsule == null:
		return
	var delta := h - _height
	_height = h
	_capsule.height = h
	body.global_position.y += delta * 0.5


## Would the body fit at `h` if it moved by `motion`? The capsule has to be the
## size being asked about, so it is resized, tested and put back.
func _fits(h: float, motion: Vector3) -> bool:
	if _capsule == null:
		return true
	var was := _height
	var xf := body.global_transform
	xf.origin.y += (h - was) * 0.5
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
