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
	return {"position": hit.position, "normal": hit.normal}


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


## Every building's box, standing ones only. For picking targets.
func building_boxes() -> Array[AABB]:
	var out: Array[AABB] = []
	for b in registry.buildings:
		if not b.toppled:
			out.append(CityPlacer.box_of(b))
	return out


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
