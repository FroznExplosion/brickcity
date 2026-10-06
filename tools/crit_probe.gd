extends SceneTree

## Crit spots (Docs/Weapons/COMBAT_DESIGN.md 4.3): a crit is WHERE the round lands.
##
##     godot --headless --path . --script res://tools/crit_probe.gd
##
## A soldier-shaped pawn and a pistol held dead straight, fired from a few metres:
##
##   head         a round in the head crits, at the gun's crit multiplier (2x a pistol)
##   body         a round in the chest does not
##   crouched     the head moved down with the crouch and still crits there
##   no dice      the same shot twice lands the same; the gun's RNG is never asked
##   shield       with a shield over the flesh the headshot lands plain -- absorbed --
##                and once the shield is gone it crits again

const RANGE := 6.0

var _pass := 0
var _fail := 0
var target: Pawn
var gun: GunController
var aim: Node3D
var _last := {}


func _init() -> void:
	print("crit probe")
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


## One round at `point` from RANGE in front of the target. Returns GunController.fired's info.
func _shoot_at(point: Vector3) -> Dictionary:
	var from := point + Vector3(0.0, 0.0, RANGE)
	aim.global_transform = Transform3D(Basis.looking_at(point - from, Vector3.UP), from)
	_last = {}
	gun._fire_one()
	return _last


func _dealt(info: Dictionary) -> float:
	var r: DamageSystem.DamageResult = info.get("result")
	return r.dealt if r != null else -1.0


func _crit(info: Dictionary) -> bool:
	var r: DamageSystem.DamageResult = info.get("result")
	return r != null and r.was_crit


func _run() -> void:
	# Head crits are off in the game until enemies are figures; this tests the system.
	Pawn.head_crits = true
	var floor := StaticBody3D.new()
	floor.collision_layer = Layers.WORLD
	var fs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(40.0, 1.0, 40.0)
	fs.shape = box
	floor.add_child(fs)
	root.add_child(floor)
	floor.global_position = Vector3(0.0, -0.5, 0.0)

	target = Pawn.spawn(root, Vector3.ZERO, 1, true, 100000.0)
	aim = Node3D.new()
	root.add_child(aim)
	gun = GunController.new()
	gun.rng = RandomNumberGenerator.new()
	gun.rng.seed = 7
	gun.aim = aim
	root.add_child(gun)
	var res := GunGenerator.generate(GunPlaceholderParts.build_library(), 11,
			WeaponClass.builtin(&"pistol"), 1, 1)
	var gi := GunInstance.from_result(res)
	gun.equip(gi)
	gun.gun.stats[&"accuracy"] = 1.0
	gun.fired.connect(func(info: Dictionary) -> void: _last = info)
	await _ticks(6)

	var spots := target.body.get_node(^"CritSpots") as CritSpots
	var dmg: float = gun.gun.stats[&"damage"]
	var mult: float = gun.gun.stats[&"crit_mult"]

	var head := _shoot_at(spots.centre_of(&"head"))
	_ok("a round in the head crits", _crit(head), "dealt %.2f" % _dealt(head))
	_ok("at the gun's crit multiplier (%.1fx)" % mult, absf(_dealt(head) - dmg * mult) < 0.01,
			"%.2f vs %.2f x %.1f" % [_dealt(head), dmg, mult])
	_ok("a pistol's is 2x", is_equal_approx(mult, 2.0))
	var body := _shoot_at(target.chest())
	_ok("a round in the chest does not", not _crit(body) and absf(_dealt(body) - dmg) < 0.01,
			"dealt %.2f" % _dealt(body))

	var state_before := gun.rng.state
	var again := _shoot_at(spots.centre_of(&"head"))
	_ok("the same shot lands the same, with no dice", _crit(again)
			and is_equal_approx(_dealt(again), _dealt(head)) and gun.rng.state == state_before)

	# Crouched: the head comes down with the body, and so does the spot.
	var standing_head := spots.centre_of(&"head")
	target.intents.crouch = true
	await _ticks(4)
	var low_head := spots.centre_of(&"head")
	var ducked := _shoot_at(low_head)
	_ok("crouched, the head moved down and still crits there",
			low_head.y < standing_head.y - 0.3 and _crit(ducked),
			"head %.2f -> %.2f" % [standing_head.y, low_head.y])
	var old_spot := _shoot_at(standing_head + Vector3(0.0, 0.0, 0.0))
	_ok("and the air where the head was is not a crit", not _crit(old_spot))
	target.intents.crouch = false
	await _ticks(4)

	# A shield over the flesh absorbs the crit; with it gone, crits come back.
	var shielded := Pawn.spawn(root, Vector3(4.0, 0.0, 0.0), 1, true, 100000.0)
	var shield := DefenseLayer.new()
	shield.layer_type = &"shield"
	shield.max_value = dmg * 2.5
	var flesh := shielded.health.layer_configs[0]
	shielded.health.layer_configs = [shield, flesh]
	shielded.health.reset()
	await _ticks(4)
	var sspots := shielded.body.get_node(^"CritSpots") as CritSpots
	var on_shield := _shoot_at(sspots.centre_of(&"head"))
	var r: DamageSystem.DamageResult = on_shield.get("result")
	_ok("with a shield up the headshot lands plain", r != null and not r.was_crit and r.crit_absorbed
			and absf(r.dealt - dmg) < 0.01, "dealt %.2f" % (r.dealt if r != null else -1.0))
	_shoot_at(sspots.centre_of(&"head"))
	_shoot_at(sspots.centre_of(&"head"))
	_ok("the shield breaks under plain hits", shielded.health.top_layer_type() == &"health",
			"top now %s" % shielded.health.top_layer_type())
	var bare := _shoot_at(sspots.centre_of(&"head"))
	_ok("and with it gone the head crits again", _crit(bare))

	print("crit probe: %d ok, %d FAIL" % [_pass, _fail])
	# Free the world before quitting: tearing down live physics bodies inside quit()
	# crashes the engine on exit.
	if gun.gun != null and not gun.gun.is_inside_tree():
		gun.gun.free()
	for c in root.get_children():
		c.queue_free()
	await _ticks(2)
	quit(1 if _fail > 0 else 0)
