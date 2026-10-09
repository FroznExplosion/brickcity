class_name Rodeo
extends Node
## A rider on a mech (Docs/AIRoster.md 4.5, R8): somebody on foot climbs an
## enemy mech, rides on the back of its torso, and plants a charge that blows its
## hatch off. One per mech, under its body.
##
##   CLIMB    from the ground within CLIMB_REACH of the hull: a pawn of another
##            side, on foot. It rides at SEAT, put there every tick.
##   PLANT    held for PLANT_SECONDS on top; then the charge is on and goes off
##            CHARGE_FUSE later, rider or not: the hatch is off.
##   NOTICED  after NOTICE_SECONDS on it (the pilot feels the weight) or as soon
##            as a soldier of the mech's side sees it: until then the rider draws
##            no attention (G5); then a spike, on the mech's side's aggro.
##
## The mech's answers (its brain asks the casebook's "A rider on us"):
##
##   SMOKE    an electric cloud: the rider is thrown off and hurt. It hurts the
##            mech's own shield, and its own pilot with the hatch off; it takes
##            SMOKE_RECHARGE to come back -- so it can be baited: jump on, jump
##            off, get back on while it is down. None on auto (R18).
##   SCRAPE   walking under something just low enough: bricks where the rider's
##            head is take it off (the brain finds such a place and walks there).
##   CRUSH    backing hard into a wall: bricks right behind its back at the
##            seat's height, at speed, and the rider is crushed.
##   ESCORT   its infantry shoot the rider -- at their own mech. Nothing here: a
##            rider is a pawn like any other, and the mech never aims at its own.

const CLIMB_REACH := Mech.RADIUS + 1.4
## The seat: on top of the torso (14 courses up), towards its back.
const SEAT_UP := Mech.COURSE * 14.0
const SEAT_BACK := 0.9
const PLANT_SECONDS := 2.5
const CHARGE_FUSE := 1.5
const NOTICE_SECONDS := 1.0
## The cloud: how long it lasts, what it does to the rider, to the mech's own
## shield and to its own pilot with the hatch off, and how long until it is back.
const SMOKE_SECONDS := 3.0
const SMOKE_RADIUS := 6.0
const SMOKE_RIDER := 45.0
const SMOKE_SHIELD := 300.0
const SMOKE_PILOT := 30.0
const SMOKE_RECHARGE := 15.0
const SCRAPE_DAMAGE := 40.0
const CRUSH_DAMAGE := 120.0
## A crush needs the mech going at least this fast, back first.
const CRUSH_SPEED := 2.0
## A rider put down: this far out from the hull, beside it.
const DROP_OUT := Mech.RADIUS + 1.2
const SMOKE_ID_BASE := 730000

signal climbed(p: Pawn)
signal noticed(p: Pawn)
signal dropped(p: Pawn, why: String)
signal charge_planted
signal charge_blew
signal smoked

var mech: Mech
var rider: Pawn
## Who rode it last, and when they came off: a mech whose smoke is spent watches
## its back for them (MechBrain).
var last_rider: Pawn
var last_drop_at := -INF
var rider_since := 0.0
var is_noticed := false
## How far through planting, 0..1; the charge is on once it is planted.
var plant := 0.0
var charge_at := INF
## The rider is holding the plant (set by whoever drives it; off when it gets off).
var planting := false
var smoke_ready_at := 0.0
var smoke_until := -INF
## For gates: what has happened.
var climbs := 0
var drops: Array[String] = []
var smokes := 0
var _now := 0.0
var _rider_layers := Vector2i.ZERO


static func attach(m: Mech) -> Rodeo:
	var r := Rodeo.new()
	r.name = "Rodeo"
	r.mech = m
	# After the pawns (0) and the motor (-10): the rider is put on the moved mech.
	r.process_physics_priority = 10
	m.body.add_child(r)
	return r


func services() -> AIServices:
	return mech.layers.services if mech.layers != null else null


## Can `p` climb on now? Another side's pawn, on foot, alive, near the hull --
## and nobody else up there.
func can_climb(p: Pawn) -> bool:
	if p == null or rider != null or mech.layers.dead or p.team == mech.team or p.has_meta(&"in_mech"):
		return false
	if p.health != null and p.health.is_dead():
		return false
	var f := p.feet()
	var c := mech.feet()
	return Vector2(f.x - c.x, f.z - c.z).length() <= CLIMB_REACH and f.y > c.y - 1.0 and f.y < c.y + 2.5


func climb(p: Pawn) -> bool:
	if not can_climb(p):
		return false
	rider = p
	rider_since = _now
	is_noticed = false
	plant = 0.0
	planting = false
	climbs += 1
	p.set_meta(&"riding", mech)
	# It rides, not walks: nothing it touches pushes it about up there.
	_rider_layers = Vector2i(p.body.collision_layer, p.body.collision_mask)
	p.body.collision_mask = 0
	_seat()
	climbed.emit(p)
	return true


## The rider gets off: `why` is "jumped", "smoke", "scraped", "crushed" or
## "dead". Put down beside the hull on the seat's side (the back).
func drop(why: String) -> void:
	var p := rider
	if p == null:
		return
	rider = null
	plant = 0.0
	planting = false
	drops.append(why)
	last_rider = p
	last_drop_at = _now
	if is_instance_valid(p):
		p.remove_meta(&"riding")
		if why != "jumped" and why != "dead":
			# Thrown off: a rider with the rodeo mod waits a little to go again.
			var so := p.body.get_node_or_null(^"Soldier") as Soldier
			if so != null:
				so.rodeo_target = null
				so._rodeo_retry_at = so.services.now() + Soldier.RODEO_RETRY
		p.body.collision_layer = _rider_layers.x
		p.body.collision_mask = _rider_layers.y
		if why != "dead":
			var back := Basis(Vector3.UP, mech.motor.torso_yaw).z
			var at := mech.feet() + back * DROP_OUT
			var s := services()
			if s != null and s.ai_nav != null:
				var snapped := s.ai_nav.snap(at)
				if snapped.distance_to(at) < 3.0:
					at = snapped
			p.place(at)
	dropped.emit(p, why)


func seat_point() -> Vector3:
	var back := Basis(Vector3.UP, mech.motor.torso_yaw).z
	return mech.feet() + Vector3.UP * SEAT_UP + back * SEAT_BACK


func smoke_ready() -> bool:
	return _now >= smoke_ready_at and not mech.layers.auto and mech.layers.piloted and not mech.layers.dead


func smoke_active() -> bool:
	return _now < smoke_until


## Smoke used and not back yet: the mech minds its back.
func smoke_spent() -> bool:
	return smokes > 0 and _now < smoke_ready_at


## The cloud (above). False if it is not ready.
func smoke() -> bool:
	if not smoke_ready():
		return false
	smokes += 1
	smoke_ready_at = _now + SMOKE_RECHARGE
	smoke_until = _now + SMOKE_SECONDS
	var l := mech.layers
	# Its own shield takes it; with the hatch off, so does its own pilot.
	if l.value(MechLayers.SHIELD) > 0.0:
		l.pool.apply_to_layer_type(minf(SMOKE_SHIELD, l.value(MechLayers.SHIELD)), MechLayers.SHIELD, &"")
	if l.hatch_off and l.piloted:
		l._hurt_pilot(SMOKE_PILOT)
	var s := services()
	if s != null and s.ai_world != null:
		s.ai_world.set_smoke(SMOKE_ID_BASE + int(get_instance_id() % 100000), mech.feet() + Vector3.UP * SEAT_UP * 0.6, SMOKE_RADIUS)
	smoked.emit()
	if rider != null:
		_hurt(rider, SMOKE_RIDER)
		drop("smoke")
	return true


func _hurt(p: Pawn, amount: float) -> void:
	if p != null and is_instance_valid(p) and p.health != null:
		p.health.apply_impact(amount, &"")


func _seat() -> void:
	rider.place(seat_point())


func _physics_process(delta: float) -> void:
	_now += delta
	if smoke_until > -INF and _now >= smoke_until:
		smoke_until = -INF
		var s := services()
		if s != null and s.ai_world != null:
			s.ai_world.remove_smoke(SMOKE_ID_BASE + int(get_instance_id() % 100000))
	if _now >= charge_at:
		charge_at = INF
		if not mech.layers.dead:
			mech.layers.blow_hatch()
			charge_blew.emit()
	if rider == null:
		return
	if not is_instance_valid(rider) or (rider.health != null and rider.health.is_dead()) or mech.layers.dead:
		drop("dead")
		return
	_seat()
	if not is_noticed and (_now - rider_since >= NOTICE_SECONDS or _seen_by_escort()):
		_notice()
	# Up there: bricks where its head is (it went under something), or right
	# behind its back while the mech rams backwards into them.
	if _scraped():
		_hurt(rider, SCRAPE_DAMAGE)
		drop("scraped")
		return
	if _crushed():
		_hurt(rider, CRUSH_DAMAGE)
		drop("crushed")
		return
	if planting and charge_at == INF and not mech.layers.hatch_off:
		plant = minf(1.0, plant + delta / PLANT_SECONDS)
		if plant >= 1.0:
			charge_at = _now + CHARGE_FUSE
			charge_planted.emit()


func _notice() -> void:
	is_noticed = true
	var s := services()
	if s != null:
		s.aggro_of(mech.team).add(rider, AggroTable.RIDER_SPIKE)
		# Felt, not seen: the side knows where it is.
		s.knowledge_of(mech.team).heard(rider, rider.feet(), s.now())
	noticed.emit(rider)


func _seen_by_escort() -> bool:
	var s := services()
	if s == null:
		return false
	var c := s.knowledge_of(mech.team).of(rider)
	if c == null or not c.visible:
		return false
	# Somebody other than the mech itself: it cannot see its own back.
	var br := mech.brain()
	for id in c.seen_by:
		if br == null or int(id) != br.get_instance_id():
			return true
	return false


func _scraped() -> bool:
	var s := services()
	if s == null or s.ai_world == null:
		return false
	var top := seat_point()
	for up in [Pawn.BODY_HEIGHT * 0.7, Pawn.BODY_HEIGHT * 0.95]:
		if s.ai_world.solid_at(top + Vector3.UP * up):
			return true
	return false


func _crushed() -> bool:
	var s := services()
	if s == null or s.ai_world == null:
		return false
	var back := Basis(Vector3.UP, mech.motor.torso_yaw).z
	# Going back first, and fast.
	var v := Vector3(mech.body.velocity.x, 0.0, mech.body.velocity.z)
	if v.length() < CRUSH_SPEED or v.normalized().dot(back) < 0.5:
		return false
	# Bricks just behind the hull at the rider's height, the way it is going:
	# the hull stops at the wall, the rider on its back does not.
	var centre := mech.feet() + Vector3.UP * (SEAT_UP + Pawn.BODY_HEIGHT * 0.5)
	# A fan round the way it goes: a wall met at an angle is as hard.
	var going := v.normalized()
	for k in [0, -1, 1, -2, 2]:
		var dir := going.rotated(Vector3.UP, deg_to_rad(30.0 * k))
		for out in [Mech.RADIUS + 0.25, Mech.RADIUS + 0.6]:
			if s.ai_world.solid_at(centre + dir * out):
				return true
	return false
