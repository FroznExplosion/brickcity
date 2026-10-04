class_name WeatherFx
extends RefCounted

## Weather on surfaces (Docs/Disasters.md 19): how wet everything is, and the
## wind that sways trees and buildings. The uniforms are in
## shaders/weather.gdshaderinc; this puts the values into every material that
## draws with it.
##
## A material is registered where it is made (the city's and the heightfield's
## brick, terrain and far materials, the terrain pieces', impostor cards), and
## a copy made from a registered one is adopted (ImpostorLod's fading copies:
## `duplicate()` takes the parameters as they are, and would not follow).
##
## Sway is per object: `sway_tree` and `sway_building` give the instance
## parameter a tree or a standing building carries.

## Soaked: 1. Set through set_weather, eased by the disaster context.
static var wet := 0.0
## Rain falling now, 0..1: ripples and running streaks.
static var rain := 0.0
## Snow lying, 0..1 (SnowCover, snow.gdshader, the caps).
static var snow := 0.0
## Direction x strength, 0..~1.
static var wind := Vector3.ZERO

static var _mats: Array[WeakRef] = []
static var _ids := {}
## Plain materials with no weather in their shader -- the small city's flat
## ground -- tinted instead: [weakref, colour, roughness] as they were made.
static var _tints: Array = []
const SNOW_WHITE := Color(0.9, 0.92, 0.96)

## How far a tree's crown and a tower's top lean at wind 1, per metre of height,
## and how fast each sways.
const TREE_LEAN := 0.05
const TREE_HZ := 0.55
const BUILDING_LEAN := 0.0015
const BUILDING_HZ := 0.22
const GRASS_LEAN := 0.45
const GRASS_HZ := 1.1


## Its next passes too: the glass pass of a brick material sways with it.
static func register(m: Material) -> void:
	if not (m is ShaderMaterial):
		return
	var id := m.get_instance_id()
	if _ids.has(id):
		return
	_ids[id] = true
	_mats.append(weakref(m))
	_apply(m as ShaderMaterial)
	if m.next_pass != null:
		register(m.next_pass)


## A plain StandardMaterial3D: white as the snow lies, darker and glossier wet.
static func register_tint(m: StandardMaterial3D) -> void:
	if m == null:
		return
	_tints.append([weakref(m), m.albedo_color, m.roughness])
	_tint(_tints[_tints.size() - 1])


static func _tint(t: Array) -> void:
	var m = (t[0] as WeakRef).get_ref()
	if m == null:
		return
	var base: Color = t[1]
	var col := base.darkened(0.25 * wet).lerp(SNOW_WHITE, clampf(snow * 1.3, 0.0, 1.0))
	(m as StandardMaterial3D).albedo_color = col
	(m as StandardMaterial3D).roughness = lerpf(float(t[2]), 0.3, wet * (1.0 - snow))


## `copy` was made from `source`: if the source is weathered, so is the copy.
static func adopt(copy: Material, source: Material) -> void:
	if source != null and _ids.has(source.get_instance_id()):
		register(copy)


static func is_registered(m: Material) -> bool:
	return m != null and _ids.has(m.get_instance_id())


## Into every registered material, if it moved enough to see.
static func set_weather(p_wet: float, p_wind: Vector3, p_rain := 0.0, p_snow := 0.0) -> void:
	p_wet = clampf(p_wet, 0.0, 1.0)
	p_rain = clampf(p_rain, 0.0, 1.0)
	p_snow = clampf(p_snow, 0.0, 1.0)
	if absf(p_snow - snow) >= 0.004 or (p_snow == 0.0 and snow != 0.0):
		snow = p_snow
		for r in _mats:
			var sm = r.get_ref()
			if sm != null:
				(sm as ShaderMaterial).set_shader_parameter("weather_snow", snow)
		for t in _tints:
			_tint(t)
	if absf(p_wet - wet) < 0.004 and p_wind.distance_to(wind) < 0.004 and absf(p_rain - rain) < 0.01 \
			and not (p_wet == 0.0 and wet != 0.0) and not (p_wind == Vector3.ZERO and wind != Vector3.ZERO) \
			and not (p_rain == 0.0 and rain != 0.0):
		return
	wet = p_wet
	wind = p_wind
	rain = p_rain
	for t in _tints:
		_tint(t)
	var live: Array[WeakRef] = []
	for r in _mats:
		var m = r.get_ref()
		if m == null:
			continue
		live.append(r)
		_apply(m)
	if live.size() != _mats.size():
		_mats = live
		_ids.clear()
		for r in _mats:
			_ids[(r.get_ref() as Object).get_instance_id()] = true


static func _apply(m: ShaderMaterial) -> void:
	m.set_shader_parameter("weather_wet", wet)
	m.set_shader_parameter("weather_wind", wind)
	m.set_shader_parameter("weather_rain", rain)
	m.set_shader_parameter("weather_snow", snow)


## The instance parameter for a tree `height` metres tall.
static func sway_tree(height: float) -> Vector3:
	return Vector3(height, TREE_LEAN, TREE_HZ)


static func sway_grass(height: float) -> Vector3:
	return Vector3(height, GRASS_LEAN, GRASS_HZ)


static func sway_building(height: float) -> Vector3:
	return Vector3(height, BUILDING_LEAN, BUILDING_HZ)
