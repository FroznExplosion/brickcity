extends SceneTree

## Acceptance probe for LimboAI in this project: it loads, and it is used the way
## Docs/AI.md says -- a behaviour tree is a BRAIN that fills PawnIntents, never a
## second way of moving a body.
##
##     godot --headless --path . --script tools/limbo_probe.gd
##
## A tree of two BTMoveTo tasks walks a Pawn to one point and then another; the
## pawn gets there by its own motor, and the tree reports success.

const LIMIT := 600

var _pass := 0
var _fail := 0
var _pawn: Pawn
var _player: BTPlayer
var _tick := 0
var _a := Vector3(6.0, 0.0, 0.0)
var _b := Vector3(6.0, 0.0, -8.0)
var _reached_a := -1


func _init() -> void:
	print("limbo probe")
	_ok("the LimboAI extension is loaded", ClassDB.class_exists(&"BTPlayer")
			and ClassDB.class_exists(&"LimboHSM"))
	var ground := StaticBody3D.new()
	ground.collision_layer = Layers.WORLD
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(100.0, 1.0, 100.0)
	shape.shape = box
	shape.position = Vector3(0.0, -0.5, 0.0)
	ground.add_child(shape)
	root.add_child(ground)
	_pawn = Pawn.spawn(root, Vector3.ZERO, 1)

	var seq := BTSequence.new()
	var to_a := BTMoveTo.new()
	to_a.target_var = &"a"
	var to_b := BTMoveTo.new()
	to_b.target_var = &"b"
	to_b.run = true
	seq.add_child(to_a)
	seq.add_child(to_b)
	var bt := BehaviorTree.new()
	bt.set_root_task(seq)
	_player = BTPlayer.new()
	_player.name = "Brain"
	_player.update_mode = BTPlayer.PHYSICS
	_player.behavior_tree = bt
	# Built in code, so there is no scene owner to find the scene root from.
	_player.set_scene_root_hint(root)
	_pawn.body.add_child(_player)
	_player.blackboard.set_var(&"a", _a)
	_player.blackboard.set_var(&"b", _b)
	physics_frame.connect(_on_tick)


func _on_tick() -> void:
	_tick += 1
	if _reached_a < 0 and _pawn.feet().distance_to(_a) < 0.7:
		_reached_a = _tick
	var inst := _player.get_bt_instance()
	var status: int = inst.get_last_status() if inst != null else BT.FRESH
	if status == BT.SUCCESS or status == BT.FAILURE or _tick >= LIMIT:
		_finish(status)


func _finish(status: int) -> void:
	physics_frame.disconnect(_on_tick)
	_ok("the tree walked the pawn to the first point", _reached_a > 0,
			"tick %d" % _reached_a)
	_ok("and then to the second, running", _pawn.feet().distance_to(_b) < 0.7,
			"%.2f m off, tick %d" % [_pawn.feet().distance_to(_b), _tick])
	_ok("and reported success", status == BT.SUCCESS, "status %d" % status)
	_ok("by writing intents, which it left at rest",
			_pawn.intents.move == Vector3.ZERO and _pawn.is_on_floor())
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])
