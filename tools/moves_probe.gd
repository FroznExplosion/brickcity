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
##   slide            crouch at a run boosts to the slide speed, crouched; a second
##                    tap straight after does not boost again; letting go stands up
##   mantle           jump at a waist-high box and end up standing on it; a wall
##                    past arm's reach is not climbed; in the air, pushing into a
##                    ledge climbs it
##   wall-run         jump along a wall pushing forward and run it, held up by it;
##                    jump and leave it, away from it
##   grapple          a line to a high block pulls the pawn to it and lets go, with
##                    a cooldown; one at the sky is a cheap miss
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


func _run() -> void:
	_box(Vector3(0.0, -0.5, 0.0), Vector3(200.0, 1.0, 200.0))
	pawn = Pawn.spawn(root, Vector3(0.0, 0.0, 0.0), 0)
	mv = PawnMoves.new(pawn)
	pawn.moves = mv
	await _ticks(10)

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
