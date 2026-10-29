class_name OrbitalData
extends Resource

## Something built that orbits a body (Docs/Planets.md 11.12 step 2; after STA's
## OrbitalEntry / OrbitalUnit): a station you can land on and walk into, or a
## satellite. Its orbit as a PlanetData's (StarSystem's clockwork); it turns
## once an orbit, its +Y away from its body -- the deck's floor faces the
## planet below -- as a station held by gravity gradient would.

## "station" or "satellite".
@export var kind := "station"
@export var orbital_name := "station"
@export var orbital_seed := 1
@export var parent := 0
@export var orbit_radius := 20000.0
@export var orbit_period := 600.0
@export var orbit_phase := 0.0
@export var orbit_inclination := 0.0
@export var orbit_node := 0.0
## A station's module, as a tower's (TowerRecipe): footprint in studs, courses.
@export var fx := 40
@export var fz := 40
@export var courses := 18
@export var colour := Color(0.8, 0.8, 0.82)
## Down on its deck, m/s^2 (artificial gravity).
@export var gravity := 9.8
