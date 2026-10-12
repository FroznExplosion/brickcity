extends SceneTree

## Probe: a dead soldier's gun falls to the floor (COMBAT_DESIGN 7.4).
##
##     godot --headless --path . --script res://tools/held_gun_drop_probe.gd
##
## What WaveDirector._on_soldier_died lays on the floor, besides its loot roll:
##   held         a soldier with a gun gives that gun's result -- the one it fired
##   none         one with no gun (a bomber, a brawler) gives nothing
##   pickup       that result made a floor gun is the same gun: seed, name, rarity,
##                and its card names it
##   lies         tossed, it falls, lands and comes to rest

var _pass := 0
var _fail := 0


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok    ", what)
	else:
		_fail += 1
		print("  FAIL  ", what, ("  (" + detail + ")") if detail != "" else "")


func _init() -> void:
	print("held gun drop probe")
	_run.call_deferred()


func _run() -> void:
	var s := AIServices.new()
	s.rng.seed = 42
	s.world3d = root.get_world_3d()
	var w := BrickWorld.new()
	s.ai_world = AIWorld.new()
	s.ai_world.set_world(w)
	s.ai_nav = AINav.new()
	s.ai_nav.set_ai_world(s.ai_world)
	s.sched = AIScheduler.new()
	s.policy = CombatPolicy.new()
	s.ai_world.sync()
	var lib := GunPlaceholderParts.build_library()
	var floor_body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(40.0, 1.0, 40.0)
	shape.shape = box
	floor_body.add_child(shape)
	floor_body.collision_layer = 0xFFFFFFFF
	root.add_child(floor_body)
	floor_body.global_position = Vector3(0.0, -0.5, 0.0)

	var gun := GunInstance.from_result(GunGenerator.generate(lib, 7, WeaponClass.builtin(&"rifle"), 1))
	var so := Soldier.spawn(s, root, Vector3(0.0, 0.0, 0.0), 1, gun)
	await physics_frame
	var held := WaveDirector.held_gun_result(so)
	_ok("held: a soldier's gun is what it drops", held != null and held == gun.result)

	var bomber := Soldier.spawn(s, root, Vector3(4.0, 0.0, 0.0), 1, null)
	bomber.no_gun = true
	_ok("none: a soldier with no gun drops none", WaveDirector.held_gun_result(bomber) == null)

	var p := WorldGunPickup.create(lib, held)
	root.add_child(p)
	p.global_position = Vector3(8.0, 1.1, 0.0)
	p.toss()
	_ok("pickup: the same gun on the floor", p.result == held and p.gun.gun_seed == gun.gun_seed)
	var card := GunCard.new()
	root.add_child(card)
	card.show_gun(p.result)
	_ok("pickup: its card names it", card.text().contains(gun.gun_name), card.text().left(80))

	var rested := false
	for i in 300:
		await physics_frame
		if p.resting():
			rested = true
			break
	_ok("lies: tossed, it falls and comes to rest", rested and p.global_position.y < 0.6,
			"y %.2f" % p.global_position.y)

	print("held gun drop probe: %d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
