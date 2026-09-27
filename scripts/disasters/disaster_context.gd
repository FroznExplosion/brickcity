class_name DisasterContext
extends RefCounted

## The city as a disaster sees it (Docs/Disasters.md section 1.3).
##
## Every change to a brick goes through the city's own doors -- _blast and chip
## -- so it is requested of the world authority, committed to the damage log and
## applied from the damage queue under its per-tick budget, exactly as a gun's
## hit is. A disaster never reaches into city_scene itself: when it needs
## something new, the call goes here.

var city: Node3D
var registry: BuildingRegistry
var islands: IslandManager

## Camera shake still owed, in metres of offset; decays in step().
var _shake := 0.0
const SHAKE_DECAY := 6.0       ## per second, exponential
const SHAKE_MAX := 0.6

## What the sky and sun were before any disaster touched them; filled the first
## time set_sky is called, and put back exactly when the amount returns to 0.
var _sky_base := {}


func _init(city_node: Node3D) -> void:
	city = city_node
	registry = city.registry
	islands = city.islands


# --- Changing bricks: through the authority, like a gun -------------------

## Destroy bricks in a ball. Queued; applied on a later tick.
func blast(point: Vector3, radius: float) -> void:
	city._blast(point, radius)


## Wear bricks in a ball by `hp`: weakens, kills only what runs out.
func chip(point: Vector3, radius: float, hp: int) -> void:
	city.chip(point, radius, hp)


# --- Asking about the world -------------------------------------------------

## First thing a segment hits: a physics body on the hitscan layers, or a
## building that has no node yet (the recipes, as the city's own _fire does --
## a meteor must be able to hit a tower on the horizon). {} for nothing;
## otherwise {"position", "normal"} and "building" when it was a recipe.
func ray(from: Vector3, to: Vector3) -> Dictionary:
	var space: PhysicsDirectSpaceState3D = city.get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.collision_mask = Layers.HITSCAN_MASK
	var hit := space.intersect_ray(q)
	var far: Dictionary = city._ray_recipes(from, to)
	if not far.is_empty() and (hit.is_empty()
			or from.distance_to(far.position) < from.distance_to(hit.position)):
		return {"position": far.position, "normal": (from - to).normalized(),
				"building": far.building}
	if hit.is_empty():
		return {}
	var layer := 0
	if hit.collider is CollisionObject3D:
		layer = (hit.collider as CollisionObject3D).collision_layer
	return {"position": hit.position, "normal": hit.normal, "layer": layer}


## The tallest standing building whose footprint centre is within `radius` of
## `point` (on the ground plane). {} when there is none; otherwise
## {"building": id, "box": AABB, "top": the roof's centre}. Reads recipes, so it
## costs nothing and materialises nothing.
func tallest_near(point: Vector3, radius: float) -> Dictionary:
	var best := {}
	var best_top := -INF
	var r2 := radius * radius
	for b in registry.buildings:
		if b.toppled:
			continue
		var box := CityPlacer.box_of(b)
		var c := box.get_center()
		if Vector2(c.x - point.x, c.z - point.z).length_squared() > r2:
			continue
		if box.end.y > best_top:
			best_top = box.end.y
			best = {"building": b.id, "box": box, "top": Vector3(c.x, box.end.y, c.z)}
	return best


## The standing building whose box holds `point` (within `margin`), or -1.
func building_at(point: Vector3, margin := 0.3) -> int:
	for b in registry.buildings:
		if not b.toppled and CityPlacer.box_of(b).grow(margin).has_point(point):
			return b.id
	return -1


## Every building's box, standing ones only. For picking targets.
func building_boxes() -> Array[AABB]:
	var out: Array[AABB] = []
	for b in registry.buildings:
		if not b.toppled:
			out.append(CityPlacer.box_of(b))
	return out


## Start a fire at `point`. Fire is D3 (Docs/Disasters.md section 5): until it
## exists this does nothing, but callers roll for it now so their seeds do not
## shift when it arrives.
func ignite(_point: Vector3, _heat: float) -> void:
	pass


## Material index of the brick at `point`, -1 for none. Walks every building:
## callers that ask often must cache (Docs/Disasters.md section 5.3).
func material_at(point: Vector3) -> int:
	return city._material_fx.material_at(point)


## Loose pieces whose centre is within `radius` of `point`.
func islands_near(point: Vector3, radius: float) -> Array[BrickIsland]:
	var out: Array[BrickIsland] = []
	var r2 := radius * radius
	for isl in islands.islands:
		if is_instance_valid(isl.body) and isl.body.global_position.distance_squared_to(point) <= r2:
			out.append(isl)
	return out


func wake_near(point: Vector3, radius: float) -> void:
	islands.wake_near(point, radius)


## The mark, debris and sound of whatever is struck at `point`. Cosmetic, local.
func impact_fx(point: Vector3, normal: Vector3) -> void:
	if city._material_fx != null and not city._material_fx.impact_at(point, normal):
		city._material_fx.impact(point, normal, 0, Color(0.6, 0.6, 0.6))


# --- The player ---------------------------------------------------------------

## Where the player is looking from: the camera, whatever it is attached to.
func player_pos() -> Vector3:
	return city.camera.global_position


## Shake the view from something at `point`. `strength` is metres of offset at
## the source, halving every 20 m.
func shake(point: Vector3, strength: float) -> void:
	var d := point.distance_to(player_pos())
	_shake = minf(SHAKE_MAX, _shake + strength * pow(0.5, d / 20.0))


## Called by the director every frame: applies and decays the shake.
func step(delta: float) -> void:
	var cam: Camera3D = city.camera
	if _shake < 0.001:
		_shake = 0.0
		cam.h_offset = 0.0
		cam.v_offset = 0.0
		return
	cam.h_offset = randf_range(-_shake, _shake)
	cam.v_offset = randf_range(-_shake, _shake)
	_shake *= exp(-SHAKE_DECAY * delta)


# --- The sky ------------------------------------------------------------------

## Tint the sky and sun towards a mood: `amount` 0 is the city's own sky, 1 is
## the given colours in full. Disasters ease `amount` up in WARNING and back
## down in ENDING; at 0 every value is put back exactly as it was.
func set_sky(amount: float, sun_colour: Color, top: Color, horizon: Color,
		sun_energy_mul: float) -> void:
	var sun: DirectionalLight3D = city._sun
	var mat := _sky_material()
	if _sky_base.is_empty():
		_sky_base = {"sun_colour": sun.light_color, "sun_energy": sun.light_energy}
		if mat != null:
			_sky_base.top = mat.sky_top_color
			_sky_base.horizon = mat.sky_horizon_color
			_sky_base.ground_horizon = mat.ground_horizon_color
	var a := clampf(amount, 0.0, 1.0)
	sun.light_color = (_sky_base.sun_colour as Color).lerp(sun_colour, a)
	sun.light_energy = float(_sky_base.sun_energy) * lerpf(1.0, sun_energy_mul, a)
	if mat != null:
		mat.sky_top_color = (_sky_base.top as Color).lerp(top, a)
		mat.sky_horizon_color = (_sky_base.horizon as Color).lerp(horizon, a)
		mat.ground_horizon_color = (_sky_base.ground_horizon as Color).lerp(horizon, a)


## The city's own sun colour and energy, whatever set_sky has done since.
func sky_base() -> Dictionary:
	if _sky_base.is_empty():
		return {"sun_colour": (city._sun as DirectionalLight3D).light_color,
				"sun_energy": (city._sun as DirectionalLight3D).light_energy}
	return _sky_base


func _sky_material() -> ProceduralSkyMaterial:
	for c in city.get_children():
		if c is WorldEnvironment and c.environment != null and c.environment.sky != null:
			return c.environment.sky.sky_material as ProceduralSkyMaterial
	return null
