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
## May this machine change the world? False on a co-op client: it plays the
## host's disaster for the look of it (DisasterDirector.receive), and every
## brick, fire and wound arrives as the host's commands instead. Bricks also
## ask the authority; this is the door for what does not go through it.
var decides := true
var registry: BuildingRegistry
var islands: IslandManager
## The fire service (fire_spread.gd), set by the director. ignite() goes here.
var fire: FireSpread
## SEVERAL DISASTERS AT ONCE (Docs/Disasters.md 22). Each disaster's sky,
## weather, lens, wind, rain, snow, storm and sea are kept apart, by `source`
## -- the disaster acting now, which the director sets round each one's tick
## -- and combined: the darkest sky, the worst sight and aim, the heaviest rain
## and dust on the lens, the winds added, any rain is rain, the highest surge.
## A disaster that ends is forgotten (forget), and what it set goes with it.
## Without a source (a probe calling straight in) it is one source of its own.
var source: Object = null
var _by := {}                     ## source -> {channel: value}
var _slots := {}                  ## source -> its hazard id block
var _next_slot := 0

## True while it rains (any disaster's). Fire reads it: rain halves spread and
## slows heating.
var raining := false:
	set(v):
		_put("raining", v)
	get:
		return _any("raining")
## How wet the world's surfaces are (WeatherFx, weather.gdshaderinc): up while
## it rains, over WET_S; drying over DRY_S after. Eased here, every frame.
var wet := 0.0
## The wind trees and buildings sway in: direction x strength, 0..~1.5 --
## every disaster's added. Disasters set it; it is theirs to put back to zero.
var gale := Vector3.ZERO:
	set(v):
		_put("gale", v)
	get:
		return _sum("gale", 1.5)
const WET_S := 15.0
const DRY_S := 120.0
## Rain falling now, eased over a couple of seconds either way.
var rain := 0.0
## Snow falling (a disaster sets it), and lying: up over SNOW_S while it falls,
## melting over MELT_S after (Docs/Disasters.md 21). The cover is made the
## first time it lies and freed when the last of it has gone.
var snowing := false:
	set(v):
		_put("snowing", v)
	get:
		return _any("snowing")
var snow := 0.0
## How fast it lies: a heavy fall, faster. The fastest of those falling.
var snow_rate := 1.0:
	set(v):
		_put("snow_rate", v)
	get:
		var r := 0.0
		for d in _by.values():
			if d.get("snowing", false):
				r = maxf(r, float(d.get("snow_rate", 1.0)))
		return r if r > 0.0 else 1.0
var snow_cover: SnowCover = null
## The colour of what lies: what is falling decides it (snow white, sand
## tan), and what has fallen keeps it while it goes.
var lying_colour := Color(0.93, 0.95, 0.99)
var snow_tint := Color(0.93, 0.95, 0.99):
	set(v):
		_put("snow_tint", v)
## How deep it may lie while it falls: 1 for snow, less for hail (a thin
## white of stones, patchy). The deepest any falling one allows.
var snow_cap := 1.0:
	set(v):
		_put("snow_cap", v)
	get:
		var c := 0.0
		for d in _by.values():
			if d.get("snowing", false):
				c = maxf(c, float(d.get("snow_cap", 1.0)))
		return c if c > 0.0 else 1.0
const SNOW_S := 45.0
const MELT_S := 90.0

## Where soldiers must not stand, by the disaster that said so: id -> AABB
## (Docs/Disasters.md section 9). Re-sent to the AI every tick by push_hazards,
## because the city clears the AI's danger boxes each tick before its own.
var hazards := {}
## The weather on the lens (director's overlay); null when there is no screen.
var screen: ShaderMaterial
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


## The host is usually a city, but a scene with no buildings -- the heightfield
## test, whose sea a hurricane raises -- can host a director too. It needs a
## `camera` and a `_sun`; `registry`, `islands`, `soldiers` and `ai_services`
## are whatever it has, and a disaster that needs buildings is not offered
## there (DisasterDirector.setup's `kinds`).
func _init(city_node: Node3D) -> void:
	city = city_node
	registry = city.get("registry")
	islands = city.get("islands")


# --- Changing bricks: through the authority, like a gun -------------------

## Destroy bricks in a ball. Queued; applied on a later tick.
func blast(point: Vector3, radius: float) -> void:
	# Not requested from a client: the host runs the same disaster and blasts
	# the same place itself.
	if decides and city.has_method("_blast"):
		city._blast(point, radius)


## Wear bricks in a ball by `hp`: weakens, kills only what runs out.
func chip(point: Vector3, radius: float, hp: int) -> void:
	if decides and city.has_method("chip"):
		city.chip(point, radius, hp)


## Blacken the bricks in a ball: fire's mark, colour only (DamageLog SCORCH).
func scorch(point: Vector3, radius: float) -> int:
	return city.scorch(point, radius) if decides and city.has_method("scorch") else 0


## Knock a clump of bricks loose from the building at `point`, whole -- they
## become a piece, and fall -- rather than destroying them. The city's own
## shear, as falling masonry does it. Host only (it commits directly, like the
## city's landings do). False where there is no building or nothing came loose.
func shear(point: Vector3, radius: float) -> bool:
	if not decides or not city.authority.may_decide():
		return false
	var id := building_at(point, 0.3)
	if id < 0:
		return false
	var before: int = city.authority.commands.size()
	city._shear_building(id, point, radius)
	return city.authority.commands.size() > before


## A sideways load on a standing building (BrickWorld.lateral_check): the
## ground, or the wind, accelerating it at `accel_g` toward `dir`. {} where its
## bricks are not in -- a far building has no joints to ask.
func lateral(id: int, accel_g: float, dir: Vector3) -> Dictionary:
	var b = registry.get_building(id)
	if b == null or b.toppled or b.chunk < 0 or b.frames.size() > 1:
		return {}
	return city.world.lateral_check(b.chunk, accel_g, dir)


## Cut a building through on the horizontal plane at `point` (a course
## boundary lateral() named): what is above comes away whole, as the host's
## SEVER command. False where it may not, or there is nothing to cut.
func sever(id: int, point: Vector3) -> bool:
	if not decides or not city.authority.may_decide():
		return false
	var b = registry.get_building(id)
	if b == null or b.toppled or b.chunk < 0:
		return false
	if not city.authority.request(DamageLog.Kind.SEVER, id, point, 0.0, Vector3.UP):
		return false
	var e := DamageLog.Entry.new()
	e.tick = Engine.get_physics_frames()
	e.kind = DamageLog.Kind.SEVER
	e.target = id
	e.point = point
	e.normal = Vector3.UP
	e.flags = DamageLog.FLAG_SEAM
	if DamageLog.apply_entry(city.world, b.chunk, e).is_empty():
		return false
	city.authority.commit_entry(e)
	city._mark_dirty(id)
	return true


## How many storeys a building has, by its box.
func storeys_of(id: int) -> int:
	var b = registry.get_building(id)
	if b == null or b.is_build():
		return 0
	return floori(float(b.recipe.courses) / TowerRecipe.COURSES_PER_FLOOR)


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
	var far: Dictionary = city._ray_recipes(from, to) if city.has_method("_ray_recipes") else {}
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


## The standing building whose REAL top is highest, of those whose footprint
## centre is within `radius` of `point` (on the ground plane). {} for none;
## otherwise {"building": id, "box": AABB, "top": its highest brick}.
##
## Real, not the recipe's: a building half blown away is as tall as what is
## left of it. The recipe box was the first answer, and lightning went for the
## roof of a building that no longer had one -- and hit the air.
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
		if box.end.y <= best_top:
			continue   # cannot beat it even whole
		var top := top_of(box)
		if not top.is_empty() and (top.position as Vector3).y > best_top:
			best_top = (top.position as Vector3).y
			best = {"building": b.id, "box": box, "top": top.position}
	return best


## The highest thing on a footprint, by rays straight down at its middle and
## near its four corners: {"position", "normal"}, or {} if every ray reached
## the ground. An intact building answers its roof (through its recipe if it
## has no bricks yet); a broken one, whatever is left standing highest.
func top_of(box: AABB) -> Dictionary:
	var best := {}
	var best_y := -INF
	var c := box.get_center()
	var hx := box.size.x * 0.5 - 0.6
	var hz := box.size.z * 0.5 - 0.6
	for off in [Vector2.ZERO, Vector2(-hx, -hz), Vector2(hx, -hz), Vector2(-hx, hz), Vector2(hx, hz)]:
		var from := Vector3(c.x + off.x, box.end.y + 5.0, c.z + off.y)
		var hit := ray(from, Vector3(from.x, box.position.y + 0.3, from.z))
		if hit.is_empty():
			continue
		var y: float = (hit.position as Vector3).y
		if y > best_y:
			best_y = y
			best = hit
	return best


## The standing building whose box holds `point` (within `margin`), or -1.
func building_at(point: Vector3, margin := 0.3) -> int:
	if registry == null:
		return -1
	for b in registry.buildings:
		if not b.toppled and CityPlacer.box_of(b).grow(margin).has_point(point):
			return b.id
	return -1


## Standing buildings as [id, box] pairs, in registry order.
func buildings() -> Array:
	var out := []
	if registry == null:
		return out
	for b in registry.buildings:
		if not b.toppled:
			out.append([b.id, CityPlacer.box_of(b)])
	return out


## Every building's box, standing ones only. For picking targets.
func building_boxes() -> Array[AABB]:
	var out: Array[AABB] = []
	if registry == null:
		return out
	for b in registry.buildings:
		if not b.toppled:
			out.append(CityPlacer.box_of(b))
	return out


## Start a fire at `point` with `heat` 0..1 (Docs/Disasters.md section 5). Does
## nothing where there is nothing to burn.
func ignite(point: Vector3, heat: float) -> bool:
	return decides and fire != null and fire.ignite(point, heat)


## Material index of the brick at `point`, -1 for none. Walks every building:
## callers that ask often must cache (Docs/Disasters.md section 5.3).
##
## A brick only where building collision actually is. The lookup alone answers
## PLA anywhere in a building whose bricks are not loaded -- and the city gives
## a far building's bricks back, damage and all, so a building with its top
## blown off read as whole to fire, which caught in the air. Collision is what
## the damage is kept in either way (bricks, or the damaged shell).
func material_at(point: Vector3) -> int:
	var q := PhysicsPointQueryParameters3D.new()
	q.position = point
	q.collision_mask = Layers.STRUCTURE
	if city.get("_material_fx") == null:
		return -1   # a host with no bricks (the heightfield)
	if city.get_world_3d().direct_space_state.intersect_point(q, 1).is_empty():
		return -1
	return city._material_fx.material_at(point)


## Loose pieces whose centre is within `radius` of `point`.
func islands_near(point: Vector3, radius: float) -> Array[BrickIsland]:
	var out: Array[BrickIsland] = []
	var r2 := radius * radius
	if islands == null:
		return out   # a host with no pieces
	for isl in islands.islands:
		if is_instance_valid(isl.body) and isl.body.global_position.distance_squared_to(point) <= r2:
			out.append(isl)
	return out


func wake_near(point: Vector3, radius: float) -> void:
	if islands != null:
		islands.wake_near(point, radius)


## Keep a piece from settling for `ms` -- it is being held up by wind, not by
## anything under it -- waking it if it has settled. IslandManager.hold_awake.
func hold_awake(isl: BrickIsland, ms: int) -> void:
	islands.hold_awake(isl, ms)


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
	if city.get("soldiers") == null:
		return out
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
	if not decides:
		return 0   # wounds are the host's to deal
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


## Tell the AI a storm is raging (AIServices.storm): soldiers with nothing to
## fight get under a roof (BTShelter).
func set_storm(on: bool) -> void:
	_put("storm", on)
	if city.get("ai_services") != null:
		city.ai_services.storm = _any("storm")


## The weather's effect on the AI (AIServices.sight_mul, aim_mul): `amount` 0
## is clear, 1 is `sight` and `aim` in full, and intensity scales how far from
## clear they go. Sight never drops below 60%.
func set_weather(amount: float, sight: float, aim: float, intensity := 1.0) -> void:
	var k := clampf(amount, 0.0, 1.0) * maxf(intensity, 0.0)
	_put("weather", [clampf(1.0 - (1.0 - sight) * k, 0.6, 1.0), maxf(1.0, 1.0 + (aim - 1.0) * k)])
	_apply_weather()


func _apply_weather() -> void:
	if city.get("ai_services") == null:
		return
	var sight := 1.0
	var aim := 1.0
	for d in _by.values():
		if d.has("weather"):
			sight = minf(sight, float(d.weather[0]))
			aim = maxf(aim, float(d.weather[1]))
	city.ai_services.sight_mul = sight
	city.ai_services.aim_mul = aim


## Rain streaking the view and dust hazing it, 0..1 each; `dust_colour` tints it.
func set_screen(p_rain: float, p_dust: float, dust_colour := Color(0.6, 0.55, 0.48),
		rain_colour := Color(0.78, 0.84, 0.92)) -> void:
	_put("screen", [clampf(p_rain, 0.0, 1.0), clampf(p_dust, 0.0, 1.0), dust_colour, rain_colour])
	_apply_screen()


func _apply_screen() -> void:
	if screen == null:
		return
	var r := 0.0
	var dsum := 0.0
	var rc := Color(0.78, 0.84, 0.92)
	var dc := Color(0.6, 0.55, 0.48)
	for d in _by.values():
		if not d.has("screen"):
			continue
		var v: Array = d.screen
		if float(v[0]) > r:
			r = float(v[0])
			rc = v[3]
		if float(v[1]) > dsum:
			dsum = float(v[1])
			dc = v[2]
	screen.set_shader_parameter("rain", r)
	screen.set_shader_parameter("dust", dsum)
	screen.set_shader_parameter("dust_colour", dc)
	screen.set_shader_parameter("rain_colour", rc)


## Soldiers within `radius` of `point` get low for `seconds` (Soldier.duck): a
## stroke is about to land there.
func duck_near(point: Vector3, radius: float, seconds: float) -> int:
	var n := 0
	if city.get("soldiers") == null:
		return 0
	for so in city.soldiers:
		if is_instance_valid(so) and so.pawn != null and not so.is_dead() 				and so.pawn.feet().distance_to(point) <= radius:
			so.duck(seconds)
			n += 1
	return n


# --- The sea and the wind ------------------------------------------------------

## Raise the sea by `surge` metres and scale its waves by `wave_mul`, where the
## host has a sea (`disaster_sea`). (0, 1) puts it back exactly. False where
## there is no sea.
func set_sea(surge: float, wave_mul: float) -> bool:
	if not city.has_method("disaster_sea"):
		return false
	_put("sea", [surge, wave_mul])
	_apply_sea()
	return true


func _apply_sea() -> void:
	if not city.has_method("disaster_sea"):
		return
	var surge := 0.0
	var mul := 1.0
	for d in _by.values():
		if d.has("sea"):
			surge = maxf(surge, float(d.sea[0]))
			mul = maxf(mul, float(d.sea[1]))
	city.disaster_sea(surge, mul)


## The wind on whoever is walking or swimming: metres a second of drift added
## to their motion (DebugCamera.wind). Vector3.ZERO is calm.
func set_wind(v: Vector3) -> void:
	_put("wind", v)
	_apply_wind()


func _apply_wind() -> void:
	var cam = city.get("camera")
	if cam != null and "wind" in cam:
		cam.wind = _sum("wind", 4.0)


# --- The player ---------------------------------------------------------------

## Where the player is looking from: the camera, whatever it is attached to.
func player_pos() -> Vector3:
	return city.camera.global_position


## Shake the view from something at `point`. `strength` is metres of offset at
## the source, halving every 20 m.
func shake(point: Vector3, strength: float) -> void:
	var d := point.distance_to(player_pos())
	_shake = minf(SHAKE_MAX, _shake + strength * pow(0.5, d / 20.0))


## Called by the director every frame: applies and decays the shake, and eases
## the wet.
func step(delta: float) -> void:
	wet = move_toward(wet, 1.0 if raining else 0.0, delta / (WET_S if raining else DRY_S))
	rain = move_toward(rain, 1.0 if raining else 0.0, delta / 2.0)
	var lie := snow_cap if snowing else 0.0
	snow = move_toward(snow, lie, delta * snow_rate / SNOW_S if snow < lie else delta / MELT_S)
	# Melting snow leaves it wet.
	if not snowing and snow > 0.0:
		wet = maxf(wet, minf(snow * 2.0, 1.0))
	for d in _by.values():
		if d.get("snowing", false) and d.has("snow_tint"):
			lying_colour = d.snow_tint
	if snowing and not _any_tint():
		lying_colour = Color(0.93, 0.95, 0.99)
	WeatherFx.set_weather(wet, gale, rain, snow, lying_colour)
	if snow > 0.0 and snow_cover == null:
		snow_cover = SnowCover.new()
		snow_cover.name = "SnowCover"
		city.add_child(snow_cover)
		snow_cover.setup(city)
	elif snow <= 0.0 and snow_cover != null:
		snow_cover.queue_free()
		snow_cover = null
	_step_shake(delta)


func _step_shake(delta: float) -> void:
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
	_put("sky", [clampf(amount, 0.0, 1.0), sun_colour, top, horizon, sun_energy_mul, flash])
	_apply_sky()


## The darkest mood any disaster asks for, and the brightest flash.
func _apply_sky() -> void:
	var best: Array = []
	var flash := 0.0
	for d in _by.values():
		if not d.has("sky"):
			continue
		var v: Array = d.sky
		flash = maxf(flash, float(v[5]))
		if best.is_empty() or float(v[0]) > float(best[0]):
			best = v
	if best.is_empty():
		if _sky_base.is_empty():
			return
		best = [0.0, Color.WHITE, Color.WHITE, Color.WHITE, 1.0, 0.0]
	_sky_now(float(best[0]), best[1], best[2], best[3], float(best[4]), flash)


func _sky_now(amount: float, sun_colour: Color, top: Color, horizon: Color,
		sun_energy_mul: float, flash: float) -> void:
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
	hazards[_hazard_key(id)] = box


func clear_hazard(id: int) -> void:
	hazards.erase(_hazard_key(id))


## Each disaster its own block of ids: two tornadoes both mark "hazard 0".
func _hazard_key(id: int) -> int:
	if not _slots.has(source):
		_slots[source] = _next_slot
		_next_slot = (_next_slot + 1) % 500
	return HAZARD_BASE - id - 100 * int(_slots[source])


# --- Several at once -------------------------------------------------------------

func _put(channel: String, value: Variant) -> void:
	if not _by.has(source):
		_by[source] = {}
	_by[source][channel] = value


func _any(channel: String) -> bool:
	for d in _by.values():
		if d.get(channel, false):
			return true
	return false


func _sum(channel: String, cap: float) -> Vector3:
	var v := Vector3.ZERO
	for d in _by.values():
		v += d.get(channel, Vector3.ZERO)
	return v.limit_length(cap)


func _any_tint() -> bool:
	for d in _by.values():
		if d.get("snowing", false) and d.has("snow_tint"):
			return true
	return false


## A disaster has ended: what it set goes, and what the others set stands.
func forget(src: Object) -> void:
	_by.erase(src)
	for k in hazards.keys():
		var slot := int(_slots.get(src, -1))
		if slot >= 0 and k <= HAZARD_BASE - 100 * slot and k > HAZARD_BASE - 100 * (slot + 1):
			hazards.erase(k)
	_slots.erase(src)
	_apply_sky()
	_apply_weather()
	_apply_screen()
	_apply_wind()
	_apply_sea()
	if city.get("ai_services") != null:
		city.ai_services.storm = _any("storm")


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
