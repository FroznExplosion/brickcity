extends SceneTree

## Acceptance probe for Pawn: the motor answers to intents, whoever fills them.
##
##     godot --headless --path . --script tools/pawn_probe.gd
##
## No keyboard here: the intents are scripted, which is exactly what an AI brain
## will do. Two pawns run the same script side by side and must end where each
## other ended, to the millimetre -- the motor is a function of its intents and
## its world, on the physics tick, and that is what lets a co-op host and a
## client, or a replay, agree about where a soldier walked.

const SCRIPT_TICKS := 150
const APART := 20.0

var _pass := 0
var _fail := 0
var _pawns: Array[Pawn] = []
var _tick := 0
var _path: Array = [[], []]


func _init() -> void:
	print("pawn probe")
	var ground := StaticBody3D.new()
	ground.collision_layer = Layers.WORLD
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(200.0, 1.0, 200.0)
	shape.shape = box
	shape.position = Vector3(0.0, -0.5, 0.0)
	ground.add_child(shape)
	root.add_child(ground)
	for i in 2:
		# The same kerb in front of each.
		var kerb := StaticBody3D.new()
		kerb.collision_layer = Layers.WORLD
		var ks := CollisionShape3D.new()
		var kb := BoxShape3D.new()
		kb.size = Vector3(4.0, 0.3, 0.6)
		ks.shape = kb
		kerb.add_child(ks)
		root.add_child(kerb)
		kerb.position = Vector3(i * APART, 0.15, 4.0)
		_pawns.append(Pawn.spawn(root, Vector3(i * APART, 1.0, 0.0), 1))
	physics_frame.connect(_tick_script)


## The "brain": walk forward over the kerb, run, crouch, strafe, jump.
func _drive(p: Pawn, t: int) -> void:
	var it := p.intents
	it.move = Vector3.ZERO
	it.run = false
	it.crouch = false
	if t > 10 and t < 60:
		it.move = Vector3(0.0, 0.0, 1.0)
	elif t < 80:
		it.move = Vector3(0.0, 0.0, 1.0)
		it.run = true
	elif t < 100:
		it.move = Vector3(1.0, 0.0, 0.0)
		it.crouch = true
	elif t == 110:
		it.jump = true


func _tick_script() -> void:
	_tick += 1
	for i in 2:
		_drive(_pawns[i], _tick)
		_path[i].append(_pawns[i].feet() - Vector3(i * APART, 0.0, 0.0))
	if _tick == 95:
		_ok("a crouch request crouches", _pawns[0].is_crouched())
	if _tick == SCRIPT_TICKS:
		_finish()


func _finish() -> void:
	var a: Pawn = _pawns[0]
	_ok("it walked forward and over the kerb", a.feet().z > 5.0, "z %.2f" % a.feet().z)
	# Crouched: 20 ticks at CROUCH_SPEED is 0.81 m.
	_ok("and strafed, at crouching speed", absf(a.feet().x - Pawn.CROUCH_SPEED * 20.0 / 30.0) < 0.05,
			"x %.2f" % a.feet().x)
	_ok("and came down from its jump onto the ground", a.is_on_floor() and a.feet().y < 0.05,
			"feet %.3f" % a.feet().y)
	var high := 0.0
	for p in _path[0]:
		high = maxf(high, (p as Vector3).y)
	_ok("the jump left the ground", high > 0.3, "%.2f m" % high)
	var worst := 0.0
	for k in _path[0].size():
		worst = maxf(worst, (_path[0][k] as Vector3).distance_to(_path[1][k]))
	_ok("two pawns given the same intents walk the same path", worst < 0.001,
			"worst %.5f m over %d ticks" % [worst, _path[0].size()])
	_ok("with health, found where a bullet looks for it",
			a.health != null and a.body.get_node_or_null(^"HealthPool") == a.health)
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])
