class_name BuildingMarks
extends RefCounted

## The points an author marked in a build (Docs/Structures.md 3.1, the spaces
## tool's P): where the AI should take cover, where a garrison starts. Docs/AI.md
## 3.3.1.
##
## A mark is a HINT, never ground truth. Cover is still what the bricks say
## (CoverSearch, AIWorld) against the actual threat: a marked spot is rated like
## any spot the ring search would try, and only taken when it really hides a
## body for long enough. A wall shot away under a mark makes it no cover, as it
## would anywhere else. What a mark buys is the author's say, and speed: a few
## rays at the marks before the 144-spot ring.
##
## A mark's cell is the air cell the author pointed at (the cell over the
## floor), in the build's own grid. Its spot is the feet at the middle of that
## cell. In building space (BuildingRegistry.to_building) that is the cell less
## the recipe's min corner -- a placed build is rebased there, in its cells for
## one frame and in its transform for several, and both come out the same
## (build_probe, the fixture check) -- times the cell size.

## A mark is taken from within this far: a short run, where the ring search
## looks out to 13.5 m and pays for it. At most this many are rated, nearest
## first.
const REACH := 8.0
const MAX_RATED := 8

## BuildRecipe instance id -> {kind: Array[Vector3] in building metres}.
static var _of_recipe := {}
## Registry instance id -> [building count when listed, ids with any marks].
static var _marked := {}


## The marks of one building, by kind, in building metres. {} for a generated
## tower (it has no author) or a build with none.
static func of_building(b) -> Dictionary:
	if b == null or not b.is_build():
		return {}
	var r: BuildRecipe = b.build
	var key := r.get_instance_id()
	if _of_recipe.has(key):
		return _of_recipe[key]
	var out := {}
	var rec: Dictionary = r.meta.get("structure", {})
	var lo := Vector3(r.origin())
	var cs := BrickWorld.get_cell_size()
	for p in rec.get("points", []):
		var at: Array = p.get("at", [])
		if at.size() < 3:
			continue
		var c := Vector3(float(at[0]), float(at[1]), float(at[2])) - lo
		var kind := String(p.get("kind", ""))
		if not out.has(kind):
			out[kind] = [] as Array[Vector3]
		(out[kind] as Array[Vector3]).append(Vector3((c.x + 0.5) * cs.x, c.y * cs.y,
				(c.z + 0.5) * cs.z))
	_of_recipe[key] = out
	return out


## The world spots of building `b`'s marks of `kind`.
static func spots(b, kind: String) -> Array[Vector3]:
	var out: Array[Vector3] = []
	for p: Vector3 in of_building(b).get(kind, []):
		out.append(BuildingRegistry.to_world(b, p))
	return out


## Every standing building's marks of `kind` within `radius` of world point `p`,
## nearest first. What the city puts in AIServices.marks, its registry passed.
static func near(p: Vector3, radius: float, kind: String, registry: BuildingRegistry) -> Array[Vector3]:
	var out: Array[Vector3] = []
	if registry == null:
		return out
	for id in _marked_ids(registry):
		var b := registry.get_building(id)
		if b == null or b.toppled or not BuildingRegistry.contains(b, p, radius):
			continue
		for q in spots(b, kind):
			if q.distance_to(p) <= radius:
				out.append(q)
	out.sort_custom(func(x: Vector3, y: Vector3) -> bool:
		return x.distance_squared_to(p) < y.distance_squared_to(p))
	return out


## The buildings that have any marks at all, listed again only when a building
## is registered: a city of thousands of towers is looked through once.
static func _marked_ids(registry: BuildingRegistry) -> PackedInt32Array:
	var key := registry.get_instance_id()
	var memo: Array = _marked.get(key, [-1, PackedInt32Array()])
	if int(memo[0]) == registry.buildings.size():
		return memo[1]
	var ids := PackedInt32Array()
	for b in registry.buildings:
		if not of_building(b).is_empty():
			ids.append(b.id)
	_marked[key] = [registry.buildings.size(), ids]
	return ids
