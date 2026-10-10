class_name VehicleDeck
extends Node
## Who rides on a vehicle without being in it (Docs/AIVehicles.md 4; Halo's
## riders and boarders). One per Tank or TransportTruck, as its `rodeo`.
##
## RIDERS -- the vehicle's own side, standing on its deck (a tank's track
## covers, a truck's open bed). Carried every tick; they shoot their own guns
## from up there and nothing else: no walking, no cover. Jump (or the vehicle
## wrecked) puts them down beside it. Up to one per SPOT.
##
## A BOARDER -- the other side, climbed on from beside it (a tank only: a
## truck's cab is taken at once, TransportTruck.hijack). It rides on the back
## deck and, held for PRY_SECONDS, pries the hatch open and drags the crew out:
## the vehicle is then the boarder's (Vehicle.hijack). Until NOTICE_SECONDS on
## it, or a soldier of the vehicle's side sees it, it draws no attention (G5);
## then a spike on that side's aggro, as a mech's rider gets. The crew cannot
## turn the gun on its own deck; its escort has to shoot it off.
##
## Its boarder half answers as Rodeo does (rider, climb, drop, planting,
## charge_at, is_noticed), so a soldier with the rodeo mod and the player's
## melee button drive a mech's back and a tank's deck alike.

signal climbed(p: Pawn)
signal noticed(p: Pawn)
signal dropped(p: Pawn, why: String)
## The hatch is open: `by` has the vehicle now.
signal hijacked(by: Pawn)
signal rider_on(p: Pawn)
signal rider_off(p: Pawn, why: String)
## Rodeo's: never on a vehicle (nothing is planted), here for the callers.
signal charge_planted
signal charge_blew

## A boarder climbs on from within this of the hull's side.
const CLIMB_REACH := 2.2
const PRY_SECONDS := 2.0
const NOTICE_SECONDS := 1.0
## A rider gets on from within this of its spot, flat.
const RIDE_REACH := 4.0
## Put down this far out from the hull's side.
const DROP_OUT := 1.2

var vehicle: Node3D
## The ride spots, in the vehicle's frame, from its feet: where a rider's feet are.
var spots: Array[Vector3] = []
## Spot -> the Pawn riding there, or null.
var riders: Array = []
## Where a boarder rides, in the vehicle's frame from its feet.
var board_spot := Vector3.ZERO
## Half the hull's width and length, for reach.
var half := Vector2.ONE

## The boarder (Rodeo's `rider`), and how far through prying the hatch, 0..1.
var rider: Pawn
var plant := 0.0
## The boarder is holding the hatch (set by whoever drives it).
var planting := false
var charge_at := INF
var is_noticed := false
var rider_since := 0.0
var climbs := 0
var drops: Array[String] = []
var hijacks := 0
var _now := 0.0
var _layers := {}


static func attach(v: Node3D, p_spots: Array[Vector3], p_board: Vector3, p_half: Vector2) -> VehicleDeck:
	var d := VehicleDeck.new()
	d.name = "Deck"
	d.vehicle = v
	d.spots = p_spots
	d.board_spot = p_board
	d.half = p_half
	d.riders.resize(p_spots.size())
	# After the pawns and the vehicle's own move: riders are put on the moved deck.
	d.process_physics_priority = 10
	v.add_child(d)
	return d


func services() -> AIServices:
	return vehicle.services


func _basis() -> Basis:
	return Basis(Vector3.UP, vehicle.rotation.y)


func _at(local: Vector3) -> Vector3:
	return vehicle.feet() + _basis() * local


func _dead(p: Pawn) -> bool:
	return p == null or not is_instance_valid(p) or (p.health != null and p.health.is_dead())


## Is `p` beside the hull, at about its ground: flat distance from its sides
## within `reach`.
func beside(p: Pawn, reach: float) -> bool:
	var local: Vector3 = _basis().inverse() * (p.feet() - vehicle.feet())
	return absf(local.x) < half.x + reach and absf(local.z) < half.y + reach \
			and local.y > -1.0 and local.y < 2.5


# --- riders -------------------------------------------------------------------------

func rider_count() -> int:
	var n := 0
	for r in riders:
		if not _dead(r):
			n += 1
	return n


func free_spot() -> int:
	for i in riders.size():
		if _dead(riders[i]):
			return i
	return -1


func is_riding(p: Pawn) -> bool:
	return riders.has(p)


## Can `p` get on? Its side's vehicle, not wrecked, a spot free, `p` on foot beside it.
func can_ride(p: Pawn) -> bool:
	if _dead(p) or vehicle.is_wrecked() or p.team != vehicle.team or free_spot() < 0:
		return false
	if p.has_meta(&"riding") or p.has_meta(&"aboard") or p.has_meta(&"in_vehicle") or p.has_meta(&"in_mech"):
		return false
	return beside(p, RIDE_REACH)


func ride(p: Pawn) -> bool:
	if not can_ride(p):
		return false
	var i := free_spot()
	riders[i] = p
	p.set_meta(&"aboard", vehicle)
	_carry(p)
	_seat(p, spots[i])
	rider_on.emit(p)
	return true


## `p` gets off: put down beside the hull (not when dead).
func get_off(p: Pawn, why := "jumped") -> void:
	var i := riders.find(p)
	if i < 0:
		return
	riders[i] = null
	if is_instance_valid(p):
		p.remove_meta(&"aboard")
		_uncarry(p)
		if not _dead(p):
			p.place(_down_point(spots[i].x >= 0.0))
	rider_off.emit(p, why)


func all_off(why: String) -> void:
	for r in riders.duplicate():
		if r != null:
			get_off(r, why)


# --- the boarder (Rodeo's half) -------------------------------------------------------

## A pawn of the other side, on foot, beside the hull, nobody else up there --
## and somebody in it to drag out (an empty vehicle is simply got into).
func can_climb(p: Pawn) -> bool:
	if _dead(p) or rider != null or vehicle.is_wrecked() or p.team == vehicle.team:
		return false
	if board_spot == Vector3.INF or vehicle.is_empty():
		return false
	if p.has_meta(&"riding") or p.has_meta(&"aboard") or p.has_meta(&"in_vehicle") or p.has_meta(&"in_mech"):
		return false
	return beside(p, CLIMB_REACH)


func climb(p: Pawn) -> bool:
	if not can_climb(p):
		return false
	rider = p
	rider_since = _now
	is_noticed = false
	plant = 0.0
	planting = false
	climbs += 1
	p.set_meta(&"riding", vehicle)
	_carry(p)
	_seat(p, board_spot)
	climbed.emit(p)
	return true


## The boarder gets off: "jumped", "dead", "wrecked", or "in" (it got in).
func drop(why: String) -> void:
	var p := rider
	if p == null:
		return
	rider = null
	plant = 0.0
	planting = false
	drops.append(why)
	if is_instance_valid(p):
		p.remove_meta(&"riding")
		_uncarry(p)
		if why != "dead" and why != "in" and not _dead(p):
			p.place(_down_point(false))
	dropped.emit(p, why)


func _notice() -> void:
	is_noticed = true
	var s := services()
	if s != null:
		s.aggro_of(vehicle.team).add(rider, AggroTable.RIDER_SPIKE)
		s.knowledge_of(vehicle.team).heard(rider, rider.feet(), s.now())
	noticed.emit(rider)


func _seen_by_escort() -> bool:
	var s := services()
	if s == null:
		return false
	var c := s.knowledge_of(vehicle.team).of(rider)
	if c == null or not c.visible:
		return false
	var own := vehicle.get_node_or_null(^"TankBrain")
	for id in c.seen_by:
		if own == null or int(id) != own.get_instance_id():
			return true
	return false


# --- carrying -------------------------------------------------------------------------

## Up there it rides, not walks: nothing it touches pushes it about, and the
## vehicle does not push against it.
func _carry(p: Pawn) -> void:
	_layers[p.get_instance_id()] = p.body.collision_mask
	p.body.collision_mask = 0
	if vehicle is PhysicsBody3D:
		(vehicle as PhysicsBody3D).add_collision_exception_with(p.body)


func _uncarry(p: Pawn) -> void:
	p.body.collision_mask = int(_layers.get(p.get_instance_id(), Layers.PAWN_MASK))
	_layers.erase(p.get_instance_id())
	if vehicle is PhysicsBody3D and is_instance_valid(vehicle):
		(vehicle as PhysicsBody3D).remove_collision_exception_with(p.body)


func _seat(p: Pawn, local: Vector3) -> void:
	p.place(_at(local))


## Beside the hull, on the right (or the left), on ground a body stands on.
func _down_point(right: bool) -> Vector3:
	var b := _basis()
	var at: Vector3 = vehicle.feet() + b.x * (half.x + DROP_OUT) * (1.0 if right else -1.0)
	var s := services()
	if s != null and s.ai_nav != null:
		var snapped := s.ai_nav.snap(at)
		if snapped.distance_to(at) < 3.0:
			return snapped
	return at


# --- the tick -------------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	_now += delta
	for i in riders.size():
		var r = riders[i]
		if r == null:
			continue
		if _dead(r):
			get_off(r, "dead")
		elif vehicle.is_wrecked():
			get_off(r, "wrecked")
		else:
			_seat(r, spots[i])
	if rider == null:
		return
	if _dead(rider):
		drop("dead")
		return
	if vehicle.is_wrecked():
		drop("wrecked")
		return
	if vehicle.is_empty():
		# Nobody left to drag out: off, and in by the hatch like anybody.
		drop("jumped")
		return
	_seat(rider, board_spot)
	if not is_noticed and (_now - rider_since >= NOTICE_SECONDS or _seen_by_escort()):
		_notice()
	if planting:
		plant = minf(1.0, plant + delta / PRY_SECONDS)
		if plant >= 1.0:
			var p := rider
			hijacks += 1
			drop("in")
			vehicle.hijack(p)
			hijacked.emit(p)
