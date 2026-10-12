extends SceneTree

## A gun on the floor is a body (WorldGunPickup).
##
##     godot --headless --path . --script res://tools/pickup_physics_probe.gd
##
##   it falls       dropped from above the floor, it falls and comes to rest ON it --
##                  not hovering, not through it -- and sleeps
##   asleep         it stays where it lies, frozen there
##   a blast        wakes it and throws it out, away from the blast
##   no floor       take the floor out from under a sleeping gun and it wakes and falls
##                  to what is below
##   walkers        it is on the rubble layer: a pawn's body does not collide with it

var _pass := 0
var _fail := 0


func _init() -> void:
	print("pickup physics probe")
	_run.call_deferred()


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _slab(at: Vector3, size: Vector3) -> StaticBody3D:
	var sb := StaticBody3D.new()
	sb.collision_layer = Layers.STRUCTURE
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	cs.shape = box
	sb.add_child(cs)
	root.add_child(sb)
	sb.global_position = at
	return sb


func _ticks(n: int) -> void:
	for i in n:
		await physics_frame


func _run() -> void:
	var lib := GunPlaceholderParts.build_library()
	var ground := _slab(Vector3(0.0, -0.5, 0.0), Vector3(40.0, 1.0, 40.0))
	ground.collision_layer = Layers.WORLD
	var floor := _slab(Vector3(0.0, 2.9, 0.0), Vector3(4.0, 0.2, 4.0))
	await _ticks(2)

	var res := GunGenerator.generate(lib, 5, WeaponClass.builtin(&"rifle"), 1)
	var p := WorldGunPickup.create(lib, res)
	root.add_child(p)
	p.global_position = Vector3(0.0, 4.5, 0.0)
	p.toss()
	var slept := false
	for i in 400:
		await physics_frame
		if p.resting():
			slept = true
			break
	var y := p.global_position.y
	_ok("dropped, it falls and comes to rest on the floor, asleep",
			slept and y > 3.0 and y < 3.25, "y %.2f (floor top 3.0), asleep %s" % [y, slept])
	var rest := p.global_position
	await _ticks(60)
	_ok("asleep, it stays where it lies, frozen", p.freeze and p.global_position.distance_to(rest) < 0.01)

	WorldGunPickup.blast(rest + Vector3(1.0, -0.2, 0.0), 4.0)
	await _ticks(20)
	var moved := p.global_position - rest
	_ok("a blast wakes it and throws it out from the blast", moved.length() > 0.3 and moved.x < 0.0,
			"moved %v" % moved)
	for i in 400:
		await physics_frame
		if p.resting():
			break
	# Back on the floor or off it; put it back in the middle and let it sleep.
	p.global_position = Vector3(0.0, 3.4, 0.0)
	p.linear_velocity = Vector3.ZERO
	p.angular_velocity = Vector3.ZERO
	for i in 400:
		await physics_frame
		if p.resting():
			break
	_ok("(asleep on the floor again)", p.resting() and p.global_position.y > 3.0)

	floor.queue_free()
	var fell := false
	for i in 240:
		await physics_frame
		if p.global_position.y < 0.5:
			fell = true
			break
	_ok("the floor gone from under it, it wakes and falls to the ground", fell,
			"y %.2f" % p.global_position.y)

	var pawn := Pawn.spawn(root, Vector3(5.0, 0.0, 0.0), 1, false)
	await _ticks(2)
	_ok("walkers do not collide with it", pawn.body.collision_mask & p.collision_layer == 0
			and p.collision_mask & Layers.PAWN == 0)
	# And walked over, it stays where it lies: a pawn's body goes through it.
	for i in 400:
		await physics_frame
		if p.resting():
			break
	var lay := p.global_position
	pawn.place(lay + Vector3(-2.0, -lay.y, 0.0))
	await _ticks(2)
	for i in 90:
		pawn.body.velocity = Vector3(4.0, pawn.body.velocity.y - 0.3, 0.0)
		pawn.body.move_and_slide()
		await physics_frame
	await _ticks(30)
	_ok("a pawn walks over it and it stays where it lies", p.global_position.distance_to(lay) < 0.02
			and pawn.feet().x > lay.x + 1.0, "moved %.3f m, pawn at x %.1f (gun %.1f)" % [
			p.global_position.distance_to(lay), pawn.feet().x, lay.x])
	print("pickup physics probe: %d ok, %d FAIL" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
