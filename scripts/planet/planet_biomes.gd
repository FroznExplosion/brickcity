class_name PlanetBiomes
extends RefCounted

## A planet's climate and biomes (Docs/Planets.md 11.9). After STA's
## PlanetFields (C:\Users\lbaun\Documents\sta\scripts\generation\planet_fields.gd),
## trimmed: temperature by latitude (about `PlanetData.climate_axis`) less a
## lapse with height, humidity by noise, a biome from a short table by the two.
## Everything that colours the ground reads this -- the baked map the ground
## shader samples, the impostor, later the trees -- so they agree.

## Sea-level temperature, degrees C, at the climate's equator and poles.
const T_EQUATOR := 30.0
const T_POLE := -22.0
## Degrees C lost a metre up. Far over Earth's 0.0065: hills here are tens of
## metres, and a cold summit is what a snowcap is.
const LAPSE := 0.25
## How far (degrees of latitude) the temperature bands wobble, and the ragged
## edges between biomes (degrees C and humidity added before the lookup).
const WOBBLE_DEG := 9.0
const RAGGED_T := 2.5
const RAGGED_H := 0.06
## The mean humidity: over 0.5 for a greener world than a dry one.
const HUMID_MEAN := 0.62
## The temperature range the map's alpha stores (sea level).
const T_RANGE := Vector2(-30.0, 40.0)

## {name, colour, dry: its colour where the ground is drier, t: Vector2 band (C,
## sea level), h: Vector2 humidity band}. First in-band wins; none: nearest.
const TABLE := [
	{"name": "tundra", "colour": Color(0.55, 0.56, 0.47), "dry": Color(0.62, 0.60, 0.52),
			"t": Vector2(-100.0, -2.0), "h": Vector2(0.0, 1.0)},
	{"name": "taiga", "colour": Color(0.21, 0.32, 0.23), "dry": Color(0.30, 0.37, 0.27),
			"t": Vector2(-2.0, 7.0), "h": Vector2(0.35, 1.0)},
	{"name": "steppe", "colour": Color(0.53, 0.52, 0.34), "dry": Color(0.62, 0.58, 0.40),
			"t": Vector2(-2.0, 19.0), "h": Vector2(0.0, 0.35)},
	{"name": "temperate forest", "colour": Color(0.23, 0.39, 0.19), "dry": Color(0.30, 0.43, 0.23),
			"t": Vector2(7.0, 19.0), "h": Vector2(0.58, 1.0)},
	{"name": "temperate grass", "colour": Color(0.36, 0.47, 0.27), "dry": Color(0.47, 0.50, 0.30),
			"t": Vector2(7.0, 19.0), "h": Vector2(0.35, 0.58)},
	{"name": "desert", "colour": Color(0.80, 0.69, 0.47), "dry": Color(0.86, 0.75, 0.54),
			"t": Vector2(19.0, 100.0), "h": Vector2(0.0, 0.32)},
	{"name": "savanna", "colour": Color(0.60, 0.56, 0.30), "dry": Color(0.68, 0.60, 0.34),
			"t": Vector2(19.0, 100.0), "h": Vector2(0.32, 0.62)},
	{"name": "jungle", "colour": Color(0.15, 0.35, 0.14), "dry": Color(0.22, 0.40, 0.18),
			"t": Vector2(19.0, 100.0), "h": Vector2(0.62, 1.0)},
]

var data: PlanetData
var axis := Vector3.UP
var _wob: ZN_FastNoiseLite
var _hum: ZN_FastNoiseLite
var _patch: ZN_FastNoiseLite
var _mot: ZN_FastNoiseLite


static func of(p_data: PlanetData) -> PlanetBiomes:
	var b := PlanetBiomes.new()
	b.data = p_data
	b.axis = p_data.climate_axis.normalized()
	b._wob = b._noise("wobble", 4000.0, 2)
	b._hum = b._noise("humidity", 2600.0, 3)
	b._patch = b._noise("patch", 220.0, 2)
	b._mot = b._noise("mottle", 90.0, 2)
	return b


func _noise(salt: String, period: float, octaves: int) -> ZN_FastNoiseLite:
	var zn := ZN_FastNoiseLite.new()
	zn.seed = hash(str(data.planet_seed, ":", salt)) & 0x7fffffff
	zn.noise_type = ZN_FastNoiseLite.TYPE_OPEN_SIMPLEX_2
	zn.fractal_type = ZN_FastNoiseLite.FRACTAL_FBM
	zn.period = period
	zn.fractal_octaves = octaves
	return zn


## Latitude about the climate's axis, degrees, wobbled.
func latitude(dir: Vector3) -> float:
	var p := dir * data.radius
	return rad_to_deg(asin(clampf(dir.dot(axis), -1.0, 1.0))) + _wob.get_noise_3dv(p) * WOBBLE_DEG


## Temperature at sea level along unit `dir`, degrees C.
func temperature_sea(dir: Vector3) -> float:
	var t01 := cos(deg_to_rad(clampf(absf(latitude(dir)), 0.0, 90.0)))
	return lerpf(T_POLE, T_EQUATOR, t01) + data.t_offset


## Temperature on the ground `h` metres over the datum.
static func temperature_at(t_sea: float, h: float) -> float:
	return t_sea - LAPSE * maxf(h, 0.0)


## 0 (dry) .. 1 (wet).
func humidity(dir: Vector3) -> float:
	return clampf(HUMID_MEAN + 0.9 * _hum.get_noise_3dv(dir * data.radius), 0.0, 1.0)


## The biome's index in TABLE along unit `dir` (by its sea-level temperature:
## a hill's top is the same biome as its foot, only colder -- snow is the
## shader's, from the temperature at the height).
func biome_index(dir: Vector3) -> int:
	var p := dir * data.radius
	var rag := _patch.get_noise_3dv(p)
	var t := temperature_sea(dir) + rag * RAGGED_T
	var h := humidity(dir) + rag * RAGGED_H
	for i in TABLE.size():
		var e: Dictionary = TABLE[i]
		if t >= e.t.x and t < e.t.y and h >= e.h.x and h < e.h.y:
			return i
	var best := 0
	var best_d := INF
	for i in TABLE.size():
		var e: Dictionary = TABLE[i]
		var d := _band_dist(t, e.t) + _band_dist(h, e.h) * 30.0
		if d < best_d:
			best_d = d
			best = i
	return best


static func _band_dist(v: float, band: Vector2) -> float:
	return maxf(band.x - v, 0.0) + maxf(v - band.y, 0.0)


## The ground's base colour along `dir`: the biome's, toward its dry colour by
## a slow mottle and the dryness there.
func colour(dir: Vector3) -> Color:
	return _colour_of(dir, biome_index(dir))


func _colour_of(dir: Vector3, index: int) -> Color:
	var e: Dictionary = TABLE[index]
	var m := clampf(0.5 + 0.6 * _mot.get_noise_3dv(dir * data.radius) + (0.5 - humidity(dir)) * 0.6, 0.0, 1.0)
	return (e.colour as Color).lerp(e.dry, m)


## The equirect map the ground shader samples: RGB the base colour, A the
## sea-level temperature in T_RANGE. The impostor's convention:
## dir = (cos lat sin lon, sin lat, cos lat cos lon), v = 0 at the north.
static func dir_of_pixel(x: int, y: int, width: int, height_px: int) -> Vector3:
	var lat := (0.5 - (float(y) + 0.5) / float(height_px)) * PI
	var lon := ((float(x) + 0.5) / float(width) - 0.5) * TAU
	return Vector3(cos(lat) * sin(lon), sin(lat), cos(lat) * cos(lon))


## The pixel (x, y) a direction samples, as the shader computes its UV.
static func pixel_of_dir(dir: Vector3, width: int, height_px: int) -> Vector2i:
	var lat := asin(clampf(dir.y, -1.0, 1.0))
	var lon := atan2(dir.x, dir.z)
	var u := lon / TAU + 0.5
	var v := 0.5 - lat / PI
	return Vector2i(clampi(int(u * width), 0, width - 1), clampi(int(v * height_px), 0, height_px - 1))


func pixel(dir: Vector3) -> Color:
	return pixel_index(dir)[0]


## pixel() and the biome's index, from one lookup: [Color, int].
func pixel_index(dir: Vector3) -> Array:
	var i := biome_index(dir)
	var c := _colour_of(dir, i)
	c.a = clampf(inverse_lerp(T_RANGE.x, T_RANGE.y, temperature_sea(dir)), 0.0, 1.0)
	return [c, i]
