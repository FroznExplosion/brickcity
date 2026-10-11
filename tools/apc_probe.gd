extends SceneTree

## Probe for the APC (TransportTruck kind &"apc"; Docs/AIVehicles.md 4, 6 step 2)
## and vehicles as cover (VehicleCover).
##
##     godot --headless --path . --script tools/apc_probe.gd
##
## A. Cover the AI knows: a line through its hull counts bricks, one to its own
##    middle does not; it is no wall to the walking map; driven off, the cover
##    goes with it. A soldier in the open with an enemy ahead finds cover in its
##    lee (CoverSearch).
## B. Armour: a person's round does a twelfth, a rocket all of it.
## C. Sent past an enemy in the open, it stops at contact, short of its goal,
##    and its gun hits the enemy.
## D. Moving cover: told its squad, it goes and stands between them and the
##    threat, at a walk.
## E. Zones: rockets into its front kill the engine (it stops); into its turret,
##    the gun (it does not fire).
## F. The player at the wheel has its gun: the trigger is theirs.

const Arena := preload("res://tools/ai_arena.gd")

var _pass := 0
var _fail := 0
var a: Arena
var _tick := 0
var _stage := ""
var _t0 := 0.0
var _log := {}
var apc: TransportTruck
var squad: Squad
var p: Pawn


func _init() -> void:
	print("apc probe")
	a = Arena.new(self, 53)
	physics_frame.connect(_on_tick)


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _forget(x: Pawn) -> void:
	if x == null or not is_instance_valid(x):
		return
	a.s.pawns.erase(x)
	for team in [0, 1]:
		a.s.knowledge_of(team).contacts.erase(x.get_instance_id())
	x.body.process_mode = Node.PROCESS_MODE_DISABLED
	x.body.position += Vector3.DOWN * 500.0


func _apc(at: Vector3, yaw: float, team := 1) -> TransportTruck:
	_clear()
	var gi := GunInstance.from_result(GunGenerator.generate(a.lib, 7, WeaponClass.builtin(&"lmg"), 1))
	var t := TransportTruck.make(a.s, root, at, yaw, &"apc", gi, a.structure_hit, a.s.rng)
	t.team = team
	return t


func _clear() -> void:
	if apc != null and is_instance_valid(apc):
		apc.queue_free()
	apc = null
	if squad != null:
		for so in squad.members:
			if is_instance_valid(so):
				_forget(so.pawn)
	squad = null
	_forget(p)
	p = null


func _rocket(at: Vector3, amount := 240.0) -> void:
	var pk := DamagePacket.new(amount, null, null)
	pk.scale = &"explosive"
	pk.hit_position = at
	DamageSystem.resolve(pk, apc)


func _begin(stage: String) -> void:
	_stage = stage
	_t0 = a.s.now()
	_log.clear()
	match stage:
		"cover":
			print("A. cover")
			apc = _apc(Vector3(0.0, 0.0, 0.0), 0.0)
		"cover_moved":
			apc.global_position += Vector3(12.0, 0.0, 0.0)
		"search":
			apc = _apc(Vector3(60.0, 0.0, 0.0), 0.0)
		"armour":
			print("B. armour")
			apc = _apc(Vector3(-60.0, 0.0, 0.0), 0.0)
			var before := apc.health.total_current()
			var rifle := DamagePacket.new(100.0, null, null)
			rifle.scale = &"person"
			rifle.hit_position = apc.global_position + Vector3(-1.5, 1.0, 0.0)
			DamageSystem.resolve(rifle, apc)
			var r := before - apc.health.total_current()
			before = apc.health.total_current()
			_rocket(apc.global_position + Vector3(-1.5, 1.0, 0.0), 100.0)
			var k := before - apc.health.total_current()
			_ok("a person's round does a twelfth; a rocket all of it", absf(r - 8.0) < 0.5 and absf(k - 100.0) < 0.5,
					"%.1f and %.1f of 100" % [r, k])
		"contact":
			print("C. contact")
			apc = _apc(Vector3(0.0, 0.0, 150.0), 0.0)
			# The enemy in the open 60 m along its way; its goal 120 m on.
			p = a.player(Vector3(0.0, 0.0, 90.0), 1e6, false, 0)
			_log["hp0"] = p.health.total_current()
			apc.cargo = [&"rifleman", &"rifleman"] as Array[StringName]
			apc.send(Vector3(0.0, 0.0, 30.0))
		"escort":
			print("D. moving cover")
			apc = _apc(Vector3(-100.0, 0.0, 100.0), 0.0)
			# Its squad 10 m to its side, the enemy 50 m ahead of them.
			var members: Array[Soldier] = []
			for i in 3:
				var so := a.soldier(Vector3(-90.0 + i * 1.5, 0.0, 100.0), 1, 80 + i)
				so.process_mode = Node.PROCESS_MODE_DISABLED
				members.append(so)
			squad = Squad.make(a.s, root, members, 1)
			p = a.player(Vector3(-88.5, 0.0, 50.0), 1e6, false, 0)
			a.s.knowledge_of(1).heard(p, p.feet(), a.s.now())
			apc.state = "arrived"
			apc.escort = squad
		"zones":
			print("E. zones")
			apc = _apc(Vector3(100.0, 0.0, -100.0), 0.0)
			var n := 0
			while apc.can_drive() and n < 10:
				apc.health.reset()
				_rocket(apc.global_transform * Vector3(0.0, 1.2, -apc.size.z * 0.5 - 0.05))
				n += 1
			_ok("rockets into its front kill the engine", not apc.can_drive(), "%d rockets" % n)
			n = 0
			while apc.bricks.has(&"gun") and n < 10:
				apc.health.reset()
				_rocket(apc.turret.global_transform * Vector3(0.0, 0.3, 0.0))
				n += 1
			_ok("into its turret: the gun", not apc.bricks.has(&"gun"), "%d rockets" % n)
			_log["shots"] = 0
			apc.gun.fired.connect(func(_i: Dictionary) -> void: _log["shots"] += 1)
			apc.take_player(1)
			apc.aim_point = apc.global_position + Vector3(0.0, 1.0, -40.0)
			apc.fire_main = true
		"player":
			print("F. the player")
			apc = _apc(Vector3(-100.0, 0.0, -100.0), 0.0, 0)
			_log["took"] = apc.take_player(0)
			_log["shots"] = 0
			apc.gun.fired.connect(func(_i: Dictionary) -> void: _log["shots"] += 1)
			apc.aim_point = apc.global_position + Vector3(0.0, 1.0, -40.0)
			apc.fire_main = true


func _check(el: float) -> bool:
	match _stage:
		"cover":
			if el < 0.5:
				return false
			var w := a.s.ai_world
			var across := w.bricks_between(Vector3(-6.0, 1.0, 0.0), Vector3(6.0, 1.0, 0.0))
			var to_it := w.bricks_between(Vector3(-6.0, 1.0, 0.0), apc.global_position + Vector3.UP * 1.0)
			_ok("a line through its hull counts bricks; one to its own middle does not", across > 0 and to_it == 0,
					"%d through, %d to it" % [across, to_it])
			var stand := a.s.ai_nav.can_stand(a.s.ai_nav.snap(Vector3(0.0, 0.0, 0.0)))
			_ok("it is no wall to the walking map", stand)
			return true
		"cover_moved":
			if el < 0.5:
				return false
			var w := a.s.ai_world
			var old := w.bricks_between(Vector3(-6.0, 1.0, 0.0), Vector3(6.0, 1.0, 0.0))
			var now := w.bricks_between(Vector3(6.0, 1.0, 0.0), Vector3(18.0, 1.0, 0.0))
			_ok("driven off, the cover goes with it", old == 0 and now > 0, "%d where it was, %d where it is" % [old, now])
			return true
		"search":
			if el < 0.3:
				return false
			var threat_eye := Vector3(60.0, 1.6, -45.0)
			var from := Vector3(64.5, 0.0, 2.0)
			var found := CoverSearch.find(a.s, from, threat_eye)
			var spot: Vector3 = found.get("cover", Vector3.INF)
			var behind := spot != Vector3.INF and spot.z > apc.global_position.z \
					and absf(spot.x - apc.global_position.x) < apc.size.x * 0.5 + 1.2
			_ok("a soldier in the open finds cover in its lee", behind and spot.distance_to(apc.feet()) < 6.0,
					"cover at %v (%s)" % [spot, found.get("kind", "none")])
			return true
		"armour":
			return true
		"contact":
			if apc.state == "driving" and el < 25.0:
				return false
			if el < float(_log.get("stop_at", el)) + 3.0:
				_log["stop_at"] = _log.get("stop_at", el)
				return false
			var d := apc.feet().distance_to(p.feet())
			_ok("sent past an enemy in the open, it stops at contact", apc.stopped_because == "contact"
					and d <= TransportTruck.CONTACT_STOP + 6.0, "%s, %.0f m off it" % [apc.stopped_because, d])
			_ok("and its gun hits the enemy", p.health.total_current() < float(_log.hp0),
					"%.0f hp off; %s" % [float(_log.hp0) - p.health.total_current(), apc.hold_fire])
			return true
		"escort":
			if el < 10.0:
				return false
			var mid := Vector3.ZERO
			for so in squad.members:
				mid += so.pawn.feet()
			mid /= squad.members.size()
			var to_threat := (p.feet() - mid).normalized()
			var ahead := (apc.feet() - mid).dot(to_threat)
			var side := ((apc.feet() - mid) - to_threat * ahead).length()
			_ok("told its squad, it stands between them and the threat", ahead > 3.0 and ahead < 10.0 and side < 3.0,
					"%.1f m ahead of them, %.1f m to the side" % [ahead, side])
			return true
		"zones":
			if el < 1.0:
				return false
			_ok("and does not fire", int(_log.shots) == 0, "%d rounds" % _log.shots)
			return true
		"player":
			if el < 1.0:
				return false
			_ok("the player at the wheel has its gun", bool(_log.took) and apc.player_guns() and int(_log.shots) > 0,
					"%d rounds" % _log.shots)
			return true
	return true


func _on_tick() -> void:
	_tick += 1
	if _tick == 2:
		_begin("cover")
		return
	if _tick < 2:
		return
	a.tick()
	if not _check(a.s.now() - _t0):
		return
	var order := ["cover", "cover_moved", "search", "armour", "contact", "escort", "zones", "player"]
	var i := order.find(_stage)
	if i + 1 < order.size():
		_begin(order[i + 1])
		return
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
