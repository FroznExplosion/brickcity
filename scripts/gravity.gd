class_name Gravity

## WHICH WAY IS DOWN, and how hard. One place (Docs/Planets.md 9.1).
##
## Today the world is flat: down is -Y everywhere and the strength is the
## project's default gravity, so every caller behaves exactly as when it wrote
## `velocity.y -= g * delta` itself. On a planet these are the functions that
## change -- toward the body's centre, and a building's own down inside its
## gravity zone (Planets.md 4.1, 5) -- and nothing that asks them has to.
##
## Each system keeps its own MAGNITUDE where it tunes one for feel (a pawn's
## 20, the debris' 1.6x): only the direction, and the project's strength
## where a system used it, come from here.

static var _strength := -1.0

## On a planet (Docs/Planets.md 11): the node at its centre and its surface
## gravity. Null in the flat game, where down is -Y as before.
static var planet: Node3D = null
static var planet_strength := 9.8


# --- fields of their own (Docs/RoomModules.md 7.12) -------------------------
#
# A working ship's or station's generator pulls inside its own boxes, toward a
# centre of its own, over whatever is outside -- a planet's, or nothing in open
# space. A piece broken off one is a field where nothing pulls. The first field
# that holds a point is its gravity; outside them all, the planet's. PlanetSystem
# sets them every tick; none in the flat game or a planet without its system.

## A field: boxes in `space`'s frame (`local` of it), pulling `pull` m/s^2
## toward `centre`, `radius` under which is its datum (height_of). No centre:
## nothing pulls in it.
class Field:
	var space: Node3D
	var local := Transform3D()
	var boxes: Array[AABB] = []
	var centre: Node3D
	var pull := 0.0
	var radius := 0.0

	func holds(p: Vector3) -> bool:
		if space == null or not is_instance_valid(space):
			return false
		var l := (space.global_transform * local).affine_inverse() * p
		for b: AABB in boxes:
			if b.has_point(l):
				return true
		return false

	func pulls() -> bool:
		return centre != null and is_instance_valid(centre) and pull > 0.0


static var fields: Array[Field] = []
## What pulls outside every field, m/s^2; below zero, `strength()` does.
static var outside_pull := -1.0


## The field world point `p` is in; null outside them all.
static func field_at(p: Vector3) -> Field:
	for f: Field in fields:
		if f.holds(p):
			return f
	return null


## How hard gravity pulls at world point `p`, m/s^2: its field's, else what pulls
## outside them. 0: nothing does (open space, a piece broken off, a generator off).
static func pull_at(p: Vector3) -> float:
	var f := field_at(p)
	if f != null:
		return f.pull if f.pulls() else 0.0
	return outside_pull if outside_pull >= 0.0 else strength()


## Anything pulling at `p`. In the flat game, always.
static func pulls_at(p: Vector3) -> bool:
	return pull_at(p) > 0.0


## While pinned (`pin`), the frame every down, up and height is taken in.
static var _pinned: Array = []


## Take every down, up and height in the frame at `p` until `unpin`: a body's
## move compares points a step apart, which at a field's edge are in two frames
## whose heights are over two datums. Only the down's frame -- what pulls is
## still each point's own.
static func pin(p: Vector3) -> void:
	_pinned = []
	_pin_up = Vector3.ZERO
	_pinned = _centre_at(p)


static func unpin() -> void:
	_pinned = []
	_pin_up = Vector3.ZERO


## While set (`pin_up`): one fixed up for every down, up and height -- a ghost
## hull's (Docs/Hulls.md 7b), whose points are not the world's, so no field or
## planet can say where down is there. Heights are along it, from the space's
## origin.
static var _pin_up := Vector3.ZERO


static func pin_up(up: Vector3) -> void:
	_pinned = []
	_pin_up = up.normalized()


## The node `p`'s down points to and its datum's radius: its field's centre, or
## the planet's. [null, 0] for the flat game's -Y.
static func _centre_at(p: Vector3) -> Array:
	if not _pinned.is_empty():
		return _pinned
	var f := field_at(p) if not fields.is_empty() else null
	if f != null and f.pulls():
		return [f.centre, f.radius]
	if planet != null and is_instance_valid(planet):
		return [planet, planet_radius]
	return [null, 0.0]


## The project's gravity, m/s^2 (physics/3d/default_gravity); the planet's on one
## -- where the player is (PlanetSystem): a ship's own inside it.
static func strength() -> float:
	if planet != null:
		return planet_strength
	if _strength < 0.0:
		_strength = float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8))
	return _strength


## Unit vector down at a world point: toward the planet's centre on one, its
## field's inside one.
static func down_at(p: Vector3) -> Vector3:
	if _pin_up != Vector3.ZERO:
		return -_pin_up
	var c: Node3D = _centre_at(p)[0]
	if c != null:
		var d := c.global_position - p
		if d.length_squared() > 1e-6:
			return d.normalized()
	return Vector3.DOWN


## Unit vector up at a world point: away from the ground.
static func up_at(p: Vector3) -> Vector3:
	return -down_at(p)


# --- one up, everywhere (Docs/Planets.md 11.7) ------------------------------
#
# What `.y` meant, said with the local up. With up = +Y each is exact: a dot
# with (0, 1, 0) is `y`, and taking `up * y` off leaves (x, 0, z) -- so the flat
# game does not move by a bit.

## The part of `v` along `up` (was `v.y`).
static func vert(v: Vector3, up: Vector3) -> float:
	return v.dot(up)


## `v` without its part along `up` (was `Vector3(v.x, 0, v.z)`).
static func flat(v: Vector3, up: Vector3) -> Vector3:
	return v - up * v.dot(up)


## `v` with its part along `up` set to `x` (was `v.y = x`). Exactly that
## off a planet: `v.y + (x - v.y)` is not always `x` to the last bit.
static func with_vert(v: Vector3, up: Vector3, x: float) -> Vector3:
	if up == Vector3.UP:
		return Vector3(v.x, x, v.z)
	return v + up * (x - v.dot(up))


## What a body standing on the floor keeps along its up: nothing on the flat
## game's flat floors; on a planet a little INTO the floor, or move_and_slide
## meets nothing on the convex ground and is_on_floor flickers (test 5, and
## the pawn: 22% of a walk's ticks "in the air" with nothing).
static func standing_vert() -> float:
	return -1.0 if planet != null and is_instance_valid(planet) else 0.0


## How fast a body on the floor may be moving along its up and still be
## following the floor, not leaving it: 0 in the flat game, as it always was;
## on a planet a slide up a facet of the voxel ground leaves a little upward
## speed, and kept, it lifts the body off for a tick every half metre (the
## pawn: 79 such hops in 42 m). Well under a jump's 4.2 m/s.
static func floor_rise() -> float:
	return 1.5 if planet != null and is_instance_valid(planet) else 0.0


## How high a world point stands (was `p.y`): over the planet's datum on one.
static var planet_radius := 0.0


static func height_of(p: Vector3) -> float:
	if _pin_up != Vector3.ZERO:
		return p.dot(_pin_up)
	var c: Array = _centre_at(p)
	if c[0] != null:
		return (p - (c[0] as Node3D).global_position).length() - float(c[1])
	return p.y


## `p` moved along its up to stand at height `h` (was `Vector3(p.x, h, p.z)`).
static func lift_to(p: Vector3, h: float) -> Vector3:
	if _centre_at(p)[0] != null:
		return p + up_at(p) * (h - height_of(p))
	return Vector3(p.x, h, p.z)


## How high the GROUND stands under a world point, over the datum: the
## planet's own height field. NAN off a planet (there the AI asks its grid).
static func ground_height(p: Vector3) -> float:
	if not fields.is_empty() and field_at(p) != null:
		return NAN
	if planet != null and is_instance_valid(planet) and planet.has_method(&"ground_height"):
		return planet.call(&"ground_height", p)
	return NAN


## A basis at `p` whose Y is up there and whose X and Z lie along the ground:
## the identity off a planet. For 2D maths on the ground (an orbit round a
## target, a ring of spots) that used to be done in the world's XZ.
static func tangent_basis(p: Vector3) -> Basis:
	if planet == null or not is_instance_valid(planet):
		return Basis.IDENTITY
	var u := up_at(p)
	var ref := Vector3.FORWARD if absf(u.dot(Vector3.FORWARD)) < 0.9 else Vector3.RIGHT
	var x := ref.cross(u).normalized()
	return Basis(x, u, x.cross(u))


## The basis `b` turned by the least rotation that takes its Y to `up`: how a
## body is carried along the curve, so nothing about its heading changes but
## what the ground's tilt demands (STA doc 05's full-basis rebuild).
static func carry(b: Basis, up: Vector3) -> Basis:
	var y := b.y.normalized()
	if y.is_equal_approx(up):
		return b
	return Basis(Quaternion(y, up)) * b


## `carry`, turning at most `max_angle` (radians) of the way: a body coming
## into a new down -- off a ship's deck into a planet's air -- rights itself
## over a moment instead of in a tick (zylanntest's PlayerController
## _orient_toward). Exactly `carry` once within `max_angle`.
static func carry_toward(b: Basis, up: Vector3, max_angle: float) -> Basis:
	var y := b.y.normalized()
	var ang := y.angle_to(up)
	if ang <= max_angle:
		return carry(b, up)
	var axis := y.cross(up)
	if axis.length_squared() < 1e-8:
		# Head down: over the body's own right.
		axis = b.x.normalized()
	return Basis(axis.normalized(), max_angle) * b


## The project's gravity as a vector at a world point.
static func at(p: Vector3) -> Vector3:
	return down_at(p) * strength()
