class_name MeleeStrike
extends RefCounted
## One melee blow (Docs/Weapons/COMBAT_DESIGN.md 4.1): what it reaches and what it does.
##
## The damage is `CombatScale.melee(tier)` at the striker's story tier -- never the gun
## in hand, never the player level -- so on level a blow is one "melee" of whatever
## layer it meets: an enemy's card says how many it takes, and that is what it takes.
## A shield takes 1.5x (Elements.MELEE), nothing is a crit, and a blow that breaks a
## layer stops there (DamagePacket.melee).
##
## Reach is a short ray from the eye, then a fat sphere ahead of it if the ray found
## nothing alive: a melee forgives aim the way a bullet does not, but never reaches
## through a wall (the sphere's pick must be in clear line from the eye).

## How far a blow reaches from the eye, and how wide it forgives.
const REACH := 1.8
const RADIUS := 0.5
## Seconds from one blow to the next can begin; the gun is down for the first part.
const RECOVERY := 0.65
const GUN_DOWN := 0.35
## Kinetic Lunge (COMBAT_DESIGN 4.2): the pawn's speed toward a blow landed past REACH.
const LUNGE_SPEED := 9.0
## Backstab: a blow lands "from behind" when it travels within this of the way the
## target faces (the dot of the two).
const BEHIND_DOT := 0.5


## Strike from `from` along `dir`. Returns {} when nothing alive was in reach, else
## {"point", "normal", "collider", "structure": false, "result": DamageResult} -- the
## shape of GunController's `fired` info, so a hit marker reads either -- and what the
## skill tree's melee reads: "target" (the living root hit), "broke_shield" (the blow
## took a shield down), "backstab" (it landed from behind and `backstab` multiplied it).
## `reach` stretches the blow (Kinetic Lunge).
static func strike(world: World3D, from: Vector3, dir: Vector3, tier: int,
		exclude: Array[RID], source: Node = null, mask := Layers.GUN_MASK, reach := 1.0,
		backstab := 1.0) -> Dictionary:
	var space := world.direct_space_state
	dir = dir.normalized()
	var length := REACH * reach
	var target: Node = null
	var point := Vector3.ZERO
	var normal := -dir
	var collider: Object = null

	var q := PhysicsRayQueryParameters3D.create(from, from + dir * length, mask, exclude)
	var hit := space.intersect_ray(q)
	if not hit.is_empty():
		collider = hit.collider
		target = GunController._living(collider)
		point = hit.position
		normal = hit.normal
	if target == null and hit.is_empty():
		var picked := _sphere_pick(space, from, dir, mask, exclude, length)
		if not picked.is_empty():
			collider = picked.collider
			target = picked.target
			point = picked.point
	if target == null:
		return {}

	var behind := backstab != 1.0 and is_behind(target, dir)
	var p := DamagePacket.new(CombatScale.melee(tier) * (backstab if behind else 1.0), null, source)
	p.melee = true
	p.scale = &"person"
	p.hit_position = point
	p.hit_normal = normal
	var pool := DamageSystem._find_health_pool(target)
	var had_shield := pool != null and pool.top_layer_type() == &"shield"
	var result := DamageSystem.resolve(p, target)
	return {"point": point, "normal": normal, "collider": collider, "structure": false,
			"result": result, "target": target, "backstab": behind,
			"broke_shield": had_shield and pool.top_layer_type() != &"shield"}


## A blow along `dir` reaches `target` from behind: it travels the way the target faces.
## Only a pawn has a facing; anything else has no back.
static func is_behind(target: Node, dir: Vector3) -> bool:
	var pawn := target.get_node_or_null(^"Pawn") as Pawn
	if pawn == null:
		return false
	var yaw := pawn.intents.look_yaw
	var facing := Vector3(-sin(yaw), 0.0, -cos(yaw))
	var flat := Vector3(dir.x, 0.0, dir.z)
	if flat.length_squared() < 1e-6:
		return false
	return facing.dot(flat.normalized()) > BEHIND_DOT


## The living body in the sphere ahead nearest the line of the blow, that the eye can
## see. {} for none.
static func _sphere_pick(space: PhysicsDirectSpaceState3D, from: Vector3, dir: Vector3,
		mask: int, exclude: Array[RID], length := REACH) -> Dictionary:
	var sphere := SphereShape3D.new()
	sphere.radius = RADIUS
	var sq := PhysicsShapeQueryParameters3D.new()
	sq.shape = sphere
	sq.transform = Transform3D(Basis.IDENTITY, from + dir * (length - RADIUS))
	sq.collision_mask = mask
	sq.exclude = exclude
	var best := {}
	var best_off := INF
	for r in space.intersect_shape(sq, 16):
		var target := GunController._living(r.collider)
		if target == null or not (r.collider is Node3D):
			continue
		var at: Vector3 = (r.collider as Node3D).global_position
		# Aim at its middle, at no more than the blow's reach.
		var to := at - from
		var along := clampf(to.dot(dir), 0.0, length)
		var near := from + dir * along
		var off := near.distance_to(at)
		if off >= best_off:
			continue
		var los := PhysicsRayQueryParameters3D.create(from, at, mask, exclude)
		var block := space.intersect_ray(los)
		if not block.is_empty() and block.collider != r.collider \
				and GunController._living(block.collider) != target:
			continue
		best_off = off
		best = {"collider": r.collider, "target": target,
				"point": block.position if not block.is_empty() else at}
	return best
