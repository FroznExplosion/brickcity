class_name PawnMoves
extends RefCounted
## The player's movement, on top of the pawn's walk: momentum, a slide, a wall-run
## and wall-jump, a mantle up onto anything within reach, and a grapple line.
##
## Taken from Ceramic Edge's PlayerMovement (Docs/Reference/ceramicedge.md section
## 2) and cut to a one-gun FPS: no dash, no air-slide, no slow motion, no ledge
## hang or shimmy -- and no wall-stick, which only made sense for a player whose
## hands were full. What stays is the Titanfall core: the moves carry speed into
## each other (slide -> jump -> wall-run -> wall-jump -> grapple), and each asks
## "does the body fit where this puts it?" before it commits.
##
## Still a motor: it reads PawnIntents and nothing else, so a brain that asks for
## the same keys gets the same moves. Pawn.moves is null for a soldier, whose
## plain walk (Pawn._walk) is left exactly as it was.
##
## Lengths come from the figure, not from a human: Ceramic Edge's 1.8 m operative
## sprinted at 11 m/s; this one is four bricks tall and runs 13.3 courses a second,
## so every speed here is a multiple of the pawn's own.

enum State { WALK, SLIDE, WALL_RUN, MANTLE, GRAPPLE }

## Ground: how fast the legs get to the asked speed, and stop without asking.
const GROUND_ACCEL := 40.0
const GROUND_FRICTION := 32.0
## Air: Quake-style -- input adds speed up to the walk's, and never takes away
## speed already built above it, so a wall-jump or a grapple keeps its flight.
const AIR_ACCEL := 16.0
## Above this, a long flight bleeds speed slowly back towards a run.
const AIR_DRAG := 2.0
## The player's jump, in bricks of clearance for the feet: a tap clears two, a
## jump held to the top clears four. It launches for four; letting go on the way
## up cuts the rise to what is left of two -- so a tap costs no wait, unlike a
## charged jump that fires on release. A soldier's jump is Pawn.JUMP_SPEED, one
## course: the nav is built around it.
const JUMP_LOW := Pawn.BRICK_M * 2.0
const JUMP_HIGH := Pawn.BRICK_M * 4.0
## Forgiveness: a jump pressed a moment before landing still happens, and one
## pressed a moment after running off an edge does too.
const JUMP_BUFFER := 0.15
const COYOTE := 0.12

## Slide: crouch while running fast. A boost to at least SLIDE_SPEED, a short
## free glide, then friction; jump out of it keeps the speed.
const SLIDE_ENTRY := Pawn.RUN_SPEED * 0.8
const SLIDE_SPEED := Pawn.RUN_SPEED * 1.3
const SLIDE_FREE := 0.35
const SLIDE_FRICTION := 5.0
const SLIDE_END := Pawn.CROUCH_SPEED + 0.4
const SLIDE_STEER := 6.0
## No boosting by tapping crouch: the next slide's boost waits this long.
const SLIDE_COOLDOWN := 0.8

## Wall-run: airborne, moving along a wall at more than a walk and asking to.
const WALL_RUN_MIN := Pawn.WALK_SPEED * 1.1
const WALL_RUN_SPEED := Pawn.RUN_SPEED * 1.15
const WALL_RUN_TIME := 1.6
## Level for this long, then sagging at a fraction of gravity.
const WALL_RUN_FREE := 0.6
const WALL_RUN_SAG := 0.3
## Onto the wall with a lift, easing to level: the run is above the heads of
## anyone in the street, not at their knees.
const WALL_RUN_LIFT := 3.0
const WALL_RUN_LEVEL := 10.0
## From the capsule's surface to where a wall still counts as beside you.
const WALL_REACH := 0.3
## Push off a wall-jump gets at the least, and the lift.
const WALL_JUMP_PUSH := 3.5
const WALL_JUMP_UP := Pawn.JUMP_SPEED * 1.15
## Each wall-jump before landing is worth a little more speed.
const WALL_CHAIN_BOOST := 0.06
const WALL_CHAIN_MAX := 5
## A wall facing the same way as the last one is the same wall.
const SAME_WALL := 0.8
const WALL_COOLDOWN := 0.25

## Mantle: a ledge up to a body and an arm above the feet is climbed. On the
## ground by jumping at it; in the air by pushing into it.
const MANTLE_REACH := Pawn.BODY_HEIGHT + 0.45
const MANTLE_TIME_MIN := 0.22
const MANTLE_TIME_MAX := 0.42

## Grapple: a line to whatever solid thing the eye is on, reeled in.
const GRAPPLE_RANGE := 32.0
const GRAPPLE_ACCEL := 36.0
const GRAPPLE_MAX_SPEED := 17.0
const GRAPPLE_GRAVITY := 0.4
const GRAPPLE_STEER := 6.0
const GRAPPLE_MAX_TIME := 2.2
const GRAPPLE_ARRIVE := 1.3
## Let go, and the next line waits this long. A miss costs less.
const GRAPPLE_COOLDOWN := 3.0
const GRAPPLE_MISS_COOLDOWN := 0.5
const GRAPPLE_RELEASE_BOOST := 3.5

signal slid
signal wall_jumped
signal mantled
## The line bit at `point`; and was let go.
signal grappled(point: Vector3)
signal grapple_released

var pawn: Pawn
var state := State.WALK
## The wall being run: its outward normal.
var wall_normal := Vector3.ZERO
## Where the line is hooked, while grappling.
var hook := Vector3.ZERO

var _buffer := 0.0
## Feet height at take-off, while a jump can still be cut short.
var _jump_from := NAN
var _coyote := 0.0
var _air_time := 0.0
var _slide_t := 0.0
var _slide_air := 0.0
var _slide_cd := 0.0
var _crouch_was := false
var _was_on_floor := true
var _wall_t := 0.0
var _wall_cd := 0.0
var _wall_idle := 0.0
var _last_wall := Vector3.ZERO
var _chain := 0
var _m_from := Vector3.ZERO
var _m_mid := Vector3.ZERO
var _m_to := Vector3.ZERO
var _m_t := 0.0
var _m_dur := 0.3
var _m_exit := Vector3.ZERO
var _m_low := false
var _grapple_was := false
var _grapple_cd := 0.0
var _g_t := 0.0
var _g_rope := 0.0
var _g_stall := 0.0
var _g_last := Vector3.ZERO
var _g_collider_id := 0


func _init(p: Pawn) -> void:
	pawn = p


## The height is the mantle's for the whole of it (Pawn.step).
func owns_height() -> bool:
	return state == State.MANTLE


## Stay crouched whether or not crouch is held.
func keeps_low() -> bool:
	return state == State.SLIDE


func is_sliding() -> bool:
	return state == State.SLIDE


func is_wall_running() -> bool:
	return state == State.WALL_RUN


func is_mantling() -> bool:
	return state == State.MANTLE


func is_grappling() -> bool:
	return state == State.GRAPPLE


## 0 when the line is ready, 1 just after it was used.
func grapple_cooldown() -> float:
	return clampf(_grapple_cd / GRAPPLE_COOLDOWN, 0.0, 1.0)


## One tick. `wish` is the move asked for (world, horizontal, length <= 1) and
## `speed` what the pawn's gait allows for it.
func step(delta: float, wish: Vector3, speed: float) -> void:
	var b := pawn.body
	var it := pawn.intents
	_buffer = maxf(_buffer - delta, 0.0)
	_coyote = maxf(_coyote - delta, 0.0)
	_slide_cd = maxf(_slide_cd - delta, 0.0)
	_wall_cd = maxf(_wall_cd - delta, 0.0)
	_grapple_cd = maxf(_grapple_cd - delta, 0.0)
	if it.jump:
		it.jump = false
		_buffer = JUMP_BUFFER
	var crouch_edge := it.crouch and not _crouch_was
	_crouch_was = it.crouch
	var grapple_edge := it.grapple and not _grapple_was
	_grapple_was = it.grapple

	var on_floor := b.is_on_floor()
	if on_floor:
		_coyote = COYOTE
		_air_time = 0.0
		_chain = 0
		_last_wall = Vector3.ZERO
	else:
		_air_time += delta
	var landed := on_floor and not _was_on_floor
	_cut_jump()
	_was_on_floor = on_floor

	if state == State.MANTLE:
		_mantle_tick(delta)
		return
	if grapple_edge and state != State.GRAPPLE:
		_try_grapple()

	match state:
		State.GRAPPLE:
			_grapple_tick(delta, wish)
		State.WALL_RUN:
			_wall_run_tick(delta, wish)
		State.SLIDE:
			_slide_tick(delta, wish)
		_:
			# Crouch while running fast, or land fast with it held: a slide.
			if on_floor and it.crouch and (crouch_edge or landed) and _slide_cd <= 0.0 \
					and _hspeed() >= SLIDE_ENTRY:
				_start_slide()
				_slide_tick(delta, wish)
			elif not _walk_tick(delta, wish, speed, on_floor):
				return
	if state == State.MANTLE:
		return
	_move(delta, wish, speed)


# --- walk and air -------------------------------------------------------------

## Returns false when it started a mantle, which moves the body itself.
func _walk_tick(delta: float, wish: Vector3, speed: float, on_floor: bool) -> bool:
	var b := pawn.body
	if _buffer > 0.0:
		if _try_mantle(wish, true):
			return false
		if on_floor or _coyote > 0.0:
			_buffer = 0.0
			_coyote = 0.0
			_jump(b.global_position.y)
			on_floor = false
	var h := Vector3(b.velocity.x, 0.0, b.velocity.z)
	if on_floor:
		var rate := GROUND_ACCEL if wish != Vector3.ZERO else GROUND_FRICTION
		h = h.move_toward(wish * speed, rate * delta)
		if b.velocity.y <= 0.0:
			b.velocity.y = 0.0
	else:
		if wish != Vector3.ZERO:
			var add := maxf(speed, Pawn.WALK_SPEED) - h.dot(wish)
			if add > 0.0:
				h += wish * minf(AIR_ACCEL * delta, add)
		var hs := h.length()
		if _air_time > 0.5 and hs > Pawn.RUN_SPEED * 1.2:
			h = h * (maxf(hs - AIR_DRAG * delta, Pawn.RUN_SPEED * 1.2) / hs)
		b.velocity.y -= Pawn.GRAVITY * delta
	b.velocity.x = h.x
	b.velocity.z = h.z
	if not on_floor:
		# Falling, not rising hard: reach for a ledge, or run the wall beside you.
		if b.velocity.y < 2.0 and _try_mantle(wish, false):
			return false
		_try_wall_run(wish)
	return true


## Up at the full jump; `from` is the body's height at take-off.
func _jump(from: float) -> void:
	pawn.body.velocity.y = rise_speed(JUMP_HIGH)
	pawn.rising_jump = true
	_jump_from = from


## Let go of the button on the way up: no higher than the low jump. The speed
## left is exactly what reaches JUMP_LOW over take-off.
func _cut_jump() -> void:
	if is_nan(_jump_from):
		return
	var b := pawn.body
	if b.velocity.y <= 0.0 or state != State.WALK:
		_jump_from = NAN
		return
	if pawn.intents.jump_held:
		return
	var left := maxf(JUMP_LOW - (b.global_position.y - _jump_from), 0.0)
	b.velocity.y = minf(b.velocity.y, rise_speed(left))
	_jump_from = NAN


## The upward speed that rises exactly `h` on this physics tick: v^2 = 2 g h,
## less what the step loses -- gravity comes off before each move, which costs
## v * dt / 2 of height (0.14 m of a four-brick jump at 30 Hz).
static func rise_speed(h: float) -> float:
	if h <= 0.0:
		return 0.0
	var gdt := Pawn.GRAVITY / float(Engine.physics_ticks_per_second)
	return gdt * 0.5 + sqrt(gdt * gdt * 0.25 + 2.0 * Pawn.GRAVITY * h)


## move_and_slide with the wind added for this tick only (it is a push, not
## momentum), then the kerb step when a walk was stopped dead by something low.
func _move(delta: float, wish: Vector3, speed: float) -> void:
	var b := pawn.body
	var shove := pawn.shove
	var push := Vector3(shove.x, 0.0, shove.z)
	if shove.y > 0.0 and b.velocity.y < shove.y:
		b.velocity.y = shove.y
	pawn.shove *= exp(-Pawn.SHOVE_DECAY * delta)
	var before := b.global_position
	b.velocity += push
	b.move_and_slide()
	b.velocity -= push
	if state == State.WALK and b.is_on_floor() and wish != Vector3.ZERO and b.is_on_wall():
		var wanted := wish * speed * delta
		var moved := b.global_position - before
		if Vector2(moved.x, moved.z).length() < Vector2(wanted.x, wanted.z).length() * 0.5:
			pawn._step_over(wanted)


# --- slide --------------------------------------------------------------------

func _start_slide() -> void:
	var b := pawn.body
	var h := Vector3(b.velocity.x, 0.0, b.velocity.z)
	var hs := h.length()
	if hs < 0.01:
		return
	h = h / hs * maxf(hs, SLIDE_SPEED)
	b.velocity.x = h.x
	b.velocity.z = h.z
	state = State.SLIDE
	_slide_t = 0.0
	_slide_air = 0.0
	_slide_cd = SLIDE_COOLDOWN
	slid.emit()


func _slide_tick(delta: float, wish: Vector3) -> void:
	var b := pawn.body
	var it := pawn.intents
	_slide_t += delta
	var h := Vector3(b.velocity.x, 0.0, b.velocity.z)
	var hs := h.length()
	if b.is_on_floor():
		_slide_air = 0.0
		if b.velocity.y <= 0.0:
			b.velocity.y = 0.0
	else:
		_slide_air += delta
		b.velocity.y -= Pawn.GRAVITY * delta
	# Off the end of something: fly on with the speed. Let go of crouch, or slow
	# to a crawl: stand up (Pawn does, if there is room).
	if _slide_air > COYOTE or not it.crouch or hs < SLIDE_END:
		state = State.WALK
		return
	if _buffer > 0.0:
		_buffer = 0.0
		_jump(b.global_position.y)
		state = State.WALK
		return
	if wish != Vector3.ZERO:
		h = h.move_toward(wish * hs, SLIDE_STEER * delta)
		hs = h.length()
	if _slide_t > SLIDE_FREE:
		var slowed := maxf(hs - SLIDE_FRICTION * delta, 0.0)
		h = h * (slowed / maxf(hs, 0.001))
	b.velocity.x = h.x
	b.velocity.z = h.z


# --- wall-run -----------------------------------------------------------------

func _try_wall_run(wish: Vector3) -> bool:
	var b := pawn.body
	if _wall_cd > 0.0 or b.is_on_floor():
		return false
	var h := Vector3(b.velocity.x, 0.0, b.velocity.z)
	if h.length() < WALL_RUN_MIN or b.velocity.y < -6.0:
		return false
	var along := h.normalized()
	# Asked for: the move is pushing along the flight, not coasting past a wall.
	if wish.dot(along) < 0.3:
		return false
	var side := along.cross(Vector3.UP)
	for s in [side, -side]:
		var hit := _ray(_chest(), _chest() + (s as Vector3) * (Pawn.BODY_RADIUS + WALL_REACH))
		if hit.is_empty():
			continue
		var n: Vector3 = hit.normal
		if absf(n.y) > 0.3:
			continue
		n = Vector3(n.x, 0.0, n.z).normalized()
		if _last_wall != Vector3.ZERO and n.dot(_last_wall) > SAME_WALL:
			continue
		state = State.WALL_RUN
		pawn.rising_jump = false
		wall_normal = n
		_wall_t = 0.0
		_wall_idle = 0.0
		b.velocity.y = maxf(b.velocity.y, WALL_RUN_LIFT)
		return true
	return false


func _wall_run_tick(delta: float, wish: Vector3) -> void:
	var b := pawn.body
	var it := pawn.intents
	_wall_t += delta
	var reach := Pawn.BODY_RADIUS + WALL_REACH + 0.1
	var hit := _ray(_chest(), _chest() - wall_normal * reach)
	if b.is_on_floor() or _wall_t > WALL_RUN_TIME or hit.is_empty() or it.crouch:
		_leave_wall()
		if it.crouch:
			b.velocity += wall_normal * 1.5
		return
	if _buffer > 0.0:
		_buffer = 0.0
		_wall_jump()
		return
	var along := wall_normal.cross(Vector3.UP).normalized()
	var h := Vector3(b.velocity.x, 0.0, b.velocity.z)
	if h.dot(along) < 0.0:
		along = -along
	# Let go of the stick and the run ends; push along it and it holds its pace.
	_wall_idle = _wall_idle + delta if wish.dot(along) < 0.2 else 0.0
	if _wall_idle > 0.2:
		_leave_wall()
		return
	var cur := h.dot(along)
	cur = move_toward(cur, maxf(WALL_RUN_SPEED, cur - 1.5 * delta), 10.0 * delta)
	b.velocity.x = along.x * cur
	b.velocity.z = along.z * cur
	# Pressed against it, so move_and_slide keeps the contact.
	b.velocity -= wall_normal * 1.5
	if _wall_t < WALL_RUN_FREE:
		b.velocity.y = move_toward(b.velocity.y, 0.0, WALL_RUN_LEVEL * delta)
	else:
		b.velocity.y = maxf(b.velocity.y - Pawn.GRAVITY * WALL_RUN_SAG * delta, -6.0)


func _leave_wall() -> void:
	state = State.WALK
	_last_wall = wall_normal
	_wall_cd = WALL_COOLDOWN


## Off the wall the way the eye looks, never back into it, and a little faster for
## each jump in the chain.
func _wall_jump() -> void:
	var b := pawn.body
	_chain = mini(_chain + 1, WALL_CHAIN_MAX)
	var look := _look_flat()
	if look.dot(wall_normal) < -0.2:
		look = (look - wall_normal * look.dot(wall_normal)).normalized()
	if look == Vector3.ZERO:
		look = wall_normal
	var hs := maxf(Pawn.RUN_SPEED * 1.1, _hspeed()) * (1.0 + WALL_CHAIN_BOOST * _chain)
	var v := look * hs
	var push := v.dot(wall_normal)
	if push < WALL_JUMP_PUSH:
		v += wall_normal * (WALL_JUMP_PUSH - push)
	v.y = WALL_JUMP_UP
	b.velocity = v
	_leave_wall()
	wall_jumped.emit()


# --- mantle -------------------------------------------------------------------

## A ledge ahead within reach: climb it. `jumped` is a jump pressed at it (the
## ground or the air); otherwise it is the air's reach while pushing into a wall.
func _try_mantle(wish: Vector3, jumped: bool) -> bool:
	var b := pawn.body
	var fwd := wish.normalized() if wish != Vector3.ZERO else _look_flat()
	if fwd == Vector3.ZERO or (not jumped and wish == Vector3.ZERO):
		return false
	var feet := pawn.feet()
	# Just over a kerb: anything taller than a step is found at this height.
	var low := feet + Vector3.UP * (Pawn.STEP_HEIGHT + 0.05)
	var face := _ray(low, low + fwd * (Pawn.BODY_RADIUS + 0.45))
	if face.is_empty():
		# Nothing at the knees: in the air it may be a lip at the chest.
		face = _ray(_chest(), _chest() + fwd * (Pawn.BODY_RADIUS + 0.45))
		if face.is_empty():
			return false
	var n: Vector3 = face.normal
	if absf(n.y) > 0.4:
		return false
	n = Vector3(n.x, 0.0, n.z).normalized()
	if fwd.dot(-n) < 0.5:
		return false
	var into := -n
	# A body-width in from the face, look down for the top.
	var over: Vector3 = face.position + into * (Pawn.BODY_RADIUS + 0.06)
	var top_from := Vector3(over.x, feet.y + MANTLE_REACH + 0.05, over.z)
	var top := _ray(top_from, Vector3(over.x, feet.y + Pawn.STEP_HEIGHT * 0.5, over.z))
	if top.is_empty() or (top.normal as Vector3).y < 0.7:
		return false
	var top_y: float = top.position.y
	var rise := top_y - feet.y
	if rise < Pawn.STEP_HEIGHT * 0.8 or rise > MANTLE_REACH:
		return false
	# What fits on top: standing, or crouched under something low.
	var land_feet := Vector3(over.x, top_y + 0.02, over.z)
	var h := Pawn.BODY_HEIGHT
	if not _fits_at(land_feet, h):
		h = Pawn.CROUCH_HEIGHT
		if not _fits_at(land_feet, h):
			return false
	# The path is an L: straight up in front of the face until the feet clear the
	# lip, then across onto the top. Never through the corner, so never through
	# the wall -- and each leg is swept with the body as it is.
	_m_low = h < Pawn.BODY_HEIGHT
	if _m_low and not pawn.is_crouched():
		pawn._set_height(Pawn.CROUCH_HEIGHT)
	var half := pawn._height * 0.5
	var start := b.global_position
	var mid := Vector3(start.x, top_y + 0.04 + half, start.z)
	var end := Vector3(land_feet.x, top_y + 0.04 + half, land_feet.z)
	var xf := b.global_transform
	if mid.y > start.y and b.test_move(xf, mid - start):
		return false
	xf.origin = mid
	if b.test_move(xf, end - mid):
		return false
	var hs := _hspeed()
	state = State.MANTLE
	pawn.rising_jump = false
	_m_from = start
	_m_mid = mid
	_m_to = end
	_m_t = 0.0
	_m_dur = clampf(0.16 + rise * 0.12, MANTLE_TIME_MIN, MANTLE_TIME_MAX)
	_m_exit = into * maxf(Pawn.WALK_SPEED, hs * 0.7)
	_buffer = 0.0
	mantled.emit()
	return true


## Along the L, eased, with the velocity it implies so the camera and the gun
## read it as motion.
func _mantle_tick(delta: float) -> void:
	var b := pawn.body
	_m_t += delta
	var k := clampf(_m_t / _m_dur, 0.0, 1.0)
	var up := _m_from.distance_to(_m_mid)
	var across := _m_mid.distance_to(_m_to)
	var split := up / maxf(up + across, 0.001)
	var pos: Vector3
	if k < split:
		pos = _m_from.lerp(_m_mid, _ease(k / maxf(split, 0.001)))
	else:
		pos = _m_mid.lerp(_m_to, _ease((k - split) / maxf(1.0 - split, 0.001)))
	b.velocity = (pos - b.global_position) / maxf(delta, 0.001)
	b.global_position = pos
	if k >= 1.0:
		state = State.WALK
		b.velocity = _m_exit
		b.move_and_slide()


static func _ease(t: float) -> float:
	return t * t * (3.0 - 2.0 * t)


# --- grapple ------------------------------------------------------------------

func _try_grapple() -> void:
	if _grapple_cd > 0.0 or pawn.eye == null:
		return
	var from := pawn.eye.global_position
	var dir := -pawn.eye.global_transform.basis.z
	var hit := _ray(from, from + dir * GRAPPLE_RANGE, Layers.HITSCAN_MASK)
	if hit.is_empty():
		_grapple_cd = GRAPPLE_MISS_COOLDOWN
		return
	if state == State.WALL_RUN:
		_leave_wall()
	hook = hit.position
	_g_collider_id = (hit.collider as Object).get_instance_id() if hit.collider != null else 0
	_g_t = 0.0
	_g_stall = 0.0
	_g_rope = _chest().distance_to(hook)
	_g_last = pawn.body.global_position
	state = State.GRAPPLE
	pawn.rising_jump = false
	pawn.body.velocity.y = maxf(pawn.body.velocity.y, 1.5)
	grappled.emit(hook)


func _grapple_tick(delta: float, wish: Vector3) -> void:
	var b := pawn.body
	_g_t += delta
	var to := hook - _chest()
	var d := to.length()
	# Let go: the button, a jump (with a kick up), arriving, time, being stuck, or
	# the thing it was hooked to going away.
	if not pawn.intents.grapple or _g_t > GRAPPLE_MAX_TIME or _hook_gone():
		_release_grapple()
		return
	if _buffer > 0.0:
		_buffer = 0.0
		b.velocity.y = maxf(b.velocity.y, 0.0) + GRAPPLE_RELEASE_BOOST
		_release_grapple()
		return
	if d < GRAPPLE_ARRIVE:
		var fwd := to / maxf(d, 0.001)
		b.velocity = Vector3(fwd.x, 0.0, fwd.z) * 3.0 + Vector3.UP * 3.5
		_release_grapple()
		return
	var moved := b.global_position.distance_to(_g_last)
	_g_last = b.global_position
	if _g_t > 0.2 and moved < b.velocity.length() * delta * 0.2:
		_g_stall += delta
		if _g_stall > 0.35:
			_release_grapple()
			return
	else:
		_g_stall = 0.0
	var dir := to / d
	var v := b.velocity + dir * GRAPPLE_ACCEL * delta + wish * GRAPPLE_STEER * delta
	v.y -= Pawn.GRAVITY * GRAPPLE_GRAVITY * delta
	# The line only shortens: moving away from the hook is taken out of the motion.
	_g_rope = minf(_g_rope, d)
	var out := -v.dot(dir)
	if d > _g_rope + 0.05 and out > 0.0:
		v += dir * out
	if v.length() > GRAPPLE_MAX_SPEED:
		v = v.normalized() * GRAPPLE_MAX_SPEED
	b.velocity = v


func _hook_gone() -> bool:
	return _g_collider_id != 0 and not is_instance_id_valid(_g_collider_id)


func _release_grapple() -> void:
	state = State.WALK
	_grapple_cd = GRAPPLE_COOLDOWN
	grapple_released.emit()


# --- helpers ------------------------------------------------------------------

func _hspeed() -> float:
	return Vector2(pawn.body.velocity.x, pawn.body.velocity.z).length()


func _chest() -> Vector3:
	return pawn.feet() + Vector3.UP * pawn._height * 0.6


## Where the eye looks, flattened; the look yaw when the eye is straight down.
func _look_flat() -> Vector3:
	var yaw := pawn.intents.look_yaw
	return Vector3(-sin(yaw), 0.0, -cos(yaw))


func _ray(from: Vector3, to: Vector3, mask := Layers.PAWN_MASK) -> Dictionary:
	var q := PhysicsRayQueryParameters3D.create(from, to, mask, [pawn.body.get_rid()])
	return pawn.body.get_world_3d().direct_space_state.intersect_ray(q)


## Would a body `h` tall stand with its feet at `feet` without touching anything?
## A hair thinner than the real capsule, so resting on the top is not a touch.
func _fits_at(feet: Vector3, h: float) -> bool:
	var cap := CapsuleShape3D.new()
	cap.radius = Pawn.BODY_RADIUS - 0.03
	cap.height = h - 0.06
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = cap
	q.transform = Transform3D(Basis.IDENTITY, feet + Vector3.UP * (h * 0.5 + 0.03))
	q.collision_mask = Layers.PAWN_MASK
	q.exclude = [pawn.body.get_rid()]
	return pawn.body.get_world_3d().direct_space_state.intersect_shape(q, 1).is_empty()
