class_name ShipCargo
extends RefCounted
## Loose things on a ship in flight (Docs/Hulls.md 7b.4): a dropped gun, or any
## RigidBody3D in group CARGO, that is inside a riding ship's box is taken into its
## ghost (GhostHulls' space), as a pawn is -- there it lies on the still decks,
## pulled by the ship's own down (its gravity field; none, it floats) -- and is drawn
## on the real ship at the same ship-local place: its visuals made top-level and put
## at ghost_to_real each frame. Out of the ship's ghost (through a hole, or the ship
## at rest again), back into the world at the real place, the deck's velocity added.

## What may ride: these groups' rigid bodies.
const CARGO := &"ship_cargo"
const GROUPS: Array[StringName] = [&"gun_pickups", CARGO]
## The pull on a ghost deck, m/s^2: a ship's field is one g.
const G := 9.8


## One frame of every loose body under `tree` against `ships`: on, off, drawn.
static func tick(tree: SceneTree, ships: Array, world_space: RID) -> void:
	var live: Array = []
	for s in ships:
		if is_instance_valid(s) and s.riding and s.ghost != null and s.ghosts != null:
			live.append(s)
	for g in GROUPS:
		for n in tree.get_nodes_in_group(g):
			var b := n as RigidBody3D
			if b == null or not b.is_inside_tree():
				continue
			var on: Variant = b.get_meta(&"ghosted") if b.has_meta(&"ghosted") else null
			if on != null:
				var st := on as SpaceStation
				if st == null or not is_instance_valid(st) or not st.riding or st.ghost == null \
						or not st.ghost_holds(b.global_position):
					get_off(b, st, world_space)
				else:
					_pull(b, st)
					_draw(b, st)
				continue
			if live.is_empty():
				continue
			for s in live:
				if (s as SpaceStation).holds(b.global_position):
					board(b, s)
					break


## `b` into ship `st`'s ghost at the same ship-local place, its velocity less the
## deck's, its visuals drawn on the real ship from now on.
static func board(b: RigidBody3D, st: SpaceStation) -> void:
	var r2g := st.ghost_to_real().affine_inverse()
	var xf := b.global_transform
	var v := b.linear_velocity - st.deck_velocity(r2g * xf.origin)
	var w := b.angular_velocity
	b.freeze = false
	b.sleeping = false
	PhysicsServer3D.body_set_space(b.get_rid(), st.ghosts.space)
	b.set_meta(&"ghosted", st)
	b.set_meta(&"cargo_gravity", b.gravity_scale)
	b.gravity_scale = 0.0
	b.global_transform = r2g * xf
	b.linear_velocity = r2g.basis * v
	b.angular_velocity = r2g.basis * w
	var keep := {}
	for c in b.get_children():
		if c is Node3D and not c is CollisionShape3D:
			keep[c] = (c as Node3D).transform
			(c as Node3D).top_level = true
	b.set_meta(&"cargo_views", keep)
	_draw(b, st)
	b.reset_physics_interpolation()


## `b` out of the ghost back into the world (`world_space`) at the real place.
static func get_off(b: RigidBody3D, st: SpaceStation, world_space: RID) -> void:
	var g2r := st.ghost_to_real() if st != null and is_instance_valid(st) else Transform3D.IDENTITY
	var g := b.global_transform
	var v := g2r.basis * b.linear_velocity
	if st != null and is_instance_valid(st):
		v += st.deck_velocity(g.origin)
	PhysicsServer3D.body_set_space(b.get_rid(), world_space)
	b.remove_meta(&"ghosted")
	b.gravity_scale = float(b.get_meta(&"cargo_gravity", 1.0))
	b.remove_meta(&"cargo_gravity")
	b.constant_force = Vector3.ZERO
	b.global_transform = g2r * g
	b.linear_velocity = v
	b.angular_velocity = g2r.basis * b.angular_velocity
	var keep: Dictionary = b.get_meta(&"cargo_views", {})
	for c in keep:
		if is_instance_valid(c):
			(c as Node3D).top_level = false
			(c as Node3D).transform = keep[c]
	b.remove_meta(&"cargo_views")
	b.reset_physics_interpolation()


## The ship's down on it, in the ghost (none where the ship pulls nothing).
static func _pull(b: RigidBody3D, st: SpaceStation) -> void:
	b.constant_force = -st.ghost_up() * G * b.mass if st.ghost_pulls() else Vector3.ZERO


## Its visuals where it is on the real ship.
static func _draw(b: RigidBody3D, st: SpaceStation) -> void:
	var at := st.ghost_to_real() * b.global_transform
	var keep: Dictionary = b.get_meta(&"cargo_views", {})
	for c in keep:
		if is_instance_valid(c):
			(c as Node3D).global_transform = at * (keep[c] as Transform3D)


## Where `b` is in the world: its body's place, or aboard a ghost the real ship's.
static func world_xf(b: RigidBody3D) -> Transform3D:
	if b.has_meta(&"ghosted"):
		var st := b.get_meta(&"ghosted") as SpaceStation
		if st != null and is_instance_valid(st):
			return st.ghost_to_real() * b.global_transform
	return b.global_transform
