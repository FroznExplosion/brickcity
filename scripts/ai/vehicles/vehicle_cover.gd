class_name VehicleCover
extends RefCounted
## A vehicle's hull as cover the AI knows (Docs/AIVehicles.md 4: moving cover).
##
## A box in AIWorld (`set_cover`) the size of the hull, kept where the vehicle
## is: lines through it -- sight, fire, a cover search's `cover_seconds` -- count
## it as `bricks_per_metre` of bricks, so a soldier looking for cover finds the
## lee of an APC, a tank or a truck, and one behind it is hidden from what is
## on the other side. It is not solid to the walking map (it moves), and a line
## to or from inside it does not count it: that is a shot at the vehicle, or a
## look out of it.
##
## Moved when the vehicle has gone MOVE metres or turned TURN since, at most
## every EVERY seconds: each move rebuilds AIWorld's proxy index.

const MOVE := 0.4
const TURN := deg_to_rad(6.0)
const EVERY := 0.2
## Proxy ids for vehicles, clear of the buildings' (id * 64 + k).
const ID_BASE := 1 << 28

static var _next := 0

var services: AIServices
var id := -1
var size := Vector3.ZERO
var bricks_per_metre := 0.0
var _at := Vector3.INF
var _yaw := 0.0
var _when := -INF


static func make(s: AIServices, p_size: Vector3, p_bricks_per_metre: float) -> VehicleCover:
	if s == null or s.ai_world == null or not s.ai_world.has_method(&"set_cover"):
		return null
	var c := VehicleCover.new()
	c.services = s
	c.size = p_size
	c.bricks_per_metre = p_bricks_per_metre
	c.id = ID_BASE + _next
	_next += 1
	return c


## `v` is where it is, its box's middle at `centre`.
func update(v: Node3D, centre: Vector3) -> void:
	var yaw := v.global_rotation.y
	var now := Time.get_ticks_msec() / 1000.0
	if now - _when < EVERY:
		return
	if _at != Vector3.INF and centre.distance_to(_at) < MOVE and absf(wrapf(yaw - _yaw, -PI, PI)) < TURN:
		return
	_when = now
	_at = centre
	_yaw = yaw
	services.ai_world.call(&"set_cover", id, Transform3D(Basis(Vector3.UP, yaw), centre), size,
			bricks_per_metre)


func remove() -> void:
	if _at != Vector3.INF and services != null and services.ai_world != null:
		services.ai_world.remove_proxy(id)
	_at = Vector3.INF
