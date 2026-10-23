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
	return -down_at(p)


## The project's gravity as a vector at a world point.
static func at(p: Vector3) -> Vector3:
	return down_at(p) * strength()
