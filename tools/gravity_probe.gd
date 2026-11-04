extends SceneTree

## Acceptance probe for ladders and gravity of one's own (Docs/RoomModules.md
## 7.12, 7.13): the pawn as the player moves it.
##
##     godot --headless --path . --script res://tools/gravity_probe.gd
##
##   ladder     walking into a ladder climbs it; forward to its top goes over it
##              and stands on what it leads to; back climbs down to the floor and
##              lets go; jump springs off it; the same wall with no ladder is not
##              climbed
##   field      inside a field its own down and pull, over the world's; outside
##              it, the world's; a field with no centre pulls nothing
##   turn       into a new down in the air the body rights itself over a moment
##              (Pawn.REORIENT_RATE), not in a tick, and lands on its feet
##   float      where nothing pulls the pawn floats, falling nowhere; the move
##              thrusts it, no faster than FLOAT_SPEED; let go, it steadies

const TICK := 1.0 / 30.0
## The ladder's wall: its face at z = 0, its top at TOP.
const TOP := 2.8

var _pass := 0
var _fail := 0
var pawn: Pawn
var mv: PawnMoves


func _init() -> void:
	print("gravity probe")
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

	# --- ladder ---------------------------------------------------------------
	# A wall TOP high, its face at z = 0, a ladder up its face; floor on top of it.
	_box(Vector3(0.0, TOP * 0.5, -2.0), Vector3(3.0, TOP, 4.0))
	var lad := Ladder.new()
	lad.width = 0.7
	lad.height = TOP
	root.add_child(lad)
	await _reset(Vector3(0.0, 0.0, 1.5))
	pawn.intents.move = Vector3(0.0, 0.0, -1.0)
	var took := false
	var high := 0.0
	var over := false
	for i in 150:
		await _ticks(1)
		took = took or mv.is_climbing()
		high = maxf(high, pawn.feet().y)
		if pawn.is_on_floor() and pawn.feet().y > TOP - 0.05 and pawn.feet().z < -0.3:
			over = true
			break
	_ok("walking into a ladder climbs it", took, "climbing seen %s, up to %.2f m" % [took, high])
	await _ticks(10)
	_ok("forward to its top goes over it, standing on what it leads to", over and pawn.is_on_floor()
			and absf(pawn.feet().y - TOP) < 0.1 and not mv.is_climbing(),
			"feet %s, on the floor %s" % [str(pawn.feet().snapped(Vector3(0.01, 0.01, 0.01))), pawn.is_on_floor()])
	# Half way up, then back: down to the floor, off it.
	await _reset(Vector3(0.0, 0.0, 1.0))
	pawn.intents.move = Vector3(0.0, 0.0, -1.0)
	for i in 60:
		await _ticks(1)
		if mv.is_climbing() and pawn.feet().y > 1.2:
			break
	var mid := pawn.feet().y
	pawn.intents.move = Vector3(0.0, 0.0, 1.0)
	var down := false
	for i in 90:
		await _ticks(1)
		if not mv.is_climbing() and pawn.is_on_floor():
			down = true
			break
	_ok("back climbs down to the floor and lets go", mid > 1.2 and down and pawn.feet().y < 0.1,
			"from %.2f m, at %.2f m, climbing %s" % [mid, pawn.feet().y, mv.is_climbing()])
	# Up a little, then jump: off it, away from its face.
	await _reset(Vector3(0.0, 0.0, 1.0))
	pawn.intents.move = Vector3(0.0, 0.0, -1.0)
	for i in 45:
		await _ticks(1)
		if mv.is_climbing() and pawn.feet().y > 0.8:
			break
	pawn.intents.move = Vector3.ZERO
	pawn.intents.jump = true
	await _ticks(8)
	_ok("jump springs off it", not mv.is_climbing() and pawn.feet().z > 0.8,
			"%.2f m out of its face" % pawn.feet().z)
	# The same wall, its ladder gone: not climbed.
	lad.queue_free()
	await _ticks(2)
	await _reset(Vector3(0.0, 0.0, 1.0))
	pawn.intents.move = Vector3(0.0, 0.0, -1.0)
	var rose := 0.0
	for i in 60:
		await _ticks(1)
		rose = maxf(rose, pawn.feet().y)
	_ok("the same wall with no ladder is not climbed", rose < 0.2 and not mv.is_climbing(), "up %.2f m" % rose)

	# --- field ----------------------------------------------------------------
	# A field round x 40..60 whose down is -X (its centre 3 km off that way).
	var space := Node3D.new()
	root.add_child(space)
	var centre := Node3D.new()
	root.add_child(centre)
	centre.global_position = Vector3(50.0 - 3000.0, 5.0, 0.0)
	var f := Gravity.Field.new()
	f.space = space
	f.boxes = [AABB(Vector3(40.0, -5.0, -10.0), Vector3(20.0, 30.0, 20.0))]
	f.centre = centre
	f.pull = 9.8
	f.radius = 3000.0
	var void_f := Gravity.Field.new()
	void_f.space = space
	void_f.boxes = [AABB(Vector3(-80.0, -5.0, -40.0), Vector3(50.0, 30.0, 80.0))]
	Gravity.fields = [f, void_f]
	var inside := Vector3(50.0, 5.0, 0.0)
	_ok("inside a field its own down and pull, over the world's", Gravity.down_at(inside).distance_to(Vector3.LEFT) < 0.01
			and Gravity.pull_at(inside) == 9.8 and Gravity.field_at(inside) == f,
			"down %s, %.1f m/s2" % [str(Gravity.down_at(inside)), Gravity.pull_at(inside)])
	_ok("outside it the world's", Gravity.down_at(Vector3(0.0, 5.0, 0.0)) == Vector3.DOWN
			and Gravity.pulls_at(Vector3(0.0, 5.0, 0.0)) and Gravity.field_at(Vector3(0.0, 5.0, 0.0)) == null)
	_ok("a field with no centre pulls nothing", not Gravity.pulls_at(Vector3(-50.0, 5.0, 0.0))
			and Gravity.pull_at(Vector3(-50.0, 5.0, 0.0)) == 0.0)

	# --- turn -----------------------------------------------------------------
	# Into the field in the air, upright for the world: its up is +X.
	_box(Vector3(44.5, 5.0, 0.0), Vector3(1.0, 20.0, 20.0))    # the field's floor, its face at x = 45
	await _reset(Vector3(0.0, 0.0, 30.0))
	pawn.body.global_position = Vector3(48.0, 5.0, 0.0)
	pawn.body.velocity = Vector3.ZERO
	pawn.body.reset_physics_interpolation()
	await _ticks(2)
	var early := rad_to_deg(pawn.body.global_basis.y.angle_to(Vector3.RIGHT))
	var t := 0
	while t < 60 and not (pawn.is_on_floor() and pawn.body.global_basis.y.angle_to(Vector3.RIGHT) < 0.02):
		await _ticks(1)
		t += 1
	var late := rad_to_deg(pawn.body.global_basis.y.angle_to(Vector3.RIGHT))
	_ok("into a new down in the air: righted over a moment, not in a tick", early > 70.0 and late < 2.0,
			"%.0f deg off two ticks in, %.1f deg after %.2f s" % [early, late, t * TICK])
	_ok("and lands on its feet on the field's floor", pawn.is_on_floor() and absf(pawn.feet().x - 45.0) < 0.15,
			"feet %s" % str(pawn.feet().snapped(Vector3(0.01, 0.01, 0.01))))

	# --- float ----------------------------------------------------------------
	await _reset(Vector3(-50.0, 0.0, 0.0))
	pawn.body.global_position = Vector3(-50.0, 6.0, 0.0)
	pawn.body.velocity = Vector3.ZERO
	await _ticks(30)
	var y0 := pawn.feet().y
	await _ticks(30)
	_ok("where nothing pulls it floats, falling nowhere", pawn.floating and mv.is_floating()
			and absf(pawn.feet().y - y0) < 0.05, "%.3f m in 1 s" % (pawn.feet().y - y0))
	pawn.intents.move = Vector3(0.0, 0.0, -1.0)
	var top_speed := 0.0
	for i in 90:
		await _ticks(1)
		top_speed = maxf(top_speed, pawn.body.velocity.length())
	_ok("the move thrusts it, no faster than FLOAT_SPEED", top_speed > PawnMoves.FLOAT_SPEED * 0.9
			and top_speed <= PawnMoves.FLOAT_SPEED + 0.01, "%.2f m/s, at most %.2f" % [top_speed, PawnMoves.FLOAT_SPEED])
	pawn.intents.move = Vector3.ZERO
	await _ticks(60)
	_ok("let go, it steadies", pawn.floating and pawn.body.velocity.length() < top_speed * 0.5
			and pawn.body.velocity.length() > 0.05, "%.2f m/s after 2 s" % pawn.body.velocity.length())

	Gravity.fields = []
	print("gravity probe: %d ok, %d FAIL" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
