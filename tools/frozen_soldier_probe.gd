extends SceneTree

## A frozen or staggered soldier is held, body and mind (Pawn.is_held, Soldier,
## Docs/Weapons/COMBAT_DESIGN.md 4.2, 5).
##
##     godot --headless --path . --script res://tools/frozen_soldier_probe.gd
##
##   fighting   a soldier in the open with the player in sight shoots
##   frozen     ice enough to freeze it: it fires no more, moves no more, turns no more
##   thawed     the freeze over, it fights again
##   staggered  a stagger holds it the same, for its time only

var s: AIServices
var soldier: Soldier
var player: Pawn
var _pass := 0
var _fail := 0


func _init() -> void:
	print("frozen soldier probe")
	_run.call_deferred()


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _ticks(n: int) -> void:
	for i in n:
		await physics_frame


func _seconds(t: float) -> void:
	await _ticks(int(ceil(t * Engine.physics_ticks_per_second)))


## The AI's frame, as the scene runs it: the world, the paths, the scheduler.
func _on_tick() -> void:
	s.ai_world.sync()
	s.ai_nav.service(500)
	s.sched.run()


func _run() -> void:
	var floor := StaticBody3D.new()
	floor.collision_layer = Layers.WORLD
	var fs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(80.0, 1.0, 80.0)
	fs.shape = box
	floor.add_child(fs)
	root.add_child(floor)
	floor.global_position = Vector3(0.0, -0.5, 0.0)
	var w := BrickWorld.new()
	s = AIServices.new()
	s.rng.seed = 42
	s.ai_world = AIWorld.new()
	s.ai_world.set_world(w)
	s.ai_nav = AINav.new()
	s.ai_nav.set_ai_world(s.ai_world)
	s.sched = AIScheduler.new()
	s.policy = CombatPolicy.new()
	s.world3d = root.get_world_3d()
	s.ai_world.sync()
	var lib := GunPlaceholderParts.build_library()
	var gun := GunInstance.from_result(GunGenerator.generate(lib, 7, WeaponClass.builtin(&"rifle"), 1))
	soldier = Soldier.spawn(s, root, Vector3(0.0, 0.0, -12.0), 1, gun)
	soldier.pawn.intents.look_yaw = PI
	player = Pawn.spawn(root, Vector3.ZERO, 0, true, 1.0e6)
	s.pawns.append(player)
	Soldier._greybox(player, 0)
	player.intents.look_yaw = 0.0
	physics_frame.connect(_on_tick)

	var waited := 0.0
	while soldier.shots == 0 and waited < 12.0:
		await _seconds(0.5)
		waited += 0.5
	_ok("in the open with the player in sight, it shoots", soldier.shots > 0,
			"%d round(s) in %.1f s" % [soldier.shots, waited])

	var es := ElementStatus.of(soldier.pawn.body, true)
	es.add_chill(1.0)
	await _ticks(1)
	var shots := soldier.shots
	var at := soldier.pawn.feet()
	var yaw := soldier.pawn.eye.global_rotation.y
	var think0 := soldier._next_think
	var sense0 := soldier._next_sense
	_ok("ice enough freezes it", es.is_frozen() and soldier.pawn.is_held())
	await _seconds(ElementStatus.FREEZE_SECONDS * 0.8)
	_ok("frozen, it fires no more", soldier.shots == shots, "%d -> %d" % [shots, soldier.shots])
	_ok("moves and turns no more", soldier.pawn.feet().distance_to(at) < 0.05
			and absf(soldier.pawn.eye.global_rotation.y - yaw) < 0.01)
	_ok("and its trigger is up", not soldier.pawn.intents.fire)
	_ok("its mind waits: no thinking, no sensing", soldier._next_think == think0
			and soldier._next_sense == sense0)
	await _seconds(ElementStatus.FREEZE_SECONDS * 0.2 + 0.2)
	_ok("the freeze over, it is let go", not soldier.pawn.is_held())
	waited = 0.0
	while soldier.shots == shots and waited < 8.0:
		await _seconds(0.25)
		waited += 0.25
	_ok("and it fights again", soldier.shots > shots, "after %.2f s" % waited)

	soldier.pawn.stagger(1.0)
	await _ticks(1)
	shots = soldier.shots
	await _seconds(0.8)
	_ok("staggered, held the same", soldier.shots == shots and soldier.pawn.is_held())
	await _seconds(0.4)
	_ok("for its time only", not soldier.pawn.is_held())

	print("frozen soldier probe: %d ok, %d FAIL" % [_pass, _fail])
	for c in root.get_children():
		c.queue_free()
	await _ticks(2)
	quit(1 if _fail > 0 else 0)
