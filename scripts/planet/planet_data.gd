class_name PlanetData
extends Resource

## Everything one planet is made from (Docs/Planets.md 11). After STA's
## `PlanetData` (C:\Users\lbaun\Documents\sta\scripts\resources\planet_data.gd),
## trimmed to what an indestructible planet needs: no caves, no edit stream, no
## water simulation. The same numbers feed the voxel generator, the impostor
## bake and every CPU height query, so the three always agree.

@export var planet_name := "planet"
## Feeds every noise. Not called `seed`: that shadows GDScript's seed().
@export var planet_seed := 1
## The ground's datum, metres from the centre.
@export var radius := 10000.0
## Solid below this whatever the noise says: nothing is ever meshed inside.
@export var core_radius := 9000.0
## The sea's surface over the datum (negative: in the valleys). NAN: no sea.
@export var sea_level := -6.0
## m/s^2 at the surface, toward the centre.
@export var gravity_strength := 9.8
@export var atmosphere_color := Color(0.45, 0.65, 1.0)
@export var ground_color := Color(0.42, 0.47, 0.36)

## The relief: hills of `amplitude` metres at noise 1, a `period`-metre wavelength,
## ridged (1 - 2|n|) for ridgelines instead of round hills.
@export var amplitude := 55.0
@export var period := 900.0
@export var octaves := 5
@export var ridged := false

## The axis the climate's latitude is measured about (PlanetBiomes, Planets.md
## 11.9): warm round its equator, cold at its poles. The default puts the
## proto's spawn (scenes/planet.tscn, near +Y) at ~50 degrees: temperate.
@export var climate_axis := Vector3(0.7, 0.7, 0.0)

## Its place in a star system (Planets.md 11.12; StarSystem computes from these,
## STA's analytic orbits): round body `parent` (an index in the system's bodies,
## -1 the star) at `orbit_radius` metres once every `orbit_period` seconds (0:
## holds still), in the plane turned `orbit_inclination` about X and then
## `orbit_node` about Y, `orbit_phase` radians along it at time 0.
@export var parent := -1
@export var orbit_radius := 0.0
@export var orbit_period := 0.0
@export var orbit_phase := 0.0
@export var orbit_inclination := 0.0
@export var orbit_node := 0.0
## One turn about `climate_axis` every `day` seconds (0: none), `spin_phase`
## radians at time 0; `tilt` takes planet-local to space at phase 0 (where the
## axis points: the axial tilt).
@export var day := 0.0
@export var spin_phase := 0.0
@export var tilt := Basis()
## Degrees C on every biome's temperature: the star's warmth at this orbit
## against home's (PlanetBiomes).
@export var t_offset := 0.0
## An atmosphere: its shell, its sky. Moons have none.
@export var has_air := true

## Flat pads the ground is levelled to, for buildings to stand on (Planets.md 11.2):
## each {dir: Vector3 (unit, planet-local), height: float (over the datum),
## flat: float (metres of level ground from the centre), blend: float (metres of
## slope from the pad's edge to the natural ground)}.
@export var pads: Array[Dictionary] = []


## The relief noise, as the generator and the CPU both sample it.
func height_noise() -> ZN_FastNoiseLite:
	var zn := ZN_FastNoiseLite.new()
	zn.seed = hash(str(planet_seed, ":relief")) & 0x7fffffff
	zn.noise_type = ZN_FastNoiseLite.TYPE_OPEN_SIMPLEX_2
	zn.fractal_type = ZN_FastNoiseLite.FRACTAL_FBM
	zn.period = period
	zn.fractal_octaves = octaves
	return zn


var _noise: ZN_FastNoiseLite


## Height of the natural ground over the datum along unit `dir`, before pads.
func relief(dir: Vector3) -> float:
	if _noise == null:
		_noise = height_noise()
	var p := dir * radius
	var n := _noise.get_noise_3d(p.x, p.y, p.z)
	if ridged:
		n = 1.0 - 2.0 * absf(n)
	return n * amplitude


## Height of the ground over the datum along unit `dir`, pads included: what
## the voxel generator makes (PlanetGraph), to the precision of its noise.
func height(dir: Vector3) -> float:
	var h := relief(dir)
	for pad in pads:
		var d: float = (dir * radius).distance_to((pad.dir as Vector3) * radius)
		var w := clampf((float(pad.flat) + float(pad.blend) - d) / maxf(float(pad.blend), 0.001), 0.0, 1.0)
		h = lerpf(h, float(pad.height), w)
	return h


## The point on the ground along unit `dir`, planet-local.
func surface_point(dir: Vector3) -> Vector3:
	return dir * (radius + height(dir))


## How far the tallest ground stands over the datum.
func peak() -> float:
	var top := amplitude
	for pad in pads:
		top = maxf(top, float(pad.height))
	return top
