class_name TransportTruck
extends CharacterBody3D
## A truck that brings a squad (Docs/AIVehicles.md, step 1).
##
## The first vehicle, and the least of one: a body that drives, that can be shot
## to pieces, and that carries a squad's worth of soldiers to the fight. What it
## carries is CARGO -- the kinds of unit the commander bought -- not bodies in
## seats: the soldiers are put down at the tailgate when it stops (its host's
## dismount), and until then they are the truck. Shoot the truck to pieces on
## the way and they die with it.
##
## It drives one path, asked for once, on the vehicle map (VehicleNav: only
## where a truck fits, up nothing steeper than a kerb) to the nearest place to
## where it was sent that a truck can reach -- the walking map's, as before, if
## there is none -- at DRIVE speed, turning no faster than TURN; it stops and
## lets them out when it is within DROP of where it was sent, when its path runs
## out, or when it has been stuck for STUCK seconds.
##
## Anybody can drive one (Halo's Warthog, R14): M at an empty one of yours gets
## in, WASD drives it as a car -- it steers only while it rolls -- and M gets
## out. An enemy's is taken at the cab (`hijack`, melee beside its front half):
## the squad in the back is put out at the tailgate there and then, and the
## truck is yours. Its open bed takes six RIDERS of its side (VehicleDeck),
## who shoot from it. Driven by the player it is a target everybody senses and
## shoots (make_target); rounds are what hurt it, as they always did.
##
## The APC (`kind` &"apc", Docs/AIVehicles.md 6 step 2) is the same body
## armoured and armed: slower, ten times the hit points behind armour (APC_ARMOUR),
## a turret with a heavy machine gun it aims itself from what it sees (a
## player at the wheel aims it as a tank's), and it stops to let its squad out
## at CONTACT -- the enemy in its own sight within CONTACT_STOP -- not at the
## goal. Then it is MOVING COVER: told its squad (`escort`), it keeps itself
## between them and the threat, at a walk, and its hull is cover the AI knows
## (VehicleCover: a box in AIWorld, so a soldier's cover search finds its lee).
##
## Its body is BRICKS (VehicleBricks), in damage zones (AIVehicles.md 4.2): its
## ENGINE under the hood -- shot out, it does not drive (a squad on its way is
## let out where it stops) -- and its WHEELS -- two shot off, it goes at half
## speed. Rounds knock bricks off where they land, as on a tank. Moving cover
## is the step after this one (AIVehicles.md 4).

signal arrived(truck: TransportTruck)
signal wrecked(truck: TransportTruck)
## Taken at the cab by `by`.
signal hijacked(by: Pawn)
## A damage zone of its bricks is gone (VehicleBricks.zone_lost).
signal damaged(zone: StringName)

const DRIVE := 9.0
const TURN := 1.6
const DROP := 22.0
const STUCK := 3.0
const HP := 400.0
## What each kind is: its box (width, height, length), top speed, hit points, the
## vehicle map it drives, and how much of a hit by each scale gets through.
const KINDS := {
	&"truck": {"size": Vector3(2.3, 2.4, 5.6), "drive": 9.0, "hp": 400.0, "nav": &"truck",
			"armour": {}, "cover": 2.0},
	&"apc": {"size": Vector3(2.8, 2.5, 6.3), "drive": 7.0, "hp": 1800.0, "nav": &"apc",
			"armour": {&"person": 0.08, &"explosive": 1.0, &"mech": 0.6}, "cover": 6.0},
}
## The APC: it sees from its turret this far, its gun reaches this far, and it
## stops for its squad when it sees the enemy this near.
const SIGHT := 90.0
const GUN_RANGE := 70.0
const CONTACT_STOP := 45.0
const SENSE_EVERY := 0.25
const GUN_TURN := deg_to_rad(90.0)
const GUN_TOL := deg_to_rad(4.0)
## A round from its gun against a body (GunController.damage_mult).
const GUN_MULT := 2.5
## Moving cover: it keeps this far ahead of its squad towards the threat, and
## goes no faster than a walk doing it.
const COVER_AHEAD := 6.0
const COVER_SPEED := 2.5
const GRAVITY := 20.0
const SIZE := Vector3(2.3, 2.4, 5.6)
const CLEARANCE := 0.55
const WHEEL := 0.45
## Hit points of a brick, by zone; a zone works down to this share of its bricks.
const BRICK_HP := {&"body": 60.0, &"engine": 45.0, &"wheels": 50.0}
const ZONE_KEEP := {&"engine": 0.5, &"wheels": 0.6}
## How far from where a round struck its damage reaches into the bricks.
const BRICK_REACH := {&"person": 0.5, &"mech": 0.8, &"explosive": 1.1}
## On what wheels it has left, once it has lost them.
const LIMP := 0.5
## Up-speed for a kerb: about half a metre at this gravity.
const KERB_POP := 4.5
## Seconds it backs up the first time it is stuck.
const REVERSE := 1.5
## An empty truck leaves the board this long after unloading.
const LEAVE_AFTER := 30.0
## Driven by a player: top speed back, how fast it gets up to speed and stops,
## and the speed at which it steers fully (slower, it steers less).
const BACK_SPEED := 4.0
const ACCEL := 6.0
const BRAKE := 14.0
const STEER_FULL := 3.0
## Its cab is taken from within this of its front half's sides.
const HIJACK_REACH := 2.0
## The open bed: six riders' feet, two by three.
const RIDE_SPOTS: Array[Vector3] = [Vector3(-0.55, 1.05, 0.1), Vector3(0.55, 1.05, 0.1),
		Vector3(-0.55, 1.05, 1.1), Vector3(0.55, 1.05, 1.1), Vector3(-0.55, 1.05, 2.1),
		Vector3(0.55, 1.05, 2.1)]

var services: AIServices
var team := 1
## &"truck" or &"apc" (KINDS).
var kind := &"truck"
var size := SIZE
var drive := DRIVE
## The APC's gun and turret; null on a truck.
var gun: GunController
var turret: Node3D
var muzzle: Node3D
var gun_yaw := 0.0
## Where the gun should point (world), INF to hold; and its trigger -- the
## player's keys, or its own eyes.
var aim_point := Vector3.INF
var fire_main := false
var fire_coax := false
## The squad it let out, that it covers (an APC's moving cover).
var escort: Squad
## Its hull as cover the AI knows (VehicleCover).
var cover: VehicleCover
## Why its gun is not firing, for logs: "" when it is.
var hold_fire := ""
var _next_sense := 0.0
var _sees := {}
## The kinds of unit riding in it.
var cargo: Array[StringName] = []
var goal := Vector3.INF
## idle, driving, arrived, wrecked -- and taken: a player's, driven or parked.
var state := "idle"
## A player is driving it.
var player_in := false
## -1 (back) .. 1 (forward), and -1 (right) .. 1 (left): the player's keys.
var throttle := 0.0
var steer := 0.0
## What everybody else senses and shoots at while a player drives it (make_target).
var pawn: Pawn
## Riders in the bed (VehicleDeck); Rodeo's name, as on a tank.
var rodeo: VehicleDeck
## Bodies it has run down (Splatter), and when each was last hit.
var splats := 0
var _splat_last := {}
var _speed := 0.0
var health: HealthPool
## Why it stopped: "there", "end of path", "stuck", "no way".
var stopped_because := ""
## What it was pressed against when it stuck.
var stuck_on: Array[String] = []
## Which map its path is on: "vehicle", or "foot" with no road on the vehicle map.
var road := ""
## Its body (VehicleBricks): zones of bricks.
var bricks: VehicleBricks
var _smoke: CPUParticles3D

var _path := PackedVector3Array()
var _path_id := -1
## The map its path is on: an AINav, or on a planet a nav net map (PlanetNavMap).
var _nav = null
var _wp := 0
var _from := Vector3.ZERO
var _moved_at := 0.0
var _yaw := 0.0
var _reverse_until := -INF
var _reversals := 0


## A truck (or, `p_kind` &"apc", an APC armed with `p_gun` -- a GunInstance --
## whose structure hits go to `on_hit`) on the ground at `at`, facing `yaw`.
static func make(s: AIServices, parent: Node, at: Vector3, yaw: float, p_kind := &"truck",
		p_gun: GunInstance = null, on_hit := Callable(), rng: RandomNumberGenerator = null) -> TransportTruck:
	var t := TransportTruck.new()
	t.kind = p_kind
	var k: Dictionary = KINDS[p_kind]
	t.size = k.size
	t.drive = float(k.drive)
	t.name = "APC" if p_kind == &"apc" else "Truck"
	t.services = s
	# Solid to pawns and to rounds, like wreckage: not brick, so not cover the
	# AI knows of yet (AIVehicles.md: brick-built is the next step).
	t.collision_layer = Layers.DEBRIS
	t.collision_mask = Layers.WORLD | Layers.STRUCTURE | Layers.DEBRIS
	t.floor_max_angle = deg_to_rad(40.0)
	t.floor_snap_length = 0.6
	t.floor_stop_on_slope = true
	# The body a clearance off the ground, on four spheres for wheels: the
	# ground is laid in plates, and a flat-bottomed box stops dead at the first
	# 14 cm step where a wheel rolls up it.
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(t.size.x, t.size.y - CLEARANCE, t.size.z)
	shape.shape = box
	shape.position = Vector3.UP * (CLEARANCE + box.size.y * 0.5)
	t.add_child(shape)
	for x in [-t.size.x * 0.4, t.size.x * 0.4]:
		for z in [-t.size.z * 0.35, t.size.z * 0.3]:
			var ws := CollisionShape3D.new()
			var sph := SphereShape3D.new()
			sph.radius = WHEEL
			ws.shape = sph
			ws.position = Vector3(x, WHEEL, z)
			t.add_child(ws)
	t._build_look()
	t.rodeo = VehicleDeck.attach(t, RIDE_SPOTS, Vector3.INF, Vector2(t.size.x * 0.5, t.size.z * 0.5))
	var pool := HealthPool.new()
	pool.name = "HealthPool"
	var layer := DefenseLayer.new()
	layer.max_value = float(k.hp)
	pool.layer_configs = [layer]
	t.add_child(pool)
	t.health = pool
	t.set_meta(&"takes_packet", t)
	if p_kind == &"apc":
		t._arm(p_gun, on_hit, rng)
	parent.add_child(t)
	t.cover = VehicleCover.make(s, Vector3(t.size.x, t.size.y - CLEARANCE * 0.5, t.size.z), float(k.cover))
	t.global_position = at
	t._yaw = yaw
	t.rotation.y = yaw
	pool.died.connect(t._on_wrecked)
	t.add_to_group(&"trucks")
	return t


## The APC's turret and gun.
func _arm(g: GunInstance, on_hit: Callable, rng: RandomNumberGenerator) -> void:
	gun = GunController.new()
	gun.name = "Gun"
	gun.aim = muzzle
	gun.rng = rng if rng != null else RandomNumberGenerator.new()
	gun.exclude = [get_rid()] as Array[RID]
	gun.on_structure_hit = on_hit
	gun.damage_mult = GUN_MULT
	if g != null and g.weapon_class != null:
		gun.damage_mult *= WeaponClass.enemy_damage_scale(g.weapon_class.id)
	add_child(gun)
	if g != null:
		g.visible = false
		muzzle.add_child(g)
		gun.equip(g)


func is_apc() -> bool:
	return kind == &"apc"


## Does the player drive it, aim its gun? (VehiclePilot asks a tank the same.)
func player_drives() -> bool:
	return player_in


func player_guns() -> bool:
	return player_in and gun != null


## Drive to `to` and let the cargo out there.
func send(to: Vector3) -> void:
	goal = to
	state = "driving"
	_path = PackedVector3Array()
	_ask_path(false)
	_from = global_position
	_moved_at = services.now()


func _ask_path(on_foot: bool) -> void:
	var vn = services.vehicle_nav(StringName(KINDS[kind].nav)) if not on_foot else null
	var to := VehicleNav.reach_point(vn, goal) if vn != null else Vector3.INF
	var from: Vector3 = vn.snap(feet()) if vn != null else Vector3.INF
	if vn != null and to != Vector3.INF and vn.can_stand(from):
		_nav = vn
		road = "vehicle"
		_path_id = vn.request_path(from, to, 8.0, 40000)
	else:
		# The walking map; on a planet the nav net's, across regions.
		_nav = services.nav_net if services.nav_net != null else services.ai_nav
		road = "foot"
		_path_id = _nav.request_path(global_position, goal, 8.0, 20000)


func feet() -> Vector3:
	return global_position


# --- the frame (Docs/Planets.md 11.7) ---------------------------------------
#
# On a planet the yaw is measured in a tangent frame carried along the curve;
# in the flat game the frame is the identity and every line takes its old path.

var frame := Basis.IDENTITY
var up := Vector3.UP


func _local(v: Vector3) -> Vector3:
	return v if frame == Basis.IDENTITY else frame.inverse() * v


## The yaw that faces along world `to`, in the frame.
func _yaw_to(to: Vector3) -> float:
	var l := _local(to)
	return atan2(-l.x, -l.z)


## Turn the body to `_yaw` (in the frame).
func _face() -> void:
	if frame == Basis.IDENTITY:
		rotation.y = _yaw
	else:
		global_transform.basis = frame * Basis(Vector3.UP, _yaw)


## The velocity along the ground set to `v` (along up kept).
func _set_flat(v: Vector3) -> void:
	velocity = Gravity.flat(v, up) + up * Gravity.vert(velocity, up)


## Rolling to a stop, axis by axis as it always did: in the frame on a planet.
func _ease_stop(rate: float) -> void:
	if frame == Basis.IDENTITY:
		velocity.x = move_toward(velocity.x, 0.0, rate)
		velocity.z = move_toward(velocity.z, 0.0, rate)
		return
	var lv := _local(velocity)
	lv.x = move_toward(lv.x, 0.0, rate)
	lv.z = move_toward(lv.z, 0.0, rate)
	velocity = frame * lv


func _physics_process(delta: float) -> void:
	up = Gravity.up_at(global_position)
	if Gravity.planet != null:
		frame = Gravity.carry(frame, up)
		up_direction = up
		_face()
	if not is_on_floor():
		velocity += Gravity.down_at(global_position) * GRAVITY * delta
	else:
		var vv := Gravity.vert(velocity, up)
		if Gravity.planet != null and vv <= Gravity.floor_rise():
			vv = Gravity.standing_vert()
		velocity = Gravity.with_vert(velocity, up, maxf(vv, 0.0) if Gravity.planet == null else vv)
	if cover != null:
		cover.update(self, feet() + up * (size.y + CLEARANCE * 0.5) * 0.5)
	if gun != null:
		_gunner(delta)
	if player_in:
		_drive_keys(delta)
		return
	if state == "arrived" and escort != null and is_apc() and not is_wrecked():
		_cover_squad(delta)
		return
	if state != "driving":
		_ease_stop(drive * delta * 2.0)
		move_and_slide()
		return
	var now := services.now()
	if now < _reverse_until:
		# Backing off what it was stuck on, before trying the way again.
		var back := global_transform.basis.z
		_set_flat(back * drive * 0.35)
		move_and_slide()
		_from = global_position
		_moved_at = now
		return
	if _path.is_empty():
		var st: int = _nav.get_status(_path_id)
		if st == AINav.PENDING:
			move_and_slide()
			return
		if st != AINav.DONE:
			_nav.release(_path_id)
			if road == "vehicle":
				_ask_path(true)   # no road for a truck: the walking map's way
				move_and_slide()
				return
			_arrive("no way")   # let them out here and walk
			return
		_path = _nav.get_path(_path_id)
		_wp = 1 if _path.size() > 1 else 0
		# Face the way out before moving off: turning on the spot swings the
		# tail into whatever it was parked beside.
		if _wp < _path.size():
			var first := _path[mini(_wp + 2, _path.size() - 1)] - global_position
			if Gravity.flat(first, up).length() > 0.5:
				_yaw = _yaw_to(first)
				_face()
	var at := global_position
	if Gravity.flat(goal - at, up).length() < DROP:
		_arrive("there")
		return
	if not can_drive():
		_arrive("engine")
		return
	# An APC lets its squad out at contact, behind it, not at the goal.
	if is_apc() and _contact_within(CONTACT_STOP):
		_arrive("contact")
		return
	while _wp < _path.size() and Gravity.flat(_path[_wp] - at, up).length() < 2.0:
		_wp += 1
	# A flyer coming down ahead (Airspace pad): hold short until it is down and gone.
	if services.airspace != null and services.airspace.blocks(at - global_transform.basis.z * (size.z * 0.5 + 4.0), size.x):
		stopped_because = "a landing ahead"
		_coast(delta)
		_from = at
		_moved_at = now
		return
	if _wp >= _path.size():
		_arrive("end of path")
		return
	var to := _path[_wp] - at
	var want := _yaw_to(to)
	var turn := clampf(wrapf(want - _yaw, -PI, PI), -TURN * delta, TURN * delta)
	_yaw += turn
	_face()
	# Slower through a sharp turn.
	var speed := top_speed() * clampf(1.0 - absf(wrapf(want - _yaw, -PI, PI)) / PI, 0.3, 1.0)
	var fwd := -global_transform.basis.z
	_set_flat(fwd * speed)
	move_and_slide()
	_run_down(fwd)
	# A kerb: pressed against something while on the ground and going nowhere,
	# a pop up the way wheels climb one. Not a wall: a wall is still a wall,
	# and STUCK lets them out there.
	if is_on_floor() and is_on_wall() and Gravity.flat(velocity, up).length() < speed * 0.3:
		velocity = Gravity.with_vert(velocity, up, KERB_POP)
	if at.distance_to(_from) > 1.0:
		_from = at
		_moved_at = now
	elif now - _moved_at > STUCK and _reversals < 1:
		# The first time: back off and try again -- a corner clipped on a turn
		# is usually cleared by a length of reverse.
		_reversals += 1
		_reverse_until = now + REVERSE
	elif now - _moved_at > STUCK:
		# What it is up against, for the log: the thing a vehicle map would
		# have routed round.
		for i in get_slide_collision_count():
			var col := get_slide_collision(i)
			var who := col.get_collider()
			var layer := PhysicsServer3D.body_get_collision_layer(col.get_collider_rid())
			stuck_on.append("%s layer %d at %v n %v" % [who.get_class() if who != null else "server body",
					layer, col.get_position() - global_position, col.get_normal()])
		_arrive("stuck")


## The player's keys, as a car: throttle up to speed, steering that bites only
## while it rolls (and turns the other way backing up).
func _drive_keys(delta: float) -> void:
	var go := throttle if can_drive() else 0.0
	var want := go * (top_speed() if go > 0.0 else BACK_SPEED * top_speed() / drive)
	var rate := BRAKE if (want == 0.0 or signf(want) != signf(_speed)) and absf(_speed) > 0.1 else ACCEL
	_speed = move_toward(_speed, want, rate * delta)
	var bite := clampf(absf(_speed) / STEER_FULL, 0.0, 1.0) * signf(_speed)
	_yaw = wrapf(_yaw + clampf(steer, -1.0, 1.0) * TURN * bite * delta, -PI, PI)
	_face()
	var fwd := -global_transform.basis.z
	_set_flat(fwd * _speed)
	move_and_slide()
	if absf(throttle) > 0.1 and is_on_floor() and is_on_wall() \
			and Gravity.flat(velocity, up).length() < absf(_speed) * 0.3:
		velocity = Gravity.with_vert(velocity, up, KERB_POP)
	# Into a wall it stops: what it went at is what it keeps.
	_speed = Gravity.flat(velocity, up).dot(Gravity.flat(fwd, up))
	_run_down(fwd)


func _run_down(fwd: Vector3) -> void:
	splats += Splatter.run_down(services, self, team, feet(), fwd, Vector2(size.x * 0.5, size.z * 0.5),
			Vector2(velocity.x, velocity.z).dot(Vector2(fwd.x, fwd.z)), _splat_last)


func is_wrecked() -> bool:
	return state == "wrecked"


func _exit_tree() -> void:
	if cover != null:
		cover.remove()


## Does it drive: an engine.
func can_drive() -> bool:
	return bricks == null or bricks.has(&"engine")


## How fast it goes on what wheels it has.
func top_speed() -> float:
	return drive * (1.0 if bricks == null or bricks.has(&"wheels") else LIMP)


## A hit through DamageSystem (the "takes_packet" meta): on its bricks where it
## struck (a splash round its middle: a brick of its outside), and its health.
func take_packet(packet: DamagePacket) -> DamageSystem.DamageResult:
	var res := DamageSystem.DamageResult.new()
	if is_wrecked():
		return res
	var before := health.total_current()
	var scale := MechLayers.scale_of(packet)
	var reach := float(BRICK_REACH.get(scale, 0.5))
	var dmg := packet.amount * float((KINDS[kind].armour as Dictionary).get(scale, 1.0))
	if packet.hit_position == Vector3.ZERO or packet.hit_position.distance_to(global_position) < 0.05:
		bricks.hit_anywhere(dmg, reach)
	else:
		bricks.hit(packet.hit_position, dmg, reach)
	if not is_wrecked():
		health.apply_impact(dmg, &"")
	res.dealt = before - health.total_current()
	res.killed = health.is_dead()
	return res


# --- the APC: its eyes, its gun, moving cover ---------------------------------------

## The enemy in its own sight within `r`?
func _contact_within(r: float) -> bool:
	for id in _sees:
		var h = instance_from_id(id)
		if h != null and is_instance_valid(h) and (h as Pawn).feet().distance_to(feet()) <= r:
			return true
	return false


func eye() -> Vector3:
	return global_position + up * (size.y + 0.5)


## All round from its turret, within SIGHT, to the chest or the eye.
func can_see(h: Pawn) -> bool:
	if h == null or not is_instance_valid(h) or h.has_meta(&"in_vehicle") or h.has_meta(&"in_mech"):
		return false
	var e := eye()
	if e.distance_to(h.chest()) > SIGHT:
		return false
	var ex: Array[RID] = [get_rid(), h.body.get_rid()]
	for p in [h.chest(), h.eye.global_position]:
		var q := PhysicsRayQueryParameters3D.create(e, p, Layers.HITSCAN_MASK, ex)
		if get_world_3d().direct_space_state.intersect_ray(q).is_empty() \
				and not services.ai_world.smoke_blocks(e, p):
			return true
	return false


## Look (SENSE_EVERY), tell its side; and, nobody else at the gun, aim it at the
## side's best contact in sight within GUN_RANGE and fire when on it -- never
## with a friend near the line.
func _gunner(delta: float) -> void:
	if is_wrecked():
		gun.set_trigger(false)
		return
	var now := services.now()
	if now >= _next_sense:
		_next_sense = now + SENSE_EVERY
		var k := services.knowledge_of(team)
		for h in services.hostiles_of(team):
			if can_see(h):
				k.saw(h, h.feet(), now, self)
				_sees[h.get_instance_id()] = true
			else:
				k.lost_sight(h, self)
				_sees.erase(h.get_instance_id())
	if not player_in:
		fire_main = false
		var c := services.knowledge_of(team).best(now)
		if c == null or c.pawn == null or not is_instance_valid(c.pawn) or not c.visible \
				or c.pawn.health == null or c.pawn.health.is_dead():
			hold_fire = "no contact"
		elif c.pos.distance_to(feet()) > GUN_RANGE:
			hold_fire = "out of range"
		else:
			aim_point = c.pawn.chest()
			if _friend_near_line(muzzle.global_position, aim_point):
				hold_fire = "friend in the line"
			elif aim_error() > GUN_TOL:
				hold_fire = "turning"
			else:
				hold_fire = ""
				fire_main = true
	_turn_gun(delta)
	gun.set_trigger(fire_main and (bricks == null or bricks.has(&"gun")))


func _turn_gun(delta: float) -> void:
	if aim_point == Vector3.INF:
		return
	var to := _local(aim_point - turret.global_position)
	var want := wrapf(atan2(-to.x, -to.z) - (rotation.y if frame == Basis.IDENTITY else _yaw), -PI, PI)
	var rate := GUN_TURN if bricks == null or bricks.has(&"gun") else 0.0
	gun_yaw = wrapf(gun_yaw + clampf(wrapf(want - gun_yaw, -PI, PI), -rate * delta, rate * delta), -PI, PI)
	turret.rotation.y = gun_yaw
	muzzle.rotation.x = clampf(atan2(to.y, Vector2(to.x, to.z).length()), deg_to_rad(-10.0), deg_to_rad(40.0))


func aim_error() -> float:
	if aim_point == Vector3.INF:
		return 0.0
	return (-muzzle.global_basis.z).angle_to((aim_point - muzzle.global_position).normalized())


func _friend_near_line(from: Vector3, to: Vector3) -> bool:
	var seg := to - from
	var len2 := seg.length_squared()
	if len2 < 0.01:
		return false
	for p in services.pawns:
		if not is_instance_valid(p) or p.team != team or p == pawn or p.health == null or p.health.is_dead():
			continue
		var x := p.chest()
		var t := clampf((x - from).dot(seg) / len2, 0.0, 1.0)
		if t < 0.97 and x.distance_to(from + seg * t) < 2.0:
			return true
	return false


## Moving cover: between its squad and the threat, COVER_AHEAD past their middle,
## at a walk -- straight there while the way is open, holding when it is not.
func _cover_squad(delta: float) -> void:
	var mates := escort.alive()
	if mates.is_empty() or not can_drive():
		_coast(delta)
		return
	var mid := Vector3.ZERO
	for so in mates:
		mid += so.pawn.feet()
	mid /= mates.size()
	var c := services.knowledge_of(team).best(services.now())
	var threat := c.pos if c != null else goal
	if threat == Vector3.INF:
		_coast(delta)
		return
	var dir := Gravity.flat(threat - mid, up)
	if dir.length() < 1.0:
		_coast(delta)
		return
	var want := mid + dir.normalized() * COVER_AHEAD
	var to := Gravity.flat(want - global_position, up)
	if to.length() < 2.5:
		_coast(delta)
		return
	_steer_to(want, minf(COVER_SPEED, top_speed()), delta)


## Slowing to a stop.
func _coast(delta: float) -> void:
	_ease_stop(drive * delta * 2.0)
	move_and_slide()


## Towards `at` at `speed`, turning no faster than TURN; backwards when it is
## behind (short moves of cover need no three-point turns).
func _steer_to(at: Vector3, speed: float, delta: float) -> void:
	var to := at - global_position
	var want := _yaw_to(to)
	var off := wrapf(want - _yaw, -PI, PI)
	var back := absf(off) > PI * 0.6
	if back:
		off = wrapf(off + PI, -PI, PI)
	_yaw += clampf(off, -TURN * delta, TURN * delta)
	_face()
	var fwd := -global_transform.basis.z
	var v := speed * (-1.0 if back else 1.0) * clampf(1.0 - absf(off) / PI, 0.3, 1.0)
	_set_flat(fwd * v)
	move_and_slide()
	_run_down(fwd)


func _on_zone_lost(zone: StringName) -> void:
	if is_wrecked():
		return
	if zone == &"engine":
		_smoke_from(Vector3(0.0, 1.6, -size.z * 0.42))
	damaged.emit(zone)


func _smoke_from(at: Vector3) -> void:
	if _smoke != null:
		return
	var s := CPUParticles3D.new()
	s.name = "Smoke"
	s.amount = 20
	s.lifetime = 2.5
	s.direction = Vector3.UP
	s.spread = 12.0
	s.initial_velocity_min = 1.0
	s.initial_velocity_max = 2.0
	s.gravity = Gravity.up_at(global_position) * 0.4
	var m := SphereMesh.new()
	m.radius = 0.3
	m.height = 0.6
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.12, 0.12, 0.12, 0.55)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.material = mat
	s.mesh = m
	s.position = at
	add_child(s)
	_smoke = s


## Nobody at the wheel: a player's truck parked, or nobody's.
func is_empty() -> bool:
	return not player_in and state != "driving"


func forward() -> Vector3:
	return -global_transform.basis.z


## Where the driver's eye is: in the cab, on the left.
func eye_interpolated() -> Vector3:
	var x := get_global_transform_interpolated()
	return x.origin + x.basis * (Vector3(-0.5, 1.95, -2.2) if is_apc() else Vector3(-0.45, 1.75, -1.6))


## Is `p` -- on foot, of another side -- beside the cab (its front half)?
func can_hijack(p: Pawn) -> bool:
	if p == null or not is_instance_valid(p) or is_wrecked() or p.team == team or player_in:
		return false
	if p.has_meta(&"riding") or p.has_meta(&"aboard") or p.has_meta(&"in_vehicle"):
		return false
	return can_reach(p)


## Taken at the cab (Halo's hijack): the squad in the back is put out there and
## then (its host's dismount, through `arrived`), and the truck is `by`'s side's,
## stopped. Its host puts a player in.
func hijack(by: Pawn) -> void:
	if is_wrecked():
		return
	if state == "driving":
		_arrive("hijacked")
	state = "taken"
	if team != by.team:
		rodeo.all_off("changed side")
		team = by.team
		if pawn != null and is_instance_valid(pawn):
			pawn.team = team
	hijacked.emit(by)


## A player gets in at the wheel: a truck nobody is driving -- an empty one of
## any side (it changes side, R14); one on its way somewhere is hijacked.
func take_player(p_team: int) -> bool:
	if is_wrecked() or player_in or state == "driving":
		return false
	if p_team != team:
		rodeo.all_off("changed side")
		team = p_team
	state = "taken"
	player_in = true
	make_target()
	pawn.team = team
	if services != null and not services.pawns.has(pawn):
		services.add_pawn(pawn)
	return true


func release_player() -> void:
	player_in = false
	throttle = 0.0
	steer = 0.0
	# Parked, it is nobody's target: a truck, not a soldier.
	if pawn != null and is_instance_valid(pawn) and services != null:
		services.pawns.erase(pawn)
		for t in [0, 1]:
			services.knowledge_of(t).contacts.erase(pawn.get_instance_id())


## The Pawn that stands for it while a player drives it -- not a heavy.
func make_target() -> Pawn:
	if pawn != null and is_instance_valid(pawn):
		return pawn
	var e := Node3D.new()
	e.name = "Eye"
	e.position = Vector3(0.0, 1.75, -1.6)
	add_child(e)
	var p := Pawn.new()
	p.name = "Pawn"
	p.team = team
	p.health = health
	p.eye = e
	p.process_mode = Node.PROCESS_MODE_DISABLED
	p.stand_height = size.y
	p._height = size.y
	p.set_meta(&"aggro_kind", "pilot")
	p.set_meta(&"vehicle", self)
	add_child(p)
	pawn = p
	return p


## Where the driver gets out: beside the cab on the left.
func mount_point() -> Vector3:
	var at := feet() + global_transform.basis * Vector3(-size.x * 0.5 - 1.0, 0.0, -1.4)
	if services != null and services.ai_nav != null:
		var snapped := services.ai_nav.snap(at)
		if snapped.distance_to(at) < 2.0:
			return snapped
	return at


## Is `p` beside the cab: its front half, either side.
func can_reach(p: Pawn) -> bool:
	var local := global_transform.basis.inverse() * (p.feet() - feet())
	return absf(local.x) < size.x * 0.5 + HIJACK_REACH and local.z < 0.5 and local.z > -size.z * 0.5 - 1.0 \
			and local.y > -1.0 and local.y < 2.0


func _arrive(why: String) -> void:
	if state != "driving":
		return
	stopped_because = why
	state = "arrived"
	# Unloaded, it goes: an empty truck is in the next one's way.
	if not is_apc():
		get_tree().create_timer(LEAVE_AFTER).timeout.connect(func() -> void:
			if is_instance_valid(self) and state == "arrived" and cargo.is_empty() and rodeo.rider_count() == 0:
				queue_free())
	if _path_id >= 0 and _nav != null:
		_nav.release(_path_id)
	arrived.emit(self)


## Is there room for a truck at `at` (feet), any way round -- a circle of its
## length, less a hand's breadth, clear of everything a truck hits?
static func room_at(world: World3D, at: Vector3) -> bool:
	var q := PhysicsShapeQueryParameters3D.new()
	var c := CylinderShape3D.new()
	# A full length and a metre: room to turn, and clear of another truck
	# parked there (a tail swung into one stuck the next).
	c.radius = SIZE.z + 1.0
	c.height = SIZE.y - CLEARANCE
	q.shape = c
	q.transform = Transform3D(Gravity.tangent_basis(at), at + Gravity.up_at(at) * (CLEARANCE + c.height * 0.5 + 0.05))
	q.collision_mask = Layers.STRUCTURE | Layers.DEBRIS | Layers.FALLING | Layers.WORLD
	return world.direct_space_state.intersect_shape(q, 1).is_empty()


## Where the cargo gets out: behind and beside the truck, on the side away from
## `threat` (its lee), as far out as a body can stand.
func tailgate_points(threat: Vector3, n: int) -> Array[Vector3]:
	var out: Array[Vector3] = []
	var b := global_transform.basis
	var side := b.x if (b.x.dot(global_position - threat) > 0.0) else -b.x
	var rear := b.z
	var base := global_position + rear * (size.z * 0.5 + 1.0)
	for i in n * 3:
		if out.size() >= n:
			break
		var p := base + side * (0.8 + 0.9 * (i % 3)) + rear * (0.9 * (i / 3))
		p = services.ai_nav.snap(p)
		if services.ai_nav.can_stand(p):
			out.append(p)
	return out


func _on_wrecked() -> void:
	state = "wrecked"
	throttle = 0.0
	steer = 0.0
	fire_main = false
	if gun != null:
		gun.set_trigger(false)
	if bricks != null:
		bricks.burn()
	_smoke_from(Vector3(0.0, 1.6, -size.z * 0.3))
	if pawn != null and is_instance_valid(pawn) and services != null:
		services.pawns.erase(pawn)
	wrecked.emit(self)


## Its body in bricks (VehicleBricks), by zone. Studs across (x) and along (z,
## forward is -z), plates up from the feet:
##   wheels   four, a stud wide and two long, two courses, under the corners;
##   chassis  two plates the whole length over them, the bed's floor;
##   engine   the front three studs, from the chassis to the hood's top;
##   cab      behind it, up to the roof; the bed's sides and tailgate one
##            course high, open on top for riders.
func _build_look() -> void:
	if is_apc():
		_build_apc()
		return
	var olive := Color(0.33, 0.38, 0.24)
	var dark := Color(0.12, 0.12, 0.12)
	var grille := Color(0.26, 0.24, 0.18)
	var glass := Color(0.35, 0.45, 0.5)
	bricks = VehicleBricks.attach(self)
	var b := bricks.add_part(self)
	var hp: Dictionary = BRICK_HP
	for x in [-3.0, 2.0]:
		for z in [-6.5, 3.5]:
			bricks.fill(b, &"wheels", Vector3(x, 0, z), Vector3(x + 1.0, 6, z + 2.0), dark, hp[&"wheels"])
	bricks.fill(b, &"body", Vector3(-3, 6, -5), Vector3(3, 8, 8), olive, hp[&"body"])
	bricks.fill(b, &"engine", Vector3(-3, 6, -8), Vector3(3, 11, -5), grille, hp[&"engine"], true)
	bricks.fill(b, &"body", Vector3(-3, 8, -5), Vector3(3, 11, -1), olive, hp[&"body"], true)
	bricks.fill(b, &"body", Vector3(-3, 11, -5), Vector3(3, 15, -4), glass, hp[&"body"], true)
	bricks.fill(b, &"body", Vector3(-3, 11, -4), Vector3(3, 15, -1), olive, hp[&"body"], true)
	bricks.fill(b, &"body", Vector3(-3, 15, -5), Vector3(3, 17, -1), olive, hp[&"body"], true)
	bricks.fill(b, &"body", Vector3(-3, 8, -1), Vector3(-2, 11, 8), olive, hp[&"body"])
	bricks.fill(b, &"body", Vector3(2, 8, -1), Vector3(3, 11, 8), olive, hp[&"body"])
	bricks.fill(b, &"body", Vector3(-2, 8, 7), Vector3(2, 11, 8), olive, hp[&"body"], true)
	for z in ZONE_KEEP:
		bricks.keep(z, ZONE_KEEP[z])
	bricks.finish()
	bricks.zone_lost.connect(_on_zone_lost)


## The APC in bricks, by zone (studs across and along, forward -z; plates up):
##   wheels   four a side, a stud wide and two long, two courses;
##   hull     a course of belly between them, then a box 8 studs wide to 13
##            plates up, its back a door; the engine its front four studs;
##   gun      a turret 3 studs square on the roof, and its barrel.
func _build_apc() -> void:
	var sand := Color(0.4, 0.39, 0.29)
	var dark := Color(0.12, 0.12, 0.12)
	var grille := Color(0.27, 0.25, 0.2)
	bricks = VehicleBricks.attach(self)
	var b := bricks.add_part(self)
	var hp := {&"hull": 120.0, &"engine": 90.0, &"wheels": 70.0, &"gun": 80.0}
	for x in [-4.0, 3.0]:
		for z in [-8.0, -4.0, 2.0, 6.0]:
			bricks.fill(b, &"wheels", Vector3(x, 0, z), Vector3(x + 1.0, 6, z + 2.0), dark, hp[&"wheels"])
	bricks.fill(b, &"hull", Vector3(-3, 3, -9), Vector3(3, 6, 9), sand, hp[&"hull"])
	bricks.fill(b, &"engine", Vector3(-3, 6, -9), Vector3(3, 13, -5), grille, hp[&"engine"], true)
	bricks.fill(b, &"hull", Vector3(-4, 6, -9), Vector3(-3, 13, -5), sand, hp[&"hull"])
	bricks.fill(b, &"hull", Vector3(3, 6, -9), Vector3(4, 13, -5), sand, hp[&"hull"])
	bricks.fill(b, &"hull", Vector3(-4, 6, -5), Vector3(4, 13, 9), sand, hp[&"hull"])
	turret = Node3D.new()
	turret.name = "Turret"
	turret.position = Vector3(0.0, 13 * VehicleBricks.PLATE, -0.5)
	add_child(turret)
	var tu := bricks.add_part(turret)
	bricks.fill(tu, &"gun", Vector3(-1.5, 0, -1.5), Vector3(1.5, 4, 1.5), sand, hp[&"gun"], true)
	muzzle = Node3D.new()
	muzzle.name = "Muzzle"
	muzzle.position = Vector3(0.0, 2 * VehicleBricks.PLATE, -1.5 * VehicleBricks.STUD)
	turret.add_child(muzzle)
	var g := bricks.add_part(muzzle)
	bricks.fill(g, &"gun", Vector3(-0.5, -1, -6), Vector3(0.5, 1, 0), dark, hp[&"gun"])
	bricks.keep(&"engine", 0.5)
	bricks.keep(&"wheels", 0.6)
	bricks.keep(&"gun", 0.5)
	bricks.finish()
	bricks.zone_lost.connect(_on_zone_lost)
