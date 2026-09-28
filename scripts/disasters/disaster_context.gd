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
## The fire service (fire_spread.gd), set by the director. ignite() goes here.
var fire: FireSpread
## True while it rains. Fire reads it: rain halves spread and slows heating.
var raining := false

## Where soldiers must not stand, by the disaster that said so: id -> AABB
## (Docs/Disasters.md section 9). Re-sent to the AI every tick by push_hazards,
## because the city clears the AI's danger boxes each tick before its own.
var hazards := {}
## Smoke ids this context set on the AI world last push, to take back.
var _smoke_ids: Array[int] = []
## Danger and smoke ids are the AI world's, shared with falling pieces (chunk
## ids, 0 and up): disasters take negative ones.
const HAZARD_BASE := -1000
const FIRE_HAZARD_BASE := -100000
const SMOKE_BASE := -1000

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


## Knock a clump of bricks loose from the building at `point`, whole -- they
## become a piece, and fall -- rather than destroying them. The city's own
## shear, as falling masonry does it. Host only (it commits directly, like the
## city's landings do). False where there is no building or nothing came loose.
func shear(point: Vector3, radius: float) -> bool:
	if not city.authority.may_decide():
		return false
	var id := building_at(point, 0.3)
	if id < 0:
		return false
	var before: int = city.authority.commands.size()
	city._shear_building(id, point, radius)
	return city.authority.commands.size() > before


## How many storeys a building has, by its box.
func storeys_of(id: int) -> int:
	var b = registry.get_building(id)
	if b == null or b.is_build():
		return 0
	return int(b.recipe.courses) / TowerRecipe.COURSES_PER_FLOOR


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


## Standing buildings as [id, box] pairs, in registry order.
func buildings() -> Array:
	var out := []
	for b in registry.buildings:
		if not b.toppled:
			out.append([b.id, CityPlacer.box_of(b)])
	return out


## Every building's box, standing ones only. For picking targets.
func building_boxes() -> Array[AABB]:
	var out: Array[AABB] = []
	for b in registry.buildings:
		if not b.toppled:
			out.append(CityPlacer.box_of(b))
	return out


## Start a fire at `point` with `heat` 0..1 (Docs/Disasters.md section 5). Does
## nothing where there is nothing to burn.
func ignite(point: Vector3, heat: float) -> bool:
	return fire != null and fire.ignite(point, heat)


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


## Wake one settled piece so it can be moved again.
func wake_piece(isl: BrickIsland) -> void:
	if isl.is_valid() and isl.settled:
		islands.wake(isl)


## How many bricks a piece still has.
func piece_bricks(isl: BrickIsland) -> int:
	return city.world.get_alive_block_count(isl.chunk) if isl.is_valid() else 0


## The box every standing building fits in; an empty AABB for none.
func city_bounds() -> AABB:
	var out := AABB()
	var first := true
	for box in building_boxes():
		out = box if first else out.merge(box)
		first = false
	return out


## The mark, debris and sound of whatever is struck at `point`. Cosmetic, local.
func impact_fx(point: Vector3, normal: Vector3) -> void:
	if city._material_fx != null and not city._material_fx.impact_at(point, normal):
		city._material_fx.impact(point, normal, 0, Color(0.6, 0.6, 0.6))


# --- People ------------------------------------------------------------------

## Every living pawn: the soldiers', and the player's when the player is in one.
func pawns() -> Array[Pawn]:
	var out: Array[Pawn] = []
	for so in city.soldiers:
		if is_instance_valid(so) and so.pawn != null and is_instance_valid(so.pawn):
			out.append(so.pawn)
	var mine: Pawn = city._player_pawn
	if mine != null and is_instance_valid(mine) and city._player.is_possessing():
		out.append(mine)
	return out


## Hurt every pawn within `radius` of `point` by `amount`, through the damage
## system like a round (no element: none exist as resources yet). Returns how
## many were hurt.
func damage_pawns(point: Vector3, radius: float, amount: float) -> int:
	var hurt := 0
	var r2 := radius * radius
	for p in pawns():
		if p.chest().distance_squared_to(point) > r2:
			continue
		var packet := DamagePacket.new(amount, null, city)
		packet.hit_position = point
		# The pool itself: resolve() takes a HealthPool as its own root.
		if p.health != null and DamageSystem.resolve(packet, p.health).dealt > 0.0:
			hurt += 1
	return hurt


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
		sun_energy_mul: float, flash := 0.0) -> void:
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
	# `flash` lights the whole scene for a lightning stroke, on top of the mood.
	sun.light_energy = float(_sky_base.sun_energy) * (lerpf(1.0, sun_energy_mul, a) + flash)
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


# --- What soldiers should keep away from ----------------------------------------

## Mark `box` as somewhere not to stand, under `id` (0, 1, 2 ... per disaster;
## the context makes it negative). Stays until cleared.
func set_hazard(id: int, box: AABB) -> void:
	hazards[HAZARD_BASE - id] = box


func clear_hazard(id: int) -> void:
	hazards.erase(HAZARD_BASE - id)


## The city calls this every AI tick, right after its own danger boxes are
## rebuilt: every hazard a disaster has set, every burning cell, and the fire's
## smoke (which blocks sight, not bullets).
func push_hazards(ai_world: AIWorld) -> void:
	for id in hazards:
		ai_world.set_danger(id, hazards[id])
	if fire == null:
		return
	var i := 0
	for c in fire.cells:
		var lo := Vector3(c.key) * FireSpread.CELL
		ai_world.set_danger(FIRE_HAZARD_BASE - i, AABB(lo, FireSpread.CELL).grow(0.8))
		i += 1
	for id in _smoke_ids:
		ai_world.remove_smoke(id)
	_smoke_ids.clear()
	var k := 0
	for spot in fire.smoke_spots:
		var id := SMOKE_BASE - k
		ai_world.set_smoke(id, spot[0], spot[1])
		_smoke_ids.append(id)
		k += 1
