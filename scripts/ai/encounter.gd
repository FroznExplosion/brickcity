class_name Encounter
extends RefCounted
## Where a fight is going to happen, made ready for it (Docs/AIPlan.md R3).
##
## An undamaged building is its shell: four wall slabs and a floor, no roof, no
## upper storeys and no openings (BuildingShell.collision_boxes). Nobody can
## fight in or from one, go in, or stand on its roof. So when an encounter
## starts, the buildings in its zone are MATERIALISED -- a few a tick, inside the
## promotion budget -- exactly as a player walking up to them would, and held
## that way until it ends.
##
## That is PRESENCE. A QUERY never materialises anything (Docs/AI.md 3.2): the AI
## asks a pristine building's proxy boxes, and a path round a building nobody is
## fighting in costs nothing. This is the one sanctioned door from "the AI wants
## to be here" to bricks.

## Buildings brought in per tick. Promotion is ~2 ms each (Docs/Status.md).
const PER_TICK := 2

var zone := AABB()
## The buildings this encounter holds materialised.
var buildings: Array[int] = []
var _queue: Array[int] = []


## Every building whose box meets `p_zone`. `world_box` answers a building's
## world AABB by id.
func setup(registry: BuildingRegistry, p_zone: AABB, world_box: Callable) -> void:
	zone = p_zone
	for b in registry.buildings:
		if b.toppled:
			continue
		var box: AABB = world_box.call(b.id)
		if box.intersects(zone):
			buildings.append(b.id)
			if not b.is_materialised():
				_queue.append(b.id)


## Bring the next few in; `promote(id)` materialises one. True once all are.
func step(promote: Callable) -> bool:
	var n := 0
	while not _queue.is_empty() and n < PER_TICK:
		promote.call(_queue.pop_front())
		n += 1
	return _queue.is_empty()


func is_ready() -> bool:
	return _queue.is_empty()


func holds(id: int) -> bool:
	return buildings.has(id)
