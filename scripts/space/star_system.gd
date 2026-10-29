class_name StarSystem
extends RefCounted

## One star and the bodies round it (Docs/Planets.md 11.12). After STA's
## StarSystemData (C:\Users\lbaun\Documents\sta\scripts\resources\
## star_system_data.gd): every position and turn is a pure function of the
## clock -- never integrated, so nothing drifts and every peer agrees -- in the
## SPACE frame, the star at its origin. PlanetSystem places that frame in the
## world.
##
## Each body is a PlanetData with its orbit (round `parent`, -1 the star) and
## its spin (about its `climate_axis`, planet-local: the equator is warm because
## the sun stands over it).

var system_name := "system"
var system_seed := 0
var star_radius := 40000.0
var star_color := Color(1.0, 0.95, 0.85)
## Relative to the home star's (1).
var luminosity := 1.0
## The orbit at which a world is as warm as home: the star's light there is home's.
var habitable := 2000000.0
var bodies: Array[PlanetData] = []
## Stations and satellites, round the bodies (step 2).
var orbitals: Array[OrbitalData] = []
## The home planet's index, or -1.
var home := -1

## STA's orbital speeds (solar_system.gd: "orbital velocities ~170/190/196
## m/s", the moon ~440 m/s at 2.8 R): the innermost planet at V_IN, the rest
## slower by Kepler, `v ~ a^-1/2`. STA's PERIODS (8-16 min) on our orbits
## would make a year shorter than a day and the sun run backwards; its speeds
## make years of hours against days of minutes.
const V_IN := 200.0
## A moon at MOON_REF radii of its parent goes at V_MOON.
const V_MOON := 440.0
const MOON_REF := 2.8
## The home star's habitable orbit; another star's goes with the root of its light.
const HABITABLE := 2000000.0
## Sea-level temperature a world at the habitable orbit has (K), for the
## warmth of the rest: T ~ (L / a^2)^(1/4).
const T_HOME_K := 288.0


# --- where things are --------------------------------------------------------

## The plane a body orbits in: its normal and the direction at phase 0.
static func _plane(d: PlanetData) -> Basis:
	return Basis(Vector3.UP, d.orbit_node) * Basis(Vector3.RIGHT, d.orbit_inclination)


## Body `i`'s place round its parent at time `t`, space frame.
func orbit_offset(i: int, t: float) -> Vector3:
	var d := bodies[i]
	if d.orbit_radius <= 0.0:
		return Vector3.ZERO
	var q := _plane(d)
	var a := d.orbit_phase + (TAU * t / d.orbit_period if d.orbit_period > 0.0 else 0.0)
	return Basis(q.y, a) * q.x * d.orbit_radius


## Body `i`'s place at time `t`, space frame (a moon's adds its parent's).
func pos(i: int, t: float) -> Vector3:
	var p := Vector3.ZERO
	var k := i
	for _n in 8:
		if k < 0:
			break
		p += orbit_offset(k, t)
		k = bodies[k].parent
	return p


## Body `i`'s velocity at time `t`, space frame: the derivative of pos().
func vel(i: int, t: float) -> Vector3:
	var v := Vector3.ZERO
	var k := i
	for _n in 8:
		if k < 0:
			break
		var d := bodies[k]
		if d.orbit_period > 0.0:
			v += _plane(d).y.cross(orbit_offset(k, t)) * (TAU / d.orbit_period)
		k = bodies[k].parent
	return v


## Body `i`'s turn at time `t`: planet-local to space.
func spin(i: int, t: float) -> Basis:
	var d := bodies[i]
	var a := d.spin_phase + (TAU * t / d.day if d.day > 0.0 else 0.0)
	return d.tilt * Basis(d.climate_axis.normalized(), a)


## Body `i`'s angular velocity, space frame (rad/s along its axis).
func omega(i: int) -> Vector3:
	var d := bodies[i]
	if d.day <= 0.0:
		return Vector3.ZERO
	return d.tilt * d.climate_axis.normalized() * (TAU / d.day)


## Body `i`'s frame at time `t`: planet-local to space.
func xform(i: int, t: float) -> Transform3D:
	return Transform3D(spin(i, t), pos(i, t))


## The velocity, space frame, of the point `x` (space frame) held fixed in body
## `i`'s turning frame: what its ground would carry you at, there.
func frame_velocity(i: int, t: float, x: Vector3) -> Vector3:
	return vel(i, t) + omega(i).cross(x - pos(i, t))


# --- frames: bodies, then what orbits them ---------------------------------------

## Frame `f`: body `f`, or past the bodies orbitals[f - bodies.size()].
func frame_count() -> int:
	return bodies.size() + orbitals.size()


func frame_xform(f: int, t: float) -> Transform3D:
	return xform(f, t) if f < bodies.size() else orbital_xform(f - bodies.size(), t)


## The space-frame velocity of the point `x` held fixed in frame `f`.
func frame_velocity_of(f: int, t: float, x: Vector3) -> Vector3:
	if f < bodies.size():
		return frame_velocity(f, t, x)
	var o := orbitals[f - bodies.size()]
	var om := Basis(Vector3.UP, o.orbit_node) * Basis(Vector3.RIGHT, o.orbit_inclination) * Vector3.UP * (TAU / o.orbit_period)
	return vel(o.parent, t) + om.cross(x - pos(o.parent, t))


## Orbital `k` at time `t`: its +Y away from its body, +X along its way.
func orbital_xform(k: int, t: float) -> Transform3D:
	var o := orbitals[k]
	var q := Basis(Vector3.UP, o.orbit_node) * Basis(Vector3.RIGHT, o.orbit_inclination)
	var r := Basis(q.y, o.orbit_phase + TAU * t / o.orbit_period) * q.x
	var along := q.y.cross(r)
	return Transform3D(Basis(along, r, along.cross(r)), pos(o.parent, t) + r * o.orbit_radius)


## The star's direction from body `i`, in its own planet-local frame.
func sun_local(i: int, t: float) -> Vector3:
	return spin(i, t).inverse() * (-pos(i, t)).normalized()


## The spin phase that puts the sun straight over planet-local `dir` of body
## `i` at time `t` (noon there), keeping its day.
func noon_phase(i: int, dir: Vector3, t: float) -> float:
	var d := bodies[i]
	var keep := d.spin_phase
	var best := 0.0
	var best_dot := -2.0
	for k in 720:
		d.spin_phase = TAU * k / 720.0
		var c := (spin(i, t) * dir).dot((-pos(i, t)).normalized())
		if c > best_dot:
			best_dot = c
			best = d.spin_phase
	d.spin_phase = keep
	return best


# --- what there is ------------------------------------------------------------

## A system from its seed. With `home_data`, that planet is put on the orbit
## nearest the habitable one (its sea, ground and towns its own; only its orbit
## and spin are set here) and the system is home's.
static func generate(p_seed: int, home_data: PlanetData = null) -> StarSystem:
	var s := StarSystem.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(str("system:", p_seed))
	s.system_seed = p_seed
	s.system_name = _name(rng)
	s.luminosity = 1.0 if home_data != null else rng.randf_range(0.4, 2.2)
	s.habitable = HABITABLE * sqrt(s.luminosity)
	s.star_radius = clampf(40000.0 * pow(s.luminosity, 0.4) * rng.randf_range(0.8, 1.2), 25000.0, 60000.0)
	s.star_color = _star_colour(s.luminosity, rng)
	var n := _weighted(rng, [0, 0, 1, 2, 4, 5, 4, 2, 1])
	var orbits: Array[float] = []
	var a := s.habitable * rng.randf_range(0.35, 0.55)
	for k in n:
		orbits.append(a)
		a *= rng.randf_range(1.5, 1.9)
	var home_k := -1
	if home_data != null:
		var best := INF
		for k in n:
			if absf(log(orbits[k] / s.habitable)) < best:
				best = absf(log(orbits[k] / s.habitable))
				home_k = k
		# Home is as warm as home: the rest are warmer or colder than it.
		s.habitable = orbits[home_k]
	for k in n:
		var d: PlanetData
		if k == home_k:
			d = home_data
		else:
			d = _planet(s, rng, k)
		d.orbit_radius = orbits[k]
		d.orbit_period = TAU * orbits[k] / (V_IN * sqrt(orbits[0] / orbits[k]))
		d.orbit_phase = rng.randf() * TAU
		d.orbit_inclination = rng.randf_range(-0.06, 0.06)
		d.orbit_node = rng.randf() * TAU
		d.parent = -1
		# A year of at least 8 days, or the sun would barely cross the sky.
		d.day = minf(rng.randf_range(600.0, 2400.0), d.orbit_period / 8.0)
		d.spin_phase = rng.randf() * TAU
		_tilt(d, rng.randf_range(0.0, deg_to_rad(30.0)), rng)
		if k == home_k:
			d.t_offset = 0.0
		else:
			d.t_offset = _warmth(s, orbits[k])
			# Boiled off, or frozen through: no sea.
			if d.t_offset > 35.0 or d.t_offset < -60.0:
				d.sea_level = NAN
		s.bodies.append(d)
		if d == home_data:
			s.home = s.bodies.size() - 1
		var pi := s.bodies.size() - 1
		var moons := _weighted(rng, [5, 3, 1]) if k > 0 or n < 3 else _weighted(rng, [3, 1])
		var mo := d.radius * rng.randf_range(8.0, 11.0)
		for m in moons:
			s.bodies.append(_moon(s, rng, pi, mo))
			mo *= rng.randf_range(1.3, 1.6)
	_add_orbitals(s)
	return s


## Stations and satellites round the planets with air (home: one station,
## three satellites -- the story's), each on a circular orbit at its own
## speed, `sqrt(g R^2 / r)`.
static func _add_orbitals(s: StarSystem) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(str("orbitals:", s.system_seed))
	for i in s.bodies.size():
		var p := s.bodies[i]
		if p.parent >= 0 or not p.has_air:
			continue
		var stations := 1 if i == s.home else _weighted(rng, [6, 3, 1])
		var sats := 3 if i == s.home else _weighted(rng, [3, 3, 2, 1])
		for k in stations + sats:
			var o := OrbitalData.new()
			o.kind = "station" if k < stations else "satellite"
			o.orbital_seed = rng.randi() & 0x7fffffff
			o.orbital_name = "%s %s %d" % [p.planet_name, o.kind, k + 1]
			o.parent = i
			o.orbit_radius = p.radius * (rng.randf_range(1.5, 2.4) if o.kind == "station" else rng.randf_range(1.3, 2.2))
			o.orbit_period = TAU * o.orbit_radius / sqrt(p.gravity_strength * p.radius * p.radius / o.orbit_radius)
			o.orbit_phase = rng.randf() * TAU
			o.orbit_inclination = rng.randf_range(-0.5, 0.5)
			o.orbit_node = rng.randf() * TAU
			o.fx = 32 + 4 * rng.randi_range(0, 4)
			o.fz = 32 + 4 * rng.randi_range(0, 4)
			o.courses = [12, 18, 24][rng.randi() % 3]
			o.colour = Color(0.82, 0.83, 0.86).lerp(Color.from_hsv(rng.randf(), 0.5, 0.8), 0.25)
			s.orbitals.append(o)


## A planet of its own: everything but its orbit and spin.
static func _planet(s: StarSystem, rng: RandomNumberGenerator, k: int) -> PlanetData:
	var d := PlanetData.new()
	d.planet_name = "%s %s" % [s.system_name, ["I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX"][k]]
	d.planet_seed = rng.randi() & 0x7fffffff
	d.radius = roundf(rng.randf_range(6000.0, 16000.0))
	d.gravity_strength = 9.8 * d.radius / 10000.0 * rng.randf_range(0.85, 1.15)
	d.amplitude = rng.randf_range(30.0, 120.0)
	d.period = rng.randf_range(600.0, 1500.0)
	d.ridged = rng.randf() < 0.3
	d.core_radius = d.radius - d.amplitude - 400.0
	d.climate_axis = _random_dir(rng)
	d.atmosphere_color = Color.from_hsv(rng.randf_range(0.5, 0.65) if rng.randf() < 0.7 else rng.randf(),
			rng.randf_range(0.35, 0.7), 1.0)
	d.has_air = rng.randf() < 0.8
	d.sea_level = rng.randf_range(-25.0, 5.0) if d.has_air else NAN
	return d


## A moon of body `parent` at orbit radius `a`: airless, dry, tidally locked.
static func _moon(s: StarSystem, rng: RandomNumberGenerator, parent: int, a: float) -> PlanetData:
	var p := s.bodies[parent]
	var d := PlanetData.new()
	d.planet_name = "%s %s" % [p.planet_name, "abc"[s.bodies.size() % 3]]
	d.planet_seed = rng.randi() & 0x7fffffff
	d.radius = roundf(rng.randf_range(2500.0, 5000.0))
	d.gravity_strength = 9.8 * d.radius / 10000.0 * rng.randf_range(0.6, 0.9)
	d.amplitude = rng.randf_range(20.0, 70.0)
	d.period = rng.randf_range(400.0, 900.0)
	d.ridged = rng.randf() < 0.5
	d.core_radius = d.radius - d.amplitude - 300.0
	d.sea_level = NAN
	d.has_air = false
	d.atmosphere_color = Color(0.0, 0.0, 0.0)
	d.parent = parent
	d.orbit_radius = a
	d.orbit_period = TAU * a / (V_MOON * sqrt(p.radius * MOON_REF / a))
	d.orbit_phase = rng.randf() * TAU
	d.orbit_inclination = rng.randf_range(-0.3, 0.3)
	d.orbit_node = rng.randf() * TAU
	# Tidally locked: one turn an orbit, about the orbit's own axis, so the same
	# face is always to its planet.
	d.day = d.orbit_period
	d.climate_axis = Vector3.UP
	d.tilt = _plane(d)
	d.spin_phase = d.orbit_phase
	d.t_offset = p.t_offset - 25.0
	return d


## Turn body `d`'s spin axis (planet-local `climate_axis`) to stand `obliquity`
## off its orbit's axis.
static func _tilt(d: PlanetData, obliquity: float, rng: RandomNumberGenerator) -> void:
	var n := _plane(d).y
	var side := n.cross(Vector3.RIGHT if absf(n.x) < 0.9 else Vector3.FORWARD).normalized()
	var axis := Basis(n, rng.randf() * TAU) * Basis(side, obliquity) * n
	d.tilt = Basis(Quaternion(d.climate_axis.normalized(), axis.normalized()))


## The sea-level temperature offset (C) of a world `a` from the star.
static func _warmth(s: StarSystem, a: float) -> float:
	return T_HOME_K * sqrt(s.habitable / a) - T_HOME_K


static func _random_dir(rng: RandomNumberGenerator) -> Vector3:
	var z := rng.randf_range(-1.0, 1.0)
	var a := rng.randf() * TAU
	var r := sqrt(1.0 - z * z)
	return Vector3(r * cos(a), z, r * sin(a))


## Index drawn by `weights`.
static func _weighted(rng: RandomNumberGenerator, weights: Array) -> int:
	var sum := 0.0
	for w in weights:
		sum += float(w)
	var x := rng.randf() * sum
	for i in weights.size():
		x -= float(weights[i])
		if x < 0.0:
			return i
	return weights.size() - 1


static func _star_colour(lum: float, rng: RandomNumberGenerator) -> Color:
	# Dim stars red-orange, bright ones white-blue.
	var warm := Color(1.0, 0.72, 0.45)
	var sun := Color(1.0, 0.95, 0.85)
	var hot := Color(0.82, 0.88, 1.0)
	var c := warm.lerp(sun, clampf((lum - 0.4) / 0.6, 0.0, 1.0)) if lum < 1.0 \
			else sun.lerp(hot, clampf((lum - 1.0) / 1.2, 0.0, 1.0))
	return c.lerp(Color.WHITE, rng.randf_range(0.0, 0.1))


static func _name(rng: RandomNumberGenerator) -> String:
	var a := ["Ka", "Ve", "Or", "Tal", "Mi", "Sor", "Bre", "Lun", "Ax", "Dra", "Hel", "Qu", "Ny", "Ser"]
	var b := ["ros", "lin", "dar", "phi", "mon", "tis", "gar", "ven", "lux", "ra", "nox", "dor"]
	return str(a[rng.randi() % a.size()], b[rng.randi() % b.size()])
