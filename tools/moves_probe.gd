extends SceneTree

## Acceptance probe for the player's movement (PawnMoves; Docs/Reference/ceramicedge.md
## section 2).
##
##     godot --headless --path . --script res://tools/moves_probe.gd
##
## A floor and a few boxes, and a pawn driven through its intents the way the
## keyboard drives it. Each check is a move the player is promised:
##
##   sprint           holding run reaches the run speed, with no instant snap
##   jump             a tap clears two bricks, held to the top four; a high jump on
##                    the flat lands unhurt
##   slide            crouch at a run boosts to the slide speed, crouched; a second
##                    tap straight after does not boost again; letting go stands up
##   mantle           jump at a waist-high box and end up standing on it; a wall
##                    past arm's reach is not climbed; in the air, pushing into a
##                    ledge climbs it
##   wall-run         jump along a wall pushing forward and run it, held up by it;
##                    jump and leave it, away from it
##   grapple          a line to a high block pulls the pawn to it and lets go, with
##                    a cooldown; one at the sky is a cheap miss
##   ledge            a jump at a lip over a body high grabs it; pushing on climbs
##                    it standing, or DUCKED from the start under a low ceiling, or
##                    not at all with no room (hang-only); sideways shimmies and
##                    wraps the corner; forward from a lip with no room steps up to
##                    the one above; crouch lets go
##   wall stick       flying into a wall too tall to climb holds, then slides down
##                    slowly; jump facing it springs back off
##   grapple tuck     on the line the legs come up to two bricks (the view stays)
##                    and the body goes through a window a crouch would not fit
##   soldier          a pawn without moves still walks the plain walk: velocity is
##                    the wish, the same tick

const TICK := 1.0 / 30.0

var _pass := 0
var _fail := 0
var pawn: Pawn
var mv: PawnMoves


func _init() -> void:
	print("moves probe")
	_run.call_deferred()


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _box(centre: Vector3, size: Vector3) -> StaticBody3D:
	var b := StaticBody3D.new()
	b.collision_layer = Layers.STRUCTURE
	var s := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	s.shape = shape
	b.add_child(s)
	root.add_child(b)
	b.global_position = centre
	return b


func _ticks(n: int) -> void:
	for i in n:
		await physics_frame


func _hs() -> float:
	return Vector2(pawn.body.velocity.x, pawn.body.velocity.z).length()


## Drive: fresh intents, feet at `at`, looking down `yaw` (0 is -Z).
func _reset(at: Vector3, yaw := 0.0) -> void:
	pawn.intents.clear()
	pawn.intents.look_yaw = yaw
	pawn.intents.look_pitch = 0.0
	mv.state = PawnMoves.State.WALK
	pawn.place(at)
	await _ticks(6)


## Stand at `at` facing -Z at a wall there, jump held and pushing at it; true once
## hanging and settled into the hang.
func _grab_at(at: Vector3) -> bool:
	await _reset(at)
	await _ticks(12)
	pawn.intents.move = Vector3(0.0, 0.0, -1.0)
	pawn.intents.jump = true
	pawn.intents.jump_held = true
	for i in 40:
		await _ticks(1)
		if mv.is_hanging():
			break
	pawn.intents.move = Vector3.ZERO
	pawn.intents.jump_held = false
	await _ticks(8)
	return mv.is_hanging()


func _run() -> void:
	_box(Vector3(0.0, -0.5, 0.0), Vector3(200.0, 1.0, 200.0))
	pawn = Pawn.spawn(root, Vector3(0.0, 0.0, 0.0), 0)
	mv = PawnMoves.new(pawn)
	pawn.moves = mv
	await _ticks(10)

	# --- jump ---------------------------------------------------------------
	for held in [false, true]:
		await _reset(Vector3(-20.0, 0.0, 60.0))
		var y0 := pawn.feet().y
		var hp := pawn.health.total_current()
		pawn.intents.jump = true
		pawn.intents.jump_held = true
		await _ticks(1)
		pawn.intents.jump_held = held
		var top := y0
		for i in 45:
			await _ticks(1)
			top = maxf(top, pawn.feet().y)
		var want := PawnMoves.JUMP_HIGH if held else PawnMoves.JUMP_LOW
		_ok("a %s jump clears %d bricks" % ["held" if held else "tapped", roundi(want / Pawn.BRICK_M)],
				absf(top - y0 - want) < 0.12, "%.2f m (want %.2f)" % [top - y0, want])
		if held:
			_ok("and lands unhurt", pawn.is_on_floor() and pawn.health.total_current() == hp,
					"%.0f hp taken, fall read %.2f m" % [hp - pawn.health.total_current(), pawn.last_fall])

	# --- sprint -------------------------------------------------------------
	await _reset(Vector3(0.0, 0.0, 60.0))
	pawn.intents.move = Vector3(0.0, 0.0, -1.0)
	pawn.intents.run = true
	await _ticks(1)
	var first := _hs()
	await _ticks(30)
	_ok("sprint reaches the run speed", absf(_hs() - Pawn.RUN_SPEED) < 0.2,
			"%.2f m/s (run %.2f)" % [_hs(), Pawn.RUN_SPEED])
	_ok("and builds up to it rather than snapping", first < Pawn.RUN_SPEED * 0.6,
			"%.2f after one tick" % first)

	# --- slide --------------------------------------------------------------
	pawn.intents.crouch = true
	await _ticks(1)
	_ok("crouch at a run slides, boosted", mv.is_sliding() and _hs() >= PawnMoves.SLIDE_SPEED * 0.95,
			"%.2f m/s, sliding %s" % [_hs(), mv.is_sliding()])
	_ok("and low", pawn.is_crouched())
	await _ticks(8)
	pawn.intents.crouch = false
	await _ticks(2)
	_ok("letting go ends it", not mv.is_sliding())
	await _ticks(10)
	_ok("and stands up", not pawn.is_crouched())
	pawn.intents.crouch = true
	await _ticks(1)
	_ok("no second boost straight after", not mv.is_sliding(), "%.2f m/s" % _hs())
	pawn.intents.crouch = false
	pawn.intents.run = false
	pawn.intents.move = Vector3.ZERO
	await _ticks(20)

	# --- mantle -------------------------------------------------------------
	# A box whose near face is 1.2 m ahead, 1.1 m tall, deep enough to walk on.
	var at := Vector3(20.0, 0.0, 0.0)
	var crate := _box(at + Vector3(0.0, 0.55, -4.2), Vector3(3.0, 1.1, 6.0))
	await _reset(at)
	pawn.intents.move = Vector3(0.0, 0.0, -1.0)
	await _ticks(8)
	pawn.intents.jump = true
	var climbed := false
	for i in 30:
		await _ticks(1)
		climbed = climbed or mv.is_mantling()
	pawn.intents.move = Vector3.ZERO
	await _ticks(6)
	_ok("jump at a waist-high box climbs it", climbed and absf(pawn.feet().y - 1.1) < 0.12
			and pawn.is_on_floor(), "feet %.2f, mantled %s" % [pawn.feet().y, climbed])
	crate.queue_free()

	var tall := _box(at + Vector3(0.0, 1.5, -2.2), Vector3(3.0, 3.0, 2.0))
	await _reset(at)
	pawn.intents.move = Vector3(0.0, 0.0, -1.0)
	await _ticks(8)
	pawn.intents.jump = true
	climbed = false
	for i in 30:
		await _ticks(1)
		climbed = climbed or mv.is_mantling()
	pawn.intents.move = Vector3.ZERO
	await _ticks(10)
	_ok("a wall past arm's reach is not climbed", not climbed and pawn.feet().y < 0.2,
			"feet %.2f" % pawn.feet().y)
	tall.queue_free()

	# In the air, falling past a ledge at 2 m and pushing into it.
	var ledge := _box(at + Vector3(0.0, 1.0, -4.0), Vector3(3.0, 2.0, 6.0))
	await _reset(at + Vector3(0.0, 1.2, -0.7))
	pawn.intents.move = Vector3(0.0, 0.0, -1.0)
	climbed = false
	for i in 30:
		await _ticks(1)
		climbed = climbed or mv.is_mantling()
	pawn.intents.move = Vector3.ZERO
	await _ticks(6)
	_ok("in the air, pushing into a ledge climbs it", climbed and absf(pawn.feet().y - 2.0) < 0.12,
			"feet %.2f, mantled %s" % [pawn.feet().y, climbed])
	ledge.queue_free()

	# --- ledge grab, hang, climb -------------------------------------------
	# A wall 3.6 m tall and wide, its face 0.5 m ahead: a jump at it grabs the top.
	var lx := Vector3(0.0, 0.0, -40.0)
	# Too tall to mantle from the top of a jump (that would just climb over it).
	var H := 3.6
	var ledge_wall := _box(lx + Vector3(0.0, H * 0.5, -1.5), Vector3(8.0, H, 2.0))
	var hung := await _grab_at(lx)
	_ok("a jump at a lip over a body high grabs it and hangs", hung
			and absf(pawn.feet().y - (H - PawnMoves.HANG_DROP)) < 0.08,
			"state %s, feet %.2f" % [PawnMoves.State.keys()[mv.state], pawn.feet().y])
	_ok("with room on top, the lip is climbable", mv.ledge_climbable)
	var eye0 := pawn.eye.global_position.y
	pawn.intents.move = Vector3(0.0, 0.0, -1.0)
	var ducked := false
	for i in 30:
		await _ticks(1)
		ducked = ducked or pawn.is_crouched()
		if not mv.is_hanging() and not mv.is_mantling():
			break
	pawn.intents.move = Vector3.ZERO
	await _ticks(6)
	_ok("pushing on climbs it, standing", absf(pawn.feet().y - H) < 0.08
			and pawn.is_on_floor() and not ducked, "feet %.2f, ducked %s" % [pawn.feet().y, ducked])
	_ok("and the view rose with it", pawn.eye.global_position.y > eye0 + 1.0)

	# The same, under a slab 1.45 m over the top: only a crouch fits up there.
	var low_roof := _box(lx + Vector3(0.0, H + 1.45 + 0.1, -2.0), Vector3(8.0, 0.2, 3.0))
	hung = await _grab_at(lx)
	var low_at_start := false
	var tall_during := false
	pawn.intents.move = Vector3(0.0, 0.0, -1.0)
	for i in 30:
		await _ticks(1)
		if mv.is_mantling():
			low_at_start = low_at_start or pawn.is_crouched()
			tall_during = tall_during or not pawn.is_crouched()
		elif not mv.is_hanging():
			break
	pawn.intents.move = Vector3.ZERO
	await _ticks(6)
	_ok("under a low ceiling the climb is ducked from the start", hung and low_at_start
			and not tall_during, "crouched through it %s" % (low_at_start and not tall_during))
	_ok("and ends crouched on top", absf(pawn.feet().y - H) < 0.08 and pawn.is_crouched(),
			"feet %.2f, crouched %s" % [pawn.feet().y, pawn.is_crouched()])
	low_roof.queue_free()

	# No room at all on top (0.9 m): the lip is hang-only.
	# Thick, so it is a ceiling and not a lip of its own to step up to.
	var no_room := _box(lx + Vector3(0.0, H + 0.9 + 1.5, -2.0), Vector3(8.0, 3.0, 3.0))
	hung = await _grab_at(lx)
	pawn.intents.move = Vector3(0.0, 0.0, -1.0)
	await _ticks(20)
	pawn.intents.move = Vector3.ZERO
	_ok("with no room on top it hangs and does not climb", hung and mv.is_hanging()
			and not mv.ledge_climbable, "state %s" % PawnMoves.State.keys()[mv.state])
	no_room.queue_free()
	await _ticks(2)

	# Shimmy along it, and round its end.
	hung = await _grab_at(lx)
	var x0 := pawn.feet().x
	pawn.intents.move = Vector3(1.0, 0.0, 0.0)
	await _ticks(30)
	_ok("sideways shimmies along the lip", mv.is_hanging() and pawn.feet().x > x0 + 1.2
			and absf(mv.ledge_top - H) < 0.05, "x %.2f -> %.2f" % [x0, pawn.feet().x])
	for i in 90:
		await _ticks(1)
		if mv.ledge_normal.dot(Vector3(1.0, 0.0, 0.0)) > 0.9:
			break
	pawn.intents.move = Vector3.ZERO
	await _ticks(12)
	_ok("and at its end wraps round the corner", mv.is_hanging()
			and mv.ledge_normal.dot(Vector3(1.0, 0.0, 0.0)) > 0.9, "normal %v" % mv.ledge_normal)

	# Crouch lets go.
	pawn.intents.crouch = true
	await _ticks(2)
	pawn.intents.crouch = false
	await _ticks(30)
	_ok("crouch lets go of it", not mv.is_hanging() and pawn.is_on_floor(),
			"state %s" % PawnMoves.State.keys()[mv.state])
	ledge_wall.queue_free()

	# A lip with no room on it, and a higher one behind: forward steps up to that.
	var sill := _box(lx + Vector3(0.0, H * 0.5, -0.8), Vector3(8.0, H, 0.6))
	var upper := _box(lx + Vector3(0.0, (H + 1.1) * 0.5, -2.1), Vector3(8.0, H + 1.1, 2.0))
	await _ticks(2)
	hung = await _grab_at(lx)
	var first_top := mv.ledge_top
	pawn.intents.move = Vector3(0.0, 0.0, -1.0)
	var top_seen := first_top
	for i in 45:
		await _ticks(1)
		# The lip it is on, or climbing over: a step up onto a lip with room goes
		# straight on over it.
		top_seen = maxf(top_seen, mv.ledge_top)
		if not mv.is_hanging() and not mv.is_mantling():
			break
	pawn.intents.move = Vector3.ZERO
	await _ticks(10)
	_ok("forward from a lip with no room steps up to the one above", hung
			and absf(first_top - H) < 0.05 and absf(top_seen - (H + 1.1)) < 0.05,
			"lip %.2f -> %.2f; feet now %.2f" % [first_top, top_seen, pawn.feet().y])
	_ok("and climbs out on top of it", absf(pawn.feet().y - (H + 1.1)) < 0.08 and pawn.is_on_floor(),
			"feet %.2f" % pawn.feet().y)
	sill.queue_free()
	upper.queue_free()

	# --- wall stick ---------------------------------------------------------
	var sx := Vector3(-80.0, 0.0, 0.0)
	var tower := _box(sx + Vector3(0.0, 5.0, -3.0), Vector3(8.0, 10.0, 2.0))
	await _reset(sx + Vector3(0.0, 0.0, 1.0))
	pawn.place(sx + Vector3(0.0, 3.0, -1.2))
	pawn.body.velocity = Vector3(0.0, 0.0, -6.0)
	var stuck := false
	for i in 20:
		await _ticks(1)
		if mv.is_wall_sticking():
			stuck = true
			break
	var y_stick := pawn.feet().y
	await _ticks(6)
	_ok("flying into a wall too tall to climb sticks to it", stuck
			and absf(pawn.feet().y - y_stick) < 0.05, "held at %.2f" % pawn.feet().y)
	await _ticks(40)
	_ok("then slides down it slowly", mv.is_wall_sticking() and pawn.feet().y < y_stick - 0.2
			and pawn.body.velocity.y > -PawnMoves.STICK_SLIDE_SPEED - 0.1,
			"feet %.2f, vy %.2f" % [pawn.feet().y, pawn.body.velocity.y])
	var z_stick := pawn.feet().z
	pawn.intents.jump = true
	await _ticks(8)
	_ok("jump facing it springs back off it", not mv.is_wall_sticking()
			and pawn.feet().z > z_stick + 0.6, "z %.2f -> %.2f" % [z_stick, pawn.feet().z])
	await _ticks(60)
	tower.queue_free()

	# --- grapple through a window -------------------------------------------
	# A wall with a window three courses tall and four studs wide -- a building's
	# -- and a hook point just behind it, the line through the opening.
	var wx2 := Vector3(80.0, 0.0, 0.0)
	var sill_y := 4.4
	var win_h := Pawn.BRICK_M * 3.0
	var win_w := 0.35 * 4.0
	var wz := -12.0
	_box(wx2 + Vector3(0.0, sill_y * 0.5, wz), Vector3(10.0, sill_y, 0.35))
	_box(wx2 + Vector3(0.0, sill_y + win_h + 1.5, wz), Vector3(10.0, 3.0, 0.35))
	_box(wx2 + Vector3(-(win_w * 0.5 + 2.5), sill_y + win_h * 0.5, wz), Vector3(5.0, win_h, 0.35))
	_box(wx2 + Vector3(win_w * 0.5 + 2.5, sill_y + win_h * 0.5, wz), Vector3(5.0, win_h, 0.35))
	var back := _box(wx2 + Vector3(0.0, sill_y + win_h * 0.5, wz - 3.0), Vector3(6.0, 6.0, 0.4))
	_box(wx2 + Vector3(0.0, sill_y - 0.5, 0.0), Vector3(3.0, 1.0, 3.0))
	await _reset(wx2 + Vector3(0.0, sill_y, 0.0))
	var aim_at := wx2 + Vector3(0.0, sill_y + win_h * 0.5, wz - 2.8)
	var to2: Vector3 = aim_at - pawn.eye.global_position
	pawn.intents.look_pitch = atan2(to2.y, Vector2(to2.x, to2.z).length())
	await _ticks(2)
	var eye_before := pawn.eye.global_position.y
	pawn.intents.grapple = true
	await _ticks(2)
	_ok("on the line the legs tuck up to two bricks", mv.is_grappling()
			and absf(pawn._height - PawnMoves.GRAPPLE_TUCK) < 0.01, "height %.2f" % pawn._height)
	_ok("and the view does not drop with them", absf(pawn.eye.global_position.y - eye_before) < 0.1,
			"eye %.2f -> %.2f" % [eye_before, pawn.eye.global_position.y])
	var through := false
	for i in 90:
		await _ticks(1)
		if pawn.feet().z < wz - 0.4:
			through = true
			break
		if not mv.is_grappling():
			break
	pawn.intents.grapple = false
	_ok("the tucked body goes through a window a crouch would not fit", through,
			"z %.2f (wall at %.2f), state %s" % [pawn.feet().z, wz, PawnMoves.State.keys()[mv.state]])
	back.queue_free()
	await _ticks(100)


	# --- wall-run -----------------------------------------------------------
	# A long wall on the right of a run down -Z.
	var wx := Vector3(-30.0, 0.0, 0.0)
	var wall := _box(wx + Vector3(1.0 + 0.5, 3.0, -10.0), Vector3(1.0, 6.0, 40.0))
	await _reset(wx + Vector3(1.0 - Pawn.BODY_RADIUS - 0.12, 0.0, 8.0))
	pawn.intents.move = Vector3(0.0, 0.0, -1.0)
	pawn.intents.run = true
	await _ticks(24)
	pawn.intents.jump = true
	var ran := false
	var y0 := 0.0
	for i in 30:
		await _ticks(1)
		if mv.is_wall_running() and not ran:
			ran = true
			y0 = pawn.feet().y
		if ran and i > 20:
			break
	_ok("jumping along a wall, pushing on, runs it", ran and mv.is_wall_running(),
			"state %s" % PawnMoves.State.keys()[mv.state])
	await _ticks(6)
	_ok("held up by it, not falling", ran and pawn.feet().y >= y0 - 0.05 and not pawn.is_on_floor(),
			"feet %.2f from %.2f" % [pawn.feet().y, y0])
	var x_before := pawn.feet().x
	pawn.intents.jump = true
	await _ticks(8)
	_ok("jump leaves the wall, away from it", not mv.is_wall_running()
			and pawn.feet().x < x_before - 0.4, "x %.2f -> %.2f" % [x_before, pawn.feet().x])
	pawn.intents.run = false
	pawn.intents.move = Vector3.ZERO
	await _ticks(40)
	wall.queue_free()

	# --- grapple ------------------------------------------------------------
	var gx := Vector3(40.0, 0.0, 0.0)
	var post := _box(gx + Vector3(0.0, 8.0, -18.0), Vector3(2.0, 2.0, 2.0))
	await _reset(gx)
	var to: Vector3 = post.global_position - pawn.eye.global_position
	pawn.intents.look_pitch = atan2(to.y, Vector2(to.x, to.z).length())
	await _ticks(2)
	var d0 := pawn.eye.global_position.distance_to(post.global_position)
	pawn.intents.grapple = true
	await _ticks(2)
	_ok("the line bites on what the eye is on", mv.is_grappling(),
			"hook %v" % mv.hook)
	var closest := d0
	var let_go := false
	for i in 90:
		await _ticks(1)
		closest = minf(closest, pawn.eye.global_position.distance_to(post.global_position))
		if not mv.is_grappling():
			let_go = true
			break
	_ok("it pulls the pawn to it and lets go", let_go and closest < 3.0,
			"%.1f m -> %.1f m" % [d0, closest])
	_ok("and the next line waits", mv.grapple_cooldown() > 0.5, "%.2f" % mv.grapple_cooldown())
	pawn.intents.grapple = false
	await _ticks(100)
	await _reset(gx + Vector3(0.0, 0.0, 30.0))
	pawn.intents.look_pitch = 1.2
	pawn.intents.grapple = true
	await _ticks(2)
	_ok("one at the sky is a miss, and cheap", not mv.is_grappling()
			and mv.grapple_cooldown() < 0.25, "cooldown %.2f" % mv.grapple_cooldown())
	pawn.intents.grapple = false
	post.queue_free()

	# --- a soldier's plain walk ---------------------------------------------
	var so := Pawn.spawn(root, Vector3(-60.0, 0.0, 0.0), 1)
	await _ticks(8)
	so.intents.move = Vector3(1.0, 0.0, 0.0)
	await _ticks(1)
	var sv := Vector2(so.body.velocity.x, so.body.velocity.z).length()
	_ok("a pawn without moves walks the plain walk", so.moves == null
			and absf(sv - Pawn.WALK_SPEED) < 0.05, "%.2f m/s the first tick" % sv)

	print("moves probe: %d ok, %d FAIL" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
