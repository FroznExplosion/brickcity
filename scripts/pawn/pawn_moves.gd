class_name PawnMoves
extends RefCounted
## The player's movement, on top of the pawn's walk: momentum, a slide, a wall-run
## and wall-jump, a mantle up onto anything within reach, and a grapple line.
##
## Taken from Ceramic Edge's PlayerMovement (Docs/Reference/ceramicedge.md section
## 2) and cut to a one-gun FPS: no dash, no air-slide, no slow motion. The moves
## carry speed into each other (slide -> jump -> wall-run -> wall-jump ->
## grapple), and each asks "does the body fit where this puts it?" before it
## commits:
##
##   ledge up to a body high   MANTLE straight over it
##   up to an arm above that   GRAB it and HANG: shimmy along the lip, round its
##                             corners, up or down to the next lip, climb, drop,
##                             leap off
##   a wall too tall for both  STICK to it when flying in, slide down it, jump off
##
## A climb -- mantle or pull-up -- sweeps the body where it will land: standing
## room climbs standing, only crouching room climbs DUCKED (crouched from the
## start, so the view never stands up into the ceiling), no room leaves the lip
## hang-only.
##
## Still a motor: it reads PawnIntents and nothing else, so a brain that asks for
## the same keys gets the same moves. Pawn.moves is null for a soldier, whose
## plain walk (Pawn._walk) is left exactly as it was.
##
## Lengths come from the figure, not from a human: Ceramic Edge's 1.8 m operative
## sprinted at 11 m/s; this one is four bricks tall and runs 13.3 courses a second,
## so every speed here is a multiple of the pawn's own.

enum State { WALK, SLIDE, WALL_RUN, MANTLE, GRAPPLE, HANG, WALL_STICK }

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

## Mantle: a ledge up to a body above the feet is climbed straight over. On the
## ground by jumping at it; in the air by pushing into it.
const MANTLE_REACH := Pawn.BODY_HEIGHT
const MANTLE_TIME_MIN := 0.22
const MANTLE_TIME_MAX := 0.42

## Ledge grab: higher than a mantle, up to fingertips on a raised arm.
const HANG_REACH := Pawn.BODY_HEIGHT + 0.75
## Hanging: the lip this far over the feet (hands over the head), the body this far
## out from the face (the view off the wall).
const HANG_DROP := Pawn.BODY_HEIGHT + 0.1
const HANG_DIST := Pawn.BODY_RADIUS + 0.15
const HANG_ENTER := 0.16
## Hang this long before pushing on climbs, so a jump into a ledge reads as a grab.
const HANG_MIN := 0.25
const SHIMMY_SPEED := 1.8
## A step up or down the wall to the next lip, and a corner wrap: eased, this long.
const HANG_STEP_TIME := 0.32
const HANG_CORNER_TIME := 0.28
## After letting go, the next grab waits this long (no re-grabbing what you left).
const LEDGE_COOLDOWN := 0.4
## Air over the lip for the fingers, and top behind it for the hand: a slab under
## a ceiling, or a knife edge, is not a ledge.
const LIP_AIR := 0.05
const LIP_DEPTH := 0.05
## Leaving the hang: leaping off the way you look, springing back off a lip you
## face but cannot climb.
const HANG_LEAP := 6.0
const HANG_BACK := 4.5

## Wall stick: fly into a wall too tall to climb and hold on; after a beat, slide
## down it; jump off any time. The harder you hit, the longer you hold.
const STICK_MIN_SPEED := 2.5
const STICK_FULL_SPEED := 8.0
const STICK_TIME_MIN := 0.35
const STICK_TIME_MAX := 1.2
const STICK_SLIDE_SPEED := 1.5
const STICK_SLIDE_TIME := 3.0
const STICK_STRAFE := 1.0
## Falling faster than this, the hands only scrape: the fall goes on.
const STICK_MAX_FALL := 12.0
const STICK_BACK_JUMP := 4.5

## Grapple: a line to whatever solid thing the eye is on, reeled in.
const GRAPPLE_RANGE := 32.0
const GRAPPLE_ACCEL := 36.0
const GRAPPLE_MAX_SPEED := 17.0
## On the line there is no gravity: it pulls straight, so it can be aimed through
## a window. And the legs come up to two bricks -- a window is three courses tall,
## exactly a crouching body, so a crouch alone would not fit through it.
const GRAPPLE_GRAVITY := 0.0
const GRAPPLE_TUCK := Pawn.BRICK_M * 2.0
## Tucked a moment longer after letting go, to carry through the opening.
const GRAPPLE_TUCK_AFTER := 0.3
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
signal grabbed
signal stuck
## The line bit at `point`; and was let go.
signal grappled(point: Vector3)
signal grapple_released

var pawn: Pawn
var state := State.WALK
## The wall being run: its outward normal.
var wall_normal := Vector3.ZERO
## Where the line is hooked, while grappling.
var hook := Vector3.ZERO
## The hang: the lip's outward normal, the face point under the hands, its top,
## and whether there is room to climb onto it.
var ledge_normal := Vector3.ZERO
var ledge_face := Vector3.ZERO
var ledge_top := 0.0
var ledge_climbable := false

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
var _tuck_left := 0.0
var _ledge_cd := 0.0
var _hang_t := 0.0
## An eased move of the hanging body (entering, a step, a corner): from, to, t, time.
var _h_from := Vector3.ZERO
var _h_to := Vector3.ZERO
var _h_t := 1.0
var _h_dur := 0.2
var _corner_cd := 0.0
var _climb_cd := 0.0
var _stick_t := 0.0
var _stick_dur := 0.5
var _stick_fast := false
var _stick_pos := Vector3.ZERO


func _init(p: Pawn) -> void:
	pawn = p


## The height is the climb's for the whole of it, and a hang's (Pawn.step).
func owns_height() -> bool:
	return state == State.MANTLE or state == State.HANG


## A height to hold whether or not crouch is held; 0 for none. A slide is a
## crouch; the grapple (and a moment after it) a tighter tuck.
func low_height() -> float:
	if state == State.GRAPPLE or (_tuck_left > 0.0 and not pawn.is_on_floor()):
		return GRAPPLE_TUCK
	if state == State.SLIDE:
		return Pawn.CROUCH_HEIGHT
	return 0.0


func is_hanging() -> bool:
	return state == State.HANG


func is_wall_sticking() -> bool:
	return state == State.WALL_STICK


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
	_tuck_left = maxf(_tuck_left - delta, 0.0)
	_ledge_cd = maxf(_ledge_cd - delta, 0.0)
	_corner_cd = maxf(_corner_cd - delta, 0.0)
	_climb_cd = maxf(_climb_cd - delta, 0.0)
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
	if state == State.HANG:
		_hang_tick(delta, wish, crouch_edge)
		return

	match state:
		State.WALL_STICK:
			_stick_tick(delta, wish)
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
	if state == State.MANTLE or state == State.HANG:
		return
	_move(delta, wish, speed)


# --- walk and air -------------------------------------------------------------

## Returns false when it started a mantle, which moves the body itself.
func _walk_tick(delta: float, wish: Vector3, speed: float, on_floor: bool) -> bool:
	var b := pawn.body
	if _buffer > 0.0:
		if _try_mantle(wish, true) or _try_grab(wish, true):
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
		# Falling, not rising hard: reach for a ledge, run the wall beside you, or
		# hold on to the one in front.
		if b.velocity.y < 2.0 and (_try_mantle(wish, false) or _try_grab(wish, false)):
			return false
		if not _try_wall_run(wish):
			_try_stick(wish)
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
	var _b := pawn.body
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
	return _climb(Vector3(over.x, top_y + 0.02, over.z), into,
			maxf(Pawn.WALK_SPEED, _hspeed() * 0.7))


## What stands on top at `feet`: the height of a body that fits there -- standing,
## else crouched -- or 0 when neither does.
func _fit_height(feet: Vector3) -> float:
	if _fits_at(feet, Pawn.BODY_HEIGHT):
		return Pawn.BODY_HEIGHT
	if _fits_at(feet, Pawn.CROUCH_HEIGHT):
		return Pawn.CROUCH_HEIGHT
	return 0.0


## Climb onto `land_feet`, leaving along `into` at `exit_speed`. Refused (false)
## when nothing fits there or the way up is blocked.
##
## The path is an L: straight up in front of the face until the feet clear the
## lip, then across onto the top. Never through the corner, so never through the
## wall -- and each leg is swept with the body as it will be. When only a crouch
## fits on top, the body crouches BEFORE it rises, so the view comes up under the
## ceiling rather than standing into it and ducking at the end.
func _climb(land_feet: Vector3, into: Vector3, exit_speed: float) -> bool:
	var b := pawn.body
	var h := _fit_height(land_feet)
	if h <= 0.0:
		return false
	var was_h := pawn._height
	var low := h < Pawn.BODY_HEIGHT
	if low and pawn._height > Pawn.CROUCH_HEIGHT:
		pawn._set_height(Pawn.CROUCH_HEIGHT)
	var half := pawn._height * 0.5
	var top_y := land_feet.y - 0.02
	var start := b.global_position
	var mid := Vector3(start.x, top_y + 0.04 + half, start.z)
	var end := Vector3(land_feet.x, top_y + 0.04 + half, land_feet.z)
	var xf := b.global_transform
	var blocked := mid.y > start.y and b.test_move(xf, mid - start)
	if not blocked:
		xf.origin = mid
		blocked = b.test_move(xf, end - mid)
	if blocked:
		if not is_equal_approx(pawn._height, was_h):
			pawn._set_height(was_h)
		return false
	state = State.MANTLE
	pawn.rising_jump = false
	_m_low = low
	_m_from = start
	_m_mid = mid
	_m_to = end
	_m_t = 0.0
	_m_dur = clampf(0.16 + (top_y - (start.y - half)) * 0.12, MANTLE_TIME_MIN, MANTLE_TIME_MAX)
	_m_exit = into * exit_speed
	_buffer = 0.0
	_ledge_cd = LEDGE_COOLDOWN
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


# --- ledge grab and hang ------------------------------------------------------

## A lip ahead, higher than a mantle and within an arm's reach: take it and hang.
## `jumped`: a jump pressed at it, which is intent enough; otherwise the move has
## to push at the wall, or the body be flying at it -- falling past a ledge with
## hands off does not grab it.
func _try_grab(wish: Vector3, jumped: bool) -> bool:
	if _ledge_cd > 0.0:
		return false
	var b := pawn.body
	var feet := pawn.feet()
	var hv := Vector3(b.velocity.x, 0.0, b.velocity.z)
	var dirs: Array[Vector3] = []
	if wish != Vector3.ZERO:
		dirs.append(wish.normalized())
	elif hv.length() > 0.5:
		dirs.append(hv.normalized())
	var look := _look_flat()
	if dirs.is_empty() or dirs[0].dot(look) < 0.85:
		dirs.append(look)
	for approach in dirs:
		if not jumped and wish.dot(approach) < 0.35 and hv.dot(approach) < 2.0:
			continue
		# Dense heights, so a single course of brick sticking out is not missed.
		for cast_h in [0.6, 0.9, 1.2, 1.5, 1.8, 2.1]:
			var o: Vector3 = feet + Vector3.UP * float(cast_h)
			var wall := _ray(o, o + approach * (Pawn.BODY_RADIUS + 0.55))
			if wall.is_empty() or absf((wall.normal as Vector3).y) > 0.4:
				continue
			var n := _flat(wall.normal)
			if n == Vector3.ZERO:
				continue
			var face: Vector3 = wall.position
			var top := _top_over(face, -n, feet.y + HANG_REACH + 0.3, feet.y + MANTLE_REACH * 0.75)
			if top.is_empty():
				continue
			var top_y: float = top.position.y
			var rise := top_y - feet.y
			if rise < MANTLE_REACH * 0.75 or rise > HANG_REACH:
				continue
			if not _lip_grippable(face, top_y, -n):
				continue
			var spot := _hang_spot(face, n, top_y)
			if spot == Vector3.INF:
				continue
			_start_hang(face, n, top_y, spot)
			return true
	return false


## Where the feet hang from a lip -- or INF when the body fits nowhere under it.
## Further out from the wall when something sticks out below the lip (a lower sill
## the body would otherwise be inside): the arms reach, the body hangs clear.
func _hang_spot(face: Vector3, n: Vector3, top_y: float) -> Vector3:
	for out in [0.0, 0.2, 0.4, 0.6]:
		var feet := Vector3(face.x, top_y - HANG_DROP, face.z) + n * (HANG_DIST + float(out))
		if _fits_at(feet, Pawn.BODY_HEIGHT):
			return feet
	return Vector3.INF


## The flat top of whatever `face` is the front of: step in from the face along
## `into` and look down from `from_y` to `to_y`. A shallow step first, so a thin
## wall is not stepped over into the air behind it.
func _top_over(face: Vector3, into: Vector3, from_y: float, to_y: float) -> Dictionary:
	for inset in [0.06, 0.18, 0.3]:
		var p: Vector3 = face + into * float(inset)
		var hit := _ray(Vector3(p.x, from_y, p.z), Vector3(p.x, to_y, p.z))
		if not hit.is_empty() and (hit.normal as Vector3).y > 0.7:
			return hit
	return {}


## Is there something to hold? Air over the lip for the fingers, and top behind
## it for the hand. It also refuses the seam between two bricks inside a wall,
## which a ray from inside the wall reads as a "top" with no air over it.
func _lip_grippable(face: Vector3, top_y: float, into: Vector3) -> bool:
	var edge := Vector3(face.x, top_y, face.z)
	var over := edge + into * 0.02 + Vector3.UP * 0.005
	var up := _ray(over, over + Vector3.UP * 0.6)
	var gap := 0.6 if up.is_empty() else (up.position as Vector3).y - top_y
	if gap < LIP_AIR:
		return false
	var probe := edge + into * LIP_DEPTH + Vector3.UP * (gap - 0.01)
	var down := _ray(probe, probe + Vector3.DOWN * (gap + 0.1))
	return not down.is_empty() and absf((down.position as Vector3).y - top_y) <= 0.06


## The lip's frame, and whether a body fits on top of it.
func _set_ledge(face: Vector3, n: Vector3, top_y: float) -> void:
	ledge_face = face
	ledge_normal = n
	ledge_top = top_y
	ledge_climbable = _fit_height(_climb_feet()) > 0.0


## Where a climb from the hang puts the feet: over the lip, a body-width in.
func _climb_feet() -> Vector3:
	return Vector3(ledge_face.x, ledge_top + 0.02, ledge_face.z) \
			- ledge_normal * (Pawn.BODY_RADIUS + 0.2)


func _start_hang(face: Vector3, n: Vector3, top_y: float, feet: Vector3) -> void:
	var b := pawn.body
	# A tuck (the grapple's) or a crouch lets the legs down: a hanging body is long.
	if pawn._height < Pawn.BODY_HEIGHT:
		pawn._set_height(Pawn.BODY_HEIGHT, true)
	if state == State.WALL_RUN or state == State.WALL_STICK:
		_last_wall = wall_normal
	state = State.HANG
	pawn.rising_jump = false
	_set_ledge(face, n, top_y)
	_hang_t = 0.0
	_buffer = 0.0
	b.velocity = Vector3.ZERO
	_ease_body(feet + Vector3.UP * Pawn.BODY_HEIGHT * 0.5, HANG_ENTER)
	grabbed.emit()


func _ease_body(to: Vector3, seconds: float) -> void:
	_h_from = pawn.body.global_position
	_h_to = to
	_h_t = 0.0
	_h_dur = maxf(seconds, 0.01)


## Hanging. Facing the wall the move keys map onto it: sideways shimmies, forward
## climbs (or steps up to the next lip), back steps down (or lets go). Jump climbs
## a lip you face, springs back off one you cannot climb, and leaps the way you
## look otherwise; crouch lets go.
func _hang_tick(delta: float, wish: Vector3, crouch_edge: bool) -> void:
	var b := pawn.body
	_hang_t += delta
	if _h_t < 1.0:
		_h_t = minf(_h_t + delta / _h_dur, 1.0)
		var p := _h_from.lerp(_h_to, _ease(_h_t))
		b.velocity = (p - b.global_position) / maxf(delta, 0.001)
		b.global_position = p
		return
	b.velocity = Vector3.ZERO
	var look := _look_flat()
	var facing := look.dot(-ledge_normal) > 0.4
	if _buffer > 0.0:
		_buffer = 0.0
		if facing:
			if not (ledge_climbable and _climb_from_hang()):
				_leave_hang(ledge_normal * HANG_BACK + Vector3.UP * rise_speed(JUMP_LOW))
		else:
			_leave_hang(look * HANG_LEAP + Vector3.UP * rise_speed(JUMP_LOW))
		return
	if crouch_edge:
		_leave_hang(ledge_normal * 1.5 + Vector3.DOWN)
		return
	var side := ledge_normal.cross(Vector3.UP).normalized()
	var side_in := wish.dot(side)
	var in_axis := wish.dot(-ledge_normal)
	if absf(side_in) > 0.3 and absf(side_in) >= absf(in_axis) * 0.8:
		var tangent := side * signf(side_in)
		var shimmy := SHIMMY_SPEED * delta
		var before := b.global_position
		var ok := _shimmy(before + tangent * shimmy)
		# Pinned at the end of the lip is the lip ending: go round the corner.
		if (not ok or (b.global_position - before).dot(tangent) < shimmy * 0.4) and _corner_cd <= 0.0:
			_corner(tangent)
		return
	if _hang_t < HANG_MIN:
		return
	if in_axis > 0.3:
		if ledge_climbable:
			if _climb_cd <= 0.0 and not _climb_from_hang():
				_climb_cd = 0.3
		else:
			_step_ledge(true)
	elif in_axis < -0.4:
		if not _step_ledge(false):
			_leave_hang(ledge_normal * 1.5 + Vector3.DOWN)


## Pull up over the lip. Re-measured now -- the hang may have lasted a while, and
## what stands on top decides a standing climb, a ducked one, or none (hang on).
func _climb_from_hang() -> bool:
	var into := -ledge_normal
	var land := _climb_feet()
	var pushing := pawn.intents.move.dot(into) > 0.3
	if _climb(land, into, Pawn.WALK_SPEED * 0.6 if pushing else 0.5):
		return true
	ledge_climbable = _fit_height(land) > 0.0
	return false


func _leave_hang(v: Vector3) -> void:
	state = State.WALK
	pawn.body.velocity = v
	_ledge_cd = LEDGE_COOLDOWN


## Slide the hang along the lip to `pos`: follows a gently curving or sloping lip
## (a fan of rays finds the face, and the normal turns with it). False when the
## lip runs out, which the caller takes for a corner.
func _shimmy(pos: Vector3) -> bool:
	var o := Vector3(pos.x, ledge_top - 0.1, pos.z)
	var best := {}
	var best_d := INF
	for deg in [0.0, -15.0, 15.0, -28.0, 28.0]:
		var d := (-ledge_normal).rotated(Vector3.UP, deg_to_rad(float(deg)))
		var wh := _ray(o, o + d * (HANG_DIST + 0.5))
		if wh.is_empty() or _flat(wh.normal) == Vector3.ZERO:
			continue
		var dist := o.distance_to(wh.position)
		if dist < best_d:
			best_d = dist
			best = wh
	if best.is_empty():
		return false
	var n := _flat(best.normal)
	var face: Vector3 = best.position
	var top := _top_over(face, -n, ledge_top + 0.35, ledge_top - 0.35)
	if top.is_empty():
		return false
	var ny: float = top.position.y
	if absf(ny - ledge_top) > 0.3 or not _lip_grippable(face, ny, -n):
		return false
	var feet := _hang_spot(face, n, ny)
	if feet == Vector3.INF:
		return false
	_set_ledge(face, n, ny)
	pawn.body.global_position = feet + Vector3.UP * Pawn.BODY_HEIGHT * 0.5
	return true


## Round a corner at the end of the lip, going along `tangent`: an INSIDE corner
## (a wall across the lip ahead) or an OUTSIDE one (the lip ends and its face
## wraps round). Eased, so the turn glides.
func _corner(tangent: Vector3) -> bool:
	var into := -ledge_normal
	var here := Vector3(pawn.body.global_position.x, ledge_top - 0.1, pawn.body.global_position.z)
	var fh := _ray(here, here + into * (HANG_DIST + 0.4))
	var lip: Vector3 = fh.position if not fh.is_empty() else here + into * HANG_DIST
	var hit := _ray(lip + ledge_normal * 0.06, lip + ledge_normal * 0.06 + tangent * 0.7)
	if hit.is_empty() or _flat(hit.normal) == Vector3.ZERO:
		var from := lip + tangent * 0.35 + into * 0.35
		hit = _ray(from, from - tangent * 0.9)
	if hit.is_empty() or _flat(hit.normal) == Vector3.ZERO:
		return false
	var n := _flat(hit.normal)
	var face: Vector3 = hit.position
	var top := _top_over(face, -n, ledge_top + 0.4, ledge_top - 0.4)
	if top.is_empty():
		return false
	var ny: float = top.position.y
	if absf(ny - ledge_top) > 0.4 or not _lip_grippable(face, ny, -n):
		return false
	var feet := _hang_spot(face, n, ny)
	if feet == Vector3.INF:
		return false
	_set_ledge(face, n, ny)
	_ease_body(feet + Vector3.UP * Pawn.BODY_HEIGHT * 0.5, HANG_CORNER_TIME)
	_corner_cd = 0.35
	return true


## Up (or down) the wall to the next lip within reach: a ladder of window sills,
## a course sticking out. Up onto a lip there is room to climb onto climbs it.
func _step_ledge(up: bool) -> bool:
	var heights := [0.5, 0.8, 1.1, 1.4, 1.7] if up else [-0.5, -0.8, -1.1, -1.4, -1.7]
	var b := pawn.body
	for dy in heights:
		var o := Vector3(b.global_position.x, ledge_top + float(dy), b.global_position.z)
		var wh := _ray(o, o - ledge_normal * (HANG_DIST + 0.9))
		if wh.is_empty() or _flat(wh.normal) == Vector3.ZERO:
			continue
		var n := _flat(wh.normal)
		var face: Vector3 = wh.position
		var top := _top_over(face, -n, face.y + 0.4, face.y - 0.4)
		if top.is_empty():
			continue
		var ny: float = top.position.y
		if up and (ny <= ledge_top + 0.3 or ny > ledge_top + 1.9):
			continue
		if not up and (ny >= ledge_top - 0.3 or ny < ledge_top - 1.9):
			continue
		if not _lip_grippable(face, ny, -n):
			continue
		var feet := _hang_spot(face, n, ny)
		if feet == Vector3.INF:
			continue
		_set_ledge(face, n, ny)
		if up and ledge_climbable and _climb_from_hang():
			return true
		_ease_body(feet + Vector3.UP * Pawn.BODY_HEIGHT * 0.5, HANG_STEP_TIME)
		return true
	return false


# --- wall stick ---------------------------------------------------------------

## Flown into a wall too tall to climb: hold on. Hitting it hard is intent enough
## (even back first); a gentle touch needs the move pushing into it and the body
## already falling -- a jump up along a wall stays a jump. A fast graze along a
## wall is a wall-run's, not this.
func _try_stick(wish: Vector3) -> bool:
	var b := pawn.body
	if _wall_cd > 0.0 or b.is_on_floor():
		return false
	var hv := Vector3(b.velocity.x, 0.0, b.velocity.z)
	var n := Vector3.ZERO
	if b.is_on_wall():
		n = _flat(b.get_wall_normal())
	elif hv.length() >= STICK_MIN_SPEED:
		var hit := _ray(_chest(), _chest() + hv.normalized() * (Pawn.BODY_RADIUS + 0.35))
		if not hit.is_empty() and absf((hit.normal as Vector3).y) < 0.3:
			n = _flat(hit.normal)
	if n == Vector3.ZERO:
		return false
	var into_speed := hv.dot(-n)
	var impact := into_speed >= STICK_MIN_SPEED
	if not impact and (wish.dot(-n) < 0.35 or b.velocity.y > -0.5):
		return false
	if impact and hv.length() > WALL_RUN_MIN and hv.normalized().dot(-n) < 0.65:
		return false
	if _lip_in_reach(n):
		return false
	# The wall just left takes you back sliding, never holding: no climbing one
	# wall by jumping at it over and over.
	var same := _last_wall != Vector3.ZERO and n.dot(_last_wall) > SAME_WALL \
			and b.global_position.distance_to(_stick_pos) < 1.5
	var t := clampf((into_speed - STICK_MIN_SPEED) / (STICK_FULL_SPEED - STICK_MIN_SPEED), 0.0, 1.0)
	state = State.WALL_STICK
	pawn.rising_jump = false
	wall_normal = n
	_stick_pos = b.global_position
	_stick_dur = lerpf(STICK_TIME_MIN, STICK_TIME_MAX, t)
	_stick_t = _stick_dur if (same or not impact) else 0.0
	_stick_fast = b.velocity.y < -STICK_MAX_FALL
	b.velocity = Vector3(0.0, b.velocity.y if _stick_fast else 0.0, 0.0)
	stuck.emit()
	return true


## A lip on this wall within reach -- the grab's or the mantle's, not the stick's.
func _lip_in_reach(n: Vector3) -> bool:
	var feet := pawn.feet()
	var o := feet + Vector3.UP * 1.0
	var wh := _ray(o, o - n * (Pawn.BODY_RADIUS + 0.5))
	if wh.is_empty():
		return false
	var top := _top_over(wh.position, -n, feet.y + HANG_REACH + 0.3, feet.y + Pawn.STEP_HEIGHT)
	return not top.is_empty() and _lip_grippable(wh.position, top.position.y, -n)


func _stick_tick(delta: float, wish: Vector3) -> void:
	var b := pawn.body
	_stick_t += delta
	if b.is_on_floor():
		state = State.WALK
		return
	if _ray(_chest(), _chest() - wall_normal * (Pawn.BODY_RADIUS + 0.4)).is_empty():
		_leave_wall()
		return
	if _buffer > 0.0:
		_buffer = 0.0
		_stick_jump()
		return
	# Sliding down past a lip, still pushing in: the hands take it.
	if wish.dot(-wall_normal) >= 0.35 and _try_grab(wish, false):
		return
	if not _stick_fast and _stick_t > _stick_dur + STICK_SLIDE_TIME:
		_leave_wall()
		return
	if wish.dot(wall_normal) > 0.4:
		_leave_wall()
		b.velocity = wall_normal * 2.0
		return
	var vy: float
	if _stick_fast:
		vy = maxf(b.velocity.y - Pawn.GRAVITY * delta, -20.0)
	else:
		vy = 0.0 if _stick_t < _stick_dur else -STICK_SLIDE_SPEED
	var tangent := wall_normal.cross(Vector3.UP).normalized()
	b.velocity = tangent * wish.dot(tangent) * STICK_STRAFE + Vector3.UP * vy \
			- wall_normal * 1.5


## Off a stuck wall: facing it, spring back off it; otherwise a wall-jump the way
## you look.
func _stick_jump() -> void:
	if _look_flat().dot(-wall_normal) > 0.5:
		pawn.body.velocity = wall_normal * STICK_BACK_JUMP + Vector3.UP * rise_speed(JUMP_LOW)
		_leave_wall()
		wall_jumped.emit()
	else:
		_wall_jump()


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
	if state == State.WALL_RUN or state == State.WALL_STICK:
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
	_tuck_left = GRAPPLE_TUCK_AFTER
	grapple_released.emit()


# --- helpers ------------------------------------------------------------------

## A normal laid flat and unit length; zero when it points (nearly) straight up
## or down.
static func _flat(n: Vector3) -> Vector3:
	var f := Vector3(n.x, 0.0, n.z)
	return f.normalized() if f.length() > 0.3 else Vector3.ZERO


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
