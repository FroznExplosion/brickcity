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
## hurt, and fight on foot. The player can take it: in at the hatch, both seats
## at once (TankPilot).
##
## What drives it is four numbers and a point, filled by its brain (TankBrain)
## or the player's keys (TankPilot): `throttle` and `steer` for the hull,
## `aim_point` for the turret, `fire_main` and `fire_coax` for the guns.
##
## It is armour, not flesh (AIRoster.md 4.6, R15): a person's rifle scratches
## it, a rocket or a mech's gun hurts it (ARMOUR). Everybody else senses and
## shoots it through `pawn` (make_target), as they do a mech.
##
## Greybox, as the mech is: boxes sized in bricks until vehicles are built of
## bricks (AIVehicles.md 1). Not yet: crushing, damage zones, riding on it.

signal wrecked(tank: Tank)
signal crew_out(p: Pawn)

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

enum Seat { DRIVER, GUNNER }

var services: AIServices
var team := 1
var health: HealthPool
## What everybody else senses and shoots at (make_target).
var pawn: Pawn
var state := "ready"   # ready, wrecked
## Seat -> the Pawn in it (an AI crewman), or null.
var crew := {Seat.DRIVER: null, Seat.GUNNER: null}
## The player is in it: both seats are theirs.
var player_in := false

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
var _clock := 0.0
var _main_pulse := false
var _look: Array[MeshInstance3D] = []


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


## Can it move? A driver in it (or the player), and not wrecked.
func driven() -> bool:
	return not is_wrecked() and (player_in or _alive(crew[Seat.DRIVER]))


## Can it shoot?
func gunned() -> bool:
	return not is_wrecked() and (player_in or _alive(crew[Seat.GUNNER]))


func crew_count() -> int:
	var n := 0
	for s in crew:
		if _alive(crew[s]):
			n += 1
	return n


func is_empty() -> bool:
	return not player_in and crew_count() == 0


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
	if p == null or is_wrecked() or player_in or _alive(crew[seat]) \
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


## The player takes it, both seats: empty, or already theirs.
func take_player(p_team: int) -> bool:
	if is_wrecked() or player_in or (p_team != team and not is_empty()):
		return false
	_take_side(p_team)
	player_in = true
	return true


func release_player() -> void:
	player_in = false
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


## A tank changes side with whoever gets into it empty.
func _take_side(p_team: int) -> void:
	if p_team == team:
		return
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

## A hit through DamageSystem (the "takes_packet" meta): armour by the hit's scale.
func take_packet(packet: DamagePacket) -> DamageSystem.DamageResult:
	var res := DamageSystem.DamageResult.new()
	if is_wrecked():
		return res
	var before := health.total_current()
	var k := float(ARMOUR.get(MechLayers.scale_of(packet), 1.0))
	health.apply_impact(packet.amount * k, &"")
	res.dealt = before - health.total_current()
	res.killed = health.is_dead()
	return res


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
	var burnt := StandardMaterial3D.new()
	burnt.albedo_color = Color(0.1, 0.09, 0.08)
	for mi in _look:
		mi.material_override = burnt
	if services != null and pawn != null:
		services.pawns.erase(pawn)
		for t in [0, 1]:
			services.knowledge_of(t).contacts.erase(pawn.get_instance_id())
	crew_get_out(BAIL_HURT)
	wrecked.emit(self)


# --- the tick -----------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	_clock += delta
	if not is_on_floor():
		velocity.y -= GRAVITY * delta
	else:
		velocity.y = maxf(velocity.y, 0.0)
	var go := throttle if driven() else 0.0
	var turn := steer if driven() else 0.0
	yaw = wrapf(yaw + clampf(turn, -1.0, 1.0) * TURN * delta, -PI, PI)
	rotation.y = yaw
	var speed := go * (DRIVE if go > 0.0 else BACK)
	var fwd := forward()
	velocity.x = move_toward(velocity.x, fwd.x * speed, DRIVE * delta * 2.0)
	velocity.z = move_toward(velocity.z, fwd.z * speed, DRIVE * delta * 2.0)
	move_and_slide()
	# A kerb: pressed against something, on the ground, going nowhere -- the
	# tracks climb it (KERB_POP is about half a metre).
	if absf(go) > 0.1 and is_on_floor() and is_on_wall() \
			and Vector2(velocity.x, velocity.z).length() < absf(speed) * 0.3:
		velocity.y = KERB_POP
	_turn_turret(delta)
	_guns()


func _turn_turret(delta: float) -> void:
	if aim_point == Vector3.INF or is_wrecked():
		return
	var ring := global_position + Vector3.UP * (RING_Y - HEIGHT * 0.5)
	var to := aim_point - ring
	var want_yaw := wrapf(atan2(-to.x, -to.z) - yaw, -PI, PI)
	var d := wrapf(want_yaw - turret_yaw, -PI, PI)
	turret_yaw = wrapf(turret_yaw + clampf(d, -TURRET_TURN * delta, TURRET_TURN * delta), -PI, PI)
	var want_pitch := clampf(atan2(to.y - COURSE, Vector2(to.x, to.z).length()), PITCH_MIN, PITCH_MAX)
	gun_pitch = move_toward(gun_pitch, want_pitch, TURRET_TURN * delta)
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
	elif can and fire_main and _clock >= main_ready_at:
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


func _build_look() -> void:
	var olive := StandardMaterial3D.new()
	olive.albedo_color = Color(0.3, 0.34, 0.22)
	var dark := StandardMaterial3D.new()
	dark.albedo_color = Color(0.13, 0.13, 0.12)
	var base := -HEIGHT * 0.5
	_box(self, Vector3(HULL.x, HULL.y, HULL.z), Vector3(0.0, base + CLEARANCE + HULL.y * 0.5, 0.0), olive)
	for x in [-1.0, 1.0]:
		_box(self, Vector3(STUD * 2.0, CLEARANCE * 2.0 + 0.2, HULL.z + 0.2),
				Vector3(x * (HULL.x * 0.5 - STUD), base + CLEARANCE, 0.0), dark)
	turret = Node3D.new()
	turret.name = "Turret"
	turret.position = Vector3(0.0, base + RING_Y, 0.4)
	add_child(turret)
	_box(turret, Vector3(STUD * 7.0, COURSE * 2.0, STUD * 8.0), Vector3(0.0, COURSE, 0.0), olive)
	mantlet = Node3D.new()
	mantlet.name = "Mantlet"
	mantlet.position = Vector3(0.0, COURSE, -STUD * 4.0)
	turret.add_child(mantlet)
	_box(mantlet, Vector3(0.22, 0.22, 3.6), Vector3(0.0, 0.0, -1.8), dark)
	muzzle = Node3D.new()
	muzzle.name = "Muzzle"
	muzzle.position = Vector3(0.0, 0.0, -3.7)
	mantlet.add_child(muzzle)


func _box(parent: Node3D, size: Vector3, at: Vector3, mat: Material) -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	bm.material = mat
	mi.mesh = bm
	mi.position = at
	parent.add_child(mi)
	_look.append(mi)
