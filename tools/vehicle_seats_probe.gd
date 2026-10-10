extends SceneTree

## Probe for riding on vehicles and boarding them (VehicleDeck; Docs/AIVehicles.md
## 4, AIRoster.md RO10 -- Halo's riders, boarding and hijacking).
##
##     godot --headless --path . --script tools/vehicle_seats_probe.gd
##
## A. Riders: a soldier of the player's side told to ride on the player's tank
##    walks to it and gets on; the tank drives off and it stays on its spot.
## B. From up there it shoots an enemy in sight.
## C. Off: put down beside the hull, walking again. Wrecked, riders are put
##    down alive.
## D. Boarding: the player beside an enemy's crewed tank climbs onto its deck;
##    noticed within a second; holding the hatch for PRY_SECONDS drags the
##    crew out, hurt, and the tank is empty for the player to take.
## E. An enemy soldier with the rodeo mod climbs onto the player's tank, pries
##    the hatch: the player is thrown out and the soldier has the gun.
## F. A truck: hijacked at the cab on its way in, its squad is put out there
##    and then and it is the player's; driven, it goes and steers as a car
##    (only while it rolls); its bed takes riders who stay on as it drives.
## G. Splatter: driven at speed into an enemy, it runs it down; a friend in its
##    way is spared.

const Arena := preload("res://tools/ai_arena.gd")

var _pass := 0
var _fail := 0
var a: Arena
var _tick := 0
var _stage := ""
var _t0 := 0.0
var _log := {}
var t: Tank
var tr: TransportTruck
var me: Pawn
var so: Soldier
var foe: Soldier
var crew: Array[Soldier] = []
var target: Pawn


func _init() -> void:
	print("vehicle seats probe")
	a = Arena.new(self, 44)
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


func _tank(at: Vector3, yaw: float, team: int, crewed: bool) -> Tank:
	var main := GunInstance.from_result(GunGenerator.generate(a.lib, 5, WeaponClass.builtin(&"rocket_launcher"), 1))
	var mg := GunInstance.from_result(GunGenerator.generate(a.lib, 6, WeaponClass.builtin(&"lmg"), 1))
	var tk := Tank.make(a.s, root, at, yaw, team, main, mg, a.structure_hit, a.s.rng)
	a.s.add_pawn(tk.make_target())
	TankBrain.attach(a.s, tk)
	crew.clear()
	if crewed:
		for seat in [Tank.Seat.DRIVER, Tank.Seat.GUNNER]:
			var c := a.soldier(at + Vector3(6.0, 0.0, 0.0), team, 60 + seat)
			tk.board(c.pawn, seat, true)
			crew.append(c)
	return tk


func _clear() -> void:
	for x in [me, so.pawn if so != null else null, foe.pawn if foe != null else null]:
		_forget(x)
	for c in crew:
		if is_instance_valid(c):
			_forget(c.pawn)
	crew.clear()
	if t != null and is_instance_valid(t):
		_forget(t.pawn)
		t.queue_free()
	if tr != null and is_instance_valid(tr):
		tr.queue_free()
	t = null
	tr = null
	me = null
	so = null
	foe = null


func _spot(v: Node3D, i: int) -> Vector3:
	var d: VehicleDeck = v.rodeo
	return v.feet() + Basis(Vector3.UP, v.rotation.y) * d.spots[i]


func _begin(stage: String) -> void:
	_stage = stage
	_t0 = a.s.now()
	_log.clear()
	match stage:
		"ride":
			print("A. riders")
			t = _tank(Vector3(20.0, 0.0, 20.0), 0.0, 0, false)
			t.take_player(0)
			so = a.soldier(Vector3(30.0, 0.0, 24.0), 0, 21)
			so.ride_on(t)
		"shoot":
			print("B. it shoots from the deck")
			# A standing enemy that does nothing but stand: something to shoot.
			target = Pawn.spawn(root, t.feet() + Vector3(0.0, 0.0, -30.0), 1, true, 1e6)
			Soldier._greybox(target, 1)
			a.s.add_pawn(target)
			_log["hp"] = target.health.total_current()
		"off":
			print("C. off")
			_forget(target)
			t.rodeo.get_off(so.pawn, "jumped")
			_log["moved_from"] = so.pawn.feet()
		"board":
			print("D. boarding")
			_clear()
			t = _tank(Vector3(0.0, 0.0, 0.0), 0.0, 1, true)
			me = a.player(Vector3(2.6, 0.0, 1.0))
			_log["climbed"] = t.rodeo.climb(me)
			_log["noticed_at"] = INF
			t.rodeo.noticed.connect(func(_p: Pawn) -> void: _log["noticed_at"] = a.s.now() - _t0)
			t.rodeo.hijacked.connect(func(by: Pawn) -> void: _log["hijacked_by"] = by)
			t.rodeo.planting = true
		"thrown":
			print("E. an enemy boards the player's tank")
			_clear()
			t = _tank(Vector3(0.0, 0.0, 0.0), 0.0, 0, false)
			t.take_player(0)
			_log["thrown"] = false
			t.player_thrown.connect(func() -> void: _log["thrown"] = true)
			so = a.soldier(Vector3(-12.0, 0.0, 10.0), 1, 23)
			so.rodeo = true
		"truck":
			print("F. a truck")
			_clear()
			tr = TransportTruck.make(a.s, root, Vector3(0.0, 0.0, 0.0), 0.0)
			tr.cargo = [&"rifleman", &"rifleman", &"rifleman"] as Array[StringName]
			_log["arrived"] = ""
			tr.arrived.connect(func(x: TransportTruck) -> void:
				_log["arrived"] = x.stopped_because
				_log["cargo_then"] = x.cargo.size())
			tr.send(Vector3(0.0, 0.0, -80.0))
			me = a.player(Vector3(2.8, 0.0, -20.0))
		"splat":
			print("G. splatter")
			_clear()
			tr = TransportTruck.make(a.s, root, Vector3(-40.0, 0.0, 40.0), 0.0)
			tr.team = 0
			tr.take_player(0)
			var enemy := Pawn.spawn(root, Vector3(-40.0, 0.0, 15.0), 1, true, 100.0)
			var friend := Pawn.spawn(root, Vector3(-40.0, 0.0, 5.0), 0, true, 100.0)
			for x in [enemy, friend]:
				Soldier._greybox(x, x.team)
				a.s.add_pawn(x)
			_log["enemy"] = enemy
			_log["friend"] = friend
		"bed":
			print("   its bed")
			so = a.soldier(tr.feet() + Vector3(5.0, 0.0, 3.0), 0, 24)
			foe = a.soldier(tr.feet() + Vector3(-5.0, 0.0, 3.0), 0, 25)
			so.ride_on(tr)
			foe.ride_on(tr)


func _check(el: float) -> bool:
	match _stage:
		"ride":
			if not _log.has("on_at") and so.pawn.has_meta(&"aboard"):
				_log["on_at"] = el
				_log["from"] = t.feet()
			if _log.has("on_at"):
				t.throttle = 1.0
				if el - float(_log.on_at) > 4.0:
					t.throttle = 0.0
					var i := t.rodeo.riders.find(so.pawn)
					var off := so.pawn.feet().distance_to(_spot(t, i)) if i >= 0 else INF
					_ok("a soldier told to ride walks to the tank and gets on", true, "on after %.1f s" % _log.on_at)
					_ok("the tank drives off and it rides along on its spot",
							t.feet().distance_to(_log.from) > 10.0 and off < 0.3,
							"tank went %.1f m, rider %.2f m off its spot, state %s" % [t.feet().distance_to(_log.from), off, so.state])
					return true
			elif el > 15.0:
				_ok("a soldier told to ride walks to the tank and gets on", false,
						"state %s, %.1f m from it" % [so.state, so.pawn.feet().distance_to(t.feet())])
				return true
		"shoot":
			var lost: float = float(_log.hp) - target.health.total_current()
			if lost > 0.0 or el > 8.0:
				_ok("from the deck it shoots an enemy in sight", lost > 0.0, "%.0f hp in %.1f s, state %s" % [lost, el, so.state])
				return true
		"off":
			if el > 2.0:
				var dl := so.pawn.feet().distance_to(t.feet())
				_ok("got off, it is down beside the hull and walking again",
						not so.pawn.has_meta(&"aboard") and so.pawn.body.collision_mask != 0 and so.pawn.feet().y < 0.5 and dl < 5.0,
						"%.1f m from it, at height %.2f, mask %d" % [dl, so.pawn.feet().y, so.pawn.body.collision_mask])
				# Back on, and the tank wrecked under it.
				t.rodeo.ride(so.pawn) if t.rodeo.can_ride(so.pawn) else null
				so.board_vehicle = null
				var was_on := so.pawn.has_meta(&"aboard")
				t.health.apply_impact(1e9, &"")
				await_frames_then_wreck_check(was_on)
				return true
		"board":
			if el > VehicleDeck.PRY_SECONDS + 1.0:
				var out := 0
				for c in crew:
					if not c.pawn.has_meta(&"in_vehicle") and c.pawn.health.total_current() < 100.0 \
							and not c.pawn.health.is_dead():
						out += 1
				_ok("the player beside an enemy's crewed tank climbs onto its deck", bool(_log.climbed))
				_ok("it is noticed within a second", float(_log.noticed_at) <= VehicleDeck.NOTICE_SECONDS + 0.1,
						"after %.2f s" % _log.noticed_at)
				_ok("holding the hatch drags the crew out, hurt, and the tank is empty",
						_log.get("hijacked_by") == me and out == 2 and t.is_empty() and not me.has_meta(&"riding"),
						"%d of 2 out, empty %s" % [out, t.is_empty()])
				_ok("and it is the player's to take", t.take_player(0) and t.team == 0)
				return true
		"thrown":
			if bool(_log.thrown) or el > 25.0:
				_ok("an enemy with the rodeo mod climbs onto the player's tank and pries it: the player is out",
						bool(_log.thrown) and not t.player_in, "%.1f s, state %s" % [el, so.state])
				_ok("and the soldier has the gun: the tank is its side's",
						t.team == 1 and t.crew[Tank.Seat.GUNNER] == so.pawn, "team %d" % t.team)
				return true
		"truck":
			if not _log.has("hijacked"):
				if el > 0.3 and tr.can_hijack(me):
					_log["hijacked"] = el
					tr.hijack(me)
					_log["took"] = tr.take_player(0)
					_log["from"] = tr.feet()
					_log["yaw0"] = tr.rotation.y
				elif el > 12.0:
					_ok("a truck is hijacked at the cab on its way in", false,
							"%.1f m from the player, state %s" % [tr.feet().distance_to(me.feet()), tr.state])
					return true
				return false
			var since := el - float(_log.hijacked)
			if since < 0.1:
				return false
			if not _log.has("checked_hijack"):
				_log["checked_hijack"] = true
				_ok("a truck is hijacked at the cab on its way in: its squad out there and then, and it is the player's",
						_log.arrived == "hijacked" and int(_log.get("cargo_then", -1)) == 3 and tr.team == 0
						and bool(_log.took) and tr.player_in, "stopped %s, team %d" % [_log.arrived, tr.team])
			if since < 2.5:
				tr.throttle = 1.0
				tr.steer = 0.0
				return false
			if since < 4.5:
				tr.throttle = 1.0
				tr.steer = 1.0
				return false
			tr.throttle = 0.0
			tr.steer = 0.0
			var went: float = tr.feet().distance_to(_log.from)
			var turned := absf(wrapf(tr.rotation.y - float(_log.yaw0), -PI, PI))
			_ok("driven, it goes, and steers as it rolls", went > 8.0 and turned > 0.5,
					"%.1f m, turned %.0f deg" % [went, rad_to_deg(turned)])
			return true
		"splat":
			tr.throttle = 1.0
			if tr.feet().z < 0.0 or el > 8.0:
				tr.throttle = 0.0
				var enemy: Pawn = _log.enemy
				var friend: Pawn = _log.friend
				_ok("driven at speed into an enemy, it runs it down", enemy.health.is_dead() and tr.splats >= 1,
						"enemy %.0f hp, %d splat(s)" % [enemy.health.total_current(), tr.splats])
				_ok("a friend in its way is spared", friend.health.total_current() >= 100.0)
				_forget(enemy)
				_forget(friend)
				return true
		"bed":
			if not _log.has("on_at") and tr.rodeo.rider_count() == 2:
				_log["on_at"] = el
				_log["from"] = tr.feet()
			if _log.has("on_at"):
				tr.throttle = 1.0
				if el - float(_log.on_at) > 3.0:
					tr.throttle = 0.0
					var worst := 0.0
					for p in [so.pawn, foe.pawn]:
						var i := tr.rodeo.riders.find(p)
						worst = maxf(worst, p.feet().distance_to(_spot(tr, i)) if i >= 0 else INF)
					_ok("its bed takes two riders, who stay on as it drives",
							tr.feet().distance_to(_log.from) > 8.0 and worst < 0.3,
							"on after %.1f s, it went %.1f m, worst %.2f m off a spot" % [_log.on_at,
							tr.feet().distance_to(_log.from), worst])
					return true
			elif el > 15.0:
				_ok("its bed takes two riders, who stay on as it drives", false,
						"%d on: %s / %s" % [tr.rodeo.rider_count(), so.state, foe.state])
				return true
	return false


var _wreck_wait := -1
var _wreck_was_on := false


func await_frames_then_wreck_check(was_on: bool) -> void:
	_wreck_wait = 10
	_wreck_was_on = was_on


func _on_tick() -> void:
	_tick += 1
	if _tick == 2:
		_begin("ride")
		return
	if _tick < 2:
		return
	a.tick()
	if _wreck_wait > 0:
		_wreck_wait -= 1
		if _wreck_wait == 0:
			_ok("wrecked, its riders are put down alive", _wreck_was_on and not so.pawn.has_meta(&"aboard")
					and not so.pawn.health.is_dead() and so.pawn.feet().y < 0.5,
					"was on %s, at height %.2f" % [_wreck_was_on, so.pawn.feet().y])
			_begin("board")
		return
	if not _check(a.s.now() - _t0):
		return
	if _stage == "off":
		return
	var order := ["ride", "shoot", "off", "board", "thrown", "truck", "bed", "splat"]
	var i := order.find(_stage)
	if i + 1 < order.size():
		_begin(order[i + 1])
		return
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
