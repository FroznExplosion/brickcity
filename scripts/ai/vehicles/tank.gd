class_name Tank
extends CharacterBody3D
## A tank (Docs/AIVehicles.md 2 and step 3; AIRoster.md 7, RO10): a crewed
## vehicle anybody can drive.
##
## A hull on tracks -- it turns on the spot, it does not steer like the truck --
## under a turret with a cannon that opens walls and a machine gun beside it.
## Its SEATS hold real soldiers: a driver and a gunner, put away inside as a
## mech's pilot is (out of everybody's sight and aim). The driver is what makes
## it move, the gunner what makes it shoot; when it is wrecked they climb out,
## hurt, and fight on foot. The player takes a seat of their own: the
## driver's (and the gun too while nobody has the gunner's), or the gunner's
## with one of theirs driving -- and switches between them (VehiclePilot).
##
## What drives it is four numbers and a point, filled by its brain (TankBrain)
## or the player's keys (VehiclePilot): `throttle` and `steer` for the hull,
## `aim_point` for the turret, `fire_main` and `fire_coax` for the guns.
##
## It is armour, not flesh (AIRoster.md 4.6, R15): a person's rifle scratches
## it, a rocket or a mech's gun hurts it (ARMOUR). Everybody else senses and
## shoots it through `pawn` (make_target), as they do a mech.
##
## On its deck (VehicleDeck, `rodeo`): four RIDERS of its side on the track
## covers, shooting their own guns (Halo's Scorpion), and an enemy BOARDER on
## the back deck, who pries the hatch open and drags the crew out -- the tank
## is then the boarder's (hijack).
##
## Its body is BRICKS (VehicleBricks), in damage zones (AIVehicles.md 4.2): the
## tracks, the engine, the turret, the gun and the ammo rack. A hit knocks
## bricks off where it lands, and a zone that has lost too many loses what it
## does -- a thrown track or a dead engine and it does not drive, a jammed
## turret does not turn, a gun shot off does not fire, and an ammo rack shot
## into cooks off: it is wrecked there and then, the turret thrown.
##
## It CRUSHES what is low (AIVehicles.md 3): driven into a garden wall, a
## barricade or a heap of rubble no higher than CRUSH_PLATES with nothing above
## it, it breaks through -- the bricks in front of it are worn off as a gun's
## hit is, through the same door (its `on_crush`, the city's structure hit), so
## co-op agrees. The tank's map knows this (VehicleNav: a way through a low
## wall at a cost).

signal wrecked(tank: Tank)
signal crew_out(p: Pawn)
## The player was in it when a boarder got the hatch open: they are out.
signal player_thrown
## A damage zone of its bricks is gone (VehicleBricks.zone_lost).
signal damaged(zone: StringName)

const STUD := 0.35
const COURSE := 0.42
## The hull: 9 studs wide, 17 long, 4 courses deep on a hand's clearance.
const HULL := Vector3(STUD * 9.0, COURSE * 4.0, STUD * 17.0)
const CLEARANCE := 0.4
## The turret ring's height above the feet; the turret is 2 courses on top.
const RING_Y := CLEARANCE + COURSE * 4.0
const HEIGHT := RING_Y + COURSE * 2.0
const DRIVE := 6.0
const BACK := 3.0
## Hull turn, radians a second -- on the spot as well as moving.
const TURN := 0.9
const TURRET_TURN := deg_to_rad(45.0)
const PITCH_MIN := deg_to_rad(-10.0)
const PITCH_MAX := deg_to_rad(25.0)
const HP := 3000.0
## A hit's damage to it, by the hit's scale (MechLayers.scale_of).
const ARMOUR := {&"person": 0.03, &"explosive": 1.0, &"mech": 0.6}
## Seconds between cannon rounds.
const MAIN_RELOAD := 4.0
## A cannon round to a mech's hull: a mech's weapon (GunController.damage_scale).
const MAIN_MULT := 3.0
const GRAVITY := 20.0
const KERB_POP := 4.0
## A crewman gets in from within this of the hatch (on top of the hull, from the
## left side, behind the turret).
const MOUNT_REACH := 2.2
## What climbing out of a wreck costs a crewman.
const BAIL_HURT := 25.0
## What being dragged out of the hatch by a boarder costs.
const DRAGGED_HURT := 20.0
## Low enough to crush: 3 courses (1.26 m), with nothing over it in front.
const CRUSH_PLATES := 9
const CRUSH_HEIGHT := CRUSH_PLATES * 0.14
## Seconds between crushes, and what each wears off a brick (a whole PLA one;
## stone takes three, metal four).
const CRUSH_EVERY := 0.25
const CRUSH_HP := 255
## The ammo rack going up: what it does round it, and to whoever is inside.
const COOK_OFF_RADIUS := 7.0
const COOK_OFF_DAMAGE := 150.0
const COOK_OFF_HURT := 60.0
## Hit points of a brick, by zone; and the share of a zone's bricks it keeps
## working down to.
const BRICK_HP := {&"hull": 110.0, &"track_l": 70.0, &"track_r": 70.0, &"engine": 80.0,
		&"turret": 130.0, &"ammo": 200.0, &"gun": 70.0}
const ZONE_KEEP := {&"track_l": 0.6, &"track_r": 0.6, &"engine": 0.5, &"turret": 0.4,
		&"ammo": 0.6, &"gun": 0.5}
## How far from where a round struck its damage reaches into the bricks, by scale.
const BRICK_REACH := {&"person": 0.6, &"mech": 0.9, &"explosive": 1.1}
## Turret and hull turn with a dead engine: by hand, slowly; on one track, it pivots.
const HAND_CRANK := 0.4
const ONE_TRACK_TURN := 0.4
## The deck: riders' feet on the track covers either side of the turret, front
## and back; a boarder's on the back deck behind it.
const RIDE_SPOTS: Array[Vector3] = [Vector3(-1.3, CLEARANCE + COURSE * 4.0, -2.0),
		Vector3(1.3, CLEARANCE + COURSE * 4.0, -2.0), Vector3(-1.3, CLEARANCE + COURSE * 4.0, 2.4),
		Vector3(1.3, CLEARANCE + COURSE * 4.0, 2.4)]
const BOARD_SPOT := Vector3(0.0, CLEARANCE + COURSE * 4.0, 2.55)

enum Seat { DRIVER, GUNNER }

var services: AIServices
var team := 1
var health: HealthPool
## What everybody else senses and shoots at (make_target).
var pawn: Pawn
var state := "ready"   # ready, wrecked
## Seat -> the Pawn in it (an AI crewman), or null.
var crew := {Seat.DRIVER: null, Seat.GUNNER: null}
## The player's seat, -1 for none. In the driver's they have the gun as well
## while nobody sits in the gunner's.
var player_seat := -1
## The player is in it, in either seat.
var player_in: bool:
	get:
		return player_seat >= 0
## Its body (VehicleBricks): zones of bricks.
var bricks: VehicleBricks
## The structure hit its crushing and its cook-off go through (point, dir, shot).
var on_crush: Callable
## Low walls and rubble it has driven through, crushes (a few bricks each).
var crushes := 0
## What climbing out of it costs now: more after a cook-off.
var bail_hurt := BAIL_HURT
var cooked_off := false

## -1 (back) .. 1 (forward).
var throttle := 0.0
## -1 (right) .. 1 (left): the hull's turn.
var steer := 0.0
## Where the gun should point, in world space; INF holds it where it is.
var aim_point := Vector3.INF
var fire_main := false
var fire_coax := false

var yaw := 0.0
## The turret's turn on the hull, and the gun's elevation, radians.
var turret_yaw := 0.0
var gun_pitch := 0.0
var turret: Node3D
var mantlet: Node3D
var muzzle: Node3D
var main_gun: GunController
var coax: GunController
var main_ready_at := 0.0
var shells := 0
## Riders and a boarder (VehicleDeck): Rodeo's name, so the same callers drive both.
var rodeo: VehicleDeck
## Bodies it has run down (Splatter), and when each was last hit.
var splats := 0
var _splat_last := {}
var _clock := 0.0
var _main_pulse := false
var _crush_at := 0.0
var _smoke: CPUParticles3D


## A tank on the ground at `feet`, facing `yaw`, of side `p_team`, its cannon
## and machine gun `main` and `mg` (GunInstances, the city's or a probe's).
static func make(s: AIServices, parent: Node, feet: Vector3, p_yaw: float, p_team: int,
		main: GunInstance, mg: GunInstance, on_structure_hit: Callable,
		rng: RandomNumberGenerator) -> Tank:
	var t := Tank.new()
	t.name = "Tank"
	t.services = s
	t.team = p_team
	# On the pawns' layer, as a mech is: rounds hit it, bodies bump it.
	t.collision_layer = Layers.PAWN
	t.collision_mask = Layers.WORLD | Layers.STRUCTURE | Layers.DEBRIS | Layers.PAWN
	t.floor_max_angle = deg_to_rad(40.0)
	t.floor_snap_length = 0.6
	t.floor_stop_on_slope = true
	# The origin at half its height (Pawn.feet), the hull a clearance off the
	# ground on road wheels: spheres roll up a plate's step where a box stops.
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(HULL.x, HEIGHT - CLEARANCE, HULL.z)
	shape.shape = box
	shape.position = Vector3.UP * (CLEARANCE + box.size.y * 0.5 - HEIGHT * 0.5)
	t.add_child(shape)
	for x in [-HULL.x * 0.38, HULL.x * 0.38]:
		for z in [-HULL.z * 0.38, 0.0, HULL.z * 0.38]:
			var ws := CollisionShape3D.new()
			var sph := SphereShape3D.new()
			sph.radius = CLEARANCE
			ws.shape = sph
			ws.position = Vector3(x, CLEARANCE - HEIGHT * 0.5, z)
			t.add_child(ws)
	t.on_crush = on_structure_hit
	t._build_look()
	var pool := HealthPool.new()
	pool.name = "HealthPool"
	var layer := DefenseLayer.new()
	layer.max_value = HP
	pool.layer_configs = [layer]
	t.add_child(pool)
	t.health = pool
	t.set_meta(&"takes_packet", t)
	t.main_gun = t._gun("MainGun", main, rng, on_structure_hit, &"mech", MAIN_MULT)
	t.coax = t._gun("Coax", mg, rng, on_structure_hit, &"", 1.0)
	t.main_gun.fired.connect(func(_i: Dictionary) -> void: t.shells += 1)
	t.rodeo = VehicleDeck.attach(t, RIDE_SPOTS, BOARD_SPOT, Vector2(HULL.x * 0.5, HULL.z * 0.5))
	parent.add_child(t)
	t.global_position = feet + Vector3.UP * HEIGHT * 0.5
	t.yaw = p_yaw
	t.rotation.y = p_yaw
	t.reset_physics_interpolation()
	pool.died.connect(t._on_wrecked)
	t.add_to_group(&"tanks")
	return t


func _gun(n: String, g: GunInstance, rng: RandomNumberGenerator, on_hit: Callable,
		scale: StringName, mult: float) -> GunController:
	var gc := GunController.new()
	gc.name = n
	gc.aim = muzzle
	gc.rng = rng
	gc.exclude = [get_rid()] as Array[RID]
	gc.on_structure_hit = on_hit
	gc.damage_scale = scale
	gc.damage_mult = mult
	add_child(gc)
	if g != null:
		g.visible = false
		muzzle.add_child(g)
		gc.equip(g)
	return gc


## The Pawn that stands for it to everyone who senses and shoots. Give it to
## AIServices.add_pawn. A heavy: soldiers facing it are outgunned (TacticsSense).
func make_target() -> Pawn:
	if pawn != null and is_instance_valid(pawn):
		return pawn
	var e := Node3D.new()
	e.name = "Eye"
	e.position = Vector3.UP * (HEIGHT * 0.5 - 0.2)
	add_child(e)
	var p := Pawn.new()
	p.name = "Pawn"
	p.team = team
	p.health = health
	p.gun = main_gun
	p.eye = e
	p.process_mode = Node.PROCESS_MODE_DISABLED
	p.stand_height = HEIGHT
	p._height = HEIGHT
	p.set_meta(&"aggro_kind", "mech")
	p.set_meta(&"vehicle", self)
	add_child(p)
	pawn = p
	return p


func feet() -> Vector3:
	return global_position - Vector3.UP * HEIGHT * 0.5


func forward() -> Vector3:
	return -Basis(Vector3.UP, yaw).z


func is_wrecked() -> bool:
	return state == "wrecked"


## Is anybody at the controls? A driver in it (or the player), and not wrecked.
func driven() -> bool:
	return not is_wrecked() and (player_seat == Seat.DRIVER or _alive(crew[Seat.DRIVER]))


## Is anybody on the gun?
func gunned() -> bool:
	return not is_wrecked() and (player_seat >= 0 or _alive(crew[Seat.GUNNER]))


## Does the player drive it?
func player_drives() -> bool:
	return player_seat == Seat.DRIVER


## Does the player have the gun: in the gunner's seat, or the driver's with
## nobody in the gunner's.
func player_guns() -> bool:
	return player_seat == Seat.GUNNER or (player_seat == Seat.DRIVER and not _alive(crew[Seat.GUNNER]))


## Does an AI crewman have the wheel, the gun?
func ai_drives() -> bool:
	return not is_wrecked() and player_seat != Seat.DRIVER and _alive(crew[Seat.DRIVER])


func ai_guns() -> bool:
	return not is_wrecked() and player_seat != Seat.GUNNER and _alive(crew[Seat.GUNNER])


## Is `seat` free -- nobody in it, the player or a crewman?
func seat_free(seat: int) -> bool:
	return player_seat != seat and not _alive(crew[seat])


## Can it drive: an engine, and both tracks.
func can_drive() -> bool:
	return bricks == null or (bricks.has(&"engine") and bricks.has(&"track_l") and bricks.has(&"track_r"))


## Can it turn its hull: an engine and a track (on one it pivots).
func can_turn() -> bool:
	return bricks == null or (bricks.has(&"engine") and (bricks.has(&"track_l") or bricks.has(&"track_r")))


func crew_count() -> int:
	var n := 0
	for s in crew:
		if _alive(crew[s]):
			n += 1
	return n


func is_empty() -> bool:
	return player_seat < 0 and crew_count() == 0


static func _alive(p: Variant) -> bool:
	return p != null and is_instance_valid(p) and (p as Pawn).health != null \
			and not (p as Pawn).health.is_dead()


# --- seats ------------------------------------------------------------------------

## Where a crewman stands to get in: beside the hull on its left, at the hatch.
func mount_point() -> Vector3:
	var b := Basis(Vector3.UP, yaw)
	var at := feet() - b.x * (HULL.x * 0.5 + 0.9) + b.z * 0.8
	if services != null and services.ai_nav != null:
		var snapped := services.ai_nav.snap(at)
		if Vector2(snapped.x - at.x, snapped.z - at.z).length() < 1.5:
			return snapped
	return at


func can_reach(p: Pawn) -> bool:
	var f := p.feet()
	var mp := mount_point()
	if Vector2(f.x - mp.x, f.z - mp.z).length() <= MOUNT_REACH and absf(f.y - mp.y) < 1.5:
		return true
	# Or anywhere along its side: a tank is long.
	var local := Basis(Vector3.UP, yaw).inverse() * (f - feet())
	return absf(local.x) < HULL.x * 0.5 + MOUNT_REACH and absf(local.z) < HULL.z * 0.5 \
			and absf(f.y - feet().y) < 1.5


## `p` takes `seat` -- from beside the hull, or `anywhere` for a crewman fielded
## in it. A tank anybody can drive (R14): an empty one of any side, a crewed one
## only by its own side. True if it got in.
func board(p: Pawn, seat: int, anywhere := false) -> bool:
	if p == null or is_wrecked() or not seat_free(seat) \
			or (p.health != null and p.health.is_dead()):
		return false
	if not anywhere and not can_reach(p):
		return false
	if p.team != team and not is_empty():
		return false
	_take_side(p.team)
	_stow(p)
	crew[seat] = p
	return true


## The player gets in: at `seat`, or (-1) the driver's if it is free and the
## gunner's if not. An empty tank of any side, or one of theirs with that seat
## free. False if there was no seat for them.
func take_player(p_team: int, seat := -1) -> bool:
	if is_wrecked() or player_in or (p_team != team and not is_empty()):
		return false
	if seat < 0:
		seat = Seat.DRIVER if seat_free(Seat.DRIVER) else Seat.GUNNER
	if not seat_free(seat):
		return false
	_take_side(p_team)
	player_seat = seat
	return true


## The player moves to the other seat. A crewman of theirs in it takes the
## player's old one: they swap. False if there is no other seat to have.
func switch_seat() -> bool:
	if not player_in or is_wrecked():
		return false
	var to := Seat.GUNNER if player_seat == Seat.DRIVER else Seat.DRIVER
	var other: Pawn = crew[to] if _alive(crew[to]) else null
	crew[to] = null
	if other != null:
		crew[player_seat] = other
	player_seat = to
	_quiet()
	return true


func release_player() -> void:
	player_seat = -1
	_quiet()


## Hands off: what the player was doing with the hull and the gun stops.
func _quiet() -> void:
	throttle = 0.0
	steer = 0.0
	fire_main = false
	fire_coax = false


## Everybody out, at the hatch; `hurt` for climbing out of a wreck.
func crew_get_out(hurt := 0.0) -> Array[Pawn]:
	var out: Array[Pawn] = []
	var b := Basis(Vector3.UP, yaw)
	var i := 0
	for s in crew:
		var p = crew[s]
		crew[s] = null
		if p == null or not is_instance_valid(p):
			continue
		var at := mount_point() + b.z * (1.2 * i)
		i += 1
		if services != null and services.ai_nav != null:
			at = services.ai_nav.snap(at)
		_unstow(p, at)
		if hurt > 0.0 and p.health != null:
			p.health.apply_impact(hurt, &"")
		out.append(p)
		crew_out.emit(p)
	return out


## A boarder has the hatch open (VehicleDeck): the crew are dragged out, hurt --
## the player too, if it was theirs (player_thrown) -- and a soldier who did it
## takes the gun (no goal to drive to, but the gun turns on its old side). The
## player who did it is put in by its host (VehicleDeck.hijacked).
func hijack(by: Pawn) -> void:
	if is_wrecked():
		return
	crew_get_out(DRAGGED_HURT)
	if player_in:
		release_player()
		player_thrown.emit()
	var so := by.body.get_node_or_null(^"Soldier") as Soldier if by != null and is_instance_valid(by) else null
	if so != null:
		so.rodeo_target = null
		board(by, Seat.GUNNER, true)


## A tank changes side with whoever gets into it empty.
func _take_side(p_team: int) -> void:
	if p_team == team:
		return
	# Its riders were the other side's: off.
	if rodeo != null:
		rodeo.all_off("changed side")
	team = p_team
	if pawn != null and is_instance_valid(pawn):
		pawn.team = p_team
		if services != null:
			for t in [0, 1]:
				services.knowledge_of(t).contacts.erase(pawn.get_instance_id())


func _stow(p: Pawn) -> void:
	if services != null:
		services.pawns.erase(p)
		for t in [0, 1]:
			services.knowledge_of(t).contacts.erase(p.get_instance_id())
	p.set_meta(&"stowed_layers", Vector2i(p.body.collision_layer, p.body.collision_mask))
	p.body.collision_layer = 0
	p.body.collision_mask = 0
	p.body.visible = false
	p.intents.clear()
	p.place(feet() + Vector3.UP * 1.0)
	p.body.process_mode = Node.PROCESS_MODE_DISABLED
	p.set_meta(&"in_vehicle", self)


func _unstow(p: Pawn, at: Vector3) -> void:
	p.body.process_mode = Node.PROCESS_MODE_INHERIT
	var l: Vector2i = p.get_meta(&"stowed_layers", Vector2i(Layers.PAWN, Layers.PAWN_MASK))
	p.body.collision_layer = l.x
	p.body.collision_mask = l.y
	p.body.visible = true
	p.place(at)
	p.remove_meta(&"in_vehicle")
	p.remove_meta(&"stowed_layers")
	if services != null and p.health != null and not p.health.is_dead():
		services.add_pawn(p)


# --- hits ---------------------------------------------------------------------------

## A hit through DamageSystem (the "takes_packet" meta): armour by the hit's
## scale, and the bricks where it struck (a splash round its middle: a brick of
## its outside).
func take_packet(packet: DamagePacket) -> DamageSystem.DamageResult:
	var res := DamageSystem.DamageResult.new()
	if is_wrecked():
		return res
	var before := health.total_current()
	var scale := MechLayers.scale_of(packet)
	var dmg := packet.amount * float(ARMOUR.get(scale, 1.0))
	if bricks != null:
		var reach := float(BRICK_REACH.get(scale, 0.6))
		if packet.hit_position == Vector3.ZERO or packet.hit_position.distance_to(global_position) < 0.05:
			bricks.hit_anywhere(dmg, reach)
		else:
			bricks.hit(packet.hit_position, dmg, reach)
	if not is_wrecked():
		health.apply_impact(dmg, &"")
	res.dealt = before - health.total_current()
	res.killed = health.is_dead()
	return res


## A zone of bricks gone: what it did, it does no more.
func _on_zone_lost(zone: StringName) -> void:
	if is_wrecked():
		return
	match zone:
		&"engine":
			_smoke_from(Vector3(0.0, -HEIGHT * 0.5 + 2.1, HULL.z * 0.36))
		&"ammo":
			_cook_off()
			return
	damaged.emit(zone)


## The ammo rack goes up: the tank is wrecked there and then, its turret thrown,
## whoever is inside badly hurt and everybody round it hit.
func _cook_off() -> void:
	if is_wrecked():
		return
	cooked_off = true
	bail_hurt = COOK_OFF_HURT
	var at := turret.global_position
	if on_crush.is_valid():
		on_crush.call(at, Vector3.DOWN, {"blast": true, "radius": 3.0, "hp": 0})
	if services != null:
		for p: Pawn in services.pawns.duplicate():
			if not is_instance_valid(p) or p == pawn or p.health == null or p.health.is_dead():
				continue
			var d := p.chest().distance_to(at)
			if d < COOK_OFF_RADIUS:
				p.health.apply_impact(COOK_OFF_DAMAGE * (1.0 - d / COOK_OFF_RADIUS), &"")
	damaged.emit(&"ammo")
	health.apply_impact(health.total_current() + 1.0, &"")
	# The turret goes up off its ring, and comes down where it comes down.
	var lid := RigidBody3D.new()
	lid.name = "ThrownTurret"
	lid.collision_layer = 0
	lid.collision_mask = Layers.WORLD | Layers.STRUCTURE | Layers.DEBRIS
	lid.mass = 400.0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(STUD * 7.0, COURSE * 2.0, STUD * 8.0)
	shape.shape = box
	shape.position = Vector3.UP * COURSE
	lid.add_child(shape)
	get_parent().add_child(lid)
	lid.global_transform = turret.global_transform
	turret.reparent(lid)
	lid.linear_velocity = velocity + Vector3.UP * 9.0 + forward().rotated(Vector3.UP, 2.0) * 2.0
	lid.angular_velocity = Vector3(2.5, 1.5, -1.0)
	_smoke_from(Vector3(0.0, -HEIGHT * 0.5 + RING_Y, 0.4))


func _on_wrecked() -> void:
	if is_wrecked():
		return
	state = "wrecked"
	throttle = 0.0
	steer = 0.0
	fire_main = false
	fire_coax = false
	main_gun.set_trigger(false)
	coax.set_trigger(false)
	if bricks != null:
		bricks.burn()
	if _smoke == null:
		_smoke_from(Vector3(0.0, 0.2, 0.0))
	if services != null and pawn != null:
		services.pawns.erase(pawn)
		for t in [0, 1]:
			services.knowledge_of(t).contacts.erase(pawn.get_instance_id())
	crew_get_out(bail_hurt)
	wrecked.emit(self)


# --- the tick -----------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	_clock += delta
	if not is_on_floor():
		velocity.y -= GRAVITY * delta
	else:
		velocity.y = maxf(velocity.y, 0.0)
	var go := throttle if driven() and can_drive() else 0.0
	var turn := steer if driven() and can_turn() else 0.0
	var rate := TURN if can_drive() else TURN * ONE_TRACK_TURN
	yaw = wrapf(yaw + clampf(turn, -1.0, 1.0) * rate * delta, -PI, PI)
	rotation.y = yaw
	var speed := go * (DRIVE if go > 0.0 else BACK)
	var fwd := forward()
	velocity.x = move_toward(velocity.x, fwd.x * speed, DRIVE * delta * 2.0)
	velocity.z = move_toward(velocity.z, fwd.z * speed, DRIVE * delta * 2.0)
	move_and_slide()
	if driven():
		splats += Splatter.run_down(services, self, team, feet(), fwd, Vector2(HULL.x * 0.5, HULL.z * 0.5),
				Vector2(velocity.x, velocity.z).dot(Vector2(fwd.x, fwd.z)), _splat_last)
	# A kerb: pressed against something, on the ground, going nowhere -- the
	# tracks climb it (KERB_POP is about half a metre).
	if absf(go) > 0.1 and is_on_floor() and is_on_wall() \
			and Vector2(velocity.x, velocity.z).length() < absf(speed) * 0.3:
		velocity.y = KERB_POP
	_crush(go)
	_turn_turret(delta)
	_guns()


## Driven into what is low enough -- bricks in front of its nose up to
## CRUSH_HEIGHT, and nothing over that up to its own height -- it wears them off,
## a row across its width, low and high, every CRUSH_EVERY.
func _crush(go: float) -> void:
	# Only pressed against something: two shape queries a tick for every tank
	# on the move would be paid for nothing on an open road.
	if absf(go) < 0.1 or _clock < _crush_at or not on_crush.is_valid() or not is_inside_tree() 			or not is_on_wall():
		return
	var nose := forward() * signf(go)
	var b := Basis(Vector3.UP, yaw)
	var ahead := HULL.z * 0.5 + 0.35
	var front := feet() + nose * ahead
	if not _front_has(front, 0.2, CRUSH_HEIGHT) or _front_has(front, CRUSH_HEIGHT + 0.15, HEIGHT - 0.15):
		return
	_crush_at = _clock + CRUSH_EVERY
	crushes += 1
	var at := feet() + nose * (HULL.z * 0.5 + 0.25)
	# Edge to edge: a brick its hull's side overlaps by a hand stops it as well
	# as one in the middle.
	for i in 6:
		var x := lerpf(-HULL.x * 0.5 - 0.05, HULL.x * 0.5 + 0.05, float(i) / 5.0)
		for y in [0.45, 1.0]:
			on_crush.call(at + b.x * x + Vector3.UP * y, nose,
					{"blast": false, "radius": 0.55, "hp": CRUSH_HP})


## Is there brick or rubble in the slab across its front at `front`, between
## `y0` and `y1` above its feet?
func _front_has(front: Vector3, y0: float, y1: float) -> bool:
	var q := PhysicsShapeQueryParameters3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(HULL.x + 0.1, y1 - y0, 0.7)
	q.shape = box
	q.transform = Transform3D(Basis(Vector3.UP, yaw), front + Vector3.UP * (y0 + y1) * 0.5)
	q.collision_mask = Layers.STRUCTURE | Layers.DEBRIS
	q.exclude = [get_rid()]
	return not get_world_3d().direct_space_state.intersect_shape(q, 1).is_empty()


func _turn_turret(delta: float) -> void:
	if aim_point == Vector3.INF or is_wrecked():
		return
	var ring := global_position + Vector3.UP * (RING_Y - HEIGHT * 0.5)
	var to := aim_point - ring
	var want_yaw := wrapf(atan2(-to.x, -to.z) - yaw, -PI, PI)
	var d := wrapf(want_yaw - turret_yaw, -PI, PI)
	# A dead engine: turned by hand. A jammed turret: not at all.
	var rate := TURRET_TURN * (1.0 if bricks == null or bricks.has(&"engine") else HAND_CRANK)
	var yaw_rate := rate if bricks == null or bricks.has(&"turret") else 0.0
	turret_yaw = wrapf(turret_yaw + clampf(d, -yaw_rate * delta, yaw_rate * delta), -PI, PI)
	var want_pitch := clampf(atan2(to.y - COURSE, Vector2(to.x, to.z).length()), PITCH_MIN, PITCH_MAX)
	gun_pitch = move_toward(gun_pitch, want_pitch, rate * delta)
	turret.rotation.y = turret_yaw
	mantlet.rotation.x = gun_pitch


## How far off its aim the gun points, radians (0 when there is nothing to aim at).
func aim_error() -> float:
	if aim_point == Vector3.INF:
		return 0.0
	var to := aim_point - muzzle.global_position
	return (-muzzle.global_basis.z).angle_to(to.normalized())


func _guns() -> void:
	var can := gunned()
	coax.set_trigger(can and fire_coax)
	# The cannon is one round at a time, MAIN_RELOAD apart: the trigger held for
	# one tick.
	if _main_pulse:
		_main_pulse = false
		main_gun.set_trigger(false)
	elif can and fire_main and _clock >= main_ready_at and (bricks == null or bricks.has(&"gun")):
		main_ready_at = _clock + MAIN_RELOAD
		_main_pulse = true
		# MAIN_RELOAD is the cannon's whole cycle: never the generated gun's own
		# magazine and reload on top of it.
		main_gun._reload_left = 0.0
		main_gun._cooldown = 0.0
		main_gun.ammo = maxi(main_gun.mag_size(), 1)
		main_gun.set_trigger(true)


func main_ready() -> bool:
	return _clock >= main_ready_at


## Where the commander's eye is: the cupola, on top of the turret.
func eye_interpolated() -> Vector3:
	var o := get_global_transform_interpolated().origin
	return o + Vector3.UP * (HEIGHT * 0.5 + 0.9)


## Its body in bricks (VehicleBricks), by zone. Studs across (x) and along (z,
## forward is -z), plates up from the feet:
##   tracks   two courses, two studs wide, down each side, the full length;
##   hull     a course of belly between the tracks, then three courses the full
##            width over them -- its top, the deck riders stand on, at RING_Y;
##   engine   the back four studs of those three courses, between the tracks;
##   turret   7 by 8 studs, two courses, with a cupola; in its back, in the lower
##            course behind a stud of turret wall, the AMMO rack;
##   gun      the mantlet, and a barrel a stud square and ten long.
func _build_look() -> void:
	var olive := Color(0.3, 0.34, 0.22)
	var dark := Color(0.13, 0.13, 0.12)
	var grille := Color(0.24, 0.21, 0.16)
	var brass := Color(0.55, 0.42, 0.16)
	var base := -HEIGHT * 0.5
	bricks = VehicleBricks.attach(self)
	var hull := Node3D.new()
	hull.name = "Hull"
	hull.position = Vector3.UP * base
	add_child(hull)
	var h := bricks.add_part(hull)
	var hp: Dictionary = BRICK_HP
	bricks.fill(h, &"track_l", Vector3(-4.5, 0, -8.5), Vector3(-2.5, 6, 8.5), dark, hp[&"track_l"])
	bricks.fill(h, &"track_r", Vector3(2.5, 0, -8.5), Vector3(4.5, 6, 8.5), dark, hp[&"track_r"])
	bricks.fill(h, &"hull", Vector3(-2.5, 3, -8.5), Vector3(2.5, 6, 8.5), olive, hp[&"hull"])
	bricks.fill(h, &"hull", Vector3(-4.5, 6, -8.5), Vector3(4.5, 15, 4.5), olive, hp[&"hull"])
	bricks.fill(h, &"hull", Vector3(-4.5, 6, 4.5), Vector3(-2.5, 15, 8.5), olive, hp[&"hull"])
	bricks.fill(h, &"hull", Vector3(2.5, 6, 4.5), Vector3(4.5, 15, 8.5), olive, hp[&"hull"])
	bricks.fill(h, &"engine", Vector3(-2.5, 6, 4.5), Vector3(2.5, 15, 8.5), grille, hp[&"engine"])
	turret = Node3D.new()
	turret.name = "Turret"
	turret.position = Vector3(0.0, base + RING_Y, 0.4)
	add_child(turret)
	var tu := bricks.add_part(turret)
	bricks.fill(tu, &"turret", Vector3(-3.5, 0, -4), Vector3(3.5, 6, 0), olive, hp[&"turret"])
	bricks.fill(tu, &"turret", Vector3(-3.5, 0, 0), Vector3(-1.5, 6, 4), olive, hp[&"turret"])
	bricks.fill(tu, &"turret", Vector3(1.5, 0, 0), Vector3(3.5, 6, 4), olive, hp[&"turret"])
	bricks.fill(tu, &"turret", Vector3(-1.5, 0, 3), Vector3(1.5, 6, 4), olive, hp[&"turret"], true)
	bricks.fill(tu, &"turret", Vector3(-1.5, 3, 0), Vector3(1.5, 6, 3), olive, hp[&"turret"])
	bricks.fill(tu, &"turret", Vector3(-1.5, 0, 0), Vector3(1.5, 3, 1), olive, hp[&"turret"], true)
	bricks.fill(tu, &"ammo", Vector3(-1.5, 0, 1), Vector3(1.5, 3, 3), brass, hp[&"ammo"], true)
	bricks.fill(tu, &"turret", Vector3(0.5, 6, -1), Vector3(2.5, 9, 1), olive, hp[&"turret"])
	mantlet = Node3D.new()
	mantlet.name = "Mantlet"
	mantlet.position = Vector3(0.0, COURSE, -STUD * 4.0)
	turret.add_child(mantlet)
	var g := bricks.add_part(mantlet)
	bricks.fill(g, &"gun", Vector3(-1.5, -2, -1), Vector3(1.5, 2, 0), dark, hp[&"gun"], true)
	bricks.fill(g, &"gun", Vector3(-0.5, -1, -11), Vector3(0.5, 1, -1), dark, hp[&"gun"])
	for z in ZONE_KEEP:
		bricks.keep(z, ZONE_KEEP[z])
	bricks.finish()
	bricks.zone_lost.connect(_on_zone_lost)
	muzzle = Node3D.new()
	muzzle.name = "Muzzle"
	muzzle.position = Vector3(0.0, 0.0, -3.7)
	mantlet.add_child(muzzle)


## Smoke from `at` (local): a dead engine, a wreck.
func _smoke_from(at: Vector3) -> void:
	if _smoke != null:
		_smoke.position = at
		return
	var s := CPUParticles3D.new()
	s.name = "Smoke"
	s.amount = 24
	s.lifetime = 3.0
	s.direction = Vector3.UP
	s.spread = 12.0
	s.initial_velocity_min = 1.0
	s.initial_velocity_max = 2.0
	s.gravity = Vector3.UP * 0.4
	s.scale_amount_min = 0.6
	s.scale_amount_max = 1.4
	var m := SphereMesh.new()
	m.radius = 0.35
	m.height = 0.7
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.12, 0.12, 0.12, 0.55)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.material = mat
	s.mesh = m
	s.position = at
	add_child(s)
	_smoke = s
