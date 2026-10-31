class_name Universe
extends RefCounted

## The universe (Docs/Planets.md 11.12): a seed, and star systems that are pure
## functions of it and their index -- nothing stored, every peer and every
## visit the same. System 0 is home's: the home planet goes into it
## (StarSystem.generate). The others are only made when asked for.

## Light years are not ours to cross: a system's place in the galaxy is for
## the map and for jumps (step 5), in light years on a disc.
const DISC_LY := 40000.0
const THICK_LY := 600.0
## How many systems there are to go to.
const SYSTEMS := 400

var universe_seed := 1


func _init(p_seed := 1) -> void:
	universe_seed = p_seed


func system_seed(i: int) -> int:
	return hash(str("universe:", universe_seed, ":", i)) & 0x7fffffff


## System `i`'s place in the galaxy, light years; home's at the origin.
func system_position(i: int) -> Vector3:
	if i == 0:
		return Vector3.ZERO
	var rng := RandomNumberGenerator.new()
	rng.seed = system_seed(i) ^ 0x5EED
	var r := DISC_LY * sqrt(rng.randf())
	var a := rng.randf() * TAU
	return Vector3(r * cos(a), rng.randfn(0.0, THICK_LY / 3.0), r * sin(a))


## The `n` systems nearest system `i`, nearest first.
func nearest(i: int, n: int) -> Array[int]:
	var from := system_position(i)
	var d := []
	for k in SYSTEMS:
		if k != i:
			d.append([from.distance_squared_to(system_position(k)), k])
	d.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	var out: Array[int] = []
	for e in d.slice(0, n):
		out.append(int(e[1]))
	return out


## System `i`; `home_data` the home planet, for system 0.
func system(i: int, home_data: PlanetData = null) -> StarSystem:
	return StarSystem.generate(system_seed(i), home_data if i == 0 else null)
