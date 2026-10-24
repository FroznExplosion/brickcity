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


## The project's gravity, m/s^2 (physics/3d/default_gravity); the planet's on one.
static func strength() -> float:
	if planet != null:
		return planet_strength
	if _strength < 0.0:
		_strength = float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8))
	return _strength


## Unit vector down at a world point: toward the planet's centre on one.
static func down_at(p: Vector3) -> Vector3:
	if planet != null and is_instance_valid(planet):
		var d := planet.global_position - p
		if d.length_squared() > 1e-6:
			return d.normalized()
	return Vector3.DOWN


## Unit vector up at a world point: away from the ground.
static func up_at(p: Vector3) -> Vector3:
	if planet != null and is_instance_valid(planet):
		return -down_at(p)
	return Vector3.UP


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
	if planet != null and is_instance_valid(planet):
		return (p - planet.global_position).length() - planet_radius
	return p.y


## `p` moved along its up to stand at height `h` (was `Vector3(p.x, h, p.z)`).
static func lift_to(p: Vector3, h: float) -> Vector3:
	if planet != null and is_instance_valid(planet):
		return p + up_at(p) * (h - height_of(p))
	return Vector3(p.x, h, p.z)


## The basis `b` turned by the least rotation that takes its Y to `up`: how a
## body is carried along the curve, so nothing about its heading changes but
## what the ground's tilt demands (STA doc 05's full-basis rebuild).
static func carry(b: Basis, up: Vector3) -> Basis:
	var y := b.y.normalized()
	if y.is_equal_approx(up):
		return b
	return Basis(Quaternion(y, up)) * b


## The project's gravity as a vector at a world point.
static func at(p: Vector3) -> Vector3:
	return down_at(p) * strength()
