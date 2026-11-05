class_name ShipRays
extends RefCounted
## Rays through the ghost hulls (Docs/Hulls.md 7b): a ship flown over a world has no
## brick collision there (riding: only its shell box), its bricks and whoever
## walks it are in its ghost. A ray that crosses such a ship's box is traced, for
## that stretch, in its ghost instead: it meets the wall it was aimed at, a crew
## member standing in it, or it goes on through a hole and out the far side into
## the world. Its shell box is never what is hit.
##
## Every gun's ray comes through `cast` (GunController), and the AI's sight lines
## (Soldier, its shelter and callouts), so a shot fired aboard hits the hull from
## inside, a shot from outside comes in through a hole, and an enemy sees whoever
## is at a hole -- with nothing else having to know about ghosts.

## The ships whose ghost is in use: riding with one (PlanetSystem keeps it).
static var ships: Array[SpaceStation] = []


## `space.intersect_ray(q)`, ghosts and all. A hit in a ghost is in the world's
## terms: its point and normal through the ship's ghost_to_real, a brick's
## collider the ship's shell body (structure: StructuralDamage routes it), a body
## its own node; and "ship" says which ship's ghost it was in.
static func cast(space: PhysicsDirectSpaceState3D, q: PhysicsRayQueryParameters3D) -> Dictionary:
	var live: Array[SpaceStation] = []
	for s in ships:
		if is_instance_valid(s) and s.riding and s.ghost != null and s.ghosts != null:
			live.append(s)
	if live.is_empty():
		return space.intersect_ray(q)
	var ex: Array[RID] = q.exclude.duplicate()
	for s in live:
		if s.shell_body != null:
			ex.append(s.shell_body.get_rid())
	var wq := _like(q, q.from, q.to, ex)
	var best := space.intersect_ray(wq)
	var length := (q.to - q.from).length()
	var best_t: float = INF if best.is_empty() else (best.position - q.from).length()
	for s in live:
		var span := s.box_span(q.from, q.to)
		if span.x > span.y or span.x * length >= best_t:
			continue
		var g2r := s.ghost_to_real()
		var r2g := g2r.affine_inverse()
		var gq := _like(q, r2g * q.from.lerp(q.to, span.x), r2g * q.from.lerp(q.to, span.y), q.exclude)
		var h: Dictionary = (s.ghosts as GhostHulls).state().intersect_ray(gq)
		if h.is_empty():
			continue
		var p: Vector3 = g2r * (h.position as Vector3)
		var t := (p - q.from).length()
		if t >= best_t:
			continue
		best = h.duplicate()
		best.position = p
		best.normal = (g2r.basis * (h.normal as Vector3)).normalized()
		best.ship = s
		if h.get("collider") == null:
			# A band of its bricks (a server body, no node): the ship's structure.
			best.collider = s.shell_body
			best.collider_id = s.shell_body.get_instance_id() if s.shell_body != null else 0
		best_t = t
	return best


static func _like(q: PhysicsRayQueryParameters3D, from: Vector3, to: Vector3, ex: Array[RID]) -> PhysicsRayQueryParameters3D:
	var out := PhysicsRayQueryParameters3D.create(from, to, q.collision_mask, ex)
	out.collide_with_areas = q.collide_with_areas
	out.collide_with_bodies = q.collide_with_bodies
	out.hit_from_inside = q.hit_from_inside
	out.hit_back_faces = q.hit_back_faces
	return out
