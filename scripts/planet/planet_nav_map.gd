class_name PlanetNavMap
extends RefCounted

## One map of the nav net (PlanetNavNet.map_view, Docs/Planets.md 11.8): a size's,
## a mech's, a vehicle kind's -- with AINav's calls, so whoever drives it on a
## planet asks it as it asks an AINav in the flat game. Paths cross regions; a
## point's questions (snap, can_stand) go to the region the point is in.

var net: PlanetNavNet
var map := "person"


func request_path(from: Vector3, to: Vector3, priority: float, max_expansions := 60000) -> int:
	return net.request_path(from, to, priority, max_expansions, map)


func get_status(id: int) -> int:
	return net.get_status(id)


func get_path(id: int) -> PackedVector3Array:
	return net.get_path(id)


func get_breaches(id: int) -> PackedVector3Array:
	return net.get_breaches(id)


func release(id: int) -> void:
	net.release(id)


func pending() -> int:
	return net.pending()


func find_path(from: Vector3, to: Vector3, max_expansions := 60000) -> PackedVector3Array:
	return net.find_path(from, to, max_expansions, map)


func snap(p: Vector3) -> Vector3:
	return net.snap(p, map)


func can_stand(p: Vector3) -> bool:
	return net.can_stand(p, map)


## The body this map is for, in studs: any region's map says the same.
func get_span() -> int:
	for r in net.regions.values():
		return net._ms(r, map).nav.get_span()
	return 2


func get_water_level() -> float:
	for r in net.regions.values():
		return net._ms(r, map).nav.get_water_level()
	return -INF


## The net serves its own maps (PlanetNavNet.service); here for callers that
## serve the maps they hold.
func service(_budget_usec: int) -> int:
	return 0


func invalidate_box(box: AABB) -> void:
	net.invalidate_box(box, map)
