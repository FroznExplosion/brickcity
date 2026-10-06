class_name CritSpots
extends Node
## Where a hit on this body is a crit (Docs/Weapons/COMBAT_DESIGN.md section 4.3).
##
## Crits are PLACES, not dice: a round that lands inside one of these spots is a crit,
## anywhere else it is not. Usually the head; an enemy type may add weak points of its own
## (a pack, a joint). A child of the body it belongs to, beside its HealthPool, so a gun
## that struck the body finds both the same way (GunController._living).
##
## Each spot is a sphere that FOLLOWS a node -- a pawn's head follows its Eye, which already
## moves with the crouch -- so a ducking body's head is still where its head is. Whether the
## crit then counts is the defences' call: a shield or armor over the flesh absorbs it
## (DamageSystem.resolve).
##
## Pure geometry, no rolls: every co-op peer agrees on a crit without being told.

## {"name": StringName, "node": Node3D, "offset": Vector3, "radius": float}
var spots: Array[Dictionary] = []


## A spot named `spot_name`, a sphere of `radius` round `node` (plus `offset` in that
## node's space).
func add(spot_name: StringName, node: Node3D, radius: float, offset := Vector3.ZERO) -> void:
	spots.append({"name": spot_name, "node": node, "offset": offset, "radius": radius})


## The spot `point` (world space) is in, or &"" for none.
func spot_at(point: Vector3) -> StringName:
	for s in spots:
		var n := s.node as Node3D
		if n == null or not is_instance_valid(n) or not n.is_inside_tree():
			continue
		var centre: Vector3 = n.global_transform * (s.offset as Vector3)
		if point.distance_to(centre) <= float(s.radius):
			return s.name
	return &""


## Where a spot is now (world), for an aimer or a probe. INF when there is none.
func centre_of(spot_name: StringName) -> Vector3:
	for s in spots:
		if s.name == spot_name and is_instance_valid(s.node):
			return (s.node as Node3D).global_transform * (s.offset as Vector3)
	return Vector3.INF
