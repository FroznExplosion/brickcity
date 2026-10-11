extends SceneTree

## Probe for the vehicles' brick bodies and damage zones, the tank's seats and
## its crushing (Docs/AIVehicles.md 3, 4.1, 4.2).
##
##     godot --headless --path . --script tools/vehicle_bricks_probe.gd
##
## A. Body: it is built of bricks in seven zones, studs on top; a rifle round
##    chips a brick and knocks none off; a rocket knocks bricks off.
## B. A track: rockets at its side throw it -- it then turns on the spot but
##    does not drive.
## C. The engine: rockets at its back deck kill it -- it neither drives nor
##    turns, and the turret turns by hand (slowly).
## D. The gun: rockets at the mantlet shoot the cannon off; the machine gun
##    still fires.
## E. The ammo rack: rockets at the turret's back get through its wall and the
##    rack cooks off -- the tank is wrecked, its turret thrown, its crew out
##    badly hurt, a body near it hit. Not the first rocket.
## F. Seats: the player at the wheel of a tank with a gunner of theirs drives
##    and the gunner has the gun; switched, the player has the gun and the
##    gunner drives them towards the fight.
## G. Crushing: driven into a wall three courses high it breaks through and
##    out the other side; into one five courses high it stops, and the wall
##    stands.
## H. The tank's map goes through a low wall the truck's goes round.
## I. The truck: rifle rounds into its hood shoot the engine out -- on its way
##    with a squad, it stops and lets them out; blasts at its wheels leave it
##    half its speed.

const Arena := preload("res://tools/ai_arena.gd")
const STUD := 0.35

var _pass := 0
var _fail := 0
var a: Arena
var _tick := 0
var _stage := ""
var _t0 := 0.0
var _log := {}
var t: Tank
var br: TankBrain
var crew: Array[Soldier] = []
var _lost: Array[StringName] = []


func _init() -> void:
	print("vehicle bricks probe")
	a = Arena.new(self, 47)
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


func _tank(at: Vector3, yaw: float, team := 0, seats: Array = []) -> Tank:
	_clear()
	var main := GunInstance.from_result(GunGenerator.generate(a.lib, 5, WeaponClass.builtin(&"rocket_launcher"), 1))
	var mg := GunInstance.from_result(GunGenerator.generate(a.lib, 6, WeaponClass.builtin(&"lmg"), 1))
	var tk := Tank.make(a.s, root, at, yaw, team, main, mg, a.structure_hit, a.s.rng)
	a.s.add_pawn(tk.make_target())
	br = TankBrain.attach(a.s, tk)
	for seat in seats:
		var so := a.soldier(at + Vector3(5.0, 0.0, 0.0), team, 60 + int(seat))
		tk.board(so.pawn, int(seat), true)
		crew.append(so)
	_lost.clear()
	tk.damaged.connect(func(z: StringName) -> void: _lost.append(z))
	return tk


func _clear() -> void:
	if t != null and is_instance_valid(t):
		_forget(t.pawn)
		for s in t.crew:
			if t.crew[s] != null and is_instance_valid(t.crew[s]):
				(t.crew[s] as Pawn).body.queue_free()
		t.queue_free()
	t = null
	for so in crew:
		if is_instance_valid(so):
			_forget(so.pawn)
	crew.clear()


## A rocket's worth (`amount`, explosive) landing at `at` on the tank.
func _rocket(at: Vector3, amount := 240.0) -> void:
	var pk := DamagePacket.new(amount, null, null)
	pk.scale = &"explosive"
	pk.hit_position = at
	DamageSystem.resolve(pk, t)


## Rockets at `local` (in `part`'s space) until `zone` is lost or `max_n` have
## landed. Returns how many it took.
func _rockets_until(part: Node3D, local: Vector3, zone: StringName, max_n := 8) -> int:
	var n := 0
	while n < max_n and t.bricks.has(zone) and not t.is_wrecked():
		_rocket(part.global_transform * local)
		n += 1
	return n


func _begin(stage: String) -> void:
	_stage = stage
	_t0 = a.s.now()
	_log.clear()
	match stage:
		"body":
			print("A. body")
			t = _tank(Vector3(0.0, 0.0, 0.0), 0.0)
			var vb := t.bricks
			var studs := 0
			for n in t.find_children("Studs*", "MultiMeshInstance3D", true, false):
				studs += (n as MultiMeshInstance3D).multimesh.instance_count
			var zones_ok := true
			for z in [&"hull", &"track_l", &"track_r", &"engine", &"turret", &"ammo", &"gun"]:
				zones_ok = zones_ok and vb.zones.has(z) and int(vb.zones[z].total) > 0
			_ok("built of bricks, in its seven zones, studs on top", vb.bricks.size() >= 120 and zones_ok and studs > 100,
					"%d bricks, %d studs" % [vb.bricks.size(), studs])
			var side := t.global_transform * Vector3(-Tank.HULL.x * 0.5, -Tank.HEIGHT * 0.5 + 0.5, 0.0)
			var rifle := DamagePacket.new(8.0, null, null)
			rifle.scale = &"person"
			rifle.hit_position = side
			var b := vb.nearest(side, 0.6)
			var hp0 := b.hp
			DamageSystem.resolve(rifle, t)
			_ok("a rifle round chips a brick and knocks none off", vb.knocked == 0 and b.hp < hp0,
					"%.2f -> %.2f" % [hp0, b.hp])
			_rocket(side)
			_ok("a rocket knocks bricks off", vb.knocked >= 2, "%d off" % vb.knocked)
		"track":
			print("B. a track")
			t = _tank(Vector3(60.0, 0.0, 0.0), 0.0)
			t.take_player(0)
			var hull := t.get_node(^"Hull") as Node3D
			_log["n"] = _rockets_until(hull, Vector3(-4.6 * STUD, 0.4, 0.0), &"track_l")
			_log["at"] = t.feet()
			_log["yaw"] = t.yaw
			t.throttle = 1.0
			t.steer = 1.0
		"engine":
			print("C. the engine")
			t = _tank(Vector3(120.0, 0.0, 0.0), 0.0)
			t.take_player(0)
			var hull := t.get_node(^"Hull") as Node3D
			_log["n"] = _rockets_until(hull, Vector3(0.0, 15.2 * 0.14, 6.5 * STUD), &"engine")
			_log["at"] = t.feet()
			_log["yaw"] = t.yaw
			_log["turret"] = t.turret_yaw
			t.throttle = 1.0
			t.steer = 1.0
			# Something to turn the turret to, behind it.
			t.aim_point = t.feet() + Vector3(0.0, 2.0, 40.0)
		"gun":
			print("D. the gun")
			t = _tank(Vector3(180.0, 0.0, 0.0), 0.0)
			t.take_player(0)
			_log["n"] = _rockets_until(t.mantlet, Vector3(0.0, 0.0, -0.6), &"gun")
			_log["shells"] = t.shells
			_log["coax"] = 0
			t.coax.fired.connect(func(_i: Dictionary) -> void: _log["coax"] += 1)
			t.aim_point = t.feet() + Vector3(0.0, 1.0, -60.0)
			t.fire_main = true
			t.fire_coax = true
		"ammo":
			print("E. the ammo rack")
			t = _tank(Vector3(240.0, 0.0, 0.0), 0.0, 1, [Tank.Seat.DRIVER, Tank.Seat.GUNNER])
			br.enabled = false
			var near := Pawn.spawn(root, t.feet() + Vector3(5.0, 0.0, 0.0), 0, true, 1000.0)
			Soldier._greybox(near, 0)
			a.s.add_pawn(near)
			_log["near"] = near
			_log["out"] = []
			t.crew_out.connect(func(p: Pawn) -> void: (_log["out"] as Array).append(p))
			var first := t.bricks.knocked
			_rocket(t.turret.global_transform * Vector3(0.0, 0.2, 4.05 * STUD))
			_log["after_one"] = t.is_wrecked()
			_log["first_off"] = t.bricks.knocked - first
			_log["n"] = 1 + _rockets_until(t.turret, Vector3(0.0, 0.2, 4.05 * STUD), &"ammo", 9)
		"splash":
			print("   a splash round its middle")
			t = _tank(Vector3(300.0 - 20.0, 0.0, 60.0), 0.0)
			var pk := DamagePacket.new(240.0, null, null)
			pk.scale = &"explosive"
			pk.hit_position = t.global_position
			DamageSystem.resolve(pk, t)
			_ok("a splash with no point lands on a brick of its outside", t.bricks.knocked >= 1,
					"%d off" % t.bricks.knocked)
		"seats":
			print("F. seats")
			t = _tank(Vector3(0.0, 0.0, 120.0), 0.0, 0, [Tank.Seat.GUNNER])
			var took := t.take_player(0)
			_ok("the player at the wheel, one of theirs on the gun: they drive, it shoots",
					took and t.player_drives() and not t.player_guns() and t.ai_guns() and not t.ai_drives())
			var swapped := t.switch_seat()
			_ok("switched: the player has the gun, the gunner drives", swapped
					and t.player_seat == Tank.Seat.GUNNER and t.player_guns() and t.ai_drives()
					and t.crew[Tank.Seat.GUNNER] == null)
			# An enemy heard far off: the driver takes the player to it.
			var foe := Pawn.spawn(root, Vector3(0.0, 0.0, 30.0), 1, true, 1e6)
			Soldier._greybox(foe, 1)
			a.s.add_pawn(foe)
			a.s.knowledge_of(0).heard(foe, foe.feet(), a.s.now())
			_log["foe"] = foe
			_log["d0"] = t.feet().distance_to(foe.feet())
		"crush":
			print("G. crushing")
			t = _tank(Vector3(-150.0, 0.0, 0.0), 0.0)
			t.take_player(0)
			# A wall three courses high across its way, 12 m ahead; another, five
			# high, in a second lane.
			_log["low"] = a.bricks(Vector3i(int(-160.0 / STUD), 0, int(-12.0 / STUD)), Vector3i(int(20.0 / STUD), 3, 1))
			_log["high"] = a.bricks(Vector3i(int(-110.0 / STUD), 0, int(-12.0 / STUD)), Vector3i(int(20.0 / STUD), 5, 1))
			_log["wall_z"] = -12.0
			t.throttle = 1.0
		"crush_high":
			t = _tank(Vector3(-100.0, 0.0, 0.0), 0.0)
			t.take_player(0)
			_log["alive0"] = _alive(_log_high)
			t.throttle = 1.0
		"map":
			print("H. the tank's map")
			# A low wall 40 m long with no gap, at z = 80 m.
			a.bricks(Vector3i(int(-220.0 / STUD), 0, int(80.0 / STUD)), Vector3i(int(40.0 / STUD), 3, 1))
			var tank_nav := a.s.vehicle_nav(&"tank")
			var truck_nav := a.s.vehicle_nav(&"truck")
			var from := Vector3(-200.0, 0.0, 70.0)
			var to := Vector3(-200.0, 0.0, 90.0)
			var tk := tank_nav.find_path(tank_nav.snap(from), tank_nav.snap(to), 60000)
			var tr := truck_nav.find_path(truck_nav.snap(from), truck_nav.snap(to), 60000)
			_ok("the tank's way is through the low wall", not tk.is_empty() and _length(tk) < 26.0,
					"%d points, %.1f m" % [tk.size(), _length(tk)])
			_ok("the truck's is round its end", not tr.is_empty() and _length(tr) > 40.0,
					"%d points, %.1f m" % [tr.size(), _length(tr)])
		"truck":
			print("I. the truck")
			_clear()
			truck = TransportTruck.make(a.s, root, Vector3(100.0, 0.0, -150.0), 0.0)
			truck.cargo = [&"rifleman", &"rifleman"] as Array[StringName]
			truck.send(Vector3(100.0, 0.0, -250.0))
			_log["lost"] = []
			truck.damaged.connect(func(z: StringName) -> void: (_log["lost"] as Array).append(z))
			_log["rounds"] = 0


var _log_high := -1
var truck: TransportTruck


static func _length(path: PackedVector3Array) -> float:
	var n := 0.0
	for i in range(1, path.size()):
		n += path[i - 1].distance_to(path[i])
	return n


func _alive(c: int) -> int:
	var n := 0
	for b in a.w.get_block_boxes(c):
		if bool(b.alive):
			n += 1
	return n


func _check(el: float) -> bool:
	match _stage:
		"body", "splash", "map":
			return true
		"track":
			if el < 1.5:
				return false
			t.throttle = 0.0
			t.steer = 0.0
			var moved := Vector2(t.feet().x - _log.at.x, t.feet().z - _log.at.z).length()
			_ok("rockets at its side throw a track", not t.bricks.has(&"track_l") and _lost.has(&"track_l")
					and int(_log.n) >= 2, "%d rockets" % _log.n)
			_ok("then it turns on the spot and does not drive", moved < 0.3 and absf(wrapf(t.yaw - _log.yaw, -PI, PI)) > 0.3
					and not t.can_drive() and t.can_turn(), "moved %.2f m, turned %.2f rad" % [moved, wrapf(t.yaw - _log.yaw, -PI, PI)])
			return true
		"engine":
			if el < 1.0:
				return false
			t.throttle = 0.0
			t.steer = 0.0
			var moved := Vector2(t.feet().x - _log.at.x, t.feet().z - _log.at.z).length()
			var turned := absf(wrapf(t.turret_yaw - _log.turret, -PI, PI))
			_ok("rockets at its back deck kill the engine", not t.bricks.has(&"engine") and int(_log.n) >= 2,
					"%d rockets" % _log.n)
			_ok("then it neither drives nor turns", moved < 0.3 and absf(wrapf(t.yaw - _log.yaw, -PI, PI)) < 0.01,
					"moved %.2f m" % moved)
			_ok("and the turret turns by hand", turned > 0.05 and turned < Tank.TURRET_TURN * Tank.HAND_CRANK * 1.1,
					"%.2f rad in 1 s" % turned)
			return true
		"gun":
			if el < 1.5:
				return false
			t.fire_main = false
			t.fire_coax = false
			_ok("rockets at the mantlet shoot the cannon off", not t.bricks.has(&"gun") and _lost.has(&"gun"),
					"%d rockets" % _log.n)
			_ok("it does not fire; the machine gun does", t.shells == int(_log.shells) and int(_log.coax) > 0,
					"%d shells, %d mg rounds" % [t.shells - int(_log.shells), _log.coax])
			return true
		"ammo":
			if el < 0.5:
				return false
			var near: Pawn = _log.near
			var out: Array = _log.out
			var hurt := true
			for p in out:
				hurt = hurt and (p as Pawn).health.total_current() <= 100.0 - Tank.COOK_OFF_HURT + 0.01
			_ok("rockets at the turret's back cook the ammo off -- not the first one",
					t.is_wrecked() and t.cooked_off and not bool(_log.after_one) and int(_log.n) >= 2,
					"%d rockets, the first knocked %d off" % [_log.n, _log.first_off])
			_ok("its turret is thrown", t.turret.get_parent() is RigidBody3D and t.turret.global_position.y > t.global_position.y + 1.0,
					"turret %.1f m over the hull" % (t.turret.global_position.y - t.global_position.y))
			_ok("its crew are out, badly hurt; a body near it is hit", out.size() == 2 and hurt
					and near.health.total_current() < 1000.0, "%d out; near %.0f hp" % [out.size(), near.health.total_current()])
			_forget(near)
			return true
		"seats":
			if el < 5.0:
				return false
			var foe: Pawn = _log.foe
			var d := t.feet().distance_to(foe.feet())
			_ok("the gunner drives them towards the fight", d < float(_log.d0) - 3.0 and br.goal != Vector3.INF,
					"%.1f -> %.1f m, %s" % [_log.d0, d, br.state])
			t.switch_seat()
			_ok("switched back: they drive, it has the gun", t.player_drives() and t.ai_guns())
			t.release_player()
			_ok("out: it is the crewman's", not t.player_in and t.crew_count() == 1)
			_forget(foe)
			return true
		"crush":
			var past := t.feet().z < float(_log.wall_z) - 4.0
			if not past and el < 10.0:
				return false
			t.throttle = 0.0
			_ok("driven into a low wall it breaks through", past and t.crushes > 0,
					"%d crushes, %d of the wall's bricks left, at z %.1f" % [t.crushes, _alive(int(_log.low)), t.feet().z])
			_log_high = int(_log.high)
			return true
		"truck":
			if el < 1.0:
				return false
			# Rifle rounds into the hood until the engine is out, a few a tick.
			if truck.can_drive() and int(_log.rounds) < 200:
				for i in 3:
					var pk := DamagePacket.new(8.0, null, null)
					pk.scale = &"person"
					pk.hit_position = truck.global_transform * Vector3(0.0, 1.4, -TransportTruck.SIZE.z * 0.5 - 0.05)
					DamageSystem.resolve(pk, truck)
					_log["rounds"] += 1
				return false
			if not _log.has("out_at"):
				_log["out_at"] = el
				_log["speed0"] = truck.top_speed()
				return false
			if el < float(_log.out_at) + 0.5:
				return false
			_ok("rifle rounds into its hood shoot the engine out", not truck.can_drive()
					and (_log.lost as Array).has(&"engine") and not truck.is_wrecked(),
					"%d rounds, %d bricks off, %.0f hp left" % [_log.rounds, truck.bricks.knocked, truck.health.total_current()])
			_ok("on its way with a squad, it stops there and lets them out", truck.state == "arrived"
					and truck.stopped_because == "engine", "%s, %s" % [truck.state, truck.stopped_because])
			for z in [-6.5 + 1.0, 3.5 + 1.0]:
				for x in [-3.0, 3.0]:
					# A grenade's worth at each corner, its health kept up: the wheels,
					# not the wreck.
					truck.health.reset()
					var pk := DamagePacket.new(100.0, null, null)
					pk.scale = &"explosive"
					pk.hit_position = truck.global_transform * Vector3(x * STUD, 0.4, z * STUD)
					DamageSystem.resolve(pk, truck)
					if not truck.bricks.has(&"wheels"):
						break
				if not truck.bricks.has(&"wheels"):
					break
			_ok("blasts at its wheels leave it half its speed", not truck.bricks.has(&"wheels")
					and is_equal_approx(truck.top_speed(), float(_log.speed0) * TransportTruck.LIMP),
					"%.1f -> %.1f m/s" % [_log.speed0, truck.top_speed()])
			truck.queue_free()
			return true
		"crush_high":
			if el < 5.0:
				return false
			t.throttle = 0.0
			_ok("into one five courses high it stops, and the wall stands",
					t.feet().z > -12.0 + Tank.HULL.z * 0.5 - 1.0 and t.crushes == 0 and _alive(_log_high) == int(_log.alive0),
					"%d crushes, at z %.1f" % [t.crushes, t.feet().z])
			return true
	return true


func _on_tick() -> void:
	_tick += 1
	if _tick == 2:
		_begin("body")
		return
	if _tick < 2:
		return
	a.tick()
	if not _check(a.s.now() - _t0):
		return
	var order := ["body", "track", "engine", "gun", "ammo", "splash", "seats", "crush", "crush_high", "map", "truck"]
	var i := order.find(_stage)
	if i + 1 < order.size():
		_begin(order[i + 1])
		return
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
