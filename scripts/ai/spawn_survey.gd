class_name SpawnSurvey
extends RefCounted
## Where a wave may put a soldier, and what it would be standing on.
##
## A spawn is only as good as what is under it. A building that has come down,
## or is coming down, or has lost the floor a soldier would stand on, is not a
## place to put one -- and none of that is visible from a recipe: a toppled
## tower's registry entry still carries its footprint, and a storey that fell
## out of a standing tower left the tower's box exactly as big as it was. So
## this reads the world itself, three ways, and a spot has to pass all three:
##
##   * THE BUILDING, as a whole (building_fit): not toppled, no collapse begun
##     in it (CollapseDirector.collapsing), still anchored, and most of its
##     bricks still in it. A building that fails is left out entirely -- a
##     storey that happens to be intact in a tower that is on its way down is
##     not somewhere to stand.
##   * THE BRICKS, cell by cell: a floor is a solid plate in the building's own
##     chunk with a figure's head room of air over it and a ceiling above (so it
##     is inside, not the roof). A floor that fell is a piece of its own now, not
##     cells in the chunk, so it is not found.
##   * THE PHYSICS, at the moment of spawning (check): a ray down from the feet
##     says what the body would land on, by the collision layer of what it hits
##     -- standing structure, the ground, settled wreckage, a section still
##     falling -- and AINav says a body fits there with nothing lying on the
##     floor, and AIWorld that no danger is marked over it.
##
## What it found is kept in `refused` by reason, so a HUD and a gate can both
## say why a wave did not put anybody where it might have.

enum On { NOTHING, GROUND, BUILDING, WRECK, FALLING, RUBBLE }
const ON_NAMES := ["nothing", "ground", "building", "wreck", "falling section", "rubble"]

## Below this share of its bricks a building is wrecked, whatever still stands.
const MIN_INTEGRITY := 0.80
## Columns sampled across a floor, every this many studs.
const FLOOR_STEP := 3
## Kept clear of the chunk's outer columns: that is the wall.
const WALL_INSET := 2
## A ceiling within this many plates over the head: inside, not on the roof.
const CEILING_PLATES := 30
## Keep-outs at spawn time.
const MIN_FROM_PLAYER := 7.0
const MIN_FROM_PAWN := 1.2
## Outside: a ring this far from the walls.
## Outside: this far from the walls -- the street, and past it wherever the
## next building is not (what_is_under refuses a spot on one).
const RING_NEAR := 1.0
const RING_FAR := 8.0

## reason -> count, since the last reset.
var refused := {}
## [world point, accepted] of every point the last surveys looked at, for the
## debug overlay.
var looked := []

var _city: Node


func _init(city: Node) -> void:
	_city = city


func reset_counts() -> void:
	refused.clear()


func _refuse(why: String) -> Dictionary:
	refused[why] = int(refused.get(why, 0)) + 1
	return {"ok": false, "why": why}


# --- the building ---------------------------------------------------------------

## Is this building somewhere a soldier may be put inside? {ok, why, integrity}.
func building_fit(id: int) -> Dictionary:
	var b: BuildingRegistry.Building = _city.registry.get_building(id)
	if b == null:
		return {"ok": false, "why": "no building", "integrity": 0.0}
	if b.toppled:
		return {"ok": false, "why": "building fell", "integrity": 0.0}
	if _city.director.collapsing.has(id):
		return {"ok": false, "why": "building collapsing", "integrity": integrity(id)}
	if b.is_build():
		return {"ok": false, "why": "not a tower", "integrity": 1.0}
	if not b.is_materialised():
		# A shell has no floors in it. Not unfit -- not ready.
		return {"ok": false, "why": "not bricks yet", "integrity": 1.0}
	if not _city.world.is_chunk_anchored(b.chunk):
		return {"ok": false, "why": "building fell", "integrity": 0.0}
	var share := integrity(id)
	if share < MIN_INTEGRITY:
		return {"ok": false, "why": "building wrecked", "integrity": share}
	return {"ok": true, "why": "", "integrity": share}


## The share of a building's bricks still in it: 1 untouched, 0 gone.
func integrity(id: int) -> float:
	var b: BuildingRegistry.Building = _city.registry.get_building(id)
	if b == null or b.toppled:
		return 0.0
	if not b.is_materialised() or b.blocks <= 0:
		return 1.0
	var alive: int = _city.world.get_alive_block_count(b.chunk)
	return clampf(float(alive) / float(b.blocks), 0.0, 1.0)


# --- candidates -----------------------------------------------------------------

## Every place inside building `id` a figure could stand, read from its bricks:
## world points of feet, grouped by nothing -- a flat list. Empty for a building
## that is not fit (the reason is counted).
func floors_of(id: int) -> Array[Vector3]:
	var out: Array[Vector3] = []
	var fit := building_fit(id)
	if not bool(fit.ok):
		_refuse(fit.why)
		return out
	var b: BuildingRegistry.Building = _city.registry.get_building(id)
	var world: BrickWorld = _city.world
	var chunk := b.chunk
	var origin: Vector3i = world.get_chunk_origin(chunk)
	var dims: Vector3i = world.get_chunk_dims(chunk)
	var head := AINav.HEAD_STAND
	for lx in range(WALL_INSET, dims.x - WALL_INSET - 1, FLOOR_STEP):
		for lz in range(WALL_INSET, dims.z - WALL_INSET - 1, FLOOR_STEP):
			var col := _column(world, chunk, origin, lx, lz, dims.y)
			var y := 1
			while y < dims.y - head:
				if col[y - 1] and not col[y] and _air(col, y, head) and _ceiling(col, y + head) \
						and _patch(world, chunk, origin + Vector3i(lx, y, lz), head):
					out.append(_cell_feet(world, chunk, origin, Vector3i(lx, y, lz)))
					y += head
				else:
					y += 1
	return out


## Points round building `id` on whatever is outside it, snapped to where a body
## stands. The ring is walked whatever state the building is in: a wreck is
## still somewhere to come at the player from.
func ring_of(id: int, count: int, rng: RandomNumberGenerator) -> Array[Vector3]:
	var out: Array[Vector3] = []
	var b: BuildingRegistry.Building = _city.registry.get_building(id)
	if b == null:
		return out
	var box: AABB = _city._world_box(b)
	var centre := box.get_center()
	var half := Vector2(box.size.x, box.size.z) * 0.5
	for i in count:
		var a := rng.randf() * TAU
		var d := Vector2(cos(a), sin(a))
		# From the centre out to the footprint's edge along d, then the ring.
		var to_edge := minf(half.x / maxf(absf(d.x), 0.001), half.y / maxf(absf(d.y), 0.001))
		var r := to_edge + rng.randf_range(RING_NEAR, RING_FAR)
		var p := Vector3(centre.x + d.x * r, 0.0, centre.z + d.y * r)
		p.y = _city.ai_world.ground_at(p.x, p.z)
		out.append(_city.ai_nav.snap(p))
	return out


# --- the check at the moment of spawning -----------------------------------------

## May a soldier be put with its feet at `feet`, now? `inside` is the building it
## is meant to be in, or -1 for anywhere outside. {ok, why, on, building}.
func check(feet: Vector3, inside: int, player: Pawn, others: Array) -> Dictionary:
	if inside >= 0:
		var fit := building_fit(inside)
		if not bool(fit.ok):
			return _refuse(fit.why)
	var under := what_is_under(feet)
	var on: int = under.on
	if inside >= 0:
		if on != On.BUILDING:
			return _refuse("floor gone" if on == On.NOTHING else "not on its floor")
		if not _floor_cell_solid(inside, feet):
			return _refuse("floor gone")
	else:
		match on:
			On.GROUND:
				pass
			On.WRECK:
				if not bool(under.settled):
					return _refuse("wreck still moving")
			On.BUILDING:
				return _refuse("on a building, not outside")
			On.FALLING:
				return _refuse("on a falling section")
			On.RUBBLE:
				return _refuse("on loose rubble")
			_:
				return _refuse("no ground under it")
	if absf(float(under.y) - feet.y) > 0.35:
		return _refuse("floor not where it was")
	if not _city.ai_nav.can_stand(feet):
		return _refuse("no room to stand")
	if _city.ai_world.in_danger(feet + Vector3.UP * 0.9):
		return _refuse("danger marked")
	if player != null and is_instance_valid(player) and feet.distance_to(player.feet()) < MIN_FROM_PLAYER:
		return _refuse("too close to the player")
	for p in others:
		if is_instance_valid(p) and feet.distance_to((p as Pawn).feet()) < MIN_FROM_PAWN:
			return _refuse("somebody there")
	return {"ok": true, "why": "", "on": on, "building": inside}


## What a body put at `feet` would land on: {on, y, settled, body}.
func what_is_under(feet: Vector3) -> Dictionary:
	var from := feet + Vector3.UP * 0.6
	var q := PhysicsRayQueryParameters3D.create(from, feet - Vector3.UP * 1.2,
			Layers.HITSCAN_MASK)
	var hit: Dictionary = _city.get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		return {"on": On.NOTHING, "y": -INF, "settled": false, "body": null}
	var layer := PhysicsServer3D.body_get_collision_layer(hit["rid"])
	var out := {"on": On.NOTHING, "y": (hit["position"] as Vector3).y, "settled": false,
			"body": hit.get("collider")}
	if layer & Layers.STRUCTURE:
		out.on = On.BUILDING
	elif layer & Layers.WORLD:
		out.on = On.GROUND
	elif layer & Layers.FALLING:
		out.on = On.FALLING
	elif layer & Layers.DEBRIS:
		out.on = On.WRECK
		var isl: BrickIsland = _city.islands.find_by_body(hit.get("collider")) \
				if hit.get("collider") != null else null
		out.settled = isl != null and isl.settled
	elif layer & Layers.RUBBLE:
		out.on = On.RUBBLE
	return out


# --- cells ------------------------------------------------------------------------

func _column(world: BrickWorld, chunk: int, origin: Vector3i, lx: int, lz: int,
		height: int) -> PackedByteArray:
	var col := PackedByteArray()
	col.resize(height)
	for y in height:
		col[y] = 1 if world.is_solid(chunk, origin + Vector3i(lx, y, lz)) else 0
	return col


func _air(col: PackedByteArray, y: int, head: int) -> bool:
	for k in head:
		if col[y + k]:
			return false
	return true


func _ceiling(col: PackedByteArray, from: int) -> bool:
	for k in range(from, mini(from + CEILING_PLATES, col.size())):
		if col[k]:
			return true
	return false


## The 2x2 of columns a body stands on: floor under all four, air over all four.
func _patch(world: BrickWorld, chunk: int, at: Vector3i, head: int) -> bool:
	for d in [Vector3i(1, 0, 0), Vector3i(0, 0, 1), Vector3i(1, 0, 1)]:
		var c: Vector3i = at + d
		if not world.is_solid(chunk, c - Vector3i(0, 1, 0)):
			return false
		for k in head:
			if world.is_solid(chunk, c + Vector3i(0, k, 0)):
				return false
	return true


## Feet on the top of cell `cell - 1`, at the middle of the 2x2 that starts there.
func _cell_feet(world: BrickWorld, chunk: int, origin: Vector3i, cell: Vector3i) -> Vector3:
	var cs := BrickWorld.get_cell_size()
	var local := Vector3(cell.x - origin.x + 1.0, cell.y - origin.y, cell.z - origin.z + 1.0) * cs
	return world.get_chunk_transform(chunk) * local


## Is the plate under `feet` still a brick of building `id`?
func _floor_cell_solid(id: int, feet: Vector3) -> bool:
	var b: BuildingRegistry.Building = _city.registry.get_building(id)
	if b == null or not b.is_materialised():
		return false
	var world: BrickWorld = _city.world
	var cs := BrickWorld.get_cell_size()
	var under := feet - Vector3.UP * cs.y * 0.5
	var local: Vector3 = world.get_chunk_transform(b.chunk).affine_inverse() * under
	var origin: Vector3i = world.get_chunk_origin(b.chunk)
	# The feet are at the corner of four columns; any of them holding is a floor.
	for dx in [-0.25, 0.25]:
		for dz in [-0.25, 0.25]:
			var at := origin + Vector3i(floori(local.x / cs.x + dx), floori(local.y / cs.y),
					floori(local.z / cs.z + dz))
			if world.is_solid(b.chunk, at):
				return true
	return false
